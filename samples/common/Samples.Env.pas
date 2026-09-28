unit Samples.Env;

{ Builds the IDBFactory the database samples use, from environment variables.

  This is the only place in the samples that knows which driver is in use:
  SQLdb on Free Pascal and FireDAC on Delphi, or Zeos on either compiler when
  PASCALDB_SAMPLES_ZEOS is defined. Everything after the factory is created
  (queries, transactions, the repository) is driver-agnostic.

  Settings (environment variables, all optional):
    PASCALDB_SAMPLE_ENGINE    postgresql (default), firebird or sqlite
    PASCALDB_SAMPLE_HOST      default localhost (unused by SQLite)
    PASCALDB_SAMPLE_PORT      default: the driver's (5432 / 3050)
    PASCALDB_SAMPLE_DATABASE  PostgreSQL: database name (default postgres).
                              Firebird: path of an existing database on the
                              server (required). SQLite: the database file,
                              created on first connect (default
                              pascaldb_samples.sqlite in the current folder)
    PASCALDB_SAMPLE_USER      default postgres / SYSDBA (unused by SQLite)
    PASCALDB_SAMPLE_PASSWORD  default postgres / masterkey (unused by SQLite)
    PASCALDB_SAMPLE_CLIENT    full path of the client library (libpq /
                              fbclient / sqlite3) when it isn't found on the
                              default search path, e.g.
                              C:\Program Files\PostgreSQL\17\bin\libpq.dll.
                              FireDAC links SQLite into the program: no
                              client library

  Each adapter has its own names for the connection settings (see the
  adapter units); SetConnectionParams below is the whole difference.

  The SQL directory follows the engine ('PG', 'FB' or 'SQLITE'), so a
  program can keep one version of a script per database under the same key. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Pool;

type
  TSampleEngine = (sePostgreSQL, seFirebird, seSQLite);

const
  SQL_DIR_POSTGRESQL = 'PG';
  SQL_DIR_FIREBIRD = 'FB';
  SQL_DIR_SQLITE = 'SQLITE';

function SampleEngine: TSampleEngine;
/// Human-readable description of the target, e.g. 'PostgreSQL on localhost (SQLdb adapter)'.
function SampleTarget: string;
/// The connection settings in effect, one per line, for error messages
/// (the password is left out).
function SampleConnectionSummary: string;
/// Acquires a pooled connection and gives it back; when that fails, prints
/// the settings in use and the driver's error, and re-raises
/// EDatabaseConnectException.
procedure CheckSampleConnection(const AFactory: IDBFactory);
/// The configuration for the configured database, SQL read from
/// ASqlSource, with the samples' default pool settings; change what you need
/// before passing it to NewSampleFactory.
function NewSampleConfig(const ASqlSource: ISqlSource): IDatabaseConfig;
/// A factory for the configured database; SQL is read from ASqlSource.
function NewSampleFactory(const ASqlSource: ISqlSource): IDBFactory; overload;
/// A factory for AConfig; AOnPoolEvent receives the pool's events (see
/// TPoolEventKind), from whichever thread caused them.
function NewSampleFactory(const AConfig: IDatabaseConfig;
  AOnPoolEvent: TPoolEventProc = nil): IDBFactory; overload;

implementation

uses
  Classes,
  PascalDb.Adapter.Base
  {$IF DEFINED(PASCALDB_SAMPLES_ZEOS)}
  , PascalDb.Adapter.Zeos
  {$ELSEIF DEFINED(FPC)}
  , PascalDb.Adapter.SQLdb
  {$ELSE}
  , PascalDb.Adapter.FireDAC
  {$IFEND};

function Env(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function SampleEngine: TSampleEngine;
var
  LEngine: string;
begin
  LEngine := LowerCase(Env('PASCALDB_SAMPLE_ENGINE', 'postgresql'));
  if LEngine = 'postgresql' then
    Result := sePostgreSQL
  else if LEngine = 'firebird' then
    Result := seFirebird
  else if LEngine = 'sqlite' then
    Result := seSQLite
  else
    raise Exception.CreateFmt('PASCALDB_SAMPLE_ENGINE must be postgresql, firebird or sqlite, not "%s"', [LEngine]);
end;

function Host: string;
begin
  Result := Env('PASCALDB_SAMPLE_HOST', 'localhost');
end;

function Port: string;
begin
  Result := Env('PASCALDB_SAMPLE_PORT', '');
end;

function DatabaseName: string;
begin
  case SampleEngine of
    sePostgreSQL:
      Result := Env('PASCALDB_SAMPLE_DATABASE', 'postgres');
    seSQLite:
      Result := ExpandFileName(Env('PASCALDB_SAMPLE_DATABASE', 'pascaldb_samples.sqlite'));
  else
    Result := Env('PASCALDB_SAMPLE_DATABASE', '');
    if Result = '' then
      raise Exception.Create('Firebird: set PASCALDB_SAMPLE_DATABASE to the path of an existing database on the server');
  end;
end;

function UserName: string;
begin
  if SampleEngine = seFirebird then
    Result := Env('PASCALDB_SAMPLE_USER', 'SYSDBA')
  else
    Result := Env('PASCALDB_SAMPLE_USER', 'postgres');
end;

function Password: string;
begin
  if SampleEngine = seFirebird then
    Result := Env('PASCALDB_SAMPLE_PASSWORD', 'masterkey')
  else
    Result := Env('PASCALDB_SAMPLE_PASSWORD', 'postgres');
end;

function ClientLibrary: string;
begin
  Result := Env('PASCALDB_SAMPLE_CLIENT', '');
end;

{$IF DEFINED(PASCALDB_SAMPLES_ZEOS)}

const
  ADAPTER_NAME = 'Zeos';

procedure SetConnectionParams(AParams: TStrings);
begin
  case SampleEngine of
    sePostgreSQL: AParams.Values['Protocol'] := 'postgresql';
    seFirebird: AParams.Values['Protocol'] := 'firebird';
    seSQLite: AParams.Values['Protocol'] := 'sqlite';
  end;
  if SampleEngine <> seSQLite then
  begin
    AParams.Values['HostName'] := Host;
    AParams.Values['Port'] := Port;
    AParams.Values['User'] := UserName;
    AParams.Values['Password'] := Password;
  end;
  AParams.Values['Database'] := DatabaseName;
  AParams.Values['ClientCodepage'] := 'UTF8';
  AParams.Values['LibraryLocation'] := ClientLibrary;
end;

function NewFactory(const AConfig: IDatabaseConfig; AOnPoolEvent: TPoolEventProc): IDBFactory;
begin
  Result := TZeosFactory.Create(AConfig, nil, AOnPoolEvent);
end;

{$ELSEIF DEFINED(FPC)}

const
  ADAPTER_NAME = 'SQLdb';

procedure SetConnectionParams(AParams: TStrings);
begin
  case SampleEngine of
    sePostgreSQL: AParams.Values['ConnectorType'] := 'PostgreSQL';
    seFirebird: AParams.Values['ConnectorType'] := 'Firebird';
    seSQLite: AParams.Values['ConnectorType'] := 'SQLite3';
  end;
  if SampleEngine <> seSQLite then
  begin
    AParams.Values['HostName'] := Host;
    AParams.Values['Port'] := Port;
    AParams.Values['UserName'] := UserName;
    AParams.Values['Password'] := Password;
    AParams.Values['CharSet'] := 'UTF8';
  end;
  AParams.Values['DatabaseName'] := DatabaseName;
  AParams.Values['ClientLibrary'] := ClientLibrary;
end;

function NewFactory(const AConfig: IDatabaseConfig; AOnPoolEvent: TPoolEventProc): IDBFactory;
begin
  Result := TSQLdbFactory.Create(AConfig, nil, AOnPoolEvent);
end;

{$ELSE}

const
  ADAPTER_NAME = 'FireDAC';

procedure SetConnectionParams(AParams: TStrings);
begin
  if SampleEngine = seSQLite then
  begin
    // No server, credentials or client library: the engine is in the program.
    AParams.Values['DriverID'] := 'SQLite';
    AParams.Values['Database'] := DatabaseName;
    Exit;
  end;
  if SampleEngine = sePostgreSQL then
    AParams.Values['DriverID'] := 'PG'
  else
  begin
    AParams.Values['DriverID'] := 'FB';
    AParams.Values['Protocol'] := 'TCPIP';
  end;
  AParams.Values['Server'] := Host;
  if Port <> '' then
    AParams.Values['Port'] := Port;
  AParams.Values['Database'] := DatabaseName;
  AParams.Values['User_Name'] := UserName;
  AParams.Values['Password'] := Password;
  AParams.Values['CharacterSet'] := 'UTF8';
  AParams.Values['VendorLib'] := ClientLibrary;
end;

function NewFactory(const AConfig: IDatabaseConfig; AOnPoolEvent: TPoolEventProc): IDBFactory;
begin
  Result := TFDFactory.Create(AConfig, nil, AOnPoolEvent);
end;

{$IFEND}

function SampleTarget: string;
begin
  case SampleEngine of
    sePostgreSQL: Result := Format('PostgreSQL on %s', [Host]);
    seFirebird: Result := Format('Firebird on %s', [Host]);
  else
    Result := Format('SQLite file %s', [DatabaseName]);
  end;
  Result := Format('%s (%s adapter)', [Result, ADAPTER_NAME]);
end;

function SampleConnectionSummary: string;
var
  LPort, LClient: string;
begin
  LClient := ClientLibrary;
  if LClient = '' then
    LClient := '(default search path)';
  if SampleEngine = seSQLite then
  begin
    Result :=
      '  database: ' + DatabaseName + sLineBreak +
      '  client:   ' + LClient;
    Exit;
  end;
  LPort := Port;
  if LPort = '' then
    if SampleEngine = sePostgreSQL then
      LPort := '5432 (default)'
    else
      LPort := '3050 (default)';
  Result :=
    '  host:     ' + Host + sLineBreak +
    '  port:     ' + LPort + sLineBreak +
    '  database: ' + DatabaseName + sLineBreak +
    '  user:     ' + UserName + sLineBreak +
    '  client:   ' + LClient;
end;

// A failed connect raises EDatabaseConnectException, whose Message is generic;
// the driver's own text, which is what says what went wrong, is in
// OriginalMessage, and neither says where the settings come from. Connecting
// alone, before any SQL, is the place to say what to check.
procedure CheckSampleConnection(const AFactory: IDBFactory);
var
  LConn: IDBConnection;
begin
  try
    LConn := AFactory.GetPool.AcquireConnection;
    LConn := nil; // back to the pool
  except
    on E: EDatabaseConnectException do
    begin
      Writeln('Could not connect. Settings in use (PASCALDB_SAMPLE_*, see samples/README.md):');
      Writeln(SampleConnectionSummary);
      Writeln('Driver: ', E.OriginalClassName, ': ', E.OriginalMessage);
      Writeln('Is the server running? Does the client library match this program''s bitness?');
      Writeln;
      raise; // the caller reports it too
    end;
  end;
end;

function NewSampleConfig(const ASqlSource: ISqlSource): IDatabaseConfig;
var
  LConfig: IDatabaseConfig; // an interface variable, never a class one (see CLAUDE.md)
begin
  LConfig := TDatabaseConfig.Create;
  SetConnectionParams(LConfig.ConnectionParams);
  case SampleEngine of
    sePostgreSQL:
      begin
        LConfig.SQLDialect := 'PostgreSQL';
        LConfig.SQLDirectory := SQL_DIR_POSTGRESQL;
      end;
    seFirebird:
      begin
        LConfig.SQLDialect := 'Firebird';
        LConfig.SQLDirectory := SQL_DIR_FIREBIRD;
      end;
    seSQLite:
      begin
        LConfig.SQLDialect := 'SQLite';
        LConfig.SQLDirectory := SQL_DIR_SQLITE;
      end;
  end;
  LConfig.SqlSource := ASqlSource;
  // One connection opened up front, up to 5 under load; a caller waits at
  // most 50 x 100 ms for a free one before EPoolTimeoutException.
  LConfig.PoolIniConnections := 1;
  LConfig.PoolMaxConnections := 5;
  LConfig.PoolWaitMaxAttemps := 50;
  LConfig.PoolWaitMilliseconds := 100;
  Result := LConfig;
end;

function NewSampleFactory(const ASqlSource: ISqlSource): IDBFactory;
begin
  Result := NewFactory(NewSampleConfig(ASqlSource), nil);
end;

function NewSampleFactory(const AConfig: IDatabaseConfig; AOnPoolEvent: TPoolEventProc): IDBFactory;
begin
  Result := NewFactory(AConfig, AOnPoolEvent);
end;

end.
