# pascal-db-faa

[![FPC Linux tests](https://github.com/fabianoallex/pascal-db-faa/actions/workflows/ci.yml/badge.svg)](https://github.com/fabianoallex/pascal-db-faa/actions/workflows/ci.yml)

A database access layer for **Delphi and Lazarus/FPC from the same source code**
(dual-compiler).

- Driver-agnostic contracts: `IDBFactory`, `IDBConnection`, `ITransaction`,
  `IScopeTransaction`, `IQuery`, `IQueryResult`, `IParams`.
- Connection pool with ramp-up, limit, bounded waiting, idle sweep, discard of broken
  connections, and events/snapshot for metrics.
- Versioned migrations.
- SQL in tagged templates (`[TAG {] ... [} TAG]`, `${LITERAL}`), read from pluggable
  sources: embedded resources (default), a directory of `.sql` files, memory, or a
  composite. `tools/build_sql_res.py` builds the `.res` on any OS.
- Optional/nullable types (`IOptXxx`, `INullXxx`, `IOptNullXxx`) integrated with the
  parameters.
- `TMockDBFactory`: a complete mock for testing repositories without a database.

Drivers live in thin adapters on top of a shared, driver-agnostic base (configuration,
transactions and savepoints, scripts, parameter semantics, TDataSet-based queries). Available:
**SQLdb** (Lazarus/FPC), **FireDAC** (Delphi) and **Zeos** (ZeosLib 8, both compilers), each
for Firebird, PostgreSQL, SQLite, MySQL and MariaDB.
Any other driver plugs in by implementing `IDBComponentProvider`.

## A quick look

```pascal
LScope := LFactory.GetPool.AcquireQuery(LQuery);   // pooled connection + its transaction
LScope.StartTransaction;
try
  LQuery.Sql := LFactory.SqlLoader['CITY.BY_STATE'].SQL;   // SQL by key, one version per database
  LQuery.Params.Strings['STATE'] := 'SP';
  LResult := LQuery.Open;
  while not LResult.Eof do
  begin
    Writeln(LResult.Strings['NAME']);
    LResult.Next;
  end;
  LScope.Commit;
except
  LScope.Rollback;
  raise;
end;  // the connection goes back to the pool when LQuery and LScope are released
```

## Documentation

- [**Guides**](docs/README.md): getting started, SQL by key and templates, optional and
  nullable values, migrations, testing with the mock, errors, the pool, adapters and databases,
  writing an adapter for another component, using another database.
- [**Samples**](samples/README.md): five console programs, each one source for both compilers.

Current version: **0.4.1**. While it is 0.x the API may still change between minor
versions; every change is listed in the [changelog](CHANGELOG.md).

## Status

Extracted from the database core of `delphi-api-infra-faa` (commit `aa49f2b`). The core
is tested on Delphi 12 CE (Windows) and FPC 3.2.2 (Windows and Linux), 0 leaks on all
of them (FastMM / heaptrc). The same integration contract suite passes on the SQLdb adapter
(Firebird 2.5 on Windows, Firebird 5 on Linux, PostgreSQL 17 on Windows and Linux), on the
FireDAC adapter (Firebird 2.5, Delphi Win32; PostgreSQL 17, Delphi Win64) and on the Zeos
adapter (Firebird 2.5, FPC Win64 and Delphi Win32/Win64; Firebird 5 on Linux; PostgreSQL 17,
FPC and Delphi Win64 and FPC on Linux). On SQLite it passes on SQLdb and Zeos with FPC on
Windows and Linux, and on FireDAC and Zeos with Delphi (Win32 and Win64). On MySQL 8.4 and
MariaDB 11.4 it passes on SQLdb and Zeos with FPC on Windows (Win64) and Linux (MariaDB
Connector/C for both servers), and on FireDAC and Zeos with Delphi (Win32 and Win64). CI runs the Linux FPC suites on every
push; the Delphi side is run in the IDE.

FPC programs must run with a UTF-8 default code page and, on Unix, include `cwstring`
— see [what a Free Pascal program must do](docs/adapters.md#what-a-free-pascal-program-must-do).

## Layout

```
src/                    core (every unit includes pascaldb.inc)
packages/               pascal_db_faa.lpk (Lazarus)
tests/Unit/             DUnitX tests (masters) + PascalDb.UnitTests.dproj
tests/Unit/fpc/         GENERATED FPCUnit mirror + PascalDbUnitTestsFpc.lpi
tests/Unit/sql/         SQL fixtures + the generated PascalDbTestSql.res
tests/Integration/       contract tests (DUnitX masters) + IntegrationEnv
tests/Integration/fpc/   GENERATED FPCUnit mirror + PascalDbIntegrationTestsFpc.lpi
tests/Integration/fpc-zeos/  FPCUnit runner on Zeos (same mirror)
adapters/sqldb/         SQLdb adapter (package pascal_db_faa_sqldb.lpk)
adapters/firedac/       FireDAC adapter (Delphi)
adapters/zeos/          Zeos adapter (both; package pascal_db_faa_zeos.lpk)
docs/                   usage guides (start at docs/README.md)
samples/                console samples, one source for both compilers (see samples/README.md)
tools/                  gen_fpc_mirror.py, build_sql_res.py, test_*.sh, ci-test.sh
PascalDb.groupproj      Delphi project group
PascalDb.lpg            Lazarus project group
```

## Tests

- FPC (Windows): `sh tools/test_fpc.sh`
- FPC (Linux, via Docker): `sh tools/test_fpc_docker.sh`
- Integration, Linux (Docker): `sh tools/test_integration_docker.sh` (Firebird 5),
  `ENGINE=postgresql sh tools/test_integration_docker.sh` (PostgreSQL 17) or `ENGINE=sqlite`
  (no server); `ADAPTER=zeos`
  (with `ZEOSDBO` set to the ZeosLib folder) runs it on the Zeos adapter
- Everything CI runs, locally: `sh tools/ci-test.sh` (unit suite, then the integration suite and
  the samples on both Linux adapters and all three databases; downloads ZeosLib 8.0.0 when
  `ZEOSDBO` isn't set)
- Integration, Windows (local Firebird, PostgreSQL with `PASCALDB_IT_ENGINE=postgresql`, or
  SQLite with `PASCALDB_IT_ENGINE=sqlite` — see
  `CLAUDE.md`): `tests/Integration/fpc/PascalDbIntegrationTestsFpc.lpi`
  (SQLdb), `tests/Integration/fpc-zeos/PascalDbIntegrationTestsZeosFpc.lpi` (Zeos),
  `tests/Integration/PascalDb.IntegrationTests.dproj` (FireDAC) and
  `tests/Integration/PascalDb.IntegrationTestsZeos.dproj` (Zeos; set `ZEOSDBO` to the
  ZeosLib folder)
- Delphi: open `PascalDb.groupproj` and run `PascalDb.UnitTests` (Community Edition can't
  compile from the command line).

Conventions, the Delphi × FPC gotchas found so far and open items: see `CLAUDE.md`.

## License

MIT.
