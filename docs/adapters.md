# 8. Adapters and databases

Every sample picks its adapter in one unit,
[`common/Samples.Env.pas`](../samples/common/Samples.Env.pas): the settings below side by side,
for all three adapters and databases.

## Choosing

| Adapter | Compilers | Unit / Lazarus package | Firebird | PostgreSQL | SQLite | MySQL / MariaDB | SQL Server |
|---|---|---|---|---|---|---|---|
| SQLdb | FPC | `PascalDb.Adapter.SQLdb` / `pascal_db_faa_sqldb.lpk` | yes | yes | yes | yes | yes (ODBC) |
| FireDAC | Delphi | `PascalDb.Adapter.FireDAC` (add `adapters/firedac` to the search path) | yes | yes | yes | yes | no (see below) |
| Zeos (ZeosLib 8) | both | `PascalDb.Adapter.Zeos` / `pascal_db_faa_zeos.lpk` | yes | yes | yes | yes | yes (ODBC) |

- **One source for both compilers:** Zeos on both, or SQLdb on FPC and FireDAC on Delphi
  behind an `{$IFDEF FPC}` in the one unit that builds the factory (what the samples do by
  default). The rest of the program only sees `IDBFactory`.
- **SQL Server on Delphi: Zeos.** FireDAC's SQL Server driver (`FireDAC.Phys.MSSQL`) is not in
  Delphi's Community Edition, which the library is tested with (only its metadata unit ships), so
  the FireDAC adapter was never run against SQL Server.
