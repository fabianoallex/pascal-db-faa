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
| [7. The connection pool](pool.md) | Settings, growth and waiting, idle sweep, events and snapshots, statement events, threads, database work off the UI thread | 05 |
| [8. Adapters and databases](adapters.md) | SQLdb / FireDAC / Zeos × Firebird / PostgreSQL / SQLite / MySQL / MariaDB / SQL Server: connection settings, client libraries, SQLite, MySQL and SQL Server notes, what an FPC program must do | all |
| [9. Writing an adapter](writing-an-adapter.md) | Supporting another connection component: the classes to write, a skeleton, what the library relies on, checking it with the contract suite | — |
| [10. Using another database](other-databases.md) | A database other than the built-in ones: the SQL dialect, the driver in each adapter, what tends to differ, running the contract suite against it | — |

## Status

- Versions and what changed in each: [`CHANGELOG.md`](../CHANGELOG.md). While the version is
  0.x, a minor version may change the API.
- CI builds and runs the FPC suites on Linux on every push. The Delphi side is built and
  run by hand in the IDE (Delphi Community Edition can't compile from the command line);
  see the README for what was validated where.

[`CLAUDE.md`](../CLAUDE.md) holds the conventions for working on the library itself and
the Delphi × FPC behavior differences found by measurement ("Gotchas found"). These guides
link to it where a gotcha affects how you use the library.
