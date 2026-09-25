unit PascalDb.Pool;

{$I pascaldb.inc}

{ Pool de conexões (TConnectionPool) sobre qualquer IDBFactory.

  AcquireConnection/AcquireQuery entregam conexões "embrulhadas": quando a
  última referência ao wrapper (conexão, query ou transação de escopo) é
  solta, a conexão volta sozinha ao pool — ou é descartada, se foi marcada
  como quebrada durante o uso (ver IDiscardableConnection e
  BuildDatabaseException em PascalDb.Interfaces).

  Comportamento configurável por IConnectionPoolConfig:
  - ramp-up de IniConnections no construtor, que NUNCA derruba o boot se o
    banco estiver fora do ar — as falhas viram eventos e a próxima Acquire
    tenta de novo;
  - crescimento sob demanda até MaxConnections, com espera limitada
    (WaitMaxAttemps × WaitMilliseconds) e EPoolTimeoutException ao esgotar;
  - teste de vivacidade de conexões paradas e descarte das mortas;
  - varredura de conexões ociosas (IdleTimeoutSeconds), numa thread dedicada
    (TIdleSweepThread) que nunca fecha abaixo de IniConnections.

  Observabilidade: eventos (TPoolEventProc) só para o que é anormal ou
  crescimento de capacidade, nunca para o caminho feliz; e GetSnapshot para
  leitura periódica de estado + contadores acumulados.

  Dual-compiler: a thread de varredura é subclasse de TThread (não
  CreateAnonymousThread), e TPoolEventProc segue PASCALDB_FUNCREFS
  (pascaldb.inc): closure ou método no Delphi, método no FPC 3.2.2.
  Tempo e espera passam por PascalDb.SystemContext, para os testes
  controlarem relógio e Sleep. }

interface

uses
  Classes,
  SysUtils,
  DateUtils,
  Generics.Collections,
  SyncObjs,
  PascalDb.Interfaces,
  PascalDb.SystemContext,
  PascalDb.Optionals;

