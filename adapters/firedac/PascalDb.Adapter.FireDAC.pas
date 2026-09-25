unit PascalDb.Adapter.FireDAC;

{$I pascaldb.inc}

{ FireDAC adapter (Delphi only): IDBFactory over TFDConnection,
  TFDTransaction and TFDQuery. Everything that isn't FireDAC-specific comes
  from PascalDb.Adapter.Base / PascalDb.Adapter.DataSet.

  Connection settings (IDatabaseConfig.ConnectionParams): FireDAC connection
  definition parameters as Name=Value — DriverID (FB or PG), Database,
  Server, Port, User_Name, Password, CharacterSet, ... — passed to
  TFDConnection.Params as is, except:
    VendorLib  full path of the client library (fbclient/libpq), applied
               once per process through the driver link (TFDPhysFBDriverLink /
               TFDPhysPgDriverLink) instead of a connection parameter. A
               32-bit program needs the 32-bit client (Firebird 2.5 64-bit
               installs it in the WOW64 folder).

  The FireDAC runtime units every FireDAC program needs (Stan.Def,
  Stan.Async, DApt, the FB and PG drivers) are used here, so a consumer
  doesn't hit "Object factory ... missing". Connections run with
  ResourceOptions.SilentMode, so no wait-cursor unit is required either.
  Queries fetch the whole result on Open (FetchOptions.Mode = fmAll), so
  RecordCount is the real row count, as on the other adapters. }

interface

{$IFDEF FPC}
  {$MESSAGE ERROR 'PascalDb.Adapter.FireDAC is for Delphi only; use PascalDb.Adapter.SQLdb or PascalDb.Adapter.Zeos on Free Pascal'}
{$ENDIF}

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  Data.DB,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Option,
  FireDAC.Stan.Param,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.DApt,
  FireDAC.Phys,
  FireDAC.Phys.FB,
  FireDAC.Phys.PG,
  FireDAC.Comp.Client,
  PascalDb.Interfaces,
  PascalDb.SqlDialect,
  PascalDb.Pool,
  PascalDb.Adapter.Base,
  PascalDb.Adapter.DataSet;

