unit PascalDb.PoolTests;

{$mode delphi}{$H+}

{ ARQUIVO GERADO por tools/gen_fpc_mirror.py a partir de
  tests/Unit/PascalDb.PoolTests.pas (DUnitX). Não edite à mão: edite o mestre DUnitX
  e rode o script de novo. }

{ Testes do pool de conexões (PascalDb.Pool) sobre conexões, transações e
  queries falsas: acquire/release, limite e timeout, ramp-up com o banco fora
  do ar, teste de vivacidade, varredura de ociosas (relógio falso e thread
  real), descarte de conexão quebrada durante o uso (inclusive Access
  Violation na leitura de campo), eventos, snapshot e concorrência.

  Relógio e Sleep são substituídos via PascalDb.SystemContext (TFakeClock,
  TFakeSleep); os eventos são gravados por TPoolEventRecorder — um método,
  não closure, porque TPoolEventProc é "of object" no FPC 3.2.2.

  Mestre DUnitX, escrito no dialeto de asserts do FPCUnit (TAssert.*, via
  PascalDb.DUnitXCompat). O espelho em tests/Unit/fpc é gerado a partir do
  mestre por tools/gen_fpc_mirror.py — edite só o mestre. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Classes,
  Generics.Collections,
  PascalDb.Interfaces,
  PascalDb.Pool,
  PascalDb.SqlLoader,
  PascalDb.SystemContext,
  PascalDb.Optionals,
  PascalDb.Threading,
  Variants;

type

  { ITestableTransaction — extensão de teste para verificar comandos gravados }

  ITestableTransaction = interface(ITransaction)
    ['{AEB38845-ABBF-4DC2-808F-2EACAC280440}']
    function GetCommands: TStringList;
    function GetCommitCount: Integer;
    function GetRollbackCount: Integer;
  end;

  { TFakeSleep }

  { TPoolEventRecorder

    Grava os eventos do pool numa lista, para os testes inspecionarem depois.
    Metodo (OnEvent) em vez de closure: TPoolEventProc e' "of object" no FPC
    3.2.2 (ver PASCALDB_FUNCREFS em pascaldb.inc), e metodo e' o subconjunto
    que compila nos dois compiladores. }

  TPoolEventRecorder = class
  private
    FEvents: TList<TPoolEvent>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const AEvent: TPoolEvent);
    property Events: TList<TPoolEvent> read FEvents;
  end;

  TFakeSleep = class(TInterfacedObject, ISleep)
  public
    procedure Sleep(milliseconds: Cardinal);
  end;

  { TFakeClock }

  TFakeClock = class(TInterfacedObject, IClock)
  private
    FTimes: TQueue<TDateTime>;
    FDefaultTime: TDateTime;
  public
    constructor Create;
    destructor Destroy; override;
    function Now: TDateTime;
    function Date: TDateTime;
    procedure EnqueueTime(ADateTime: TDateTime);
    procedure SetDefaultTime(ADateTime: TDateTime);
  end;

  { TFakeDBConnection }

  TFakeDBConnection = class(TInterfacedObject, IDBConnection)
  private
    FConnected: Boolean;
  public
    constructor Create;
    procedure Commit;
    procedure Connect;
    procedure Disconnect(Force: Boolean = False);
    function GetNativeConnection: TObject;
    function GetSQLDialect: ISQLDialect;
    function IsConnected: Boolean;
    procedure Rollback;
    // Mutável de propósito — testes usam pra simular o driver detectando a
    // queda da conexão (IsConnected = False) depois de Open/ExecSql falhar.
    property Connected: Boolean read FConnected write FConnected;
  end;

  { TFakeTransaction }

  TFakeTransaction = class(TInterfacedObject, ITransaction, ITestableTransaction)
  private
    FCommands: TStringList;
    FCommitCount: Integer;
    FRollbackCount: Integer;
    FConnection: IDBConnection;
  public
    constructor Create(AConn: IDBConnection);
    destructor Destroy; override;
    // ITransaction
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;
    function GetConnection: IDBConnection;
    function GetNativeTransaction: TObject;
    procedure ExecSql(const ASql: string);
    // ITestableTransaction
    function GetCommands: TStringList;
    function GetCommitCount: Integer;
    function GetRollbackCount: Integer;
  end;

  { TFakeScopeTransaction }

  TFakeScopeTransaction = class(TInterfacedObject, IScopeTransaction)
  private
    FOriginalTransaction: ITransaction;
  public
    constructor Create(AOriginalTransaction: ITransaction);
    procedure Commit;
    function GetOriginalTransaction: ITransaction;
    function InTransaction: Boolean;
    function IsMain: Boolean;
    procedure Rollback;
    procedure StartTransaction;
  end;

  { TFakeQueryResult
    Mock de IQueryResult cujos métodos podem ser configurados pra lançar uma
    exceção — usado pra reproduzir o cenário real (Access Violation durante a
    leitura de campo, depois do Open já ter retornado com sucesso) que
    TQueryWrapper.Open sozinho não cobria — ver TQueryResultWrapper
    (PascalDb.Pool). }

  TFakeQueryResult = class(TInterfacedObject, IQueryResult)
  private
    FExceptionClass: ExceptClass;
    FExceptionMsg: string;
    procedure MaybeRaise;
  public
    procedure SetRaiseOnAnyCall(AExceptionClass: ExceptClass; const AMsg: string);
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

  { TFakeQuery }

  TFakeQuery = class(TInterfacedObject, IQuery)
  private
    FSql: string;
    FTransaction: ITransaction;
    FConnection: IDBConnection;
    FOpenExceptionClass: ExceptClass;
    FOpenExceptionMsg: string;
    FOpenResult: IQueryResult;
  public
    constructor Create(AConn: IDBConnection; ATrans: ITransaction);
    procedure Close;
    procedure ExecSql;
    function GetConnection: IDBConnection;
    function GetParams: IParams;
    function GetSql: string;
    function GetTransaction: ITransaction;
    function Open: IQueryResult;
    procedure SetSql(const ASql: string);
    // Testes de Test_Pool_ConexaoDescartada_* / Test_Pool_ConexaoMantida_* —
    // faz o próximo Open lançar AExceptionClass em vez de devolver nil.
    procedure SetRaiseOnOpen(AExceptionClass: ExceptClass; const AMsg: string);
    // Test_Pool_ConexaoDescartada_ExcecaoDuranteLeituraDeCampo — Open passa a
    // devolver AResult (em vez de nil) quando não há SetRaiseOnOpen configurado.
    procedure SetOpenResult(AResult: IQueryResult);
  end;

  { TDBFactoryMock }

  TDBFactoryMock = class(TInterfacedObject, IDBFactory)
  private
    FSimulateTestConnectionFail: Boolean;
    FTestedConnections: TList<IDBConnection>;
    FLastCreatedConnection: TFakeDBConnection;
    FNextQueryOpenExceptionClass: ExceptClass;
    FNextQueryOpenExceptionMsg: string;
    FNextQueryOpenResult: IQueryResult;
    // Test_Pool_InicialConnections_BancoForaDoAr_* — quantas próximas chamadas
    // a CreateConnection devem simular "banco fora do ar" (Connect falhando),
    // decrementado a cada chamada até chegar a 0.
    FCreateConnectionFailuresRemaining: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function CreateConnection: IDBConnection;
    function CreateQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function CreateScopeTransaction(ATransaction: ITransaction): IScopeTransaction;
    function CreateSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
    function CreateTransaction(AConn: IDBConnection): ITransaction;
    function GetPool: IDBConnectionPool;
    function SqlLoader: TSQLLoader;
    function TestConnection(AConn: IDBConnection): Boolean;
    // Consumido uma vez pela próxima CreateQuery — usado pelos testes de
    // descarte por conexão quebrada (ver TFakeQuery.SetRaiseOnOpen).
    procedure RaiseOnNextQueryOpen(AExceptionClass: ExceptClass; const AMsg: string = 'fake error');
    // Consumido uma vez pela próxima CreateQuery — Open dessa query devolve
    // AResult (com sucesso) em vez de nil (ver TFakeQuery.SetOpenResult).
    procedure SetNextQueryOpenResult(AResult: IQueryResult);
    // Faz as próximas ACount chamadas a CreateConnection lançarem exceção
    // (simula Connect falhando por banco fora do ar).
    procedure SimulateCreateConnectionFail(ACount: Integer);
    property SimulateTestConnectionFail: Boolean
      read FSimulateTestConnectionFail write FSimulateTestConnectionFail;
    property TestedConnections: TList<IDBConnection> read FTestedConnections;
    // Última TFakeDBConnection criada por CreateConnection — testes usam pra
    // simular IsConnected caindo depois de uma falha (ver TFakeDBConnection.Connected).
    property LastCreatedConnection: TFakeDBConnection read FLastCreatedConnection;
  end;

  { TPoolStressThread
    Adquire e libera conexões do pool repetidamente para testar concorrência. }

  TPoolStressThread = class(TThread)
  private
    FPool: IDBConnectionPool;
    FIterations: Integer;
    FErrorOccurred: Boolean;
    FErrorMessage: string;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: IDBConnectionPool; AIterations: Integer);
    property ErrorOccurred: Boolean read FErrorOccurred;
    property ErrorMessage: string read FErrorMessage;
  end;

  { TPoolTests }

  TPoolTests = class(TTestCase)
  private
    procedure MaxConnectionsEstoura_Method;
  published
    procedure Test_Pool_InicioVazio;
    procedure Test_Pool_InicialConnections;
    procedure Test_Pool_MaxConnections_Estoura;
    procedure Test_Pool_AquireELibera;
    procedure Test_Pool_CriaNovaCon_QuandoVazio;
    procedure Test_Pool_AcquireQuery;
    procedure Test_Pool_AcquireQueries_MesmaTransacao;
    procedure Test_Pool_AcquireQueries_TransacoesDiferentes;
    procedure Test_Pool_SharedTransaction_RegistraComandos;
    procedure Test_Pool_TransacoesDiferentes_RegistraComandosSeparados;
    procedure Test_Pool_ConexaoInativa120s;
    procedure Test_Pool_ConexaoInativaFalha;
    procedure Test_Pool_Concorrencia;
    procedure Test_Pool_IdleTimeout_Desligado_NaoEvictaNada;
    procedure Test_Pool_IdleTimeout_EvictaSoOsMaisAntigos;
    procedure Test_Pool_IdleTimeout_RespeitaPiso_IniConnections;
    procedure Test_Pool_IdleTimeoutConfig_ValoresPadraoEValidacao;
    procedure Test_Pool_IdleSweep_DestroyNaoTrava;
    procedure Test_Pool_Concorrencia_ComIdleSweepAtivo;
    procedure Test_Pool_Evento_ConnectionCreated_DisparaAoCrescer;
    procedure Test_Pool_Evento_ConnectionDiscarded_TestConnectionFalha;
    procedure Test_Pool_Evento_AcquireTimeout_DisparaAntesDaExcecao;
    procedure Test_Pool_Evento_IdleSweepClosed_DisparaComContagem;
    procedure Test_Pool_ConexaoDescartada_ExcecaoExternal;
    procedure Test_Pool_ConexaoDescartada_IsConnectedFalseAposExcecao;
    procedure Test_Pool_ConexaoMantida_ExcecaoDeNegocio;
    procedure Test_Pool_ConexaoDescartada_ExcecaoDuranteLeituraDeCampo;
    procedure Test_EDatabaseUnavailableException_PreservaDetalheOriginal;
    procedure Test_Pool_InicialConnections_BancoForaDoAr_NaoLancaExcecao;
    procedure Test_Pool_InicialConnections_BancoForaDoAr_RecuperaNaProximaAcquire;
  end;

