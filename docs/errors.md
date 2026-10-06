# 6. Errors

Samples: [`02-quickstart`](../samples/02-quickstart/Quickstart.dpr) (connecting, a failing
batch), [`05-pool`](../samples/05-pool/PoolUnderLoad.dpr) (pool timeouts); the connection
check is `CheckSampleConnection` in
[`common/Samples.Env.pas`](../samples/common/Samples.Env.pas).

The library doesn't wrap every error in its own exception. What you get depends on **when**
the failure happens:

| When | What is raised | Where |
|---|---|---|
| Creating the factory | nothing because the server is down | the pool's initial connections that fail are retried on the next acquire |
| Opening a **new** connection fails (server down, wrong host or port, bad credentials, missing client library) | `EDatabaseConnectException`, a subclass of `EDatabaseUnavailableException`; the driver's detail is in `OriginalClassName` / `OriginalMessage` | `AcquireQuery` / `AcquireConnection` |
| An **open** connection drops while in use | `EDatabaseUnavailableException` | `Open`, `ExecSql`, `StartTransaction`, `Commit`, `Rollback` |
| A constraint violation: duplicate key, missing or still referenced row, NULL in a NOT NULL column, a CHECK | `EConstraintViolationException`, with `Kind`; the driver's detail is in `OriginalClassName` / `OriginalMessage` | `Open`, `ExecSql`, a batch's `Execute`; `Commit` for a deferred constraint |
| Any other data error: bad SQL, wrong type, value too long | the driver's own exception, unchanged | `Open`, `ExecSql`, `Commit` |
| Another transaction holds or changed the data: a lock wait longer than `LockTimeoutMs`, an update conflict, a deadlock | `ELockConflictException`; the driver's detail is in `OriginalClassName` / `OriginalMessage` | `Open`, `ExecSql` |
| No free connection within the wait limit | `EPoolTimeoutException` (unit `PascalDb.Pool`) | `AcquireQuery` / `AcquireConnection` |
| A SQL key that doesn't exist | `ESQLLoaderException` | `SqlLoader['KEY']` |
| A `.sql` file or resource with non-ASCII text while an FPC program's code page isn't UTF-8 | `ESqlSourceException` | `SqlLoader['KEY']` |

## A connection lost in use: `EDatabaseUnavailableException`

When a native call fails and the connection turns out to be gone (the driver says it is
disconnected, or the call crashed with an access violation inside the client library), the
library:

- raises `EDatabaseUnavailableException`, whose `Message` ("Database unavailable or connection
  lost. Please try again shortly.") is safe to show to a user or return from an API; the
  driver's text and class are kept in `OriginalMessage` and `OriginalClassName`, for the log;
- marks the connection so the pool **discards** it instead of handing it out again.

A layer on top would usually answer 503 for it. A data error on a healthy connection is *not*
converted: the connection stays in the pool, and discarding it on every duplicate key would
churn connections for nothing.

## Connecting

When the pool can't open a connection, the acquire raises `EDatabaseConnectException`,
whatever the driver. It is an `EDatabaseUnavailableException`, so one handler covers "lost in
use" and "could not connect"; catch `EDatabaseConnectException` first when the two need
different handling. Its `Message` is generic ("Could not connect to the database."): the
acquire can't tell a server that is down from a wrong password or a missing client library, so
it doesn't say that trying again will help. The driver's class and text are in
`OriginalClassName` and `OriginalMessage`, and they rarely say which setting was wrong.

To report a bad configuration clearly, acquire a connection once at startup: at that point the
failure is almost always the configuration, not an outage.

```pascal
try
  LConn := LFactory.GetPool.AcquireConnection;
  LConn := nil;   // back to the pool
except
  on E: EDatabaseConnectException do
  begin
    Writeln('Could not connect to ', DescribeSettings, ': ', E.OriginalMessage);  // your own summary
    raise;
  end;
end;
```

Only the pool converts the exception. `IDBFactory.CreateConnection`, which opens a connection
outside the pool, still raises the driver's own.

`TestConnection(CreateConnection)` is **not** a way to do this: `CreateConnection` already opens
the connection on SQLdb, so it raises before `TestConnection` runs. `TestConnection` answers
"is this open connection still alive?" (the pool uses it on connections idle for
`PoolValidateIdleSeconds` or more, 2 minutes by default, and for the keepalive) and returns
`False` instead of raising.

## Transactions and exceptions

Always roll back in the `except` and re-raise, as in [guide 1](getting-started.md):

```pascal
LScope.StartTransaction;
try
  ...
  LScope.Commit;
except
  LScope.Rollback;
  raise;
end;
```

In [sample 02](../samples/02-quickstart/Quickstart.dpr), a batch whose second insert violates the
primary key raises `EConstraintViolationException` and the rollback leaves none of the batch in
the table.

## Constraint violations: `EConstraintViolationException`

When the database rejects a statement because of a constraint, the adapters raise
`EConstraintViolationException` instead of the driver's exception, whatever the driver.
`Kind` says which constraint:

| `Kind` | The statement | A layer on top would usually answer |
|---|---|---|
| `cvUnique` | repeated a primary key or a unique column | 409 |
| `cvForeignKey` | referred to a row that doesn't exist, or deleted (or changed the key of) a row others refer to | 409 |
| `cvNotNull` | left a NOT NULL column NULL | 422 (or 400) |
| `cvCheck` | broke a CHECK constraint | 422 (or 400) |

`Message` is generic and safe to show ("A record with the same key already exists.", ...); the
driver's class and text, with the constraint's name, are in `OriginalClassName` /
`OriginalMessage`. The connection is healthy and stays in the pool. As after any error, roll the
transaction back: on PostgreSQL nothing else runs in it.

Let the database enforce the key and turn the exception into your own where the caller needs to
know:

```pascal
procedure TProductRepository.Insert(const AProduct: TProduct);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['PRODUCT.INSERT'].SQL;
    // ... bind the parameters ...
    LQuery.ExecSql;
    LScope.Commit;
  except
    on E: EConstraintViolationException do
    begin
      LScope.Rollback;
      if E.Kind = cvUnique then
        raise EProductAlreadyExists.CreateFmt('Product %s already exists', [AProduct.Code]);
      raise;
    end;
    on Exception do
    begin
      LScope.Rollback;
      raise;
    end;
  end;
end;
```

Checking *before* the insert instead would leave a gap in which another connection inserts the
same key; the database's constraint is what actually decides.

A constraint declared `DEFERRABLE INITIALLY DEFERRED` (PostgreSQL, SQLite) is checked by the
`Commit`, which then raises the same exception.

What each adapter recognizes (measured with the contract suite on every database):

| Database | `cvUnique` | `cvForeignKey` | `cvNotNull` | `cvCheck` |
|---|---|---|---|---|
| Firebird | GDS `isc_unique_key_violation`, `isc_no_dup` | `isc_foreign_key` | `isc_not_valid` with `*** null ***` | `isc_check_constraint`; `isc_not_valid` otherwise (a domain's CHECK) |
| PostgreSQL | SQLSTATE `23505` | `23503` | `23502` | `23514` |
| MySQL / MariaDB | errors 1062, 1586 | 1451, 1452 (1216, 1217 on old servers) | 1048, 1364 | 3819 (MySQL), 4025 (MariaDB) |
| SQL Server | errors 2627, 2601 | 547 (FOREIGN KEY / REFERENCE) | 515 | 547 (CHECK) |
| SQLite | extended codes 2067, 1555 | 787 | 1299 | 275 |

**SQLite checks foreign keys only when the connection asks for it** (`PRAGMA foreign_keys`).
The adapters turn it on for every connection unless the settings say otherwise:
`foreign_keys=OFF` (SQLdb, Zeos) or `ForeignKeys=Off` (FireDAC).

To test this without a database, make the mock fail the `INSERT` with `AddConstraintViolation`
([guide 5](testing-with-the-mock.md#simulating-a-database-error)).

## Locks and conflicts: `ELockConflictException`

A statement that changes a row another transaction has changed and not yet committed waits
for that transaction to end. On Firebird and PostgreSQL it waits **as long as it takes**: a
transaction left open by a stuck request holds every later writer of the same rows, and each
of them holds a pooled connection while it waits. `IDatabaseConfig.LockTimeoutMs` bounds that
wait:

```pascal
LConfig.LockTimeoutMs := 5000;  // give up after 5 s
```

The statement then fails with `ELockConflictException`, whatever the driver. The same class
covers the other ways another transaction can stop a change: Zeos and FireDAC on Firebird not
waiting at all, an **update conflict** (the row was changed by a transaction that committed while this one
waited, on Firebird's snapshot isolation), a **deadlock**, and PostgreSQL's serialization
failure. They share one class because the databases don't tell them apart reliably (Firebird 5
reports an expired lock timeout with the same codes as an update conflict) and because the
remedy is the same: roll the transaction back (on PostgreSQL nothing else runs in it after an
error) and, when the work is safe to repeat, repeat the whole unit of work later, as in
[trying again after an outage](#trying-again-after-an-outage). A layer on top would usually
answer 409.

`Message` ("The data is locked or was changed by another transaction.") is safe to show; the
driver's detail is in `OriginalClassName` / `OriginalMessage`. The connection is healthy and
stays in the pool.

| Database | How `LockTimeoutMs` is applied | With `LockTimeoutMs` = 0 (default) | Recognized as a conflict |
|---|---|---|---|
| Firebird | transaction parameters (`isc_tpb_wait` + `isc_tpb_lock_timeout`), **whole seconds**: the value is rounded up | SQLdb waits until the lock is released; **Zeos and FireDAC don't wait at all** (their transactions are `nowait`, so the statement fails at once) | GDS `isc_lock_timeout`, `isc_lock_conflict`, `isc_deadlock`, `isc_update_conflict` |
| PostgreSQL | `lock_timeout` of each server session | waits until the lock is released | SQLSTATE `55P03`, `40P01`, `40001` |
| MySQL / MariaDB | `innodb_lock_wait_timeout` of each server session, **whole seconds**: the value is rounded up | the server's `innodb_lock_wait_timeout` (50 s by default) | errors 1205 (`ER_LOCK_WAIT_TIMEOUT`), 1213 (`ER_LOCK_DEADLOCK`) |
| SQL Server | `SET LOCK_TIMEOUT` on each connection, in milliseconds | waits until the lock is released | errors 1222 (lock request time out), 1205 (deadlock victim) |
| SQLite | the busy timeout, for the database's single write lock | 5000 ms (the adapters' busy timeout); an explicit `BusyTimeout` / `busytimeout` setting wins over `LockTimeoutMs` | `SQLITE_BUSY`, `SQLITE_LOCKED` |

What `LockTimeoutMs` doesn't cover: a slow query that isn't waiting for anyone (a full scan, a
big report) runs to the end, and a plain `SELECT` rarely waits for a lock at all (Firebird and
PostgreSQL read the last committed version of the row).

Measured with the contract test `LockWait_GivesUpAfterLockTimeout` (1000 ms): every adapter
gave up after about 1 s — SQLdb and Zeos on Firebird 2.5, PostgreSQL 17 and SQLite (Windows) and
on Firebird 5 (Linux), FireDAC and Zeos on Delphi (Win32 and Win64; PostgreSQL Win64 only),
SQLdb and Zeos on MySQL 8.4 and MariaDB 11.4 (FPC, Windows and Linux), FireDAC and Zeos on them
with Delphi (Win32 and Win64), SQLdb and Zeos on SQL Server 2022 (FPC, Windows and Linux), and Zeos on it with Delphi (Win32
and Win64).
Without the setting, PostgreSQL and SQLdb on Firebird waited the full 8 s the test held the lock,
Zeos on Firebird failed at once (FireDAC's transactions showed the same `nowait` in
`MON$TRANSACTIONS`), and SQLite gave up after 5 s.

## Pool timeouts

`EPoolTimeoutException` means every connection stayed busy for the whole wait
(`PoolWaitMaxAttemps` × `PoolWaitMilliseconds`). Its message has the pool's state ("Pool: 3/3
active, 0 queued. Attempts: 20"). What it means is the caller's decision, often "try again
later" (503). [Guide 7](pool.md) covers the settings and the events that show it coming.

It is about capacity, not about the database being down: that raises
`EDatabaseConnectException` or `EDatabaseUnavailableException` (below). The pool already waits
for a free connection; to wait longer, raise `PoolWaitMaxAttemps` rather than looping around
the acquire.

## Trying again after an outage

The library doesn't retry anything by itself. A statement that failed with the connection may
or may not have run on the server (a `Commit` that failed may have committed), and the
transaction it belonged to is gone with the connection. Only the caller knows whether the work
can be repeated. What the pool does on its own: it discards the broken connection, pings every
idle one before handing it out again (they probably died together), and opens new ones as
needed.

When the work is safe to repeat, repeat **the whole unit of work** (acquire, transaction,
commit), catching `EDatabaseUnavailableException`, which also covers `EDatabaseConnectException`.
Bound it by total time and wait longer each round:

```pascal
uses PascalCommon.Threading; // PcTickMs: a monotonic clock on both compilers (pascal-common-faa)

procedure TOrderService.SaveWithRetry(const AOrder: TOrder);
const
  DEADLINE_MS = 10000;
var
  LStart: UInt64;
  LDelayMs: Cardinal;
begin
  LStart := PcTickMs;
  LDelayMs := 200;
  while True do
    try
      Save(AOrder); // acquires, starts the transaction, ..., commits (or rolls back and re-raises)
      Exit;
    except
      on E: EDatabaseUnavailableException do
      begin
        if PcTickMs - LStart + LDelayMs > DEADLINE_MS then
          raise;
        Sleep(LDelayMs);
        LDelayMs := LDelayMs * 2; // 200, 400, 800 ms, ...
      end;
    end;
end;
```

Things to decide before using it:

- **Is the work idempotent?** A read is. An `UPDATE ... SET STATUS = 'PAID'` is. An `INSERT` with
  a key the database generates is not: after a failed `Commit`, check whether the row is there
  before inserting again (a `cvUnique` [constraint violation](#constraint-violations-econstraintviolationexception) says it is),
  or generate the key in the caller.
- **How long can the caller wait?** Each round holds a thread. In a server, a short deadline and
  then a 503 (letting the client or the load balancer try again) usually hold up better than
  many threads sleeping at once.
- **Is it a configuration error?** A wrong password or a missing client library also raises
  `EDatabaseConnectException` and will fail every round; checking the connection at startup
  ([Connecting](#connecting)) catches those before any retry loop runs.