type

  { EPoolTimeoutException }

  EPoolTimeoutException = class(Exception)
  public
    constructor Create(Active, Max, InQueue, Attempts: Integer);
  end;

  { TConnectionItem }

  TConnectionItem = record
    Connection: IDBConnection;
    LastRelease: TDateTime;
    class function New(AConn: IDBConnection): TConnectionItem; static;
  end;

  { IConnectionPoolConfig }

  IConnectionPoolConfig = interface
    ['{2AD13457-7932-46C0-B2C4-A9CE804A9672}']
    function GetIniConnections: Integer;
    function GetMaxConnections: Integer;
    function GetWaitMaxAttemps: Integer;
    function GetWaitMilliseconds: Integer;
    function GetIdleTimeoutSeconds: Integer;
    function GetIdleCheckIntervalMs: Integer;
    procedure SetIniConnections(AValue: Integer);
    procedure SetMaxConnections(AValue: Integer);
    procedure SetWaitMaxAttemps(AValue: Integer);
    procedure SetWaitMilliseconds(AValue: Integer);
    procedure SetIdleTimeoutSeconds(AValue: Integer);
    procedure SetIdleCheckIntervalMs(AValue: Integer);
    property IniConnections: Integer read GetIniConnections write SetIniConnections;
    property MaxConnections: Integer read GetMaxConnections write SetMaxConnections;
    property WaitMaxAttemps: Integer read GetWaitMaxAttemps write SetWaitMaxAttemps;
    property WaitMilliseconds: Integer read GetWaitMilliseconds write SetWaitMilliseconds;
    /// Segundos que uma conexão pode ficar ociosa no pool antes de ser
    /// fechada (nunca abaixo de IniConnections). 0 (padrão) = desligado.
    property IdleTimeoutSeconds: Integer read GetIdleTimeoutSeconds write SetIdleTimeoutSeconds;
    /// Intervalo entre varreduras de ociosidade. Só importa quando
    /// IdleTimeoutSeconds > 0. Valores <= 0 caem no padrão (30000ms).
    property IdleCheckIntervalMs: Integer read GetIdleCheckIntervalMs write SetIdleCheckIntervalMs;
  end;

  { TConnectionPoolConfig }

  TConnectionPoolConfig = class(TInterfacedObject, IConnectionPoolConfig)
  private
    FIniConnections: Integer;
    FMaxConnections: Integer;
    FWaitMaxAttemps: Integer;
    FWaitMilliseconds: Integer;
    FIdleTimeoutSeconds: Integer;
    FIdleCheckIntervalMs: Integer;
    function GetIniConnections: Integer;
    function GetMaxConnections: Integer;
    procedure SetIniConnections(AValue: Integer);
    procedure SetMaxConnections(AValue: Integer);
  public
    constructor Create;
    function GetWaitMaxAttemps: Integer;
    function GetWaitMilliseconds: Integer;
    function GetIdleTimeoutSeconds: Integer;
    function GetIdleCheckIntervalMs: Integer;
    procedure SetWaitMaxAttemps(AValue: Integer);
    procedure SetWaitMilliseconds(AValue: Integer);
    procedure SetIdleTimeoutSeconds(AValue: Integer);
    procedure SetIdleCheckIntervalMs(AValue: Integer);
  end;

  // Eventos do pool cobrem só o que é sinal de operação anormal ou de
  // crescimento de capacidade — nunca o caminho feliz (acquire/release de uma
  // conexão já pronta no pool, que acontece em toda requisição). Diferente de
  // TMigrationEvent (PascalDb.Migrations, que roda poucas vezes no startup), aqui
  // NÃO existe fallback de log no console quando AOnEvent não é informado:
  // silêncio é o comportamento correto de um pool saudável, e notificar em
  // toda acquire/release geraria uma linha de log por requisição.
  TPoolEventKind = (
    pekConnectionCreated,    // nova conexão física criada (ramp-up inicial ou crescimento sob carga)
    pekConnectionDiscarded,  // uma conexão do pool foi descartada (falhou reconectar, falhou o teste
                             // de vivacidade, ou saiu marcada como quebrada durante o uso — ver TPoolDiscardReason)
    pekAcquireThrottled,     // AcquireConnection precisou esperar (pool no limite) antes de conseguir uma conexão
    pekAcquireTimeout,       // esgotou as tentativas de espera; EPoolTimeoutException será lançada em seguida
    pekIdleSweepClosed       // a varredura de ociosidade fechou uma ou mais conexões
  );

  TPoolDiscardReason = (
    pdrConnectFailed,     // ConnectionItem.Connection.Connect falhou ao reconectar, ou
                           // AcquireConnection falhou ao abrir uma conexão nova durante o
                           // ramp-up inicial (CreateInitialConnections, banco fora do ar no boot)
    pdrStaleCheckFailed,  // FFactory.TestConnection retornou False (conexão parada/morta)
    pdrBrokenAfterUse     // IsConnectionBrokenError (PascalDb.Interfaces) marcou a conexão via
                           // IDiscardableConnection durante o uso (Query/Commit/Rollback) —
                           // descartada no release, nunca volta ociosa ao pool
  );

  TPoolEvent = record
    Kind: TPoolEventKind;
    ActiveConnections: Integer;  // FActiveConnections no momento do evento
    PoolSize: Integer;           // conexões ociosas na fila no momento do evento
    MaxConnections: Integer;
    IniConnections: Integer;
    WaitAttempts: Integer;             // pekAcquireThrottled / pekAcquireTimeout
    ClosedCount: Integer;              // pekIdleSweepClosed
    DiscardReason: TPoolDiscardReason; // pekConnectionDiscarded
    ErrorMessage: string;              // pekConnectionDiscarded (mensagem da exceção de Connect, se houver)
  end;

  // Ver PASCALDB_FUNCREFS em pascaldb.inc: "reference to" no Delphi (aceita
  // closure e metodo), "of object" no FPC 3.2.2 — passar um metodo compila
  // nos dois.
  TPoolEventProc = {$IFDEF PASCALDB_FUNCREFS}reference to procedure(const AEvent: TPoolEvent)
    {$ELSE}procedure(const AEvent: TPoolEvent) of object{$ENDIF};

  { TConnectionPool }

  TConnectionPool = class(TInterfacedObject, IDBConnectionPool, IDBConnectionPoolInternalActions)
  private
    FFactory: IDBFactory;
    FMaxConnections: Integer;
    FIniConnections: Integer;
    FPool: TQueue<TConnectionItem>;
    FLockPool: TCriticalSection;
    FActiveConnections: Integer;
    FWaitMaxAttemps: Integer;
    FWaitMilliseconds: Integer;
    FIdleTimeoutSeconds: Integer;
    FIdleCheckIntervalMs: Integer;
    FIdleSweepThread: TThread;
    FIdleSweepWake: TEvent;
    FOnEvent: TPoolEventProc;
    FTotalCreated: Int64;
    FTotalDiscarded: Int64;
    FTotalTimeouts: Int64;
    FTotalIdleSwept: Int64;
    procedure CreateInitialConnections;
    procedure IncrementActiveConnections;
    procedure DecrementActiveConnections;
    function NewConnection: IDBConnection;
    procedure StartIdleSweep;
    procedure StopIdleSweep;
    function BaseEvent(AKind: TPoolEventKind): TPoolEvent;
    procedure Notify(const AEvent: TPoolEvent);
  protected
    procedure ReleaseConnection(AConn: IDBConnection);
    procedure DiscardConnection(AConn: IDBConnection);
    procedure ReleaseQuery(var AQuery: IQuery);
  public
    // AOnEvent é opcional — sem ele, o pool simplesmente não notifica nada
    // (ver comentário em TPoolEventKind sobre por que não há fallback de
    // console aqui, ao contrário de TDBMigrationEngine).
    constructor Create(AFactory: IDBFactory; AConfig: IConnectionPoolConfig = nil;
      AOnEvent: TPoolEventProc = nil);
    destructor Destroy; override;
    function AcquireConnection: IDBConnection;
    function AcquireQuery(out AQuery: IQuery; ATransaction: ITransaction = nil): IScopeTransaction;
    function GetActiveConnections: Integer;
    function GetPoolSize: Integer;
    function GetWaitMaxAttemps: Integer;
    function GetWaitMilliseconds: Integer;
    // Estado atual + contadores acumulados desde a criação do pool — ver
    // TPoolSnapshot (PascalDb.Interfaces) para o propósito de cada campo.
    function GetSnapshot: TPoolSnapshot;
    /// Fecha, imediatamente, as conexões ociosas mais antigas do pool que
    /// ultrapassarem IdleTimeoutSeconds, nunca abaixo de IniConnections.
    /// A thread de varredura automática chama a versão sem parâmetro
    /// periodicamente quando IdleTimeoutSeconds > 0.
    /// Ambas são públicas principalmente para permitir testes determinísticos
    /// (com IClock fake) sem esperar o intervalo real nem depender da thread
    /// de fundo — a versão com parâmetro nem precisa de IdleTimeoutSeconds
    /// configurado (nem, portanto, de nenhuma thread ter sido iniciada).
    procedure SweepIdleConnections; overload;
    procedure SweepIdleConnections(AIdleTimeoutSeconds: Integer); overload;
  end;