implementation

{ TPoolEventRecorder }

constructor TPoolEventRecorder.Create;
begin
  inherited Create;
  FEvents := TList<TPoolEvent>.Create;
end;

destructor TPoolEventRecorder.Destroy;
begin
  FEvents.Free;
  inherited;
end;

procedure TPoolEventRecorder.OnEvent(const AEvent: TPoolEvent);
begin
  FEvents.Add(AEvent);
end;

{ TFakeSleep }


procedure TFakeSleep.Sleep(milliseconds: Cardinal);
begin
end;

{ TFakeClock }

constructor TFakeClock.Create;
begin
  FTimes := TQueue<TDateTime>.Create;
  FDefaultTime := 0;
end;

destructor TFakeClock.Destroy;
begin
  FTimes.Free;
  inherited Destroy;
end;

function TFakeClock.Now: TDateTime;
begin
  if FTimes.Count > 0 then
    Result := FTimes.Dequeue
  else
    Result := FDefaultTime;
end;

function TFakeClock.Date: TDateTime;
begin
  Result := Trunc(Now);
end;

procedure TFakeClock.EnqueueTime(ADateTime: TDateTime);
begin
  FTimes.Enqueue(ADateTime);
end;

procedure TFakeClock.SetDefaultTime(ADateTime: TDateTime);
begin
  FDefaultTime := ADateTime;
end;

{ TFakeDBConnection }

constructor TFakeDBConnection.Create;
begin
  inherited Create;
  FConnected := True;
end;

procedure TFakeDBConnection.Commit;   begin end;
procedure TFakeDBConnection.Connect;  begin end;
procedure TFakeDBConnection.Disconnect(Force: Boolean); begin end;

function TFakeDBConnection.GetNativeConnection: TObject;
begin
  Result := nil;
end;

function TFakeDBConnection.GetSQLDialect: ISQLDialect;
begin
  Result := nil;
end;

function TFakeDBConnection.IsConnected: Boolean;
begin
  Result := FConnected;
end;

procedure TFakeDBConnection.Rollback; begin end;

{ TFakeQueryResult }

procedure TFakeQueryResult.SetRaiseOnAnyCall(AExceptionClass: ExceptClass; const AMsg: string);
begin
  FExceptionClass := AExceptionClass;
  FExceptionMsg := AMsg;
end;

procedure TFakeQueryResult.MaybeRaise;
begin
  if Assigned(FExceptionClass) then
    raise FExceptionClass.Create(FExceptionMsg);
end;

function TFakeQueryResult.GetAsBoolean(const AName: string): Boolean;
begin
  MaybeRaise;
  Result := False;
end;

function TFakeQueryResult.GetAsDateTime(const AName: string): TDateTime;
begin
  MaybeRaise;
  Result := 0;
end;

function TFakeQueryResult.GetAsInteger(const AName: string): Integer;
begin
  MaybeRaise;
  Result := 0;
end;

function TFakeQueryResult.GetAsInt64(const AName: string): Int64;
begin
  MaybeRaise;
  Result := 0;
end;

function TFakeQueryResult.GetAsString(const AName: string): string;
begin
  MaybeRaise;
  Result := '';
end;

function TFakeQueryResult.GetAsCurrency(const AName: string): Currency;
begin
  MaybeRaise;
  Result := 0;
end;

function TFakeQueryResult.GetNullableBoolean(const AName: string): INullBoolean;
begin
  MaybeRaise;
  Result := nil;
end;

function TFakeQueryResult.GetNullableDateTime(const AName: string): INullDateTime;
begin
  MaybeRaise;
  Result := nil;
end;

function TFakeQueryResult.GetNullableInteger(const AName: string): INullInteger;
begin
  MaybeRaise;
  Result := nil;
end;

function TFakeQueryResult.GetNullableInt64(const AName: string): INullInt64;
begin
  MaybeRaise;
  Result := nil;
end;

function TFakeQueryResult.GetNullableString(const AName: string): INullString;
begin
  MaybeRaise;
  Result := nil;
end;

function TFakeQueryResult.GetNullableCurrency(const AName: string): INullCurrency;
begin
  MaybeRaise;
  Result := nil;
end;

function TFakeQueryResult.IsEmpty: Boolean;
begin
  MaybeRaise;
  Result := True;
end;

function TFakeQueryResult.FieldCount: Integer;
begin
  MaybeRaise;
  Result := 0;
end;

function TFakeQueryResult.FieldValue(AIndex: Integer): Variant;
begin
  MaybeRaise;
  Result := Null;
end;

function TFakeQueryResult.RecordCount: Integer;
begin
  MaybeRaise;
  Result := 0;
end;

procedure TFakeQueryResult.Next;
begin
  MaybeRaise;
end;

function TFakeQueryResult.Eof: Boolean;
begin
  MaybeRaise;
  Result := True;
end;

{ TFakeTransaction }

constructor TFakeTransaction.Create(AConn: IDBConnection);
begin
  FConnection := AConn;
  FCommands := TStringList.Create;
  FCommitCount := 0;
  FRollbackCount := 0;
end;

destructor TFakeTransaction.Destroy;
begin
  FCommands.Free;
  inherited Destroy;
end;

procedure TFakeTransaction.StartTransaction; begin end;

procedure TFakeTransaction.Commit;
begin
  Inc(FCommitCount);
end;

procedure TFakeTransaction.Rollback;
begin
  Inc(FRollbackCount);
