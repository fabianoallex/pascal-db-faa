unit PascalDb.SqlDialect;

{$I pascaldb.inc}

{ Diferenças de SQL entre bancos que a própria lib precisa gerar: savepoints
  (criar, voltar, liberar) via ISQLDialect, e as consultas da tabela de
  controle de migrations via IMigrationDialect. Implementações para
  PostgreSQL e Firebird, registradas no initialization desta unit com os
  nomes 'PostgreSQL' e 'Firebird'; adapters resolvem o dialeto com
  TSQLDialectFactory.GetDialect(Config.SQLDialect). Banco novo:
  RegisterDialect(Nome, Classe) no ponto de montagem da aplicação.

  SQL de negócio NÃO passa por aqui — esse fica nos arquivos .sql de cada
  projeto (ver PascalDb.SqlLoader). }

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
    class var FDialects: TDictionary<string, TSQLDialectClass>;
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
    function GetMigrationTableExistsSQL: string;
    function GetMigrationLastVersionSQL: string;
    function GetMigrationInsertVersionSQL: string;
  end;

implementation

{ TSQLDialectFactory }

class constructor TSQLDialectFactory.Create;
begin
  FDialects := TDictionary<string, TSQLDialectClass>.Create;
end;

class destructor TSQLDialectFactory.Destroy;
begin
  FDialects.Free;
end;

class procedure TSQLDialectFactory.RegisterDialect(const AName: string;
  ADialectClass: TSQLDialectClass);
begin
  FDialects.Add(AName, ADialectClass);
end;

class function TSQLDialectFactory.GetDialect(const AName: string): ISQLDialect;
var
  LDialectClass: TSQLDialectClass;
begin
  if not FDialects.TryGetValue(AName, LDialectClass) then
    raise Exception.CreateFmt('Dialeto SQL "%s" não encontrado ou não registrado.', [AName]);

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

initialization
  TSQLDialectFactory.RegisterDialect('PostgreSQL', TPostgreSQLDialect);
  TSQLDialectFactory.RegisterDialect('Firebird', TFirebirdDialect);

end.
