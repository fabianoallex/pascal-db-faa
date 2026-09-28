# 9. Writing an adapter

An adapter connects the library to one database access component (UniDAC, IBX, ADO,
dbExpress, a native client, ...). The core never changes for a new one: the adapter implements
`IDBComponentProvider`, and everything above it (pool, transactions and savepoints, SQL loader,
migrations, optional parameters, error classification) comes from the library.

Read an existing adapter next to this guide:

- [`adapters/sqldb/PascalDb.Adapter.SQLdb.pas`](../adapters/sqldb/PascalDb.Adapter.SQLdb.pas):
  the simplest, a `TDataSet` component with Data.DB `TParams`;
- [`adapters/zeos/PascalDb.Adapter.Zeos.pas`](../adapters/zeos/PascalDb.Adapter.Zeos.pas):
  both compilers, and parameters that aren't Data.DB's;
- [`adapters/firedac/PascalDb.Adapter.FireDAC.pas`](../adapters/firedac/PascalDb.Adapter.FireDAC.pas):
  Delphi only.

Each is 500 to 600 lines. The skeleton below is about 150; the rest of each adapter is its
driver's quirks, found by running the contract suite ([below](#checking-it-the-contract-suite)).

## The pieces

| You write | Based on | What it wraps |
|---|---|---|
| a connection | `IDBConnection` (implement it directly) | the component's connection |
| a transaction | `TTransactionBase` (`PascalDb.Adapter.Base`) | the component's transaction |
| a query | `TDataSetQueryBase` (`PascalDb.Adapter.DataSet`), or `IQuery` + `IQueryResult` directly | the component's query |
| parameters, only if they aren't Data.DB's `TParams` | `TParamsBase` (`PascalDb.Adapter.Base`) | the query's parameter collection |
| a provider | `IDBComponentProvider` | builds the four above |
| a factory | `TDBFactory` (`PascalDb.Adapter.Base`) | passes the provider; users create this class |

What the base classes already do, so the adapter doesn't:

- `TTransactionBase` keeps the in-transaction state and sends every failure of `StartTransaction`,
  `Commit`, `Rollback` and `ExecSql` through `BuildDatabaseException`, which decides between
  "connection lost" (`EDatabaseUnavailableException`, connection discarded) and "data error"
  (the driver's exception, connection kept).
- `TScopeTransaction` implements nested scopes with savepoints from the SQL dialect.
- `TSqlScript` splits a script and runs each statement through `ITransaction.ExecSql`.
- `TParamsBase` implements every `Strings`/`NullStrings`/`OptStrings`/`OptNullStrings`/... setter
  and getter on top of a few primitives. `TDBParams` implements those primitives over a Data.DB
  `TParams`, binding strings as Unicode on Delphi (`ftWideString`).
- `TDataSetQueryBase` implements `IQuery` and `IQueryResult` over any `TDataSet`: setting SQL,
  starting the transaction before `Open`, every typed and nullable getter, `Eof`/`Next`,
  `RecordCount`.
- `TDBFactory` builds the pool and the SQL loader from the configuration, and `TestConnection`
  runs the dialect's ping.
- The pool wraps connections and queries, so the query wrapper also classifies failures of
  `Open`, `ExecSql` and field reads.

## Skeleton (a `TDataSet` component)

`TXyzConnection`, `TXyzTransaction`, `TXyzQuery` and their properties stand for your
component's classes.

```pascal
unit PascalDb.Adapter.Xyz;

{$I pascaldb.inc}

interface

uses
  Classes, SysUtils, DB,
  XyzComponents,                 // your component's units
  PascalDb.Interfaces, PascalDb.SqlDialect, PascalDb.Pool,
  PascalDb.Adapter.Base, PascalDb.Adapter.DataSet;

type
  TXyzConnectionAdapter = class(TInterfacedObject, IDBConnection)
  private
    FConnection: TXyzConnection;
    FSQLDialect: ISQLDialect;
  public
    constructor Create(AConnection: TXyzConnection; const ASQLDialect: ISQLDialect);
    destructor Destroy; override;
    function GetNativeConnection: TObject;
    function IsConnected: Boolean;
    procedure Connect;
    procedure Disconnect(Force: Boolean = False);
    procedure Commit;     // no-op: transactions go through ITransaction
    procedure Rollback;   // no-op
    function GetSQLDialect: ISQLDialect;
  end;

  TXyzTransactionAdapter = class(TTransactionBase)
  private
    FTransaction: TXyzTransaction;
  protected
    procedure DoStartTransaction; override;
    procedure DoCommit; override;
    procedure DoRollback; override;
    procedure DoExecSql(const ASql: string); override;
  public
    constructor Create(const AConn: IDBConnection);
    destructor Destroy; override;
    function GetNativeTransaction: TObject; override;
  end;

  TXyzQueryAdapter = class(TDataSetQueryBase)
  private
    FQuery: TXyzQuery;
  protected
    function DataSet: TDataSet; override;
    function SqlLines: TStrings; override;
    procedure DoExecSql; override;
    procedure DoClearParams; override;
    function ResetParamValues: Boolean; override;  // optional, see below
    function CreateParams: IParams; override;
  public
    constructor Create(const AConn: IDBConnection; const ATransaction: ITransaction);
    destructor Destroy; override;
  end;

  TXyzProvider = class(TInterfacedObject, IDBComponentProvider)
  public
    function BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
    function BuildTransaction(AConn: IDBConnection): ITransaction;
    function BuildScopeTransaction(ATransaction: ITransaction;
      AContextTransaction: IContextTransaction): IScopeTransaction;
    function BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
  end;

  TXyzFactory = class(TDBFactory)
  public
    constructor Create(const AConfig: IDatabaseConfig;
      const AContextTransactionProvider: IContextTransactionProvider = nil;
      AOnPoolEvent: TPoolEventProc = nil);
  end;

implementation

{ TXyzConnectionAdapter }

constructor TXyzConnectionAdapter.Create(AConnection: TXyzConnection; const ASQLDialect: ISQLDialect);
begin
  inherited Create;
  FConnection := AConnection;   // owned
  FSQLDialect := ASQLDialect;
end;

destructor TXyzConnectionAdapter.Destroy;
begin
  FConnection.Free;
  inherited Destroy;
end;

function TXyzConnectionAdapter.GetNativeConnection: TObject;
begin
  Result := FConnection;
end;

function TXyzConnectionAdapter.IsConnected: Boolean;
begin
  Result := FConnection.Connected;   // must turn False when the server is gone (see below)
end;

procedure TXyzConnectionAdapter.Connect;
begin
  FConnection.Connected := True;
end;

procedure TXyzConnectionAdapter.Disconnect(Force: Boolean);
begin
  FConnection.Connected := False;
end;

procedure TXyzConnectionAdapter.Commit;
begin
end;

procedure TXyzConnectionAdapter.Rollback;
begin
end;

function TXyzConnectionAdapter.GetSQLDialect: ISQLDialect;
begin
  Result := FSQLDialect;
end;

{ TXyzTransactionAdapter }

constructor TXyzTransactionAdapter.Create(const AConn: IDBConnection);
begin
  inherited Create(AConn);
  FTransaction := TXyzTransaction.Create(nil);
  FTransaction.Connection := AConn.GetNativeConnection as TXyzConnection;
end;

destructor TXyzTransactionAdapter.Destroy;
begin
  if FTransaction.Active then
    FTransaction.Rollback;
  FTransaction.Free;
  inherited Destroy;
end;

procedure TXyzTransactionAdapter.DoStartTransaction;
begin
  if not FTransaction.Active then
    FTransaction.StartTransaction;
end;

procedure TXyzTransactionAdapter.DoCommit;
begin
  if FTransaction.Active then
    FTransaction.Commit;
end;

procedure TXyzTransactionAdapter.DoRollback;
begin
  if FTransaction.Active then
    FTransaction.Rollback;
end;

// Runs SQL with no parameters and no result (savepoints, script statements).
procedure TXyzTransactionAdapter.DoExecSql(const ASql: string);
var
  LQuery: TXyzQuery;
begin
  LQuery := TXyzQuery.Create(nil);
  try
    LQuery.Connection := FTransaction.Connection;
    LQuery.Transaction := FTransaction;
    LQuery.ParamCheck := False;   // the text may contain ':' that isn't a parameter
    LQuery.SQL.Text := ASql;
    LQuery.ExecSQL;
  finally
    LQuery.Free;
  end;
end;

function TXyzTransactionAdapter.GetNativeTransaction: TObject;
begin
  Result := FTransaction;
end;

{ TXyzQueryAdapter }

constructor TXyzQueryAdapter.Create(const AConn: IDBConnection; const ATransaction: ITransaction);
begin
  inherited Create(AConn, ATransaction);
  FQuery := TXyzQuery.Create(nil);
  FQuery.Connection := AConn.GetNativeConnection as TXyzConnection;
  FQuery.Transaction := ATransaction.GetNativeTransaction as TXyzTransaction;
  FQuery.FetchAll := True;   // whatever makes Open fetch every row (see below)
end;

destructor TXyzQueryAdapter.Destroy;
begin
  FQuery.Free;
  inherited Destroy;
end;

function TXyzQueryAdapter.DataSet: TDataSet;
begin
  Result := FQuery;
end;

function TXyzQueryAdapter.SqlLines: TStrings;
begin
  Result := FQuery.SQL;
end;

procedure TXyzQueryAdapter.DoExecSql;
begin
  FQuery.ExecSQL;
end;

procedure TXyzQueryAdapter.DoClearParams;
begin
  FQuery.Params.Clear;
end;

// Optional. Called when IQuery.Sql is set to the text it already has (a loop that sets the
// SQL on every iteration): clear the values, keep the parameters, and the driver keeps the
// statement prepared. Without the override, the query is reset as for new SQL.
function TXyzQueryAdapter.ResetParamValues: Boolean;
var
  I: Integer;
begin
  for I := 0 to FQuery.Params.Count - 1 do
    FQuery.Params[I].Clear;
  Result := True;
end;

function TXyzQueryAdapter.CreateParams: IParams;
begin
  Result := TDBParams.Create(FQuery.Params);   // Data.DB TParams; otherwise your TParamsBase
end;

{ TXyzProvider }

function TXyzProvider.BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
var
  LConn: TXyzConnection;
  LParams: TStrings;
begin
  LParams := AConfig.ConnectionParams;
  LConn := TXyzConnection.Create(nil);
  try
    LConn.LoginPrompt := False;
    LConn.Server := LParams.Values['Server'];      // the names are yours: document them
    LConn.Database := LParams.Values['Database'];
    LConn.UserName := LParams.Values['UserName'];
    LConn.Password := LParams.Values['Password'];
    LConn.Connected := True;                         // the pool expects an open connection
  except
    LConn.Free;
    raise;
  end;
  Result := TXyzConnectionAdapter.Create(LConn, TSQLDialectFactory.GetDialect(AConfig.SQLDialect));
end;

function TXyzProvider.BuildTransaction(AConn: IDBConnection): ITransaction;
begin
  Result := TXyzTransactionAdapter.Create(AConn);
end;

function TXyzProvider.BuildScopeTransaction(ATransaction: ITransaction;
  AContextTransaction: IContextTransaction): IScopeTransaction;
begin
  Result := TScopeTransaction.Create(ATransaction, AContextTransaction);
end;

function TXyzProvider.BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
begin
  Result := TXyzQueryAdapter.Create(AConn, ATransaction);
end;

function TXyzProvider.BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
begin
  Result := TSqlScript.Create(AConn, ATransaction);
end;

{ TXyzFactory }

constructor TXyzFactory.Create(const AConfig: IDatabaseConfig;
  const AContextTransactionProvider: IContextTransactionProvider; AOnPoolEvent: TPoolEventProc);
begin
  inherited Create(AConfig, TXyzProvider.Create, AContextTransactionProvider, AOnPoolEvent);
end;

end.
```

Users then create it like any other factory ([guide 1](getting-started.md)):
`LFactory := TXyzFactory.Create(LConfig);`.

### A component without `TDataSet`

Implement `IQuery` and `IQueryResult` yourself instead of deriving from `TDataSetQueryBase`,
and still derive the parameters from `TParamsBase`: it only needs `ParamExists`, `ParamIsNull`,
`WriteNull` and one `ReadXxx`/`WriteXxx` pair per type (string, Boolean, date-time, Double,
Integer, Int64, Currency). `TDataSetQueryBase` is the reference for what each `IQueryResult`
getter returns: the plain getters read NULL as `''` / `0` / `False`, the `Nullable...` ones
return an `INullXxx`.

### A new database

The dialect is looked up by `IDatabaseConfig.SQLDialect`: `Firebird`, `PostgreSQL` and `SQLite`
are built in. For another database, write one class implementing both `ISQLDialect` (savepoint
statements, whether `RELEASE SAVEPOINT` exists, a ping query) and `IMigrationDialect` (the
queries on the migrations table; without it, the migration engine refuses to run), and register
it once at startup, before creating the factory:

```pascal
TSQLDialectFactory.RegisterDialect('MyDb', TMyDbDialect);
```

`PascalDb.SqlDialect` has the three built-in dialects to copy from; [guide 10](other-databases.md)
describes each method and what else tends to differ between databases.

## What the rest of the library relies on

Each of these was a real defect in one of the existing adapters, found by the contract suite.
Check them against your component's documentation, then let the suite confirm.

- **`IsConnected` must tell the truth after a failure.** When an operation fails, the library
  asks `IsConnected`: `False` means the connection is lost (it is discarded, and the caller gets
  `EDatabaseUnavailableException`); `True` means a data error (the connection goes back to the
  pool). A component that keeps reporting `True` after the server went away gets its dead
  connection reused.
- **`BuildConnection` returns an open connection**, and raises the driver's exception when it
  can't open one; the pool reports that to the caller as `EDatabaseConnectException`, with the
  driver's class and text in `OriginalClassName` / `OriginalMessage` ([guide 6](errors.md)).
- **`Commit` must end the transaction.** Some components commit "retaining" (the transaction
  stays open) under some conditions, and some turn a `StartTransaction` on an already open
  transaction into a savepoint, whose `Commit` only releases it. Zeos does both (see its unit
  header); the library needs a real start and a real commit.
- **`Open` must fetch every row.** `RecordCount` has to be exact, and committing must not leave a
  half-read cursor behind: SQLdb `PacketRecords = -1`, FireDAC `FetchOptions.Mode = fmAll`,
  Zeos `FetchAll`.
- **Read before commit is enough.** SQLdb closes the transaction's datasets on commit; that is
  fine because the usage pattern reads first, but a component that invalidates results earlier
  would not be.
- **Strings are Unicode.** On Delphi, a Data.DB or FireDAC parameter set with `AsString` is ANSI
  (`ftString`), and characters outside the code page arrive as `?`. `TDBParams` already uses
  `ftWideString`; a `TParamsBase` of your own must do the same (gotcha 13 in
  [`CLAUDE.md`](../CLAUDE.md)). Set the connection's character set to UTF-8.
- **Setting the same SQL text again must rebind parameters.** `TDataSetQueryBase.SetSql` clears
  the SQL before assigning it, because Zeos skipped re-parsing an unchanged text and the cleared
  parameters never came back (gotcha 17). A query written from scratch needs the same care.
- **Never re-raise an exception object by reference** (`raise E;`) from outside the `except`
  block that caught it: raise a new exception or use a bare `raise;`. On Delphi, the first form
  caused access violations; the comments in `PascalDb.Pool` explain it.
- **Client libraries load once per process.** If your component loads the client library
  globally, the first load wins; on Windows, a library given by full path may not find its own
  dependencies. `PdbPreloadClientLibrary` (`PascalDb.Adapter.Base`) solves the second
  (gotcha 14).
- **SQLite needs a busy timeout.** With a pool, several connections write to the same file; with
  no busy timeout, the second writer fails at once with "database is locked" (gotcha 24). Every
  existing adapter sets one (5000 ms by default).
- **Dual-compiler:** if the component exists for both Delphi and Lazarus, keep the unit free of
  compiler-specific code where you can (Zeos's adapter is the example), and check
  [what a Free Pascal program must do](adapters.md#what-a-free-pascal-program-must-do).

## Checking it: the contract suite

`tests/Integration/PascalDb.ContractTests.pas` is the same suite for every adapter: 16 tests,
from the ping to typed parameters and NULLs, UTF-8 text, `INSERT ... RETURNING`, commit and
rollback, savepoints, a constraint violation that keeps the connection, scripts, exact
`RecordCount`, the same SQL assigned twice and concurrent writers. The tests only see an
`IDBFactory`; the adapter-specific part lives in one unit.

1. In `tests/Integration/PascalDb.IntegrationEnv.pas`, add a `{$IF DEFINED(PASCALDB_IT_XYZ)}`
   block next to the existing ones with four routines: `SetConnectionParams` (your settings for
   the test database), `CreateDatabase` and `DropDatabase` (a fresh database per run), and
   `NewFactory` (returns your `TXyzFactory`). Add your unit to its `uses` under the same define.
2. Add a runner that defines `PASCALDB_IT_XYZ`: copy `PascalDb.IntegrationTestsZeos.dpr`/`.dproj`
   (Delphi) or `tests/Integration/fpc-zeos` (Lazarus) and swap the adapter unit.
3. Run it on every database the component supports (`PASCALDB_IT_ENGINE=firebird`,
   `postgresql` or `sqlite`; the other settings are in the unit's header), on each compiler
   and bitness you target. Acceptance, as for the existing adapters: every test green and no
   memory leaks (FastMM on Delphi, heaptrc on FPC).

The suite runs single-threaded (except the concurrent writers) and against a server that stays
up. What it doesn't cover:

- a connection lost in the middle of an operation;
- many threads sharing the pool.

Sample [`05-pool`](../samples/05-pool/PoolUnderLoad.dpr) exercises the second: point
`Samples.Env` at your adapter and run it. For the first, stop the server while a program holds
connections, and check that the next operation raises `EDatabaseUnavailableException` and the
pool recovers once the server is back.
