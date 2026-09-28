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
  said 2. They now use `PdbAtomicInc64`/`PdbAtomicAdd64` and are read with `PdbAtomicRead64`.
- `TClock` and `TSleep` (`PascalDb.SystemContext`) created their default instance lazily on the
  first call; two threads making that first call together raced on the shared interface (one
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
| `PascalDb.Optionals` / `ClockCache` / `SystemContext` / `SafeLog` | `Common.*` with the same name |
| `PascalDb.Threading` | — (new: portable atomics + tick) |

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
- **Atomics and monotonic time only through `PascalDb.Threading`** (`PdbAtomicInc`,
  `PdbAtomicInc64`, `PdbAtomicRead64`, `PdbTickMs`). `TInterlocked` and `TStopwatch` don't
  exist in FPC.
- **Never `TDictionary.Create(AComparer)` with a possibly-`nil` `AComparer`** (see gotcha 1
  below).
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
  variables. `PASCALDB_IT_ENGINE` picks the database: `firebird` (default), `postgresql` or
  `sqlite` (a file next to the runner; no server).
  Each run creates a fresh database, migrates it with `TDBMigrationEngine` (SQL from a
  `TMemorySqlSource`) and drops it at the end. FPC on Windows: build
  `tests/Integration/fpc/PascalDbIntegrationTestsFpc.lpi` (SQLdb) or
  `tests/Integration/fpc-zeos/PascalDbIntegrationTestsZeosFpc.lpi` (Zeos) and run it with
  `--all --format=plain`. The Zeos runners (FPC and Delphi) define `PASCALDB_IT_ZEOS` and
  reuse the same fixtures. Linux: `sh tools/test_integration_docker.sh` (`ENGINE=firebird`,
  `postgresql` or `sqlite`; `ADAPTER=sqldb` (default) or `zeos`, the latter with `ZEOSDBO` pointing at the
  ZeosLib folder, mounted into the container; server container + FPC container on a private
  network). **CI:** `.github/workflows/ci.yml` only calls `sh tools/ci-test.sh`, which runs the
  unit suite, then all six Linux integration combinations (SQLdb/Zeos ×
  Firebird/PostgreSQL/SQLite) and the samples on the same six (`tools/test_samples_docker.sh`);
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

| Adapter | Compiler | Package / unit | Status |
|---|---|---|---|
| SQLdb | FPC only | `pascal_db_faa_sqldb.lpk` / `adapters/sqldb` | done: contract suite green on Firebird 2.5 (Windows), Firebird 5 (Linux), PostgreSQL 17 (Windows and Linux), SQLite (Windows with sqlite.org's 3.53.4 DLL, Linux with Debian bookworm's libsqlite3) |
| FireDAC | Delphi only | `adapters/firedac` | done: contract suite green on Firebird 2.5 (Delphi 12 CE, Win32 and Win64), PostgreSQL 17 (Win64) and SQLite (Win32 and Win64, engine linked in) — `tests/Integration/PascalDb.IntegrationTests.dproj` |
| Zeos | dual | `pascal_db_faa_zeos.lpk` / `adapters/zeos` | done: contract suite green on Firebird 2.5 with FPC (Win64) and Delphi 12 CE (Win32 and Win64), PostgreSQL 17 with FPC and Delphi (Win64), Firebird 5 and PostgreSQL 17 with FPC on Linux, SQLite with FPC on Windows and Linux and Delphi (Win32 and Win64) — `tests/Integration/fpc-zeos`, `tests/Integration/PascalDb.IntegrationTestsZeos.dproj` |

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
(`PacketRecords = -1`), so `RecordCount` is exact.

**Zeos specifics** (ZeosLib 8): `ConnectionParams` takes `Protocol` (`firebird`/`postgresql`;
`firebird` falls back to the legacy API with a 2.5 client), `HostName`, `Port`, `Database`,
`User`, `Password`, `ClientCodepage`, `LibraryLocation`; any other line goes to
`TZConnection.Properties`. Zeos 8 queries use its own `TZParams` (not Data.DB's `TParams`),
so the adapter has its own `TParamsBase` over them; `TZParam.AsString` is Unicode on Delphi,
so the FireDAC ANSI problem doesn't apply. `TZTransaction.StartTransaction` on a transaction
whose native handle is already open (Zeos opens it with the first statement) creates a
**savepoint** instead, and the matching `Commit` only releases it — so every statement the
adapter runs starts the `ITransaction` first. Queries call `FetchAll` after opening, so
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
SQLite's types are loose: a `NUMERIC(15,2)` is stored as `REAL`, so money keeps a `Double`'s
precision, not an exact decimal. `CREATE TABLE IF NOT EXISTS`, `RETURNING` and transactional
DDL all work (the contract suite passes unchanged). `:memory:` gives each pooled connection its
own empty database: use a file.

**Zeos on Delphi is compiled from source:** the Delphi Zeos runner finds ZeosLib through the
`ZEOSDBO` environment variable (the folder containing `src\core`, `src\dbc`, ...), set in
the IDE (Tools > Options > IDE > Environment Variables) or in the OS. On Lazarus, install
`packages/lazarus/zcomponent.lpk` from the ZeosLib sources (it isn't found in the Online
Package Manager under "zeos").

---

## Known open items

None.

Closed on 2026-09-27: the rare failures with concurrent connections on Zeos + Firebird (Linux),
sample 05 (CI run 36235419745: `EAccessViolation` in a worker; once 26 unfreed blocks locally).
Attributed to the `TClock`/`TSleep` lazy-initialization race fixed in `5c853c6` (see the list
under "Origin"); sample 05 stayed clean in every CI run since. If it comes back, the sample
prints the FPC backtrace and `test_samples_docker.sh` prints heaptrc's report.

---

## Gotchas found (Delphi × FPC 3.2.2)

Format: symptom → cause → fix. Also recorded in the skill: 1–4, 7 in
`references/rtl-gotchas.md` ("Generics / RTL collections", "Types", "Resource files"), 18
in "Types", 19 in "Resource files" and 20 in "Threading / interop"; 5–6 in
the compat adapter bullet of `SKILL.md` ("Mirrored tests"); 8 in "Encoding"; 9 in the
`lazbuild` bullets; 10 in the tests/CI sections; 11, 13, 14, 16 and 21–25 in "Database access"; 12
and 15 in the tests section (`TearDown`, `finalization`). The skill links to this repository
(https://github.com/fabianoallex/pascal-db-faa) from each of them.

1. **`TDictionary.Create(nil)` raises an Access Violation on FPC.** Symptom: AV in
   `FindBucketIndex` (`generics.dictionaries.inc`) on the first `Add`/`TryGetValue`: 30 of 158
   tests failed because of it, all through `TClockCache`. Cause: Delphi replaces a `nil`
   comparer with `TEqualityComparer<T>.Default`; FPC's `rtl-generics` stores the `nil` and
   calls `GetHashCode` on it. Fix: `if Assigned(AComparer) then TMap.Create(AComparer) else
   TMap.Create` (`PascalDb.ClockCache`).
2. **`IEqualityComparer<T>` has a different signature**: FPC uses `constref` and a `UInt32`
   hash; Delphi uses `const` and an `Integer` hash. `TEqualityComparer<T>.Construct` accepts a
   closure in Delphi and only a plain function / `of object` in FPC. Fix: a named function
   with the signature under `{$IFDEF FPC}`, which both accept (`SingleKeyEquals`/
   `SingleKeyHash` in `PascalDb.Optionals`).
3. **`TGuid.Empty` doesn't exist in FPC 3.2.2** (it comes from Delphi's `TGuidHelper`). Fix: a
   typed constant `EMPTY_GUID: TGUID = '{00000000-...}'`.
4. **In FPC 3.2.2, `RT_RCDATA` is only in the `system` unit on non-Windows targets**; on
   Windows it lives in the `Windows` unit. Fix: a local constant
   `{$IFDEF FPC}PChar(10){$ELSE}RT_RCDATA{$ENDIF}` (`MAKEINTRESOURCE(10)` on any platform).
5. **FPCUnit has no delta-less `AssertEquals(Double, Double)`**, and FPC resolves the call to
   the `Currency` overload **without any warning**. Symptom: a test comparing `TDateTime`
   passed on FPC at 4-decimal precision, while the original DUnitX test compared `Double`.
   Fix: always an explicit delta; `PascalDb.DUnitXCompat` doesn't offer the delta-less
   overload either, so the master can't compile differently on each side.
6. **DUnitX's `Assert.AreEqual(string, string)` ignores case by default.** The overload
   without `ignoreCase` uses `fIgnoreCaseDefault`, initialized to `true`
   (`source\DUnitX\DUnitX.Assert.pas`, line 1355, in Delphi 12; configurable through
   `Assert.IgnoreCaseDefault`). Already documented in `Redis.DUnitXCompat`; confirmed in the
   source here. The compat adapter passes `False` explicitly.
7. **Compiling a `.rc` on Linux FPC needs a MinGW C toolchain** (see "SQL sources"). Fix:
   generate the `.res` directly (`tools/build_sql_res.py`) and link it with `{$R x.res}`.
8. **FPC console/service apps lose non-ASCII text outside the default code page**, and
   **FPC on Unix mangles non-ASCII text in WideString Variants without `cwstring`** (see
   "Runtime requirements for FPC applications" for the exact, measured scope). Neither
   shows up in an LCL app on Windows.
9. **Stale `.ppu` after switching a project from a source search path to a package.** The
   test runner's own output folder kept a `PascalDb.SqlLoader.ppu` from when its `.lpi`
   compiled `src/` directly; with the source no longer on its search path, FPC used that old
   `.ppu` even with `lazbuild -B` ("Wrong number of parameters specified for call to
   Create"). Fix: delete the project's `lib/` folder after such a switch.
10. **Linux runs exposed two test bugs that Windows (pt-BR) hid**: `StrToDateTime('28/12/2025
    ...')` depends on the locale's date format (use `EncodeDate`/`EncodeTime`), and a
    concurrency test whose fake `Sleep` returned instantly let a waiting thread burn all its
    retries before the connection holders were scheduled — flaky in a Linux container (use
    real short waits when the test is about contention).
11. **SQLdb loads the database client library once per process; the first load wins** (see
    "SQLdb specifics"). Observed: the integration suite passed only while the pool's ramp-up
    happened to connect first; with the database created through a plain `TIBConnection`
    first, every test failed with "Firebird interface already initialized from library
    fbclient.dll". Fix: load the configured library explicitly before any direct connection.
12. **Test fixtures that keep a reference to a pooled factory keep its connections open past
    unit finalization** (FPCUnit frees its test objects after the units they use are
    finalized), so dropping the test database at the end failed silently and the leftover
    database broke the next run. Fix: release the factory in `TearDown`; the integration
    environment also starts the pool with no connections, so a leftover database never blocks
    the DROP.
13. **On Delphi, `AsString` on a FireDAC `TFDParam` or a Data.DB `TParam` makes an ANSI
    (`ftString`) parameter**: the text is converted to the ANSI code page and characters outside
    it reach the database as `?`. Observed with FireDAC on Firebird (`CharacterSet=UTF8`):
    `'São Paulo → ok'` stored as `'São Paulo ? ok'` — `ã` survives (it's in cp1252), `→` doesn't,
    which is why Portuguese text never showed it. Fix: `AsWideString` / `ftWideString` for
    strings on Delphi (FPC is unaffected: its `string` is UTF-8). The origin adapter used
    `AsString`.
14. **On Windows, a client library loaded by full path doesn't find its own dependencies.**
    Observed with SQLdb (FPC Win64) and the `libpq.dll` of a PostgreSQL 18 install: with the
    install's `bin` folder on `PATH` the suite passed; without it, every test failed with "Can
    not load PostgreSQL client library "C:\Program Files\PostgreSQL\18\bin\libpq.dll"" —
    `libpq.dll` needs `libssl`, `libcrypto`, `libintl`, ... from that same folder, and the
    default DLL search doesn't look in the folder of the DLL being loaded. Zeos passed without
    `PATH` (its loader uses `LoadLibraryEx(..., LOAD_WITH_ALTERED_SEARCH_PATH)` when given a
    path). Fix: `PdbPreloadClientLibrary`, which loads the library the same way first; with it
    SQLdb passed without `PATH`, and so did FireDAC (Delphi Win64) — whether FireDAC alone
    would fail was not measured. A developer machine with the database installed usually has
    that folder on `PATH`, which hides the problem until deployment.
15. **When the client library fails to load, cleanup code fails the same way.** The first
    run with a missing library ended in runtime error 217 and 67 leaked blocks instead of 14
    clean test errors: the integration environment's finalization tried to drop the database,
    which loads the library again and raised — an exception in a finalization section aborts
    the remaining ones. Separately, `PdbSQLdbUseClientLibrary` leaked its
    `TSQLDBLibraryLoader` when `Enabled := True` raised. Fix: never raise from finalization;
    free the loader on failure. Checked with a nonexistent library path: 14 errors, 0 leaks.
16. **Zeos 8 + Firebird 3+ API: `Commit` loops forever after an `INSERT ... RETURNING` opened
    as a query.** Observed on Linux (FPC 3.2.2, Debian's Firebird 3 client, Firebird 5
    server): the contract test `OptionalColumn_OmittedByTag_UsesDefault` hung at 100% CPU;
    gdb showed the main thread in `TZFirebirdTransaction.TestCachedResultsAndForceFetchAll`
    (`ZDbcFirebird.pas`), which calls `Last` on each open cursor until it unregisters itself —
    that cursor never does. It never showed up on Windows, where the 2.5 client makes Zeos use
    the legacy API. Fix: `hard_commit=true` by default for Firebird connections (the adapter
    already fetches every result on `Open`); the suite then passed on Linux and still passed on
    Windows. Not measured: whether other statement kinds trigger it, and the Delphi runner with
    the Firebird 3+ API.
17. **Zeos 8: assigning the same SQL text again loses the parameters.** Observed with the
    Zeos adapter on Linux (FPC 3.2.2, PostgreSQL 17 and Firebird 5): a loop that set
    `IQuery.Sql` to the same INSERT on every iteration failed on the second one with
    `Parameter "CODE" not found` (found by sample 02; SQLdb passed). Cause:
    `TDataSetQueryBase.SetSql` removes the parameters (`DoClearParams`) and then assigns
    `SQL.Text`; Zeos doesn't re-parse a text equal to the current one, so the parameters never
    come back. Fix: `SqlLines.Clear` before the assignment. Contract test
    `SameSqlReassigned_ParamsStillBind` failed on Zeos before the fix and passes on all four
    Linux combinations after it. Not measured: whether FireDAC was affected.
18. **A `Double(...)` typecast of a `Currency` converts on FPC for Windows but not on FPC for
    Linux.** Sample 03 printed prices with `Format('%8.2f', [Double(LResult.Currencies['PRICE'])])`:
    `12.50` on Windows, `125000.00` on every Linux run. Isolated with FPC 3.2.2 x86_64 on both
    targets: on win64 the cast gives `12.50`; on linux, `0.00` for a `Currency` variable and
    `125000.00` for a `Currency` function result (the internal Int64, scaled by 10000); no
    warning on either. An assignment to a `Double` gave `12.50` everywhere. Fix: convert by
    assignment (`samples/03-migrations/Migrations.dpr`, `ListProducts`). Not measured: Delphi.
19. **FPC with a unit output folder (`-FU`) links a same-named `.res` from the program's folder
    instead of the path in `{$R}`.** Sample 03 linked its SQL as `{$R 'sql/Migrations.res'}`;
    after the program was built in the Delphi IDE, which writes `Migrations.res` next to the
    `.dpr`, every Linux run failed with `SQL not found ... resource SQL_PG_MIG_0001`, and passed
    again with that file removed. Isolated with FPC 3.2.2 (linux and win64): a program with
    `{$R 'sub/data.res'}` and another `data.res` next to it gets the one next to it when built with
    `-FU`, whatever the program is called; without `-FU`, it gets `sub/data.res`. lazbuild passes
    `-FU` when the project has a unit output directory (the samples' `.lpi` do). Fix: never give
    an embedded `.res` the project's name (now `sql/MigrationsSql.res`). Not measured: Delphi's
    resolution of the same case, and FPC versions other than 3.2.2.
20. **On FPC, console lines written by two threads come out cut in the middle when the output is
    redirected, even under a lock.** Sample 05 writes from worker threads, the pool's sweep thread
    and the main thread, every line inside one `TCriticalSection`; on Linux, redirected to a file,
    a line came out as `pool: 1 open (1 id` + the sweep thread's line + `le), max 3; ...`. Cause:
    FPC's `Output` is a threadvar, one buffer per thread, and each buffer reaches the file when it
    fills, not when the lock is released. Isolated with FPC 3.2.2 (x86_64), two threads writing 200
    locked lines each, output redirected: linux, 2 broken lines without `Flush(Output)` and 0 with
    it; win64, 0 in both. Fix: `Flush(Output)` inside the lock, after `Writeln`
    (`samples/05-pool/PoolUnderLoad.dpr`, `Say`). Not measured: Delphi, and an interactive
    terminal on Linux.
21. **SQLdb + SQLite: "database schema has changed" on a pooled connection after migrations.**
    The contract suite's migrations failed on Linux with `TSQLite3Connection : database schema
    has changed` (`SQLITE_SCHEMA`, 17): the DDL ran on one pooled connection and the version
    record on another, opened before. FPC 3.2.2's `sqlite3conn` prepares with the legacy
    `sqlite3_prepare` (`sqlite3conn.pp`, line 262), which returns `SQLITE_SCHEMA` instead of
    preparing again as `sqlite3_prepare_v2` does. Fix: the SQLdb adapter prepares and runs the
    statement once more on that error (query `Open`/`ExecSql` and the transaction's `ExecSql`);
    the suite then passed on Linux and Windows.
22. **Zeos 8 + SQLite stores a `Currency` parameter ×10000.** `Params_EveryType_RoundTrip`
    read `123400` for `12.34`. A probe showed the stored value was the integer `123400` for the
    parameter and the real `12.34` for a literal: `TZSQLiteCAPIPreparedStatement.SetCurrency`
    binds `sqlite3_bind_int64` over an `Int64 absolute` the Currency (`ZDbcSqLiteStatement.pas`).
    Fix: the Zeos adapter sends `Currency` to SQLite as a `Double`. Measured with FPC 3.2.2 on
    Linux; the code path doesn't depend on the compiler, but Delphi wasn't run.
23. **A `sqlite3.dll` without the column-metadata functions makes SQLdb and Zeos fail with an
    access violation at `$0`.** With Python 3.12's `DLLs\sqlite3.dll` (SQLite 3.45.3, 64-bit),
    every test of both FPC Windows runners failed in `SetUp` with an AV at address 0; that
    DLL doesn't export `sqlite3_column_table_name` and its siblings (built without
    `SQLITE_ENABLE_COLUMN_METADATA`), and the drivers call them. With the official DLL from
    sqlite.org (3.53.4, which exports them) both suites passed. Debian's `libsqlite3-0` has them.
24. **SQLite without a busy timeout: concurrent writers fail at once with "database is
    locked".** A probe with 4 threads each inserting in its own transaction held 200 ms: 3 of 4
    failed within 4 ms, on SQLdb and on Zeos (FPC 3.2.2, Linux). Neither driver sets a busy
    timeout by default. Fix: 5000 ms on every SQLite connection (see "SQLite specifics"); the
    probe then had 0 failures, and `ConcurrentWriters_AllCommit` keeps it covered.
25. **FireDAC + SQLite needs three settings changed from FireDAC's defaults to pass the
    contract suite** (Delphi 12 CE, Win32 and Win64, same results on both). First run: 14/16.
    `Utf8Text_RoundTrip` read `'São Paulo ? ok'` for `'São Paulo → ok'` (VARCHAR handled as ANSI,
    as in gotcha 13) — `StringFormat=Unicode` fixed it. `ConcurrentWriters_AllCommit` failed
    with "database table is locked" (a shared-cache table lock); with `SharedCache=False` it
    failed instead with "database is locked", still at once (the whole suite took 0.29 s); with
    `BusyTimeout=5000` and `UpdateOptions.LockWait = True` added together it passed (16/16, the
    suite now 1.2 s: the writers wait for each other). Which of those last two was needed wasn't
    isolated. `LockingMode=Normal` is set from FireDAC's documentation, never tried with
    `Exclusive`. The Community Edition ships no source for the SQLite driver, so these came
    from measurement, not from reading the driver.
26. **SQLdb reads a backslash as an escape when finding parameters, on the SQLite3 and PostgreSQL
    connectors.** `... LIKE :A ESCAPE '\' AND PRICE >= :B AND CATEGORY = :C` gives a `TSQLQuery`
    with one parameter (`A`): `\'` is taken as an escaped quote, the rest of the text as part of a
    string literal, and `:B`/`:C` silently disappear, to fail later with `Parameter "B" not
    found`. With `ESCAPE '!'` all three are found. Measured with FPC 3.2.2 on Linux, parameter
    list only (no server needed): SQLite3 and PostgreSQL 1 of 3, Firebird 3 of 3. Found by an
    agent writing a consumer program (a prefix search with escaped wildcards). Fix: use an
    escape character other than a backslash (`docs/sql.md`). Not measured: FireDAC and Zeos.
27. **On Linux, SQLdb's default client library names don't match what the runtime packages
    install, for SQLite and Firebird.** Measured on Debian bookworm with only the runtime
    packages (`libsqlite3-0`, `libpq5`, `libfbclient2`), FPC 3.2.2: SQLite3 looks for
    `libsqlite3.so` (only the `-dev` package creates it) and fails with `Can not load SQLite
    client library "libsqlite3.so"`; Firebird looks for `libfbclient.so.2.5.1`, `libgds.so` or
    `libfbembed.so.2.5` and fails with bookworm's `libfbclient.so.2` (a 3.0 client); PostgreSQL
    finds `libpq.so.5` by itself. With `ClientLibrary` set to `libsqlite3.so.0` /
    `libfbclient.so.2` both load. The test scripts always pass the full path, which is why the
    suites never showed it; three agents writing a consumer program all hit the SQLite one. Not
    measured: Zeos's default names.
