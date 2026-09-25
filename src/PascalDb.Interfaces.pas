unit PascalDb.Interfaces;

{$I pascaldb.inc}

{ Contratos da lib, agnósticos de driver: conexão, transação (e transação de
  escopo), query, resultado, parâmetros, script, pool, configuração e a
  fábrica (IDBFactory) que junta tudo. Nenhuma unit de driver é referenciada
  aqui — FireDAC, Zeos, SQLdb ou qualquer outro entram por adapter, que
  implementa IDBComponentProvider/IDBFactory.

  Também concentra a classificação de "conexão quebrada": quando uma operação
  nativa falha, IsConnectionBrokenError/MarkConnectionBrokenIfNeeded decidem se
  a conexão física deve ser descartada pelo pool, e BuildDatabaseException
  troca a exceção de baixo nível do driver (inclusive Access Violation) por
  EDatabaseUnavailableException, com mensagem segura para expor e o detalhe
  original preservado em OriginalClassName/OriginalMessage.

  IParams e IQueryResult expõem os tipos de PascalDb.Optionals (IOptXxx,
  INullXxx, IOptNullXxx): o bind de um parâmetro opcional só acontece quando
  HasValue, e coluna nullable é lida como INullXxx. }

interface

uses
  Classes,
  SysUtils,
  PascalDb.Optionals,
  PascalDb.SqlLoader;

