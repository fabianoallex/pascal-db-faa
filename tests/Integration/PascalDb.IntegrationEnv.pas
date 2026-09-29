unit PascalDb.IntegrationEnv;

{ The integration suite's environment: a fresh database per run (Firebird,
  PostgreSQL, SQLite, MySQL or MariaDB), migrated with the library's own migration engine, and the
  IDBFactory the contract tests run against. This is the only
  adapter-specific part of the integration suite: on FPC the factory is the
  SQLdb adapter's; on Delphi it is the FireDAC adapter's; with
  PASCALDB_IT_ZEOS defined (the *Zeos* runners), it is the Zeos adapter's on
  both. The tests themselves (PascalDb.ContractTests) only see IDBFactory, so
  the same test bodies validate every adapter on every database.

  Settings (environment variables, all optional):
    PASCALDB_IT_ENGINE    firebird (default), postgresql, sqlite, mysql or
                          mariadb (the last two: Zeos runners only, so far)
    PASCALDB_IT_HOST      server host (default localhost, over TCP). Firebird:
                          'local' = the local protocol (path only), which
                          fails intermittently with concurrent connections on
                          Firebird 2.5 (CLAUDE.md, gotcha 29). Unused by
                          SQLite
    PASCALDB_IT_PORT      server port (default: the driver's; PostgreSQL 5432,
                          MySQL/MariaDB 3306)
    PASCALDB_IT_DATABASE  Firebird: database path on the server (default:
                          pascaldb_it.fdb next to the executable).
                          PostgreSQL, MySQL, MariaDB: database name
                          (default pascaldb_it).
                          SQLite: database file (default pascaldb_it.sqlite
                          next to the executable)
    PASCALDB_IT_USER      default SYSDBA / postgres / root (MySQL, MariaDB)
    PASCALDB_IT_PASSWORD  default masterkey / postgres / root
    PASCALDB_IT_CLIENT    full path of the client library
                          (fbclient/libpq/sqlite3/libmysql/libmariadb). When empty on Windows:
                          Firebird, the client of a default Firebird 2.5
                          64-bit install that matches the executable's
                          bitness (bin or WOW64); PostgreSQL (64-bit only),
                          bin\libpq.dll of the newest install under
                          C:\Program Files\PostgreSQL. Otherwise the
                          driver's default search. FireDAC links SQLite into
                          the program: no client library.

  The database is dropped (if it exists) and created on first use, and
  dropped again at the end of the run. PostgreSQL, MySQL and MariaDB
  databases are created and dropped with SQL through a maintenance database
  (postgres; mysql), outside any transaction.
  A SQLite database is a file: the first connection creates it, and dropping
  it is deleting the file (with its -journal/-wal/-shm companions).
  Zeos has no call of its own to drop a Firebird database; the Zeos runners
  use PdbZeosDropFirebirdDatabase (PascalDb.Adapter.Zeos), which works on a
  remote server too. }

interface

uses
  Classes,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.Pool;

/// The factory the contract tests use; created (with a fresh, migrated
/// database) on first call.
function IntegrationFactory: IDBFactory;

/// Number of migrations IntegrationFactory applies.
function IntegrationSchemaVersion: Integer;

/// Whether the database has INSERT ... RETURNING (MySQL doesn't; MariaDB has
/// it since 10.5).
function SupportsReturning: Boolean;

/// A SELECT returning the server's id of the current session in column SID,
/// or '' when the database has no such thing (SQLite: no server).
function SessionIdSql: string;

/// PoolMaxConnections of IntegrationFactory's configuration.
function IntegrationPoolMax: Integer;

/// A factory with the same settings as IntegrationFactory's, except that no
/// connection can be opened: servers get a host name that never resolves,
/// SQLite a database file in a folder that doesn't exist. A new one on each
/// call; nothing is created or dropped.
function UnreachableFactory: IDBFactory;

/// A factory for IntegrationFactory's database (call IntegrationFactory
/// first) with LockTimeoutMs set to AMs. A new one on each call, with no
/// initial connections; nothing is created or dropped.
function LockTimeoutFactory(AMs: Integer): IDBFactory;

