# pascal-db-faa — Guide for AI agents

A **dual-compiler** (Delphi + Lazarus/FPC) database access layer: driver-agnostic contracts
(`IDBFactory`/`IQuery`/`IParams`), connection pool, migrations, tagged SQL templates,
optional/nullable types and a complete mock for tests. Connection drivers live outside the
core, in adapters.

For the general dual-compiler rules (project anatomy, `.inc`, mirrored tests, CI), use the
`dual-compiler-delphi-lazarus` skill. This file records only what is specific to this repo.

---

## Language

Everything in this repository is in **English**: code, identifiers, comments, runtime
messages (exceptions, logs), test names and assertion messages, documentation and commit
messages. Test *data* may contain non-ASCII values on purpose (e.g. `'São Paulo'`, to
exercise non-ASCII strings).

---

## Origin: extracted from delphi-api-infra-faa

The core came out of `delphi-api-infra-faa` (`src/Db/*` + its dependencies in `src/Common`),
at commit **`aa49f2b` (2026-08-25)**. The two repositories are **independent**: fixes made
there after that commit (especially in the pool, the most active area) **do not flow here
automatically**. If delphi-api-infra-faa starts consuming this library (an open decision),
that divergence goes away; until then, check `git log aa49f2b..HEAD -- src/Db
src/Common/Common.Optionals.pas` on that side before assuming both are in sync.

The other direction too: fixed here after the extraction, probably still present there
(not checked on that side):
- `TDataSetQueryBase.SetSql` losing the parameters when the same SQL text is assigned again
  on Zeos (gotcha 17).
- The pool's snapshot counters (`TotalTimeouts`, `TotalCreated`, `TotalDiscarded`,
  `TotalIdleSwept`) were incremented with a plain `Inc`, some outside the pool's lock, so
  concurrent events lost counts: sample 05 had 3 timeouts at the same moment and the snapshot
  said 2. They now use `PcAtomicInc64`/`PcAtomicAdd64` and are read with `PcAtomicRead64`.
- `TClock` and `TSleep` (then `PascalDb.SystemContext`, now in pascal-common-faa) created their
  default instance lazily on the first call; two threads making that first call together raced on the shared interface (one
  instance leaked, another was released twice: `EInvalidPointer`/`EAccessViolation` in pool
  workers). Measured on Linux FPC, `--cpus=1`, 4 runners at once, `--suite=TPoolTests` × 400:
  14 failures and 73 leaks before, 0 and 0 after. The defaults are now created in the unit's
  initialization (`5c853c6`).

| Here | There |
|---|---|
| `PascalDb.Interfaces` | `Db.Interfaces` |
| `PascalDb.Pool` | `Db.Connection.Pool` |
| `PascalDb.Migrations` | `Db.Migrations` |
| `PascalDb.SqlLoader` / `SqlDialect` / `Registry` / `Mock` | `Db.SqlLoader` / `Db.SqlDialect` / `Db.Adapters.Registry` / `Db.Mock` |
| `PascalCommon.SafeLog` (pascal-common-faa; was `PascalDb.SafeLog` until 0.11.0) | `Common.SafeLog` |
| `PascalCommon.Optionals` / `ClockCache` / `SystemContext` (pascal-common-faa) | `Common.*` with the same name |
| `PascalCommon.Threading` (pascal-common-faa) | — (new: portable atomics + tick) |

The origin is in Portuguese (comments, messages, some test names); this repository was
translated to English after the extraction, so identifiers and messages differ where they
were Portuguese there.

The `PascalDb.*` prefix is mandatory: `Db.*` would collide with FPC's `db` unit (the base of
SQLdb) and with delphi-api-infra-faa's own units if both libraries were on the same search
path.

---

## Code rules (apply to every unit in `src/`)

- **Every unit includes `{$I pascaldb.inc}` right after `unit ...;`.** The `.inc` turns on
  `{$MODE DELPHI}{$H+}` on FPC and normalizes `PASCALDB_WINDOWS`.
- **`uses` without namespaces** (`SysUtils`, `Generics.Collections`), never
  `System.SysUtils`. Delphi resolves them through the project's `DCC_Namespace`; FPC 3.2.2
  doesn't have the dotted units. A Delphi-only unit goes inside `{$IFNDEF FPC}` with its full
  name (`Winapi.Windows`).
- **No anonymous methods** (`TThread.CreateAnonymousThread`, closures in
  `TEqualityComparer.Construct`, etc.): stable FPC 3.2.2 doesn't have them. Use a `TThread`
  subclass or a named function/method.
- **Public callbacks follow `PASCALDB_FUNCREFS`** (see `pascaldb.inc`): the type is
  `reference to` in Delphi and `of object` in FPC. The portable subset is "pass a method": it
  compiles on both. Delphi-only users can still pass a closure. Real examples:
  `TPoolEventProc`, `TMigrationEventProc`.
