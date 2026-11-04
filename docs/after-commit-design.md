# Actions after the commit — design

Status: **H1 done, 2026-11-04** (`PascalDb.AfterCommit`, unreleased): unit suite on FPC Windows
x64 green, 0 leaks; contract suite on the twelve Linux combinations (see "Phases"). **H2 code
done** the same day (`PascalDb.Cache`, guide 12, sample 08); its full Linux run is pending.
Delphi 12 CE, Win32 and Win64: unit suite 254/254, FireDAC contract suite on SQLite 57/57 (and PostgreSQL 17, Win64), sample
08 on SQLite, 0 leaks. The contract test for an abandoned scope found that FireDAC committed it
(gotcha 61, fixed in the adapter). The user's choices (2026-11-04): A2 a unit of its own, A7 as recommended, A9 (a);
every other decision as recommended. What the implementation settled is in "Decided in H1".

## Where this came from

pascal-common-faa 1.29.0 has `PascalCommon.Cache` (its `docs/cache-design.md`). Its decision C11
keeps pascal-db-faa out of the cache's first phases: the application caches its mapped DTO in its
own service, so a hit takes nothing from the pool. Reviewing how an application on this library
would use it (2026-11-04), the one thing missing here is C7's first rule, **invalidate after the
commit, never before**, which this library makes easy to break:

- A repository method gets the caller's `ITransaction`, opens its own scope with
  `AcquireQuery(LQuery, ATransaction)` and commits it. When the caller already had a transaction,
  that scope isn't the main one: its `Commit` only releases a savepoint
  (`TScopeTransaction.Commit`, `PascalDb.Adapter.Base`). A `Cache.Invalidate` written after that
  `Commit` runs before the real commit, and a concurrent reader can load the old row and write it
  back under the new generation (C4's argument only covers a reader that read the generation
  *before* the invalidation).
- The repository can't tell: `IScopeTransaction.IsMain` says whether *its* scope is the main one,
  but when it isn't, the repository has no way to reach the main scope's commit.

C7 itself says "pascal-db-faa could later offer an after-commit hook on `ITransaction` so rule 1
happens by itself". This is that hook. It knows nothing about the cache: the same need shows up
for waking the outbox dispatcher, publishing an event, sending an e-mail after the data is saved.

## What it is

```pascal
// PascalDb.AfterCommit (A2)
type
  TAfterCommitProc = {$IFDEF PASCALDB_FUNCREFS}reference to procedure(const AArg: string)
    {$ELSE}procedure(const AArg: string) of object{$ENDIF};

  IAfterCommitAction = interface
    ['{...}']
    procedure Run;
  end;

/// Runs AProc(AArg) after the main transaction AScope belongs to commits; never if it
/// rolls back (or the savepoint of AScope's own nested scope does, A5).
procedure PdbAfterCommit(const AScope: IScopeTransaction; const AProc: TAfterCommitProc;
  const AArg: string = '');
procedure PdbAfterCommitAction(const AScope: IScopeTransaction; const AAction: IAfterCommitAction);
```

Usage, in a repository that may or may not be the outermost scope:

```pascal
procedure TProductRepository.UpdatePrice(AId: Integer; APrice: Currency;
  ATransaction: ITransaction);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery, ATransaction);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['PRODUCT.UPDATE_PRICE'].SQL;
    LQuery.Params.Integers['ID'] := AId;
    LQuery.Params.Currencies['PRICE'] := APrice;
    LQuery.ExecSql;
    PdbInvalidateAfterCommit(LScope, FCache, ['product:' + IntToStr(AId), 'products.list']);
    LScope.Commit;    // a savepoint release when nested; the invalidation waits for the real one
  except
    LScope.Rollback;
    raise;
  end;
end;
```

## Decisions

### A1 — the actions live on the transaction, not on the scope (recommended)

