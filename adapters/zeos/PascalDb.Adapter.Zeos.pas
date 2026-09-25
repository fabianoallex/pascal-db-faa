unit PascalDb.Adapter.Zeos;

{$I pascaldb.inc}

{ ZeosLib 8 adapter (Delphi and Free Pascal): IDBFactory over TZConnection,
  TZTransaction and TZQuery. Everything that isn't Zeos-specific comes from
  PascalDb.Adapter.Base / PascalDb.Adapter.DataSet.

  Connection settings (IDatabaseConfig.ConnectionParams, Name=Value):
    Protocol         Zeos protocol: 'firebird' or 'postgresql' (required).
                     'firebird' uses the Firebird 3+ API when the client
                     library has it and the legacy API otherwise (a 2.5
                     client).
    HostName         server host ('' = local server, Firebird)
    Port             server port (optional)
    Database         database path (Firebird) or name (PostgreSQL)
    User, Password
    ClientCodepage   connection character set (e.g. UTF8)
    LibraryLocation  full path of the client library (fbclient/libpq) when
                     it isn't found on the default search path (optional)
  Any other line goes to TZConnection.Properties as is (Zeos connection
  properties, e.g. CreateNewDatabase=true).

  Zeos specifics handled here:
  - Zeos 8 queries use its own TZParams, not Data.DB's TParams, so the
    parameters have their own IParams (TZeosParamsAdapter). TZParam.AsString
    is a Unicode string on Delphi — no ANSI conversion as with
    TParam/TFDParam.AsString.
  - TZTransaction.StartTransaction on a transaction whose native handle is
    already open creates a SAVEPOINT instead, and its Commit then only
    releases that savepoint. The native handle opens implicitly with the
    first statement, so every statement here runs inside a transaction the
    ITransaction started: otherwise a later StartTransaction/Commit pair
    would never commit.
  - Queries fetch the whole result on Open (FetchAll), so RecordCount is the
    real row count and a Commit is a hard commit: with rows still pending,
    Zeos commits with "commit retaining" and keeps the transaction open. }

interface

uses
  Classes,
  SysUtils,
  DB,
  ZDbcIntfs,
  ZConnection,
  ZTransaction,
  ZDataset,
  ZDatasetParam,
  PascalDb.Interfaces,
  PascalDb.SqlDialect,
  PascalDb.Pool,
  PascalDb.Adapter.Base,
  PascalDb.Adapter.DataSet;

type
  { TZeosConnectionAdapter }

  TZeosConnectionAdapter = class(TInterfacedObject, IDBConnection)
  private
    FConnection: TZConnection;
    FSQLDialect: ISQLDialect;
  public
    /// Takes ownership of AConnection.
    constructor Create(AConnection: TZConnection; const ASQLDialect: ISQLDialect);
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

  { TZeosTransactionAdapter }

  TZeosTransactionAdapter = class(TTransactionBase)
  private
    FTransaction: TZTransaction;
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

  { TZeosParamsAdapter }

  TZeosParamsAdapter = class(TParamsBase)
  private
    FParams: TZParams;
  protected
    function ParamExists(const AName: string): Boolean; override;
    function ParamIsNull(const AName: string): Boolean; override;
    procedure WriteNull(const AName: string; AType: TPdbParamType); override;
    function ReadString(const AName: string): string; override;
    function ReadBoolean(const AName: string): Boolean; override;
    function ReadDateTime(const AName: string): TDateTime; override;
    function ReadDouble(const AName: string): Double; override;
    function ReadInteger(const AName: string): Integer; override;
    function ReadInt64(const AName: string): Int64; override;
    function ReadCurrency(const AName: string): Currency; override;
    procedure WriteString(const AName: string; AValue: string); override;
    procedure WriteBoolean(const AName: string; AValue: Boolean); override;
    procedure WriteDateTime(const AName: string; AValue: TDateTime); override;
    procedure WriteDouble(const AName: string; AValue: Double); override;
    procedure WriteInteger(const AName: string; AValue: Integer); override;
    procedure WriteInt64(const AName: string; AValue: Int64); override;
    procedure WriteCurrency(const AName: string; AValue: Currency); override;
  public
    /// AParams is not owned (it belongs to the query).
    constructor Create(AParams: TZParams);
  end;

  { TZeosQueryAdapter }

  TZeosQueryAdapter = class(TDataSetQueryBase)
  private
    FQuery: TZQuery;
    procedure EnsureTransaction;
    procedure QueryAfterOpen(ADataSet: TDataSet);
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

  { TZeosProvider }

  TZeosProvider = class(TInterfacedObject, IDBComponentProvider)
  public
    function BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
    function BuildTransaction(AConn: IDBConnection): ITransaction;
    function BuildScopeTransaction(ATransaction: ITransaction; AContextTransaction: IContextTransaction): IScopeTransaction;
    function BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
  end;

  { TZeosFactory }

  TZeosFactory = class(TDBFactory)
  public
    constructor Create(const AConfig: IDatabaseConfig;
      const AContextTransactionProvider: IContextTransactionProvider = nil;
      AOnPoolEvent: TPoolEventProc = nil);
  end;

