unit PascalDb.Adapter.SQLdb;

{$I pascaldb.inc}

{ SQLdb adapter (Free Pascal / Lazarus only): IDBFactory over TSQLConnector,
  TSQLTransaction and TSQLQuery. Everything that isn't SQLdb-specific comes
  from PascalDb.Adapter.Base / PascalDb.Adapter.DataSet.

  Connection settings (IDatabaseConfig.ConnectionParams, Name=Value):
    ConnectorType  SQLdb connector name (required). 'Firebird', 'PostgreSQL',
                   'SQLite3', 'MySQL 5.7', 'MySQL 8.0' and 'ODBC' are
                   registered by this unit (the MySQL ones talk to MariaDB
                   servers too; with MariaDB Connector/C use 'MySQL 5.7', see
                   below; 'ODBC' is for SQL Server, see below); for another
                   one, add its connection unit to the program's uses
                   (e.g. oracleconnection for 'Oracle') and register an SQL
                   dialect for it (docs/other-databases.md)
    HostName       server host ('' = local/embedded, Firebird; unused by
                   SQLite); SQL Server: host or host\instance
    Port           server port (optional)
    DatabaseName   database path (Firebird, SQLite: the file, created on
                   first connect) or name (PostgreSQL, MySQL/MariaDB, SQL
                   Server)
    Driver         SQL Server only: the ODBC driver's name, e.g. ODBC Driver
                   18 for SQL Server
    UserName, Password
    CharSet        connection character set (e.g. UTF8; MySQL/MariaDB:
                   utf8mb4, since their utf8 has no 4-byte characters)
    BusyTimeout    SQLite only: milliseconds a statement waits for another
                   connection's write lock before failing with "database is
                   locked" (default: IDatabaseConfig.LockTimeoutMs, or 5000
                   when that is 0)
    ClientLibrary  full path of the client library (fbclient/libpq/sqlite3/
                   libmysqlclient/libmariadb; SQL Server: the ODBC driver
                   manager, odbc32.dll or libodbc) when it isn't found on the
                   default search path (optional)
    SkipLibraryVersionCheck
                   MySQL only: true to connect with a client library of
                   another version than the connector's (see below)
    MYSQL_PLUGIN_DIR
                   MySQL only: the client's plugin folder (default: the
                   plugin folder next to ClientLibrary, if there is one;
                   see PdbMySQLPluginDir)
    foreign_keys   SQLite only: ON (default) or OFF, SQLite's own pragma
                   (SQLdb runs it when the connection opens)
  Any other line is passed to the connection's Params as is (SQL Server:
  keywords of the ODBC connection string, e.g. TrustServerCertificate=yes or
  Encrypt=no).

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
  - SQLite checks foreign keys only when the connection asks for it: SQLite
    connections get foreign_keys=ON unless the settings set it.
  - Constraint violations become EConstraintViolationException (the codes
    are in PascalDb.Adapter.Base): ESQLDatabaseError.ErrorCode (Firebird's
    GDS code, MySQL's and SQL Server's error number, SQLite's extended code,
    which sqlite3conn turns on), EPQDatabaseError.SQLSTATE. A COMMIT that
    fails on SQLite (a deferred foreign key) raises a plain EDatabaseError
    with SQLite's message only, which is recognized by its text.
  - PostgreSQL: a COMMIT that fails (a deferred constraint, a serialization
    failure) makes the connector close that transaction's server connection
    (TPQConnection.CheckResultError calls PQfinish), so the Rollback that
    must follow failed with "connection pointer is NULL" and the
    transaction's handle leaked (measured: 268 unfreed blocks). DoCommit then
    rolls back with the connector's ForcedClose set, the path SQLdb itself
    takes on a forced disconnect: the failure is ignored and the
    transaction ends; the next one gets a new server connection.
  - Rows affected: TSQLQuery.RowsAffected. MySQL/MariaDB count only the rows
    an UPDATE changed unless the client connects with CLIENT_FOUND_ROWS,
    and FPC 3.2.2's MySQL connectors pass fixed client flags to
    mysql_real_connect (no setting for it). The matched rows are read from
    mysql_info right after the statement ("Rows matched: N  Changed: M
    Warnings: W", sent by the server after an UPDATE), so an UPDATE counts
    the rows it matched, as on the other databases.
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
    The connectors also differ in how they number mysql_options: FPC's
    'MySQL 8.0' header follows MySQL 8.0, which dropped five options from
    the middle of the list, while MariaDB Connector/C keeps 5.7's numbering.
    Any connection option set through the 8.0 connector reaches libmariadb
    as another option: with MYSQL_PLUGIN_DIR set, every connection failed
    with "Server connect failed" (FPC 3.2.2, Windows, libmariadb 3.4.11,
    MySQL 8.4 and MariaDB 11.4), and with 'MySQL 5.7' all passed. So with
    MariaDB Connector/C use 'MySQL 5.7'; 'MySQL 8.0' is for Oracle's 8.0
    libmysqlclient.
    MYSQL_PLUGIN_DIR defaults to the plugin folder next to ClientLibrary
    (PdbMySQLPluginDir): the client looks for its authentication plugins
    (caching_sha2_password, MySQL 8's default) in a folder fixed when it was
    built.
    Parameters are replaced in the SQL text on the client (the connector has
    no server-side prepared statements), escaping backslashes as the server
    expects.
  - SQL Server goes through ODBC (ConnectorType=ODBC) with Microsoft's ODBC
    Driver 18, not through the db-lib connector (TMSSQLConnection, FreeTDS):
    that one keeps its error text in unit-level variables, and two
    connections failing at the same moment corrupted the heap (measured: FPC
    3.2.2, Linux, FreeTDS 1.3.17, 8 threads, "double free or corruption" in
    every run with concurrent errors); its sessions also start with the ANSI
    options off (a column declared without NULL comes out NOT NULL), and
    every error came as the generic 20018. Through ODBC the server's error
    number is the exception's ErrorCode and the session has the ANSI
    defaults. What this unit does for it: HostName/Port and DatabaseName
    become the connection string's Server=host[,port] and Database= (SQLdb's
    own DatabaseName is an ODBC DSN); ClientLibrary loads the driver manager
    (FPC 3.2.2's ODBC connector has no library loader for
    TSQLDBLibraryLoader, and on Unix it looks for libodbc.so, which only
    unixODBC's -dev package creates, so libodbc.so.2 is the default there);
    connections are opened one at a time, because the connector creates its
    shared ODBC environment on the first connect without a lock (measured: 7
    of 8 threads connecting at once failed with an access violation; with
    the connects serialized, 8 threads x 2000 statements clean, errors
    included); and the lock timeout is a SET LOCK_TIMEOUT run with
    SQLExecDirect on the connection's own handle when it opens: the connector
    prepares every statement, the driver runs a prepared one as a procedure
    (sp_prepexec), and a SET inside a procedure is undone when it returns
    (measured: @@LOCK_TIMEOUT back at -1 after the SET through SQLdb, 1000
    through SQLExecDirect, still 1000 after a commit). The same applies to
    any SET a program runs through a query. Lock errors: 1222 (lock request
    time out) and 1205 (deadlock victim). }

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
  odbcconn,
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
    /// ODBC only: runs ASql with SQLExecDirect on the open connection's own
    /// handle, outside SQLdb (see the unit header: session settings).
    procedure ExecDirectOnSession(const ASql: string);
    /// The rows the statement just run affected, given SQLdb's count: on
    /// MySQL/MariaDB, an UPDATE's matched rows (see the unit header).
    function MatchedRows(ARowsAffected: Int64): Int64;
    /// Rolls ATransaction back, ignoring a failure, and leaves it inactive
    /// (see the unit header: a failed COMMIT on PostgreSQL).
    procedure DiscardTransaction(ATransaction: TSQLTransaction);
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
    function DoExecSqlRows(const ASql: string): Int64; override;
    function IsLockConflictError(E: Exception): Boolean; override;
    function IsConstraintViolationError(E: Exception; out AKind: TConstraintViolationKind): Boolean; override;
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
    function RowsAffected: Int64; override;
    function IsLockConflictError(E: Exception): Boolean; override;
    function IsConstraintViolationError(E: Exception; out AKind: TConstraintViolationKind): Boolean; override;
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

uses
  SyncObjs,
  odbcsqldyn,
  mysql57dyn,
  mysql80dyn;

var
  GLibraryLoaders: TList = nil;
  GODBCConnectLock: TCriticalSection = nil;
  GODBCLoaded: Boolean = False;

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
  MSSQL_LOCK_TIMEOUT = 1222;         // "Lock request time out period exceeded"
  MSSQL_DEADLOCK_VICTIM = 1205;      // "... was deadlocked ... and has been chosen as the deadlock victim"
  {$IFDEF UNIX}
  // See the unit header: unixODBC's runtime package has only the versioned name.
  DEFAULT_ODBC_LIBRARY = 'libodbc.so.2';
  {$ELSE}
  DEFAULT_ODBC_LIBRARY = '';
  {$ENDIF}

function IsMySQLConnector(const AConnectorType: string): Boolean;
begin
  Result := SameText(Copy(AConnectorType, 1, 5), 'MySQL');
end;

function IsODBCConnector(const AConnectorType: string): Boolean;
begin
  Result := SameText(AConnectorType, 'ODBC');
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
  // See the unit header: ODBC connections are opened one at a time.
  if not IsODBCConnector(ConnectorType) then
  begin
    inherited DoInternalConnect;
    Exit;
  end;
  GODBCConnectLock.Enter;
  try
    inherited DoInternalConnect;
  finally
    GODBCConnectLock.Leave;
  end;
end;

procedure TPdbSQLConnector.ExecDirectOnSession(const ASql: string);
var
  LStatement: SQLHSTMT;
  LResult: SQLRETURN;
  LSql: AnsiString;
begin
  CheckProxy;
  LResult := SQLAllocHandle(SQL_HANDLE_STMT, SQLHDBC(Proxy.Handle), LStatement);
  if not (LResult in [SQL_SUCCESS, SQL_SUCCESS_WITH_INFO]) then
    raise EDatabaseError.CreateFmt('PascalDb.Adapter.SQLdb: SQLAllocHandle failed (%d) for "%s"', [LResult, ASql]);
  try
    LSql := AnsiString(ASql);
    LResult := SQLExecDirect(LStatement, PAnsiChar(LSql), Length(LSql));
    if not (LResult in [SQL_SUCCESS, SQL_SUCCESS_WITH_INFO, SQL_NO_DATA]) then
      raise EDatabaseError.CreateFmt('PascalDb.Adapter.SQLdb: SQLExecDirect failed (%d) for "%s"', [LResult, ASql]);
  finally
    SQLFreeHandle(SQL_HANDLE_STMT, LStatement);
  end;
end;

// See the unit header: mysql_info has "Rows matched: N  Changed: M
// Warnings: W" after an UPDATE (and nothing, or another text, after other
// statements).
function TPdbSQLConnector.MatchedRows(ARowsAffected: Int64): Int64;
const
  PREFIX = 'Rows matched:';
var
  LInfo: PAnsiChar;
  LText: string;
  I: Integer;
begin
  Result := ARowsAffected;
  if not IsMySQLConnector(ConnectorType) then
    Exit;
  CheckProxy;
  if Proxy is TMySQL80Connection then
    LInfo := mysql80dyn.mysql_info(mysql80dyn.PMYSQL(Proxy.Handle))
  else
    LInfo := mysql57dyn.mysql_info(mysql57dyn.PMYSQL(Proxy.Handle));
  if LInfo = nil then
    Exit;
  LText := string(LInfo);
  if Copy(LText, 1, Length(PREFIX)) <> PREFIX then
    Exit;
  LText := TrimLeft(Copy(LText, Length(PREFIX) + 1, MaxInt));
  I := 1;
  while (I <= Length(LText)) and (LText[I] in ['0'..'9']) do
    Inc(I);
  Result := StrToInt64Def(Copy(LText, 1, I - 1), ARowsAffected);
end;

// See the unit header: AttemptRollBack ignores the failure while ForcedClose
// is set, and then frees the transaction's handle, as a forced close does.
procedure TPdbSQLConnector.DiscardTransaction(ATransaction: TSQLTransaction);
begin
  if not ATransaction.Active then
    Exit;
  ForcedClose := True;
  try
    try
      ATransaction.Rollback;
    except
      // ignored: the server already ended the transaction
    end;
  finally
    ForcedClose := False;
  end;
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

// See the unit header: SQL Server's lock timeout, on the session itself.
procedure ApplySqlServerLockTimeout(AConn: TPdbSQLConnector);
begin
  if (AConn.LockTimeoutMs > 0) and IsODBCConnector(AConn.ConnectorType) then
    AConn.ExecDirectOnSession('SET LOCK_TIMEOUT ' + IntToStr(AConn.LockTimeoutMs));
end;

// Everything a connection needs right after it opens (also on a reconnect).
procedure ApplySessionSettings(AConn: TPdbSQLConnector);
begin
  ApplySQLiteBusyTimeout(AConn);
  ApplyMySQLLockTimeout(AConn);
  ApplySqlServerLockTimeout(AConn);
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
      Result := (LCode = MYSQL_ER_LOCK_WAIT_TIMEOUT) or (LCode = MYSQL_ER_LOCK_DEADLOCK)
    else if IsODBCConnector(LType) then
      Result := (LCode = MSSQL_LOCK_TIMEOUT) or (LCode = MSSQL_DEADLOCK_VICTIM);
  end;
end;

// See the unit header: the driver's constraint violations.
function IsSQLdbConstraintViolation(E: Exception; ADataBase: TDatabase;
  out AKind: TConstraintViolationKind): Boolean;
var
  LType: string;
  LCode: Integer;
begin
  Result := False;
  AKind := cvUnique;
  if not (ADataBase is TSQLConnector) then
    Exit;
  LType := TSQLConnector(ADataBase).ConnectorType;
  if E is EPQDatabaseError then
    Result := PdbPostgresConstraintKind(EPQDatabaseError(E).SQLSTATE, AKind)
  // A failed COMMIT on SQLite (a deferred foreign key) is a plain
  // EDatabaseError with SQLite's message only.
  else if SameText(LType, 'SQLite3') and (E is EDatabaseError) then
  begin
    if E is ESQLDatabaseError then
      LCode := ESQLDatabaseError(E).ErrorCode
    else
      LCode := 0;
    Result := PdbSQLiteConstraintKind(LCode, E.Message, AKind);
  end
  else if E is ESQLDatabaseError then
  begin
    LCode := ESQLDatabaseError(E).ErrorCode;
    if SameText(LType, 'Firebird') then
      Result := PdbFirebirdConstraintKind(LCode, E.Message, AKind)
    else if IsMySQLConnector(LType) then
      Result := PdbMySQLConstraintKind(LCode, AKind)
    else if IsODBCConnector(LType) then
      Result := PdbSqlServerConstraintKind(LCode, E.Message, AKind);
  end;
end;

// See the unit header: SQLite's "schema changed", which a new prepare fixes.
function IsSQLiteSchemaChanged(E: Exception; ADataBase: TDatabase): Boolean;
begin
  Result := (E is ESQLDatabaseError) and (ESQLDatabaseError(E).ErrorCode = SQLITE_SCHEMA)
    and (ADataBase is TSQLConnector) and SameText(TSQLConnector(ADataBase).ConnectorType, 'SQLite3');
end;

// See the unit header: the ODBC driver manager, loaded once for the process
// (InitialiseODBC counts references, so the connector's own later calls,
// without a name, reuse it).
procedure UseODBCLibrary(const ALibrary: string);
begin
  if GODBCLoaded or (ALibrary = '') then
    Exit;
  GODBCConnectLock.Enter;
  try
    if not GODBCLoaded then
    begin
      PdbPreloadClientLibrary(ALibrary);
      InitialiseODBC(ALibrary);
      GODBCLoaded := True;
    end;
  finally
    GODBCConnectLock.Leave;
  end;
end;

// One TSQLDBLibraryLoader per (type, path), alive for the whole process.
procedure PdbSQLdbUseClientLibrary(const AConnectorType, ALibrary: string);
var
  I: Integer;
  LLoader: TSQLDBLibraryLoader;
begin
  if IsODBCConnector(AConnectorType) then
  begin
    if ALibrary <> '' then
      UseODBCLibrary(ALibrary)
    else
      UseODBCLibrary(DEFAULT_ODBC_LIBRARY);
    Exit;
  end;
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
  if not FTransaction.Active then
    Exit;
  try
    FTransaction.Commit;
  except
    // See the unit header: the PostgreSQL connector has already closed the
    // transaction's server connection; leave the transaction inactive.
    if SameText((FTransaction.DataBase as TPdbSQLConnector).ConnectorType, 'PostgreSQL') then
      (FTransaction.DataBase as TPdbSQLConnector).DiscardTransaction(FTransaction);
    raise;
  end;
end;

procedure TSQLdbTransactionAdapter.DoRollback;
begin
  if FTransaction.Active then
    FTransaction.Rollback;
end;

procedure TSQLdbTransactionAdapter.DoExecSql(const ASql: string);
begin
  DoExecSqlRows(ASql);
end;

function TSQLdbTransactionAdapter.DoExecSqlRows(const ASql: string): Int64;
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
    Result := (LQuery.DataBase as TPdbSQLConnector).MatchedRows(LQuery.RowsAffected);
  finally
    LQuery.Free;
  end;
end;

function TSQLdbTransactionAdapter.IsLockConflictError(E: Exception): Boolean;
begin
  Result := IsSQLdbLockConflict(E, FTransaction.DataBase);
end;

function TSQLdbTransactionAdapter.IsConstraintViolationError(E: Exception;
  out AKind: TConstraintViolationKind): Boolean;
begin
  Result := IsSQLdbConstraintViolation(E, FTransaction.DataBase, AKind);
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

function TSQLdbQueryAdapter.RowsAffected: Int64;
begin
  Result := (FQuery.DataBase as TPdbSQLConnector).MatchedRows(FQuery.RowsAffected);
end;

function TSQLdbQueryAdapter.IsLockConflictError(E: Exception): Boolean;
begin
  Result := IsSQLdbLockConflict(E, FQuery.DataBase);
end;

function TSQLdbQueryAdapter.IsConstraintViolationError(E: Exception;
  out AKind: TConstraintViolationKind): Boolean;
begin
  Result := IsSQLdbConstraintViolation(E, FQuery.DataBase, AKind);
end;

{ TSQLdbProvider }

function TSQLdbProvider.BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
var
  LConn: TPdbSQLConnector;
  LParams: TStrings;
  I: Integer;
  LName, LValue, LServer, LPort: string;
  LIsODBC: Boolean;
begin
  LParams := AConfig.ConnectionParams;
  if LParams.Values['ConnectorType'] = '' then
    raise EDatabaseError.Create('PascalDb.Adapter.SQLdb: ConnectionParams must set ConnectorType (the SQLdb connector name, e.g. Firebird, PostgreSQL or SQLite3)');
  PdbSQLdbUseClientLibrary(LParams.Values['ConnectorType'], LParams.Values['ClientLibrary']);
  LIsODBC := IsODBCConnector(LParams.Values['ConnectorType']);
  LServer := '';
  LPort := '';

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
      // See the unit header: ODBC takes these in the connection string.
      else if LIsODBC and SameText(LName, 'HostName') then
        LServer := LValue
      else if LIsODBC and SameText(LName, 'Port') then
        LPort := LValue
      else if LIsODBC and SameText(LName, 'DatabaseName') then
      begin
        if LValue <> '' then
          LConn.Params.Values['Database'] := LValue;
      end
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
    if LIsODBC and (LServer <> '') then
    begin
      if LPort <> '' then
        LServer := LServer + ',' + LPort;
      LConn.Params.Values['Server'] := LServer;
    end;
    ApplyPostgresLockTimeout(LConn);
    // See the unit header: SQLite checks foreign keys only when asked to.
    if SameText(LConn.ConnectorType, 'SQLite3') and (LParams.IndexOfName('foreign_keys') < 0) then
      LConn.Params.Values['foreign_keys'] := 'ON';
    if IsMySQLConnector(LConn.ConnectorType) and (LParams.Values['MYSQL_PLUGIN_DIR'] = '') and
      (PdbMySQLPluginDir(LParams.Values['ClientLibrary']) <> '') then
      LConn.Params.Values['MYSQL_PLUGIN_DIR'] := PdbMySQLPluginDir(LParams.Values['ClientLibrary']);
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
  GODBCConnectLock := TCriticalSection.Create;

finalization
  FreeLibraryLoaders;
  if GODBCLoaded then
    ReleaseODBC;
  GODBCConnectLock.Free;

end.