/// A factory for IntegrationFactory's database (call IntegrationFactory
/// first) that reports every pooled statement to AOnStatement. A new one on
/// each call; nothing is created or dropped.
function StatementEventFactory(AOnStatement: TStatementEventProc): IDBFactory;

implementation

uses
  PascalDb.SqlSources,
  PascalDb.Migrations,
  PascalDb.Adapter.Base
  {$IF DEFINED(PASCALDB_IT_ZEOS)}
  , ZConnection
  , PascalDb.Adapter.Zeos
  {$ELSEIF DEFINED(FPC)}
  , sqldb
  , ibconnection
  , pqconnection
  , PascalDb.Adapter.SQLdb
  {$ELSE}
  , FireDAC.Comp.Client
  , PascalDb.Adapter.FireDAC
  {$IFEND};

const
  SQL_DIRECTORY = 'IT';
  // Firebird 2.5 64-bit default install: the 64-bit client in bin, the 32-bit
  // one in WOW64 — the client must match the test executable's bitness.
  // (Delphi defines CPU64BITS, FPC defines CPU64.)
  DEFAULT_FB25_CLIENT = {$IF DEFINED(CPU64) or DEFINED(CPU64BITS)}'C:\Program Files\Firebird\Firebird_2_5\bin\fbclient.dll'
    {$ELSE}'C:\Program Files\Firebird\Firebird_2_5\WOW64\fbclient.dll'{$IFEND};
  // PostgreSQL ships no 32-bit Windows client: 64-bit test executables only.
  PG_INSTALL_ROOT = 'C:\Program Files\PostgreSQL\';
  // The databases PostgreSQL and MySQL/MariaDB connections use to create/drop
  // the test database.
  PG_MAINTENANCE_DB = 'postgres';
  MYSQL_MAINTENANCE_DB = 'mysql';

var
  GFactory: IDBFactory = nil;

