# pascal-db-faa

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

Drivers live in separate adapters. Planned: FireDAC (Delphi only), Zeos (dual) and SQLdb
(Lazarus only). Any other driver plugs in by implementing `IDBComponentProvider`/`IDBFactory`.

## Status

Extracted from the database core of `delphi-api-infra-faa` (commit `aa49f2b`). The core
is tested on Delphi 12 CE (Windows) and FPC 3.2.2 (Windows and Linux), 0 leaks on all
of them (FastMM / heaptrc). The adapters don't exist yet.

FPC programs must run with a UTF-8 default code page and, on Unix, include `cwstring`
— see "Runtime requirements for FPC applications" in `CLAUDE.md`.

## Layout

```
src/                    core (every unit includes pascaldb.inc)
packages/               pascal_db_faa.lpk (Lazarus)
tests/Unit/             DUnitX tests (masters) + PascalDb.UnitTests.dproj
tests/Unit/fpc/         GENERATED FPCUnit mirror + PascalDbUnitTestsFpc.lpi
tests/Unit/sql/         SQL fixtures + the generated PascalDbTestSql.res
tools/                  gen_fpc_mirror.py, build_sql_res.py, test_fpc.sh, test_fpc_docker.sh
PascalDb.groupproj      Delphi project group
PascalDb.lpg            Lazarus project group
```

## Tests

- FPC (Windows): `sh tools/test_fpc.sh`
- FPC (Linux, via Docker): `sh tools/test_fpc_docker.sh`
- Delphi: open `PascalDb.groupproj` and run `PascalDb.UnitTests` (Community Edition can't
  compile from the command line).

Conventions, the Delphi × FPC gotchas found so far and open items: see `CLAUDE.md`.

## License

MIT.