The list is kept by `TTransactionBase`, the one object every scope of a transaction shares, and
run by `TTransactionBase.Commit` after `DoCommit` succeeds. So the actions run on the real commit
whoever calls it: the main scope, or code that commits an `ITransaction` directly. A nested scope
only adds to its transaction's list.

The transaction exposes it through a side interface, as `ITransactionSpan` already does
(`PascalDb.Pool`):

```pascal
  IAfterCommitActions = interface
    ['{...}']
    procedure Add(const AAction: IAfterCommitAction);
    function Count: Integer;
    /// Drops the actions added after the first ACount (A5).
    procedure Truncate(ACount: Integer);
  end;
```

`TTransactionBase` implements it, so the three adapters and any third-party adapter built on it
get it with no code. Internally a `TAfterCommitProc` + argument is wrapped in an
`IAfterCommitAction`, so the list holds one type.

### A2 — no change to `IScopeTransaction` or `ITransaction` (recommended)

A method on a public interface breaks every class that implements it (the mock's
`TMockScopeTransaction`, third-party adapters' scopes). Free functions over a side interface are
additive: `PdbAfterCommit(AScope, ...)` finds the transaction through
`AScope.OriginalTransaction` and `Supports(..., IAfterCommitActions)`. Same shape as
`PdbDialectOf(AScope)` in `PascalDb.Paging`.

Where: **a unit of its own, `PascalDb.AfterCommit`** (the user's choice; the alternative was
`PascalDb.Interfaces`, with nothing new in a `uses`). `PascalDb.Adapter.Base`, `PascalDb.Pool`
and `PascalDb.Mock` use it.

### A3 — the callback shape (recommended)

Two overloads, because a method on FPC 3.2.2 can't capture local variables (C5 of the cache had
the same problem):

- `TAfterCommitProc(AArg: string)`, following `PASCALDB_FUNCREFS`: a method plus one string, enough
  for "wake the dispatcher" or an id; a closure on Delphi.
- `IAfterCommitAction`: an object carrying its own state, for anything with more than a string
  (the cache's tags). Portable, and what `PdbInvalidateAfterCommit` (A9) builds.

### A4 — order and thread (recommended)

Actions run in the order they were added, on the thread that called `Commit`, after
`InTransaction` is already False. The list is taken out of the transaction before the first one
runs, so an action that commits something else on the same transaction object doesn't run the
list again. A transaction is used by one thread at a time (as today), so the list has no lock.

### A5 — rollback, also of a savepoint (recommended)

- `Rollback` of the transaction drops every action.
- A **nested** scope remembers `Count` when it starts its savepoint; its `Rollback` (to the
  savepoint) calls `Truncate` with that count. Scopes are strictly nested, so the actions added
  after that point are exactly those of the scope that rolled back and of scopes inside it.
- A nested scope's `Commit` (release) does nothing to the list.
- A transaction released without `Commit` (the pool rolls it back on release) or destroyed drops
  its actions with it.

For the cache alone, keeping the actions of a rolled-back savepoint would be harmless (an extra
invalidation is one miss). For "send the e-mail" it isn't, and the truncation costs one integer
per nested scope.

### A6 — a failed commit drops the actions (recommended)

If `DoCommit` raises, the actions are dropped, not run. There is a rare case where the commit
reached the server and the client didn't hear the answer (connection lost during `COMMIT`); then
an invalidation is lost and the value is stale until its TTL, which is the cache's documented
bound (C6). Running the actions on a commit that may not have happened is worse for the other uses.

### A7 — an action that raises doesn't turn the commit into an error (recommended)

The data is committed: raising from `Commit` would make a handler answer 500 for a write that
happened, and a client that retries could write it twice (the same argument as the cache's C6
for `Invalidate`). So:

- each action runs in its own `try/except`; one that raises doesn't stop the next ones;
- the failure is reported as a pool event, a new `pekAfterCommitFailed` kind with
  `ErrorMessage` (and the exception class), on the factory's `AOnPoolEvent`. The pool hands the
  callback to each transaction it creates, through the same side interface (a setter), since
  `TTransactionBase` doesn't know the pool (see "Decided in H1");
- `EExternal` (access violation and the like) is not swallowed: it means memory is corrupt, as in
  `IsConnectionBrokenError`.

Alternative: run them all, then raise an `EAfterCommitException` that says the commit happened.
Honest, but every caller must then know that exception is not a failed write.

Adding a value to `TPoolEventKind` is source-compatible (a `case` without `else` still compiles);
an application that logs every event sees the new kind.

### A8 — adding an action outside a transaction raises (recommended)

`PdbAfterCommit` on a scope whose transaction isn't started raises `EInvalidOperation` ("no
transaction to run after"). Running the action at once would hide the bug this exists for (the
caller thinks it waits for a commit that never comes). A scope or transaction without
`IAfterCommitActions` (an adapter not on `TTransactionBase`) raises too, naming the class.

