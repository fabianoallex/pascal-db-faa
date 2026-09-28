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
| A data error: constraint violation, bad SQL, wrong type | the driver's own exception, unchanged | `Open`, `ExecSql`, `Commit` |
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
primary key raises the driver's exception and the rollback leaves none of the batch in the
table.

## Turning a duplicate key into your own exception

A constraint violation arrives as the driver's exception, whose class and error code differ
for every driver and database, so matching on them ties the repository to one driver. A
portable way: let the database enforce the key, and when the `INSERT` fails, ask, in a new
transaction, whether the key exists now.

```pascal
procedure TProductRepository.Insert(const AProduct: TProduct);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  try
    LScope := FFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    try
      LQuery.Sql := FFactory.SqlLoader['PRODUCT.INSERT'].SQL;
      // ... bind the parameters ...
      LQuery.ExecSql;
      LScope.Commit;
    except
      LScope.Rollback;
      raise;
    end;
  except
    on E: Exception do
    begin
      LQuery := nil;  // give the connection back before Exists takes one
      LScope := nil;
      // Not EDatabaseUnavailableException: a lost connection is not a duplicate.
      if not (E is EDatabaseUnavailableException) and Exists(AProduct.Code) then
        raise EProductAlreadyExists.CreateFmt('Product %s already exists', [AProduct.Code]);
      raise;
    end;
  end;
end;
```

`Exists` is a plain `SELECT` by key in its own scope. Checking *before* the insert instead would
leave a gap in which another connection inserts the same key; the database's constraint is what
actually decides. Where every target database supports it, `INSERT ... ON CONFLICT DO NOTHING
RETURNING ...` (PostgreSQL, SQLite) opened with `Open` answers in one statement, but Firebird has
no `ON CONFLICT`.

To test this without a database, make the mock fail the `INSERT` with `AddFailure` and answer
the existence check with `AddResult` ([guide 5](testing-with-the-mock.md#simulating-a-database-error)).

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
uses PascalDb.Threading; // PdbTickMs: a monotonic clock on both compilers

procedure TOrderService.SaveWithRetry(const AOrder: TOrder);
const
  DEADLINE_MS = 10000;
var
  LStart: UInt64;
  LDelayMs: Cardinal;
begin
  LStart := PdbTickMs;
  LDelayMs := 200;
  while True do
    try
      Save(AOrder); // acquires, starts the transaction, ..., commits (or rolls back and re-raises)
      Exit;
    except
      on E: EDatabaseUnavailableException do
      begin
        if PdbTickMs - LStart + LDelayMs > DEADLINE_MS then
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
  before inserting again (as in [the duplicate key section](#turning-a-duplicate-key-into-your-own-exception)),
  or generate the key in the caller.
- **How long can the caller wait?** Each round holds a thread. In a server, a short deadline and
  then a 503 (letting the client or the load balancer try again) usually hold up better than
  many threads sleeping at once.
- **Is it a configuration error?** A wrong password or a missing client library also raises
  `EDatabaseConnectException` and will fail every round; checking the connection at startup
  ([Connecting](#connecting)) catches those before any retry loop runs.