/// A TZConnection (not connected) set up from Zeos-style Name=Value settings
/// — the same ones ConnectionParams takes (see the unit header). Used by the
/// provider; also handy for direct connections (e.g. creating a database).
function PdbZeosNewConnection(ASettings: TStrings): TZConnection;

implementation

function PdbZeosNewConnection(ASettings: TStrings): TZConnection;
var
  I: Integer;
  LName, LValue: string;
begin
  if ASettings.Values['Protocol'] = '' then
    raise EDatabaseError.Create('PascalDb.Adapter.Zeos: ConnectionParams must set Protocol (firebird or postgresql)');
  Result := TZConnection.Create(nil);
  try
    Result.LoginPrompt := False;
    for I := 0 to ASettings.Count - 1 do
    begin
      LName := ASettings.Names[I];
      LValue := ASettings.ValueFromIndex[I];
      if SameText(LName, 'Protocol') then
        Result.Protocol := LValue
      else if SameText(LName, 'HostName') then
        Result.HostName := LValue
      else if SameText(LName, 'Port') then
        Result.Port := StrToIntDef(LValue, 0)
      else if SameText(LName, 'Database') then
        Result.Database := LValue
      else if SameText(LName, 'User') then
        Result.User := LValue
      else if SameText(LName, 'Password') then
        Result.Password := LValue
      else if SameText(LName, 'ClientCodepage') then
        Result.ClientCodepage := LValue
      else if SameText(LName, 'LibraryLocation') then
        Result.LibraryLocation := LValue
      else if LName <> '' then
        Result.Properties.Values[LName] := LValue;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ TZeosConnectionAdapter }

constructor TZeosConnectionAdapter.Create(AConnection: TZConnection; const ASQLDialect: ISQLDialect);
begin
  inherited Create;
  FConnection := AConnection;
  FSQLDialect := ASQLDialect;
end;

destructor TZeosConnectionAdapter.Destroy;
begin
  FConnection.Free;
  inherited Destroy;
end;

function TZeosConnectionAdapter.GetNativeConnection: TObject;
begin
  Result := FConnection;
end;

function TZeosConnectionAdapter.IsConnected: Boolean;
begin
  Result := FConnection.Connected;
end;

procedure TZeosConnectionAdapter.Connect;
begin
  FConnection.Connect;
end;

procedure TZeosConnectionAdapter.Commit;
begin
end;

procedure TZeosConnectionAdapter.Rollback;
begin
end;

procedure TZeosConnectionAdapter.Disconnect(Force: Boolean);
begin
  FConnection.Disconnect;
end;

