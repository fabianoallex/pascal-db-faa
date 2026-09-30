unit PascalDb.Adapter.Zeos;

{$I pascaldb.inc}

{ ZeosLib 8 adapter (Delphi and Free Pascal): IDBFactory over TZConnection
  and TZQuery. Everything that isn't Zeos-specific comes from
  PascalDb.Adapter.Base / PascalDb.Adapter.DataSet.

  Connection settings (IDatabaseConfig.ConnectionParams, Name=Value):
    Protocol         Zeos protocol (required): 'firebird', 'postgresql',
                     'sqlite', 'mysql' and 'mariadb' are the ones tested
                     (the last two load the same client libraries: MySQL's
                     libmysql or MariaDB Connector/C's libmariadb); any other
                     Zeos protocol
                     is passed through, with an SQL dialect registered for
                     it (docs/other-databases.md). 'firebird' uses the Firebird 3+ API when
                     the client library has it and the legacy API otherwise
                     (a 2.5 client).
    HostName         server host ('' = local server, Firebird; unused by
                     SQLite)
    Port             server port (optional)
    Database         database path (Firebird, SQLite: the file, created on
                     first connect) or name (PostgreSQL, MySQL/MariaDB)
    User, Password
    ClientCodepage   connection character set (e.g. UTF8; MySQL/MariaDB:
                     utf8mb4, since their utf8 has no 4-byte characters)
    LibraryLocation  full path of the client library (fbclient/libpq/sqlite3/
                     libmysql/libmariadb) when
                     it isn't found on the default search path (optional)
  Any other line goes to TZConnection.Properties as is (Zeos connection
  properties, e.g. CreateNewDatabase=true). MySQL/MariaDB: MYSQL_PLUGIN_DIR,
  the client's plugin folder, defaults to the plugin folder next to
  LibraryLocation, if there is one (see PdbMySQLPluginDir).

  Zeos specifics handled here:
  - Zeos 8 queries use its own TZParams, not Data.DB's TParams, so the
    parameters have their own IParams (TZeosParamsAdapter). TZParam.AsString
    is a Unicode string on Delphi — no ANSI conversion as with
    TParam/TFDParam.AsString.
  - An ITransaction is the TZConnection's own transaction, never a
    TZTransaction component. On a database that has one transaction per
    connection (PostgreSQL, SQLite, MySQL, ...; not Firebird), Zeos 8 gives
    each TZTransaction a physical connection of its own
    (TZAbstractSingleTxnConnection.CreateTransaction calls
    DriverManager.GetConnection): with one TZTransaction per ITransaction,
    every request opened and closed a PostgreSQL connection (measured: 211
    connections for 200 requests, ~38 ms each to start the transaction),
    the pool's limit didn't bound the server connections, and its checks
    watched an idle connection instead of the one doing the work. A pooled
    connection serves one unit of work at a time, so its own transaction is
    enough; nested scopes are savepoints (TScopeTransaction).
  - TZConnection.StartTransaction with a transaction already open creates a
    SAVEPOINT instead, and the matching Commit only releases it. Every
    statement here runs inside a transaction the ITransaction started (the
    connection stays in AutoCommit otherwise), and releasing a connection to
    the pool rolls back whatever was left open.
  - Queries fetch the whole result on Open (FetchAll), so RecordCount is the
    real row count and a Commit is a hard commit: with rows still pending,
    Zeos commits with "commit retaining" and keeps the transaction open.
  - Firebird connections get hard_commit=true unless the settings say
    otherwise. Without it, a Commit through the Firebird 3+ API first walks
    the open cursors calling Last until each one unregisters itself
    (TZFirebirdTransaction.TestCachedResultsAndForceFetchAll); the cursor of
    an INSERT ... RETURNING opened as a query never does, and the Commit
    loops forever at 100% CPU (measured: Zeos 8.0.0, FPC 3.2.2, Linux,
    Firebird 3 client, Firebird 5 server). A hard commit costs nothing here:
    results are already fully fetched.
  - Zeos can create a Firebird database (CreateNewDatabase=true) but has no
    call to drop one. PdbZeosDropFirebirdDatabase connects through Zeos's
    legacy (ISC) API and calls the client's isc_drop_database on that
    handle, so it works on a remote server too. The legacy API because
    isc_drop_database zeroes the handle Zeos keeps, and Disconnect then
    skips the detach; the Firebird 3+ API's IAttachment.dropDatabase frees
    the attachment while Zeos still holds it, and there is no way to clear
    that reference from outside.
  - SQLite: Zeos 8.0.0 binds a Currency parameter with
    sqlite3_bind_int64 over the Currency's own bits (an Int64 "absolute"
    the value, in ZDbcSqLiteStatement), so 12.34 is stored as the integer
    123400 (measured on FPC 3.2.2, Linux). The parameters here send a
    Currency to SQLite as a Double instead, which is also how SQLite stores
    a NUMERIC with decimals (REAL).
  - SQLite allows one writer at a time, and without a busy timeout a second
    connection that tries to write fails at once with "database is locked"
    (measured: 3 of 4 concurrent writers failed within 4 ms). SQLite
    connections get Zeos's busytimeout=5000 (milliseconds) unless the
    settings say otherwise.
  - IDatabaseConfig.LockTimeoutMs: Firebird gets isc_tpb_wait and
    isc_tpb_lock_timeout (whole seconds, rounded up) in its transaction
    parameters; PostgreSQL a SET lock_timeout right after connecting (one
    server session per TZConnection); MySQL/MariaDB a SET SESSION
    innodb_lock_wait_timeout (whole seconds, rounded up; the server's own
    default is 50 s); SQLite the busy timeout. Without it,
    Zeos on Firebird doesn't wait for a lock at all: the read-committed TPB
    it builds is isc_tpb_nowait, so a statement meeting another
    transaction's lock fails at once (measured, Firebird 2.5), and that
    error is an ELockConflictException too. The driver's lock conflict
    errors (Firebird GDS isc_lock_timeout, isc_lock_conflict, isc_deadlock
    and isc_update_conflict; PostgreSQL SQLSTATE 55P03, 40P01 and 40001;
    MySQL/MariaDB ER_LOCK_WAIT_TIMEOUT and ER_LOCK_DEADLOCK; SQLite
    SQLITE_BUSY and SQLITE_LOCKED) become ELockConflictException. On
    MySQL/MariaDB an expired lock wait undoes only the statement, not the
    transaction (unless the server runs with innodb_rollback_on_timeout).
    Firebird 5 reports an expired lock timeout as isc_deadlock (measured on
    Linux, Firebird 3 client API).
  - Firebird connections are opened one at a time (a process-wide lock around
    TZConnection.Connect). Several opened at the same moment through the
    Firebird 3+ API corrupted memory: access violations, "Invalid index ...
    in function IMessageMetadata::getScale" reported by another connection's
    COMMIT, and a thread stuck for good inside fbclient while Connect ran
    SET BIND OF DECFLOAT TO LEGACY. Measured with 16 threads connecting at
    once, Zeos 8.0.0, FPC 3.2.2, Linux, Debian's Firebird 3 client, Firebird 5
    server: stuck within 73 rounds; with only Connect serialized (queries,
    commits and disconnects still in parallel), 4800 connections clean, and
    with the legacy API (FirebirdAPI=legacy) too. Whether the fault is in
    Zeos or in fbclient wasn't isolated. A pool opens connections rarely, so
    the lock costs little. }

