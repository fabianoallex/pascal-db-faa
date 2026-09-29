unit PascalDb.Adapter.SQLdb;

{$I pascaldb.inc}

{ SQLdb adapter (Free Pascal / Lazarus only): IDBFactory over TSQLConnector,
  TSQLTransaction and TSQLQuery. Everything that isn't SQLdb-specific comes
  from PascalDb.Adapter.Base / PascalDb.Adapter.DataSet.

  Connection settings (IDatabaseConfig.ConnectionParams, Name=Value):
    ConnectorType  SQLdb connector name (required). 'Firebird', 'PostgreSQL',
                   'SQLite3', 'MySQL 8.0' and 'MySQL 5.7' are registered by
                   this unit (the MySQL ones talk to MariaDB servers too);
                   for another
                   one, add its connection unit to the program's uses
                   (e.g. oracleconnection for 'Oracle') and register an SQL
                   dialect for it (docs/other-databases.md)
    HostName       server host ('' = local/embedded, Firebird; unused by
                   SQLite)
    Port           server port (optional)
    DatabaseName   database path (Firebird, SQLite: the file, created on
                   first connect) or name (PostgreSQL, MySQL/MariaDB)
    UserName, Password
    CharSet        connection character set (e.g. UTF8; MySQL/MariaDB:
                   utf8mb4, since their utf8 has no 4-byte characters)
    BusyTimeout    SQLite only: milliseconds a statement waits for another
                   connection's write lock before failing with "database is
                   locked" (default: IDatabaseConfig.LockTimeoutMs, or 5000
                   when that is 0)
    ClientLibrary  full path of the client library (fbclient/libpq/sqlite3/
                   libmysqlclient/libmariadb) when it isn't found on the
                   default search path (optional)
    SkipLibraryVersionCheck
                   MySQL only: true to connect with a client library of
                   another version than the connector's (see below)
  Any other line is passed to the connection's Params as is.

  SQLdb specifics handled here:
  - PacketRecords = -1: the whole result is fetched on Open, so RecordCount
    is the real row count (SQLdb otherwise counts only fetched rows).
  - SQLdb starts the native transaction by itself when a query opens, so
    DoStartTransaction only starts it if it isn't active yet.
  - TSQLTransaction.Commit/Rollback close the datasets attached to it: read
    the results before committing (the usual repository pattern).
  - SQLite: FPC 3.2.2's sqlite3conn prepares statements with the legacy
    sqlite3_prepare, which returns SQLITE_SCHEMA ("database schema has
    changed") when another connection changed the schema after this one last
    read it, instead of preparing again as sqlite3_prepare_v2 does. With a
    pool that is the normal case (migrations on one connection, the next
    statement on another), so a statement failing with SQLITE_SCHEMA is
    prepared and run once more; the error is raised before the statement
    does anything, so the retry is safe.
  - SQLite allows one writer at a time, and without a busy timeout a second
    connection that tries to write fails at once with "database is locked"
    (measured: 3 of 4 concurrent writers failed within 4 ms). Every SQLite
    connection gets PRAGMA busy_timeout (BusyTimeout, default 5000 ms) when
    it opens.
  - IDatabaseConfig.LockTimeoutMs: Firebird gets it in every transaction's
    TPB (isc_tpb_lock_timeout, whole seconds, rounded up, with SQLdb's
    default concurrency/wait/write spelled out, since a TPB with any item
    replaces the defaults); PostgreSQL through the connection string
    (options='-c lock_timeout=N'), because the PostgreSQL connector opens a
    server connection per transaction and a SET would reach only one of
    them; MySQL/MariaDB a SET SESSION innodb_lock_wait_timeout when the
    connection opens (whole seconds, rounded up; one server session per
    connection); SQLite as the busy timeout. The driver's lock conflict
    errors (Firebird GDS isc_lock_timeout, isc_lock_conflict, isc_deadlock
    and isc_update_conflict; PostgreSQL SQLSTATE 55P03, 40P01 and 40001;
    MySQL/MariaDB ER_LOCK_WAIT_TIMEOUT and ER_LOCK_DEADLOCK; SQLite
    SQLITE_BUSY and SQLITE_LOCKED) become ELockConflictException. Firebird 5
    reports an expired lock timeout as isc_deadlock (measured on Linux), 2.5
    as isc_lock_timeout.
  - MySQL: FPC 3.2.2 has one connector per client version ('MySQL 8.0' wants
    a client library that reports 8.0.x, 'MySQL 5.7' 5.7.x or a MariaDB
    10.x) and refuses any other when connecting ("can not work with the
    installed MySQL client version"). Debian bookworm's MariaDB
    Connector/C (libmariadb3) reports 3.3.19 and is refused by both, and so
    is a newer MySQL client (8.4). With SkipLibraryVersionCheck=true the
    check is left out; measured with libmariadb 3.3.19 on Linux, both
    connectors against MySQL 8.4 and MariaDB 11.4: connect, UTF-8 text,
    BIGINT, DECIMAL, DOUBLE and DATETIME(3) round trips all correct.
    Parameters are replaced in the SQL text on the client (the connector has
    no server-side prepared statements), escaping backslashes as the server
    expects. }

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
  sqlite3conn,
  mysql57conn,
  mysql80conn,
  PascalDb.Interfaces,
  PascalDb.SqlDialect,
  PascalDb.Pool,
  PascalDb.Adapter.Base,
  PascalDb.Adapter.DataSet;

type
  { TPdbSQLConnector }

  // The native connection: a TSQLConnector that also carries the settings
  // the transactions and a reconnect need (IDatabaseConfig.LockTimeoutMs,
  // SkipLibraryVersionCheck).
  TPdbSQLConnector = class(TSQLConnector)
  protected
    procedure DoInternalConnect; override;
  public
    LockTimeoutMs: Integer;
    SkipLibraryVersionCheck: Boolean;
  end;

  { TSQLdbConnectionAdapter }

  TSQLdbConnectionAdapter = class(TInterfacedObject, IDBConnection)
  private
    FConnection: TPdbSQLConnector;
    FSQLDialect: ISQLDialect;
  public
    /// Takes ownership of AConnection.
    constructor Create(AConnection: TPdbSQLConnector; const ASQLDialect: ISQLDialect);
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
    function IsLockConflictError(E: Exception): Boolean; override;
  public
    constructor Create(const AConn: IDBConnection);
    destructor Destroy; override;
    function GetNativeTransaction: TObject; override;
  end;

  { TSQLdbQueryAdapter }

  TSQLdbQueryAdapter = class(TDataSetQueryBase)
  private
    FQuery: TSQLQuery;
    FPreparedIn: PtrInt; // the transaction's Tag when DoExecSql prepared
  protected
    function DataSet: TDataSet; override;
    function SqlLines: TStrings; override;
    procedure DoExecSql; override;
    procedure DoOpen; override;
    procedure DoClearParams; override;
    function ResetParamValues: Boolean; override;
    function CreateParams: IParams; override;
    function IsLockConflictError(E: Exception): Boolean; override;
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
      AOnPoolEvent: TPoolEventProc = nil; AOnStatement: TStatementEventProc = nil);
  end;

