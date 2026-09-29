# 8. Adapters and databases

Every sample picks its adapter in one unit,
[`common/Samples.Env.pas`](../samples/common/Samples.Env.pas): the settings below side by side,
for all three adapters and the Firebird, PostgreSQL and SQLite databases.

## Choosing

| Adapter | Compilers | Unit / Lazarus package | Firebird | PostgreSQL | SQLite | MySQL / MariaDB |
|---|---|---|---|---|---|---|
| SQLdb | FPC | `PascalDb.Adapter.SQLdb` / `pascal_db_faa_sqldb.lpk` | yes | yes | yes | yes (run on Linux only, so far) |
| FireDAC | Delphi | `PascalDb.Adapter.FireDAC` (add `adapters/firedac` to the search path) | yes | yes | yes | not yet |
| Zeos (ZeosLib 8) | both | `PascalDb.Adapter.Zeos` / `pascal_db_faa_zeos.lpk` | yes | yes | yes | yes (run with FPC on Linux only, so far) |

- **One source for both compilers:** Zeos on both, or SQLdb on FPC and FireDAC on Delphi
  behind an `{$IFDEF FPC}` in the one unit that builds the factory (what the samples do by
  default). The rest of the program only sees `IDBFactory`.
- The core package is `pascal_db_faa.lpk` (Lazarus); on Delphi, add `src` to the search path.
- Which combinations were run where (compiler, bitness, OS, database version) is in the
  [README](../README.md#status). CI covers FPC on Linux; the Delphi side is run by hand.

Each adapter class is the factory: `TSQLdbFactory`, `TFDFactory`, `TZeosFactory`, all created
as `Create(AConfig, AContextTransactionProvider = nil, AOnPoolEvent = nil)`.

## Connection settings

`IDatabaseConfig.ConnectionParams` takes `Name=Value` lines, named as each driver names them.
Lines an adapter doesn't know go to the driver as they are.

| | SQLdb | FireDAC | Zeos |
|---|---|---|---|
| Driver / database kind | `ConnectorType` = `Firebird`, `PostgreSQL`, `SQLite3`, `MySQL 8.0` | `DriverID` = `FB`, `PG`, `SQLite` | `Protocol` = `firebird`, `postgresql`, `sqlite`, `mysql`, `mariadb` |
| Host, port | `HostName`, `Port` | `Server`, `Port` | `HostName`, `Port` |
| Database | `DatabaseName` | `Database` | `Database` |
| Credentials | `UserName`, `Password` | `User_Name`, `Password` | `User`, `Password` |
| Character set | `CharSet=UTF8` (MySQL: `utf8mb4`) | `CharacterSet=UTF8` | `ClientCodepage=UTF8` (MySQL: `utf8mb4`) |
| Client library path | `ClientLibrary` | `VendorLib` | `LibraryLocation` |

For Firebird on FireDAC, also `Protocol=TCPIP` for a server. `SQLDialect` on the configuration
is `Firebird`, `PostgreSQL`, `SQLite`, `MySQL` or `MariaDB`, whatever the adapter.

Always set the character set to UTF-8: that is the setting every test and sample runs with. On
MySQL and MariaDB that is `utf8mb4`: their `utf8` stores no 4-byte characters.

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
  query fail with an access violation at `$0` (gotcha 23 in [`CLAUDE.md`](../CLAUDE.md)).
- **MySQL on SQLdb: `SkipLibraryVersionCheck=true` unless the client matches the connector.**
  FPC 3.2.2's `MySQL 8.0` connector accepts only a client that reports version 8.0.x (and
  `MySQL 5.7` only 5.7.x or MariaDB 10.x). Debian's `libmariadb3` reports 3.3.19, and the first
  connection fails with `TMySQL80Connection can not work with the installed MySQL client version:
  Expected (8.0), got (3.3.19)`. With the setting, both connectors worked with it against MySQL
  8.4 and MariaDB 11.4 (gotcha 34). On Linux, set `ClientLibrary` to the versioned file
  (`libmariadb.so.3`): SQLdb looks for `libmysqlclient.so.21` by default.

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
requirements for FPC applications" in [`CLAUDE.md`](../CLAUDE.md).

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
