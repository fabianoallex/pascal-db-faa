unit PascalDb.Migrations;

{$I pascaldb.inc}

{ Motor de migrations versionadas (TDBMigrationEngine): aplica, em ordem, os
  scripts de uma lista de TMigrationItem ainda não registrados na tabela
  SCHEMA_MIGRATIONS, e emite eventos de progresso (TMigrationEventProc).

  Padrão append-only: script publicado nunca é alterado; mudança nova é
  sempre um script novo, adicionado ao final da lista, para manter a ordem
  cronológica.

  Primeira migration: o motor NÃO cria SCHEMA_MIGRATIONS sozinho. O script
  MIG.0001 do projeto cria a tabela com esta estrutura mínima:

    -- Firebird:
    CREATE TABLE SCHEMA_MIGRATIONS (
      VERSION    INTEGER   NOT NULL,
      APPLIED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      CONSTRAINT PK_SCHEMA_MIGRATIONS PRIMARY KEY (VERSION)
    );

    -- PostgreSQL:
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version    INTEGER   NOT NULL,
      applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      CONSTRAINT pk_schema_migrations PRIMARY KEY (version)
    );

  Baseline (squashing): consolide scripts antigos num baseline quando o volume
  deixar o deploy lento ou numa versão major. Antes de remover os scripts
  anteriores, garanta que nenhum banco em produção esteja abaixo da versão do
  baseline.

  IsDDL em cada TMigrationItem:
  - False (padrão, DML): script + INSERT da versão na MESMA transação —
    atomicidade completa. Para INSERT de seed, UPDATE/DELETE de dados.
  - True (DDL): script em T1 (commit) e INSERT da versão numa T2 separada.
    Para CREATE/ALTER/DROP, CREATE INDEX etc. Motivo: no Firebird, DDL faz
    commit implícito da transação ativa; no PostgreSQL DDL é transacional, mas
    duas transações são seguras nos dois bancos, então IsDDL=True é portável.
  Esquecer IsDDL=True num script DDL provoca "Table unknown" no INSERT da
  versão — o erro que motivou o flag.

  Sem AOnEvent, os eventos viram uma linha de texto via SafeWriteln
  (PascalDb.SafeLog). O callback segue PASCALDB_FUNCREFS (pascaldb.inc):
  closure ou método no Delphi, método no FPC 3.2.2. }

interface

uses
  Classes,
  SysUtils,
  PascalDb.Interfaces;

type
  TParamReplaceProc = procedure(AScript: TStrings);

  TMigrationItem = record
    Version: Integer;
    ScriptName: string;
    ParamReplaceProc: TParamReplaceProc;
    Terminator: string;
    IsDDL: Boolean;
  end;

  // Cada etapa do Execute dispara um TMigrationEvent — o engine não formata
  // texto nem decide destino de log; o chamador tem os dados estruturados
  // da migration em andamento e escolhe como/onde registrar (console,
  // Common.FileLog, métricas, etc.).
  TMigrationEventKind = (
    mekCheck,      // início do Execute: SchemaVersion = versão antes de aplicar qualquer coisa
    mekApplying,   // uma migration pendente está prestes a rodar
    mekApplied,    // a migration rodou e a versão já foi registrada
    mekFailed,     // a migration falhou (ErrorMessage preenchido); Execute vai propagar a exceção em seguida
    mekCompleted   // fim do Execute: AppliedCount e SchemaVersion refletem o resultado final
  );

  TMigrationEvent = record
    Kind: TMigrationEventKind;
    Version: Integer;        // versão da migration em processamento (mekApplying/mekApplied/mekFailed); 0 nos demais
    ScriptName: string;      // nome do script (mekApplying/mekApplied/mekFailed); '' nos demais
    IsDDL: Boolean;          // TMigrationItem.IsDDL da migration em processamento
    SchemaVersion: Integer;  // versão do schema: baseline em mekCheck, versão final em mekCompleted
    AppliedCount: Integer;   // quantas migrations já foram aplicadas nesta execução (mekCompleted)
    ErrorMessage: string;    // mensagem da exceção (mekFailed)
  end;

  // Ver PASCALDB_FUNCREFS em pascaldb.inc: "reference to" no Delphi (aceita
  // closure e metodo), "of object" no FPC 3.2.2 — passar um metodo compila
  // nos dois.
  TMigrationEventProc = {$IFDEF PASCALDB_FUNCREFS}reference to procedure(const AEvent: TMigrationEvent)
    {$ELSE}procedure(const AEvent: TMigrationEvent) of object{$ENDIF};

  { TDBMigrationEngine }

  TDBMigrationEngine = class
  private
    FFactory: IDBFactory;
    FOnEvent: TMigrationEventProc;
    function DescribeEvent(const AEvent: TMigrationEvent): string;
    procedure Notify(const AEvent: TMigrationEvent);
    function ResolveMigrationDialect: IMigrationDialect;
    function GetCurrentVersion(AMigDialect: IMigrationDialect): Integer;
    procedure ApplyScript(const AMigration: TMigrationItem; ATransaction: ITransaction);
    procedure InsertVersionRecord(AVersion: Integer; AMigDialect: IMigrationDialect;
      ATransaction: ITransaction = nil);
  public
    // AOnEvent é opcional — sem ele, os eventos viram uma linha de texto no
    // console via SafeWriteln (mesmo fallback de TLoggerMiddleware.New).
    // Passe um callback para acessar os dados da migration em andamento e
    // registrá-los do jeito que convier:
    //
    //   TDBMigrationEngine.Create(LFactory,
    //     procedure(const AEvent: TMigrationEvent)
    //     begin
    //       case AEvent.Kind of
    //         mekApplying: FileLog('migrations', 'Aplicando %d (%s)', [AEvent.Version, AEvent.ScriptName]);
    //         mekFailed:   FileLog('migrations', 'Falhou %d: %s', [AEvent.Version, AEvent.ErrorMessage]);
    //       end;
    //     end);
    constructor Create(AFactory: IDBFactory; AOnEvent: TMigrationEventProc = nil);
    // Versão atual do schema (última migration aplicada). Útil no startup da
    // aplicação para logar/expor o estado do banco antes de decidir se roda
    // Execute — resolve o dialeto e consulta SCHEMA_MIGRATIONS diretamente,
    // sem depender de uma chamada prévia a Execute.
    function CurrentVersion: Integer;
    procedure Execute(const AMigrations: array of TMigrationItem);
  end;