- The core package is `pascal_db_faa.lpk` (Lazarus), which requires `pascal_common_faa.lpk`
  ([pascal-common-faa](https://github.com/fabianoallex/pascal-common-faa)); on Delphi, add `src`
  and pascal-common-faa's `src` to the search path.
- Which combinations were run where (compiler, bitness, OS, database version) is in the
  [README](../README.md#status). CI covers FPC on Linux; the Delphi side is run by hand.

Each adapter class is the factory: `TSQLdbFactory`, `TFDFactory`, `TZeosFactory`, all created
as `Create(AConfig, AContextTransactionProvider = nil, AOnPoolEvent = nil)`.

## Connection settings

`IDatabaseConfig.ConnectionParams` takes `Name=Value` lines, named as each driver names them.
Lines an adapter doesn't know go to the driver as they are.

| | SQLdb | FireDAC | Zeos |
|---|---|---|---|
| Driver / database kind | `ConnectorType` = `Firebird`, `PostgreSQL`, `SQLite3`, `MySQL 5.7`, `ODBC` (SQL Server) | `DriverID` = `FB`, `PG`, `SQLite`, `MySQL` | `Protocol` = `firebird`, `postgresql`, `sqlite`, `mysql`, `mariadb`, `odbc_w` (SQL Server) |
| Host, port | `HostName`, `Port` | `Server`, `Port` | `HostName`, `Port` (SQL Server: in `Database`) |
| Database | `DatabaseName` | `Database` | `Database` (SQL Server: the ODBC connection string) |
| Credentials | `UserName`, `Password` | `User_Name`, `Password` | `User`, `Password` |
| Character set | `CharSet=UTF8` (MySQL: `utf8mb4`) | `CharacterSet=UTF8` (MySQL: `utf8mb4`) | `ClientCodepage=UTF8` (MySQL: `utf8mb4`) |
| Client library path | `ClientLibrary` | `VendorLib` | `LibraryLocation` |

For Firebird on FireDAC, also `Protocol=TCPIP` for a server. `SQLDialect` on the configuration
is `Firebird`, `PostgreSQL`, `SQLite`, `MySQL`, `MariaDB` or `SQLServer` (also `MSSQL`), whatever
the adapter.

SQL Server settings, on SQLdb:

```
ConnectorType=ODBC
Driver=ODBC Driver 18 for SQL Server
HostName=dbserver
Port=1433
DatabaseName=sales
UserName=app
Password=...
```

`HostName`/`Port` and `DatabaseName` become the ODBC connection string's `Server=host,port` and
`Database=`; any other line is a keyword of that string (e.g. `TrustServerCertificate=yes` for a
server with a self-signed certificate, `Encrypt=no`). On Zeos, `Database` *is* the connection
string (Zeos's own convention for ODBC):

```
Protocol=odbc_w
Database=DRIVER={ODBC Driver 18 for SQL Server};SERVER=dbserver,1433;DATABASE=sales
User=app
Password=...
```

The adapter adds `MARS_Connection=yes` to it unless it says otherwise.

Always set the character set to UTF-8: that is the setting every test and sample runs with. On
MySQL and MariaDB that is `utf8mb4`: their `utf8` stores no 4-byte characters. SQL Server has no
such setting: ODBC exchanges text as UTF-16, and what a column holds depends on its type (use
`NVARCHAR`, see the SQL Server notes).

## Client libraries

Firebird, PostgreSQL and MySQL/MariaDB need their client library (`fbclient`, `libpq`,
`libmysqlclient` or MariaDB Connector/C's `libmariadb`, which also talks to MySQL servers) in
every adapter; SQLite needs `sqlite3` on SQLdb and Zeos, while FireDAC links SQLite into the
program.

- **Match the program's bitness.** A 32-bit program needs a 32-bit client. PostgreSQL ships no
  32-bit client, so a Delphi program using PostgreSQL must be 64-bit.
- **Give the full path when the library isn't on the search path.** On Windows, the adapters
  load it so that its own dependencies are found in its folder (`libpq.dll` needs `libssl`,
  `libcrypto`, ... from the same folder).
- **A client library is loaded once per process.** On SQLdb the first load wins: if something
  opens a SQLdb connection directly before the factory's first connection, the default library
  is loaded and the configured one then fails. Call `PdbSQLdbUseClientLibrary` before any such
  direct use. On FireDAC, `VendorLib` is applied once per process through the driver link.
- **On Linux, give SQLdb the versioned file name for SQLite and Firebird.** The runtime packages
  install versioned names (`libsqlite3.so.0`, `libfbclient.so.2`); the unversioned
  `libsqlite3.so` that SQLdb looks for by default comes only with the `-dev` package, and its
  default Firebird names are those of a 2.5 client. Without the setting, the first connection
  fails with `Can not load SQLite client library "libsqlite3.so"` (or `Can not load default
  Firebird clients`). Set `ClientLibrary=libsqlite3.so.0` or `ClientLibrary=libfbclient.so.2`;
  PostgreSQL's `libpq.so.5` is found without it. Measured on Debian bookworm (gotcha 27); Zeos's
  default names weren't measured.
- **SQLite on Windows (SQLdb, Zeos):** the DLL must export the column-metadata functions, such
  as the official one from sqlite.org. Other builds (e.g. the one shipped with Python) make every
  query fail with an access violation at `$0` (gotcha 23 in [`gotchas.md`](gotchas.md)).
- **MySQL/MariaDB client: MariaDB Connector/C works for both servers.** On Windows, take
  `libmariadb.dll` from its installer (an administrative install, `msiexec /a`, extracts it
  without installing) and keep the `plugin` folder next to it: MySQL 8's default authentication
  (`caching_sha2_password`) is a plugin, and without it every connection to MySQL fails with
  `Plugin caching_sha2_password could not be loaded`. When the library is given by full path,
  SQLdb and Zeos point the client at that folder (`MYSQL_PLUGIN_DIR`); FireDAC has no such
  parameter, so it sets `MARIADB_PLUGIN_DIR` / `LIBMYSQL_PLUGIN_DIR` for the process, unless
  they are set already. Match the program's bitness: Connector/C ships 32- and 64-bit installers.
- **MySQL on SQLdb: `ConnectorType=MySQL 5.7` and `SkipLibraryVersionCheck=true` with MariaDB
  Connector/C.** FPC 3.2.2's connectors accept only a client that reports their own version
  (`MySQL 5.7`: 5.7.x or MariaDB 10.x); MariaDB Connector/C reports 3.x, and the first connection
  fails with `TMySQL57Connection can not work with the installed MySQL client version`. The
  setting leaves the check out (gotcha 34). `MySQL 8.0` numbers the connection options as MySQL
  8.0 does, which libmariadb doesn't: with any option set, connections fail with `Server connect
  failed` (gotcha 35). On Linux, set `ClientLibrary` to the versioned file (`libmariadb.so.3`):
  SQLdb looks for `libmysqlclient.so.20` by default.
- **SQL Server client: Microsoft's ODBC Driver 18 for SQL Server**, on SQLdb and Zeos. Windows:
  install it from Microsoft (the "SQL Server" driver that comes with Windows is a much older one);
  the driver manager, `odbc32.dll`, is part of Windows. Linux: the `msodbcsql18` package from
  Microsoft's repository, with unixODBC (`unixodbc`); `ClientLibrary`/`LibraryLocation` names the
  driver manager, `libodbc.so.2` (SQLdb uses that name by default on Unix; it looks for
  `libodbc.so`, which only the `-dev` package creates, otherwise). Installing the driver means
  accepting Microsoft's license. FreeTDS (the db-lib connectors: SQLdb's `MSSQLServer`, Zeos's
  `mssql`) is not supported: with SQLdb, errors on two connections at the same moment corrupted the
  heap; with Zeos, `DATETIME2` couldn't be read and date-times lost their milliseconds (both
  measured, see the adapter units).

## SQLite notes

- The database is a file, created on the first connect. Don't use `:memory:`: each pooled
  connection would get its own empty database.
- SQLite allows one writer at a time. Every adapter sets a busy timeout (5000 ms unless the
  settings say otherwise), so a second writer waits instead of failing at once with "database is
  locked".
- FireDAC needs `LockingMode=Normal`, `SharedCache=False`, `StringFormat=Unicode` and a busy
  timeout to share a file across a pool; the adapter sets them unless the settings do (gotcha 25).
- Types are loose: a `NUMERIC(15,2)` is stored as a floating-point `REAL`, so money keeps a
  `Double`'s precision, not an exact decimal.
- `CREATE TABLE IF NOT EXISTS`, `RETURNING`, savepoints and transactional DDL all work.

## MySQL and MariaDB notes

- One SQL dialect for both (`SQLDialect` = `MySQL` or `MariaDB`: the same class).
- **MySQL has no `INSERT ... RETURNING`** (MariaDB has it since 10.5). Read a generated key back
  with `SELECT LAST_INSERT_ID()` in the same transaction, or give the key yourself.
- **DDL isn't transactional:** every `CREATE`/`ALTER`/`DROP` commits the transaction it runs in.
  Mark such migrations `IsDDL: True` ([guide 7](migrations.md)), as on Firebird.
- **Table names are case-sensitive on Linux** (`lower_case_table_names=0`) and not on Windows:
  write each table name the same way everywhere. The migrations table is `SCHEMA_MIGRATIONS`.
- `DATETIME` and `TIMESTAMP` keep whole seconds unless declared with a precision: `DATETIME(3)`
  for milliseconds. `DECIMAL` is exact.
- A backslash is an escape character inside string literals (unless the server runs with
  `NO_BACKSLASH_ESCAPES`), and SQLdb's connector escapes parameter values that way.
- An expired lock wait (`LockTimeoutMs`) undoes only the statement, not the transaction; roll the
  transaction back anyway, as on the other databases.

## SQL Server notes

- One SQL dialect: `SQLServer` (also registered as `MSSQL`). Tested with SQL Server 2022.
- **Text: `NVARCHAR`, and `N'...'` for literals.** A `VARCHAR` holds only its collation's code
  page (1252 by default): `'São Paulo → ok'` comes back as `'São Paulo ? ok'`. Parameters are sent
  as Unicode either way.
- **`TIMESTAMP` is not a date** in SQL Server (it's a row version): use `DATETIME2` (`DATETIME2(3)`
  keeps milliseconds exactly; the older `DATETIME` rounds them to 1/300 s).
- **No `RETURNING`: `INSERT ... OUTPUT INSERTED.ID, ...`** returns the new row, through `Open`, as
  `RETURNING` does elsewhere.
- **No `CREATE TABLE IF NOT EXISTS`:** `IF OBJECT_ID('NAME', 'U') IS NULL CREATE TABLE ...`. In
  `ALTER TABLE`, `ADD` takes no `COLUMN`.
- Savepoints exist but can't be released: a nested scope that commits keeps its savepoint until the
  transaction ends (`SupportsRelease` is `False`); rolling back to it works as elsewhere.
- DDL is transactional, as on PostgreSQL. A `UNIQUE` column accepts a single `NULL`.
- `LockTimeoutMs` is `SET LOCK_TIMEOUT` (milliseconds) on every connection; errors 1222 (lock
  request time out) and 1205 (deadlock victim) become `ELockConflictException`. By default (0) a
  statement waits for a lock forever.
- **A `SET` run through a query doesn't stay on SQLdb:** its ODBC connector prepares every
  statement, the driver runs a prepared statement as a procedure, and SQL Server undoes a `SET`
  when a procedure returns (measured with `SET LOCK_TIMEOUT`, which is why the adapter applies it
  outside SQLdb). Zeos runs it directly.
- The ODBC session has the ANSI options on (`ANSI_NULLS`, `ANSI_WARNINGS`, a column declared
  without `NULL` accepts NULLs, ...), as in any ODBC or OLE DB program; `ARITHABORT` is off.
- SQLdb reads a `NUMERIC`/`DECIMAL` column as a floating-point field, so `Currencies[...]` goes
  through a `Double` (exact for amounts that fit 15 digits); Zeos reads it as a decimal.

## Adapter-specific behavior you may notice

- Every adapter fetches the whole result on `Open`, so `RecordCount` is exact.
- SQLdb closes a transaction's datasets on `Commit` / `Rollback`: read results first (the usual
  pattern does).
- Zeos on Firebird uses hard commits (`hard_commit=true`) unless the settings say otherwise;
  without it a `Commit` after an `INSERT ... RETURNING` could loop forever (gotcha 16).
- Zeos and FireDAC on Firebird don't wait for a row another transaction holds: the statement
  fails at once with `ELockConflictException`, where SQLdb and PostgreSQL wait until the lock is
  released.
  `LockTimeoutMs` makes every adapter wait up to the same limit
  ([guide 6](errors.md#locks-and-conflicts-elockconflictexception); gotcha 32).
- On Delphi, the adapters bind strings as Unicode; a plain `AsString` on a FireDAC or Data.DB
  parameter would turn characters outside the ANSI code page into `?` (gotcha 13).
- A batch (`IBatch`) goes to the database as FireDAC's Array DML, one operation per send; SQLdb
  and Zeos run it one `ExecSql` per row. Same results, very different speed over a network
  ([guide 2](sql.md#batches-ibatch); gotcha 44).

## What a Free Pascal program must do

In FPC's `{$MODE DELPHI}`, `string` is an 8-bit string in the process's code page, so an FPC
program using the library must:

1. **Run with UTF-8 as the default code page.** Console and service programs call, at startup:

   ```pascal
   {$IFDEF FPC}
   SetMultiByteConversionCodePage(CP_UTF8);
   {$ENDIF}
   ```

   LCL (GUI) applications already run in UTF-8. Without it, non-ASCII text outside the code page
   becomes `?`; SQL sources raise `ESqlSourceException` rather than corrupt a statement.

2. **On Unix, put `cthreads` and `cwstring` first in the program's `uses`:**

   ```pascal
   uses
     {$IFDEF UNIX}
     cthreads,
     cwstring,
     {$ENDIF}
     SysUtils, ...
   ```

   `cthreads` is needed by the pool (it uses threads and locks). Without `cwstring`, a
   `Variant` holding a non-ASCII `WideString` comes back as invalid UTF-8.

3. Save source files with non-ASCII literals as **UTF-8 with a BOM**, so both compilers read
   them as UTF-8.

Delphi needs none of this: its `string` is UTF-16. Details and measurements: "Runtime
requirements for FPC applications" in [`gotchas.md`](gotchas.md).

## Another driver

An adapter implements `IDBComponentProvider` (connection, transaction, query, script), usually on
top of `PascalDb.Adapter.Base` and `PascalDb.Adapter.DataSet`, which already hold everything
that isn't driver-specific: most of each existing adapter is its driver's quirks. The integration
contract suite (`tests/Integration`) is what tells whether a new adapter behaves like the
others. [Guide 9](writing-an-adapter.md) walks through it, with a skeleton.

## Another database

A database other than the ones above needs an SQL dialect registered by the program and the
driver's unit linked in; the adapters pass other drivers through.
[Guide 10](other-databases.md) covers it, and how to check it with the contract suite.