- **Atomics and monotonic time only through `PascalCommon.Threading`** (`PcAtomicInc`,
  `PcAtomicInc64`, `PcAtomicRead64`, `PcTickMs`, `PcTickUs`). `TInterlocked` and `TStopwatch`
  don't exist in FPC.
- **Never `TDictionary.Create(AComparer)` with a possibly-`nil` `AComparer`** (see gotcha 1
  in docs/gotchas.md).
- **Top-of-file comment in every unit, program and test**, between `unit X;` (+ `{$I
  pascaldb.inc}`) and `interface`/`uses`:

  ```pascal
  { One sentence: what the unit is.

    Paragraphs: why it exists, decisions, relevant Delphi × FPC gotchas. }
  ```

  Plain prose, no banners (`****`, `----`) and no upper-case headings. If the text needs to
  quote something containing `}` (the SQL tag syntax, a `{$DIRECTIVE}`), use `(* ... *)`: a
  `}` inside `{ }` closes the comment early. In tests, the header says what the unit covers
  and ends with the master/mirror note; the FPCUnit mirror gets the "generated file" note on
  top, added by the generator.

---

## SQL sources

`TSQLLoader` (`PascalDb.SqlLoader`) asks an `ISqlSource` (`PascalDb.SqlSources`) for the
text of `<DIRECTORY>/<NAME>`, caches it per loader and hands it to `TSQLResult` for tag
processing. `TSQLLoader.Create(Dir)` without a source uses `TResourceSqlSource`.

| Source | Reads | Use |
|---|---|---|
| `TResourceSqlSource` | RCDATA resource `SQL_<DIR>_<NAME>` (dots → `_`, upper case) | default: one executable, SQL can't drift or be edited in production |
| `TDirectorySqlSource` | `<Root>/<Dir>/<Name>.sql` (also a lower-case `<dir>` folder); relative root = executable's folder | development, local overrides |
| `TMemorySqlSource` | SQL registered in code | tests |
| `TCompositeSqlSource` | several sources, first hit wins | e.g. directory, then resources |