end;

function TFakeTransaction.InTransaction: Boolean;
begin
  Result := False;
end;

function TFakeTransaction.GetConnection: IDBConnection;
begin
  Result := FConnection;
end;

function TFakeTransaction.GetNativeTransaction: TObject;
begin
  Result := nil;
end;

procedure TFakeTransaction.ExecSql(const ASql: string);
begin
end;

function TFakeTransaction.GetCommands: TStringList;
begin
  Result := FCommands;
end;

function TFakeTransaction.GetCommitCount: Integer;
begin
  Result := FCommitCount;
end;

function TFakeTransaction.GetRollbackCount: Integer;
begin
  Result := FRollbackCount;
end;

{ TFakeScopeTransaction }

constructor TFakeScopeTransaction.Create(AOriginalTransaction: ITransaction);
begin
  FOriginalTransaction := AOriginalTransaction;
end;

procedure TFakeScopeTransaction.Commit;    begin end;
procedure TFakeScopeTransaction.Rollback;  begin end;
procedure TFakeScopeTransaction.StartTransaction; begin end;

function TFakeScopeTransaction.GetOriginalTransaction: ITransaction;
begin
  Result := FOriginalTransaction;
end;

function TFakeScopeTransaction.InTransaction: Boolean;
begin
  Result := False;
end;

function TFakeScopeTransaction.IsMain: Boolean;
begin
  Result := True;
end;

{ TFakeQuery }

constructor TFakeQuery.Create(AConn: IDBConnection; ATrans: ITransaction);
begin
  FConnection := AConn;
  FTransaction := ATrans;
end;

procedure TFakeQuery.Close; begin end;

procedure TFakeQuery.ExecSql;
var
  LTestable: ITestableTransaction;
begin
  if Assigned(FTransaction) and Supports(FTransaction, ITestableTransaction, LTestable) then
    LTestable.GetCommands.Add(FSql);
end;

function TFakeQuery.GetConnection: IDBConnection;
begin
  Result := FConnection;
end;

function TFakeQuery.GetParams: IParams;
begin
  Result := nil;
end;

function TFakeQuery.GetSql: string;
begin
  Result := FSql;
end;

function TFakeQuery.GetTransaction: ITransaction;
begin
  Result := FTransaction;
end;

function TFakeQuery.Open: IQueryResult;
begin
  if Assigned(FOpenExceptionClass) then
    raise FOpenExceptionClass.Create(FOpenExceptionMsg);
  Result := FOpenResult;
end;

procedure TFakeQuery.SetSql(const ASql: string);
begin
  FSql := ASql;
end;

procedure TFakeQuery.SetRaiseOnOpen(AExceptionClass: ExceptClass; const AMsg: string);
begin
  FOpenExceptionClass := AExceptionClass;
  FOpenExceptionMsg := AMsg;
end;

procedure TFakeQuery.SetOpenResult(AResult: IQueryResult);
begin
  FOpenResult := AResult;
end;

{ TDBFactoryMock }

constructor TDBFactoryMock.Create;
begin
  FSimulateTestConnectionFail := False;
  FTestedConnections := TList<IDBConnection>.Create;
end;

destructor TDBFactoryMock.Destroy;
begin
  FTestedConnections.Free;
  inherited Destroy;
end;

function TDBFactoryMock.CreateConnection: IDBConnection;
begin
  if FCreateConnectionFailuresRemaining > 0 then
  begin
    Dec(FCreateConnectionFailuresRemaining);
    raise Exception.Create('fake connect failure (banco fora do ar)');
  end;

  FLastCreatedConnection := TFakeDBConnection.Create;
  Result := FLastCreatedConnection;
end;

procedure TDBFactoryMock.SimulateCreateConnectionFail(ACount: Integer);
begin
  FCreateConnectionFailuresRemaining := ACount;
end;

function TDBFactoryMock.CreateQuery(AConn: IDBConnection;
  ATransaction: ITransaction): IQuery;
var
  LQuery: TFakeQuery;
begin
  LQuery := TFakeQuery.Create(AConn, ATransaction);
  if Assigned(FNextQueryOpenExceptionClass) then
  begin
    LQuery.SetRaiseOnOpen(FNextQueryOpenExceptionClass, FNextQueryOpenExceptionMsg);
    FNextQueryOpenExceptionClass := nil;
  end;
  if Assigned(FNextQueryOpenResult) then
  begin
    LQuery.SetOpenResult(FNextQueryOpenResult);
    FNextQueryOpenResult := nil;
  end;
  Result := LQuery;
end;

procedure TDBFactoryMock.RaiseOnNextQueryOpen(AExceptionClass: ExceptClass; const AMsg: string);
begin
  FNextQueryOpenExceptionClass := AExceptionClass;
  FNextQueryOpenExceptionMsg := AMsg;
end;

procedure TDBFactoryMock.SetNextQueryOpenResult(AResult: IQueryResult);
begin
  FNextQueryOpenResult := AResult;
end;

function TDBFactoryMock.CreateScopeTransaction(
  ATransaction: ITransaction): IScopeTransaction;
begin
  Result := TFakeScopeTransaction.Create(ATransaction);
end;

function TDBFactoryMock.CreateSqlScript(AConn: IDBConnection;
  ATransaction: ITransaction): ISqlScript;
begin
  Result := nil;
end;

function TDBFactoryMock.CreateTransaction(AConn: IDBConnection): ITransaction;
begin
  Result := TFakeTransaction.Create(AConn);
end;

function TDBFactoryMock.GetPool: IDBConnectionPool;
begin
  Result := nil;
end;

function TDBFactoryMock.SqlLoader: TSQLLoader;
begin
  Result := nil;
end;

function TDBFactoryMock.TestConnection(AConn: IDBConnection): Boolean;
begin
  FTestedConnections.Add(AConn);
  Result := not FSimulateTestConnectionFail;
end;

{ TPoolTests }

procedure TPoolTests.MaxConnectionsEstoura_Method;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: TConnectionPool;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.MaxConnections := 3;
  LConfig.IniConnections := 5;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);
  try
  finally
    LPool.Free;
  end;
end;

procedure TPoolTests.Test_Pool_InicioVazio;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 0;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  TAssert.AssertEquals('Pool vazio: GetPoolSize deve ser 0 quando IniConnections = 0', 0, LPool.GetPoolSize);
end;

procedure TPoolTests.Test_Pool_InicialConnections;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 5;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  TAssert.AssertEquals('Pool deve ter 5 conexões iniciais', 5, LPool.GetPoolSize);
end;

procedure TPoolTests.Test_Pool_InicialConnections_BancoForaDoAr_NaoLancaExcecao;
var
  LConfig: IConnectionPoolConfig;
  LMockFactory: TDBFactoryMock;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
  I: Integer;
begin
  // Simula TFDFactory.Create com o banco inteiramente fora do ar: as 3
  // tentativas do ramp-up inicial falham. O construtor do pool não pode
  // deixar a exceção subir (ver CreateInitialConnections) — é exatamente
  // isso que garante que TFDFactory.Create/ConfigurarBancoXxx não derrube o
  // boot da aplicação inteira.
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 3;
  LConfig.MaxConnections := 10;

  LMockFactory := TDBFactoryMock.Create;
  LMockFactory.SimulateCreateConnectionFail(3);
  LFactory := LMockFactory;

  LRecorder := TPoolEventRecorder.Create;

  LEvents := LRecorder.Events;
  try
    LPool := TConnectionPool.Create(LFactory, LConfig,
      LRecorder.OnEvent);

    TAssert.AssertEquals('Nenhuma conexão deve sobreviver ao ramp-up com o banco fora do ar', 0, LPool.GetPoolSize);
    TAssert.AssertEquals('FActiveConnections deve voltar a 0 após cada falha (sem vazamento de contagem)', 0, LPool.GetActiveConnections);

    TAssert.AssertEquals('Cada falha do ramp-up inicial deve gerar 1 evento pekConnectionDiscarded', 3, LEvents.Count);
    for I := 0 to LEvents.Count - 1 do
    begin
      TAssert.AssertEquals(Ord(pekConnectionDiscarded), Ord(LEvents[I].Kind));
      TAssert.AssertEquals(Ord(pdrConnectFailed), Ord(LEvents[I].DiscardReason));
    end;

    TAssert.AssertEquals(Int64(0), LPool.GetSnapshot.TotalCreated);
    TAssert.AssertEquals(Int64(3), LPool.GetSnapshot.TotalDiscarded);
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_InicialConnections_BancoForaDoAr_RecuperaNaProximaAcquire;
var
  LConfig: IConnectionPoolConfig;
  LMockFactory: TDBFactoryMock;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LConn: IDBConnection;
