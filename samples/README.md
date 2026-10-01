# Samples

Console programs showing how to use pascal-db-faa. Each sample is **one source file for
both compilers**: open the `.dproj` in Delphi or the `.lpi` in Lazarus (they're also in
`PascalDb.groupproj` and `PascalDb.lpg`). The [guides](../docs/README.md) explain the
concepts each one shows.

| Sample | Shows | Needs a database |
|---|---|---|
| [01-mock-repository](01-mock-repository/MockRepository.dpr) | A repository that only knows `IDBFactory`, checked against `TMockDBFactory`: canned results, recorded executions and parameters, a paged query | No |
| [02-quickstart](02-quickstart/Quickstart.dpr) | Configuration and factory, the acquire / start / commit / rollback pattern, SQL by key with one version per database, the same repository on a real database, a batch rolled back as a whole, a state's cities read page by page (the paging clause written by each database's dialect), error handling | Yes |
| [03-migrations](03-migrations/Migrations.dpr) | Versioned migrations (`TDBMigrationEngine`): `IsDDL` and why DDL and DML go in separate migrations, progress events through a method, running twice applies nothing; SQL in `.sql` files embedded as resources (`build_sql_res.py`), with a folder that overrides them during development | Yes |
| [04-optionals](04-optionals/Optionals.dpr) | `INullXxx` / `IOptXxx` / `IOptNullXxx` as parameters and column reads; SQL templates shaped by them: optional filters (`ApplyFilter`, `${NAME_OP}`), partial updates where Undefined leaves a column alone and Null clears it (`ProcessTag`), printing the SQL each case produces | Yes |
| [05-pool](05-pool/PoolUnderLoad.dpr) | The connection pool under concurrent load (worker threads): growth up to the limit, callers waiting their turn, `EPoolTimeoutException` when the wait runs out, the idle sweep; observed through its events (thread-safe handler) and `GetSnapshot` | Yes |

01 and 02 share `common/Samples.CityRepository.pas`: the same class runs against the mock in 01
and against PostgreSQL, Firebird, SQLite, MySQL, MariaDB or SQL Server in 02.

## Running samples 02 to 05

They connect to a local PostgreSQL by default:

```
docker run -d --name pascaldb-sample-pg -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:17
```

Or, with no server at all, `PASCALDB_SAMPLE_ENGINE=sqlite`: the database is the file
`pascaldb_samples.sqlite` in the current folder (or `PASCALDB_SAMPLE_DATABASE`). FireDAC
(Delphi) has SQLite built in; SQLdb and Zeos load `sqlite3.dll` / `libsqlite3.so.0`, and on
Windows it must be a build with the column-metadata functions, such as the official one from
sqlite.org (see gotcha 23 in `docs/gotchas.md`).

Settings come from environment variables (`PASCALDB_SAMPLE_ENGINE`, `_HOST`, `_PORT`,
`_DATABASE`, `_USER`, `_PASSWORD`, `_CLIENT`); `common/Samples.Env.pas` documents them.
On Windows, point `PASCALDB_SAMPLE_CLIENT` at the client library when it isn't on the
`PATH`, e.g. `C:\Program Files\PostgreSQL\17\bin\libpq.dll` (64-bit programs only:
PostgreSQL ships no 32-bit client). For Firebird, set `PASCALDB_SAMPLE_ENGINE=firebird`
and `PASCALDB_SAMPLE_DATABASE` to an existing database.

For MySQL or MariaDB, `PASCALDB_SAMPLE_ENGINE=mysql` (or `mariadb`); the database `samples`
must exist (the images create it):

```
docker run -d --name pascaldb-sample-mysql -p 3306:3306 -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=samples mysql:8.4
```

The client is MariaDB Connector/C for both servers (`libmariadb.dll` from its installer, with
the `plugin` folder next to it, which MySQL 8's default authentication needs; `libmariadb.so.3`
on Linux). See the MySQL notes in [docs/adapters.md](../docs/adapters.md#mysql-and-mariadb-notes).

For SQL Server, `PASCALDB_SAMPLE_ENGINE=sqlserver`, with SQLdb or Zeos (FireDAC's SQL Server
driver isn't in Delphi's Community Edition: build with `PASCALDB_SAMPLES_ZEOS` on Delphi); the
database `samples` must exist:

```
docker run -d --name pascaldb-sample-mssql -p 1433:1433 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD=PascalDb_It1 mcr.microsoft.com/mssql/server:2022-latest
docker exec pascaldb-sample-mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P PascalDb_It1 -Q "CREATE DATABASE samples"
```

The client is Microsoft's ODBC Driver 18 for SQL Server (`PASCALDB_SAMPLE_ODBC_DRIVER` names
another), installed from Microsoft; on Linux, set `PASCALDB_SAMPLE_CLIENT=libodbc.so.2` for Zeos.
The samples trust the server's self-signed certificate. See the SQL Server notes in
[docs/adapters.md](../docs/adapters.md#sql-server-notes).

On PostgreSQL, from the second run on, the client library prints
`NOTICE: relation "sample_cities" already exists, skipping` to stderr: it comes from
`CREATE TABLE IF NOT EXISTS` and is harmless.

## Sample 03: SQL files

The `.sql` files under `03-migrations/sql/PG`, `sql/FB`, `sql/SQLITE`, `sql/MYSQL` (MySQL and
MariaDB) and `sql/MSSQL` are linked into the program
through `sql/MigrationsSql.res`. After editing one, rebuild the `.res` (the test script
checks it's up to date):

```
python tools/build_sql_res.py samples/03-migrations/sql samples/03-migrations/sql/MigrationsSql.res
```

Or, while developing, set `PASCALDB_SAMPLE_SQL_DIR` to the `sql` folder: the files there
are read first and the embedded copies are only the fallback. `--reset` drops the
sample's tables (`SAMPLE_PRODUCTS`, `SCHEMA_MIGRATIONS`) so every migration applies again.

## Adapter

`common/Samples.Env.pas` is the only adapter-specific unit: SQLdb on Free Pascal, FireDAC
on Delphi. Define `PASCALDB_SAMPLES_ZEOS` to use Zeos on either compiler instead (add
`adapters/zeos` and the ZeosLib source folders to the search path; on Lazarus, require
`pascal_db_faa_zeos.lpk` instead of `pascal_db_faa_sqldb.lpk`).

## Free Pascal programs

The samples do what any FPC console program using the library must do: call
`SetMultiByteConversionCodePage(CP_UTF8)` at startup and, on Unix, use `cthreads` and
`cwstring` (see "Runtime requirements for FPC applications" in `CLAUDE.md`). Source files
with non-ASCII literals are saved as UTF-8 with a BOM, so both compilers read them as
UTF-8.

## Testing the samples

`sh tools/test_samples_docker.sh` builds the samples on Linux FPC and runs them against
a PostgreSQL container (`ENGINE=firebird` for Firebird 5, `ENGINE=sqlite` for SQLite with no
server, `ENGINE=mysql` / `mariadb` for MySQL 8.4 / MariaDB 11.4, `ENGINE=sqlserver` for SQL
Server 2022, `ADAPTER=zeos` with `ZEOSDBO`
for Zeos); each must exit with 0 and report 0 unfreed
blocks.
