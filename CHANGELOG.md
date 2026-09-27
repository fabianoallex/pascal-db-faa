# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here.

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

[0.1.0]: https://github.com/fabianoallex/pascal-db-faa/releases/tag/v0.1.0