begin
  // Banco volta a responder logo depois do boot: o ramp-up inicial falha
  // (2 tentativas), mas a próxima AcquireConnection real (1ª requisição/health
  // check) já não tem mais falha simulada e deve suceder normalmente.
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 2;
  LConfig.MaxConnections := 10;

  LMockFactory := TDBFactoryMock.Create;
  LMockFactory.SimulateCreateConnectionFail(2);
  LFactory := LMockFactory;

  LPool := TConnectionPool.Create(LFactory, LConfig);

  TAssert.AssertEquals('Ramp-up inicial falhou por completo — pool nasce vazio, não quebrado', 0, LPool.GetActiveConnections);

  LConn := LPool.AcquireConnection;

  TAssert.AssertTrue('Banco já respondendo: AcquireConnection deve suceder normalmente', Assigned(LConn));
  TAssert.AssertEquals(1, LPool.GetActiveConnections);
  TAssert.AssertEquals(Int64(1), LPool.GetSnapshot.TotalCreated);
end;

procedure TPoolTests.Test_Pool_MaxConnections_Estoura;
var
  LRaised: Boolean;
begin
  TSleep.SetSleep(TFakeSleep.Create);
  try
    LRaised := False;
    try
      MaxConnectionsEstoura_Method;
    except
      on E: EPoolTimeoutException do
        LRaised := True;
    end;
    TAssert.AssertTrue('Deve lançar EPoolTimeoutException quando IniConnections > MaxConnections', LRaised);
  finally
    TSleep.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_AquireELibera;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LConn1, LConn2: IDBConnection;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 3;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  TAssert.AssertEquals('1. Pool deve ter 3 conexões', 3, LPool.GetPoolSize);

  LConn1 := LPool.AcquireConnection;
  TAssert.AssertEquals('2. Pool deve ter 2 conexões após 1 acquire', 2, LPool.GetPoolSize);

  LConn2 := LPool.AcquireConnection;
  TAssert.AssertEquals('3. Pool deve ter 1 conexão após 2 acquires', 1, LPool.GetPoolSize);

  LConn2 := nil;
  TAssert.AssertEquals('4. Pool deve ter 2 conexões após release de LConn2', 2, LPool.GetPoolSize);

  LConn1 := nil;
  TAssert.AssertEquals('5. Pool deve ter 3 conexões após release de LConn1', 3, LPool.GetPoolSize);
end;

procedure TPoolTests.Test_Pool_CriaNovaCon_QuandoVazio;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LConn: IDBConnection;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 0;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  TAssert.AssertEquals('1. Pool deve ter 0 conexões ociosas', 0, LPool.GetPoolSize);
  TAssert.AssertEquals('2. Pool deve ter 0 conexões ativas', 0, LPool.GetActiveConnections);

  LConn := LPool.AcquireConnection;

  TAssert.AssertEquals('3. Pool ainda deve ter 0 conexões ociosas', 0, LPool.GetPoolSize);
  TAssert.AssertEquals('4. Pool deve ter 1 conexão ativa', 1, LPool.GetActiveConnections);

  TAssert.AssertTrue('Conexão não deve ser nil', Assigned(LConn));
end;

procedure TPoolTests.Test_Pool_AcquireQuery;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 0;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  LQuery := nil;
  LScope := LPool.AcquireQuery(LQuery);

  TAssert.AssertTrue('Query não deve ser nil', Assigned(LQuery));
  TAssert.AssertTrue('IScopeTransaction não deve ser nil', Assigned(LScope));
end;

procedure TPoolTests.Test_Pool_AcquireQueries_MesmaTransacao;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LQuery1, LQuery2: IQuery;
  LScope1, LScope2: IScopeTransaction;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 0;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  LQuery1 := nil;
  LScope1 := LPool.AcquireQuery(LQuery1);
  LScope2 := LPool.AcquireQuery(LQuery2, LScope1.GetOriginalTransaction);

  TAssert.AssertTrue('Query1 não deve ser nil', Assigned(LQuery1));
  TAssert.AssertTrue('Query2 não deve ser nil', Assigned(LQuery2));
  TAssert.AssertTrue('As transações das duas queries devem ser a mesma instância', LScope1.GetOriginalTransaction = LScope2.GetOriginalTransaction);
end;

procedure TPoolTests.Test_Pool_AcquireQueries_TransacoesDiferentes;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LQuery1, LQuery2: IQuery;
  LScope1, LScope2: IScopeTransaction;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 0;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  LQuery1 := nil;
  LScope1 := LPool.AcquireQuery(LQuery1);
  LScope2 := LPool.AcquireQuery(LQuery2);

  TAssert.AssertTrue('Query1 não deve ser nil', Assigned(LQuery1));
  TAssert.AssertTrue('Query2 não deve ser nil', Assigned(LQuery2));
  TAssert.AssertTrue('Scope1 não deve ser nil', Assigned(LScope1));
  TAssert.AssertTrue('Scope2 não deve ser nil', Assigned(LScope2));
  TAssert.AssertTrue('As transações das duas queries devem ser instâncias diferentes', LScope1.GetOriginalTransaction <> LScope2.GetOriginalTransaction);
end;

procedure TPoolTests.Test_Pool_SharedTransaction_RegistraComandos;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LQuery1, LQuery2: IQuery;
  LScope: IScopeTransaction;
  LTestable: ITestableTransaction;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 0;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  LScope := LPool.AcquireQuery(LQuery1);
  LPool.AcquireQuery(LQuery2, LScope.GetOriginalTransaction);

  LQuery1.SetSql('CMD1');
  LQuery1.ExecSql;
  LQuery2.SetSql('CMD2');
  LQuery2.ExecSql;

  TAssert.AssertTrue('Transação deve implementar ITestableTransaction', Supports(LScope.GetOriginalTransaction, ITestableTransaction, LTestable));
  TAssert.AssertEquals('Ambos os comandos devem estar registrados na mesma transação compartilhada', 2, LTestable.GetCommands.Count);
end;

procedure TPoolTests.Test_Pool_TransacoesDiferentes_RegistraComandosSeparados;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LQuery1, LQuery2: IQuery;
  LScope1, LScope2: IScopeTransaction;
  LTestable1, LTestable2: ITestableTransaction;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 0;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  LScope1 := LPool.AcquireQuery(LQuery1);
  LScope2 := LPool.AcquireQuery(LQuery2);

  LQuery1.SetSql('CMD1');
  LQuery1.ExecSql;

  LQuery2.SetSql('CMD2');
  LQuery2.ExecSql;
  LQuery2.SetSql('CMD3');
  LQuery2.ExecSql;

  Supports(LScope1.GetOriginalTransaction, ITestableTransaction, LTestable1);
  Supports(LScope2.GetOriginalTransaction, ITestableTransaction, LTestable2);

  TAssert.AssertEquals('Transação 1 deve ter somente 1 comando', 1, LTestable1.GetCommands.Count);
  TAssert.AssertEquals('Transação 2 deve ter 2 comandos', 2, LTestable2.GetCommands.Count);
end;

procedure TPoolTests.Test_Pool_ConexaoInativa120s;

  procedure TestarSegundos(const AMensagem: string; ASegundos: Integer;
    ATestedCountEsperado: Integer);
  var
    LConfig: IConnectionPoolConfig;
    LFactory: IDBFactory;
    LMockFactory: TDBFactoryMock;
    LPool: IDBConnectionPool;
    LConn: IDBConnection;
    LClock: TFakeClock;
    BaseTime: TDateTime;
  begin
    BaseTime := StrToDateTime('28/12/2025 11:44:18');

    LClock := TFakeClock.Create;
    LClock.SetDefaultTime(BaseTime);
    LClock.EnqueueTime(BaseTime);                                // liberação em CreateInitialConnections
    LClock.EnqueueTime(BaseTime + (ASegundos / 86400));          // verificação em AcquireConnection

    TClock.SetClock(LClock);
    try
      LConfig := TConnectionPoolConfig.Create;
      LConfig.IniConnections := 1;
      LConfig.MaxConnections := 10;

      LMockFactory := TDBFactoryMock.Create;
      LFactory := LMockFactory;
      LPool := TConnectionPool.Create(LFactory, LConfig);

      TAssert.AssertEquals('Antes do acquire não deve haver conexões testadas', 0, LMockFactory.TestedConnections.Count);

      LConn := LPool.AcquireConnection;

      TAssert.AssertEquals(AMensagem, ATestedCountEsperado, LMockFactory.TestedConnections.Count);
    finally
      TClock.Reset;
    end;
  end;

