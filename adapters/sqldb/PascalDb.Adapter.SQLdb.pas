unit PascalDb.Adapter.SQLdb;

{$I pascaldb.inc}

{ SQLdb adapter (Free Pascal / Lazarus only): IDBFactory over TSQLConnector,
  TSQLTransaction and TSQLQuery. Everything that isn't SQLdb-specific comes
  from PascalDb.Adapter.Base / PascalDb.Adapter.DataSet.

  Connection settings (IDatabaseConfig.ConnectionParams, Name=Value):
    ConnectorType  SQLdb connector name: 'Firebird' or 'PostgreSQL'
                   (required; both are registered by this unit)
    HostName       server host ('' = local/embedded, Firebird)
    Port           server port (optional)
    DatabaseName   database path (Firebird) or name (PostgreSQL)
    UserName, Password
    CharSet        connection character set (e.g. UTF8)
    ClientLibrary  full path of the client library (fbclient/libpq) when it
                   isn't found on the default search path (optional)
  Any other line is passed to the connection's Params as is.

  SQLdb specifics handled here:
  - PacketRecords = -1: the whole result is fetched on Open, so RecordCount
    is the real row count (SQLdb otherwise counts only fetched rows).
  - SQLdb starts the native transaction by itself when a query opens, so
    DoStartTransaction only starts it if it isn't active yet.
  - TSQLTransaction.Commit/Rollback close the datasets attached to it: read
    the results before committing (the usual repository pattern). }

interface

{$IFNDEF FPC}
  {$MESSAGE ERROR 'PascalDb.Adapter.SQLdb is for Free Pascal only; use PascalDb.Adapter.FireDAC or PascalDb.Adapter.Zeos on Delphi'}
{$ENDIF}

uses
  Classes,
  SysUtils,
  DB,
  sqldb,
  sqldblib,
  ibconnection,
  pqconnection,
  PascalDb.Interfaces,
  PascalDb.SqlDialect,
  PascalDb.Pool,
  PascalDb.Adapter.Base,
  PascalDb.Adapter.DataSet;

type
  { TSQLdbConnectionAdapter }

  TSQLdbConnectionAdapter = class(TInterfacedObject, IDBConnection)
  private
    FConnection: TSQLConnector;
    FSQLDialect: ISQLDialect;
  public
    /// Takes ownership of AConnection.
    constructor Create(AConnection: TSQLConnector; const ASQLDialect: ISQLDialect);
    destructor Destroy; override;
    function GetNativeConnection: TObject;
    function IsConnected: Boolean;
    procedure Connect;
    /// Transactions are managed through ITransaction; no-op here.
    procedure Commit;
    /// Transactions are managed through ITransaction; no-op here.
    procedure Rollback;
    procedure Disconnect(Force: Boolean = False);
    function GetSQLDialect: ISQLDialect;
  end;

  { TSQLdbTransactionAdapter }

  TSQLdbTransactionAdapter = class(TTransactionBase)
  private
    FTransaction: TSQLTransaction;
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

  { TSQLdbQueryAdapter }

  TSQLdbQueryAdapter = class(TDataSetQueryBase)
  private
    FQuery: TSQLQuery;
  protected
    function DataSet: TDataSet; override;
    function SqlLines: TStrings; override;
    procedure DoExecSql; override;
    procedure DoClearParams; override;
    function CreateParams: IParams; override;
  public
    constructor Create(const AConn: IDBConnection; const ATransaction: ITransaction);
    destructor Destroy; override;
  end;

  { TSQLdbProvider }

  TSQLdbProvider = class(TInterfacedObject, IDBComponentProvider)
  public
    function BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
    function BuildTransaction(AConn: IDBConnection): ITransaction;
    function BuildScopeTransaction(ATransaction: ITransaction; AContextTransaction: IContextTransaction): IScopeTransaction;
    function BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
  end;

  { TSQLdbFactory }

  TSQLdbFactory = class(TDBFactory)
  public
    constructor Create(const AConfig: IDatabaseConfig;
      const AContextTransactionProvider: IContextTransactionProvider = nil;
      AOnPoolEvent: TPoolEventProc = nil);
  end;