type
  ISQLDialect = interface
    ['{5209436D-A6C9-4AA2-9258-BE8E5EE7A999}']
    function GetSavepointSQL(const AName: string): string;
    function GetRollbackToSavepointSQL(const AName: string): string;
    function GetReleaseSavepointSQL(const AName: string): string;
    function SupportsRelease: Boolean;
  end;

  IMigrationDialect = interface
    ['{A5F2C9E1-3B7D-4F8A-92C6-1E4D8B5F3A2C}']
    // Retorna 1/0 na coluna "EXISTS" — verifica se a tabela SCHEMA_MIGRATIONS existe
    function GetMigrationTableExistsSQL: string;
    // Retorna o maior VERSION aplicado na coluna "VERSION" (0 se vazia)
    function GetMigrationLastVersionSQL: string;
    // INSERT com parâmetro nomeado :VERSION
    function GetMigrationInsertVersionSQL: string;
  end;

  IDBConnection = interface
    ['{0763D2A3-9EAE-4F40-8580-E5F742C82105}']
    function GetNativeConnection: TObject;
    function IsConnected: Boolean;
    procedure Connect;
    procedure Commit;
    procedure Rollback;
    procedure Disconnect(Force: Boolean = False);
    function GetSQLDialect: ISQLDialect;
  end;

  IUnwrapDBConnection = interface
    ['{2F9E7DBA-9C39-4576-BAFB-4BA68819D35C}']
    function GetRealConnection: IDBConnection;
  end;

  // Levantada (via BuildDatabaseException) em vez da exceção nativa (FireDAC
  // ou EExternal/AV) sempre que IsConnectionBrokenError classifica a falha
  // como conexão quebrada. Nunca deveria chegar ao cliente/aos logs como um
  // "Access violation at address ..." sem contexto nenhum — essa classe dá
  // um tipo estável e reconhecível pro que é, de fato, sempre a mesma causa
  // raiz (servidor de banco fora do ar / conexão perdida), independente de
  // qual chamada nativa especificamente crashou. `Message` é genérica de
  // propósito (segura de expor ao cliente); o detalhe original (classe +
  // texto da exceção nativa, endereço de AV incluso) fica só em
  // OriginalClassName/OriginalMessage, pra quem for logar/investigar — não
  // existe "inner exception" nativa em Delphi, é assim que se preserva o
  // contexto sem vazar ruído pro cliente. Fora desta lib,
  // Horse.Middleware.ErrorHandler mapeia essa classe pra 503.
  EDatabaseUnavailableException = class(Exception)
  private
    FOriginalClassName: string;
    FOriginalMessage: string;
  public
    constructor Create(AOriginalException: Exception);
    property OriginalClassName: string read FOriginalClassName;
    property OriginalMessage: string read FOriginalMessage;
  end;

  // Implementada só pelo wrapper que o pool devolve em AcquireConnection
  // (PascalDb.Pool.TConnectionWrapper) — nunca pelos adapters "reais"
  // (TFDConnectionAdapter etc.), que não sabem nada sobre pool. Ver
  // MarkConnectionBrokenIfNeeded logo abaixo: é o ponto único que decide
  // quando chamar MarkForDiscard, a partir dos pontos onde a lib toca o
  // driver nativo (Query.Open/ExecSql, Commit/Rollback de transação).
  IDiscardableConnection = interface
    ['{6C8B2E39-6D40-4C4E-9E77-8B5B0DDE9E56}']
    procedure MarkForDiscard;
    function ShouldDiscard: Boolean;
  end;

  ITransaction = interface
    ['{DE6B1218-7FCD-4729-8D58-3CBCB3E2BCD4}']
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;
    function GetConnection: IDBConnection;
    function GetNativeTransaction: TObject;
    procedure ExecSql(const ASql: string);
  end;

  IScopeTransaction = interface
    ['{27E0E126-6765-434E-9342-33A83468DE23}']
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;
    function IsMain: Boolean;
    function GetOriginalTransaction: ITransaction;
    property OriginalTransaction: ITransaction read GetOriginalTransaction;
  end;

  { IQueryResult }

  IQueryResult = interface
    ['{6F5B03E4-49C4-487C-8AB8-742BAA268906}']
    function GetAsBoolean(const AName: string): Boolean;
    function GetAsDateTime(const AName: string): TDateTime;
    function GetAsInteger(const AName: string): Integer;
    function GetAsInt64(const AName: string): Int64;
    function GetAsString(const AName: string): string;
    function GetAsCurrency(const AName: string): Currency;
    function GetNullableBoolean(const AName: string): INullBoolean;
    function GetNullableDateTime(const AName: string): INullDateTime;
    function GetNullableInteger(const AName: string): INullInteger;
    function GetNullableInt64(const AName: string): INullInt64;
    function GetNullableString(const AName: string): INullString;
    function GetNullableCurrency(const AName: string): INullCurrency;
    function IsEmpty: Boolean;
    function FieldCount: Integer;
    function FieldValue(AIndex: Integer): Variant;
    function RecordCount: Integer;
    procedure Next;
    function Eof: Boolean;
    property NullableStrings[const AName: string]: INullString read GetNullableString;
    property NullableIntegers[const AName: string]: INullInteger read GetNullableInteger;
    property NullableInt64[const AName: string]: INullInt64 read GetNullableInt64;
    property NullableDateTimes[const AName: string]: INullDateTime read GetNullableDateTime;
    property NullableBooleans[const AName: string]: INullBoolean read GetNullableBoolean;
    property NullableCurrencies[const AName: string]: INullCurrency read GetNullableCurrency;
    property Strings[const AName: string]: string read GetAsString;
    property Integers[const AName: string]: Integer read GetAsInteger;
    property Int64s[const AName: string]: Int64 read GetAsInt64;
    property DateTimes[const AName: string]: TDateTime read GetAsDateTime;
    property Booleans[const AName: string]: Boolean read GetAsBoolean;
    property Currencies[const AName: string]: Currency read GetAsCurrency;
  end;

  { IParams }

  IParams = interface
    ['{4A386E9D-10C0-485C-83DC-8A8B663EE8BB}']
    function GetString(const AName: string): string;
    function GetBoolean(const AName: string): Boolean;
    function GetDateTime(const AName: string): TDateTime;
    function GetInteger(const AName: string): Integer;
    function GetInt64(const AName: string): Int64;
    function GetDouble(const AName: string): Double;
    function GetCurrency(const AName: string): Currency;

    function GetOptNullString(const AName: string): IOptNullString;
    function GetOptNullBoolean(const AName: string): IOptNullBoolean;
    function GetOptNullDateTime(const AName: string): IOptNullDateTime;
    function GetOptNullInteger(const AName: string): IOptNullInteger;
    function GetOptNullInt64(const AName: string): IOptNullInt64;
    function GetOptNullDouble(const AName: string): IOptNullDouble;
    function GetOptNullCurrency(const AName: string): IOptNullCurrency;

    function GetNullString(const AName: string): INullString;
    function GetNullBoolean(const AName: string): INullBoolean;
    function GetNullDateTime(const AName: string): INullDateTime;
    function GetNullInteger(const AName: string): INullInteger;
    function GetNullInt64(const AName: string): INullInt64;
    function GetNullDouble(const AName: string): INullDouble;
    function GetNullCurrency(const AName: string): INullCurrency;

    function GetOptString(const AName: string): IOptString;
    function GetOptBoolean(const AName: string): IOptBoolean;
    function GetOptDateTime(const AName: string): IOptDateTime;
    function GetOptInteger(const AName: string): IOptInteger;
    function GetOptInt64(const AName: string): IOptInt64;
    function GetOptDouble(const AName: string): IOptDouble;
    function GetOptCurrency(const AName: string): IOptCurrency;

    procedure SetString(const AName: string; AValue: string);
    procedure SetBoolean(const AName: string; AValue: Boolean);
    procedure SetDateTime(const AName: string; AValue: TDateTime);
    procedure SetInteger(const AName: string; AValue: Integer);
    procedure SetInt64(const AName: string; AValue: Int64);
    procedure SetDouble(const AName: string; AValue: Double);
    procedure SetCurrency(const AName: string; AValue: Currency);

    procedure SetOptNullBoolean(const AName: string; AValue: IOptNullBoolean);
    procedure SetOptNullDateTime(const AName: string; AValue: IOptNullDateTime);
    procedure SetOptNullInteger(const AName: string; AValue: IOptNullInteger);
    procedure SetOptNullInt64(const AName: string; AValue: IOptNullInt64);
    procedure SetOptNullString(const AName: string; AValue: IOptNullString);
    procedure SetOptNullDouble(const AName: string; AValue: IOptNullDouble);
    procedure SetOptNullCurrency(const AName: string; AValue: IOptNullCurrency);

    procedure SetNullBoolean(const AName: string; AValue: INullBoolean);
    procedure SetNullDateTime(const AName: string; AValue: INullDateTime);
    procedure SetNullInteger(const AName: string; AValue: INullInteger);
    procedure SetNullInt64(const AName: string; AValue: INullInt64);
    procedure SetNullString(const AName: string; AValue: INullString);
    procedure SetNullDouble(const AName: string; AValue: INullDouble);
    procedure SetNullCurrency(const AName: string; AValue: INullCurrency);

    procedure SetOptBoolean(const AName: string; AValue: IOptBoolean);
    procedure SetOptDateTime(const AName: string; AValue: IOptDateTime);
    procedure SetOptInteger(const AName: string; AValue: IOptInteger);
    procedure SetOptInt64(const AName: string; AValue: IOptInt64);
    procedure SetOptString(const AName: string; AValue: IOptString);
    procedure SetOptDouble(const AName: string; AValue: IOptDouble);
    procedure SetOptCurrency(const AName: string; AValue: IOptCurrency);

    property OptNullStrings[const AName: string]: IOptNullString read GetOptNullString write SetOptNullString;
    property OptNullIntegers[const AName: string]: IOptNullInteger read GetOptNullInteger write SetOptNullInteger;
    property OptNullInt64[const AName: string]: IOptNullInt64 read GetOptNullInt64 write SetOptNullInt64;
    property OptNullDateTimes[const AName: string]: IOptNullDateTime read GetOptNullDateTime write SetOptNullDateTime;
    property OptNullBooleans[const AName: string]: IOptNullBoolean read GetOptNullBoolean write SetOptNullBoolean;
    property OptNullDoubles[const AName: string]: IOptNullDouble read GetOptNullDouble write SetOptNullDouble;
    property OptNullCurrencies[const AName: string]: IOptNullCurrency read GetOptNullCurrency write SetOptNullCurrency;

    property NullStrings[const AName: string]: INullString read GetNullString write SetNullString;
    property NullIntegers[const AName: string]: INullInteger read GetNullInteger write SetNullInteger;
    property NullInt64[const AName: string]: INullInt64 read GetNullInt64 write SetNullInt64;
    property NullDateTimes[const AName: string]: INullDateTime read GetNullDateTime write SetNullDateTime;
    property NullBooleans[const AName: string]: INullBoolean read GetNullBoolean write SetNullBoolean;
    property NullDoubles[const AName: string]: INullDouble read GetNullDouble write SetNullDouble;
    property NullCurrencies[const AName: string]: INullCurrency read GetNullCurrency write SetNullCurrency;

    property OptStrings[const AName: string]: IOptString read GetOptString write SetOptString;
    property OptIntegers[const AName: string]: IOptInteger read GetOptInteger write SetOptInteger;
    property OptInt64[const AName: string]: IOptInt64 read GetOptInt64 write SetOptInt64;
    property OptDateTimes[const AName: string]: IOptDateTime read GetOptDateTime write SetOptDateTime;
    property OptBooleans[const AName: string]: IOptBoolean read GetOptBoolean write SetOptBoolean;
    property OptDoubles[const AName: string]: IOptDouble read GetOptDouble write SetOptDouble;
    property OptCurrencies[const AName: string]: IOptCurrency read GetOptCurrency write SetOptCurrency;

    property Strings[const AName: string]: string read GetString write SetString;
    property Integers[const AName: string]: Integer read GetInteger write SetInteger;
    property Int64s[const AName: string]: Int64 read GetInt64 write SetInt64;
    property DateTimes[const AName: string]: TDateTime read GetDateTime write SetDateTime;
    property Booleans[const AName: string]: Boolean read GetBoolean write SetBoolean;
    property Doubles[const AName: string]: Double read GetDouble write SetDouble;
    property Currencies[const AName: string]: Currency read GetCurrency write SetCurrency;
  end;

  IQuery = interface
    ['{1FA6B8E8-750E-4748-825D-E83C980C02D8}']
    function GetParams: IParams;
    procedure SetSql(const ASql: string);
    function GetSql: string;
    function Open: IQueryResult;
    procedure Close;
    procedure ExecSql;
    function GetConnection: IDBConnection;
    function GetTransaction: ITransaction;
    property Sql: string read GetSql write SetSql;
    property Params: IParams read GetParams;
  end;

  { ISqlScript }

  ISqlScript = interface
    ['{2AC04627-1987-44A7-9A00-7685D6B05D98}']
    procedure ExecuteScript(ATerminator: string = ';');
    function GetConnection: IDBConnection;
    function GetScript: TStrings;
    function GetTransaction: ITransaction;
    procedure SetScript(AValue: TStrings);
    property Script: TStrings read GetScript write SetScript;
  end;

  // Contadores acumulados desde a criação do pool + estado atual — pensado
  // para leitura periódica (health check, timer de métricas), não para
  // reagir a cada mudança. Complementa TPoolEvent (PascalDb.Pool): o
  // evento cobre "aconteceu agora", o snapshot cobre "quanto já aconteceu
  // no total e como está agora".
  TPoolSnapshot = record
    ActiveConnections: Integer;  // conexões físicas vivas agora (ociosas + em uso)
    PoolSize: Integer;           // conexões ociosas na fila agora
    MaxConnections: Integer;
    IniConnections: Integer;
    TotalCreated: Int64;         // conexões físicas criadas desde o início (ramp-up + crescimento sob carga)
    TotalDiscarded: Int64;       // conexões descartadas por falha de reconexão ou teste de vivacidade
    TotalTimeouts: Int64;        // AcquireConnection que esgotaram as tentativas de espera (EPoolTimeoutException)
    TotalIdleSwept: Int64;       // conexões fechadas por PoolIdleTimeoutSeconds
  end;

  { IDBConnectionPool }

  IDBConnectionPool = interface
    ['{B4214985-5C99-4323-AD5F-3DC4B5AB1194}']
    function AcquireConnection: IDBConnection;
    function GetWaitMaxAttemps: Integer;
    function GetWaitMilliseconds: Integer;
    function AcquireQuery(out AQuery: IQuery; ATransaction: ITransaction = nil): IScopeTransaction;
    function GetActiveConnections: Integer;
    function GetPoolSize: Integer;
    // Estado atual + contadores acumulados, para logging/métricas periódicos
    // (ver TPoolSnapshot). Implementações que não rastreiam os totais (ex.:
    // pools de teste/mock) podem devolver os contadores zerados.
    function GetSnapshot: TPoolSnapshot;
    property WaitMaxAttemps: Integer read GetWaitMaxAttemps;
    property WaitMilliseconds: Integer read GetWaitMilliseconds;
  end;

  IDBConnectionPoolInternalActions = interface
    ['{C1EA34EC-6E45-4B99-A2D2-2AEAB4BF382D}']
    procedure ReleaseConnection(AConn: IDBConnection);
    // Fim de vida de uma conexão que saiu marcada via IDiscardableConnection
    // (MarkConnectionBrokenIfNeeded) — descarta em vez de reenfileirar, sem
    // esperar o próximo AcquireConnection provar que ela está morta.
    procedure DiscardConnection(AConn: IDBConnection);
    procedure ReleaseQuery(var AQuery: IQuery);
  end;

  { IDatabaseConfig }

  IDatabaseConfig = interface
    ['{1B2EB232-446B-4F04-8A1B-11757D7B6F17}']
    function GetPoolIniConnections: Integer;
    function GetPoolMaxConnections: Integer;
    function GetPoolWaitMaxAttemps: Integer;
    function GetPoolWaitMilliseconds: Integer;
    function GetPoolIdleTimeoutSeconds: Integer;
    function GetPoolIdleCheckIntervalMs: Integer;
    function GetSQLDialect: string;
    procedure SetPoolIniConnections(AValue: Integer);
    procedure SetPoolMaxConnections(AValue: Integer);
    procedure SetPoolWaitMaxAttemps(AValue: Integer);
    procedure SetPoolWaitMilliseconds(AValue: Integer);
    procedure SetPoolIdleTimeoutSeconds(AValue: Integer);
    procedure SetPoolIdleCheckIntervalMs(AValue: Integer);
    procedure SetSQLDialect(AValue: string);
    property PoolWaitMaxAttemps: Integer read GetPoolWaitMaxAttemps write SetPoolWaitMaxAttemps;
    property PoolWaitMilliseconds: Integer read GetPoolWaitMilliseconds write SetPoolWaitMilliseconds;
    property PoolMaxConnections: Integer read GetPoolMaxConnections write SetPoolMaxConnections;
    property PoolIniConnections: Integer read GetPoolIniConnections write SetPoolIniConnections;
    /// Segundos que uma conexão pode ficar ociosa no pool antes de ser
    /// fechada (nunca abaixo de PoolIniConnections). 0 (padrão) = desligado,
    /// comportamento idêntico ao de antes desta propriedade existir.
    property PoolIdleTimeoutSeconds: Integer read GetPoolIdleTimeoutSeconds write SetPoolIdleTimeoutSeconds;
    /// Intervalo entre varreduras de ociosidade. Só importa quando
    /// PoolIdleTimeoutSeconds > 0. Valores <= 0 caem no padrão (30000ms).
    property PoolIdleCheckIntervalMs: Integer read GetPoolIdleCheckIntervalMs write SetPoolIdleCheckIntervalMs;
    property SQLDialect: string read GetSQLDialect write SetSQLDialect;
  end;

  IContextTransaction = interface
    ['{2DE17937-9016-4766-B186-B91033EDD8E4}']
    procedure Apply(ATransaction: ITransaction);
  end;

  IContextTransactionProvider = interface
    ['{F96AB110-4A2A-4286-A941-0C5A24FC50AB}']
    function GetContextTransaction: IContextTransaction;
  end;

  IDBComponentProvider = interface
    ['{A4738719-3191-4BA0-81A0-12AB8AE80483}']
    function BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
    function BuildTransaction(AConn: IDBConnection): ITransaction;
    function BuildScopeTransaction(ATransaction: ITransaction; AContextTransaction: IContextTransaction): IScopeTransaction;
    function BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
  end;

  IDBComponentProviderSupport = interface
    ['{10C14706-ABF5-4238-ADEF-FA41C679A555}']
    function GetProvider: IDBComponentProvider;
    procedure SetProvider(AProvider: IDBComponentProvider);
  end;

  IDBFactory = interface
    ['{7FF3BE63-5205-48AF-B52F-59F927787AE8}']
    function SqlLoader: TSQLLoader;
    function GetPool: IDBConnectionPool;
    function CreateConnection: IDBConnection;
    function CreateTransaction(AConn: IDBConnection): ITransaction;
    function CreateScopeTransaction(ATransaction: ITransaction): IScopeTransaction;
    function CreateQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function CreateSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
    function TestConnection(AConn: IDBConnection): Boolean;
  end;