**Building the `.res`: `python tools/build_sql_res.py sql/ sql/app.res`**, then
`{$R 'sql\app.res'}` in the program (both compilers). It walks `sql/<DIR>/*.sql`, uses the
same naming rule as `TResourceSqlSource.ResourceName`, refuses name collisions
(`X.Y.sql` vs `X_Y.sql`) and has `--check` for CI. Its output is byte-for-byte what `windres`
produces for the equivalent `.rc`. Why not a `.rc`: FPC on Windows compiles one fine (it
calls the `windres` shipped with Lazarus), but **FPC on Linux needs a MinGW C toolchain**
just to preprocess it (tested: "resource compiler "windres" not found"; installing
`binutils-mingw-w64` isn't enough, it wants `x86_64-w64-mingw32-gcc`). A prebuilt `.res`
links fine on Linux. The test suite follows the pattern it recommends: the `.res` is
versioned (`.gitignore` exception) and regenerated/checked by the test scripts.

The text is returned as stored (original line endings, no trailing line break added); a
leading UTF-8 BOM is dropped.

**Paging** (`PascalDb.Paging`): the dialect writes the clause (`IPagingDialect`, separate from
`ISQLDialect` so applications' own dialects still compile), and the SQL places it with a
`${PAGE}` literal (`ReplaceLiteral('PAGE', PdbPagingClause(LScope, APage))`). Deliberately no
SQL parsing: the caller writes the `COUNT` query, and the library never wraps or rewrites a
statement (a derived table with `ORDER BY` is an error on SQL Server). Limit and offset go in
as integer literals. Firebird uses `ROWS m TO n` because `OFFSET/FETCH` needs 3.0.

---

## pascal-common-faa (base library)

The optional types (`PascalCommon.Optionals`), the atomics and ticks (`PascalCommon.Threading`),
`TClock`/`TTicker`/`TSleep` (`PascalCommon.SystemContext`) and `TClockCache`
(`PascalCommon.ClockCache`) come from [pascal-common-faa](https://github.com/fabianoallex/pascal-common-faa),
shared with pascal-named-pipes-faa, pascal-amqp-faa and pascal-redis-faa. They lived here as
`PascalDb.Optionals`, `PascalDb.Threading` (`Pdb*` functions), `PascalDb.SystemContext` and
`PascalDb.ClockCache` until 0.8.0; their tests (`OptionalsTests`, `ClockCacheTests`) went with
them. Moved in the pilot migration (pascal-common-faa's plan, phase F6, 2026-10-04).

- **A git submodule in `external/pascal-common-faa`, for tests, CI and samples only.** The
  application provides the single copy (several `*-faa` libraries may depend on it):
  `pascal_db_faa.lpk` requires `pascal_common_faa` **by name, with no `DefaultFilename`**, and the
  test and sample `.lpi` files point at the submodule's `.lpk` with `Prefer="True"`, listed
  first. The Delphi projects add `external/pascal-common-faa/src` to the search path.
- **This library's own version** is in `PascalDb.Version` (`PASCALDB_VERSION`, same `MMmmpp`
  format; consumers test it with that unit in their `uses`). A release bumps it together with the
  `.lpk` files, the README and the CHANGELOG.
- **Minimum version** checked in `PascalDb.Interfaces` (every user compiles it):
  `PASCALCOMMON_VERSION < 10300` stops the build with "pascal-db-faa needs pascal-common-faa 1.3.0
  or later" (measured by raising the bound: lazbuild "Fatal: (2022) User defined: ...", Delphi 12
  "F1054 ..."). 1.3.0 is the first with `PascalCommon.SafeLog` (only additions within 1.x);
  `pascal_db_faa.lpk` has `MinVersion Major="1" Minor="3"`. Raise both when the library starts using something newer.
- **Checkout without `--recursive`**: pascal-common-faa's own `external/pascal-jsonmapper-faa` is
  for its own tests. CI uses `submodules: true` (not recursive).
- Something the library needs changed there goes to pascal-common-faa first (strict semver,
  additive within a major version), never patched in the submodule.

## JSON bridge (pascal-jsonmapper-faa)

The `IJsonConverter` for the 27 optional interfaces is pascal-common-faa's
`PascalCommon.JsonMapper.Optionals` (package `pascal_common_faa_jsonmapper.lpk`; it was
`PascalDb.JsonMapper.Optionals` / `pascal_db_faa_jsonmapper.lpk` here until 0.8.0, and its tests
went with it). Only sample 06 uses it. The mapper stays a **git submodule** here
(`external/pascal-jsonmapper-faa`), and the bridge is built against **this** copy, not
pascal-common-faa's (which isn't checked out): `JsonApi.lpi` requires `pascaljsonmapper_pkg`
from `external/pascal-jsonmapper-faa` with `Prefer="True"` before the bridge package (the
bridge `.lpk` requires the mapper by name only, since pascal-common-faa 1.0.0). Measured with
lazbuild in the pilot: without that item, Lazarus silently takes whatever `pascaljsonmapper_pkg`
the IDE has registered (here, a separate `../pascal-jsonmapper-faa` checkout). `JsonApi.dproj` has the
mapper's `src` and `external/pascal-common-faa/bridges/jsonmapper` on its search path;
`test_samples_docker.sh` passes the same folders to `fpc`.

The JSON decisions (2026-10-02, now pinned by pascal-common-faa's
`PascalCommon.JsonMapperOptionalsTests`): `null` into an `IOptXxx` raises; a `nil` `INullXxx` is
written as `null`; an `IOptXxx` holding Null writes `null`; GUIDs go out with braces and are read
with or without; `DecimalPlaces` isn't in the JSON.

---

## Runtime requirements for FPC applications

Two things an FPC program using this library must do, or non-ASCII text silently becomes
`?` (confirmed on FPC 3.2.2; Delphi needs neither — its `string` is UTF-16):

- **Run with a UTF-8 default code page.** In `{$MODE DELPHI}`, `string` is an AnsiString in
  the process's default code page (measured: 1252 in a plain FPC console program on
  Windows). LCL applications already run in UTF-8 (measured: `DefaultSystemCodePage` = 65001
  even before `Application.Initialize`); console/service programs call
  `SetMultiByteConversionCodePage(CP_UTF8)` at startup. `PdbUtf8BytesToString` (used by the
  file and resource sources) raises `ESqlSourceException` instead of corrupting a non-ASCII
  SQL when the code page isn't UTF-8.
- **On Unix, include `cwstring` (with `cthreads`) in the program's `uses`.** Without it, a
  `Variant` holding a WideString (`varOleStr` — e.g. a non-ASCII literal passed in an
  `array of Variant`) converts back to `string` one byte per character (Latin-1), ignoring
  the UTF-8 code page: `'São'` (`53 C3 A3 6F`) comes back as `53 E3 6F`, invalid UTF-8.
  Measured in isolation on FPC 3.2.2/Linux: a `string` variable stored in a `Variant`
  (`varString`) and a direct `string` ↔ `WideString` assignment were **not** affected.
  Found through the `TMockQueryResult` tests.

The FPCUnit runner does both.

---

## Tests

- The masters are the **DUnitX** files in `tests/Unit/*Tests.pas`, written in **FPCUnit's
  assertion dialect** (`TAssert.AssertEquals/AssertTrue/AssertFalse/Fail`). On Delphi that is
  provided by `tests/Unit/PascalDb.DUnitXCompat.pas`.
- **`tests/Unit/fpc/*Tests.pas` are generated**: `python tools/gen_fpc_mirror.py`. Never edit
  those files by hand. The generator swaps only the fixture declarations and the
  registration; the body comes out byte-for-byte identical. `--check` fails if any mirror is
  out of date.
- **Run on FPC:** `sh tools/test_fpc.sh` (regenerates the mirrors and the test `.res`,
  builds with `lazbuild` and runs). **On Linux:** `sh tools/test_fpc_docker.sh` (builds and
  runs inside a container with FPC 3.2.2; `FPC_IMAGE` selects the image).