begin
  TestarSegundos('Com 120s: deve testar a conexão (Count=1)',  120, 1);
  TestarSegundos('Com 119s: não deve testar (Count=0)',        119, 0);
  TestarSegundos('Com 1s: não deve testar (Count=0)',            1, 0);
  TestarSegundos('Com 5280s: deve testar a conexão (Count=1)', 5280, 1);
end;

procedure TPoolTests.Test_Pool_ConexaoInativaFalha;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LMockFactory: TDBFactoryMock;
  LPool: IDBConnectionPool;
  LConn: IDBConnection;
  LClock: TFakeClock;
  BaseTime: TDateTime;
begin
  BaseTime := StrToDateTime('28/12/2025 11:44:18');

  LClock := TFakeClock.Create;
  LClock.SetDefaultTime(BaseTime);
  // Liberações durante CreateInitialConnections (2 conexões, em ordem de índice)
  LClock.EnqueueTime(BaseTime);                      // LastRelease conn1
  LClock.EnqueueTime(BaseTime + (50 / 86400));       // LastRelease conn2
  // Verificações em AcquireConnection
  LClock.EnqueueTime(BaseTime + (121 / 86400));      // 121s p/ conn1 → testa → falha → remove
  LClock.EnqueueTime(BaseTime + (130 / 86400));      // 80s p/ conn2 → não testa → usa

  TClock.SetClock(LClock);
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 2;
    LConfig.MaxConnections := 10;

    LMockFactory := TDBFactoryMock.Create;
    LFactory := LMockFactory;
    LPool := TConnectionPool.Create(LFactory, LConfig);

    TAssert.AssertEquals('Pool deve ter 2 conexões ativas após inicialização', 2, LPool.GetActiveConnections);

    LMockFactory.SimulateTestConnectionFail := True;

    LConn := LPool.AcquireConnection;

    TAssert.AssertEquals('Após remover a conexão falha, deve restar 1 conexão ativa', 1, LPool.GetActiveConnections);

    TAssert.AssertTrue('Deve retornar a segunda conexão (saudável)', Assigned(LConn));
  finally
    TClock.Reset;
  end;
end;

{ TPoolStressThread }

constructor TPoolStressThread.Create(APool: IDBConnectionPool; AIterations: Integer);
begin
  inherited Create(True); // suspenso — aguarda chamada explícita de Start
  FPool := APool;
  FIterations := AIterations;
  FreeOnTerminate := False;
  FErrorOccurred := False;
end;

procedure TPoolStressThread.Execute;
var
  I: Integer;
  LConn: IDBConnection;
begin
  try
    for I := 1 to FIterations do
    begin
      LConn := FPool.AcquireConnection;
      LConn := nil; // libera imediatamente → devolve ao pool
    end;
  except
    on E: Exception do
    begin
      FErrorOccurred := True;
      FErrorMessage := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

procedure TPoolTests.Test_Pool_Concorrencia;
const
  NUM_THREADS = 20;
  ITERACOES   = 50;
  MAX_CONNS   = 5;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LThreads: array[1..NUM_THREADS] of TPoolStressThread;
  I: Integer;
begin
  // TFakeSleep evita espera real: threads em contenção reentram imediatamente
  TSleep.SetSleep(TFakeSleep.Create);
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections  := 0;
    LConfig.MaxConnections  := MAX_CONNS;
    LConfig.WaitMaxAttemps  := 2000; // suficiente para 20 threads × 50 iterações
    LConfig.WaitMilliseconds := 0;

    LFactory := TDBFactoryMock.Create;
    LPool := TConnectionPool.Create(LFactory, LConfig);

    // Cria todas as threads suspensas
    for I := 1 to NUM_THREADS do
      LThreads[I] := TPoolStressThread.Create(LPool, ITERACOES);

    // Dispara todas de uma vez para forçar concorrência real
    for I := 1 to NUM_THREADS do
      LThreads[I].Start;

    // Aguarda cada thread e verifica que não gerou erro
    for I := 1 to NUM_THREADS do
    begin
      LThreads[I].WaitFor;
      TAssert.AssertFalse(Format('Thread %d reportou erro: %s', [I, LThreads[I].ErrorMessage]), LThreads[I].ErrorOccurred);
      LThreads[I].Free;
    end;

    // Após todas as threads terminarem, nenhuma conexão deve estar em uso:
    // GetPoolSize (ociosas) deve igualar GetActiveConnections (total físico criado)
    TAssert.AssertEquals('Todas as conexões físicas devem ter voltado ao pool — nenhum vazamento', LPool.GetActiveConnections, LPool.GetPoolSize);

    TAssert.AssertTrue('O pool nunca deve ter criado mais conexões do que o limite máximo', LPool.GetActiveConnections <= MAX_CONNS);
  finally
    TSleep.Reset;
  end;
end;

{ TPoolTests — idle timeout }

procedure TPoolTests.Test_Pool_IdleTimeout_Desligado_NaoEvictaNada;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  // LPoolIntf segura a referência contada do início ao fim (mesmo padrão dos
  // testes originais, ex. Test_Pool_AquireELibera) — sem isso, os ciclos de
  // Acquire/libera abaixo derrubam a contagem de TConnectionPool a zero no
  // meio do teste e o _Release automático do TInterfacedObject destrói o
  // pool ali mesmo; o LPool.Free explícito no final vira free duplo.
  // LPool é só uma "view" da classe concreta, pra chamar SweepIdleConnections
  // (que não faz parte de IDBConnectionPool) — nunca dar Free nela.
  LPoolIntf: IDBConnectionPool;
  LPool: TConnectionPool;
  LClock: TFakeClock;
  LConn1, LConn2: IDBConnection;
  BaseTime: TDateTime;
begin
  BaseTime := StrToDateTime('28/12/2025 11:44:18');
  LClock := TFakeClock.Create;
  LClock.SetDefaultTime(BaseTime);
  TClock.SetClock(LClock);
  try
    // IdleTimeoutSeconds não configurado -> fica 0 = desligado (padrão)
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 0;
    LConfig.MaxConnections := 10;

    LFactory := TDBFactoryMock.Create;
    LPoolIntf := TConnectionPool.Create(LFactory, LConfig);
    LPool := LPoolIntf as TConnectionPool;

    LConn1 := LPoolIntf.AcquireConnection;
    LConn2 := LPoolIntf.AcquireConnection;
    LConn1 := nil;
    LConn2 := nil; // 2 conexões ociosas no pool

    TAssert.AssertEquals('Pré-condição: 2 conexões ociosas', 2, LPoolIntf.GetPoolSize);

    LClock.SetDefaultTime(BaseTime + (100000 / 86400)); // bem além de qualquer limite razoável
    LPool.SweepIdleConnections;

    TAssert.AssertEquals('IdleTimeoutSeconds=0 (padrão): SweepIdleConnections não deve remover nada', 2, LPoolIntf.GetPoolSize);
    TAssert.AssertEquals('IdleTimeoutSeconds=0 (padrão): contagem de ativas não deve mudar', 2, LPoolIntf.GetActiveConnections);
  finally
    TClock.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_IdleTimeout_EvictaSoOsMaisAntigos;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPoolIntf: IDBConnectionPool; // ver comentário em Test_Pool_IdleTimeout_Desligado_NaoEvictaNada
  LPool: TConnectionPool;
  LClock: TFakeClock;
  LConn1, LConn2, LConn3: IDBConnection;
  BaseTime: TDateTime;
