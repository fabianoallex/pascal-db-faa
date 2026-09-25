# pascal-db-faa

A database access layer for **Delphi and Lazarus/FPC from the same source code**
(dual-compiler).

- Driver-agnostic contracts: `IDBFactory`, `IDBConnection`, `ITransaction`,
  `IScopeTransaction`, `IQuery`, `IQueryResult`, `IParams`.
- Connection pool with ramp-up, limit, bounded waiting, idle sweep, discard of broken
  connections, and events/snapshot for metrics.
- Versioned migrations.
- SQL in tagged templates (`[TAG {] ... [} TAG]`, `${LITERAL}`).
- Optional/nullable types (`IOptXxx`, `INullXxx`, `IOptNullXxx`) integrated with the
  parameters.
- `TMockDBFactory`: a complete mock for testing repositories without a database.

Drivers live in separate adapters. Planned: FireDAC (Delphi only), Zeos (dual) and SQLdb
(Lazarus only). Any other driver plugs in by implementing `IDBComponentProvider`/`IDBFactory`.

## Status

Extracted from the database core of `delphi-api-infra-faa` (commit `aa49f2b`). The core
compiles on FPC 3.2.2 (Lazarus 4.0) and on Delphi 12 CE: 158/158 tests on both, 0 leaks on
both (heaptrc / FastMM). The adapters don't exist yet.

## Layout

```
src/                    core (every unit includes pascaldb.inc)
packages/               pascal_db_faa.lpk (Lazarus)
tests/Unit/             DUnitX tests (masters) + PascalDb.UnitTests.dproj
tests/Unit/fpc/         GENERATED FPCUnit mirror + PascalDbUnitTestsFpc.lpi
tools/                  gen_fpc_mirror.py, test_fpc.sh
PascalDb.groupproj      Delphi project group
PascalDb.lpg            Lazarus project group
```

## Tests

- FPC: `sh tools/test_fpc.sh`
- Delphi: open `PascalDb.groupproj` and run `PascalDb.UnitTests` (Community Edition can't
  compile from the command line).

Conventions, the Delphi × FPC gotchas found so far and open items: see `CLAUDE.md`.

## License

MIT.