### A9 — the cache helper (decided: (a))

```pascal
// PascalDb.Cache
procedure PdbInvalidateAfterCommit(const AScope: IScopeTransaction; const ACache: IPcCache;
  const ATags: array of string);
```

An `IAfterCommitAction` holding the cache and a copy of the tags, calling `ACache.Invalidate`
(which never raises `EPcCacheUnavailable`). Small, but it makes the right way the short way.

It needs `PascalCommon.Cache`, i.e. pascal-common-faa **1.29.0**. Options:

- (a) the unit in `pascal_db_faa.lpk` and the minimum version raised to 1.29.0 (the check in
  `PascalDb.Interfaces`, `MinVersion` in the `.lpk`). Every application must then provide 1.29.0
  or later, even one with no cache; within 1.x that is only additions;
- (b) the unit in the repository but outside the package, compiled only by who lists it (with its
  own version check in the unit), the minimum staying at 1.17.0;
- (c) no helper: the usage guide shows the ten-line action class.

Recommendation: (a), **chosen**. The application already provides the one copy of pascal-common-faa, the
other `*-faa` libraries move it forward too, and a unit outside the package is easy to forget in
the Lazarus projects.

### A10 — the mock (recommended)

`TMockScopeTransaction` keeps its own list: `Commit` runs the actions, `Rollback` and the scope's
destruction drop them; adding one before `StartTransaction` raises as in A8. So a service tested
with the mock can assert that the invalidation (or the wake-up) happened after its commit and not
after a rollback. The mock's nested scopes are not modelled (each `AcquireQuery` is its own main
scope), as today.

## Decided in H1 (2026-11-04)

- **Two names, not overloads**: `PdbAfterCommit` (method + string) and `PdbAfterCommitAction`
  (object). On Delphi `TAfterCommitProc` is a `reference to` type, itself an interface, next to an
  overload taking `IAfterCommitAction`; distinct names leave no doubt about which one a call picks,
  and Delphi can't be compiled from the command line here to check.
- **Who sets `OnFailure`**: the pool, in `AcquireQuery`, on each transaction it creates
  (`SetOnFailure` on `IAfterCommitActions`), not `TDBFactory.CreateTransaction`: the factory
  doesn't hold the pool's event handler, the pool does. A transaction made with
  `IDBFactory.CreateTransaction` directly has no reporter: its failing actions are swallowed.
  `TPoolEvent` gained `ErrorClass`.
- **The list**: `TAfterCommitList` (in the unit, shared by `TTransactionBase` and the mock), a
  dynamic array of `IAfterCommitAction` created on the first `Add`, so a transaction that never
  adds one allocates nothing and its `Commit` pays one nil check.