// Classifica se uma exceção ocorrida durante uma operação de banco (Query,
// Commit, Rollback) indica que a conexão física ficou com estado
// comprometido e não deve ser reaproveitada:
// - EExternal (base de EAccessViolation, EStackOverflow, EPrivilege, ...) —
//   a CPU faltou dentro de uma chamada nativa; o objeto de conexão não é
//   mais confiável, independente do que IsConnected reportar depois (por
//   isso o curto-circuito do "or": nunca se chama IsConnected depois de uma
//   EExternal).
// - Qualquer outra exceção seguida de IsConnected = False — a conexão caiu
//   de fato (ex.: servidor indisponível).
// Deliberadamente NÃO cobre exceções de dados "normais" (violação de
// constraint, tipo inválido, etc.) com a conexão ainda IsConnected = True —
// aí a conexão continua saudável, só a operação falhou; descartar nesse caso
// geraria churn de conexão em todo erro de negócio comum (ex.: chave
// duplicada), sem necessidade.
function IsConnectionBrokenError(E: Exception; AConn: IDBConnection): Boolean;

// Marca AConn para descarte (via IDiscardableConnection) se E indicar
// conexão quebrada — ver IsConnectionBrokenError. Devolve se marcou ou não;
// convertido em no-op (devolve False) se AConn não implementar
// IDiscardableConnection (conexão obtida fora do pool, ou adapter de
// teste/mock) ou não estiver Assigned.
function MarkConnectionBrokenIfNeeded(AConn: IDBConnection; E: Exception): Boolean;