/// Loads the client library of AConnectorType ('Firebird', 'PostgreSQL', ...)
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

const
  SQLITE_SCHEMA = 17; // sqlite3.h: "The database schema changed"
  SQLITE_BUSY = 5;    // sqlite3.h: "The database file is locked"
  SQLITE_LOCKED = 6;  // sqlite3.h: "A table in the database is locked"
  DEFAULT_SQLITE_BUSY_TIMEOUT_MS = 5000;
  // iberror.h
  ISC_DEADLOCK = 335544336;        // "deadlock" (also an expired lock timeout on Firebird 3+)
  ISC_LOCK_CONFLICT = 335544345;   // "lock conflict on no wait transaction"
  ISC_UPDATE_CONFLICT = 335544451; // "update conflicts with concurrent update"
  ISC_LOCK_TIMEOUT = 335544510;    // "lock time-out on wait transaction"
  PG_LOCK_NOT_AVAILABLE = '55P03';
  PG_DEADLOCK_DETECTED = '40P01';
  PG_SERIALIZATION_FAILURE = '40001';
  MYSQL_ER_LOCK_WAIT_TIMEOUT = 1205; // mysqld_error.h: "Lock wait timeout exceeded"
  MYSQL_ER_LOCK_DEADLOCK = 1213;     // mysqld_error.h: "Deadlock found when trying to get lock"

function IsMySQLConnector(const AConnectorType: string): Boolean;
begin
  Result := SameText(Copy(AConnectorType, 1, 5), 'MySQL');
end;