implementation

type
  { Thread de varredura de conexoes ociosas.

    Classe dedicada em vez de TThread.CreateAnonymousThread: o FPC 3.2.2 nao
    tem metodos anonimos. Acessa membros privados do pool (mesma unit). O
    ciclo de vida (Terminate via FIdleSweepWake, WaitFor unico, Free) continua
    sendo do TConnectionPool — ver StartIdleSweep/StopIdleSweep. }
  TIdleSweepThread = class(TThread)
  private
    FPool: TConnectionPool;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TConnectionPool);
  end;

constructor TIdleSweepThread.Create(APool: TConnectionPool);
begin
  FPool := APool;
  inherited Create(False);
end;

procedure TIdleSweepThread.Execute;
begin
  while FPool.FIdleSweepWake.WaitFor(FPool.FIdleCheckIntervalMs) = wrTimeout do
    FPool.SweepIdleConnections;
end;

type

  { TConnectionWrapper
    Auto-devolve a conexão ao pool quando destruído. }

  TConnectionWrapper = class(TInterfacedObject, IDBConnection, IUnwrapDBConnection, IDiscardableConnection)
  private
    FPool: IDBConnectionPoolInternalActions;
    FInternalConn: IDBConnection;
    FDiscard: Boolean;
  public
    constructor Create(APool: IDBConnectionPoolInternalActions; ARealConn: IDBConnection);
    destructor Destroy; override;
    procedure Connect;
    procedure Disconnect(Force: Boolean = False);
    function GetNativeConnection: TObject;
    function GetRealConnection: IDBConnection;
    function GetSQLDialect: ISQLDialect;
    function IsConnected: Boolean;
    procedure Commit;
    procedure Rollback;
    // IDiscardableConnection — ver comentário na declaração da interface
    // (PascalDb.Interfaces) e MarkConnectionBrokenIfNeeded, chamado a partir de
    // TQueryWrapper.Open/ExecSql e TFDTransactionAdapter.Commit/Rollback.
    procedure MarkForDiscard;
    function ShouldDiscard: Boolean;
  end;

  { TQueryWrapper
    Auto-devolve a query ao pool quando destruído. }

  TQueryWrapper = class(TInterfacedObject, IQuery)
  private
    FPool: IDBConnectionPoolInternalActions;
    FInternalQuery: IQuery;
  public
    constructor Create(APool: IDBConnectionPoolInternalActions; ARealQuery: IQuery);
    destructor Destroy; override;
    procedure Close;
    procedure ExecSql;
    function GetConnection: IDBConnection;
    function GetParams: IParams;
    function GetSql: string;
    function GetTransaction: ITransaction;
    function Open: IQueryResult;
    procedure SetSql(const ASql: string);
  end;

  { TQueryResultWrapper
    Envolve o IQueryResult devolvido por Query.Open. Todo acesso a campo
    (GetAsXxx, GetNullableXxx, Next, ...) passa por aqui — é o ponto certo pra
    aplicar a mesma classificação de MarkConnectionBrokenIfNeeded usada em
    TQueryWrapper.Open/ExecSql: um AV ou perda de conexão no meio da leitura
    dos campos (ex.: servidor caiu durante o fetch, depois do Open já ter
    retornado com sucesso) precisa marcar a conexão pro descarte tanto quanto
    uma falha no próprio Open — sem isso, TQueryWrapper.Open só cobre a
    metade do ciclo de vida da query que menos concentra acesso ao driver
    nativo (a maior parte da leitura de dados acontece aqui, não no Open). }

  TQueryResultWrapper = class(TInterfacedObject, IQueryResult)
  private
    FInternalResult: IQueryResult;
    FConnection: IDBConnection;
    // Devolve a exceção a relançar (nova EDatabaseUnavailableException) ou
    // nil (relançar E como está) — nunca relança ela mesma. Ver comentário
    // em BuildDatabaseException (PascalDb.Interfaces): "raise E;" por referência,
    // a partir do frame de Guard (que não é onde E foi capturado), causa AV
    // nesta versão do Delphi — por isso cada método abaixo relança
    // localmente, lexicamente dentro do próprio except.
    function Guard(E: Exception): Exception;
  public
    constructor Create(AResult: IQueryResult; AConnection: IDBConnection);
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
  end;