implementation

uses
  PascalDb.SafeLog;

{ TDBMigrationEngine }

constructor TDBMigrationEngine.Create(AFactory: IDBFactory; AOnEvent: TMigrationEventProc);
begin
  FFactory := AFactory;
  FOnEvent := AOnEvent;
end;

function TDBMigrationEngine.DescribeEvent(const AEvent: TMigrationEvent): string;
begin
  case AEvent.Kind of
    mekCheck:
      Result := Format('Verificando migrations. Versão atual: %d', [AEvent.SchemaVersion]);
    mekApplying:
      Result := Format('Aplicando migration %d (%s)...', [AEvent.Version, AEvent.ScriptName]);
    mekApplied:
      Result := Format('Migration %d (%s) aplicada com sucesso.', [AEvent.Version, AEvent.ScriptName]);
    mekFailed:
      Result := Format('Falha ao aplicar migration %d (%s): %s',
        [AEvent.Version, AEvent.ScriptName, AEvent.ErrorMessage]);
    mekCompleted:
      if AEvent.AppliedCount = 0 then
        Result := Format('Nenhuma migration pendente. Versão atual: %d', [AEvent.SchemaVersion])
      else
        Result := Format('Migrations concluídas: %d aplicada(s). Versão final: %d',
          [AEvent.AppliedCount, AEvent.SchemaVersion]);
  else
    Result := '';
  end;
end;

procedure TDBMigrationEngine.Notify(const AEvent: TMigrationEvent);
begin
  if Assigned(FOnEvent) then
    FOnEvent(AEvent)
  else
    SafeWriteln(Format('[%s] %s',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), DescribeEvent(AEvent)]));
end;

function TDBMigrationEngine.CurrentVersion: Integer;
begin
  Result := GetCurrentVersion(ResolveMigrationDialect);
end;

function TDBMigrationEngine.ResolveMigrationDialect: IMigrationDialect;
var
  LConn: IDBConnection;
begin
  LConn := FFactory.GetPool.AcquireConnection;
  try
    if not Supports(LConn.GetSQLDialect, IMigrationDialect, Result) then
      raise Exception.Create(
        'O dialeto configurado não implementa IMigrationDialect. ' +
        'Verifique se TFirebirdDialect ou TPostgreSQLDialect está em uso.');
  finally
    LConn := nil; // devolve ao pool
  end;
end;

function TDBMigrationEngine.GetCurrentVersion(AMigDialect: IMigrationDialect): Integer;
var
  LScope: IScopeTransaction;
  LQuery: IQuery;
  LResult: IQueryResult;
  LTableExists: Boolean;
begin
  // Verifica existência da tabela de controle
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AMigDialect.GetMigrationTableExistsSQL;
    LResult := LQuery.Open;
    LTableExists := LResult.Booleans['EXISTS'];
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;

  if not LTableExists then
  begin
    Result := 0;
    Exit;
  end;

  // Lê a versão atual
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AMigDialect.GetMigrationLastVersionSQL;
    LResult := LQuery.Open;
    Result := LResult.Integers['VERSION'];
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TDBMigrationEngine.ApplyScript(const AMigration: TMigrationItem;
  ATransaction: ITransaction);
var
  LScript: TStrings;
  LSqlScript: ISqlScript;
