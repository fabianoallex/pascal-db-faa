unit PascalDb.SqlDialect;

{$I pascaldb.inc}

{ SQL differences between databases that the library itself has to generate:
  savepoints (create, roll back to, release) via ISQLDialect, and the queries
  on the migrations control table via IMigrationDialect. Implementations for
  PostgreSQL, Firebird and SQLite, registered in this unit's initialization
  section under the names 'PostgreSQL', 'Firebird' and 'SQLite'; adapters
  resolve the dialect
  with TSQLDialectFactory.GetDialect(Config.SQLDialect). New database:
  RegisterDialect(Name, Class) in the application's composition root.
  Names are matched ignoring case, like the drivers' own names ('firebird'
  finds 'Firebird'); an unknown name raises EArgumentException listing the
  registered ones.

  Business SQL does NOT go through here — it lives in each project's .sql
  files (see PascalDb.SqlLoader). }

interface

uses
  Classes,
  SysUtils,
  Generics.Collections,
  PascalDb.Interfaces;

type
  TSQLDialectClass = class of TInterfacedObject;

  { TSQLDialectFactory }

  TSQLDialectFactory = class
  private
    // Keyed by the upper-cased name; FNames keeps the names as registered,
    // for error messages.
    class var FDialects: TDictionary<string, TSQLDialectClass>;
    class var FNames: TStringList;
    class function RegisteredNames: string; static;
  public
    class constructor Create;
    class destructor Destroy;
    class procedure RegisterDialect(const AName: string; ADialectClass: TSQLDialectClass);
    class function GetDialect(const AName: string): ISQLDialect;
  end;

  { TPostgreSQLDialect }

  TPostgreSQLDialect = class(TInterfacedObject, ISQLDialect, IMigrationDialect)
  public
    function GetReleaseSavepointSQL(const AName: string): string;
    function GetRollbackToSavepointSQL(const AName: string): string;
    function GetSavepointSQL(const AName: string): string;
    function SupportsRelease: Boolean;
    function GetPingSQL: string;
    function GetMigrationTableExistsSQL: string;
    function GetMigrationLastVersionSQL: string;
    function GetMigrationInsertVersionSQL: string;
  end;

  { TFirebirdDialect }

  TFirebirdDialect = class(TInterfacedObject, ISQLDialect, IMigrationDialect)
  public
    function GetReleaseSavepointSQL(const AName: string): string;
    function GetRollbackToSavepointSQL(const AName: string): string;
    function GetSavepointSQL(const AName: string): string;
    function SupportsRelease: Boolean;
    function GetPingSQL: string;
    function GetMigrationTableExistsSQL: string;
    function GetMigrationLastVersionSQL: string;
    function GetMigrationInsertVersionSQL: string;
  end;

  { TSQLiteDialect
    SQLite has savepoints (SAVEPOINT / ROLLBACK TO / RELEASE) and keeps table
    names as written, so the control table is looked up case-insensitively
    in sqlite_master. }

  TSQLiteDialect = class(TInterfacedObject, ISQLDialect, IMigrationDialect)
  public
    function GetReleaseSavepointSQL(const AName: string): string;
    function GetRollbackToSavepointSQL(const AName: string): string;
    function GetSavepointSQL(const AName: string): string;
    function SupportsRelease: Boolean;
    function GetPingSQL: string;
    function GetMigrationTableExistsSQL: string;
    function GetMigrationLastVersionSQL: string;
    function GetMigrationInsertVersionSQL: string;
  end;

implementation

{ TSQLDialectFactory }

class constructor TSQLDialectFactory.Create;
begin
  FDialects := TDictionary<string, TSQLDialectClass>.Create;
  FNames := TStringList.Create;
end;

class destructor TSQLDialectFactory.Destroy;
begin
  FNames.Free;
  FDialects.Free;
end;

class function TSQLDialectFactory.RegisteredNames: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FNames.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + FNames[I];
  end;
end;

class procedure TSQLDialectFactory.RegisterDialect(const AName: string;
  ADialectClass: TSQLDialectClass);
begin
  if Trim(AName) = '' then
    raise EArgumentException.Create('TSQLDialectFactory.RegisterDialect: the name is empty');
  if FDialects.ContainsKey(UpperCase(AName)) then
    raise EArgumentException.CreateFmt('TSQLDialectFactory.RegisterDialect: a dialect named "%s" is already registered',
      [AName]);
  FDialects.Add(UpperCase(AName), ADialectClass);
  FNames.Add(AName);
end;

class function TSQLDialectFactory.GetDialect(const AName: string): ISQLDialect;
var
  LDialectClass: TSQLDialectClass;
begin
  if not FDialects.TryGetValue(UpperCase(AName), LDialectClass) then
  begin
    if AName = '' then
      raise EArgumentException.CreateFmt('No SQL dialect set: IDatabaseConfig.SQLDialect is empty ' +
        '(registered dialects: %s)', [RegisteredNames]);
    raise EArgumentException.CreateFmt('SQL dialect "%s" is not registered (registered dialects: %s). ' +
      'Check IDatabaseConfig.SQLDialect, or register it with TSQLDialectFactory.RegisterDialect',
      [AName, RegisteredNames]);
  end;

  Result := LDialectClass.Create as ISQLDialect;