- **Integration (contract) tests** — `tests/Integration/PascalDb.ContractTests.pas` only uses
  `IDBFactory`/`IQuery`/`IParams`/`IQueryResult`, so the same bodies validate every adapter;
  `tests/Integration/PascalDb.IntegrationEnv.pas` is the only adapter-specific part (which
  factory, how to create/drop the database) and documents its `PASCALDB_IT_*` environment
  variables. `PASCALDB_IT_ENGINE` picks the database: `firebird` (default), `postgresql`,
  `sqlite` (a file next to the runner; no server), `mysql`, `mariadb` or `sqlserver` (SQLdb and
  Zeos runners only).
  Each run creates a fresh database, migrates it with `TDBMigrationEngine` (SQL from a
  `TMemorySqlSource`) and drops it at the end. FPC on Windows: build
  `tests/Integration/fpc/PascalDbIntegrationTestsFpc.lpi` (SQLdb) or
  `tests/Integration/fpc-zeos/PascalDbIntegrationTestsZeosFpc.lpi` (Zeos) and run it with
  `--all --format=plain`. The Zeos runners (FPC and Delphi) define `PASCALDB_IT_ZEOS` and
  reuse the same fixtures. Linux: `sh tools/test_integration_docker.sh` (`ENGINE=firebird`,
  `postgresql`, `sqlite`, `mysql`, `mariadb` or `sqlserver`; `ADAPTER=sqldb` (default) or `zeos`, the latter with `ZEOSDBO` pointing at the
  ZeosLib folder, mounted into the container; server container + FPC container on a private
  network). **CI:** `.github/workflows/ci.yml` only calls `sh tools/ci-test.sh`, which runs the
  unit suite, then all twelve Linux integration combinations (SQLdb/Zeos ×
  Firebird/PostgreSQL/SQLite/MySQL/MariaDB/SQL Server) and the samples on the same twelve
  (`tools/test_samples_docker.sh`); for SQL Server the FPC container installs Microsoft's
  `msodbcsql18` and `mssql-tools18` from Microsoft's Debian 12 repository (`ACCEPT_EULA=Y`: that
  accepts Microsoft's license, as running the server image does);
  it builds its FPC image (`pascaldb-fpc322`, Debian bookworm's fpc) and, without `ZEOSDBO`,
  downloads ZeosLib 8.0.0 into `.ci/` and checks its pinned SHA-256. Run it locally before
  pushing a change to the scripts.
- **PostgreSQL server for Windows runs:** `docker run -d --name pascaldb-it-pg -p 55432:5432
  -e POSTGRES_PASSWORD=postgres postgres:17`, then run with `PASCALDB_IT_ENGINE=postgresql`
  and `PASCALDB_IT_PORT=55432` (user/password default to postgres/postgres). The client is
  the 64-bit `libpq.dll` of a local PostgreSQL install (found under
  `C:\Program Files\PostgreSQL`, or `PASCALDB_IT_CLIENT`); PostgreSQL ships no 32-bit Windows
  client, so the Delphi runners must be built for **Win64** to test PostgreSQL.
- **SQLite on Windows:** `PASCALDB_IT_ENGINE=sqlite`. SQLdb and Zeos load `sqlite3.dll`
  (`PASCALDB_IT_CLIENT`, or the default search), and it must be one with the column-metadata
  functions — the official build from sqlite.org has them, Python's doesn't (see gotcha 23).
  Local copies of sqlite.org's 3.53.4 DLL live in `.deps/sqlite-3.53.4/{x86,x64}/sqlite3.dll`
  (git-ignored; SHA-256 x86 `1c2fcfa7...2eb9f`, x64 `ab57d043...cd1ec`): point
  `PASCALDB_IT_CLIENT` at the one matching the runner's bitness. Without it, a Win32 runner may
  pick up the old `sqlite3.dll` in Delphi's own `bin` folder (no `RETURNING`: 3 contract tests
  fail) and a Win64 one finds none.
  FireDAC links SQLite into the program and needs no DLL. **On Delphi:** open
  `PascalDb.groupproj` in the IDE and run
  `tests/Unit/PascalDb.UnitTests.dproj`, `tests/Integration/PascalDb.IntegrationTests.dproj`
  (FireDAC) and `tests/Integration/PascalDb.IntegrationTestsZeos.dproj` (Zeos; needs
  `ZEOSDBO`). Delphi Community Edition doesn't compile from the
  command line: `dcc32` prints "This version of the product does not support command line
  compiling." and **exits with code 0**. Don't read that as success.
- **Acceptance criterion:** every test green **and 0 leaks on both sides** (heaptrc on FPC,
  `ReportMemoryLeaksOnShutdown` on Delphi).
- Floating point **always with an explicit delta** (`AssertEquals(E, A, 0)` for exact). See
  gotcha 5.
