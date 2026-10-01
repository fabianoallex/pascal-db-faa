# 7. The connection pool

Sample: [`05-pool`](../samples/05-pool/PoolUnderLoad.dpr): worker threads against a small
pool, watched through its events and snapshots.

Each factory owns one pool (`IDBFactory.GetPool`). Every `AcquireQuery` /
`AcquireConnection` takes a connection from it, and releasing the interfaces gives the
connection back ([guide 1](getting-started.md)).

## Settings

All on `IDatabaseConfig`, with the defaults `TDatabaseConfig` starts with.

| Setting | Default | Meaning |
|---|---|---|
| `PoolIniConnections` | 1 | connections opened when the factory is created. If the database is down then, the failures become events and the next acquire tries again: the program still starts |
| `PoolMaxConnections` | 10 | the most connections the pool will have open at once. Below 1, creating the factory raises `EArgumentException` |
| `PoolWaitMaxAttemps`, `PoolWaitMilliseconds` | 50, 100 | when all `PoolMaxConnections` are busy, a caller checks again every `PoolWaitMilliseconds`, up to `PoolWaitMaxAttemps` times, then gets `EPoolTimeoutException`. `PoolWaitMaxAttemps` = 0 means no waiting at all |
| `PoolIdleTimeoutSeconds` | 0 | close connections idle for this long, never going below `PoolIniConnections`. 0 turns the sweep off |
| `PoolIdleCheckIntervalMs` | 30000 | how often the background thread runs the sweep and the keepalive. Only matters when one of them is on |
| `PoolValidateIdleSeconds` | 120 | a connection not known to work for this long (since its release or its last keepalive ping) gets the dialect's ping before it is handed out. 0 pings on every acquire (one extra round trip each time); negative never pings |
| `PoolKeepaliveSeconds` | 0 | the background thread pings idle connections not known to work for this long, and closes the ones that fail. 0 turns it off |

The samples use 1 initial, 5 max and 50 × 100 ms of waiting. Size `PoolMaxConnections` to what
the database accepts from this program, not to the number of threads: a thread that has to
wait a little for a connection is normal.

## What the pool does by itself

- **Grows on demand**: when no idle connection is left, it opens a new one, up to
  `PoolMaxConnections`.
- **Reuses the most recently released connection first** (last in, first out). The same few
  connections do the work, and the ones a peak left behind stay idle long enough for the
  sweep to close them.
- **Checks old connections before reusing them**: a connection not known to work for
  `PoolValidateIdleSeconds` or more (2 minutes by default) gets the dialect's ping first, and is
  discarded if it fails; the acquire then tries the next one. The ping has no timeout of its
  own: on a connection the network dropped silently, it waits as long as the driver does.
- **Suspects the idle connections once one proves dead**: when a connection drops in use,
  fails to connect or fails a ping, the idle ones probably died with it (a server restart, a
  failover), so each gets the ping on its next acquire however recent its release (unless
  `PoolValidateIdleSeconds` is negative). After a restart, one request fails instead of one per
  idle connection.
- **Discards broken connections**: a connection that dropped while in use comes back marked
  and is closed instead of queued ([guide 6](errors.md)).
- **Sweeps idle connections** when `PoolIdleTimeoutSeconds` is set, in a background thread.
- **Keeps idle connections alive** when `PoolKeepaliveSeconds` is set: the same thread pings
  them, so a firewall or the server's idle limit doesn't drop them, and an acquire finds them
  already checked. Set it below whichever of those limits is shortest, and below
  `PoolValidateIdleSeconds` if you want the acquire to skip its ping. A ping doesn't count as
  use: the sweep still closes a connection nobody used for `PoolIdleTimeoutSeconds`. While a
  connection is being pinged it is out of the pool (an acquire gets another one, or opens one),
  and a ping stuck on a dead network holds the background thread, never an acquire.

Idle times are measured on a monotonic clock, so changing the system time (daylight saving, a
manual adjustment) doesn't age the connections. Tests can replace that clock with
`TTicker.SetTicker` (`PascalDb.SystemContext`).

## Events

Pass a handler to the adapter's factory constructor to hear about what isn't the happy path:

```pascal
LFactory := TSQLdbFactory.Create(LConfig, nil, LMonitor.OnPoolEvent);
```

| `TPoolEvent.Kind` | When |
|---|---|
| `pekConnectionCreated` | a physical connection was opened (initial or growth) |
| `pekConnectionDiscarded` | a connection was dropped; `DiscardReason`: `pdrConnectFailed` (opening or reopening failed; `ErrorMessage` has why), `pdrStaleCheckFailed` (the ping failed, on acquire or in the keepalive), `pdrBrokenAfterUse` (it dropped while in use) |
| `pekAcquireThrottled` | a caller had to wait (`WaitAttempts`) and **then got** a connection |
| `pekAcquireTimeout` | a caller gave up; `EPoolTimeoutException` is raised right after |
| `pekIdleSweepClosed` | the sweep closed `ClosedCount` connections |

