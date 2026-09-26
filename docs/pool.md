# 7. The connection pool

Sample: [`05-pool`](../samples/05-pool/PoolUnderLoad.dpr): worker threads against a small
pool, watched through its events and snapshots.

Each factory owns one pool (`IDBFactory.GetPool`). Every `AcquireQuery` /
`AcquireConnection` takes a connection from it, and releasing the interfaces gives the
connection back ([guide 1](getting-started.md)).

## Settings

All on `IDatabaseConfig`. `TDatabaseConfig` starts with every one of them at 0, so set at least
the first four.

| Setting | Meaning |
|---|---|
| `PoolIniConnections` | connections opened when the factory is created. If the database is down then, the failures become events and the next acquire tries again: the program still starts |
| `PoolMaxConnections` | the most connections the pool will have open at once. **0 means none**: the first acquire raises `EPoolTimeoutException` |
| `PoolWaitMaxAttemps`, `PoolWaitMilliseconds` | when all `PoolMaxConnections` are busy, a caller checks again every `PoolWaitMilliseconds`, up to `PoolWaitMaxAttemps` times, then gets `EPoolTimeoutException` |
| `PoolIdleTimeoutSeconds` | close connections idle for this long, never going below `PoolIniConnections`. 0 (the default) turns the sweep off |
| `PoolIdleCheckIntervalMs` | how often the sweep runs (default 30000). Only matters when the sweep is on |

The samples use 1 initial, 5 max and 50 × 100 ms of waiting. Size `PoolMaxConnections` to what
the database accepts from this program, not to the number of threads: a thread that has to
wait a little for a connection is normal.

## What the pool does by itself

- **Grows on demand**: when no idle connection is left, it opens a new one, up to
  `PoolMaxConnections`.
- **Checks old connections before reusing them**: a connection idle for 2 minutes or more gets
  the dialect's ping first, and is discarded if it fails.
- **Discards broken connections**: a connection that dropped while in use comes back marked
  and is closed instead of queued ([guide 6](errors.md)).
- **Sweeps idle connections** when `PoolIdleTimeoutSeconds` is set, in a background thread.

## Events

Pass a handler to the adapter's factory constructor to hear about what isn't the happy path:

```pascal
LFactory := TSQLdbFactory.Create(LConfig, nil, LMonitor.OnPoolEvent);
```

| `TPoolEvent.Kind` | When |
|---|---|
| `pekConnectionCreated` | a physical connection was opened (initial or growth) |
| `pekConnectionDiscarded` | a connection was dropped; `DiscardReason`: `pdrConnectFailed` (opening or reopening failed; `ErrorMessage` has why), `pdrStaleCheckFailed` (the ping failed), `pdrBrokenAfterUse` (it dropped while in use) |
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

## Threads

The pool and the factory are meant to be shared by every thread. A connection, a query and a
scope are not: each thread acquires its own and releases it when done. Workers in the sample are
`TThread` subclasses; `TThread.CreateAnonymousThread` doesn't exist on FPC 3.2.2.

On FPC, `Output` is per thread (a `threadvar`): with the output redirected on Linux, lines from
different threads came out cut in the middle even under a lock. Call `Flush(Output)` inside the
lock, after `Writeln` (gotcha 20 in [`CLAUDE.md`](../CLAUDE.md)).