begin
  BaseTime := StrToDateTime('28/12/2025 11:44:18');
  LClock := TFakeClock.Create;
  LClock.SetDefaultTime(BaseTime);
  TClock.SetClock(LClock);
  try
    // IdleTimeoutSeconds fica 0 (padrão) de propósito: assim NENHUMA thread
    // de varredura é criada — o teste chama SweepIdleConnections(60)
    // diretamente, na thread do próprio teste, com TFakeClock. Determinístico,
    // sem concorrência nenhuma envolvida.
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 0;
    LConfig.MaxConnections := 10;

    LFactory := TDBFactoryMock.Create;
    LPoolIntf := TConnectionPool.Create(LFactory, LConfig);
    LPool := LPoolIntf as TConnectionPool;

    LConn1 := LPoolIntf.AcquireConnection;
    LConn2 := LPoolIntf.AcquireConnection;
    LConn3 := LPoolIntf.AcquireConnection;
    TAssert.AssertEquals('Pré-condição: 3 conexões ativas', 3, LPoolIntf.GetActiveConnections);

    LClock.SetDefaultTime(BaseTime);
    LConn1 := nil; // LastRelease = T0        (65s de idade no sweep abaixo)
    LClock.SetDefaultTime(BaseTime + (10 / 86400));
    LConn2 := nil; // LastRelease = T0+10s     (55s de idade — NÃO deve sair)
    LClock.SetDefaultTime(BaseTime + (20 / 86400));
    LConn3 := nil; // LastRelease = T0+20s     (45s de idade — NÃO deve sair)

    TAssert.AssertEquals('Pré-condição: 3 conexões ociosas no pool', 3, LPoolIntf.GetPoolSize);

    LClock.SetDefaultTime(BaseTime + (65 / 86400)); // "agora" = T0+65s
    LPool.SweepIdleConnections(60);

    TAssert.AssertEquals('Só a conexão liberada em T0 (65s de idade, >=60) deve ser removida', 2, LPoolIntf.GetPoolSize);
    TAssert.AssertEquals('FActiveConnections deve acompanhar a remoção', 2, LPoolIntf.GetActiveConnections);
  finally
    TClock.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_IdleTimeout_RespeitaPiso_IniConnections;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPoolIntf: IDBConnectionPool; // ver comentário em Test_Pool_IdleTimeout_Desligado_NaoEvictaNada
  LPool: TConnectionPool;
  LClock: TFakeClock;
  LConn1, LConn2, LConn3: IDBConnection;
  BaseTime: TDateTime;
begin
  BaseTime := StrToDateTime('28/12/2025 11:44:18');
  LClock := TFakeClock.Create;
  LClock.SetDefaultTime(BaseTime);
  TClock.SetClock(LClock);
  try
    // IdleTimeoutSeconds fica 0 (padrão) de propósito — ver comentário no
    // teste Test_Pool_IdleTimeout_EvictaSoOsMaisAntigos.
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 2; // piso: nunca evictar abaixo disso
    LConfig.MaxConnections := 10;

    LFactory := TDBFactoryMock.Create;
    LPoolIntf := TConnectionPool.Create(LFactory, LConfig);
    LPool := LPoolIntf as TConnectionPool;

    // CreateInitialConnections já deixou 2 ociosas (LastRelease = BaseTime).
    // Esvazia as 2 (reuso) e força a criação de uma 3ª nova, depois libera
    // as 3 — pra ter 3 conexões ociosas de verdade, todas velhas o bastante.
    LConn1 := LPoolIntf.AcquireConnection; // reusa uma das 2 do pool
    LConn2 := LPoolIntf.AcquireConnection; // reusa a outra
    LConn3 := LPoolIntf.AcquireConnection; // pool vazio agora -> cria nova (3ª física)
    LConn1 := nil;
    LConn2 := nil;
    LConn3 := nil;
    TAssert.AssertEquals('Pré-condição: 3 conexões ociosas', 3, LPoolIntf.GetPoolSize);

    // Todas MUITO além do limite de 60s — sem piso, evictaria tudo.
    LClock.SetDefaultTime(BaseTime + (100000 / 86400));
    LPool.SweepIdleConnections(60);

    TAssert.AssertEquals('Nunca deve evictar abaixo de IniConnections, mesmo com todas idosas', 2, LPoolIntf.GetPoolSize);
    TAssert.AssertEquals('FActiveConnections deve parar no piso também', 2, LPoolIntf.GetActiveConnections);
  finally
    TClock.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_IdleTimeoutConfig_ValoresPadraoEValidacao;
var
  LConfig: IConnectionPoolConfig;
begin
  LConfig := TConnectionPoolConfig.Create;

  TAssert.AssertEquals('Padrão de IdleTimeoutSeconds deve ser 0 (desligado)', 0, LConfig.IdleTimeoutSeconds);
  TAssert.AssertEquals('Padrão de IdleCheckIntervalMs deve ser 30000ms', 30000, LConfig.IdleCheckIntervalMs);

  LConfig.IdleCheckIntervalMs := 0;
  TAssert.AssertEquals('IdleCheckIntervalMs <= 0 deve ser ignorado (mantém o padrão)', 30000, LConfig.IdleCheckIntervalMs);

  LConfig.IdleCheckIntervalMs := -5;
  TAssert.AssertEquals('IdleCheckIntervalMs negativo deve ser ignorado', 30000, LConfig.IdleCheckIntervalMs);

  LConfig.IdleCheckIntervalMs := 5000;
  TAssert.AssertEquals('IdleCheckIntervalMs válido deve ser aceito', 5000, LConfig.IdleCheckIntervalMs);

  LConfig.IdleTimeoutSeconds := -1;
  TAssert.AssertEquals('IdleTimeoutSeconds negativo deve ser ignorado', 0, LConfig.IdleTimeoutSeconds);

  LConfig.IdleTimeoutSeconds := 45;
  TAssert.AssertEquals('IdleTimeoutSeconds válido (>=0) deve ser aceito', 45, LConfig.IdleTimeoutSeconds);
end;

procedure TPoolTests.Test_Pool_IdleSweep_DestroyNaoTrava;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: TConnectionPool;
  LStart, LElapsed: UInt64;
begin
  // Sem TFakeClock/TFakeSleep aqui de propósito: quer a thread de varredura
  // REAL rodando, pra provar que Destroy não trava nem AV mesmo com ela viva.
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 1;
  LConfig.MaxConnections := 10;
  LConfig.IdleTimeoutSeconds := 1;
  LConfig.IdleCheckIntervalMs := 5000; // não importa: SetEvent acorda na hora, não espera isso

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  LStart := PdbTickMs;
  LPool.Free;
  LElapsed := PdbTickMs - LStart;

  TAssert.AssertTrue(Format('Destroy com sweep ativo deveria ser quase instantâneo (SetEvent), levou %dms',
      [LElapsed]), LElapsed < 2000);
end;

procedure TPoolTests.Test_Pool_Concorrencia_ComIdleSweepAtivo;
const
  NUM_THREADS = 20;
  ITERACOES   = 50;
  MAX_CONNS   = 5;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LThreads: array[1..NUM_THREADS] of TPoolStressThread;
  I: Integer;
begin
  // Igual Test_Pool_Concorrencia, mas com a thread de varredura REAL ativa e
  // rodando em paralelo (intervalo curto) — cobre o lock entre
  // Acquire/Release concorrentes e SweepIdleConnections ao mesmo tempo.
  TSleep.SetSleep(TFakeSleep.Create);
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections  := 0;
    LConfig.MaxConnections  := MAX_CONNS;
    LConfig.WaitMaxAttemps  := 2000;
    LConfig.WaitMilliseconds := 0;
    LConfig.IdleTimeoutSeconds := 1;
    LConfig.IdleCheckIntervalMs := 5;

    LFactory := TDBFactoryMock.Create;
    LPool := TConnectionPool.Create(LFactory, LConfig);

    for I := 1 to NUM_THREADS do
      LThreads[I] := TPoolStressThread.Create(LPool, ITERACOES);

    for I := 1 to NUM_THREADS do
      LThreads[I].Start;

    for I := 1 to NUM_THREADS do
    begin
      LThreads[I].WaitFor;
      TAssert.AssertFalse(Format('Thread %d reportou erro: %s', [I, LThreads[I].ErrorMessage]), LThreads[I].ErrorOccurred);
      LThreads[I].Free;
    end;

    TAssert.AssertEquals('Mesmo com sweep concorrente, toda conexão física deve estar ou ativa ou no pool — sem vazamento', LPool.GetActiveConnections, LPool.GetPoolSize);
    TAssert.AssertTrue('O pool nunca deve ter criado mais conexões do que o limite máximo', LPool.GetActiveConnections <= MAX_CONNS);
  finally
    TSleep.Reset;
  end;
end;

{ TPoolTests — eventos e snapshot }

procedure TPoolTests.Test_Pool_Evento_ConnectionCreated_DisparaAoCrescer;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
  LConn: IDBConnection;
begin
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 0;
  LConfig.MaxConnections := 10;

  LFactory := TDBFactoryMock.Create;
  LRecorder := TPoolEventRecorder.Create;
  LEvents := LRecorder.Events;
  try
    LPool := TConnectionPool.Create(LFactory, LConfig,
      LRecorder.OnEvent);

    TAssert.AssertEquals('Sem IniConnections, a construção do pool não deve disparar eventos', 0, LEvents.Count);

    LConn := LPool.AcquireConnection;

    TAssert.AssertEquals('Criar 1 conexão física deve disparar exatamente 1 evento pekConnectionCreated', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekConnectionCreated), Ord(LEvents[0].Kind));
    TAssert.AssertEquals(1, LEvents[0].ActiveConnections);
    TAssert.AssertEquals(10, LEvents[0].MaxConnections);

    TAssert.AssertEquals(Int64(1), LPool.GetSnapshot.TotalCreated);
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_Evento_ConnectionDiscarded_TestConnectionFalha;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LMockFactory: TDBFactoryMock;
  LPool: IDBConnectionPool;
  LConn: IDBConnection;
  LClock: TFakeClock;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
  BaseTime: TDateTime;
