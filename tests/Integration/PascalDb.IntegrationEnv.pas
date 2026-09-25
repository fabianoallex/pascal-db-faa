unit PascalDb.IntegrationEnv;

{ The integration suite's environment: a fresh database per run (Firebird or
  PostgreSQL), migrated with the library's own migration engine, and the
  IDBFactory the contract tests run against. This is the only
  adapter-specific part of the integration suite: on FPC the factory is the
  SQLdb adapter's; on Delphi it is the FireDAC adapter's; with
  PASCALDB_IT_ZEOS defined (the *Zeos* runners), it is the Zeos adapter's on
  both. The tests themselves (PascalDb.ContractTests) only see IDBFactory, so
  the same test bodies validate every adapter on every database.

  Settings (environment variables, all optional):
    PASCALDB_IT_ENGINE    firebird (default) or postgresql
    PASCALDB_IT_HOST      server host. Firebird: '' = local server (path
                          only). PostgreSQL: default localhost
    PASCALDB_IT_PORT      server port (default: the driver's; PostgreSQL 5432)
    PASCALDB_IT_DATABASE  Firebird: database path on the server (default:
                          pascaldb_it.fdb next to the executable).
                          PostgreSQL: database name (default pascaldb_it)
    PASCALDB_IT_USER      default SYSDBA / postgres
    PASCALDB_IT_PASSWORD  default masterkey / postgres
    PASCALDB_IT_CLIENT    full path of the client library (fbclient/libpq).
                          When empty on Windows: Firebird, the client of a
                          default Firebird 2.5 64-bit install that matches
                          the executable's bitness (bin or WOW64);
                          PostgreSQL (64-bit only), bin\libpq.dll of the
                          newest install under C:\Program Files\PostgreSQL.
                          Otherwise the driver's default search.

  The database is dropped (if it exists) and created on first use, and
  dropped again at the end of the run. PostgreSQL databases are created and
  dropped with SQL through a maintenance database, outside any transaction.
  Zeos has no call to drop a Firebird database, so the Zeos + Firebird
  combination deletes the database file instead: it supports only a local
  server (PASCALDB_IT_HOST empty). }

interface

uses
  Classes,
  SysUtils,
  PascalDb.Interfaces;

/// The factory the contract tests use; created (with a fresh, migrated
/// database) on first call.
function IntegrationFactory: IDBFactory;

/// Number of migrations IntegrationFactory applies.
function IntegrationSchemaVersion: Integer;

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
  // The database PostgreSQL connections use to create/drop the test database.
  PG_MAINTENANCE_DB = 'postgres';

var
  GFactory: IDBFactory = nil;

function Env(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function IsPostgres: Boolean;
var
  LEngine: string;
begin
  LEngine := LowerCase(Env('PASCALDB_IT_ENGINE', 'firebird'));
  if (LEngine <> 'firebird') and (LEngine <> 'postgresql') then
    raise Exception.CreateFmt('PASCALDB_IT_ENGINE must be firebird or postgresql, not "%s"', [LEngine]);
  Result := LEngine = 'postgresql';
end;

function Host: string;
begin
  if IsPostgres then
    Result := Env('PASCALDB_IT_HOST', 'localhost')
  else
    Result := Env('PASCALDB_IT_HOST', '');
end;

function Port: string;
begin
  Result := Env('PASCALDB_IT_PORT', '');
end;

function DatabaseName: string;
begin
  if IsPostgres then
    Result := Env('PASCALDB_IT_DATABASE', 'pascaldb_it')
  else
    Result := Env('PASCALDB_IT_DATABASE', ExtractFilePath(ParamStr(0)) + 'pascaldb_it.fdb');
end;

function UserName: string;
begin
  if IsPostgres then
    Result := Env('PASCALDB_IT_USER', 'postgres')
  else
    Result := Env('PASCALDB_IT_USER', 'SYSDBA');
end;

function Password: string;
begin
  if IsPostgres then
    Result := Env('PASCALDB_IT_PASSWORD', 'postgres')
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
    else if FileExists(DEFAULT_FB25_CLIENT) then
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
  // official images) applies to every column.
  if IsPostgres then
    LUtf8 := ''
  else
    LUtf8 := ' CHARACTER SET UTF8';
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
      '  [NOTE {], :NOTE [} NOTE])' +
      ' RETURNING ID, NOTE')
    .Add(SQL_DIRECTORY, 'ITEMS.BY_ID', 'SELECT * FROM ITEMS WHERE ID = :ID');