function TZeosConnectionAdapter.GetSQLDialect: ISQLDialect;
begin
  Result := FSQLDialect;
end;

{ TZeosTransactionAdapter }

constructor TZeosTransactionAdapter.Create(const AConn: IDBConnection);
begin
  inherited Create(AConn);
  FTransaction := TZTransaction.Create(nil);
  FTransaction.Connection := AConn.GetNativeConnection as TZConnection;
  FTransaction.AutoCommit := False;
  FTransaction.TransactIsolationLevel := tiReadCommitted;
end;

destructor TZeosTransactionAdapter.Destroy;
begin
  if InTransaction then
  try
    FTransaction.Rollback;
  except
    // connection already gone: nothing left to roll back
  end;
  FTransaction.Free;
  inherited Destroy;
end;

procedure TZeosTransactionAdapter.DoStartTransaction;
begin
  FTransaction.StartTransaction;
end;

procedure TZeosTransactionAdapter.DoCommit;
begin
  FTransaction.Commit;
end;

procedure TZeosTransactionAdapter.DoRollback;
begin
  FTransaction.Rollback;
end;

procedure TZeosTransactionAdapter.DoExecSql(const ASql: string);
var
  LQuery: TZQuery;
begin
  // See the unit header: never let Zeos open the native transaction by itself.
  StartTransaction;
  LQuery := TZQuery.Create(nil);
  try
    LQuery.Connection := FTransaction.Connection;
    LQuery.Transaction := FTransaction;
    LQuery.ParamCheck := False;
    LQuery.SQL.Text := ASql;
    LQuery.ExecSQL;
  finally
    LQuery.Free;
  end;
end;

function TZeosTransactionAdapter.GetNativeTransaction: TObject;
begin
  Result := FTransaction;
end;

{ TZeosParamsAdapter }

constructor TZeosParamsAdapter.Create(AParams: TZParams);
begin
  inherited Create;
  FParams := AParams;
end;

function TZeosParamsAdapter.ParamExists(const AName: string): Boolean;
begin
  Result := FParams.FindParam(AName) <> nil;
end;

function TZeosParamsAdapter.ParamIsNull(const AName: string): Boolean;
begin
  Result := FParams.ParamByName(AName).IsNull;
end;

procedure TZeosParamsAdapter.WriteNull(const AName: string; AType: TPdbParamType);
var
  LParam: TZParam;
begin
  LParam := FParams.ParamByName(AName);
  LParam.DataType := TDBParams.FieldTypeOf(AType);
  LParam.Clear;
end;

function TZeosParamsAdapter.ReadString(const AName: string): string;
begin
  Result := FParams.ParamByName(AName).AsString;
end;

function TZeosParamsAdapter.ReadBoolean(const AName: string): Boolean;
begin
  Result := FParams.ParamByName(AName).AsBoolean;
end;

function TZeosParamsAdapter.ReadDateTime(const AName: string): TDateTime;
begin
  Result := FParams.ParamByName(AName).AsDateTime;
end;

function TZeosParamsAdapter.ReadDouble(const AName: string): Double;
begin
  Result := FParams.ParamByName(AName).AsDouble;
end;

function TZeosParamsAdapter.ReadInteger(const AName: string): Integer;
begin
  Result := FParams.ParamByName(AName).AsInteger;
end;

function TZeosParamsAdapter.ReadInt64(const AName: string): Int64;
begin
  Result := FParams.ParamByName(AName).AsInt64;
end;

function TZeosParamsAdapter.ReadCurrency(const AName: string): Currency;
begin
  Result := FParams.ParamByName(AName).AsCurrency;
end;

procedure TZeosParamsAdapter.WriteString(const AName: string; AValue: string);
begin
  FParams.ParamByName(AName).AsString := AValue;
end;

procedure TZeosParamsAdapter.WriteBoolean(const AName: string; AValue: Boolean);
begin
  FParams.ParamByName(AName).AsBoolean := AValue;