interface

uses
  Classes,
  SysUtils,
  DB,
  ZDbcIntfs,
  ZConnection,
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
    FLockTimeoutMs: Integer;
  public
    /// Takes ownership of AConnection. ALockTimeoutMs: applied again on each
    /// Connect where the database needs it (PostgreSQL).
    constructor Create(AConnection: TZConnection; const ASQLDialect: ISQLDialect;
      ALockTimeoutMs: Integer = 0);
    destructor Destroy; override;
    function GetNativeConnection: TObject;
    function IsConnected: Boolean;
    procedure Connect;
    /// Transactions are managed through ITransaction; no-op here.
    procedure Commit;
    /// Rolls back a transaction left open on the connection (the pool calls
    /// it when the connection comes back), so the next user starts clean.
    procedure Rollback;
    procedure Disconnect(Force: Boolean = False);
    function GetSQLDialect: ISQLDialect;
  end;

  { TZeosTransactionAdapter }

  TZeosTransactionAdapter = class(TTransactionBase)
  private
    FConnection: TZConnection; // not owned; its own transaction is the one used
  protected
    procedure DoStartTransaction; override;
    procedure DoCommit; override;
    procedure DoRollback; override;
    procedure DoExecSql(const ASql: string); override;
    function IsLockConflictError(E: Exception): Boolean; override;
  public
    constructor Create(const AConn: IDBConnection);
    destructor Destroy; override;
    /// The TZConnection: the transaction is the connection's own.
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
  private
    FCurrencyAsDouble: Boolean;
  public
    /// AParams is not owned (it belongs to the query). ACurrencyAsDouble:
    /// the connection is SQLite (see the unit header).
    constructor Create(AParams: TZParams; ACurrencyAsDouble: Boolean);
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
    function ResetParamValues: Boolean; override;
    function CreateParams: IParams; override;
    function IsLockConflictError(E: Exception): Boolean; override;
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
      AOnPoolEvent: TPoolEventProc = nil; AOnStatement: TStatementEventProc = nil);
  end;