{ TPdbSQLConnector }

// See the unit header: the MySQL connectors' client version check. Set on
// the connector's inner connection right before it connects: setting
// ConnectorType already creates that connection, before the other settings
// are read.
procedure TPdbSQLConnector.DoInternalConnect;
begin
  CheckProxy;
  if Proxy is TMySQL80Connection then
    TMySQL80Connection(Proxy).SkipLibraryVersionCheck := SkipLibraryVersionCheck
  else if Proxy is TMySQL57Connection then
    TMySQL57Connection(Proxy).SkipLibraryVersionCheck := SkipLibraryVersionCheck;
  inherited DoInternalConnect;
end;

// See the unit header. Runs in a throwaway transaction: SQLdb executes
// statements only inside one.
procedure ApplySQLiteBusyTimeout(AConn: TPdbSQLConnector);
var
  LTransaction: TSQLTransaction;
  LDefault: Integer;
begin
  if not SameText(AConn.ConnectorType, 'SQLite3') then
    Exit;
  if AConn.LockTimeoutMs > 0 then
    LDefault := AConn.LockTimeoutMs
  else
    LDefault := DEFAULT_SQLITE_BUSY_TIMEOUT_MS;
  LTransaction := TSQLTransaction.Create(nil);
  try
    LTransaction.DataBase := AConn;
    AConn.ExecuteDirect('PRAGMA busy_timeout = ' +
      IntToStr(StrToIntDef(AConn.Params.Values['BusyTimeout'], LDefault)), LTransaction);
    LTransaction.Commit;
  finally
    LTransaction.Free;
  end;
end;

// See the unit header: MySQL/MariaDB get the lock timeout on the open
// session. A throwaway transaction, as for SQLite's busy timeout.
procedure ApplyMySQLLockTimeout(AConn: TPdbSQLConnector);
var
  LTransaction: TSQLTransaction;
begin
  if (AConn.LockTimeoutMs <= 0) or not IsMySQLConnector(AConn.ConnectorType) then
    Exit;
  LTransaction := TSQLTransaction.Create(nil);
  try
    LTransaction.DataBase := AConn;
    AConn.ExecuteDirect('SET SESSION innodb_lock_wait_timeout = ' +
      IntToStr((AConn.LockTimeoutMs + 999) div 1000), LTransaction);
    LTransaction.Commit;
  finally
    LTransaction.Free;
  end;
end;

// Everything a connection needs right after it opens (also on a reconnect).
procedure ApplySessionSettings(AConn: TPdbSQLConnector);
begin
  ApplySQLiteBusyTimeout(AConn);
  ApplyMySQLLockTimeout(AConn);
end;

// See the unit header: PostgreSQL gets the lock timeout as a libpq option of
// the connection string, next to any options the settings already have.
procedure ApplyPostgresLockTimeout(AConn: TPdbSQLConnector);
var
  LOptions: string;
