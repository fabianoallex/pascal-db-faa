unit PascalDb.IntegrationEnv;

{ The integration suite's environment: a fresh Firebird database per run,
  migrated with the library's own migration engine, and the IDBFactory the
  contract tests run against. This is the only compiler-specific part of the
  integration suite: on FPC the factory is the SQLdb adapter's; on Delphi it
  is the FireDAC adapter's; with PASCALDB_IT_ZEOS defined (the *Zeos*
  runners), it is the Zeos adapter's on both. The tests themselves
  (PascalDb.ContractTests) only see IDBFactory, so the same test bodies
  validate every adapter.

  Settings (environment variables, all optional):
    PASCALDB_IT_HOST      Firebird server host ('' = local server, path only)
    PASCALDB_IT_DATABASE  database path on the server
                          (default: pascaldb_it.fdb next to the executable)
    PASCALDB_IT_USER      default SYSDBA
    PASCALDB_IT_PASSWORD  default masterkey
    PASCALDB_IT_CLIENT    full path of fbclient; when empty, the client of a
                          default Firebird 2.5 64-bit install that matches the
                          executable's bitness (bin or WOW64) is used if it
                          exists, else the driver's default search.

  The database is dropped (if it exists) and created on first use, and
  dropped again at the end of the run. Zeos has no drop-database call, so
  the Zeos branch deletes the database file instead: it supports only a
  local server (PASCALDB_IT_HOST empty). }

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
  , ibconnection
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

var
  GFactory: IDBFactory = nil;