- `python ../skills/dual-compiler-delphi-lazarus/scripts/verify_test_mirrors.py --root .
  --ignore-glob /lib/` is a second check, independent of the generator.

---

## Adapters

The core knows no driver. Everything that isn't driver-specific lives in the core, so an
adapter only wraps its driver's connection, transaction and query (500-600 lines each, most of
them the driver's quirks):

- `PascalDb.Adapter.Base` (no Data.DB): `TDatabaseConfig`, `TTransactionBase` (routes every
  native failure through `BuildDatabaseException`), `TScopeTransaction` (savepoints for nested
  scopes), `TSqlScript`, `TParamsBase` (the whole `IOptXxx`/`INullXxx`/`IOptNullXxx` semantics
  over a few primitives; a NULL gets the value's type) and `TDBFactory` (pool + SQL loader +
  provider; `TestConnection` runs the dialect's `GetPingSQL`, so it works on any driver).
- `PascalDb.Adapter.DataSet` (Data.DB / db): `TDBParams` over a Data.DB `TParams` (SQLdb) and
  `TDataSetQueryBase` over the driver's query dataset. Non-nullable getters use `TField`
  semantics (NULL reads as `''`/`0`/`False`); booleans convert through Variant, so a Firebird
  2.5 SMALLINT flag reads as a Boolean.
- `TTransactionBase.ExecSql` and `TDataSetQueryBase.Open`/`ExecSql` turn the driver's lock
  conflict errors (expired lock wait, immediate lock conflict, update conflict, deadlock) into
  `ELockConflictException` through the adapter's `IsLockConflictError` override; each adapter
  applies `IDatabaseConfig.LockTimeoutMs` its own way (gotcha 32).
- Constraint violations become `EConstraintViolationException` (`Kind`: `cvUnique`, `cvForeignKey`,
  `cvNotNull`, `cvCheck`) at the same points, through the adapter's `IsConstraintViolationError`
  override (checked after `IsLockConflictError`; also on `Commit`, for deferred constraints). The
  codes of each database are in `PascalDb.Adapter.Base` (`PdbFirebirdConstraintKind`, ...),
  shared by the three adapters; all measured with the contract suite (`Constraint_*` tests).
- `IQuery.ExecSql` / `ITransaction.ExecSql` return the rows affected: `TDataSetQueryBase.RowsAffected`
  and `TTransactionBase.DoExecSqlRows` overrides (-1 by default). An `UPDATE` counts matched rows
  on every database, MySQL/MariaDB included (gotcha 46).
- Statement events (`AOnStatement`, `TStatementInfo` in `PascalDb.Pool`) are raised by the
  pool's `TQueryWrapper`, the one place every pooled `Open`/`ExecSql` goes through, so adapters
  need nothing for them. Timed with `PcTickUs`: `PcTickMs` (`GetTickCount64`) moves in 15-16 ms
  steps on Windows (measured). No parameter values on purpose (secrets in logs; `IParams` can't
  list them).
- Batches (`PascalDb.Batch`, `TBatch.New(Query, Sql, MaxRows)`): the rows are buffered with one
  type per parameter and sent `MaxRows` at a time, through `INativeBatchQuery` when the adapter's
  query says `SupportsNativeBatch` (FireDAC's Array DML), otherwise one `ExecSql` per row (SQLdb,
  Zeos: gotcha 44). The pool's `TQueryWrapper` forwards it (`skExecBatch` event, broken-connection
  handling). Probe that justified it: `.ci/probe-batch` (git-ignored).

