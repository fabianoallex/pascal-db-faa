unit PascalDb.Adapter.FireDAC;

{$I pascaldb.inc}

{ FireDAC adapter (Delphi only): IDBFactory over TFDConnection,
  TFDTransaction and TFDQuery. Everything that isn't FireDAC-specific comes
  from PascalDb.Adapter.Base / PascalDb.Adapter.DataSet.

  Connection settings (IDatabaseConfig.ConnectionParams): FireDAC connection
  definition parameters as Name=Value — DriverID (FB, PG or SQLite; another
  driver works when the program links its FireDAC.Phys.* unit and registers
  an SQL dialect for it, see docs/other-databases.md),
  Database, Server, Port, User_Name, Password, CharacterSet, ... — passed
  to TFDConnection.Params as is, except:
    VendorLib  full path of the client library (fbclient/libpq), applied
               once per process through the driver link (TFDPhysFBDriverLink /
               TFDPhysPgDriverLink) instead of a connection parameter. A
               32-bit program needs the 32-bit client (Firebird 2.5 64-bit
               installs it in the WOW64 folder). Not for SQLite: its engine
               is linked into the program (FireDAC.Phys.SQLiteWrapper.Stat),
               so there is no client library. For a driver other than FB
               and PG, leave VendorLib out and set it on that driver's link
               in the program (e.g. a TFDPhysOracleDriverLink).
  SQLite (Database = the file, created on first connect). Unless the
  settings say otherwise, connections here use:
    LockingMode=Normal  FireDAC's documented default (Exclusive) keeps every
                        other connection out of the file, so a pool couldn't
                        open a second one (not tried with Exclusive);
    SharedCache=False   with FireDAC's default (True), a second writer failed
                        at once with "database table is locked" (a table
                        lock, which the busy timeout doesn't wait for);
    BusyTimeout=5000    (or IDatabaseConfig.LockTimeoutMs when set)
                        and UpdateOptions.LockWait = True: with SharedCache
                        off, a second writer still failed at once, with
                        "database is locked"; with both of these set it
                        waited for the lock (which of the two was needed
                        wasn't isolated);
    StringFormat=Unicode  with FireDAC's default, 'São Paulo → ok' came back
                        as 'São Paulo ? ok': VARCHAR columns were handled as
                        ANSI strings.

  The FireDAC runtime units every FireDAC program needs (Stan.Def,
  Stan.Async, DApt, the FB, PG and SQLite drivers) are used here, so a
  consumer doesn't hit "Object factory ... missing". Connections run with
  ResourceOptions.SilentMode, so no wait-cursor unit is required either.
  Queries fetch the whole result on Open (FetchOptions.Mode = fmAll), so
  RecordCount is the real row count, as on the other adapters.

  IDatabaseConfig.LockTimeoutMs: connections get UpdateOptions.LockWait =
  True; Firebird transactions get wait and lock_timeout (whole seconds,
  rounded up) in their Options.Params; PostgreSQL a SET lock_timeout right
  after connecting; SQLite the busy timeout. Measured on Firebird 2.5
  (Delphi 12 CE, Win64, MON$TRANSACTIONS.MON$LOCK_TIMEOUT of the waiting
  transaction): the short names work and the isc_tpb_ ones are ignored, and
  only in the TFDTransaction's Options.Params, not in the connection's
  TxOptions alone. Without LockTimeoutMs, FireDAC's Firebird transactions
  don't wait at all (MON$LOCK_TIMEOUT = 0: UpdateOptions.LockWait is False
  by default).
  FireDAC doesn't give the lock errors of Firebird and PostgreSQL the kind
  ekRecordLocked (measured: ekOther), so they are recognized by code: the
  GDS code in TFDDBError.ErrorCode (Firebird), the SQLSTATE in
  TFDPgError.ErrorCode (PostgreSQL); ekRecordLocked still covers SQLite.
  Those become ELockConflictException (see the codes in
  PascalDb.Adapter.SQLdb). The Community Edition has no source for the
  drivers: these came from measurement and the names in the compiled units. }

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
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteWrapper.Stat,
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
    FLockTimeoutMs: Integer;
  public
    /// Takes ownership of AConnection. ALockTimeoutMs: applied again on each
    /// Connect where the database needs it (PostgreSQL).
    constructor Create(AConnection: TFDConnection; const ASQLDialect: ISQLDialect;
      ALockTimeoutMs: Integer = 0);
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
    function IsLockConflictError(E: Exception): Boolean; override;
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
    function ResetParamValues: Boolean; override;
    function CreateParams: IParams; override;
    function IsLockConflictError(E: Exception): Boolean; override;
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

uses
  FireDAC.Stan.Error,
  FireDAC.Phys.PGWrapper;

const
  // iberror.h; see PascalDb.Adapter.SQLdb
  ISC_DEADLOCK = 335544336;
  ISC_LOCK_CONFLICT = 335544345;
  ISC_UPDATE_CONFLICT = 335544451;
  ISC_LOCK_TIMEOUT = 335544510;

var
  GDriverLinks: TObjectList<TFDPhysDriverLink> = nil;

// See the unit header: PostgreSQL's lock timeout is set on the open session.
procedure ApplyFireDACLockTimeout(AConn: TFDConnection; AMs: Integer);
begin
  if (AMs > 0) and SameText(AConn.Params.Values['DriverID'], 'PG') then
    AConn.ExecSQL('SET lock_timeout = ' + IntToStr(AMs));
end;

// See the unit header.
function IsFireDACLockConflict(E: Exception): Boolean;
var
  LError: EFDDBEngineException;
  LItem: TFDDBError;
  LState: string;
  I: Integer;
begin
  Result := False;
  if not (E is EFDDBEngineException) then
    Exit;
  LError := EFDDBEngineException(E);
  if LError.Kind = ekRecordLocked then
    Exit(True);
  for I := 0 to LError.ErrorCount - 1 do
  begin
    LItem := LError.Errors[I];
    if LItem is TFDPgError then
    begin
      LState := TFDPgError(LItem).ErrorCode;
      if (LState = '55P03') or (LState = '40P01') or (LState = '40001') then
        Exit(True);
    end
    else if (LItem.ErrorCode = ISC_LOCK_TIMEOUT) or (LItem.ErrorCode = ISC_LOCK_CONFLICT) or
      (LItem.ErrorCode = ISC_DEADLOCK) or (LItem.ErrorCode = ISC_UPDATE_CONFLICT) then
      Exit(True);
  end;
end;

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
    raise EDatabaseError.CreateFmt('PascalDb.Adapter.FireDAC: VendorLib in ConnectionParams is only applied for ' +
      'FB and PG, not %s. Leave it out and set VendorLib on that driver''s link in your program (e.g. ' +
      'TFDPhysOracleDriverLink.VendorLib) before the first connection; SQLite needs none (it is linked in)',
      [ADriverID]);
  PdbPreloadClientLibrary(AVendorLib);
  LLink.VendorLib := AVendorLib;
  GDriverLinks.Add(LLink);
end;

{ TFDConnectionAdapter }

constructor TFDConnectionAdapter.Create(AConnection: TFDConnection; const ASQLDialect: ISQLDialect;
  ALockTimeoutMs: Integer);
begin
  inherited Create;
  FConnection := AConnection;
  FSQLDialect := ASQLDialect;
  FLockTimeoutMs := ALockTimeoutMs;
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
  ApplyFireDACLockTimeout(FConnection, FLockTimeoutMs);
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
  // The Firebird lock timeout BuildConnection put in the connection's
  // TxOptions: FireDAC reads it only from the transaction's own options
  // (see the unit header).
  FTransaction.Options.Params.Assign(FTransaction.Connection.TxOptions.Params);
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

function TFDTransactionAdapter.IsLockConflictError(E: Exception): Boolean;
begin
  Result := IsFireDACLockConflict(E);
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
  // Growing it isn't enough once the command is prepared (FireDAC keeps it
  // prepared between executions of the same SQL): the bound buffer keeps the
  // old size, and PostgreSQL, which doesn't describe parameter sizes, failed
  // with "Data too large for variable". Unprepare, so the next execution
  // prepares with the new size (a re-prepare only when a value is longer
  // than every one before it).
  if AParam.Size < Length(AValue) then
  begin
    if FQuery.Prepared then
      FQuery.Unprepare;
    AParam.Size := Length(AValue);
  end;
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

function TFDQueryAdapter.ResetParamValues: Boolean;
var
  I: Integer;
begin
  // Values only: the parameters (and the prepared statement) stay.
  for I := 0 to FQuery.Params.Count - 1 do
    FQuery.Params[I].Clear;
  Result := True;
end;

function TFDQueryAdapter.CreateParams: IParams;
begin
  Result := TFDParamsAdapter.Create(FQuery);
end;

function TFDQueryAdapter.IsLockConflictError(E: Exception): Boolean;
begin
  Result := IsFireDACLockConflict(E);
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
    // SQLite defaults: see the unit header.
    if SameText(LParams.Values['DriverID'], 'SQLite') then
    begin
      if LConn.Params.Values['LockingMode'] = '' then
        LConn.Params.Values['LockingMode'] := 'Normal';
      if LConn.Params.Values['SharedCache'] = '' then
        LConn.Params.Values['SharedCache'] := 'False';
      if LConn.Params.Values['StringFormat'] = '' then
        LConn.Params.Values['StringFormat'] := 'Unicode';
      if LConn.Params.Values['BusyTimeout'] = '' then
        if AConfig.LockTimeoutMs > 0 then
          LConn.Params.Values['BusyTimeout'] := IntToStr(AConfig.LockTimeoutMs)
        else
          LConn.Params.Values['BusyTimeout'] := '5000';
      LConn.UpdateOptions.LockWait := True;
    end;
    // Lock timeout: see the unit header.
    if AConfig.LockTimeoutMs > 0 then
    begin
      LConn.UpdateOptions.LockWait := True;
      if SameText(LParams.Values['DriverID'], 'FB') then
      begin
        LConn.TxOptions.Params.Add('wait');
        LConn.TxOptions.Params.Add('lock_timeout=' + IntToStr((AConfig.LockTimeoutMs + 999) div 1000));
      end;
    end;
    LConn.Connected := True;
    ApplyFireDACLockTimeout(LConn, AConfig.LockTimeoutMs);
  except
    LConn.Free;
    raise;
  end;
  Result := TFDConnectionAdapter.Create(LConn, TSQLDialectFactory.GetDialect(AConfig.SQLDialect),
    AConfig.LockTimeoutMs);
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
