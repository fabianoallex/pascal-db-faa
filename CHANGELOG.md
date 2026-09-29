# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here.

## [Unreleased]

### Added

- MySQL and MariaDB on every adapter (SQLdb, Zeos, FireDAC): a `MySQL` SQL dialect (also registered as
  `MariaDB`); `LockTimeoutMs` applied as `innodb_lock_wait_timeout` (whole seconds) and errors
  1205 / 1213 raised as `ELockConflictException`. SQLdb registers the `MySQL 5.7` and
  `MySQL 8.0` connectors (use `MySQL 5.7` with MariaDB Connector/C) and takes a
  `SkipLibraryVersionCheck=true` setting, needed with a client library of another version than
  the connector's. `PdbMySQLPluginDir` (`PascalDb.Adapter.Base`): SQLdb and Zeos point the client
  at the `plugin` folder next to a client library given by full path, where MySQL 8's
  `caching_sha2_password` authentication lives. Contract suite run on MySQL 8.4 and MariaDB 11.4
  with FPC on Windows (Win64) and Linux, and with Delphi (FireDAC and Zeos, Win32 and Win64).
  FireDAC has no connection parameter for the plugin folder: it sets `MARIADB_PLUGIN_DIR` /
  `LIBMYSQL_PLUGIN_DIR` for the process instead (when not set already).
- `IDatabaseConfig.LockTimeoutMs`: the longest a statement waits for a lock held by another
  transaction, on every adapter (Firebird transaction parameters, whole seconds; PostgreSQL
  `lock_timeout`; SQLite busy timeout). 0 (default) keeps each database's behavior: Firebird
  and PostgreSQL wait until the lock is released. **Breaking** for a custom `IDatabaseConfig`
  implementation: the interface has two new methods.
- `ELockConflictException` (`PascalDb.Interfaces`): raised by `Open` / `ExecSql` instead of the
  driver's exception when another transaction stopped the statement: a lock wait longer than
  `LockTimeoutMs`, an immediate lock conflict (Zeos and FireDAC on Firebird don't wait), an update
  conflict or a deadlock (Firebird 5 reports an expired lock wait with the same codes as an
  update conflict). The driver's detail is in `OriginalClassName` / `OriginalMessage`. Adapters
  recognize their driver's errors by overriding `IsLockConflictError` (`TTransactionBase`,
  `TDataSetQueryBase`). **Breaking** for a program that caught the driver's exception for a
  deadlock or an update conflict: it now gets this class.
- Statement events: an optional `AOnStatement` handler (after `AOnPoolEvent` in every factory
  constructor and in `TConnectionPool.Create`) is called after each `Open` / `ExecSql` of a
  pooled query with a `TStatementInfo` (`PascalDb.Pool`): the SQL text, the time in
  microseconds, the rows an `Open` fetched, and the error, if any. Without a handler there is no
  cost. An exception in the handler is swallowed.
- `PdbTickUs` (`PascalDb.Threading`): monotonic microseconds (`QueryPerformanceCounter` on
  Windows, `CLOCK_MONOTONIC` on Linux FPC, `TStopwatch` on Delphi elsewhere). `PdbTickMs`
  (`GetTickCount64`) advances in 15-16 ms steps on Windows.

### Fixed

- SQLdb: settings with no value in `ConnectionParams` are no longer passed to the driver. FPC's
  `Values[Name] := ''` keeps a `Name=` line, and on PostgreSQL an empty `port=` made libpq read
  the next option of the connection string as the port.

## [0.3.0] - 2026-09-28

### Changed

- SQLdb: `ExecSql` keeps the statement prepared for the next run with the same SQL in the same
  transaction (SQLdb unprepared it after every run). 2000 INSERTs on PostgreSQL: 3.4 s -> 1.4 s.
- Setting `IQuery.Sql` to the text it already has keeps the parameters and the prepared
  statement and clears only the values (it used to rebuild both, so FireDAC and Zeos prepared
  the statement again). 2000 SELECTs with the SQL set inside the loop, Zeos: PostgreSQL
  2.2 s -> 1.1 s, Firebird 1.3 s -> 0.31 s. An adapter opts in with
  `TDataSetQueryBase.ResetParamValues`; without it, the old reset applies.
- SQLdb: queries no longer look the table's primary key up in the catalog on every `Open`
  (`UsePrimaryKeyAsKey := False`; the adapter never edits a dataset). 2000 SELECTs by key:
  PostgreSQL 10.0 s -> 3.5 s, Firebird 1.9 s -> 0.5 s.
- **Breaking:** when the pool can't open a new connection, `AcquireConnection` /
  `AcquireQuery` raise `EDatabaseConnectException` (new, a subclass of
  `EDatabaseUnavailableException`) instead of the driver's own exception, which was a different
  class for each adapter. The driver's class and text are in `OriginalClassName` /
  `OriginalMessage`; the `pdrConnectFailed` event's `ErrorMessage` still carries the driver's
  text. `IDBFactory.CreateConnection`, outside the pool, still raises the driver's exception.