/// A TZConnection (not connected) set up from Zeos-style Name=Value settings
/// — the same ones ConnectionParams takes (see the unit header). Used by the
/// provider; also handy for direct connections (e.g. creating a database).
function PdbZeosNewConnection(ASettings: TStrings): TZConnection;

/// Drops the Firebird database ASettings points to (the same settings as
/// ConnectionParams; Protocol must be firebird), local or remote. Raises
/// when it can't connect (e.g. the database doesn't exist) or the server
/// refuses the drop (e.g. other attachments are open).
procedure PdbZeosDropFirebirdDatabase(ASettings: TStrings);

implementation

uses
  SyncObjs,
  ZExceptions,
  ZDbcInterbase6,
  ZDbcInterbase6Utils,
  ZPlainFirebirdInterbaseDriver;

const
  SQLITE_BUSY = 5;   // sqlite3.h: "The database file is locked"
  SQLITE_LOCKED = 6; // sqlite3.h: "A table in the database is locked"
  PG_LOCK_NOT_AVAILABLE = '55P03';
  PG_DEADLOCK_DETECTED = '40P01';
  PG_SERIALIZATION_FAILURE = '40001';
  MYSQL_ER_LOCK_WAIT_TIMEOUT = 1205; // mysqld_error.h: "Lock wait timeout exceeded"
  MYSQL_ER_LOCK_DEADLOCK = 1213;     // mysqld_error.h: "Deadlock found when trying to get lock"

function IsProtocol(AConn: TZConnection; const APrefix: string): Boolean;
begin
  Result := SameText(Copy(AConn.Protocol, 1, Length(APrefix)), APrefix);
end;

function IsMySQLProtocol(AConn: TZConnection): Boolean;
begin
  Result := IsProtocol(AConn, 'mysql') or IsProtocol(AConn, 'mariadb');
end;

var
  GFirebirdConnectLock: TCriticalSection = nil;

// See the unit header: Firebird connections are opened one at a time.
procedure ConnectZeos(AConn: TZConnection);
begin
  if not IsProtocol(AConn, 'firebird') then
  begin
    AConn.Connect;
    Exit;
  end;
  GFirebirdConnectLock.Enter;
  try
    AConn.Connect;
  finally
    GFirebirdConnectLock.Leave;
  end;
end;

// See the unit header: the lock timeout settings Zeos takes before connecting.
// ASettings are the configured ones, to leave alone what they set.
procedure SetZeosLockTimeout(AConn: TZConnection; ASettings: TStrings; AMs: Integer);
begin
  if AMs <= 0 then
    Exit;
  if IsProtocol(AConn, 'firebird') and (ASettings.Values['isc_tpb_lock_timeout'] = '') then
  begin
    if AConn.Properties.IndexOf('isc_tpb_nowait') < 0 then
      AConn.Properties.Add('isc_tpb_wait');
    AConn.Properties.Values['isc_tpb_lock_timeout'] := IntToStr((AMs + 999) div 1000);
  end
  else if IsProtocol(AConn, 'sqlite') and (ASettings.Values['busytimeout'] = '') then
    AConn.Properties.Values['busytimeout'] := IntToStr(AMs);
end;

// See the unit header: PostgreSQL's and MySQL's lock timeouts are set on the
// open session.
procedure ApplyZeosLockTimeout(AConn: TZConnection; AMs: Integer);
begin
  if AMs <= 0 then
    Exit;
  if IsProtocol(AConn, 'postgresql') then
    AConn.ExecuteDirect('SET lock_timeout = ' + IntToStr(AMs))
  else if IsMySQLProtocol(AConn) then
    AConn.ExecuteDirect('SET SESSION innodb_lock_wait_timeout = ' + IntToStr((AMs + 999) div 1000));
end;