// Chamado nos locais onde a lib toca o driver nativo: TQueryWrapper.Open/
// ExecSql e TQueryResultWrapper (leitura de campo do IQueryResult devolvido
// por Open — cobre o AV que acontece só no meio do fetch, depois do Open já
// ter retornado com sucesso) em PascalDb.Pool;
// TFDTransactionAdapter.StartTransaction/Commit/Rollback/ExecSql em
// Db.Adapters.FireDAC — StartTransaction é o primeiro round-trip real ao
// servidor quando o Repository chama LScope.StartTransaction explicitamente
// ANTES do try/except (padrão documentado no CLAUDE.md para Insert/Update, e
// usado também por Find/Get que abrem transação cedo).
//
// Marca a conexão (MarkConnectionBrokenIfNeeded) e devolve a exceção a
// relançar: uma EDatabaseUnavailableException NOVA se E foi classificado
// como conexão quebrada (nunca deixa uma EAccessViolation ou outra exceção
// de baixo nível do driver vazar pro chamador como está — é o que chegava
// ao cliente HTTP como "Access violation at address ..." sem contexto
// nenhum, antes desta função existir), ou nil se não (erro de dados normal,
// ex. violação de constraint — o chamador deve relançar E como está).
//
// Por que devolve em vez de já relançar: "raise E;" (relançar por
// REFERÊNCIA um objeto capturado no frame de OUTRA procedure) causa Access
// Violation nesta versão do Delphi — só é seguro relançar uma exceção NOVA
// (`raise Result;`, sempre seguro de qualquer frame) ou fazer bare "raise;"
// LEXICAMENTE dentro do próprio except de quem capturou. Por isso todo call
// site segue o padrão:
//   except
//     on E: Exception do
//     begin
//       LNewE := BuildDatabaseException(AConn, E);
//       if Assigned(LNewE) then raise LNewE;
//       raise;
//     end;
//   end;
function BuildDatabaseException(AConn: IDBConnection; E: Exception): Exception;

implementation

function IsConnectionBrokenError(E: Exception; AConn: IDBConnection): Boolean;
begin
  Result := (E is EExternal) or (Assigned(AConn) and (not AConn.IsConnected));
end;

function MarkConnectionBrokenIfNeeded(AConn: IDBConnection; E: Exception): Boolean;
var
  LDiscardable: IDiscardableConnection;
begin
  Result := Assigned(AConn) and IsConnectionBrokenError(E, AConn);
  if Result and Supports(AConn, IDiscardableConnection, LDiscardable) then
    LDiscardable.MarkForDiscard;
end;

function BuildDatabaseException(AConn: IDBConnection; E: Exception): Exception;
begin
  if MarkConnectionBrokenIfNeeded(AConn, E) then
    Result := EDatabaseUnavailableException.Create(E)
  else
    Result := nil;
end;

{ EDatabaseUnavailableException }

constructor EDatabaseUnavailableException.Create(AOriginalException: Exception);
begin
  inherited Create('Banco de dados indisponível ou conexão perdida. Tente novamente em instantes.');
  if Assigned(AOriginalException) then
  begin
    FOriginalClassName := AOriginalException.ClassName;
    FOriginalMessage := AOriginalException.Message;
  end;
end;

end.