end;

procedure TZeosParamsAdapter.WriteDateTime(const AName: string; AValue: TDateTime);
begin
  FParams.ParamByName(AName).AsDateTime := AValue;
end;

procedure TZeosParamsAdapter.WriteDouble(const AName: string; AValue: Double);
begin
  FParams.ParamByName(AName).AsDouble := AValue;
end;

procedure TZeosParamsAdapter.WriteInteger(const AName: string; AValue: Integer);
begin
  FParams.ParamByName(AName).AsInteger := AValue;
end;

procedure TZeosParamsAdapter.WriteInt64(const AName: string; AValue: Int64);
begin
  FParams.ParamByName(AName).AsInt64 := AValue;
end;

procedure TZeosParamsAdapter.WriteCurrency(const AName: string; AValue: Currency);
begin
  FParams.ParamByName(AName).AsCurrency := AValue;
end;

{ TZeosQueryAdapter }

constructor TZeosQueryAdapter.Create(const AConn: IDBConnection; const ATransaction: ITransaction);
begin
  inherited Create(AConn, ATransaction);
  FQuery := TZQuery.Create(nil);
  FQuery.Connection := AConn.GetNativeConnection as TZConnection;
  FQuery.Transaction := ATransaction.GetNativeTransaction as TZTransaction;
  FQuery.AfterOpen := QueryAfterOpen;
end;

destructor TZeosQueryAdapter.Destroy;
begin
  FQuery.Free;
  inherited Destroy;
end;

procedure TZeosQueryAdapter.EnsureTransaction;
begin
  if not GetTransaction.InTransaction then
    GetTransaction.StartTransaction;
end;

procedure TZeosQueryAdapter.QueryAfterOpen(ADataSet: TDataSet);
begin
  FQuery.FetchAll;
end;

function TZeosQueryAdapter.DataSet: TDataSet;
begin
  Result := FQuery;
end;

function TZeosQueryAdapter.SqlLines: TStrings;
begin
  Result := FQuery.SQL;
end;

procedure TZeosQueryAdapter.DoExecSql;
begin
  // See the unit header: never let Zeos open the native transaction by itself.
  EnsureTransaction;
  FQuery.ExecSQL;
end;

procedure TZeosQueryAdapter.DoClearParams;
begin
  FQuery.Params.Clear;
end;

function TZeosQueryAdapter.CreateParams: IParams;
begin
  Result := TZeosParamsAdapter.Create(FQuery.Params);
end;

{ TZeosProvider }

function TZeosProvider.BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
var
  LConn: TZConnection;
begin
  LConn := PdbZeosNewConnection(AConfig.ConnectionParams);
  try
    LConn.Connect;
  except
    LConn.Free;
    raise;
  end;
  Result := TZeosConnectionAdapter.Create(LConn, TSQLDialectFactory.GetDialect(AConfig.SQLDialect));
end;

function TZeosProvider.BuildTransaction(AConn: IDBConnection): ITransaction;
begin
  Result := TZeosTransactionAdapter.Create(AConn);
end;

function TZeosProvider.BuildScopeTransaction(ATransaction: ITransaction;
  AContextTransaction: IContextTransaction): IScopeTransaction;
begin
  Result := TScopeTransaction.Create(ATransaction, AContextTransaction);
end;

function TZeosProvider.BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
begin
  Result := TZeosQueryAdapter.Create(AConn, ATransaction);
end;

function TZeosProvider.BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
begin
  Result := TSqlScript.Create(AConn, ATransaction);
end;

{ TZeosFactory }

constructor TZeosFactory.Create(const AConfig: IDatabaseConfig;
  const AContextTransactionProvider: IContextTransactionProvider; AOnPoolEvent: TPoolEventProc);
begin
  inherited Create(AConfig, TZeosProvider.Create, AContextTransactionProvider, AOnPoolEvent);
end;

end.