{ TQueryWrapper }

constructor TQueryWrapper.Create(APool: IDBConnectionPoolInternalActions; ARealQuery: IQuery);
begin
  FPool := APool;
  FInternalQuery := ARealQuery;
end;

destructor TQueryWrapper.Destroy;
begin
  if Assigned(FPool) then
    FPool.ReleaseQuery(FInternalQuery);
  inherited Destroy;
end;

procedure TQueryWrapper.Close;
begin
  FInternalQuery.Close;
end;

procedure TQueryWrapper.ExecSql;
var
  LNewE: Exception;
begin
  try
    FInternalQuery.ExecSql;
  except
    on E: Exception do
    begin
      // Ver BuildDatabaseException (PascalDb.Interfaces) — nunca "raise E;" aqui:
      // relançar por referência um objeto capturado no frame de OUTRA
      // procedure causa Access Violation nesta versão do Delphi. Só é seguro
      // relançar uma exceção NOVA (LNewE) ou "raise;" bare, lexicamente
      // dentro deste próprio except.
      LNewE := BuildDatabaseException(FInternalQuery.GetConnection, E);
      if Assigned(LNewE) then
        raise LNewE;
      raise;
    end;
  end;
end;

function TQueryWrapper.GetConnection: IDBConnection;
begin
  Result := FInternalQuery.GetConnection;
end;

function TQueryWrapper.GetParams: IParams;
begin
  Result := FInternalQuery.GetParams;
end;

function TQueryWrapper.GetSql: string;
begin
  Result := FInternalQuery.GetSql;
end;

function TQueryWrapper.GetTransaction: ITransaction;
begin
  Result := FInternalQuery.GetTransaction;
end;

function TQueryWrapper.Open: IQueryResult;
var
  LRawResult: IQueryResult;
  LNewE: Exception;
begin
  try
    LRawResult := FInternalQuery.Open;
  except
    on E: Exception do
    begin
      // Ver BuildDatabaseException (PascalDb.Interfaces): só relança como
      // EDatabaseUnavailableException em EExternal (ex.: Access Violation
      // dentro da chamada nativa) ou se IsConnected virou False — violação
      // de constraint e outros erros de dados normais relançam E como está.
      // Nunca "raise E;" aqui (ver comentário em TQueryWrapper.ExecSql).
      LNewE := BuildDatabaseException(FInternalQuery.GetConnection, E);
      if Assigned(LNewE) then
        raise LNewE;
      raise;
    end;
  end;
  // O resultado cru não passa por nenhum wrapper do pool — sem isso, um AV
  // durante a leitura dos campos (ex.: servidor caiu no meio do fetch, já
  // depois do Open ter retornado com sucesso) nunca seria classificado.
  // Ver TQueryResultWrapper.
  Result := TQueryResultWrapper.Create(LRawResult, FInternalQuery.GetConnection);
end;

procedure TQueryWrapper.SetSql(const ASql: string);
begin
  FInternalQuery.SetSql(ASql);
end;

{ TQueryResultWrapper }

constructor TQueryResultWrapper.Create(AResult: IQueryResult; AConnection: IDBConnection);
begin
  FInternalResult := AResult;
  FConnection := AConnection;
end;

function TQueryResultWrapper.Guard(E: Exception): Exception;
begin
  Result := BuildDatabaseException(FConnection, E);
end;

