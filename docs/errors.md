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
| Opening a **new** connection fails (server down, wrong host or port, bad credentials, missing client library) | **the driver's own exception**, different for each driver | `AcquireQuery` / `AcquireConnection` |
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

A failed connect is the driver's exception, not `EDatabaseUnavailableException`, and its text
rarely says which setting was wrong. To report a bad configuration clearly, acquire a
connection once at startup: at that point an exception can only mean "could not connect".

```pascal
try
  LConn := LFactory.GetPool.AcquireConnection;
  LConn := nil;   // back to the pool
except
  on E: Exception do
  begin
    Writeln('Could not connect to ', DescribeSettings, ': ', E.Message);  // your own summary
    raise;
  end;
end;
```

`TestConnection(CreateConnection)` is **not** a way to do this: `CreateConnection` already opens
the connection on SQLdb, so it raises before `TestConnection` runs. `TestConnection` answers
"is this open connection still alive?" (the pool uses it on connections idle for 2 minutes or
more) and returns `False` instead of raising.

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

## Pool timeouts

`EPoolTimeoutException` means every connection stayed busy for the whole wait
(`PoolWaitMaxAttemps` × `PoolWaitMilliseconds`). Its message has the pool's state ("Pool: 3/3
active, 0 queued. Attempts: 20"). What it means is the caller's decision, often "try again
later" (503). [Guide 7](pool.md) covers the settings and the events that show it coming.