function Env(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

type
  TEngine = (engFirebird, engPostgres, engSQLite, engMySQL, engMariaDB);

function Engine: TEngine;
var
  LEngine: string;
begin
  LEngine := LowerCase(Env('PASCALDB_IT_ENGINE', 'firebird'));
  if LEngine = 'firebird' then
    Result := engFirebird
  else if LEngine = 'postgresql' then
    Result := engPostgres
  else if LEngine = 'sqlite' then
    Result := engSQLite
  else if LEngine = 'mysql' then
    Result := engMySQL
  else if LEngine = 'mariadb' then
    Result := engMariaDB
  else
    raise Exception.CreateFmt('PASCALDB_IT_ENGINE must be firebird, postgresql, sqlite, mysql or mariadb, not "%s"', [LEngine]);
end;

function IsPostgres: Boolean;
begin
  Result := Engine = engPostgres;
end;

function IsSQLite: Boolean;
begin
  Result := Engine = engSQLite;
end;

// MySQL or MariaDB: same SQL, same client libraries, same dialect class.
function IsMySQL: Boolean;
begin
  Result := Engine in [engMySQL, engMariaDB];
end;

function SupportsReturning: Boolean;
begin
  Result := Engine <> engMySQL;
end;

function Host: string;
begin
  // Firebird defaults to TCP too, not the local protocol: with Firebird 2.5
  // on Windows, several connections opened at once through the local
  // protocol sometimes failed with "connection lost to database" (see
  // CLAUDE.md, gotcha 29). 'local' still selects it.
  Result := Env('PASCALDB_IT_HOST', 'localhost');
  if SameText(Result, 'local') then
    Result := '';
end;

function Port: string;
begin
  Result := Env('PASCALDB_IT_PORT', '');
end;

function DatabaseName: string;
begin
  case Engine of
    engPostgres, engMySQL, engMariaDB: Result := Env('PASCALDB_IT_DATABASE', 'pascaldb_it');
    engSQLite: Result := Env('PASCALDB_IT_DATABASE', ExtractFilePath(ParamStr(0)) + 'pascaldb_it.sqlite');
  else
    Result := Env('PASCALDB_IT_DATABASE', ExtractFilePath(ParamStr(0)) + 'pascaldb_it.fdb');
  end;
end;

// SQLite: the database file and the companions the engine may leave next to it.
procedure DeleteSQLiteFiles;
const
  SUFFIXES: array[0..3] of string = ('', '-journal', '-wal', '-shm');
var
  LSuffix: string;
begin
  for LSuffix in SUFFIXES do
    if FileExists(DatabaseName + LSuffix) then
      DeleteFile(DatabaseName + LSuffix);
end;

function UserName: string;
begin
  if IsPostgres then
    Result := Env('PASCALDB_IT_USER', 'postgres')
  else if IsMySQL then
    Result := Env('PASCALDB_IT_USER', 'root')
  else
    Result := Env('PASCALDB_IT_USER', 'SYSDBA');
end;

function Password: string;
begin
  if IsPostgres then
    Result := Env('PASCALDB_IT_PASSWORD', 'postgres')
  else if IsMySQL then
    Result := Env('PASCALDB_IT_PASSWORD', 'root')
  else
    Result := Env('PASCALDB_IT_PASSWORD', 'masterkey');
end;

{$IFDEF MSWINDOWS}
// bin\libpq.dll of the newest install under C:\Program Files\PostgreSQL
// (folders named by major version: 16, 17, 18, ...).
function DefaultLibPq: string;
var
  LSearch: TSearchRec;
  LBest, LVersion: Integer;
begin
  Result := '';
  {$IF DEFINED(CPU64) or DEFINED(CPU64BITS)}
  LBest := -1;
  if FindFirst(PG_INSTALL_ROOT + '*', faDirectory, LSearch) = 0 then
  try
    repeat
      LVersion := StrToIntDef(LSearch.Name, -1);
      if (LVersion > LBest) and FileExists(PG_INSTALL_ROOT + LSearch.Name + '\bin\libpq.dll') then
      begin
        LBest := LVersion;
        Result := PG_INSTALL_ROOT + LSearch.Name + '\bin\libpq.dll';
      end;
    until FindNext(LSearch) <> 0;
  finally
    FindClose(LSearch);
  end;
  {$IFEND}
end;
{$ENDIF}

function ClientLibrary: string;
begin
  Result := Env('PASCALDB_IT_CLIENT', '');
  {$IFDEF MSWINDOWS}
  if Result = '' then
  begin
    if IsPostgres then
      Result := DefaultLibPq
    else if (Engine = engFirebird) and FileExists(DEFAULT_FB25_CLIENT) then
      Result := DEFAULT_FB25_CLIENT;
  end;
  {$ENDIF}
end;

function IntegrationSchemaVersion: Integer;
begin
  Result := 2;
end;

function BuildSqlSource: ISqlSource;
var
  LUtf8: string;
begin
  // Firebird: the text columns are declared UTF8 (the database default
  // character set is NONE). PostgreSQL: the database encoding (UTF8 in the
  // official images) applies to every column; MySQL/MariaDB: the database's
  // (created utf8mb4). SQLite stores text as UTF-8.
  if Engine = engFirebird then
    LUtf8 := ' CHARACTER SET UTF8'
  else
    LUtf8 := '';
  Result := TMemorySqlSource.Create
    .Add(SQL_DIRECTORY, 'MIG.0001',
      'CREATE TABLE SCHEMA_MIGRATIONS (' +
      '  VERSION    INTEGER   NOT NULL,' +
      '  APPLIED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,' +
      '  CONSTRAINT PK_SCHEMA_MIGRATIONS PRIMARY KEY (VERSION))')
    .Add(SQL_DIRECTORY, 'MIG.0002',
      'CREATE TABLE ITEMS (' +
      '  ID         INTEGER NOT NULL,' +
      '  NAME       VARCHAR(100)' + LUtf8 + ',' +
      '  QTY        INTEGER,' +
      '  BIG        BIGINT,' +
      '  PRICE      NUMERIC(15,2),' +
      '  RATIO      DOUBLE PRECISION,' +
      '  CREATED_AT TIMESTAMP,' +
      '  ACTIVE     SMALLINT,' +
      '  NOTE       VARCHAR(100)' + LUtf8 + ' DEFAULT ''default note'',' +
      '  CONSTRAINT PK_ITEMS PRIMARY KEY (ID),' +
      '  CONSTRAINT UQ_ITEMS_NAME UNIQUE (NAME))^' +
      'CREATE TABLE LOG_LINES (ID INTEGER NOT NULL PRIMARY KEY, TXT VARCHAR(50))^')
    .Add(SQL_DIRECTORY, 'ITEMS.INSERT',
      'INSERT INTO ITEMS (ID, NAME, QTY, BIG, PRICE, RATIO, CREATED_AT, ACTIVE' +
      '  [NOTE {], NOTE [} NOTE])' +
      ' VALUES (:ID, :NAME, :QTY, :BIG, :PRICE, :RATIO, :CREATED_AT, :ACTIVE' +
      '  [NOTE {], :NOTE [} NOTE])')
    .Add(SQL_DIRECTORY, 'ITEMS.BY_ID', 'SELECT * FROM ITEMS WHERE ID = :ID');
end;

{ Adapter-specific part: connection settings, database creation and removal,
  and the factory. }

{$IF DEFINED(PASCALDB_IT_ZEOS)}

procedure SetConnectionParams(AParams: TStrings; const ADatabase: string);
begin
  // Zeos connection settings (see PascalDb.Adapter.Zeos)
  case Engine of
    engPostgres: AParams.Values['Protocol'] := 'postgresql';
    engSQLite: AParams.Values['Protocol'] := 'sqlite';
    engMySQL: AParams.Values['Protocol'] := 'mysql';
    engMariaDB: AParams.Values['Protocol'] := 'mariadb';
  else
    AParams.Values['Protocol'] := 'firebird';
  end;
  AParams.Values['HostName'] := Host;
  AParams.Values['Port'] := Port;
  AParams.Values['Database'] := ADatabase;
  AParams.Values['User'] := UserName;
  AParams.Values['Password'] := Password;
  if IsMySQL then
    AParams.Values['ClientCodepage'] := 'utf8mb4'
  else
    AParams.Values['ClientCodepage'] := 'UTF8';
  AParams.Values['LibraryLocation'] := ClientLibrary;
end;

// PostgreSQL, MySQL, MariaDB: CREATE/DROP DATABASE through the maintenance
// database, with the connection in auto-commit (TZConnection's default).
procedure ExecOnMaintenanceDb(const ASql: string);
var
  LSettings: TStringList;
  LConn: TZConnection;
begin
  LSettings := TStringList.Create;
  try
    if IsMySQL then
      SetConnectionParams(LSettings, MYSQL_MAINTENANCE_DB)
    else
      SetConnectionParams(LSettings, PG_MAINTENANCE_DB);
    LConn := PdbZeosNewConnection(LSettings);
  finally
    LSettings.Free;
  end;
  try
    LConn.Connect;
    LConn.ExecuteDirect(ASql);
    LConn.Disconnect;
  finally
    LConn.Free;
  end;
end;

procedure DropDatabase(const AConfig: IDatabaseConfig);
begin
  if IsSQLite then
  begin
    DeleteSQLiteFiles;
    Exit;
  end;
  if IsPostgres or IsMySQL then
  begin
    try
      ExecOnMaintenanceDb('DROP DATABASE IF EXISTS ' + DatabaseName);
    except
      // server unreachable: nothing to drop
    end;
  end
  else
  begin
    try
      PdbZeosDropFirebirdDatabase(AConfig.ConnectionParams);
    except
      // did not exist
    end;
    // Local database file left behind (e.g. the drop failed): remove it.
    if (Host = '') and FileExists(DatabaseName) then
      DeleteFile(DatabaseName);
  end;
end;

procedure CreateDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TZConnection;
begin
  DropDatabase(AConfig);
  if IsSQLite then
  begin
    // The first connection creates the file.
    if FileExists(DatabaseName) then
      raise Exception.CreateFmt('Could not delete the test database left by a previous run: %s (still in use?)', [DatabaseName]);
    Exit;
  end;
  if IsPostgres then
    ExecOnMaintenanceDb('CREATE DATABASE ' + DatabaseName)
  else if IsMySQL then
    ExecOnMaintenanceDb('CREATE DATABASE ' + DatabaseName + ' CHARACTER SET utf8mb4')
  else
  begin
    if (Host = '') and FileExists(DatabaseName) then
      raise Exception.CreateFmt('Could not delete the test database left by a previous run: %s (still in use?)', [DatabaseName]);
    LConn := PdbZeosNewConnection(AConfig.ConnectionParams);
    try
      LConn.Properties.Values['CreateNewDatabase'] := 'true';
      LConn.Connect;
      LConn.Disconnect;
    finally
      LConn.Free;
    end;
  end;
end;

function NewFactory(const AConfig: IDatabaseConfig; AOnStatement: TStatementEventProc = nil): IDBFactory;
begin
  Result := TZeosFactory.Create(AConfig, nil, nil, AOnStatement);
end;

{$ELSEIF DEFINED(FPC)}

procedure SetConnectionParams(AParams: TStrings; const ADatabase: string);
begin
  // SQLdb connection settings (see PascalDb.Adapter.SQLdb)
  if IsMySQL then
    raise Exception.Create('PASCALDB_IT_ENGINE=mysql/mariadb: only the Zeos runners support it so far');
  case Engine of
    engPostgres: AParams.Values['ConnectorType'] := 'PostgreSQL';
    engSQLite: AParams.Values['ConnectorType'] := 'SQLite3';
  else
    AParams.Values['ConnectorType'] := 'Firebird';
  end;
  AParams.Values['HostName'] := Host;
  AParams.Values['Port'] := Port;
  AParams.Values['DatabaseName'] := ADatabase;
  AParams.Values['UserName'] := UserName;
  AParams.Values['Password'] := Password;
  AParams.Values['CharSet'] := 'UTF8';
  AParams.Values['ClientLibrary'] := ClientLibrary;
end;

// A direct SQLdb connection to the test database — TIBConnection or
// TPQConnection, whose CreateDB/DropDB create and drop it (TPQConnection
// through the template1 database).
function NewDirectConnection: TSQLConnection;
begin
  // Before any direct SQLdb connection: the first client library loaded wins.
  if IsPostgres then
  begin
    PdbSQLdbUseClientLibrary('PostgreSQL', ClientLibrary);
    Result := TPQConnection.Create(nil);
  end
  else
  begin
    PdbSQLdbUseClientLibrary('Firebird', ClientLibrary);
    Result := TIBConnection.Create(nil);
    Result.CharSet := 'UTF8';
  end;
  Result.HostName := Host;
  Result.DatabaseName := DatabaseName;
  Result.UserName := UserName;
  Result.Password := Password;
  if Port <> '' then
    Result.Params.Values['port'] := Port;
  Result.LoginPrompt := False;
end;

procedure DropDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TSQLConnection;
begin
  if IsSQLite then
  begin
    DeleteSQLiteFiles;
    Exit;
  end;
  LConn := NewDirectConnection;
  try
    try
      LConn.DropDB;
    except
      // did not exist
    end;
  finally
    LConn.Free;
  end;
end;

procedure CreateDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TSQLConnection;
begin
  DropDatabase(AConfig);
  if IsSQLite then
  begin
    // The first connection creates the file.
    if FileExists(DatabaseName) then
      raise Exception.CreateFmt('Could not delete the test database left by a previous run: %s (still in use?)', [DatabaseName]);
    Exit;
  end;
  LConn := NewDirectConnection;
  try
    LConn.CreateDB;
  finally
    LConn.Free;
  end;
end;

function NewFactory(const AConfig: IDatabaseConfig; AOnStatement: TStatementEventProc = nil): IDBFactory;
begin
  Result := TSQLdbFactory.Create(AConfig, nil, nil, AOnStatement);
end;

{$ELSE}

procedure SetConnectionParams(AParams: TStrings; const ADatabase: string);
begin
  // FireDAC connection definition (see PascalDb.Adapter.FireDAC)
  if IsMySQL then
    raise Exception.Create('PASCALDB_IT_ENGINE=mysql/mariadb: only the Zeos runners support it so far');
  if IsSQLite then
  begin
    // No server, credentials or client library: the engine is in the program.
    AParams.Values['DriverID'] := 'SQLite';
    AParams.Values['Database'] := ADatabase;
    Exit;
  end;
  if IsPostgres then
    AParams.Values['DriverID'] := 'PG'
  else
    AParams.Values['DriverID'] := 'FB';
  if Host <> '' then
  begin
    AParams.Values['Server'] := Host;
    if not IsPostgres then
      AParams.Values['Protocol'] := 'TCPIP';
  end;
  if Port <> '' then
    AParams.Values['Port'] := Port;
  AParams.Values['Database'] := ADatabase;
  AParams.Values['User_Name'] := UserName;
  AParams.Values['Password'] := Password;
  AParams.Values['CharacterSet'] := 'UTF8';
  AParams.Values['VendorLib'] := ClientLibrary;
end;

function NewFDConnection(ASettings: TStrings; const AExtra: string): TFDConnection;
var
  I: Integer;
begin
  PdbFireDACUseVendorLib(ASettings.Values['DriverID'], ASettings.Values['VendorLib']);
  Result := TFDConnection.Create(nil);
  Result.LoginPrompt := False;
  Result.ResourceOptions.SilentMode := True;
  for I := 0 to ASettings.Count - 1 do
    if not SameText(ASettings.Names[I], 'VendorLib') then
      Result.Params.Add(ASettings[I]);
  if AExtra <> '' then
    Result.Params.Add(AExtra);
end;

// PostgreSQL: CREATE/DROP DATABASE through the maintenance database;
// TFDConnection.ExecSQL outside an explicit transaction runs in auto-commit.
procedure ExecOnMaintenanceDb(const ASql: string);
var
  LSettings: TStringList;
  LConn: TFDConnection;
begin
  LSettings := TStringList.Create;
  try
    SetConnectionParams(LSettings, PG_MAINTENANCE_DB);
    LConn := NewFDConnection(LSettings, '');
  finally
    LSettings.Free;
  end;
  try
    LConn.Connected := True;
    LConn.ExecSQL(ASql);
    LConn.Connected := False;
  finally
    LConn.Free;
  end;
end;

// Firebird: FireDAC's driver creates the database on connect with
// CreateDatabase=Yes and drops it on disconnect with DropDatabase=Yes.
procedure DropDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TFDConnection;
begin
  if IsSQLite then
  begin
    DeleteSQLiteFiles;
    Exit;
  end;
  if IsPostgres then
  begin
    try
      ExecOnMaintenanceDb('DROP DATABASE IF EXISTS ' + DatabaseName);
    except
      // server unreachable: nothing to drop
    end;
    Exit;
  end;
  LConn := NewFDConnection(AConfig.ConnectionParams, 'DropDatabase=Yes');
  try
    try
      LConn.Connected := True;
      LConn.Connected := False;
    except
      // did not exist
    end;
  finally
    LConn.Free;
  end;
  // Local database file left behind (e.g. the drop failed): remove it.
  if (Host = '') and FileExists(DatabaseName) then
    DeleteFile(DatabaseName);
end;

procedure CreateDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TFDConnection;
begin
  DropDatabase(AConfig);
  if IsSQLite then
  begin
    // The first connection creates the file.
    if FileExists(DatabaseName) then
      raise Exception.CreateFmt('Could not delete the test database left by a previous run: %s (still in use?)', [DatabaseName]);
    Exit;
  end;
  if IsPostgres then
  begin
    ExecOnMaintenanceDb('CREATE DATABASE ' + DatabaseName);
    Exit;
  end;
  LConn := NewFDConnection(AConfig.ConnectionParams, 'CreateDatabase=Yes');
  try
    LConn.Connected := True;
    LConn.Connected := False;
  finally
    LConn.Free;
  end;
end;

function NewFactory(const AConfig: IDatabaseConfig; AOnStatement: TStatementEventProc = nil): IDBFactory;
begin
  Result := TFDFactory.Create(AConfig, nil, nil, AOnStatement);
end;

{$IFEND}

function BuildConfig: IDatabaseConfig;
begin
  Result := TDatabaseConfig.Create;
  SetConnectionParams(Result.ConnectionParams, DatabaseName);
  case Engine of
    engPostgres: Result.SQLDialect := 'PostgreSQL';
    engSQLite: Result.SQLDialect := 'SQLite';
    engMySQL: Result.SQLDialect := 'MySQL';
    engMariaDB: Result.SQLDialect := 'MariaDB';
  else
    Result.SQLDialect := 'Firebird';
  end;
  Result.SQLDirectory := SQL_DIRECTORY;
  Result.SqlSource := BuildSqlSource;
  // 0 on purpose: the factory is created before the database is recreated,
  // and a ramp-up connection to a database left over by an interrupted run
  // would make the DROP fail ("object in use").
  Result.PoolIniConnections := 0;
  Result.PoolMaxConnections := 5;
  Result.PoolWaitMaxAttemps := 200;
  Result.PoolWaitMilliseconds := 10;
end;

function SessionIdSql: string;
begin
  case Engine of
    engPostgres: Result := 'SELECT pg_backend_pid() AS SID';
    engSQLite: Result := '';
    engMySQL, engMariaDB: Result := 'SELECT CONNECTION_ID() AS SID';
  else
    Result := 'SELECT CURRENT_CONNECTION AS SID FROM RDB$DATABASE';
  end;
end;

function IntegrationPoolMax: Integer;
begin
  Result := BuildConfig.PoolMaxConnections;
end;

function UnreachableFactory: IDBFactory;
const
  // .invalid never resolves (RFC 2606): the connect fails at once, on every
  // driver, with no server to stop.
  UNREACHABLE_HOST = 'pascaldb-unreachable.invalid';
var
  LConfig: IDatabaseConfig;
begin
  LConfig := BuildConfig;
  if IsSQLite then
    SetConnectionParams(LConfig.ConnectionParams,
      ExtractFilePath(ParamStr(0)) + 'no-such-folder' + PathDelim + 'unreachable.sqlite')
  else
  begin
    {$IF DEFINED(PASCALDB_IT_ZEOS) or DEFINED(FPC)}
    LConfig.ConnectionParams.Values['HostName'] := UNREACHABLE_HOST;
    {$ELSE}
    LConfig.ConnectionParams.Values['Server'] := UNREACHABLE_HOST;
    if not IsPostgres then
      LConfig.ConnectionParams.Values['Protocol'] := 'TCPIP';
    {$IFEND}
  end;
  Result := NewFactory(LConfig);
end;

function LockTimeoutFactory(AMs: Integer): IDBFactory;
var
  LConfig: IDatabaseConfig;
begin
  LConfig := BuildConfig;
  LConfig.LockTimeoutMs := AMs;
  Result := NewFactory(LConfig);
end;

function StatementEventFactory(AOnStatement: TStatementEventProc): IDBFactory;
begin
  Result := NewFactory(BuildConfig, AOnStatement);
end;

var
  GConfig: IDatabaseConfig = nil;

function IntegrationFactory: IDBFactory;
const
  MIGRATIONS: array[0..1] of TMigrationItem = (
    (Version: 1; ScriptName: 'MIG.0001'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: True),
    (Version: 2; ScriptName: 'MIG.0002'; ParamReplaceProc: nil; Terminator: '^'; IsDDL: True));
var
  LEngine: TDBMigrationEngine;
begin
  if not Assigned(GFactory) then
  begin
    GConfig := BuildConfig;
    // The factory loads the client library (ClientLibrary) — create it before
    // touching the database directly. Its pool can't connect yet (the
    // database doesn't exist), which it tolerates: the ramp-up failure only
    // becomes a pool event.
    GFactory := NewFactory(GConfig);
    CreateDatabase(GConfig);
    LEngine := TDBMigrationEngine.Create(GFactory, nil);
    try
      LEngine.Execute(MIGRATIONS);
    finally
      LEngine.Free;
    end;
  end;
  Result := GFactory;
end;

initialization

finalization
  if Assigned(GFactory) then
  begin
    GFactory := nil;
    // Never raise from here: when the run failed early (e.g. the client
    // library didn't load), the drop fails the same way, and an exception in
    // finalization aborts the remaining finalizations (runtime error 217 and
    // leaks reported by heaptrc).
    try
      DropDatabase(GConfig);
    except
    end;
  end;
  GConfig := nil;

end.