/// Loads the client library of AConnectorType ('Firebird', 'PostgreSQL')
/// from ALibrary, once per process. SQLdb loads a client library globally and
/// the first load wins: any SQLdb connection opened before this (e.g. a
/// TIBConnection used directly to create a database) loads the default
/// library instead, and a later request for another path fails with
/// "interface already initialized from library ...". The provider calls this
/// from BuildConnection; call it yourself before using SQLdb connections
/// directly.
procedure PdbSQLdbUseClientLibrary(const AConnectorType, ALibrary: string);

implementation

var
  GLibraryLoaders: TList = nil;

// One TSQLDBLibraryLoader per (type, path), alive for the whole process.
procedure PdbSQLdbUseClientLibrary(const AConnectorType, ALibrary: string);
var
  I: Integer;
  LLoader: TSQLDBLibraryLoader;
begin
  if ALibrary = '' then
    Exit;
  for I := 0 to GLibraryLoaders.Count - 1 do
  begin
    LLoader := TSQLDBLibraryLoader(GLibraryLoaders[I]);
    if SameText(LLoader.ConnectionType, AConnectorType) and SameText(LLoader.LibraryName, ALibrary) then
      Exit;
  end;
  LLoader := TSQLDBLibraryLoader.Create(nil);
  LLoader.ConnectionType := AConnectorType;
  LLoader.LibraryName := ALibrary;
  LLoader.Enabled := True;
  GLibraryLoaders.Add(LLoader);
end;

{ TSQLdbConnectionAdapter }

constructor TSQLdbConnectionAdapter.Create(AConnection: TSQLConnector; const ASQLDialect: ISQLDialect);
begin
  inherited Create;
  FConnection := AConnection;
  FSQLDialect := ASQLDialect;
end;

destructor TSQLdbConnectionAdapter.Destroy;
begin
  FConnection.Free;
  inherited Destroy;
end;

function TSQLdbConnectionAdapter.GetNativeConnection: TObject;
begin
  Result := FConnection;
end;

function TSQLdbConnectionAdapter.IsConnected: Boolean;
begin
  Result := FConnection.Connected;
end;

procedure TSQLdbConnectionAdapter.Connect;
begin
  FConnection.Open;
end;

procedure TSQLdbConnectionAdapter.Commit;
begin
end;

procedure TSQLdbConnectionAdapter.Rollback;
begin
end;

procedure TSQLdbConnectionAdapter.Disconnect(Force: Boolean);
begin
  FConnection.Close(Force);
end;

function TSQLdbConnectionAdapter.GetSQLDialect: ISQLDialect;
begin
  Result := FSQLDialect;
end;

{ TSQLdbTransactionAdapter }

constructor TSQLdbTransactionAdapter.Create(const AConn: IDBConnection);
begin
  inherited Create(AConn);
  FTransaction := TSQLTransaction.Create(nil);
  FTransaction.DataBase := AConn.GetNativeConnection as TSQLConnector;
end;

destructor TSQLdbTransactionAdapter.Destroy;
begin
  if FTransaction.Active then
    FTransaction.Rollback;
  FTransaction.Free;
  inherited Destroy;
end;

procedure TSQLdbTransactionAdapter.DoStartTransaction;
begin
  if not FTransaction.Active then
    FTransaction.StartTransaction;
end;

procedure TSQLdbTransactionAdapter.DoCommit;
begin
  if FTransaction.Active then
    FTransaction.Commit;
end;

procedure TSQLdbTransactionAdapter.DoRollback;
begin
  if FTransaction.Active then
    FTransaction.Rollback;
end;

procedure TSQLdbTransactionAdapter.DoExecSql(const ASql: string);
var
  LQuery: TSQLQuery;
begin
  LQuery := TSQLQuery.Create(nil);
  try
    LQuery.DataBase := FTransaction.DataBase;
    LQuery.Transaction := FTransaction;
    LQuery.ParseSQL := False;
    LQuery.ParamCheck := False;
    LQuery.SQL.Text := ASql;
    LQuery.ExecSQL;
  finally
    LQuery.Free;
  end;
end;

function TSQLdbTransactionAdapter.GetNativeTransaction: TObject;
begin
  Result := FTransaction;
end;

{ TSQLdbQueryAdapter }