end;

{ Adapter-specific part: connection settings, database creation and removal,
  and the factory. }

{$IF DEFINED(PASCALDB_IT_ZEOS)}

procedure SetConnectionParams(AParams: TStrings; const ADatabase: string);
begin
  // Zeos connection settings (see PascalDb.Adapter.Zeos)
  if IsPostgres then
    AParams.Values['Protocol'] := 'postgresql'
  else
  begin
    if Host <> '' then
      raise Exception.Create('The Zeos runners support only a local Firebird server (PASCALDB_IT_HOST empty)');
    AParams.Values['Protocol'] := 'firebird';
  end;
  AParams.Values['HostName'] := Host;
  AParams.Values['Port'] := Port;
  AParams.Values['Database'] := ADatabase;
  AParams.Values['User'] := UserName;
  AParams.Values['Password'] := Password;
  AParams.Values['ClientCodepage'] := 'UTF8';
  AParams.Values['LibraryLocation'] := ClientLibrary;
end;

// PostgreSQL: CREATE/DROP DATABASE through the maintenance database, with
// the connection in auto-commit (TZConnection's default).
procedure ExecOnMaintenanceDb(const ASql: string);
var
  LSettings: TStringList;
  LConn: TZConnection;
begin
  LSettings := TStringList.Create;
  try
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
  if IsPostgres then
  begin
    try
      ExecOnMaintenanceDb('DROP DATABASE IF EXISTS ' + DatabaseName);
    except
      // server unreachable: nothing to drop
    end;
  end
  // Zeos can create a Firebird database (CreateNewDatabase) but not drop
  // one; the database is local (see SetConnectionParams): delete the file.
  else if FileExists(DatabaseName) then
    DeleteFile(DatabaseName);
end;

procedure CreateDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TZConnection;
begin
  DropDatabase(AConfig);
  if IsPostgres then
    ExecOnMaintenanceDb('CREATE DATABASE ' + DatabaseName)
  else
  begin
    if FileExists(DatabaseName) then
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

function NewFactory(const AConfig: IDatabaseConfig): IDBFactory;
begin
  Result := TZeosFactory.Create(AConfig);
end;

{$ELSEIF DEFINED(FPC)}

procedure SetConnectionParams(AParams: TStrings; const ADatabase: string);
begin
  // SQLdb connection settings (see PascalDb.Adapter.SQLdb)
  if IsPostgres then
    AParams.Values['ConnectorType'] := 'PostgreSQL'
  else
    AParams.Values['ConnectorType'] := 'Firebird';
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
  LConn := NewDirectConnection;
  try
    LConn.CreateDB;
  finally
    LConn.Free;
  end;
end;

function NewFactory(const AConfig: IDatabaseConfig): IDBFactory;
begin
  Result := TSQLdbFactory.Create(AConfig);
end;

{$ELSE}

procedure SetConnectionParams(AParams: TStrings; const ADatabase: string);
begin
  // FireDAC connection definition (see PascalDb.Adapter.FireDAC)
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

function NewFactory(const AConfig: IDatabaseConfig): IDBFactory;
begin
  Result := TFDFactory.Create(AConfig);
end;

{$IFEND}

function BuildConfig: IDatabaseConfig;
begin
  Result := TDatabaseConfig.Create;
  SetConnectionParams(Result.ConnectionParams, DatabaseName);
  if IsPostgres then
    Result.SQLDialect := 'PostgreSQL'
  else
    Result.SQLDialect := 'Firebird';
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
