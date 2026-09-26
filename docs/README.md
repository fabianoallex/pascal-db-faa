# Documentation

Guides for using pascal-db-faa, in the order the concepts build on each other. Each one
points to the sample that shows it running; the samples compile unchanged on Delphi and
Free Pascal (see [`samples/README.md`](../samples/README.md)).

| Guide | What it covers | Sample |
|---|---|---|
| [1. Getting started](getting-started.md) | The factory and its configuration, the acquire / start / commit / rollback pattern, reading results, nested scopes | 02 |
| [2. SQL by key](sql.md) | `SqlLoader['KEY']`, one SQL folder per database, SQL sources (resources, directory, memory, composite), template tags and `${...}` literals | 02, 03, 04 |
| [3. Optional and nullable values](optionals.md) | `INullXxx`, `IOptXxx`, `IOptNullXxx` as parameters and column reads; optional filters and partial updates | 04 |
| [4. Migrations](migrations.md) | `TDBMigrationEngine`, `IsDDL`, the migrations table, how scripts are split | 03 |
| [5. Testing with the mock](testing-with-the-mock.md) | `TMockDBFactory`: canned results, recorded executions, and its lifetime | 01 |
| [6. Errors](errors.md) | What raises what, and when: connecting, a connection lost in use, data errors, pool timeouts | 02, 05 |
| [7. The connection pool](pool.md) | Settings, growth and waiting, idle sweep, events and snapshots | 05 |
| [8. Adapters and databases](adapters.md) | SQLdb / FireDAC / Zeos × Firebird / PostgreSQL / SQLite: connection settings, client libraries, SQLite notes, what an FPC program must do | all |

## Status

- No version has been tagged yet (the Lazarus package says 0.1): the API isn't frozen.
- CI builds and runs the FPC suites on Linux on every push. The Delphi side is built and
  run by hand in the IDE (Delphi Community Edition can't compile from the command line);
  see the README for what was validated where.
- A rare failure with concurrent connections on Zeos + Firebird (Linux) is still
  unexplained; see "Known open items" in [`CLAUDE.md`](../CLAUDE.md).

[`CLAUDE.md`](../CLAUDE.md) holds the conventions for working on the library itself and
the Delphi × FPC behavior differences found by measurement ("Gotchas found"). These guides
link to it where a gotcha affects how you use the library.