constructor TSQLdbQueryAdapter.Create(const AConn: IDBConnection; const ATransaction: ITransaction);
begin
  inherited Create(AConn, ATransaction);
  FQuery := TSQLQuery.Create(nil);
  FQuery.DataBase := AConn.GetNativeConnection as TSQLConnector;
  FQuery.Transaction := ATransaction.GetNativeTransaction as TSQLTransaction;
  FQuery.PacketRecords := -1;
end;

destructor TSQLdbQueryAdapter.Destroy;
begin
  FQuery.Free;
  inherited Destroy;
end;

function TSQLdbQueryAdapter.DataSet: TDataSet;
begin
  Result := FQuery;
end;

function TSQLdbQueryAdapter.SqlLines: TStrings;
begin
  Result := FQuery.SQL;
end;

procedure TSQLdbQueryAdapter.DoExecSql;
begin
  FQuery.ExecSQL;
end;

procedure TSQLdbQueryAdapter.DoClearParams;
begin
  FQuery.Params.Clear;
end;

function TSQLdbQueryAdapter.CreateParams: IParams;
begin
  Result := TDBParams.Create(FQuery.Params);
end;

{ TSQLdbProvider }

function TSQLdbProvider.BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
var
  LConn: TSQLConnector;
  LParams: TStrings;
  I: Integer;
  LName, LValue: string;
begin
  LParams := AConfig.ConnectionParams;
  if LParams.Values['ConnectorType'] = '' then
    raise EDatabaseError.Create('PascalDb.Adapter.SQLdb: ConnectionParams must set ConnectorType (Firebird or PostgreSQL)');
  PdbSQLdbUseClientLibrary(LParams.Values['ConnectorType'], LParams.Values['ClientLibrary']);

  LConn := TSQLConnector.Create(nil);
  try
    LConn.LoginPrompt := False;
    for I := 0 to LParams.Count - 1 do
    begin
      LName := LParams.Names[I];
      LValue := LParams.ValueFromIndex[I];
      if SameText(LName, 'ConnectorType') then
        LConn.ConnectorType := LValue
      else if SameText(LName, 'HostName') then
        LConn.HostName := LValue
      else if SameText(LName, 'DatabaseName') then
        LConn.DatabaseName := LValue
      else if SameText(LName, 'UserName') then
        LConn.UserName := LValue
      else if SameText(LName, 'Password') then
        LConn.Password := LValue
      else if SameText(LName, 'CharSet') then
        LConn.CharSet := LValue
      else if SameText(LName, 'Port') then
        LConn.Params.Values['port'] := LValue
      else if SameText(LName, 'ClientLibrary') then
        // handled by PdbSQLdbUseClientLibrary
      else if LName <> '' then
        LConn.Params.Values[LName] := LValue;
    end;
    LConn.Open;
  except
    LConn.Free;
    raise;
  end;
  Result := TSQLdbConnectionAdapter.Create(LConn, TSQLDialectFactory.GetDialect(AConfig.SQLDialect));
end;

function TSQLdbProvider.BuildTransaction(AConn: IDBConnection): ITransaction;
begin
  Result := TSQLdbTransactionAdapter.Create(AConn);
end;

function TSQLdbProvider.BuildScopeTransaction(ATransaction: ITransaction;
  AContextTransaction: IContextTransaction): IScopeTransaction;
begin
  Result := TScopeTransaction.Create(ATransaction, AContextTransaction);
end;

function TSQLdbProvider.BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
begin
  Result := TSQLdbQueryAdapter.Create(AConn, ATransaction);
end;

function TSQLdbProvider.BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
begin
  Result := TSqlScript.Create(AConn, ATransaction);
end;

{ TSQLdbFactory }

constructor TSQLdbFactory.Create(const AConfig: IDatabaseConfig;
  const AContextTransactionProvider: IContextTransactionProvider; AOnPoolEvent: TPoolEventProc);
begin
  inherited Create(AConfig, TSQLdbProvider.Create, AContextTransactionProvider, AOnPoolEvent);
end;

procedure FreeLibraryLoaders;
var
  I: Integer;
begin
  for I := 0 to GLibraryLoaders.Count - 1 do
    TSQLDBLibraryLoader(GLibraryLoaders[I]).Free;
  GLibraryLoaders.Free;
end;

initialization
  GLibraryLoaders := TList.Create;

finalization
  FreeLibraryLoaders;

end.
