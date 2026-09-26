unit Samples.Env;

{ Builds the IDBFactory the database samples use, from environment variables.

  This is the only place in the samples that knows which driver is in use:
  SQLdb on Free Pascal and FireDAC on Delphi, or Zeos on either compiler when
  PASCALDB_SAMPLES_ZEOS is defined. Everything after the factory is created
  (queries, transactions, the repository) is driver-agnostic.

  Settings (environment variables, all optional):
    PASCALDB_SAMPLE_ENGINE    postgresql (default) or firebird
    PASCALDB_SAMPLE_HOST      default localhost
    PASCALDB_SAMPLE_PORT      default: the driver's (5432 / 3050)
    PASCALDB_SAMPLE_DATABASE  PostgreSQL: database name (default postgres).
                              Firebird: path of an existing database on the
                              server (required)
    PASCALDB_SAMPLE_USER      default postgres / SYSDBA
    PASCALDB_SAMPLE_PASSWORD  default postgres / masterkey
    PASCALDB_SAMPLE_CLIENT    full path of the client library (libpq /
                              fbclient) when it isn't found on the default
                              search path, e.g.
                              C:\Program Files\PostgreSQL\17\bin\libpq.dll

  Each adapter has its own names for the connection settings (see the
  adapter units); SetConnectionParams below is the whole difference.

  The SQL directory follows the engine ('PG' or 'FB'), so a program can keep
  one version of a script per database under the same key. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Pool;

const
  SQL_DIR_POSTGRESQL = 'PG';
  SQL_DIR_FIREBIRD = 'FB';

function SampleIsPostgres: Boolean;
/// Human-readable description of the target, e.g. 'PostgreSQL on localhost (SQLdb)'.
function SampleTarget: string;
/// The connection settings in effect, one per line, for error messages
/// (the password is left out).
function SampleConnectionSummary: string;
/// Acquires (and returns) a pooled connection; when that fails, prints the
/// settings in use and re-raises the driver's exception.
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

function SampleIsPostgres: Boolean;
var
  LEngine: string;
begin
  LEngine := LowerCase(Env('PASCALDB_SAMPLE_ENGINE', 'postgresql'));
  if (LEngine <> 'postgresql') and (LEngine <> 'firebird') then
    raise Exception.CreateFmt('PASCALDB_SAMPLE_ENGINE must be postgresql or firebird, not "%s"', [LEngine]);
  Result := LEngine = 'postgresql';
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
  if SampleIsPostgres then
    Result := Env('PASCALDB_SAMPLE_DATABASE', 'postgres')
  else
  begin
    Result := Env('PASCALDB_SAMPLE_DATABASE', '');
    if Result = '' then
      raise Exception.Create('Firebird: set PASCALDB_SAMPLE_DATABASE to the path of an existing database on the server');
  end;
end;

function UserName: string;
begin
  if SampleIsPostgres then
    Result := Env('PASCALDB_SAMPLE_USER', 'postgres')
  else
    Result := Env('PASCALDB_SAMPLE_USER', 'SYSDBA');
end;

function Password: string;
begin
  if SampleIsPostgres then
    Result := Env('PASCALDB_SAMPLE_PASSWORD', 'postgres')
  else
    Result := Env('PASCALDB_SAMPLE_PASSWORD', 'masterkey');
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
  if SampleIsPostgres then
    AParams.Values['Protocol'] := 'postgresql'
  else
    AParams.Values['Protocol'] := 'firebird';
  AParams.Values['HostName'] := Host;
  AParams.Values['Port'] := Port;
  AParams.Values['Database'] := DatabaseName;
  AParams.Values['User'] := UserName;
  AParams.Values['Password'] := Password;
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
  if SampleIsPostgres then
    AParams.Values['ConnectorType'] := 'PostgreSQL'
  else
    AParams.Values['ConnectorType'] := 'Firebird';
  AParams.Values['HostName'] := Host;
  AParams.Values['Port'] := Port;
  AParams.Values['DatabaseName'] := DatabaseName;
  AParams.Values['UserName'] := UserName;
  AParams.Values['Password'] := Password;
  AParams.Values['CharSet'] := 'UTF8';
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
  if SampleIsPostgres then
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
var
  LEngine: string;
begin
  if SampleIsPostgres then
    LEngine := 'PostgreSQL'
  else
    LEngine := 'Firebird';
  Result := Format('%s on %s (%s adapter)', [LEngine, Host, ADAPTER_NAME]);
end;

function SampleConnectionSummary: string;
var
  LPort, LClient: string;
begin
  LPort := Port;
  if LPort = '' then
    if SampleIsPostgres then
      LPort := '5432 (default)'
    else
      LPort := '3050 (default)';
  LClient := ClientLibrary;
  if LClient = '' then
    LClient := '(default search path)';
  Result :=
    '  host:     ' + Host + sLineBreak +
    '  port:     ' + LPort + sLineBreak +
    '  database: ' + DatabaseName + sLineBreak +
    '  user:     ' + UserName + sLineBreak +
    '  client:   ' + LClient;
end;

// A failed connect raises the driver's own exception (not
// EDatabaseUnavailableException), different for each driver and silent about
// where the settings come from. Connecting alone, before any SQL, is the one
// place where an exception can only mean "could not connect", so this is
// where to say what to check.
procedure CheckSampleConnection(const AFactory: IDBFactory);
var
  LConn: IDBConnection;
begin
  try
    LConn := AFactory.GetPool.AcquireConnection;
    LConn := nil; // back to the pool
  except
    Writeln('Could not connect. Settings in use (PASCALDB_SAMPLE_*, see samples/README.md):');
    Writeln(SampleConnectionSummary);
    Writeln('Is the server running? Does the client library match this program''s bitness?');
    Writeln;
    raise; // the caller reports the driver's message
  end;
end;

function NewSampleConfig(const ASqlSource: ISqlSource): IDatabaseConfig;
var
  LConfig: IDatabaseConfig; // an interface variable, never a class one (see CLAUDE.md)
begin
  LConfig := TDatabaseConfig.Create;
  SetConnectionParams(LConfig.ConnectionParams);
  if SampleIsPostgres then
  begin
    LConfig.SQLDialect := 'PostgreSQL';
    LConfig.SQLDirectory := SQL_DIR_POSTGRESQL;
  end
  else
  begin
    LConfig.SQLDialect := 'Firebird';
    LConfig.SQLDirectory := SQL_DIR_FIREBIRD;
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
