# 11. Transactional outbox

`PascalDb.Outbox` publishes events about database changes without the *dual write*: a program
that commits an order and then sends "order placed" to a broker (or an email, or another
service) loses the event when it stops between the two, or sends it for an order that was
rolled back. With an outbox, the event is a row written **in the same transaction** as the
change, so it exists exactly when the change does; a relay reads those rows afterwards and
hands each to a sink, marking it delivered.

It came from [pascal-agenda-faa](https://github.com/fabianoallex/pascal-agenda-faa), where it
ran from its M4 milestone on (appointments booked, moved and cancelled; reminders), and was
promoted with its tests in 0.18.0. Sample: [07-outbox](../samples/07-outbox/Outbox.dpr).

## What it promises

- **At-least-once delivery.** A relay that stops after the sink and before its commit
  delivers the event again. Whoever handles an event deduplicates by its `Id` (32 random hex
  digits), or does something a repeat doesn't hurt.
- **Order within a batch**: the creation order (`CREATED_AT`, then `ID`). Not across batches,
  retries or relays: an event whose sink failed waits its retry while the next ones go.
- **Nothing lost when a relay dies**: a claimed event carries a lease (owner, until when);
  once it runs out the event is pending again.
- **Several relays may run**: a claim's `UPDATE` only takes rows whose lease is free or
  expired, so two relays never hold one row.

What it doesn't do: no thread, timer or sleep (your program calls the passes), no broker
client (the local sink runs handlers in the relay's process; a broker sink implements
`IOutboxSink`), no reading of the database log (CDC). Polling is enough.

## The pieces

| | |
|---|---|
| `TOutbox.Enqueue(Factory, Query, TenantId, Kind, Payload, Now)` | Writes one event on `Query`'s connection, in the transaction open there, and returns its id. The current span's W3C traceparent (`TPcTracing.Current`) goes with it. `Query`'s SQL is replaced. |
| `TOutboxRelay.RunOnce(Now)` | One pass: claims up to `BatchSize` pending events with a lease, hands each to the sink and marks it delivered in **one transaction with what the sink wrote**. A sink that raises leaves the event pending, with `ATTEMPTS + 1`, its error and a later `AVAILABLE_AT` (`TOutboxRetry`); the rest of the batch goes on. Returns the events delivered. |
| `IOutboxSink.Deliver(Query, Event, Now)` | Where an event goes. `Query` is on the transaction that then marks the event delivered, and it stays open while `Deliver` runs: keep it short (on SQLite it is the database's one write lock). Raise to leave the event pending. A sink's event is never dead: a broker that is down comes back. |
| `TOutboxLocalSink` (`IOutboxLocalSink`) | The sink without a broker: one `OUTBOX_DELIVERIES` row per handler that accepts the event's kind, written in the relay's transaction. Its own `RunOnce(Now)` runs them **outside any transaction** (a handler may send an email), each in a span continuing the event's trace, each retried on its own and `dead` after `MaxAttempts`, so a failing handler neither blocks nor repeats the others. |
| `IOutboxHandler` | `Name` (stored with each delivery: keep it once deliveries exist), `Accepts(Kind)`, `Handle(Event)` (raise to fail this try). |
| `TOutboxOptions.Default` | `BatchSize` 50, `LeaseSeconds` 60, `MaxAttempts` 10, `Retry` 5 s doubling up to 600 s. |
| `TOutbox.Purge(Factory, Before)` | Deletes the events delivered before `Before` whose deliveries are all done or dead, with those deliveries. |
| `TOutbox.MeasurePending(Factory, Now)` | Sets the gauges below and returns the events not delivered yet (a query per call). |
| `PdbOutboxNewOwner(Prefix)` | `Prefix-` and 16 random hex digits: a lease owner for one running relay or sink. |
| `OnError` / `SetOnError` | A failed try: the event, the handler (`''` for the sink) and `ExceptionClass: message`. `TOutboxErrorProc` is `reference to` on Delphi and `of object` on FPC 3.2.2: pass a method. |

Times are Unix seconds, passed in: tests choose them, and the database never needs a clock
function of its own.

### Metrics and traces

In pascal-common-faa's `PcMetrics` (OpenTelemetry names): `outbox.events.delivered` and
`outbox.events.failed` by `outbox.event.kind` (the relay's), `outbox.handler.runs` by
`outbox.handler`, `outbox.event.kind` and `outbox.result` (`done`, `retried`, `dead`; the local
sink's), and the gauges `outbox.events.pending` and `outbox.events.oldest_age` (seconds) that
`MeasurePending` sets. The relay's span (`outbox <kind>`, producer) and each handler's
(`<handler> <kind>`, consumer) are children of the span that enqueued the event, through its
stored traceparent, so a request's trace goes on into the work it caused.

## Running it

```pascal
// The change and its event: one transaction.
LScope := LFactory.GetPool.AcquireQuery(LQuery);
LScope.StartTransaction;
try
  LQuery.Sql := LFactory.SqlLoader['ORDER.INSERT'].SQL;
  ...
  LQuery.ExecSql;
  TOutbox.Enqueue(LFactory, LQuery, LTenant, 'order.placed',
    Format('{"orderId":%d}', [LId]), DateTimeToUnix(Now, False));
  LScope.Commit;
except
  LScope.Rollback;
  raise;
end;
```

```pascal
// A worker: one relay and one local sink, each named once.
LSink := TOutboxLocalSink.Create(LFactory, PdbOutboxNewOwner('sink'), TOutboxOptions.Default);
LSink.AddHandler(TEmailHandler.Create);   // before the first event
LRelay := TOutboxRelay.Create(LFactory, LSink, PdbOutboxNewOwner('relay'), TOutboxOptions.Default);
while not Terminated do
begin
  LNow := DateTimeToUnix(Now, False);
  if (LRelay.RunOnce(LNow) = 0) and (LSink.RunOnce(LNow) = 0) then
    Sleep(1000);                           // nothing to do: wait a little
end;
```

Keep payloads thin (ids and a version, not the whole row): the handler reads the current
state, and a payload never goes stale. The tenant id is part of the key; a program without
tenants passes a constant.

## The tables and their SQL

The tables and the statements are **the application's**, read by name through the factory's
SQL loader (`OUTBOX_SQL_*` in the unit), as `TDbIdempotencyStore` does in pascal-api-infra-faa:
a schema, a column type or a claim can follow each database, and the library never writes DDL.
The reference SQL for every database the library supports is in [`docs/outbox/sql`](outbox/sql),
one file per name, in the layout of [`TFallbackSqlSource`](sql.md):

| Folder | For |
|---|---|
| `COMMON` | every database, unless its folder has the same name (PostgreSQL and SQLite take everything else from here) |
| `PG` | PostgreSQL: the claims, a CTE with `FOR UPDATE SKIP LOCKED` |
| `FB` | Firebird 2.5 and later: the schema (`UTF8` text columns; the payload `VARCHAR(8000)`, not a text `BLOB`, gotcha 59) and the claims (`UPDATE ... ORDER BY ... ROWS`) |
| `MYSQL` | MySQL 8 and MariaDB 10.6 or later: the schema, the claims (a derived table with `FOR UPDATE SKIP LOCKED`, `STRAIGHT_JOIN`ed to the table), the purge of deliveries (error 1093 refuses the common one) |
| `MSSQL` | SQL Server: the schema (`NVARCHAR`; the payload `NVARCHAR(4000)`, gotcha 58), the claims and the reads with `READPAST` |

Every file there runs in the integration suite on each database, with SQLdb, Zeos and (on
Delphi) FireDAC (`tests/Integration/PascalDb.OutboxTests.pas`), and sample 07 embeds the folder
unchanged. To use it: copy the files into your SQL folder (or your resources), run
`OUTBOX.SCHEMA` as a DDL migration (`IsDDL = True`, terminator `;`; see
[Migrations](migrations.md)), and point the factory's SQL source at the folder with
`TFallbackSqlSource.Create(..., 'COMMON')`, or merge the statements into your own directories.

| Name | Run by | Parameters | Returns |
|---|---|---|---|
| `OUTBOX.SCHEMA` | you, as a migration | | |
| `OUTBOX.INSERT` | `Enqueue` | `TENANT_ID`, `ID`, `KIND`, `PAYLOAD`, `CREATED_AT`; `TRACE_PARENT` inside a `[TRACE {] ... [} TRACE]` tag, kept only when there is a trace | |
| `OUTBOX.CLAIM` | the relay | `OWNER`, `LEASE_UNTIL`, `NOW`; the literal `${PAGE}` (the dialect's paging clause for `BatchSize` rows) | rows affected |
| `OUTBOX.CLAIMED` | the relay | `OWNER`, `LEASE_UNTIL` | `TENANT_ID`, `ID`, `KIND`, `PAYLOAD`, `TRACE_PARENT`, `CREATED_AT`, `ATTEMPTS`, in creation order |
| `OUTBOX.DELIVERED` | the relay | `TENANT_ID`, `ID`, `OWNER`, `NOW` | rows affected (0: the lease ran out and another relay has it) |
| `OUTBOX.FAILED` | the relay | `TENANT_ID`, `ID`, `OWNER`, `AVAILABLE_AT`, `LAST_ERROR` | |
| `OUTBOX.PENDING` | `MeasurePending` | | `PENDING` (a count), `OLDEST` (the oldest `CREATED_AT`) |
| `OUTBOX.PURGE_DELIVERIES` | `Purge` | `BEFORE`, `PENDING` (the status text) | |
| `OUTBOX.PURGE` | `Purge` | `BEFORE` | rows affected |
| `OUTBOX_DELIVERY.INSERT` | the local sink, in the relay's transaction | `TENANT_ID`, `EVENT_ID`, `HANDLER`, `STATUS`, `NOW` | |
| `OUTBOX_DELIVERY.CLAIM` | the local sink | `OWNER`, `LEASE_UNTIL`, `NOW`, `PENDING`; `${PAGE}` | rows affected |
| `OUTBOX_DELIVERY.CLAIMED` | the local sink | `OWNER`, `LEASE_UNTIL`, `PENDING` | `TENANT_ID`, `ID` (the event's), `HANDLER`, `ATTEMPTS`, `KIND`, `PAYLOAD`, `TRACE_PARENT`, `CREATED_AT` |
| `OUTBOX_DELIVERY.DONE` | the local sink | `STATUS`, `TENANT_ID`, `EVENT_ID`, `HANDLER`, `OWNER`, `NOW` | |
| `OUTBOX_DELIVERY.FAILED` | the local sink | as `DONE`, plus `ATTEMPTS`, `AVAILABLE_AT`, `LAST_ERROR` (`STATUS` is `pending` or `dead`) | |

The payload is a bounded text column on Firebird (`VARCHAR(8000)`) and SQL Server
(`NVARCHAR(4000)`): FireDAC failed to write some values into a Firebird text `BLOB` (gotcha 59),
and SQLdb read an `NVARCHAR(MAX)` back empty (gotcha 58). Keep payloads thin, or widen the column
where your driver handles it.

Sizes the unit relies on: `ID` 32 characters, `TRACE_PARENT` 55, `HANDLER` 60, `LAST_ERROR`
500 (`OUTBOX_MAX_ERROR_CHARS`: longer messages are cut). `KIND` (40) and `TENANT_ID` (40) are
yours to size. Rename the tables or columns freely: only the names of the statements, their
parameters and the columns they return are the contract.

## Per database

Each claim is one `UPDATE` that sets the lease on up to `BatchSize` free rows, oldest first,
and repeats the "free" test on the rows it changes, so a row another relay leased in between
is left alone. They differ in how a second relay meets rows the first one is claiming:

- **PostgreSQL, MySQL, MariaDB** skip them (`FOR UPDATE SKIP LOCKED`; MariaDB has it from
  10.6). The locking `SELECT` must run once and first: PostgreSQL's is a CTE, because inside
  `IN (...)` the planner re-ran it for each row and claimed more than the batch (gotcha 56);
  MySQL's is a derived table joined with `STRAIGHT_JOIN`, because joined the other way the
  `UPDATE` read the table first and waited for the locked rows (gotcha 57).
- **SQL Server** skips them with `READPAST`, on the claim and on the reads of the claimed rows
  and of the pending count: at its default isolation a plain `SELECT` waits for a row another
  transaction is writing, and an event an application has just written in a transaction still
  open is such a row.
- **Firebird** has no way to skip a locked row: the claim waits for it, and after the lock
  timeout (`IDatabaseConfig.LockTimeoutMs`) the pass fails with `ELockConflictException`
  ([errors](errors.md)), having claimed nothing; the next pass tries again. With one relay this
  doesn't happen. An event written in a transaction still open is invisible to the claim, which
  doesn't wait for it.
- **SQLite** has one writer at a time: the claim waits for the database's write lock (the
  adapters' busy timeout, 5 s by default), whether another relay or the application holds it,
  and fails the same way when it runs out.

Measured in the integration suite: a claim while another transaction holds one row locked
takes the others (PostgreSQL, MySQL, MariaDB, SQL Server) or gives up with
`ELockConflictException` (Firebird, SQLite), and a claim while an application's transaction has
an uncommitted event delivers the committed ones without waiting (every database but SQLite).