- **`PdbAfterCommitActionsOf(Scope)`** looks at the scope first (the mock's keeps its own list),
  then at `Scope.OriginalTransaction`.
- **The A8 check lives in `Add`**: `TTransactionBase` checks its `InTransaction`, the mock scope
  whether it was started. `TMockScopeTransaction.InTransaction` still returns False (unchanged).
- **A nested scope's mark** is taken in `StartTransaction`, before its savepoint statement, and
  `Truncate` runs before the `ROLLBACK TO SAVEPOINT` statement.

## Tests

- **Unit** (`tests/Unit`, mirrored DUnitX/FPCUnit, 0 leaks): the mock's behaviour (A10); a fake
  `TTransactionBase` descendant for order, the list taken out before running, an action that
  raises (the next ones run, the event is raised, `Commit` doesn't raise), `EExternal` propagating,
  a failed `DoCommit` dropping them, A8's errors.
- **Contract** (`tests/Integration/PascalDb.ContractTests.pas`, every database and adapter): runs
  after a main commit; not after a nested scope's commit until the main one; dropped by the main
  rollback; dropped by a nested scope's rollback while the outer one's still run; dropped when the
  scope is released without commit; an action that reads the row it waited for sees it committed
  from another connection (the point of the whole thing). The savepoint cases run on every
  database, SQL Server included (`SupportsRelease = False`: a nested commit is a no-op there).
- **Cache helper** (if A9 (a) or (b)): `PdbInvalidateAfterCommit` with a `TPcMemoryCacheStore`:
  the key still hits before the commit, misses after; still hits after a rollback.

## Usage guide

`docs/cache.md` (new) with the pattern of pascal-common-faa's "Usage" written for this library:
the cache in the service, reads for the cache in a scope of their own (`AcquireQuery` without
`ATransaction`: C7's second rule, never `Put` what a write transaction read), invalidation with
`PdbInvalidateAfterCommit`, single-flight protecting the pool (N concurrent misses take one
connection). A sample `08-cache` with the memory store, run by `test_samples_docker.sh` on every
database. The submodule `external/pascal-common-faa` moves from 1.26.0 to 1.29.0 or later.

`docs/outbox.md` may later use the hook to wake the dispatcher after a commit that enqueued
messages; not part of this design.

## Open points

- The cost of an empty list on every commit (one nil check expected; measure with the pool's
  benchmark before and after).
- `FIsMain` is decided when the scope is built (`not InTransaction`): a scope built on a
  transaction that a sibling scope starts later is "main" for both. Existing behaviour; check
  whether the hooks change what it costs.

## Phases

| Phase | What | Done when |
|---|---|---|
| H1 | `IAfterCommitActions` on `TTransactionBase`, `PdbAfterCommit`, truncation in `TScopeTransaction`, `pekAfterCommitFailed`, the mock; unit and contract tests | unit suite on FPC and Delphi, contract suite on the twelve Linux combinations and the Windows runners, 0 leaks; minor release (0.19.0) — **FPC done 2026-11-04**: `tests/Unit/PascalDb.AfterCommitTests.pas` (16), unit suite 251/251 on Windows x64, 0 leaks; 3 contract tests (`AfterCommit_*`), 57/57 on the twelve Linux combinations (SQLdb and Zeos × six databases), 0 leaks; the samples on 10 of the 12 (the run was stopped for low memory before Zeos on MySQL, MariaDB and SQL Server). Delphi and the Windows integration runners: not run yet |
| H2 | `PascalDb.Cache` (A9), `docs/cache.md`, sample `08-cache`, submodule to ≥ 1.29.0 | the same suites plus the sample on every database — **code done 2026-11-04**: submodule on v1.29.0, minimum raised to 1.29.0 (`PascalDb.Interfaces`, `.lpk`); 3 more unit tests (`Cache_*`, with a `TPcMemoryCacheStore`), unit suite 254/254 on FPC Windows x64, 0 leaks; sample 08 on FPC Windows x64 with SQLite, its expected lines and 0 leaks, and added to `test_samples_docker.sh`. Not run yet: the Linux samples run, the full CI after the submodule move, Delphi |