Every event also carries the pool's state (`ActiveConnections`, `PoolSize` = idle connections,
`MaxConnections`, `IniConnections`).

Things to know before writing the handler:

- **No event for an ordinary acquire or release**, and no default output: without a handler,
  the pool is silent. A healthy pool under steady load raises no events at all.
- **Events arrive on the thread that caused them**: a worker, or the sweep thread. The handler
  must be thread-safe (the sample sends every console line through one lock).
- `ActiveConnections` also counts connections other threads are still opening, so two
  `pekConnectionCreated` in a row can both say "3 of 3".
- A caller that waits and gets a connection raises `pekAcquireThrottled`; one that waits and
  gives up raises only `pekAcquireTimeout`.
- Pass a **method** as the handler: it compiles on both compilers (FPC 3.2.2 has no anonymous
  methods; Delphi accepts either).

## Snapshots

For periodic reads (a health check, a metrics timer), `GetPool.GetSnapshot` returns the current
state plus counters since the pool was created:

| Field | |
|---|---|
| `ActiveConnections` | open connections now, idle and in use |
| `PoolSize` | idle connections now |
| `MaxConnections`, `IniConnections` | the settings |
| `TotalCreated` | connections opened since start |
| `TotalDiscarded` | connections dropped (failed reconnect, failed ping, broken in use) |
| `TotalTimeouts` | acquires that ended in `EPoolTimeoutException` |
| `TotalIdleSwept` | connections closed by the sweep |

Events answer "what just happened"; the snapshot answers "how much, so far, and how does it
look now".

## Statement events

To see what runs (which SQL, how long it took, how many rows, what failed), pass a statement
handler after the pool one. It is called after every `Open` and `ExecSql` of a query from
`AcquireQuery`, whether it worked or not:

```pascal
type
  TSqlLog = class
    procedure OnStatement(const AInfo: TStatementInfo);
  end;

procedure TSqlLog.OnStatement(const AInfo: TStatementInfo);
begin
  if AInfo.ErrorClass <> '' then
    MyLog.Error(Format('%s failed after %.1f ms: %s', [AInfo.Sql, AInfo.ElapsedUs / 1000, AInfo.ErrorMessage]))
  else if AInfo.ElapsedUs > 500000 then  // 0.5 s
    MyLog.Warn(Format('slow: %.1f ms, %d rows: %s', [AInfo.ElapsedUs / 1000, AInfo.Rows, AInfo.Sql]));
end;

LFactory := TSQLdbFactory.Create(LConfig, nil, LMonitor.OnPoolEvent, LSqlLog.OnStatement);
```