| Adapter | Compiler | Package / unit | Status |
|---|---|---|---|
| SQLdb | FPC only | `pascal_db_faa_sqldb.lpk` / `adapters/sqldb` | done: contract suite green on Firebird 2.5 (Windows), Firebird 5 (Linux), PostgreSQL 17 (Windows and Linux), SQLite (Windows with sqlite.org's 3.53.4 DLL, Linux with Debian bookworm's libsqlite3), MySQL 8.4 and MariaDB 11.4 (`MySQL 5.7` connector; Windows with MariaDB Connector/C 3.4.11, Linux with Debian bookworm's libmariadb3), SQL Server 2022 (`ODBC` connector, Microsoft's ODBC Driver 18: 18.5 on Windows Win64, 18.7 on Linux) |
| FireDAC | Delphi only | `adapters/firedac` | done: contract suite green on Firebird 2.5 (Delphi 12 CE, Win32 and Win64), PostgreSQL 17 (Win64) and SQLite (Win32 and Win64, engine linked in), MySQL 8.4 and MariaDB 11.4 (Win32 and Win64, MariaDB Connector/C 3.4.11); no SQL Server (gotcha 42) — `tests/Integration/PascalDb.IntegrationTests.dproj` |
| Zeos | dual | `pascal_db_faa_zeos.lpk` / `adapters/zeos` | done: contract suite green on Firebird 2.5 with FPC (Win64) and Delphi 12 CE (Win32 and Win64), PostgreSQL 17 with FPC and Delphi (Win64), Firebird 5 and PostgreSQL 17 with FPC on Linux, SQLite with FPC on Windows and Linux and Delphi (Win32 and Win64), MySQL 8.4 and MariaDB 11.4 with FPC on Windows (Win64) and Linux and Delphi (Win32 and Win64) (MariaDB Connector/C), SQL Server 2022 with FPC on Windows (Win64) and Linux and Delphi (Win32 and Win64) (`odbc_w`, Microsoft's ODBC Driver 18.5 / 18.7) — `tests/Integration/fpc-zeos`, `tests/Integration/PascalDb.IntegrationTestsZeos.dproj` |

A third-party adapter implements `IDBComponentProvider` (usually on top of the two units
above), and `TDBFactory` does the rest: the core never has to change for a new driver.

**Client library by full path (Windows):** an adapter given the full path of a client library
calls `PdbPreloadClientLibrary` (in `PascalDb.Adapter.Base`) before the driver loads it: the
library is loaded with `LOAD_WITH_ALTERED_SEARCH_PATH`, so its own dependencies are found in
its folder (see gotcha 14). SQLdb and FireDAC use it; Zeos already loads that way by itself.

**FireDAC specifics:** `ConnectionParams` is a FireDAC connection definition (`DriverID=FB`,
`Database`, `User_Name`, `Password`, `CharacterSet`, ...). `VendorLib` is taken out of it and
applied to the driver link once per process (`PdbFireDACUseVendorLib`); a Win32 program needs
the 32-bit client (WOW64 folder of a 64-bit Firebird 2.5). The adapter uses the FireDAC
runtime units (`Stan.Def`, `Stan.Async`, `DApt`, FB/PG drivers) and runs connections with
`SilentMode`, so consumers don't need them for the adapter to work; queries use
`FetchOptions.Mode = fmAll`.

**Use `IDatabaseConfig` through an interface variable** (`LConfig: IDatabaseConfig :=
TDatabaseConfig.Create`): the properties are declared on the interface, and mixing a class
variable with a reference-counted interface frees the object too early.

**SQLdb specifics:** set `ConnectorType` (`Firebird`/`PostgreSQL`) in `ConnectionParams`, and
`ClientLibrary` when fbclient/libpq isn't on the default path. SQLdb loads a client library
once per process and **the first load wins**: a `TIBConnection` used directly before the
factory's first connection loads the default library, and the configured one then fails with
"interface already initialized from library ...". Call `PdbSQLdbUseClientLibrary` before any
direct SQLdb connection (the integration environment does). `TSQLTransaction.Commit`/`Rollback` close the datasets attached to it:
read results before committing. Results are fetched completely on `Open`
(`PacketRecords = -1`), so `RecordCount` is exact. Queries set `UsePrimaryKeyAsKey := False`:
by default SQLdb queries the catalog for the table's primary key on every `Open`, to make the
dataset editable, and the adapter never edits it (2000 SELECTs by key, FPC 3.2.2 Windows:
PostgreSQL 10.0 s → 3.5 s, Firebird 1.9 s → 0.5 s). `ExecSql` prepares explicitly and keeps the statement
prepared while the same transaction lasts (gotcha 31); `Open` leaves preparing to SQLdb. On
PostgreSQL a failed `COMMIT` leaves the `TSQLTransaction` with a dead handle; `DoCommit` ends it
with `ForcedClose` (gotcha 47).

**Zeos specifics** (ZeosLib 8): `ConnectionParams` takes `Protocol` (`firebird`/`postgresql`;
`firebird` falls back to the legacy API with a 2.5 client), `HostName`, `Port`, `Database`,
`User`, `Password`, `ClientCodepage`, `LibraryLocation`; any other line goes to
`TZConnection.Properties`. Zeos 8 queries use its own `TZParams` (not Data.DB's `TParams`),
so the adapter has its own `TParamsBase` over them; `TZParam.AsString` is Unicode on Delphi,
so the FireDAC ANSI problem doesn't apply. An `ITransaction` is the `TZConnection`'s own
transaction, **never a `TZTransaction` component**: on PostgreSQL, SQLite and the other
one-transaction-per-connection databases, Zeos 8 opens a physical connection for each
`TZTransaction` (gotcha 30). `TZConnection.StartTransaction` with a transaction already open
creates a **savepoint** instead, and the matching `Commit` only releases it — so every
statement the adapter runs starts the `ITransaction` first, and releasing a connection to the
pool rolls back whatever was left open. Queries call `FetchAll` after opening, so
`RecordCount` is exact and commits are hard commits (with rows pending, Zeos uses commit
retaining). Firebird connections get `hard_commit=true` unless `ConnectionParams` sets it
(see gotcha 16). Zeos can create a Firebird database (`CreateNewDatabase=true`) but has no
call to drop one: `PdbZeosDropFirebirdDatabase` connects with `FirebirdAPI=legacy` and calls
the client's `isc_drop_database` on Zeos's handle, which works on a remote server too (checked
on Linux against a Firebird 5 container: the `.fdb` is gone after the run). The legacy API
because `isc_drop_database` zeroes the handle and Zeos's `Disconnect` then skips the detach;
the Firebird 3+ API's `IAttachment.dropDatabase` would free the attachment Zeos still holds.

**SQLite specifics:** the core registers a `SQLite` dialect (savepoints; the migrations table
is looked up in `sqlite_master`). Connection settings: SQLdb `ConnectorType=SQLite3`, Zeos
`Protocol=sqlite`, FireDAC `DriverID=SQLite`; the database is a file, created on the first
connect. What the adapters add, all measured on FPC (SQLdb, Zeos) unless noted:
- a busy timeout on every connection (SQLdb `PRAGMA busy_timeout`, `BusyTimeout` setting;
  Zeos `busytimeout`; both 5000 ms by default): SQLite has one writer at a time, and without it
  a second writer fails at once with "database is locked" (gotcha 24). FireDAC has its own
  `BusyTimeout` setting;
- SQLdb retries a statement once on `SQLITE_SCHEMA` (gotcha 21);
- Zeos sends a `Currency` parameter as a `Double` (gotcha 22);
- FireDAC (Delphi 12 CE): `FireDAC.Phys.SQLite` + `FireDAC.Phys.SQLiteWrapper.Stat` (the engine
  is linked in, no `VendorLib`), and, unless the settings say otherwise, `LockingMode=Normal`,
  `SharedCache=False`, `StringFormat=Unicode`, `BusyTimeout=5000` and
  `UpdateOptions.LockWait = True` (gotcha 25).
- foreign keys turned on (SQLdb and Zeos `foreign_keys=ON`, FireDAC `ForeignKeys=On`) unless the
  settings say otherwise: SQLite doesn't check them by default (gotcha 45).
SQLite's types are loose: a `NUMERIC(15,2)` is stored as `REAL`, so money keeps a `Double`'s
precision, not an exact decimal. `CREATE TABLE IF NOT EXISTS`, `RETURNING` and transactional
DDL all work (the contract suite passes unchanged). `:memory:` gives each pooled connection its
own empty database: use a file.

**MySQL/MariaDB specifics:** one dialect class, registered
as `MySQL` and `MariaDB`. SQLdb `ConnectorType=MySQL 5.7` (the adapter also registers
`MySQL 8.0`, for Oracle's 8.0 client only: gotcha 35), Zeos `Protocol=mysql` or `mariadb`,
FireDAC `DriverID=MySQL` (`FireDAC.Phys.MySQL`, in the Community Edition too);
character set `utf8mb4`. Measured with MariaDB Connector/C for both servers: Debian bookworm's
`libmariadb3` (3.3.19) on Linux, 3.4.11 on Windows (`.deps/mariadb-connector-c-3.4.11/{x64,x86}`,
git-ignored, extracted from the signed MSIs in `msi/` with `msiexec /a`; SHA-256 x64
`3faa123d...a71c8`, x86 `603a09c1...55ae2`). Windows runs: `docker run -d --name
pascaldb-it-mysql -p 33306:3306 -e MYSQL_ROOT_PASSWORD=root mysql:8.4` (MariaDB:
`pascaldb-it-mariadb`, 33307, `MARIADB_ROOT_PASSWORD`), then `PASCALDB_IT_ENGINE=mysql`,
`PASCALDB_IT_PORT=33306`, `PASCALDB_IT_CLIENT=<the x64 libmariadb.dll>`. No Oracle
`libmysqlclient` measured. What the adapters add:
- `LockTimeoutMs` as `SET SESSION innodb_lock_wait_timeout` (whole seconds, rounded up) when a
  connection opens (both connectors use one server session per connection), and errors 1205 /
  1213 as `ELockConflictException`. An expired lock wait undoes only the statement;
- SQLdb: `SkipLibraryVersionCheck=true`, needed with any client whose version isn't the
  connector's (gotcha 34);
- `MYSQL_PLUGIN_DIR` defaults to the `plugin` folder next to a client library given by full
  path (`PdbMySQLPluginDir`): MySQL 8.4's default authentication, `caching_sha2_password`, is a
  client plugin, and MariaDB Connector/C copied out of its install folder didn't find it ("Plugin
  caching_sha2_password could not be loaded", every connection to MySQL, SQLdb and Zeos on
  Windows; MariaDB servers don't use it). Debian's package finds its own plugins. FireDAC has
  no parameter for it, so `PdbFireDACUseVendorLib` sets the process's `MARIADB_PLUGIN_DIR` and
  `LIBMYSQL_PLUGIN_DIR` before the library loads (unless set): measured first with an FPC probe
  (the library sees a variable the process set itself; without it, "Server connect failed"),
  then with the Delphi FireDAC runners on MySQL 8.4, Win32 and Win64.
MySQL has no `INSERT ... RETURNING` (MariaDB has): the contract test `InsertReturning_ViaOpen`
exits early on `ENGINE=mysql` (`SupportsReturning` in the integration environment), and the
optional-column tests read the row back with a `SELECT` on every database. DDL commits
implicitly, as on Firebird (the migrations' `IsDDL` mode already handles it). Table names are
case-sensitive on Linux servers: the dialect looks the migrations table up with `LOWER(...)` in
`information_schema` and always writes `SCHEMA_MIGRATIONS`. The SQLdb connector replaces
parameters in the SQL text on the client (no server-side prepared statements).

**SQL Server specifics:** one dialect class, registered as `SQLServer` and `MSSQL` (savepoints with
`SAVE TRANSACTION` / `ROLLBACK TRANSACTION`, no release: `SupportsRelease = False`; the
migrations table found with `OBJECT_ID`). Both adapters go through **ODBC with Microsoft's ODBC
Driver 18**: SQLdb `ConnectorType=ODBC` (+ `Driver=ODBC Driver 18 for SQL Server`; the adapter
turns `HostName`/`Port`/`DatabaseName` into the connection string's `Server=host,port` and
`Database=`, since SQLdb's own `DatabaseName` is a DSN), Zeos `Protocol=odbc_w` (`Database` is the
connection string). FreeTDS/db-lib is rejected (gotchas 37, 38) and FireDAC can't be tested (gotcha
42). Linux client: `msodbcsql18` + `unixodbc` from Microsoft's repository; `ClientLibrary` /
`LibraryLocation` = `libodbc.so.2` (the driver manager). What the adapters add:
- SQLdb: loads the driver manager itself (`InitialiseODBC`, `libodbc.so.2` by default on Unix),
  opens ODBC connections one at a time (gotcha 39) and applies `LockTimeoutMs` as `SET
  LOCK_TIMEOUT` through `SQLExecDirect` on the connection's own handle (gotcha 40);
- Zeos: `MARS_Connection=yes` appended to the connection string unless it has one (gotcha 41),
  `SET LOCK_TIMEOUT` after connecting;
- errors 1222 (lock request time out) and 1205 (deadlock victim) → `ELockConflictException`
  (SQLdb: `ESQLDatabaseError.ErrorCode`; Zeos: `EZSQLThrowable.ErrorCode`).
Schema differences the integration environment handles: `NVARCHAR` (a `VARCHAR` holds only its
collation's code page: `→` came back as `?` on every driver), `DATETIME2(3)` (`TIMESTAMP` is a row
version), `INSERT ... OUTPUT INSERTED.*` instead of `RETURNING` (`InsertReturningSql`), and the
database dropped after `ALTER DATABASE ... SET SINGLE_USER WITH ROLLBACK IMMEDIATE`. SQLdb reads
`NUMERIC` as a float field (`Currencies` goes through a `Double`); Zeos as a BCD field. Linux
runs: `ENGINE=sqlserver sh tools/test_integration_docker.sh` (image
`mcr.microsoft.com/mssql/server:2022-latest`, `sa` / `PascalDb_It1`; the script waits with `sqlcmd`
until the server accepts logins, which comes after the port opens). Windows runs: `docker run -d
--name pascaldb-it-mssql -p 14330:1433 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD=PascalDb_It1
mcr.microsoft.com/mssql/server:2022-latest`, then `PASCALDB_IT_ENGINE=sqlserver`,
`PASCALDB_IT_PORT=14330`; the ODBC Driver 18 must be installed in the runner's bitness (the driver
manager, `odbc32.dll`, is Windows's own: no `PASCALDB_IT_CLIENT`). The FreeTDS/ODBC probes that
led here are in `.ci/probe-mssql` (git-ignored).

**Zeos on Delphi is compiled from source:** the Delphi Zeos runner finds ZeosLib through the
`ZEOSDBO` environment variable (the folder containing `src\core`, `src\dbc`, ...), set in
the IDE (Tools > Options > IDE > Environment Variables) or in the OS. On Lazarus, install
`packages/lazarus/zcomponent.lpk` from the ZeosLib sources (it isn't found in the Online
Package Manager under "zeos").

---

## Known open items

None.

Closed on 2026-09-30: the rare failures with concurrent connections on Zeos + Firebird (Linux),
sample 05 (CI run 36235419745) and `ConcurrentWriters_AllCommit` (CI run 36644884746, attempt
1). First attributed to the `TClock`/`TSleep` race (`5c853c6`), which was a separate bug; the
cause is concurrent `TZConnection.Connect` through the Firebird 3+ API (gotcha 36), fixed by
serializing Firebird connects in the Zeos adapter.

---

## Gotchas

The numbered gotchas (symptom → cause → fix, 1–49) live in [`docs/gotchas.md`](docs/gotchas.md).
Read it before touching the pool, an adapter, resources or anything that differs between
Delphi and FPC, and add new ones there, keeping the numbering. References in this file
("gotcha 17") point to it.