begin
  // Mesmo cenário de Test_Pool_ConexaoInativaFalha: 2 conexões no ramp-up,
  // a 1ª falha no teste de vivacidade (>=120s ociosa) e é descartada, a 2ª
  // é reaproveitada.
  BaseTime := StrToDateTime('28/12/2025 11:44:18');

  LClock := TFakeClock.Create;
  LClock.SetDefaultTime(BaseTime);
  LClock.EnqueueTime(BaseTime);                      // LastRelease conn1
  LClock.EnqueueTime(BaseTime + (50 / 86400));       // LastRelease conn2
  LClock.EnqueueTime(BaseTime + (121 / 86400));      // 121s p/ conn1 → testa → falha → remove
  LClock.EnqueueTime(BaseTime + (130 / 86400));      // 80s p/ conn2 → não testa → usa

  TClock.SetClock(LClock);
  LRecorder := TPoolEventRecorder.Create;
  LEvents := LRecorder.Events;
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 2;
    LConfig.MaxConnections := 10;

    LMockFactory := TDBFactoryMock.Create;
    LFactory := LMockFactory;
    LPool := TConnectionPool.Create(LFactory, LConfig,
      LRecorder.OnEvent);

    LEvents.Clear; // descarta os 2 pekConnectionCreated do ramp-up inicial

    LMockFactory.SimulateTestConnectionFail := True;
    LConn := LPool.AcquireConnection;

    TAssert.AssertEquals('O descarte da conexão morta deve disparar exatamente 1 evento pekConnectionDiscarded', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekConnectionDiscarded), Ord(LEvents[0].Kind));
    TAssert.AssertEquals(Ord(pdrStaleCheckFailed), Ord(LEvents[0].DiscardReason));
    TAssert.AssertEquals('Após o descarte, ActiveConnections deve refletir só a conexão restante', 1, LEvents[0].ActiveConnections);

    TAssert.AssertEquals(Int64(2), LPool.GetSnapshot.TotalCreated);
    TAssert.AssertEquals(Int64(1), LPool.GetSnapshot.TotalDiscarded);
  finally
    TClock.Reset;
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_Evento_AcquireTimeout_DisparaAntesDaExcecao;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
  LEvent: TPoolEvent;
  LRaised: Boolean;
  LTimeoutCount: Integer;
begin
  // Mesmo cenário de Test_Pool_MaxConnections_Estoura: IniConnections (5) >
  // MaxConnections (3) força o ramp-up a estourar EPoolTimeoutException.
  LConfig := TConnectionPoolConfig.Create;
  LConfig.MaxConnections := 3;
  LConfig.IniConnections := 5;

  LFactory := TDBFactoryMock.Create;
  LRecorder := TPoolEventRecorder.Create;
  LEvents := LRecorder.Events;
  TSleep.SetSleep(TFakeSleep.Create);
  try
    LRaised := False;
    try
      TConnectionPool.Create(LFactory, LConfig,
        LRecorder.OnEvent).Free;
    except
      on E: EPoolTimeoutException do
        LRaised := True;
    end;

    TAssert.AssertTrue('Deveria ter lançado EPoolTimeoutException', LRaised);

    LTimeoutCount := 0;
    for LEvent in LEvents do
      if LEvent.Kind = pekAcquireTimeout then
        Inc(LTimeoutCount);

    TAssert.AssertEquals('Deve disparar exatamente 1 evento pekAcquireTimeout, logo antes da exceção', 1, LTimeoutCount);
  finally
    TSleep.Reset;
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_Evento_IdleSweepClosed_DisparaComContagem;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPoolIntf: IDBConnectionPool; // ver comentário em Test_Pool_IdleTimeout_Desligado_NaoEvictaNada
  LPool: TConnectionPool;
  LClock: TFakeClock;
  LConn1, LConn2, LConn3: IDBConnection;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
  BaseTime: TDateTime;
begin
  // Mesmo cenário de Test_Pool_IdleTimeout_EvictaSoOsMaisAntigos: só a
  // conexão liberada há mais tempo deve ser fechada pela varredura.
  BaseTime := StrToDateTime('28/12/2025 11:44:18');
  LClock := TFakeClock.Create;
  LClock.SetDefaultTime(BaseTime);
  TClock.SetClock(LClock);
  LRecorder := TPoolEventRecorder.Create;
  LEvents := LRecorder.Events;
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 0;
    LConfig.MaxConnections := 10;

    LFactory := TDBFactoryMock.Create;
    LPoolIntf := TConnectionPool.Create(LFactory, LConfig,
      LRecorder.OnEvent);
    LPool := LPoolIntf as TConnectionPool;

    LConn1 := LPoolIntf.AcquireConnection;
    LConn2 := LPoolIntf.AcquireConnection;
    LConn3 := LPoolIntf.AcquireConnection;

    LClock.SetDefaultTime(BaseTime);
    LConn1 := nil; // LastRelease = T0        (65s de idade no sweep abaixo)
    LClock.SetDefaultTime(BaseTime + (10 / 86400));
    LConn2 := nil; // LastRelease = T0+10s     (55s de idade — NÃO deve sair)
    LClock.SetDefaultTime(BaseTime + (20 / 86400));
    LConn3 := nil; // LastRelease = T0+20s     (45s de idade — NÃO deve sair)

    LEvents.Clear; // descarta os 3 pekConnectionCreated do crescimento acima

    LClock.SetDefaultTime(BaseTime + (65 / 86400)); // "agora" = T0+65s
    LPool.SweepIdleConnections(60);

    TAssert.AssertEquals('Uma varredura que fecha conexões deve disparar exatamente 1 evento pekIdleSweepClosed', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekIdleSweepClosed), Ord(LEvents[0].Kind));
    TAssert.AssertEquals('Só a conexão mais antiga (65s de idade, >=60) deve ter sido fechada', 1, LEvents[0].ClosedCount);

    TAssert.AssertEquals(Int64(1), LPoolIntf.GetSnapshot.TotalIdleSwept);
  finally
    TClock.Reset;
    LRecorder.Free;
  end;
end;

{ TPoolTests — descarte de conexão quebrada durante o uso }

procedure TPoolTests.Test_Pool_ConexaoDescartada_ExcecaoExternal;
var
  LRaised: Boolean;
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LMockFactory: TDBFactoryMock;
  LPool: IDBConnectionPool;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
begin
  // Reproduz o cenário real: Query.Open estoura EAccessViolation (driver
  // nativo encontrando o servidor derrubado no meio da chamada) — a conexão
  // precisa ser descartada mesmo que IsConnected ainda reporte True (estado
  // em memória, não é round-trip real). BuildDatabaseException troca a AV
  // pela EDatabaseUnavailableException antes de relançar — é essa que deve
  // chegar ao chamador, nunca a AV crua (ver PascalDb.Interfaces).
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 1;
  LConfig.MaxConnections := 10;

  LMockFactory := TDBFactoryMock.Create;
  LFactory := LMockFactory;
  LRecorder := TPoolEventRecorder.Create;
  LEvents := LRecorder.Events;
  try
    LPool := TConnectionPool.Create(LFactory, LConfig,
      LRecorder.OnEvent);
    LEvents.Clear; // descarta o pekConnectionCreated do ramp-up

    TAssert.AssertEquals('Pré-condição: 1 conexão ociosa', 1, LPool.GetPoolSize);

    LMockFactory.RaiseOnNextQueryOpen(EAccessViolation, 'fake AV');
    LQuery := nil;
    LScope := LPool.AcquireQuery(LQuery);
    TAssert.AssertEquals('A conexão saiu do pool para a query', 0, LPool.GetPoolSize);

    LRaised := False;

    try

      LQuery.Open;

    except

      on E: EDatabaseUnavailableException do

        LRaised := True;

    end;

    TAssert.AssertTrue('Open deve propagar EDatabaseUnavailableException, não a EAccessViolation crua', LRaised);

    LQuery := nil;
    LScope := nil; // solta as duas referências que seguram a conexão

    TAssert.AssertEquals('Conexão que sofreu EAccessViolation não deve voltar ao pool', 0, LPool.GetPoolSize);
    TAssert.AssertEquals('Conexão descartada não conta mais como ativa', 0, LPool.GetActiveConnections);
    TAssert.AssertEquals('Deve disparar exatamente 1 evento pekConnectionDiscarded', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekConnectionDiscarded), Ord(LEvents[0].Kind));
    TAssert.AssertEquals(Ord(pdrBrokenAfterUse), Ord(LEvents[0].DiscardReason));
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_ConexaoDescartada_IsConnectedFalseAposExcecao;
var
  LRaised: Boolean;
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LMockFactory: TDBFactoryMock;
  LPool: IDBConnectionPool;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
