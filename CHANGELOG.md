# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here.

## [Unreleased]

## [0.10.1] - 2026-10-05

### Changed

- Tests, CI and samples build against pascal-common-faa 1.2.0 (the `external/pascal-common-faa`
  submodule). The library's code is unchanged and still requires 1.0.0 or later: it uses nothing
  added after 1.0.0.

## [0.10.0] - 2026-10-05

### Fixed

- SQL templates: the closing marker now accepts optional spaces around the tag name (`[}TAG]`,
  `[}  TAG ]`), as the opening one already did, and the opening one also accepts spaces after
  `[`. Before, a closing marker without exactly one space wasn't recognized: `ProcessTag(TAG,
  False)` kept the block, or paired its opening with the next block's closing and deleted the
  SQL between them, and looped forever when that closing came before the opening. The cleanup
  done when `.SQL` is read follows the same rule (it left `[TAG{]` behind).

### Changed

- `ProcessTag` raises `ESQLLoaderException` on a malformed block of the tag: a closing marker
  with no opening before it, an opening with no closing after it, or a block nested in another
  block of the same tag. It used to leave markers in the SQL, remove the wrong text or hang.

## [0.9.0] - 2026-10-04

### Changed

- **Breaking:** the optional types, the atomics and ticks, the clock/sleep context and the cache
  moved to a new base library,
  [pascal-common-faa](https://github.com/fabianoallex/pascal-common-faa) (1.0.0 or later), shared
  with the other `*-faa` libraries; the application now provides it (see the README,
  "Dependency: pascal-common-faa"). Renames: `PascalDb.Optionals` → `PascalCommon.Optionals`,
  `PascalDb.SystemContext` → `PascalCommon.SystemContext`, `PascalDb.ClockCache` →
  `PascalCommon.ClockCache`, `PascalDb.Threading` → `PascalCommon.Threading`, `PdbAtomic*` /
  `PdbTickMs` / `PdbTickUs` → `PcAtomic*` / `PcTickMs` / `PcTickUs`; the type names
  (`IOptString`, `TOptionals`, `TClock`, `TTicker`...) are unchanged. The JSON bridge moved too:
  `PascalDb.JsonMapper.Optionals` → `PascalCommon.JsonMapper.Optionals`, package
  `pascal_db_faa_jsonmapper.lpk` → `pascal_common_faa_jsonmapper.lpk`. `pascal_db_faa.lpk`
  requires `pascal_common_faa`; on Delphi, add pascal-common-faa's `src` to the search path. An
  older pascal-common-faa stops the build with a message naming the version needed. Behavior
  differences that come with it: `TOptNullXxx.SafeNullable` / `SafeOptional` / `SafeOptNull`
  (deprecated) are gone, use `TOptionals.Safe`; the 64-bit atomics wrap around instead of
  raising `EIntOverflow` with overflow checks on. pascal-common-faa's
  [migration guide](https://github.com/fabianoallex/pascal-common-faa/blob/main/docs/migrating.md)
  has the full name map.
- The pascal-jsonmapper-faa submodule moves from `6306385` to
  [v0.2.0](https://github.com/fabianoallex/pascal-jsonmapper-faa/releases/tag/v0.2.0). For code
  using the mapper this adds `Serialize<T>` / `Deserialize<T>` (arrays and other types at the top
  level), indented output, `Naming := jnSnakeCase`, `RenameMember` and `UnknownMembers := umError`,
  all opt-in: the defaults behave as before, and so does the optionals bridge (same unit and
  sample results).

## [0.8.0] - 2026-10-02

### Added

- JSON for the optional types, through [pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa)
  (git submodule in `external/pascal-jsonmapper-faa`): `PascalDb.JsonMapper.Optionals`
  (`bridges/jsonmapper`, Lazarus package `pascal_db_faa_jsonmapper.lpk`) registers a converter
  for the 27 `IOptXxx`/`INullXxx`/`IOptNullXxx` interfaces on `TJsonMapper.Shared`. `null` into
  an `IOptXxx` raises `EJsonMapperError` with the JSON path, and a `nil` `INullXxx` is written
  as `null` (`delphi-api-infra-faa`'s `Common.JsonMapper` accepted the first and omitted the
  second). The core doesn't use the mapper. Unit tests `PascalDb.JsonMapperOptionalsTests`;
  the unit suite now needs the submodule (`git submodule update --init`).
- Sample `06-json` (`JsonApi`): POST / GET / PATCH between JSON and the database with the
  optional types, including the 400 answers; run and checked by `test_samples_docker.sh` on every
  database and adapter.

## [0.7.0] - 2026-10-02

### Added

- Batches (`PascalDb.Batch`): `TBatch.New(Query, Sql, MaxRows = 1000)` returns an `IBatch`; set a
  row's values through `Params` (every `IParams` setter, optionals included), `AddRow`, and
  `Execute`. Rows are sent `MaxRows` at a time. With FireDAC each send is one Array DML
  operation (measured, 10 000 INSERTs: PostgreSQL 6.1 s → 0.56 s, MySQL 26 s → 0.17 s,
  Firebird 2.5 local 0.63 s → 0.15 s); SQLdb and Zeos run one `ExecSql` per row on the prepared
  statement (Zeos's own batch DML failed: gotcha 44). Each row starts empty (a parameter not set
  in a row is NULL there), a parameter keeps one type, `Execute` with values and no `AddRow`
  raises. New interfaces `IBatch`, `IBatchRows` and `INativeBatchQuery` (optional on an adapter's
  query: `TDataSetQueryBase.SupportsNativeBatch`/`DoExecBatch`); the pool's query wrapper forwards
  it with the broken-connection handling and a new statement event kind, `skExecBatch`. Unit
  tests (`PascalDb.BatchTests`, two pool tests) and contract tests `Batch_EveryTypeAndNulls_RoundTrip`,
  `Batch_RejectedRow_RaisesAndRollbackDiscardsAll` and `Batch_LockWait_GivesUpAfterLockTimeout`.
- Samples: `Samples.CityRepository.FindByStatePaged` (a `COUNT` plus the page query with
  `PdbPagingClause`), shown page by page in sample 02 on every database and checked against the
  mock in sample 01; `tools/test_samples_docker.sh` checks the pages.

### Changed

- `TPdbParamType` is declared in `PascalDb.Interfaces` (batches use it);
  `PascalDb.Adapter.Base` keeps the name as an alias. Code that names its values (`pptString`,
  ...) through `PascalDb.Adapter.Base` alone must also use `PascalDb.Interfaces`.
- `TStatementKind` has a third value, `skExecBatch`: a `case` over it without an `else` must
  handle it.

## [0.6.0] - 2026-09-30

### Added

- Offset paging (`PascalDb.Paging`): `TPageRequest` (page and limit normalized: page below 1,
  missing limit, limit above a maximum), `TPageMeta` (`TotalPages`, `HasNext`, `HasPrev`),
  `TPage<T>`, `PdbDialectOf(Scope)` and `PdbPagingClause`, which writes the clause for the
  scope's database into a `${PAGE}` template literal: `LIMIT/OFFSET` on PostgreSQL, SQLite,
  MySQL and MariaDB, `ROWS m TO n` on Firebird (2.5 included), `OFFSET/FETCH` on SQL Server.
  The dialects implement the new `IPagingDialect`, a separate interface (as `IMigrationDialect`)
  so dialects registered by applications still compile. The total is a query the caller writes;
  the library doesn't parse SQL. Contract test `Paging_PagesCoverAllRowsInOrder`.
- `TMockDBFactory`'s scopes now have a connection and a dialect (`TMockSQLDialect`), so code
  calling `PdbPagingClause` runs against the mock; `TMockTransaction.GetConnection` and
  `TMockDBConnection.GetSQLDialect` no longer return `nil`.

## [0.5.1] - 2026-09-30

### Fixed

- Delphi on Windows: a MySQL/MariaDB client library given with forward slashes
  (`C:/libs/libmariadb.dll`) no longer hides the `plugin` folder next to it. Delphi's
  `ExtractFilePath` knows only the backslash on Windows, so `PdbMySQLPluginDir` looked for
  `C:plugin` and every connection to MySQL 8 failed with "Plugin caching_sha2_password could not
  be loaded" (FireDAC and Zeos, Win32 and Win64). `PdbPreloadClientLibrary` normalizes the path
  too. FPC was not affected.

## [0.5.0] - 2026-09-30

### Added

- SQL Server on SQLdb and Zeos, through Microsoft's ODBC Driver 18 (`ConnectorType=ODBC` on
  SQLdb, `Protocol=odbc_w` on Zeos): a `SQLServer` SQL dialect (also registered as `MSSQL`;
  savepoints with `SAVE TRANSACTION`, which can't be released: `SupportsRelease` is `False`);
  `LockTimeoutMs` applied as `SET LOCK_TIMEOUT` and errors 1222 / 1205 raised as
  `ELockConflictException`. SQLdb maps `HostName`/`Port`/`DatabaseName` to the ODBC connection
  string, loads the driver manager given by `ClientLibrary` (`libodbc.so.2` by default on Unix),
  opens ODBC connections one at a time (FPC 3.2.2's ODBC connector creates its shared environment
  on the first connect without a lock: concurrent connects failed with access violations) and
  applies the lock timeout outside SQLdb (a `SET` in a prepared statement doesn't stay on the
  session). Zeos adds `MARS_Connection=yes` to the connection string. FreeTDS (db-lib) is not
  supported: measured heap corruption with concurrent errors on SQLdb, no `DATETIME2` and lost
  milliseconds on Zeos. FireDAC isn't covered: its SQL Server driver isn't in Delphi's Community
  Edition. Contract suite run on SQL Server 2022 with FPC on Windows (Win64) and Linux and with
  Delphi on Zeos (Win32 and Win64), samples on Linux; CI runs the Linux side.
- Integration environment: `InsertReturningSql` replaces `SupportsReturning`, so the contract test
  `InsertReturning_ViaOpen` also covers `INSERT ... OUTPUT` on SQL Server.

## [0.4.1] - 2026-09-30

### Fixed

- Zeos on Firebird (Firebird 3+ client API, e.g. on Linux): connections opened at the same moment
  could corrupt memory (access violations, "Invalid index ... IMessageMetadata::getScale" from
  another connection) or hang inside the client library. The adapter now opens Firebird
  connections one at a time; queries and commits still run in parallel. Reproduced with 16
  threads connecting at once (hung within 73 rounds); with the fix, 4800 connections clean.

## [0.4.0] - 2026-09-29

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
  `LIBMYSQL_PLUGIN_DIR` for the process instead (when not set already). The samples run on
  MySQL and MariaDB too (`PASCALDB_SAMPLE_ENGINE=mysql` / `mariadb`).
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

[0.10.1]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/fabianoallex/pascal-db-faa/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/fabianoallex/pascal-db-faa/releases/tag/v0.1.0