// See the unit header: the driver's lock conflict errors.
function IsZeosLockConflict(E: Exception; AConn: TZConnection): Boolean;
var
  LCode: Integer;
  LState: string;
begin
  Result := False;
  if not (E is EZSQLThrowable) then
    Exit;
  if EZSQLThrowable(E).SpecificData is TZIBSpecificData then
  begin
    LCode := TZIBSpecificData(EZSQLThrowable(E).SpecificData).IBErrorCode;
    Result := (LCode = isc_lock_timeout) or (LCode = isc_lock_conflict) or
      (LCode = isc_deadlock) or (LCode = isc_update_conflict);
  end
  else if IsProtocol(AConn, 'postgresql') then
  begin
    LState := EZSQLThrowable(E).StatusCode;
    Result := (LState = PG_LOCK_NOT_AVAILABLE) or (LState = PG_DEADLOCK_DETECTED) or
      (LState = PG_SERIALIZATION_FAILURE);
  end
  else if IsMySQLProtocol(AConn) then
    Result := (EZSQLThrowable(E).ErrorCode = MYSQL_ER_LOCK_WAIT_TIMEOUT) or
      (EZSQLThrowable(E).ErrorCode = MYSQL_ER_LOCK_DEADLOCK)
  else if IsProtocol(AConn, 'sqlite') then
    Result := (EZSQLThrowable(E).ErrorCode = SQLITE_BUSY) or (EZSQLThrowable(E).ErrorCode = SQLITE_LOCKED);
end;

function PdbZeosNewConnection(ASettings: TStrings): TZConnection;
var
  I: Integer;
  LName, LValue: string;
begin
  if ASettings.Values['Protocol'] = '' then
    raise EDatabaseError.Create('PascalDb.Adapter.Zeos: ConnectionParams must set Protocol (the Zeos protocol, e.g. firebird, postgresql or sqlite)');
  Result := TZConnection.Create(nil);
  try
    Result.LoginPrompt := False;
    Result.TransactIsolationLevel := tiReadCommitted;
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
    // See the unit header.
    if SameText(Copy(Result.Protocol, 1, 8), 'firebird') and (Result.Properties.Values['hard_commit'] = '') then
      Result.Properties.Values['hard_commit'] := 'true';
    if SameText(Copy(Result.Protocol, 1, 6), 'sqlite') and (Result.Properties.Values['busytimeout'] = '') then
      Result.Properties.Values['busytimeout'] := '5000';
    if IsMySQLProtocol(Result) and (Result.Properties.Values['MYSQL_PLUGIN_DIR'] = '') and
      (PdbMySQLPluginDir(Result.LibraryLocation) <> '') then
      Result.Properties.Values['MYSQL_PLUGIN_DIR'] := PdbMySQLPluginDir(Result.LibraryLocation);
  except
    Result.Free;
    raise;
  end;
end;

procedure PdbZeosDropFirebirdDatabase(ASettings: TStrings);
var
  LConn: TZConnection;
  LLegacy: IZInterbase6Connection;
  LStatus: TARRAY_ISC_STATUS;
begin
  LConn := PdbZeosNewConnection(ASettings);
  try
    // See the unit header: the legacy API, so the drop clears Zeos's handle.
    LConn.Properties.Values['FirebirdAPI'] := 'legacy';
    ConnectZeos(LConn);
    if not Supports(LConn.DbcConnection, IZInterbase6Connection, LLegacy) then
      raise EDatabaseError.Create('PdbZeosDropFirebirdDatabase: not a Firebird connection (Protocol must be firebird)');
    FillChar(LStatus, SizeOf(LStatus), 0);
    if LLegacy.GetPlainDriver.isc_drop_database(@LStatus[0], LLegacy.GetDBHandle) <> 0 then
      raise EDatabaseError.CreateFmt('PdbZeosDropFirebirdDatabase: isc_drop_database failed (GDS code %d)', [LStatus[1]]);
    LLegacy := nil;
    LConn.Disconnect;
  finally
    LConn.Free;
  end;
end;

{ TZeosConnectionAdapter }

constructor TZeosConnectionAdapter.Create(AConnection: TZConnection; const ASQLDialect: ISQLDialect;
  ALockTimeoutMs: Integer);
begin
  inherited Create;
  FConnection := AConnection;
  FSQLDialect := ASQLDialect;
  FLockTimeoutMs := ALockTimeoutMs;
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
  ConnectZeos(FConnection);
  ApplyZeosLockTimeout(FConnection, FLockTimeoutMs);
end;