begin
  // Exceção "normal" do driver (não EExternal), mas a conexão já reporta
  // IsConnected=False logo depois — sinal de queda real (ex.: "unavailable
  // database"), mesmo sem AV.
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 1;
  LConfig.MaxConnections := 10;

  LMockFactory := TDBFactoryMock.Create;
  LFactory := LMockFactory;
  LRecorder := TPoolEventRecorder.Create;
  LEvents := LRecorder.Events;
  try
    LPool := TConnectionPool.Create(LFactory, LConfig,
      LRecorder.OnEvent);
    LEvents.Clear;

    LMockFactory.RaiseOnNextQueryOpen(Exception, 'unavailable database');
    LQuery := nil;
    LScope := LPool.AcquireQuery(LQuery);

    // Simula o driver detectando a queda no momento da falha
    LMockFactory.LastCreatedConnection.Connected := False;

    LRaised := False;

    try

      LQuery.Open;

    except

      on E: EDatabaseUnavailableException do

        LRaised := True;

    end;

    TAssert.AssertTrue('Open deve propagar EDatabaseUnavailableException, não a exceção crua do driver', LRaised);

    LQuery := nil;
    LScope := nil;

    TAssert.AssertEquals('Conexão com IsConnected=False após a falha não deve voltar ao pool', 0, LPool.GetPoolSize);
    TAssert.AssertEquals('Deve disparar exatamente 1 evento pekConnectionDiscarded', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pdrBrokenAfterUse), Ord(LEvents[0].DiscardReason));
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_ConexaoMantida_ExcecaoDeNegocio;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LMockFactory: TDBFactoryMock;
  LPool: IDBConnectionPool;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
begin
  // Caso negativo, o mais importante dos três: uma exceção de dados comum
  // (ex.: violação de constraint, chave duplicada) com a conexão ainda
  // IsConnected=True NÃO pode descartar a conexão — senão todo erro de
  // negócio corriqueiro geraria churn de conexão no pool.
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 1;
  LConfig.MaxConnections := 10;

  LMockFactory := TDBFactoryMock.Create;
  LFactory := LMockFactory;
  LRecorder := TPoolEventRecorder.Create;
  LEvents := LRecorder.Events;
  try
    LPool := TConnectionPool.Create(LFactory, LConfig,
      LRecorder.OnEvent);
    LEvents.Clear;

    TAssert.AssertEquals('Pré-condição: 1 conexão ociosa', 1, LPool.GetPoolSize);

    LMockFactory.RaiseOnNextQueryOpen(Exception, 'violation of PRIMARY or UNIQUE KEY constraint');
    LQuery := nil;
    LScope := LPool.AcquireQuery(LQuery);
    // LastCreatedConnection.Connected permanece True (default) — a conexão
    // continua saudável, só a operação falhou.

    // try/except direto (não AssertRaises) — precisa confirmar que a
    // exceção propagada NÃO é EDatabaseUnavailableException; "Exception"
    // como classe esperada em AssertRaises deixaria passar até uma
    // reclassificação errada, já que EDatabaseUnavailableException também
    // "is Exception".
    try
      LQuery.Open;
      TAssert.Fail('Open deveria ter propagado a exceção simulada');
    except
      on E: EDatabaseUnavailableException do
        TAssert.Fail('Erro de dados normal não pode virar EDatabaseUnavailableException — ' +
          'a conexão está saudável, só a operação falhou');
      on E: Exception do
        ; // esperado: a exceção original, sem reclassificação
    end;

    LQuery := nil;
    LScope := nil;

    TAssert.AssertEquals('Exceção de negócio com conexão ainda saudável não deve descartar a conexão', 1, LPool.GetPoolSize);
    TAssert.AssertEquals('Nenhum evento pekConnectionDiscarded deve disparar para erro de dados normal', 0, LEvents.Count);
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_ConexaoDescartada_ExcecaoDuranteLeituraDeCampo;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LMockFactory: TDBFactoryMock;
  LPool: IDBConnectionPool;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LFakeResult: TFakeQueryResult;
  LResult: IQueryResult;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
  LRaised: Boolean;
begin
  // Reproduz o gap real encontrado em produção: Open retorna com sucesso (o
  // servidor caiu só depois, no meio do fetch dos campos) — a AV acontece
  // num GetAsXxx/GetNullableXxx chamado pelo Repository ao montar o DTO de
  // resposta, não dentro do próprio Open. Sem TQueryResultWrapper, esse
  // ponto não tinha nenhuma classificação.
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 1;
  LConfig.MaxConnections := 10;

  LMockFactory := TDBFactoryMock.Create;
  LFactory := LMockFactory;
  LRecorder := TPoolEventRecorder.Create;
  LEvents := LRecorder.Events;
  try
    LPool := TConnectionPool.Create(LFactory, LConfig,
      LRecorder.OnEvent);
    LEvents.Clear;

    LFakeResult := TFakeQueryResult.Create;
    LFakeResult.SetRaiseOnAnyCall(EAccessViolation, 'fake AV no fetch');
    LMockFactory.SetNextQueryOpenResult(LFakeResult);

    LQuery := nil;
    LScope := LPool.AcquireQuery(LQuery);

    LResult := LQuery.Open;
    TAssert.AssertTrue('Open deve retornar com sucesso (a falha é só na leitura do campo)', Assigned(LResult));

    // try/except direto em vez de AssertRaises — evita depender de como o
    // closure da anônima interage com o refcount de LResult (ver diagnóstico
    // de GetActiveConnections abaixo, que separa "vazou referência" de
    // "descartou mas o evento não disparou"). Espera EDatabaseUnavailableException
    // (BuildDatabaseException troca a AV crua por ela antes de relançar).
    LRaised := False;
    try
      LResult.GetAsString('QUALQUER_CAMPO');
    except
      on E: EDatabaseUnavailableException do
        LRaised := True;
    end;
    TAssert.AssertTrue('A leitura do campo deve propagar EDatabaseUnavailableException, não a AV crua', LRaised);

    LResult := nil;
    LQuery := nil;
    LScope := nil;

    TAssert.AssertEquals('Conexão que sofreu EAccessViolation na leitura de campo deve sair de ativa (0), não ficar presa como se ainda estivesse em uso', 0, LPool.GetActiveConnections);
    TAssert.AssertEquals('Conexão que sofreu EAccessViolation na leitura de campo não deve voltar ao pool', 0, LPool.GetPoolSize);
    TAssert.AssertEquals('Deve disparar exatamente 1 evento pekConnectionDiscarded', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekConnectionDiscarded), Ord(LEvents[0].Kind));
    TAssert.AssertEquals(Ord(pdrBrokenAfterUse), Ord(LEvents[0].DiscardReason));
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_EDatabaseUnavailableException_PreservaDetalheOriginal;
var
  LOriginal: Exception;
  LWrapped: EDatabaseUnavailableException;
begin
  LOriginal := EAccessViolation.Create(
    'Access violation at address 00D5D0F6 in module ''RetaWebLocalSvc.exe''. Read of address 005B005D');
  try
    LWrapped := EDatabaseUnavailableException.Create(LOriginal);
    try
      TAssert.AssertEquals('OriginalClassName deve preservar a classe da exceção nativa', 'EAccessViolation', LWrapped.OriginalClassName);
      TAssert.AssertEquals('OriginalMessage deve preservar o texto original (endereço da AV incluso)', LOriginal.Message, LWrapped.OriginalMessage);
      TAssert.AssertEquals('Message pública não deve vazar o texto técnico da AV pro cliente', 0, Pos('Access violation', LWrapped.Message));
      TAssert.AssertTrue('Message pública deve ser genérica e não vazia', Length(LWrapped.Message) > 0);
    finally
      LWrapped.Free;
    end;
  finally
    LOriginal.Free;
  end;
end;

initialization
  RegisterTest(TPoolTests);

end.