function Env(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function DatabasePath: string;
begin
  Result := Env('PASCALDB_IT_DATABASE', ExtractFilePath(ParamStr(0)) + 'pascaldb_it.fdb');
end;

function ClientLibrary: string;
begin
  Result := Env('PASCALDB_IT_CLIENT', '');
  {$IFDEF MSWINDOWS}
  if (Result = '') and FileExists(DEFAULT_FB25_CLIENT) then
    Result := DEFAULT_FB25_CLIENT;
  {$ENDIF}
end;

function IntegrationSchemaVersion: Integer;
begin
  Result := 2;
end;

function BuildSqlSource: ISqlSource;
begin
  Result := TMemorySqlSource.Create
    .Add(SQL_DIRECTORY, 'MIG.0001',
      'CREATE TABLE SCHEMA_MIGRATIONS (' +
      '  VERSION    INTEGER   NOT NULL,' +
      '  APPLIED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,' +
      '  CONSTRAINT PK_SCHEMA_MIGRATIONS PRIMARY KEY (VERSION))')
    .Add(SQL_DIRECTORY, 'MIG.0002',
      'CREATE TABLE ITEMS (' +
      '  ID         INTEGER NOT NULL,' +
      '  NAME       VARCHAR(100) CHARACTER SET UTF8,' +
      '  QTY        INTEGER,' +
      '  BIG        BIGINT,' +
      '  PRICE      NUMERIC(15,2),' +
      '  RATIO      DOUBLE PRECISION,' +
      '  CREATED_AT TIMESTAMP,' +
      '  ACTIVE     SMALLINT,' +
      '  NOTE       VARCHAR(100) CHARACTER SET UTF8 DEFAULT ''default note'',' +
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

function BuildConfig: IDatabaseConfig;
var
  LDatabase: string;
begin
  Result := TDatabaseConfig.Create;
  LDatabase := DatabasePath;
  {$IF DEFINED(PASCALDB_IT_ZEOS)}
  // Zeos connection settings (see PascalDb.Adapter.Zeos)
  if Env('PASCALDB_IT_HOST', '') <> '' then
    raise Exception.Create('The Zeos integration runners support only a local Firebird server (PASCALDB_IT_HOST empty)');
  Result.ConnectionParams.Values['Protocol'] := 'firebird';
  Result.ConnectionParams.Values['Database'] := LDatabase;
  Result.ConnectionParams.Values['User'] := Env('PASCALDB_IT_USER', 'SYSDBA');
  Result.ConnectionParams.Values['Password'] := Env('PASCALDB_IT_PASSWORD', 'masterkey');
  Result.ConnectionParams.Values['ClientCodepage'] := 'UTF8';
  Result.ConnectionParams.Values['LibraryLocation'] := ClientLibrary;
  {$ELSEIF DEFINED(FPC)}
  // SQLdb connection settings (see PascalDb.Adapter.SQLdb)
  Result.ConnectionParams.Values['ConnectorType'] := 'Firebird';
  Result.ConnectionParams.Values['HostName'] := Env('PASCALDB_IT_HOST', '');
  Result.ConnectionParams.Values['DatabaseName'] := LDatabase;
  Result.ConnectionParams.Values['UserName'] := Env('PASCALDB_IT_USER', 'SYSDBA');
  Result.ConnectionParams.Values['Password'] := Env('PASCALDB_IT_PASSWORD', 'masterkey');
  Result.ConnectionParams.Values['CharSet'] := 'UTF8';
  Result.ConnectionParams.Values['ClientLibrary'] := ClientLibrary;
  {$ELSE}
  // FireDAC connection definition (see PascalDb.Adapter.FireDAC)
  Result.ConnectionParams.Values['DriverID'] := 'FB';
  if Env('PASCALDB_IT_HOST', '') <> '' then
  begin
    Result.ConnectionParams.Values['Server'] := Env('PASCALDB_IT_HOST', '');
    Result.ConnectionParams.Values['Protocol'] := 'TCPIP';
  end;
  Result.ConnectionParams.Values['Database'] := LDatabase;
  Result.ConnectionParams.Values['User_Name'] := Env('PASCALDB_IT_USER', 'SYSDBA');
  Result.ConnectionParams.Values['Password'] := Env('PASCALDB_IT_PASSWORD', 'masterkey');
  Result.ConnectionParams.Values['CharacterSet'] := 'UTF8';
  Result.ConnectionParams.Values['VendorLib'] := ClientLibrary;
  {$IFEND}
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

{$IF DEFINED(PASCALDB_IT_ZEOS)}
procedure DropDatabase(const AConfig: IDatabaseConfig);
begin
  // Zeos can create a database (CreateNewDatabase) but not drop one; the
  // database is local (see BuildConfig), so delete the file.
  if FileExists(DatabasePath) then
    DeleteFile(DatabasePath);
end;

procedure CreateDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TZConnection;
begin
  DropDatabase(AConfig);
  if FileExists(DatabasePath) then
    raise Exception.CreateFmt('Could not delete the test database left by a previous run: %s (still in use?)', [DatabasePath]);
  LConn := PdbZeosNewConnection(AConfig.ConnectionParams);
  try
    LConn.Properties.Values['CreateNewDatabase'] := 'true';
    LConn.Connect;
    LConn.Disconnect;
  finally
    LConn.Free;
  end;
end;

function NewFactory(const AConfig: IDatabaseConfig): IDBFactory;
begin
  Result := TZeosFactory.Create(AConfig);
end;
{$ELSEIF DEFINED(FPC)}
function NewIBConnection(const AConfig: IDatabaseConfig): TIBConnection;
begin
  // Before any direct SQLdb connection: the first client library loaded wins.
  PdbSQLdbUseClientLibrary('Firebird', AConfig.ConnectionParams.Values['ClientLibrary']);
  Result := TIBConnection.Create(nil);
  Result.HostName := AConfig.ConnectionParams.Values['HostName'];
  Result.DatabaseName := AConfig.ConnectionParams.Values['DatabaseName'];
  Result.UserName := AConfig.ConnectionParams.Values['UserName'];
  Result.Password := AConfig.ConnectionParams.Values['Password'];
  Result.CharSet := 'UTF8';
  Result.LoginPrompt := False;
end;

procedure DropDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TIBConnection;
begin
  LConn := NewIBConnection(AConfig);
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
  LConn: TIBConnection;
begin
  DropDatabase(AConfig);
  LConn := NewIBConnection(AConfig);
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
// FireDAC's Firebird driver creates the database on connect with
// CreateDatabase=Yes and drops it on disconnect with DropDatabase=Yes.
function NewFDConnection(const AConfig: IDatabaseConfig; const AExtra: string): TFDConnection;
var
  I: Integer;
begin
  PdbFireDACUseVendorLib('FB', AConfig.ConnectionParams.Values['VendorLib']);
  Result := TFDConnection.Create(nil);
  Result.LoginPrompt := False;
  Result.ResourceOptions.SilentMode := True;
  for I := 0 to AConfig.ConnectionParams.Count - 1 do
    if not SameText(AConfig.ConnectionParams.Names[I], 'VendorLib') then
      Result.Params.Add(AConfig.ConnectionParams[I]);
  Result.Params.Add(AExtra);
end;

procedure DropDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TFDConnection;
begin
  LConn := NewFDConnection(AConfig, 'DropDatabase=Yes');
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
  if (Env('PASCALDB_IT_HOST', '') = '') and FileExists(DatabasePath) then
    DeleteFile(DatabasePath);
end;

procedure CreateDatabase(const AConfig: IDatabaseConfig);
var
  LConn: TFDConnection;
begin
  DropDatabase(AConfig);
  LConn := NewFDConnection(AConfig, 'CreateDatabase=Yes');
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
    DropDatabase(GConfig);
  end;
  GConfig := nil;

end.
