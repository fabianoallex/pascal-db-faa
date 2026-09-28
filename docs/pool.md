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

## Threads

The pool and the factory are meant to be shared by every thread. A connection, a query and a
scope are not: each thread acquires its own and releases it when done. Workers in the sample are
`TThread` subclasses; `TThread.CreateAnonymousThread` doesn't exist on FPC 3.2.2.

On FPC, `Output` is per thread (a `threadvar`): with the output redirected on Linux, lines from
different threads came out cut in the middle even under a lock. Call `Flush(Output)` inside the
lock, after `Writeln` (gotcha 20 in [`CLAUDE.md`](../CLAUDE.md)).