procedure TZeosConnectionAdapter.Commit;
begin
end;

procedure TZeosConnectionAdapter.Rollback;
begin
  // Every level: a scope left open may have added savepoints.
  while FConnection.Connected and FConnection.InTransaction do
    FConnection.Rollback;
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
  FConnection := AConn.GetNativeConnection as TZConnection;
end;

destructor TZeosTransactionAdapter.Destroy;
begin
  if InTransaction then
  try
    FConnection.Rollback;
  except
    // connection already gone: nothing left to roll back
  end;
  inherited Destroy;
end;

procedure TZeosTransactionAdapter.DoStartTransaction;
begin
  FConnection.StartTransaction;
end;

procedure TZeosTransactionAdapter.DoCommit;
begin
  FConnection.Commit;
end;

procedure TZeosTransactionAdapter.DoRollback;
begin
  FConnection.Rollback;
end;

procedure TZeosTransactionAdapter.DoExecSql(const ASql: string);
var
  LQuery: TZQuery;
begin
  // See the unit header: never let Zeos open the native transaction by itself.
  StartTransaction;
  LQuery := TZQuery.Create(nil);
  try
    LQuery.Connection := FConnection;
    LQuery.ParamCheck := False;
    LQuery.SQL.Text := ASql;
    LQuery.ExecSQL;
  finally
    LQuery.Free;
  end;
end;

function TZeosTransactionAdapter.IsLockConflictError(E: Exception): Boolean;
begin
  Result := IsZeosLockConflict(E, FConnection);
end;

function TZeosTransactionAdapter.GetNativeTransaction: TObject;
begin
  Result := FConnection;
end;

{ TZeosParamsAdapter }

constructor TZeosParamsAdapter.Create(AParams: TZParams; ACurrencyAsDouble: Boolean);
begin
  inherited Create;
  FParams := AParams;
  FCurrencyAsDouble := ACurrencyAsDouble;
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
var
  LValue: Double;
begin
  if FCurrencyAsDouble then
  begin
    LValue := AValue; // an assignment converts (a Double(...) cast may not: CLAUDE.md, gotcha 18)
    FParams.ParamByName(AName).AsDouble := LValue;
  end
  else
    FParams.ParamByName(AName).AsCurrency := AValue;
end;

{ TZeosQueryAdapter }

constructor TZeosQueryAdapter.Create(const AConn: IDBConnection; const ATransaction: ITransaction);
begin
  inherited Create(AConn, ATransaction);
  FQuery := TZQuery.Create(nil);
  FQuery.Connection := AConn.GetNativeConnection as TZConnection;
  // No Transaction: the query runs in the connection's own transaction (see
  // the unit header).
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

function TZeosQueryAdapter.ResetParamValues: Boolean;
var
  I: Integer;
begin
  // Values only: the parameters (and the prepared statement) stay.
  for I := 0 to FQuery.Params.Count - 1 do
    FQuery.Params[I].Clear;
  Result := True;
end;

function TZeosQueryAdapter.CreateParams: IParams;
begin
  Result := TZeosParamsAdapter.Create(FQuery.Params,
    SameText(Copy(FQuery.Connection.Protocol, 1, 6), 'sqlite'));
end;

function TZeosQueryAdapter.IsLockConflictError(E: Exception): Boolean;
begin
  Result := IsZeosLockConflict(E, FQuery.Connection as TZConnection);
end;

{ TZeosProvider }

function TZeosProvider.BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
var
  LConn: TZConnection;
begin
  LConn := PdbZeosNewConnection(AConfig.ConnectionParams);
  try
    SetZeosLockTimeout(LConn, AConfig.ConnectionParams, AConfig.LockTimeoutMs);
    ConnectZeos(LConn);
    ApplyZeosLockTimeout(LConn, AConfig.LockTimeoutMs);
  except
    LConn.Free;
    raise;
  end;
  Result := TZeosConnectionAdapter.Create(LConn, TSQLDialectFactory.GetDialect(AConfig.SQLDialect),
    AConfig.LockTimeoutMs);
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
  const AContextTransactionProvider: IContextTransactionProvider; AOnPoolEvent: TPoolEventProc;
  AOnStatement: TStatementEventProc);
begin
  inherited Create(AConfig, TZeosProvider.Create, AContextTransactionProvider, AOnPoolEvent, AOnStatement);
end;

initialization
  GFirebirdConnectLock := TCriticalSection.Create;

finalization
  GFirebirdConnectLock.Free;

end.