end;

{ TPostgreSQLDialect }

function TPostgreSQLDialect.GetReleaseSavepointSQL(const AName: string): string;
begin
  Result := Format('RELEASE SAVEPOINT %s;', [AName]);
end;

function TPostgreSQLDialect.GetRollbackToSavepointSQL(const AName: string): string;
begin
  Result := Format('ROLLBACK TO SAVEPOINT %s;', [AName]);
end;

function TPostgreSQLDialect.GetSavepointSQL(const AName: string): string;
begin
  Result := Format('SAVEPOINT %s;', [AName]);
end;

function TPostgreSQLDialect.SupportsRelease: Boolean;
begin
  Result := True;
end;

function TPostgreSQLDialect.GetPingSQL: string;
begin
  Result := 'SELECT 1';
end;

function TPostgreSQLDialect.GetMigrationTableExistsSQL: string;
begin
  Result :=
    'SELECT CASE WHEN EXISTS(' +
    '  SELECT 1 FROM information_schema.tables ' +
    '  WHERE table_schema = ''public'' AND table_name = ''schema_migrations''' +
    ') THEN 1 ELSE 0 END AS "EXISTS"';
end;

function TPostgreSQLDialect.GetMigrationLastVersionSQL: string;
begin
  Result := 'SELECT COALESCE(MAX(version), 0) AS VERSION FROM schema_migrations';
end;

function TPostgreSQLDialect.GetMigrationInsertVersionSQL: string;
begin
  Result :=
    'INSERT INTO schema_migrations (version, applied_at) ' +
    'VALUES (:VERSION, CURRENT_TIMESTAMP)';
end;

{ TFirebirdDialect }

function TFirebirdDialect.GetReleaseSavepointSQL(const AName: string): string;
begin
  Result := Format('RELEASE SAVEPOINT %s;', [AName]);
end;

function TFirebirdDialect.GetRollbackToSavepointSQL(const AName: string): string;
begin
  Result := Format('ROLLBACK TO SAVEPOINT %s;', [AName]);
end;

function TFirebirdDialect.GetSavepointSQL(const AName: string): string;
begin
  Result := Format('SAVEPOINT %s;', [AName]);
end;

function TFirebirdDialect.SupportsRelease: Boolean;
begin
  Result := True;
end;

function TFirebirdDialect.GetPingSQL: string;
begin
  Result := 'SELECT 1 FROM RDB$DATABASE';
end;

function TFirebirdDialect.GetMigrationTableExistsSQL: string;
begin
  Result :=
    'SELECT CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END AS "EXISTS" ' +
    'FROM RDB$RELATIONS ' +
    'WHERE RDB$RELATION_NAME = ''SCHEMA_MIGRATIONS''';
end;

function TFirebirdDialect.GetMigrationLastVersionSQL: string;
begin
  Result := 'SELECT COALESCE(MAX(VERSION), 0) AS VERSION FROM SCHEMA_MIGRATIONS';
end;

function TFirebirdDialect.GetMigrationInsertVersionSQL: string;
begin
  Result :=
    'INSERT INTO SCHEMA_MIGRATIONS (VERSION, APPLIED_AT) ' +
    'VALUES (:VERSION, CURRENT_TIMESTAMP)';
end;

{ TSQLiteDialect }

function TSQLiteDialect.GetReleaseSavepointSQL(const AName: string): string;
begin
  Result := Format('RELEASE SAVEPOINT %s;', [AName]);
end;

function TSQLiteDialect.GetRollbackToSavepointSQL(const AName: string): string;
begin
  Result := Format('ROLLBACK TO SAVEPOINT %s;', [AName]);
end;

function TSQLiteDialect.GetSavepointSQL(const AName: string): string;
begin
  Result := Format('SAVEPOINT %s;', [AName]);
end;

function TSQLiteDialect.SupportsRelease: Boolean;
begin
  Result := True;
end;

function TSQLiteDialect.GetPingSQL: string;
begin
  Result := 'SELECT 1';
end;

function TSQLiteDialect.GetMigrationTableExistsSQL: string;
begin
  Result :=
    'SELECT CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END AS "EXISTS" ' +
    'FROM sqlite_master ' +
    'WHERE type = ''table'' AND LOWER(name) = ''schema_migrations''';
end;

function TSQLiteDialect.GetMigrationLastVersionSQL: string;
begin
  Result := 'SELECT COALESCE(MAX(VERSION), 0) AS VERSION FROM SCHEMA_MIGRATIONS';
end;

function TSQLiteDialect.GetMigrationInsertVersionSQL: string;
begin
  Result :=
    'INSERT INTO SCHEMA_MIGRATIONS (VERSION, APPLIED_AT) ' +
    'VALUES (:VERSION, CURRENT_TIMESTAMP)';
end;

initialization
  TSQLDialectFactory.RegisterDialect('PostgreSQL', TPostgreSQLDialect);
  TSQLDialectFactory.RegisterDialect('Firebird', TFirebirdDialect);
  TSQLDialectFactory.RegisterDialect('SQLite', TSQLiteDialect);

end.