| `TStatementInfo` field | |
|---|---|
| `Kind` | `skOpen` or `skExecSql` |
| `Sql` | the text the query ran, after the SQL tags were processed (not the loader's key: the query never sees it) |
| `ElapsedUs` | microseconds; for `Open`, including fetching every row (what the caller waited) |
| `Rows` | `Open`: the rows fetched; `ExecSql`: -1 (rows affected aren't reported) |
| `ErrorClass`, `ErrorMessage` | empty when it worked; otherwise the class and message the caller gets (`EDatabaseUnavailableException`, `ELockConflictException` or the driver's own) |

- **Once per statement, on the happy path too.** That is why it has its own handler, apart from
  the pool events: without one there is no cost. With one, the handler runs inside every call,
  so keep it cheap; filter there (a threshold, only errors) instead of writing every statement.
- **On the thread that ran the statement.** Make the handler thread-safe. It also means the
  handler can read the caller's own context (the current request, a tenant in a `threadvar`)
  to tag the line: the library knows nothing about it.
- **An exception in the handler is swallowed**: a logger that fails doesn't fail the
  statement, nor replaces its exception.
- **No parameter values.** They would put passwords, tokens and personal data in the logs, and
  `IParams` has no way to list them; the SQL text has the placeholders.
- **Only pooled queries.** A query from `IDBFactory.CreateQuery`, outside the pool, and the mock
  factory's queries aren't reported.
- Time is measured with `PdbTickUs` (`PascalDb.Threading`): on Windows `GetTickCount64` advances
  in 15-16 ms steps (measured), too coarse for a statement that takes 2 ms.

For production, the database's own tools see every client and the query plans: PostgreSQL's
`log_min_duration_statement` and `pg_stat_statements`, Firebird's trace API and
`MON$STATEMENTS`. This handler is the portable, in-program view; SQLite has no server-side
equivalent.

## Threads

The pool and the factory are meant to be shared by every thread. A connection, a query and a
scope are not: each thread acquires its own and releases it when done. Workers in the sample are
`TThread` subclasses; `TThread.CreateAnonymousThread` doesn't exist on FPC 3.2.2.

On FPC, `Output` is per thread (a `threadvar`): with the output redirected on Linux, lines from
different threads came out cut in the middle even under a lock. Call `Flush(Output)` inside the
lock, after `Writeln` (gotcha 20 in [`gotchas.md`](gotchas.md)).

## Database work off the UI thread

Every call in the library blocks until the database answers, and there is no `OpenAsync`. In a
server that is what you want: each request already runs on a worker thread of the HTTP
framework, and the drivers underneath (fbclient, libpq, sqlite3) block anyway, so an
asynchronous wrapper would only hand the wait to yet another thread. In a desktop or mobile
program, a slow query on the main thread freezes the window: run it on a thread of its own.

Move the **whole unit of work** to the thread, not a single `Open`: acquire, transaction,
queries, commit, and a **copy** of the rows. The result of `Open` is the query itself, tied to
its connection and transaction: it can't be handed to the main thread, and on SQLdb the commit
closes it. Hand over plain data (records, objects, strings) instead:

```pascal
type
  TCity = record
    Id: Integer;
    Name: string;
  end;
  TCities = array of TCity;

  TLoadCities = class(TThread)
  private
    FFactory: IDBFactory;
    FCities: TCities;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFactory: IDBFactory);
    property Cities: TCities read FCities;
    property Error: string read FError;  // '' = success
  end;

constructor TLoadCities.Create(const AFactory: IDBFactory);
begin
  FFactory := AFactory;
  inherited Create(False);
end;

procedure TLoadCities.Execute;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  try
    LScope := FFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    try
      LQuery.Sql := FFactory.SqlLoader['CITY.LIST'].SQL;
      LResult := LQuery.Open;
      while not LResult.Eof do
      begin
        SetLength(FCities, Length(FCities) + 1);
        FCities[High(FCities)].Id := LResult.Integers['ID'];
        FCities[High(FCities)].Name := LResult.Strings['NAME'];
        LResult.Next;
      end;
      LScope.Commit;
    except
      LScope.Rollback;
      raise;
    end;
  except
    on E: Exception do
      FError := E.Message;  // an exception must not escape Execute
  end;
end;
```

The form starts it and gets the rows in `OnTerminate`, which runs on the main thread:

```pascal
procedure TCityForm.LoadButtonClick(Sender: TObject);
begin
  LoadButton.Enabled := False;
  FLoader := TLoadCities.Create(FFactory);
  FLoader.OnTerminate := LoaderDone;
end;

procedure TCityForm.LoaderDone(Sender: TObject);
begin
  if FLoader.Error <> '' then
    ShowMessage(FLoader.Error)
  else
    ShowCities(FLoader.Cities);
  LoadButton.Enabled := True;
  // Not freed here: this runs inside the thread's own termination.
end;

procedure TCityForm.FormDestroy(Sender: TObject);
begin
  if Assigned(FLoader) then
  begin
    FLoader.OnTerminate := nil;  // the form is going away: don't call it back
    FLoader.WaitFor;
    FLoader.Free;
  end;
end;
```

Things that bite:

- **Closing waits.** `FormDestroy` blocks until the unit of work ends: a query can't be
  cancelled portably. Keep the work short, or bound its lock waits with `LockTimeoutMs`
  ([guide 6](errors.md#locks-and-conflicts-elockconflictexception)).
- **The callback needs a message loop.** `OnTerminate` (like `TThread.Synchronize` and
  `TThread.Queue`) reaches the main thread only when it calls `CheckSynchronize`. VCL and LCL
  applications do; a console program or a service must call it in its own loop, or the callback
  never arrives.
- **One loader at a time per form**, as above (the button is disabled). Starting a second one
  over `FLoader` would lose the first; keep a list if you need several.
- **Every thread acquires its own query** from the shared factory (see [Threads](#threads)); a
  query acquired on the main thread must not be used by the worker.
- **FPC 3.2.2 has no anonymous methods**, so no `TThread.CreateAnonymousThread` and no closures
  for the callback: a `TThread` subclass and a method, as here, compile on both compilers.

Checked with FPC 3.2.2 (Win64, SQLdb and SQLite, a console loop calling `CheckSynchronize`):
`OnTerminate` ran on the main thread with the rows; a failing query arrived as `Error`; clearing
`OnTerminate`, `WaitFor` and `Free` while the worker was still running waited for it (1 s of work
in the test), never called back, and left 0 leaks (heaptrc). Not run on Delphi.
