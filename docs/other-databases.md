# 10. Using another database

Firebird, PostgreSQL, SQLite, MySQL, MariaDB and SQL Server are the databases the library
supports: each one passes the integration contract suite on every adapter that can reach it
(SQL Server: SQLdb and Zeos, [guide 8](adapters.md#sql-server-notes)), and CI runs it on every
push. Another database (Oracle, ...) goes through the same parts without changing the library, but
nothing here has been run against it: the contract suite is how you find out whether it works,
and this guide ends with how to run it.

You need three things: an SQL dialect, the driver for that database in your adapter, and a
folder with your SQL for it.

## 1. An SQL dialect

The dialect is the SQL the library generates by itself: savepoints for nested scopes, the ping
that checks an idle pooled connection, the queries on the migrations table and the paging clause.
The rest of your business SQL never goes through it. Write one class and register it once at
startup, before creating the factory:

```pascal
type
  TMyDbDialect = class(TInterfacedObject, ISQLDialect, IMigrationDialect, IPagingDialect)
  public
    // ISQLDialect
    function GetSavepointSQL(const AName: string): string;
    function GetRollbackToSavepointSQL(const AName: string): string;
    function GetReleaseSavepointSQL(const AName: string): string;
    function SupportsRelease: Boolean;
    function GetPingSQL: string;
    // IMigrationDialect (only if you run migrations)
    function GetMigrationTableExistsSQL: string;
    function GetMigrationLastVersionSQL: string;
    function GetMigrationInsertVersionSQL: string;
    // IPagingDialect (only if you page queries)
    function GetPagingClause(ALimit: Integer; AOffset: Int64): string;
  end;

// in the program's start-up code
TSQLDialectFactory.RegisterDialect('MyDb', TMyDbDialect);
LConfig.SQLDialect := 'MyDb';
```

| Method | Returns | Notes |
|---|---|---|
| `GetSavepointSQL`, `GetRollbackToSavepointSQL` | the statement that creates / rolls back to savepoint `AName` | the built-in dialects end them with `;`; some drivers reject a trailing `;`, so leave it out unless yours needs it |
| `SupportsRelease`, `GetReleaseSavepointSQL` | whether the database has `RELEASE SAVEPOINT`, and the statement | with `False`, a nested scope's commit issues nothing |
| `GetPingSQL` | the cheapest statement that reaches the server | e.g. `SELECT 1`, or `SELECT 1 FROM <a one-row table>` where a `SELECT` needs a `FROM` |
| `GetMigrationTableExistsSQL` | one row, column `EXISTS` = 1 or 0: whether `SCHEMA_MIGRATIONS` exists | a query on the database's catalog. `EXISTS` is a reserved word in most databases: quote the alias |
| `GetMigrationLastVersionSQL` | one row, column `VERSION`: the highest applied version, 0 when empty | `SELECT COALESCE(MAX(VERSION), 0) AS VERSION FROM SCHEMA_MIGRATIONS` is standard SQL |
| `GetMigrationInsertVersionSQL` | an `INSERT` into `SCHEMA_MIGRATIONS` with the named parameter `:VERSION` | |
| `GetPagingClause` | the clause, placed after `ORDER BY`, that returns at most `ALimit` rows after skipping `AOffset` | `LIMIT n OFFSET m` where the database has it; without `IPagingDialect`, `PdbPagingClause` raises `EArgumentException` ([guide 2](sql.md#paging)) |

`src/PascalDb.SqlDialect.pas` has the built-in dialects to copy from. Names are matched
ignoring case; registering a name that is already there raises `EArgumentException`, and so
does creating a factory whose `SQLDialect` isn't registered (the message lists the registered
ones).

## 2. The driver

| Adapter | What your program does |
|---|---|
| Zeos | `Protocol=<the Zeos protocol>` in `ConnectionParams`. The adapter passes any protocol through; its other settings (`HostName`, `Database`, `LibraryLocation`, ...) work as for the tested databases. |
| FireDAC | Add the driver's unit to the program's `uses` (e.g. `FireDAC.Phys.Oracle`) and set `DriverID` to it. `VendorLib` in `ConnectionParams` is only applied for FB and PG: for another driver, leave it out and set `VendorLib` on that driver's link (e.g. `TFDPhysOracleDriverLink`) in your program before the first connection. Check that your Delphi edition includes the driver. |
| SQLdb | Add the connector's unit to the program's `uses` (e.g. `oracleconnection`, `mssqlconn`, `mysql80conn`) and set `ConnectorType` to the name it registers. `ClientLibrary` works for any connector that has a library loader. |

The library's own code doesn't depend on the database: the pool, transactions, parameters and
error classification (a lost connection is recognized by `IsConnected`, not by an error code)
are the same for every driver. What changes is how the driver and the database behave, below.

## 3. Your SQL

Point `SQLDirectory` at a folder with your SQL written for that database
([guide 2](sql.md)). The three settings are independent:

```pascal
LConfig.ConnectionParams.Values['Protocol'] := 'mydb';  // the driver
LConfig.SQLDialect := 'MyDb';                           // the SQL the library generates
LConfig.SQLDirectory := 'MYDB';                         // the folder of your SQL
```

## What tends to differ

Each item is something the contract suite checks, and something that differs between databases
in general. None of them was measured here on a database other than the three supported ones.

- **Transactional DDL.** Where DDL commits the transaction by itself (as in Firebird), a
  migration with DDL needs `IsDDL = True` ([guide 4](migrations.md)); it is portable to set it
  anyway.
- **`INSERT ... RETURNING`.** Some databases return the values as a result set (what the
  library expects when you `Open` the statement), others only through output parameters
  (`RETURNING ... INTO`), others have their own syntax (`OUTPUT INSERTED.*`) or none.
- **Empty string and NULL.** Where `''` is stored as NULL, an `IOptNullString` holding `''`
  reads back as Null.
- **Types.** A Boolean column may not exist (a `SMALLINT` or `NUMBER(1)` flag reads as a Boolean
  through the DataSet adapters, since booleans convert through Variant); `NUMERIC` may be stored
  as floating point (as in SQLite); `BIGINT` may be spelled otherwise.
- **Text encoding.** The connection character set and the column types decide whether non-ASCII
  text survives; on Delphi, see gotcha 13 in [`gotchas.md`](gotchas.md).
- **Parameters in the SQL text.** How the driver finds `:NAME` can depend on the database's
  quoting rules (gotcha 26: SQLdb loses parameters after a `'\'` on some connectors).
- **Concurrency.** Locking and waiting for a lock differ; `ConcurrentWriters_AllCommit` checks
  that concurrent writers wait instead of failing at once.

## Checking it: the contract suite

The suite (`tests/Integration/PascalDb.ContractTests.pas`, 24 tests) only uses `IDBFactory`;
everything database-specific lives in `tests/Integration/PascalDb.IntegrationEnv.pas`. To run
it against another database:

1. In `PascalDb.IntegrationEnv.pas`, add the engine to `TEngine` and to the
   `PASCALDB_IT_ENGINE` parsing, and give it a branch in each routine that switches on the
   engine: the defaults (`DatabaseName`, `UserName`, `Password`, `ClientLibrary`), the schema
   in `BuildSqlSource` (change the column types if the database spells them differently, and
   keep the column names), `SetConnectionParams` for your adapter, and `CreateDatabase` /
   `DropDatabase`. Where the database has no "create database" (Oracle, for one), create and
   drop a user or schema instead: each run needs a fresh, empty one.
2. Set `BuildConfig`'s `SQLDialect` to your dialect's name, and register the dialect before
   the factory is created (in `IntegrationFactory`, or in the runner).
3. Run the runner of the adapter you use with `PASCALDB_IT_ENGINE` set to your engine, on each
   compiler and bitness you target. Acceptance, as for the supported databases: every test
   green and no memory leaks (FastMM on Delphi, heaptrc on FPC).

A failing test is either a difference to handle in your SQL or dialect (most of the list above),
or a driver quirk the adapter should handle, as the existing adapters do for the three supported
databases (their unit headers and the gotchas in [`gotchas.md`](gotchas.md) record each one).
If you get the suite green on another database, the dialect and the environment changes are
welcome as a contribution: that is how a database becomes supported.