begin
  if (AConn.LockTimeoutMs <= 0) or not SameText(AConn.ConnectorType, 'PostgreSQL') then
    Exit;
  LOptions := Trim(AConn.Params.Values['options']);
  if (Length(LOptions) >= 2) and (LOptions[1] = '''') and (LOptions[Length(LOptions)] = '''') then
    LOptions := Copy(LOptions, 2, Length(LOptions) - 2);
  AConn.Params.Values['options'] := '''' +
    Trim(LOptions + ' -c lock_timeout=' + IntToStr(AConn.LockTimeoutMs)) + '''';
end;

// See the unit header: the TPB of a Firebird transaction with a lock timeout.
function FirebirdLockTimeoutTPB(AConn: TPdbSQLConnector): string;
begin
  Result := '';
  if (AConn.LockTimeoutMs > 0) and SameText(AConn.ConnectorType, 'Firebird') then
    Result := 'isc_tpb_write,isc_tpb_concurrency,isc_tpb_wait,isc_tpb_lock_timeout=' +
      IntToStr((AConn.LockTimeoutMs + 999) div 1000);
end;

// See the unit header: the driver's lock conflict errors.
function IsSQLdbLockConflict(E: Exception; ADataBase: TDatabase): Boolean;
var
  LType: string;
  LCode: Integer;
begin
  Result := False;
  if not (ADataBase is TSQLConnector) then
    Exit;
  LType := TSQLConnector(ADataBase).ConnectorType;
  if E is EPQDatabaseError then
    Result := (EPQDatabaseError(E).SQLSTATE = PG_LOCK_NOT_AVAILABLE) or
      (EPQDatabaseError(E).SQLSTATE = PG_DEADLOCK_DETECTED) or
      (EPQDatabaseError(E).SQLSTATE = PG_SERIALIZATION_FAILURE)
  else if E is ESQLDatabaseError then
  begin
    LCode := ESQLDatabaseError(E).ErrorCode;
    if SameText(LType, 'Firebird') then
      Result := (LCode = ISC_LOCK_TIMEOUT) or (LCode = ISC_LOCK_CONFLICT) or
        (LCode = ISC_DEADLOCK) or (LCode = ISC_UPDATE_CONFLICT)
    else if SameText(LType, 'SQLite3') then
      Result := (LCode = SQLITE_BUSY) or (LCode = SQLITE_LOCKED)
    else if IsMySQLConnector(LType) then
      Result := (LCode = MYSQL_ER_LOCK_WAIT_TIMEOUT) or (LCode = MYSQL_ER_LOCK_DEADLOCK);
  end;
end;

// See the unit header: SQLite's "schema changed", which a new prepare fixes.
function IsSQLiteSchemaChanged(E: Exception; ADataBase: TDatabase): Boolean;
begin
  Result := (E is ESQLDatabaseError) and (ESQLDatabaseError(E).ErrorCode = SQLITE_SCHEMA)
    and (ADataBase is TSQLConnector) and SameText(TSQLConnector(ADataBase).ConnectorType, 'SQLite3');
end;

// One TSQLDBLibraryLoader per (type, path), alive for the whole process.
procedure PdbSQLdbUseClientLibrary(const AConnectorType, ALibrary: string);
var
  I: Integer;
  LLoader: TSQLDBLibraryLoader;
begin
  if ALibrary = '' then
    Exit;
  PdbPreloadClientLibrary(ALibrary);
  for I := 0 to GLibraryLoaders.Count - 1 do
  begin
    LLoader := TSQLDBLibraryLoader(GLibraryLoaders[I]);
    if SameText(LLoader.ConnectionType, AConnectorType) and SameText(LLoader.LibraryName, ALibrary) then
      Exit;
  end;
  LLoader := TSQLDBLibraryLoader.Create(nil);
  try
    LLoader.ConnectionType := AConnectorType;
    LLoader.LibraryName := ALibrary;
    LLoader.Enabled := True;
  except
    LLoader.Free;
    raise;
  end;
  GLibraryLoaders.Add(LLoader);
end;

{ TSQLdbConnectionAdapter }

constructor TSQLdbConnectionAdapter.Create(AConnection: TPdbSQLConnector; const ASQLDialect: ISQLDialect);
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
  ApplySessionSettings(FConnection);
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
  if FTransaction.DataBase is TPdbSQLConnector then
    FTransaction.Params.CommaText := FirebirdLockTimeoutTPB(TPdbSQLConnector(FTransaction.DataBase));
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
  begin
    FTransaction.StartTransaction;
    // Counts the transactions started, so a query can tell that the one it
    // prepared a statement in has ended (see TSQLdbQueryAdapter.DoExecSql).
    FTransaction.Tag := FTransaction.Tag + 1;
  end;
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
    try
      LQuery.ExecSQL;
    except
      on E: Exception do
      begin
        if not IsSQLiteSchemaChanged(E, LQuery.DataBase) then
          raise;
        LQuery.UnPrepare;
        LQuery.ExecSQL;
      end;
    end;
  finally
    LQuery.Free;
  end;
end;

function TSQLdbTransactionAdapter.IsLockConflictError(E: Exception): Boolean;
begin
  Result := IsSQLdbLockConflict(E, FTransaction.DataBase);
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
  // By default SQLdb looks the table's primary key up in the catalog on every
  // Open, to make the dataset editable; the adapter never edits it. Measured
  // (FPC 3.2.2, Windows, 2000 SELECTs by key): PostgreSQL 12.2 s -> 3.6 s,
  // Firebird 2.0 s -> 0.6 s.
  FQuery.UsePrimaryKeyAsKey := False;
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
  try
    // Prepared explicitly, so it stays prepared for the next ExecSql with the
    // same SQL: a statement SQLdb prepares by itself is unprepared right after
    // it runs (measured, 2000 INSERTs on PostgreSQL: 3.7 s implicit, 1.4 s
    // explicit). Only here, not in DoOpen: an explicitly prepared SELECT
    // reopened on Firebird raised an access violation inside TSQLQuery.Open
    // (FPC 3.2.2) on the second Open.
    // Only within one transaction: SQLdb ties a prepared statement to the
    // transaction it was prepared in. Reused after a commit, it failed on
    // Firebird ("invalid transaction handle") and hung on PostgreSQL (the
    // PostgreSQL connector takes a server connection per transaction).
    if FQuery.Prepared and ((not FQuery.SQLTransaction.Active) or
      (FQuery.SQLTransaction.Tag <> FPreparedIn)) then
      FQuery.UnPrepare;
    if not FQuery.Prepared then
    begin
      FQuery.Prepare;
      FPreparedIn := FQuery.SQLTransaction.Tag;
    end;
    FQuery.ExecSQL;
  except
    on E: Exception do
    begin
      if not IsSQLiteSchemaChanged(E, FQuery.DataBase) then
        raise;
      FQuery.UnPrepare;
      FQuery.ExecSQL;
    end;
  end;
end;

procedure TSQLdbQueryAdapter.DoOpen;
begin
  // Left prepared by DoExecSql (the same SQL run with ExecSql, then opened):
  // SQLdb must prepare it itself here, see DoExecSql.
  if FQuery.Prepared then
    FQuery.UnPrepare;
  try
    FQuery.Open;
  except
    on E: Exception do
    begin
      if not IsSQLiteSchemaChanged(E, FQuery.DataBase) then
        raise;
      if FQuery.Active then
        FQuery.Close;
      FQuery.UnPrepare;
      FQuery.Open;
    end;
  end;
end;

procedure TSQLdbQueryAdapter.DoClearParams;
begin
  FQuery.Params.Clear;
end;

function TSQLdbQueryAdapter.ResetParamValues: Boolean;
var
  I: Integer;
begin
  // Values only: the parameters (and the prepared statement) stay.
  for I := 0 to FQuery.Params.Count - 1 do
    FQuery.Params[I].Clear;
  Result := True;
end;

function TSQLdbQueryAdapter.CreateParams: IParams;
begin
  Result := TDBParams.Create(FQuery.Params);
end;

function TSQLdbQueryAdapter.IsLockConflictError(E: Exception): Boolean;
begin
  Result := IsSQLdbLockConflict(E, FQuery.DataBase);
end;

{ TSQLdbProvider }

function TSQLdbProvider.BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
var
  LConn: TPdbSQLConnector;
  LParams: TStrings;
  I: Integer;
  LName, LValue: string;
begin
  LParams := AConfig.ConnectionParams;
  if LParams.Values['ConnectorType'] = '' then
    raise EDatabaseError.Create('PascalDb.Adapter.SQLdb: ConnectionParams must set ConnectorType (the SQLdb connector name, e.g. Firebird, PostgreSQL or SQLite3)');
  PdbSQLdbUseClientLibrary(LParams.Values['ConnectorType'], LParams.Values['ClientLibrary']);

  LConn := TPdbSQLConnector.Create(nil);
  try
    LConn.LoginPrompt := False;
    LConn.LockTimeoutMs := AConfig.LockTimeoutMs;
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
      else if SameText(LName, 'ClientLibrary') then
        // handled by PdbSQLdbUseClientLibrary
      else if SameText(LName, 'SkipLibraryVersionCheck') then
        LConn.SkipLibraryVersionCheck := SameText(LValue, 'true') or (LValue = '1')
      // Settings with no value are left out: FPC's Values[Name] := '' keeps
      // a "Name=" line (Delphi deletes it), and PostgreSQL's connection
      // string reads the next option as the value of an empty "port=".
      else if LValue = '' then
      else if SameText(LName, 'Port') then
        LConn.Params.Values['port'] := LValue
      else if LName <> '' then
        LConn.Params.Values[LName] := LValue;
    end;
    ApplyPostgresLockTimeout(LConn);
    LConn.Open;
    ApplySessionSettings(LConn);
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
  const AContextTransactionProvider: IContextTransactionProvider; AOnPoolEvent: TPoolEventProc;
  AOnStatement: TStatementEventProc);
begin
  inherited Create(AConfig, TSQLdbProvider.Create, AContextTransactionProvider, AOnPoolEvent, AOnStatement);
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