type
  { TFDConnectionAdapter }

  TFDConnectionAdapter = class(TInterfacedObject, IDBConnection)
  private
    FConnection: TFDConnection;
    FSQLDialect: ISQLDialect;
  public
    /// Takes ownership of AConnection.
    constructor Create(AConnection: TFDConnection; const ASQLDialect: ISQLDialect);
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

  { TFDTransactionAdapter }

  TFDTransactionAdapter = class(TTransactionBase)
  private
    FTransaction: TFDTransaction;
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

  { TFDParamsAdapter
    TParamsBase over a TFDQuery's TFDParams (FireDAC doesn't use Data.DB's
    TParams, so TDBParams doesn't apply). }

  TFDParamsAdapter = class(TParamsBase)
  private
    FQuery: TFDQuery;
    procedure SetStringParam(AParam: TFDParam; const AValue: string);
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
    /// AQuery is not owned.
    constructor Create(AQuery: TFDQuery);
  end;

  { TFDQueryAdapter }

  TFDQueryAdapter = class(TDataSetQueryBase)
  private
    FQuery: TFDQuery;
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

  { TFDProvider }

  TFDProvider = class(TInterfacedObject, IDBComponentProvider)
  public
    function BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
    function BuildTransaction(AConn: IDBConnection): ITransaction;
    function BuildScopeTransaction(ATransaction: ITransaction; AContextTransaction: IContextTransaction): IScopeTransaction;
    function BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
  end;

  { TFDFactory }

  TFDFactory = class(TDBFactory)
  public
    constructor Create(const AConfig: IDatabaseConfig;
      const AContextTransactionProvider: IContextTransactionProvider = nil;
      AOnPoolEvent: TPoolEventProc = nil);
  end;

/// Applies VendorLib to the FireDAC driver link of ADriverID (FB or PG), once
/// per process. Called by the provider; public so a program can set it before
/// creating anything else.
procedure PdbFireDACUseVendorLib(const ADriverID, AVendorLib: string);

implementation

var
  GDriverLinks: TObjectList<TFDPhysDriverLink> = nil;

procedure PdbFireDACUseVendorLib(const ADriverID, AVendorLib: string);
var
  LLink: TFDPhysDriverLink;
begin
  if AVendorLib = '' then
    Exit;
  for LLink in GDriverLinks do
    if SameText(LLink.BaseDriverID, ADriverID) then
    begin
      if not SameText(LLink.VendorLib, AVendorLib) then
        raise EDatabaseError.CreateFmt(
          'PascalDb.Adapter.FireDAC: the %s client library is already %s; a process can only load one (asked for %s)',
          [ADriverID, LLink.VendorLib, AVendorLib]);
      Exit;
    end;
  if SameText(ADriverID, 'FB') then
    LLink := TFDPhysFBDriverLink.Create(nil)
  else if SameText(ADriverID, 'PG') then
    LLink := TFDPhysPgDriverLink.Create(nil)
  else
    raise EDatabaseError.CreateFmt('PascalDb.Adapter.FireDAC: VendorLib is only supported for FB and PG, not %s', [ADriverID]);
  PdbPreloadClientLibrary(AVendorLib);
  LLink.VendorLib := AVendorLib;
  GDriverLinks.Add(LLink);
end;

{ TFDConnectionAdapter }

constructor TFDConnectionAdapter.Create(AConnection: TFDConnection; const ASQLDialect: ISQLDialect);
begin
  inherited Create;
  FConnection := AConnection;
  FSQLDialect := ASQLDialect;
end;

destructor TFDConnectionAdapter.Destroy;
begin
  FConnection.Free;
  inherited Destroy;
end;

function TFDConnectionAdapter.GetNativeConnection: TObject;
begin
  Result := FConnection;
end;

function TFDConnectionAdapter.IsConnected: Boolean;
begin
  Result := FConnection.Connected;
end;

procedure TFDConnectionAdapter.Connect;
begin
  FConnection.Open;
end;

procedure TFDConnectionAdapter.Commit;
begin
end;

procedure TFDConnectionAdapter.Rollback;
begin
end;

procedure TFDConnectionAdapter.Disconnect(Force: Boolean);
begin
  FConnection.Close;
end;

function TFDConnectionAdapter.GetSQLDialect: ISQLDialect;
begin
  Result := FSQLDialect;
end;

{ TFDTransactionAdapter }

constructor TFDTransactionAdapter.Create(const AConn: IDBConnection);
begin
  inherited Create(AConn);
  FTransaction := TFDTransaction.Create(nil);
  FTransaction.Connection := AConn.GetNativeConnection as TFDConnection;
end;

destructor TFDTransactionAdapter.Destroy;
begin
  FTransaction.Free;
  inherited Destroy;
end;

procedure TFDTransactionAdapter.DoStartTransaction;
begin
  if not FTransaction.Active then
    FTransaction.StartTransaction;
end;

procedure TFDTransactionAdapter.DoCommit;
begin
  if FTransaction.Active then
    FTransaction.Commit;
end;

procedure TFDTransactionAdapter.DoRollback;
begin
  if FTransaction.Active then
    FTransaction.Rollback;
end;

procedure TFDTransactionAdapter.DoExecSql(const ASql: string);
var
  LQuery: TFDQuery;
begin
  LQuery := TFDQuery.Create(nil);
  try
    LQuery.Connection := FTransaction.Connection;
    LQuery.Transaction := FTransaction;
    LQuery.ResourceOptions.ParamCreate := False;
    LQuery.SQL.Text := ASql;
    LQuery.ExecSQL;
  finally
    LQuery.Free;
  end;
end;

function TFDTransactionAdapter.GetNativeTransaction: TObject;
begin
  Result := FTransaction;
end;

{ TFDParamsAdapter }

constructor TFDParamsAdapter.Create(AQuery: TFDQuery);
begin
  inherited Create;
  FQuery := AQuery;
end;

procedure TFDParamsAdapter.SetStringParam(AParam: TFDParam; const AValue: string);
begin
  // FireDAC sizes a string parameter from its first value; a longer value
  // later would be truncated — grow it first (behavior of the origin adapter).
  if AParam.Size < Length(AValue) then
    AParam.Size := Length(AValue);
  // AsWideString, not AsString: TFDParam.AsString makes the parameter
  // ftString (ANSI), and FireDAC then converts the text to the ANSI code
  // page — characters outside it arrive at the database as "?" (observed:
  // 'São Paulo → ok' stored as 'São Paulo ? ok' on Firebird with
  // CharacterSet=UTF8). The origin adapter used AsString too.
  AParam.AsWideString := AValue;
end;

function TFDParamsAdapter.ParamExists(const AName: string): Boolean;
begin
  Result := FQuery.Params.FindParam(AName) <> nil;
end;

function TFDParamsAdapter.ParamIsNull(const AName: string): Boolean;
begin
  Result := FQuery.ParamByName(AName).IsNull;
end;

procedure TFDParamsAdapter.WriteNull(const AName: string; AType: TPdbParamType);
var
  LParam: TFDParam;
begin
  LParam := FQuery.ParamByName(AName);
  LParam.DataType := TDBParams.FieldTypeOf(AType); // ftWideString for strings on Delphi
  LParam.Clear;
end;

function TFDParamsAdapter.ReadString(const AName: string): string;
begin
  Result := FQuery.ParamByName(AName).AsString;
end;

function TFDParamsAdapter.ReadBoolean(const AName: string): Boolean;
begin
  Result := FQuery.ParamByName(AName).AsBoolean;
end;

function TFDParamsAdapter.ReadDateTime(const AName: string): TDateTime;
begin
  Result := FQuery.ParamByName(AName).AsDateTime;
end;

function TFDParamsAdapter.ReadDouble(const AName: string): Double;
begin
  Result := FQuery.ParamByName(AName).AsFloat;
end;

function TFDParamsAdapter.ReadInteger(const AName: string): Integer;
begin
  Result := FQuery.ParamByName(AName).AsInteger;
end;

function TFDParamsAdapter.ReadInt64(const AName: string): Int64;
begin
  Result := FQuery.ParamByName(AName).AsLargeInt;
end;

function TFDParamsAdapter.ReadCurrency(const AName: string): Currency;
begin
  Result := FQuery.ParamByName(AName).AsCurrency;
end;

procedure TFDParamsAdapter.WriteString(const AName: string; AValue: string);
begin
  SetStringParam(FQuery.ParamByName(AName), AValue);
end;

procedure TFDParamsAdapter.WriteBoolean(const AName: string; AValue: Boolean);
begin
  FQuery.ParamByName(AName).AsBoolean := AValue;
end;

procedure TFDParamsAdapter.WriteDateTime(const AName: string; AValue: TDateTime);
begin
  FQuery.ParamByName(AName).AsDateTime := AValue;
end;

procedure TFDParamsAdapter.WriteDouble(const AName: string; AValue: Double);
begin
  FQuery.ParamByName(AName).AsFloat := AValue;
end;

procedure TFDParamsAdapter.WriteInteger(const AName: string; AValue: Integer);
begin
  FQuery.ParamByName(AName).AsInteger := AValue;
end;

procedure TFDParamsAdapter.WriteInt64(const AName: string; AValue: Int64);
begin
  FQuery.ParamByName(AName).AsLargeInt := AValue;
end;

procedure TFDParamsAdapter.WriteCurrency(const AName: string; AValue: Currency);
begin
  FQuery.ParamByName(AName).AsCurrency := AValue;
end;

{ TFDQueryAdapter }

constructor TFDQueryAdapter.Create(const AConn: IDBConnection; const ATransaction: ITransaction);
begin
  inherited Create(AConn, ATransaction);
  FQuery := TFDQuery.Create(nil);
  FQuery.Connection := AConn.GetNativeConnection as TFDConnection;
  FQuery.Transaction := ATransaction.GetNativeTransaction as TFDTransaction;
  FQuery.FetchOptions.Mode := fmAll;
end;

destructor TFDQueryAdapter.Destroy;
begin
  FQuery.Free;
  inherited Destroy;
end;

function TFDQueryAdapter.DataSet: TDataSet;
begin
  Result := FQuery;
end;

function TFDQueryAdapter.SqlLines: TStrings;
begin
  Result := FQuery.SQL;
end;

procedure TFDQueryAdapter.DoExecSql;
begin
  FQuery.ExecSQL;
end;

procedure TFDQueryAdapter.DoClearParams;
begin
  FQuery.Params.Clear;
end;

function TFDQueryAdapter.CreateParams: IParams;
begin
  Result := TFDParamsAdapter.Create(FQuery);
end;

{ TFDProvider }

function TFDProvider.BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
var
  LConn: TFDConnection;
  LParams: TStrings;
  I: Integer;
begin
  LParams := AConfig.ConnectionParams;
  PdbFireDACUseVendorLib(LParams.Values['DriverID'], LParams.Values['VendorLib']);

  LConn := TFDConnection.Create(nil);
  try
    LConn.LoginPrompt := False;
    LConn.ResourceOptions.SilentMode := True;
    for I := 0 to LParams.Count - 1 do
      if not SameText(LParams.Names[I], 'VendorLib') then
        LConn.Params.Add(LParams[I]);
    LConn.Connected := True;
  except
    LConn.Free;
    raise;
  end;
  Result := TFDConnectionAdapter.Create(LConn, TSQLDialectFactory.GetDialect(AConfig.SQLDialect));
end;

function TFDProvider.BuildTransaction(AConn: IDBConnection): ITransaction;
begin
  Result := TFDTransactionAdapter.Create(AConn);
end;

function TFDProvider.BuildScopeTransaction(ATransaction: ITransaction;
  AContextTransaction: IContextTransaction): IScopeTransaction;
begin
  Result := TScopeTransaction.Create(ATransaction, AContextTransaction);
end;

function TFDProvider.BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
begin
  Result := TFDQueryAdapter.Create(AConn, ATransaction);
end;

function TFDProvider.BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
begin
  Result := TSqlScript.Create(AConn, ATransaction);
end;

{ TFDFactory }

constructor TFDFactory.Create(const AConfig: IDatabaseConfig;
  const AContextTransactionProvider: IContextTransactionProvider; AOnPoolEvent: TPoolEventProc);
begin
  inherited Create(AConfig, TFDProvider.Create, AContextTransactionProvider, AOnPoolEvent);
end;

initialization
  GDriverLinks := TObjectList<TFDPhysDriverLink>.Create(True);

finalization
  GDriverLinks.Free;

end.