function TQueryResultWrapper.GetAsBoolean(const AName: string): Boolean;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsBoolean(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsDateTime(const AName: string): TDateTime;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsDateTime(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsInteger(const AName: string): Integer;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsInteger(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsInt64(const AName: string): Int64;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsInt64(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsString(const AName: string): string;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsString(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsCurrency(const AName: string): Currency;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsCurrency(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableBoolean(const AName: string): INullBoolean;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableBoolean(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableDateTime(const AName: string): INullDateTime;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableDateTime(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableInteger(const AName: string): INullInteger;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableInteger(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableInt64(const AName: string): INullInt64;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableInt64(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableString(const AName: string): INullString;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableString(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableCurrency(const AName: string): INullCurrency;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableCurrency(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.IsEmpty: Boolean;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.IsEmpty;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.FieldCount: Integer;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.FieldCount;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.FieldValue(AIndex: Integer): Variant;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.FieldValue(AIndex);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.RecordCount: Integer;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.RecordCount;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

procedure TQueryResultWrapper.Next;
var
  LNewE: Exception;
begin
  try
    FInternalResult.Next;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.Eof: Boolean;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.Eof;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

{ TConnectionWrapper }

constructor TConnectionWrapper.Create(APool: IDBConnectionPoolInternalActions;
  ARealConn: IDBConnection);
begin
  FPool := APool;
  FInternalConn := ARealConn;
end;

destructor TConnectionWrapper.Destroy;
begin
  if Assigned(FPool) then
  begin
    if FDiscard then
      FPool.DiscardConnection(FInternalConn)
    else
      FPool.ReleaseConnection(FInternalConn);
  end;
  inherited Destroy;
end;

procedure TConnectionWrapper.Commit;
begin
  FInternalConn.Commit;
end;

procedure TConnectionWrapper.Connect;
begin
  FInternalConn.Connect;
end;

procedure TConnectionWrapper.Disconnect(Force: Boolean);
begin
  FInternalConn.Disconnect(Force);
end;

function TConnectionWrapper.GetNativeConnection: TObject;
begin
  Result := FInternalConn.GetNativeConnection;
end;

function TConnectionWrapper.GetRealConnection: IDBConnection;
begin
  Result := FInternalConn;
end;

function TConnectionWrapper.GetSQLDialect: ISQLDialect;
begin
  Result := FInternalConn.GetSQLDialect;
end;

function TConnectionWrapper.IsConnected: Boolean;
begin
  Result := FInternalConn.IsConnected;
end;

procedure TConnectionWrapper.Rollback;
begin
  FInternalConn.Rollback;
end;

procedure TConnectionWrapper.MarkForDiscard;
begin
  FDiscard := True;
end;

function TConnectionWrapper.ShouldDiscard: Boolean;
begin
  Result := FDiscard;
end;

{ EPoolTimeoutException }

constructor EPoolTimeoutException.Create(Active, Max, InQueue, Attempts: Integer);
begin
  inherited CreateFmt(
    'Timeout ao aguardar conexão. Pool: %d/%d ativas, %d na fila. Tentativas: %d',
    [Active, Max, InQueue, Attempts]
  );
end;

{ TConnectionItem }

class function TConnectionItem.New(AConn: IDBConnection): TConnectionItem;
begin
  Result.Connection := AConn;
  Result.LastRelease := TClock.Now;
end;

{ TConnectionPoolConfig }

constructor TConnectionPoolConfig.Create;
begin
  inherited Create;
  FIdleCheckIntervalMs := 30000; // só importa se IdleTimeoutSeconds > 0
end;

function TConnectionPoolConfig.GetIniConnections: Integer;
begin
  Result := FIniConnections;
end;

function TConnectionPoolConfig.GetMaxConnections: Integer;
begin
  Result := FMaxConnections;
end;

procedure TConnectionPoolConfig.SetIniConnections(AValue: Integer);
begin
  if AValue >= 0 then
    FIniConnections := AValue;
end;

procedure TConnectionPoolConfig.SetMaxConnections(AValue: Integer);
begin
  if AValue > 0 then
    FMaxConnections := AValue;
end;

function TConnectionPoolConfig.GetWaitMaxAttemps: Integer;
begin
  Result := FWaitMaxAttemps;
end;

function TConnectionPoolConfig.GetWaitMilliseconds: Integer;
begin
  Result := FWaitMilliseconds;
end;

procedure TConnectionPoolConfig.SetWaitMaxAttemps(AValue: Integer);
begin
  FWaitMaxAttemps := AValue;
end;

procedure TConnectionPoolConfig.SetWaitMilliseconds(AValue: Integer);
begin
  FWaitMilliseconds := AValue;
end;

function TConnectionPoolConfig.GetIdleTimeoutSeconds: Integer;
begin
  Result := FIdleTimeoutSeconds;
end;

function TConnectionPoolConfig.GetIdleCheckIntervalMs: Integer;
begin
  Result := FIdleCheckIntervalMs;
end;

procedure TConnectionPoolConfig.SetIdleTimeoutSeconds(AValue: Integer);
begin
  if AValue >= 0 then
    FIdleTimeoutSeconds := AValue;
end;

procedure TConnectionPoolConfig.SetIdleCheckIntervalMs(AValue: Integer);
begin
  if AValue > 0 then
    FIdleCheckIntervalMs := AValue;
end;

{ TConnectionPool }

constructor TConnectionPool.Create(AFactory: IDBFactory; AConfig: IConnectionPoolConfig;
  AOnEvent: TPoolEventProc);

  // Referência fraca para quebrar ciclo circular TConnectionPool <-> IDBFactory
  procedure SetWeak(aInterfaceField: PInterface; const aValue: IInterface);
  begin
    PPointer(aInterfaceField)^ := Pointer(aValue);
  end;

begin
  FOnEvent := AOnEvent;

  if Assigned(AConfig) then
  begin
    FIniConnections  := AConfig.IniConnections;
    FMaxConnections  := AConfig.MaxConnections;
    FWaitMilliseconds := AConfig.WaitMilliseconds;
    FWaitMaxAttemps  := AConfig.WaitMaxAttemps;
    FIdleTimeoutSeconds := AConfig.IdleTimeoutSeconds;
    FIdleCheckIntervalMs := AConfig.IdleCheckIntervalMs;
  end
  else
  begin
    FIniConnections  := 3;
    FMaxConnections  := 20;
    FWaitMilliseconds := 20;
    FWaitMaxAttemps  := 50;
    FIdleTimeoutSeconds := 0; // desligado por padrão
    FIdleCheckIntervalMs := 30000;
  end;

  if FIdleCheckIntervalMs <= 0 then
    FIdleCheckIntervalMs := 30000; // config já validava isso, mas o branch "sem AConfig" não

  FActiveConnections := 0;

  SetWeak(@FFactory, AFactory);

  FPool     := TQueue<TConnectionItem>.Create;
  FLockPool := TCriticalSection.Create;

  CreateInitialConnections;

  if FIdleTimeoutSeconds > 0 then
    StartIdleSweep;
end;

destructor TConnectionPool.Destroy;
begin
  // Precisa parar ANTES de mexer em FPool/FLockPool — senão a thread de
  // varredura pode disparar em cima de campos já liberados.
  StopIdleSweep;

  // Anula a referência fraca antes do Release automático gerado pelo compilador
  PPointer(@FFactory)^ := nil;

  FLockPool.Enter;
  try
    while FPool.Count > 0 do
      FPool.Dequeue;
    FPool.Free;
  finally
    FLockPool.Leave;
    FLockPool.Free;
  end;

  inherited Destroy;
end;

function TConnectionPool.BaseEvent(AKind: TPoolEventKind): TPoolEvent;
begin
  Result := Default(TPoolEvent);
  Result.Kind := AKind;
  Result.ActiveConnections := FActiveConnections;
  Result.PoolSize := FPool.Count;
  Result.MaxConnections := FMaxConnections;
  Result.IniConnections := FIniConnections;
end;

procedure TConnectionPool.Notify(const AEvent: TPoolEvent);
begin
  if Assigned(FOnEvent) then
    FOnEvent(AEvent);
end;

function TConnectionPool.GetSnapshot: TPoolSnapshot;
begin
  Result.ActiveConnections := FActiveConnections;
  Result.PoolSize := FPool.Count;
  Result.MaxConnections := FMaxConnections;
  Result.IniConnections := FIniConnections;
  Result.TotalCreated := FTotalCreated;
  Result.TotalDiscarded := FTotalDiscarded;
  Result.TotalTimeouts := FTotalTimeouts;
  Result.TotalIdleSwept := FTotalIdleSwept;
end;

procedure TConnectionPool.StartIdleSweep;
begin
  // Evento manual-reset: SetEvent no Terminate acorda a thread na hora,
  // sem esperar o intervalo cheio — mesmo padrão usado no reconnect thread
  // do pascal-named-pipes-faa (TPipeClient.FReconnectAbort).
  FIdleSweepWake := TEvent.Create(nil, True, False, '');
  FIdleSweepThread := TIdleSweepThread.Create(Self);
end;

procedure TConnectionPool.StopIdleSweep;
begin
  if not Assigned(FIdleSweepThread) then
    Exit;

  FIdleSweepWake.SetEvent;
  FIdleSweepThread.WaitFor;
  FreeAndNil(FIdleSweepThread);
  FreeAndNil(FIdleSweepWake);
end;

procedure TConnectionPool.SweepIdleConnections;
begin
  SweepIdleConnections(FIdleTimeoutSeconds);
end;

procedure TConnectionPool.SweepIdleConnections(AIdleTimeoutSeconds: Integer);
var
  LToClose: TList<IDBConnection>;
  LItem: TConnectionItem;
  LConn: IDBConnection;
  LEvent: TPoolEvent;
begin
  if AIdleTimeoutSeconds <= 0 then
    Exit;

  LToClose := TList<IDBConnection>.Create;
  try
    // Fase 1 (rápida, sob lock): decidir o que sai. FPool é FIFO por
    // LastRelease crescente, então o item da frente é sempre o mais antigo —
    // basta espiar e parar no primeiro que ainda não está ocioso o bastante.
    FLockPool.Enter;
    try
      while (FPool.Count > FIniConnections) and (FPool.Count > 0) do
      begin
        LItem := FPool.Peek;
        if SecondsBetween(TClock.Now, LItem.LastRelease) < AIdleTimeoutSeconds then
          Break;

        FPool.Dequeue;
        LToClose.Add(LItem.Connection);
        Dec(FActiveConnections); // já estamos sob FLockPool; ver DecrementActiveConnections
      end;
    finally
      FLockPool.Leave;
    end;

    // Fase 2 (lenta, fora do lock): desconectar de fato. Nunca fazer IO de
    // rede com FLockPool preso — bloquearia todo AcquireConnection/
    // ReleaseConnection concorrente da aplicação até o Disconnect terminar.
    for LConn in LToClose do
    begin
      try
        LConn.Disconnect(True);
      except
        // ignora — a conexão está sendo descartada de qualquer forma
      end;
    end;

    if LToClose.Count > 0 then
    begin
      Inc(FTotalIdleSwept, LToClose.Count);
      LEvent := BaseEvent(pekIdleSweepClosed);
      LEvent.ClosedCount := LToClose.Count;
      Notify(LEvent);
    end;
  finally
    LToClose.Free;
  end;
end;

procedure TConnectionPool.CreateInitialConnections;
var
  I: Integer;
  { Holders mantém os Wrappers vivos durante o loop para forçar o pool a
    criar conexões físicas novas. Ao sair do procedure, o array sai de escopo,
    todos os Wrappers são liberados e as conexões voltam ao pool. }
  Holders: TArray<IDBConnection>;
  LEvent: TPoolEvent;
begin
  if FIniConnections <= 0 then
    Exit;

  SetLength(Holders, FIniConnections);
  for I := 0 to FIniConnections - 1 do
  begin
    try
      Holders[I] := AcquireConnection;
    except
      // IniConnections > MaxConnections é erro de configuração, não "banco
      // fora do ar" — continua subindo, como sempre subiu (ver
      // Test_Pool_MaxConnections_Estoura/Test_Pool_Evento_AcquireTimeout_*).
      on E: EPoolTimeoutException do
        raise;
      on E: Exception do
      begin
        { Banco fora do ar (ou inacessível) no boot: não deixamos a falha subir
          e derrubar TConnectionPool.Create/TFDFactory.Create por causa do
          ramp-up inicial. Holders[I] fica nil (AcquireConnection já reverteu
          FActiveConnections em TryGetNewConnection) e o pool nasce sem essa
          conexão pré-aquecida; a próxima AcquireConnection real (primeira
          requisição, health check, etc.) tenta de novo. }
        Inc(FTotalDiscarded);
        LEvent := BaseEvent(pekConnectionDiscarded);
        LEvent.DiscardReason := pdrConnectFailed;
        LEvent.ErrorMessage := E.Message;
        Notify(LEvent);
      end;
    end;
  end;
end;

procedure TConnectionPool.IncrementActiveConnections;
begin
  FLockPool.Enter;
  try
    Inc(FActiveConnections);
  finally
    FLockPool.Leave;
  end;
end;

procedure TConnectionPool.DecrementActiveConnections;
begin
  FLockPool.Enter;
  try
    Dec(FActiveConnections);
  finally
    FLockPool.Leave;
  end;
end;

function TConnectionPool.NewConnection: IDBConnection;
begin
  Result := FFactory.CreateConnection;
end;

function TConnectionPool.AcquireConnection: IDBConnection;
var
  WaitAttempts: Integer;
  ConnectionItem: TConnectionItem;
  ShouldCreateNew: Boolean;
  ShouldUseFromPool: Boolean;
  RealConnection: IDBConnection;
  LThrottleEvent: TPoolEvent;

  procedure NotifyThrottledIfWaited;
  begin
    if WaitAttempts = 0 then
      Exit;
    LThrottleEvent := BaseEvent(pekAcquireThrottled);
    LThrottleEvent.WaitAttempts := WaitAttempts;
    Notify(LThrottleEvent);
  end;

  procedure CheckPool;
  begin
    FLockPool.Enter;
    try
      if FPool.Count > 0 then
      begin
        ShouldUseFromPool := True;
        ConnectionItem := FPool.Dequeue;
      end
      else if FActiveConnections < FMaxConnections then
      begin
        ShouldCreateNew := True;
        IncrementActiveConnections;
      end;
    finally
      FLockPool.Leave;
    end;
  end;

  function TryGetNewConnection(out AConnection: IDBConnection): Boolean;
  begin
    Result := True;
    try
      AConnection := NewConnection;
    except
      Result := False;
      DecrementActiveConnections;
      raise;
    end;
    Inc(FTotalCreated);
    Notify(BaseEvent(pekConnectionCreated));
  end;

  function TryGetConnectionFromPool(out AConnection: IDBConnection): Boolean;
  var
    LEvent: TPoolEvent;
  begin
    Result := False;

    if not ConnectionItem.Connection.IsConnected then
    begin
      try
        ConnectionItem.Connection.Connect;
      except
        on E: Exception do
        begin
          try
            ConnectionItem.Connection.Disconnect(True);
          finally
            DecrementActiveConnections;
          end;
          Inc(FTotalDiscarded);
          LEvent := BaseEvent(pekConnectionDiscarded);
          LEvent.DiscardReason := pdrConnectFailed;
          LEvent.ErrorMessage := E.Message;
          Notify(LEvent);
          Exit;
        end;
      end;
    end;

    if SecondsBetween(TClock.Now, ConnectionItem.LastRelease) >= 120 then
    begin
      if not FFactory.TestConnection(ConnectionItem.Connection) then
      begin
        try
          ConnectionItem.Connection.Disconnect(True);
        finally
          DecrementActiveConnections;
        end;
        Inc(FTotalDiscarded);
        LEvent := BaseEvent(pekConnectionDiscarded);
        LEvent.DiscardReason := pdrStaleCheckFailed;
        Notify(LEvent);
        Exit;
      end;
    end;

    Result := True;
    AConnection := ConnectionItem.Connection;
  end;

begin
  WaitAttempts := 0;
  while True do
  begin
    ShouldCreateNew  := False;
    ShouldUseFromPool := False;

    CheckPool;

    if ShouldCreateNew then
    begin
      if TryGetNewConnection(RealConnection) then
      begin
        NotifyThrottledIfWaited;
        Result := TConnectionWrapper.Create(Self, RealConnection);
        Exit;
      end;
      Result := nil;
    end;

    if ShouldUseFromPool then
    begin
      if not TryGetConnectionFromPool(RealConnection) then
      begin
        Result := nil;
        Continue;
      end;
      NotifyThrottledIfWaited;
      Result := TConnectionWrapper.Create(Self, RealConnection);
      Exit;
    end;

    if WaitAttempts >= FWaitMaxAttemps then
    begin
      Inc(FTotalTimeouts);
      LThrottleEvent := BaseEvent(pekAcquireTimeout);
      LThrottleEvent.WaitAttempts := WaitAttempts;
      Notify(LThrottleEvent);
      raise EPoolTimeoutException.Create(
        FActiveConnections, FMaxConnections, FPool.Count, WaitAttempts
      );
    end;

    TSleep.Sleep(FWaitMilliseconds);
    Inc(WaitAttempts);
  end;
end;

function TConnectionPool.AcquireQuery(out AQuery: IQuery; ATransaction: ITransaction): IScopeTransaction;
var
  LConn: IDBConnection;
  RealQuery: IQuery;
  LTransaction: ITransaction;
begin
  if Assigned(ATransaction) then
  begin
    LTransaction := ATransaction;
    LConn := ATransaction.GetConnection;
  end
  else
  begin
    LConn := AcquireConnection;
    LTransaction := FFactory.CreateTransaction(LConn);
  end;

  RealQuery := FFactory.CreateQuery(LConn, LTransaction);
  AQuery := TQueryWrapper.Create(Self, RealQuery);
  Result := FFactory.CreateScopeTransaction(LTransaction);
end;

function TConnectionPool.GetActiveConnections: Integer;
begin
  Result := FActiveConnections;
end;

function TConnectionPool.GetPoolSize: Integer;
begin
  Result := FPool.Count;
end;

function TConnectionPool.GetWaitMaxAttemps: Integer;
begin
  Result := FWaitMaxAttemps;
end;

function TConnectionPool.GetWaitMilliseconds: Integer;
begin
  Result := FWaitMilliseconds;
end;

procedure TConnectionPool.ReleaseConnection(AConn: IDBConnection);
var
  LUnwrapper: IUnwrapDBConnection;
  LRealConn: IDBConnection;
begin
  if AConn = nil then
    Exit;

  if Supports(AConn, IUnwrapDBConnection, LUnwrapper) then
    LRealConn := LUnwrapper.GetRealConnection
  else
    LRealConn := AConn;

  try
    LRealConn.Rollback;
  except
    // Chamado a partir de TConnectionWrapper.Destroy (um destructor) — nunca
    // deixa a exceção escapar daqui. Uma conexão que falha no Rollback não
    // parecia quebrada até agora (senão já teria vindo com FDiscard=True);
    // não arrisca reenfileirar mesmo assim, descarta.
    DiscardConnection(LRealConn);
    Exit;
  end;

  FLockPool.Enter;
  try
    FPool.Enqueue(TConnectionItem.New(LRealConn));
  finally
    FLockPool.Leave;
  end;
end;

procedure TConnectionPool.DiscardConnection(AConn: IDBConnection);
var
  LUnwrapper: IUnwrapDBConnection;
  LRealConn: IDBConnection;
  LEvent: TPoolEvent;
begin
  if AConn = nil then
    Exit;

  if Supports(AConn, IUnwrapDBConnection, LUnwrapper) then
    LRealConn := LUnwrapper.GetRealConnection
  else
    LRealConn := AConn;

  try
    LRealConn.Disconnect(True);
  except
    // ignora — a conexão está sendo descartada de qualquer forma
  end;

  DecrementActiveConnections;
  Inc(FTotalDiscarded);
  LEvent := BaseEvent(pekConnectionDiscarded);
  LEvent.DiscardReason := pdrBrokenAfterUse;
  Notify(LEvent);
end;

procedure TConnectionPool.ReleaseQuery(var AQuery: IQuery);
begin
  if not Assigned(AQuery) then
    Exit;

  AQuery.Close;
  AQuery := nil;
end;

end.