begin
  LScript := TStringList.Create;
  try
    LScript.Text := FFactory.SqlLoader[AMigration.ScriptName].SQL;

    if Assigned(AMigration.ParamReplaceProc) then
      AMigration.ParamReplaceProc(LScript);

    if Trim(LScript.Text) = '' then
      raise Exception.CreateFmt('Script vazio: %s', [AMigration.ScriptName]);

    LSqlScript := FFactory.CreateSqlScript(ATransaction.GetConnection, ATransaction);
    LSqlScript.Script := LScript;
    LSqlScript.ExecuteScript(AMigration.Terminator);
  finally
    LScript.Free;
  end;
end;

procedure TDBMigrationEngine.InsertVersionRecord(AVersion: Integer;
  AMigDialect: IMigrationDialect; ATransaction: ITransaction);
var
  LScope: IScopeTransaction;
  LQuery: IQuery;
begin
  if Assigned(ATransaction) then
  begin
    // DML: INSERT na mesma transação do script para garantir atomicidade.
    // Usa CreateQuery diretamente para não interferir com o IScopeTransaction do chamador.
    LQuery := FFactory.CreateQuery(ATransaction.GetConnection, ATransaction);
    LQuery.Sql := AMigDialect.GetMigrationInsertVersionSQL;
    LQuery.Params.Integers['VERSION'] := AVersion;
    LQuery.ExecSql;
  end
  else
  begin
    // DDL: Firebird auto-commita DDL; precisamos de transação nova
    // para enxergar a tabela criada pelo script anterior.
    LScope := FFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    try
      LQuery.Sql := AMigDialect.GetMigrationInsertVersionSQL;
      LQuery.Params.Integers['VERSION'] := AVersion;
      LQuery.ExecSql;
      LScope.Commit;
    except
      LScope.Rollback;
      raise;
    end;
  end;
end;

procedure TDBMigrationEngine.Execute(const AMigrations: array of TMigrationItem);
var
  LMigDialect: IMigrationDialect;
  LCurrentVersion: Integer;
  LLastAppliedVersion: Integer;
  LAppliedCount: Integer;
  LMigration: TMigrationItem;
  LScope: IScopeTransaction;
  LQuery: IQuery;
  LEvent: TMigrationEvent;
begin
  LMigDialect := ResolveMigrationDialect;
  LCurrentVersion := GetCurrentVersion(LMigDialect);
  LLastAppliedVersion := LCurrentVersion;
  LAppliedCount := 0;

  LEvent := Default(TMigrationEvent);
  LEvent.Kind := mekCheck;
  LEvent.SchemaVersion := LCurrentVersion;
  Notify(LEvent);

  for LMigration in AMigrations do
  begin
    if LMigration.Version <= LCurrentVersion then
      Continue;

    LEvent := Default(TMigrationEvent);
    LEvent.Kind := mekApplying;
    LEvent.Version := LMigration.Version;
    LEvent.ScriptName := LMigration.ScriptName;
    LEvent.IsDDL := LMigration.IsDDL;
    Notify(LEvent);

    try
      if LMigration.IsDDL then
      begin
        // T1: executa o DDL e commita (Firebird auto-commita; PostgreSQL commita aqui)
        LScope := FFactory.GetPool.AcquireQuery(LQuery);
        LScope.StartTransaction;
        try
          ApplyScript(LMigration, LScope.GetOriginalTransaction);
          LScope.Commit;
        except
          LScope.Rollback;
          raise;
        end;

        // T2: registra versão — transação nova enxerga a tabela criada acima
        InsertVersionRecord(LMigration.Version, LMigDialect, nil);
      end
      else
      begin
        // DML: script + versão em uma única transação (atômica)
        LScope := FFactory.GetPool.AcquireQuery(LQuery);
        LScope.StartTransaction;
        try
          ApplyScript(LMigration, LScope.GetOriginalTransaction);
          InsertVersionRecord(LMigration.Version, LMigDialect,
            LScope.GetOriginalTransaction);
          LScope.Commit;
        except
          LScope.Rollback;
          raise;
        end;
      end;
    except
      on E: Exception do
      begin
        LEvent := Default(TMigrationEvent);
        LEvent.Kind := mekFailed;
        LEvent.Version := LMigration.Version;
        LEvent.ScriptName := LMigration.ScriptName;
        LEvent.IsDDL := LMigration.IsDDL;
        LEvent.ErrorMessage := E.Message;
        Notify(LEvent);
        raise;
      end;
    end;

    LLastAppliedVersion := LMigration.Version;
    Inc(LAppliedCount);

    LEvent := Default(TMigrationEvent);
    LEvent.Kind := mekApplied;
    LEvent.Version := LMigration.Version;
    LEvent.ScriptName := LMigration.ScriptName;
    LEvent.IsDDL := LMigration.IsDDL;
    Notify(LEvent);
  end;

  LEvent := Default(TMigrationEvent);
  LEvent.Kind := mekCompleted;
  LEvent.SchemaVersion := LLastAppliedVersion;
  LEvent.AppliedCount := LAppliedCount;
  Notify(LEvent);
end;

end.