- The pool hands out the most recently released idle connection (LIFO); it was FIFO. With
  FIFO, a light, steady load went round every open connection, none stayed idle for
  `PoolIdleTimeoutSeconds`, and a pool that grew in a peak never shrank back (3 connections
  and one request every 10 s: the 60 s sweep closed none; now it closes the 2 unused ones).
- Once a connection proves dead (drops in use, fails to connect, fails a ping), every idle
  connection gets the ping on its next acquire, however recently it was released. Before, after
  a server restart each idle connection released less than `PoolValidateIdleSeconds` ago was
  handed out unchecked and failed a request of its own.

### Added

- `PoolValidateIdleSeconds` (`IDatabaseConfig`; `ValidateIdleSeconds` on
  `IConnectionPoolConfig`): how long a connection must have been idle to get the ping before it
  is handed out. The default, 120, is the value that was fixed in the code; 0 pings on every
  acquire, a negative value never.
- `PoolKeepaliveSeconds` (`IDatabaseConfig`; `KeepaliveSeconds` on `IConnectionPoolConfig`),
  off by default: the pool's background thread pings idle connections not known to work for
  that long and closes the ones that fail. A ping resets the time `PoolValidateIdleSeconds`
  measures, not the one `PoolIdleTimeoutSeconds` does. `TConnectionPool.KeepaliveIdleConnections`
  runs one round on demand.
- `TTicker` (`PascalDb.SystemContext`): a replaceable monotonic clock, like `TClock` and
  `TSleep`, for tests that control the pool's idle times.

### Fixed

- Zeos on PostgreSQL and SQLite: every transaction opened a physical connection of its own (Zeos
  8 does that for each `TZTransaction` component on databases with one transaction per
  connection), so each request connected and disconnected, the pool's limit didn't bound the
  server connections, and its checks watched an idle connection. The adapter now uses the
  connection's own transaction. 2000 short requests on PostgreSQL: 103 s before, 5.4 s after.
- FireDAC on PostgreSQL: running the same query again with a longer string parameter failed
  with "Data too large for variable" (FireDAC keeps the command prepared, and the parameter kept
  the first value's size). The adapter now unprepares when a string parameter has to grow.
- The pool measures idle times on a monotonic clock. With the wall clock, a change of the
  system time (daylight saving, a manual adjustment) made every idle connection look that much
  older, sending them all to the liveness check and to the idle sweep at once.

## [0.2.0] - 2026-09-27

### Changed

- SQL dialect names are matched ignoring case (`'firebird'` finds `Firebird`).
- `TDBFactory.Create` resolves the SQL dialect and raises `EArgumentException` when it isn't
  registered or `SQLDialect` is empty; before, the error appeared only on the first acquire.
  The message lists the registered dialects.
- `TSQLDialectFactory.GetDialect` raises `EArgumentException` (was `Exception`), and
  `RegisterDialect` raises it for an empty name or a name already registered in any case.
- The adapters' error messages and headers no longer present their tested drivers as the only
  ones: Zeos passes any protocol, SQLdb any registered connector, FireDAC any linked driver
  (`VendorLib` still only for FB and PG; the message says how to set it for another driver).

### Added

- Guide 10, [using another database](docs/other-databases.md).

## [0.1.0] - 2026-09-27

First tagged version.

### Added

- Driver-agnostic contracts: `IDBFactory`, `IDBConnection`, `ITransaction`,
  `IScopeTransaction` (nested scopes as savepoints), `IQuery`, `IQueryResult`, `IParams`.
- Connection pool: ramp-up, limit, bounded waiting, idle sweep, discard of broken connections,
  events and a snapshot for metrics.
- Versioned migrations (`TDBMigrationEngine`).
- SQL by key in tagged templates, read from pluggable sources: embedded resources (default), a
  directory of `.sql` files, memory, or a composite. `tools/build_sql_res.py` builds the `.res`
  on any OS.
- Optional and nullable types (`IOptXxx`, `INullXxx`, `IOptNullXxx`) integrated with the
  parameters.
- `TMockDBFactory`: a mock for testing repositories without a database, including rewinding
  results on `Open` and simulated database errors (`AddFailure`).
- SQL dialects for Firebird, PostgreSQL and SQLite.
- Adapters: SQLdb (FPC), FireDAC (Delphi) and Zeos 8 (both compilers), each for Firebird,
  PostgreSQL and SQLite, validated by one shared contract suite.
- Usage guides (`docs/`) and five samples, each one source for both compilers.

### Tested on

Delphi 12 CE (Win32, Win64) and FPC 3.2.2 (Windows, Linux), 0 leaks on all of them. CI runs
the unit suite, the contract suite and the samples on Linux FPC for SQLdb and Zeos × Firebird
5, PostgreSQL 17 and SQLite; the Delphi side is run in the IDE. The full matrix is in the
README.

[0.3.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/fabianoallex/pascal-db-faa/releases/tag/v0.1.0
