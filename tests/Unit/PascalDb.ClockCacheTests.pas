unit PascalDb.ClockCacheTests;

{ Testes do TClockCache (PascalDb.ClockCache): Put/Get, evicção por vidas
  com as duas políticas de admissão, limite de vidas, callback de remoção,
  giro completo do ponteiro, contagem de referência dos valores (sem leak) e
  estresse multithread de leitura e escrita.

  Mestre DUnitX, escrito no dialeto de asserts do FPCUnit (TAssert.*, via
  PascalDb.DUnitXCompat). O espelho em tests/Unit/fpc é gerado a partir do
  mestre por tools/gen_fpc_mirror.py — edite só o mestre. }

interface

uses
  DUnitX.TestFramework,
  PascalDb.DUnitXCompat,
  Classes,
  SysUtils,
  SyncObjs,
  PascalDb.ClockCache,
  PascalDb.Threading;

type
  IMyTest = interface
    ['{42405278-EB64-40F1-A6A6-DA8DF4C26937}']
    function GetText: string;
    procedure SetText(AValue: string);
    property Text: string read GetText write SetText;
  end;

  TMyTest = class(TInterfacedObject, IMyTest)
  private
    FText: string;
  public
    function GetText: string;
    procedure SetText(AValue: string);
    property Text: string read GetText write SetText;
  end;

  { TStressThread }
  TStressThread = class(TThread)
  type
    TCache = TClockCache<string, IMyTest>;
  private
    FCache: TCache;
    FKeys: array of string;
    FIterations: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ACache: TCache; AIterations: Integer);
  end;

  { TReadWriteStressThread }
  TReadWriteStressThread = class(TThread)
  type
    TCache = TClockCache<string, IMyTest>;
  private
    FCache: TCache;
    FKeys: array of string;
    FIterations: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ACache: TCache; AIterations: Integer);
  end;

  { TLeakTestObject }
  TLeakTestObject = class(TInterfacedObject, IInterface)
  private
    class var FInstanceCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    class property InstanceCount: Integer read FInstanceCount;
  end;

  [TestFixture]
  TClockCacheTests = class
  private
    FRemovedCount: Integer;
    FLastRemovedText: string;
    procedure OnItemRemoved(var AValue: IMyTest);
    procedure TestEvict(const ATestName: string; ACacheSize: Integer;
      AElementsCount: Integer; ALives: array of Byte;
      AExpectedInCache: array of Boolean; AAdmissionPolicy: TAdmissionPolicy);
  public
    [Setup]
    procedure SetUp;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure TestClockCache;
    [Test]
    procedure TestClockCache_Evict_SameLives;
    [Test]
    procedure TestClockCache_Evict_DifferentLives;
    [Test]
    procedure TestClockCache_Evict_DifferentLives_MultiTests;
    [Test]
    procedure TestClockCache_MultiThreadStress;
    [Test]
    procedure TestOnRemoveItem_CallbackFiredOnEviction;
    [Test]
    procedure TestMaxLives_Cap;
    [Test]
    procedure TestPut_UpdateExistingKey_AccumulatesLives;
    [Test]
    procedure TestCacheHitRate_TracksHitsAndMisses;

    // Novos testes propostos
    [Test]
    procedure TestClockCache_HeavyConcurrency_ReadWrite;
    [Test]
    procedure TestClockCache_ReferenceCounting_LeakCheck;
    [Test]
    procedure TestClockCache_FullCycle_HandWrapAround;
  end;

implementation

{ TMyTest }

function TMyTest.GetText: string;
begin
  Result := FText;
end;

procedure TMyTest.SetText(AValue: string);
begin
  FText := AValue;
end;

{ TStressThread }

procedure TStressThread.Execute;
var
  I: Integer;
  MyTest: IMyTest;
  Key: string;
begin
  for I := 1 to FIterations do
  begin
    Key := FKeys[Random(Length(FKeys))];

    if not FCache.Get(Key, MyTest) then
    begin
      MyTest := TMyTest.Create;
      FCache.Put(Key, MyTest, Random(3) + 1);
    end;
  end;
end;

constructor TStressThread.Create(ACache: TCache; AIterations: Integer);
begin
  inherited Create(False);
  FCache := ACache;
  FIterations := AIterations;

  FKeys := ['01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11'
    , '12', '13', '14', '15', '16', '17', '18', '19', '20', '21', '22', '23'
    , '24', '25', '26', '27', '28', '29', '30', '31', '32', '33', '34', '35'
    , '36', '37', '38', '39', '40', '41', '42', '43', '44', '45', '46', '47'
    , '48', '49', '50'];

  FreeOnTerminate := False;
end;

{ TReadWriteStressThread }

procedure TReadWriteStressThread.Execute;
var
  I: Integer;
  MyTest: IMyTest;
  Key: string;
begin
  for I := 1 to FIterations do
  begin
    Key := FKeys[Random(Length(FKeys))];

    // Simula uma carga mista de leitura e escrita
    if Random(100) < 70 then // 70% Leituras
    begin
      FCache.Get(Key, MyTest);
    end
    else // 30% Escritas
    begin
      MyTest := TMyTest.Create;
      MyTest.Text := 'Update ' + IntToStr(I);
      FCache.Put(Key, MyTest, 1);
    end;
  end;
end;

constructor TReadWriteStressThread.Create(ACache: TCache; AIterations: Integer);
begin
  inherited Create(False);
  FCache := ACache;
  FIterations := AIterations;

  // Usa um conjunto menor de chaves para forçar colisão e contenção
  FKeys := ['K1', 'K2', 'K3', 'K4', 'K5'];

  FreeOnTerminate := False;
end;

{ TLeakTestObject }

constructor TLeakTestObject.Create;
begin
  inherited Create;
  PdbAtomicInc(FInstanceCount);
end;

destructor TLeakTestObject.Destroy;
begin
  PdbAtomicDec(FInstanceCount);
  inherited;
end;

{ TClockCacheTests }

procedure TClockCacheTests.SetUp;
begin
  FRemovedCount := 0;
  FLastRemovedText := '';
end;

procedure TClockCacheTests.TearDown;
begin
end;

procedure TClockCacheTests.OnItemRemoved(var AValue: IMyTest);
begin
  Inc(FRemovedCount);
  if Assigned(AValue) then
    FLastRemovedText := AValue.Text;
end;

procedure TClockCacheTests.TestClockCache;
type
  TCacheTest = TClockCache<string, IMyTest>;
var
  Cache: TCacheTest;
  MyTest: IMyTest;
  BooleanResult: Boolean;
begin
  Cache := TCacheTest.Create(3);
  try
    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertFalse('BooleanResult deveria ser False', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := '444';
    Cache.Put('A', MyTest);
    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertTrue('BooleanResult deveria ser True', BooleanResult);
    TAssert.AssertEquals('MyTest.Text diferente do esperado', '444', MyTest.Text);

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertFalse('BooleanResult deveria ser False', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := '555';
    Cache.Put('B', MyTest);
    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult deveria ser True', BooleanResult);
    TAssert.AssertEquals('MyTest.Text diferente do esperado', '555', MyTest.Text);

    // tenta novamente o A
    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertTrue('BooleanResult deveria ser True', BooleanResult);
    TAssert.AssertEquals('MyTest.Text diferente do esperado', '444', MyTest.Text);

    // tenta novamente o B
    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult deveria ser True', BooleanResult);
    TAssert.AssertEquals('MyTest.Text diferente do esperado', '555', MyTest.Text);

  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestClockCache_Evict_SameLives;
type
  TCacheTest = TClockCache<string, IMyTest>;
var
  Cache: TCacheTest;
  MyTest: IMyTest;
  BooleanResult: Boolean;
begin
  Cache := TCacheTest.Create(3);
  try
    MyTest := TMyTest.Create;
    MyTest.Text := 'AAA';
    Cache.Put('A', MyTest);

    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertTrue('BooleanResult A deveria ser True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'BBB';
    Cache.Put('B', MyTest);

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult B deveria ser True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'CCC';
    Cache.Put('C', MyTest);

    BooleanResult := Cache.Get('C', MyTest);
    TAssert.AssertTrue('BooleanResult C deveria ser True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'DDD';
    Cache.Put('D', MyTest);         // deve remover A do cache

    //--------------

    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertFalse('BooleanResult A deveria ser False', BooleanResult);

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult B deveria ser True', BooleanResult);

    BooleanResult := Cache.Get('C', MyTest);
    TAssert.AssertTrue('BooleanResult C deveria ser True', BooleanResult);

    BooleanResult := Cache.Get('D', MyTest);
    TAssert.AssertTrue('BooleanResult D deveria ser True', BooleanResult);
  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestEvict(const ATestName: string; ACacheSize: Integer;
  AElementsCount: Integer; ALives: array of Byte;
  AExpectedInCache: array of Boolean; AAdmissionPolicy: TAdmissionPolicy);
type
  TCacheTest = TClockCache<string, IMyTest>;
var
  Cache: TCacheTest;
  MyTest: IMyTest;
  I: Integer;
  Key: string;
begin
  Cache := TCacheTest.Create(ACacheSize, 10);
  Cache.AdmissionPolicy := AAdmissionPolicy;
  try
    for I := 0 to AElementsCount - 1 do
    begin
      Key := Chr(65 + I); // Gera 'A', 'B', 'C', 'D'...
      MyTest := TMyTest.Create;
      MyTest.Text := 'Content ' + Key;
      Cache.Put(Key, MyTest, ALives[I]);
    end;

    for I := 0 to AElementsCount - 1 do
    begin
      Key := Chr(65 + I);
      TAssert.AssertEquals(ATestName + '. ' + Format('Erro de expectativa para a chave %s', [Key]), AExpectedInCache[I], Cache.Get(Key, MyTest));
    end;
  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestClockCache_Evict_DifferentLives;
type
  TCacheTest = TClockCache<string, IMyTest>;
var
  Cache: TCacheTest;
  MyTest: IMyTest;
  BooleanResult: Boolean;
begin
  Cache := TCacheTest.Create(3);
  try
    MyTest := TMyTest.Create;
    MyTest.Text := 'AAA';
    Cache.Put('A', MyTest);  // 'A' Lives vai para 1

    MyTest := TMyTest.Create;
    MyTest.Text := 'AAA';
    Cache.Put('A', MyTest);  // 'A' Lives vai para 2

    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertTrue('BooleanResult A deveria ser True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'BBB';
    Cache.Put('B', MyTest);  // 'B' Lives vai para 1

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult B deveria ser True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'CCC';
    Cache.Put('C', MyTest);  // 'C' Lives vai para 1

    BooleanResult := Cache.Get('C', MyTest);
    TAssert.AssertTrue('BooleanResult C deveria ser True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'DDD';
    Cache.Put('D', MyTest);         // deve remover B do cache, pois A tem uma vida a mais

    //--------------

    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertTrue('BooleanResult A deveria ser True', BooleanResult);

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertFalse('BooleanResult B deveria ser False', BooleanResult);

    BooleanResult := Cache.Get('C', MyTest);
    TAssert.AssertTrue('BooleanResult C deveria ser True', BooleanResult);

    BooleanResult := Cache.Get('D', MyTest);
    TAssert.AssertTrue('BooleanResult D deveria ser True', BooleanResult);
  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestClockCache_Evict_DifferentLives_MultiTests;
begin
  TestEvict('CASE 01', 2, 3, [1, 1, 1], [False, True, True], apAlwaysAdmit);
  TestEvict('CASE 02', 2, 3, [2, 1, 1], [True, False, True], apAlwaysAdmit);
  TestEvict('CASE 03', 2, 3, [2, 2, 1], [False, True, True], apAlwaysAdmit);
  TestEvict('CASE 04', 2, 3, [2, 2, 1], [True, True, False], apProtectHotItems);
  TestEvict('CASE 05', 2, 3, [1, 1, 1], [False, True, True], apProtectHotItems);
  TestEvict('CASE 06', 2, 4, [3, 5, 1, 2], [False, True, False, True], apAlwaysAdmit);
  TestEvict('CASE 07', 3, 4, [5, 5, 5, 1], [True, True, True, False], apProtectHotItems);
  TestEvict('CASE 09', 2, 4, [1, 1, 1, 1], [False, False, True, True], apAlwaysAdmit);
  TestEvict('CASE 10', 5, 10,
    [1,     10,   1,     1,     1,     1,     1,    1,    1,    1],
    [False, True, False, False, False, False, True, True, True, True],
    apAlwaysAdmit);
  TestEvict('CASE 11', 2, 3, [10, 10, 1], [False, True, True], apAlwaysAdmit);
  TestEvict('CASE 12', 2, 4, [0, 0, 0, 0], [False, False, True, True], apAlwaysAdmit);
end;

procedure TClockCacheTests.TestClockCache_MultiThreadStress;
type
  TCache = TClockCache<string, IMyTest>;
const
  THREAD_COUNT = 10;
  ITERATIONS_PER_THREAD = 10000;
var
  Threads: array[1..THREAD_COUNT] of TStressThread;
  I: Integer;
  Cache: TCache;
begin
  Cache := TCache.Create(20, 5);
  try
    Cache.CacheHitRate.Start;
    for I := 1 to THREAD_COUNT do
      Threads[I] := TStressThread.Create(Cache, ITERATIONS_PER_THREAD);

    for I := 1 to THREAD_COUNT do
    begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;
    Cache.CacheHitRate.Stop;

    TAssert.AssertTrue('O mapa não deveria estar vazio', Cache.CacheHitRate.Hits + Cache.CacheHitRate.Misses > 0);
  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestOnRemoveItem_CallbackFiredOnEviction;
type
  TCacheTest = TClockCache<string, IMyTest>;
var
  Cache: TCacheTest;
  MyTest: IMyTest;
begin
  Cache := TCacheTest.Create(2);
  try
    Cache.OnRemoveItem := OnItemRemoved;

    MyTest := TMyTest.Create; MyTest.Text := 'AAA';
    Cache.Put('A', MyTest);
    MyTest := TMyTest.Create; MyTest.Text := 'BBB';
    Cache.Put('B', MyTest);

    TAssert.AssertEquals('Sem eviction ainda', 0, FRemovedCount);

    MyTest := TMyTest.Create; MyTest.Text := 'CCC';
    Cache.Put('C', MyTest);

    TAssert.AssertEquals('OnRemoveItem deve ter sido chamado 1 vez', 1, FRemovedCount);
    TAssert.AssertEquals('Item expulso deve ser AAA', 'AAA', FLastRemovedText);
  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestMaxLives_Cap;
type
  TCacheTest = TClockCache<string, IMyTest>;
var
  Cache: TCacheTest;
  MyTest: IMyTest;
begin
  Cache := TCacheTest.Create(2, 2);
  try
    MyTest := TMyTest.Create; MyTest.Text := 'A';
    Cache.Put('A', MyTest, 100);

    MyTest := TMyTest.Create; MyTest.Text := 'B';
    Cache.Put('B', MyTest, 1);

    MyTest := TMyTest.Create; MyTest.Text := 'C';
    Cache.Put('C', MyTest, 1);

    MyTest := TMyTest.Create; MyTest.Text := 'D';
    Cache.Put('D', MyTest, 1);

    TAssert.AssertFalse('B deve ter sido expulso na 1ª rodada', Cache.Get('B', MyTest));
    TAssert.AssertFalse('A deve ter sido expulso na 2ª rodada (cap funcionou)', Cache.Get('A', MyTest));
    TAssert.AssertTrue('D deve estar no cache', Cache.Get('D', MyTest));
  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestPut_UpdateExistingKey_AccumulatesLives;
type
  TCacheTest = TClockCache<string, IMyTest>;
var
  Cache: TCacheTest;
  MyTest: IMyTest;
begin
  Cache := TCacheTest.Create(3, 5);
  try
    MyTest := TMyTest.Create; MyTest.Text := 'versão 1';
    Cache.Put('A', MyTest, 1);

    MyTest := TMyTest.Create; MyTest.Text := 'versão 2';
    Cache.Put('A', MyTest, 2);

    TAssert.AssertTrue('A deve estar no cache', Cache.Get('A', MyTest));
    TAssert.AssertEquals('Valor deve ser a versão 2', 'versão 2', MyTest.Text);

    MyTest := TMyTest.Create; MyTest.Text := 'B';
    Cache.Put('B', MyTest, 1);
    MyTest := TMyTest.Create; MyTest.Text := 'C';
    Cache.Put('C', MyTest, 1);

    MyTest := TMyTest.Create; MyTest.Text := 'D';
    Cache.Put('D', MyTest, 1);

    TAssert.AssertTrue('A deve sobreviver', Cache.Get('A', MyTest));
    TAssert.AssertFalse('B deve ter sido expulso', Cache.Get('B', MyTest));
  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestCacheHitRate_TracksHitsAndMisses;
type
  TCacheTest = TClockCache<string, IMyTest>;
var
  Cache: TCacheTest;
  MyTest: IMyTest;
  Stats: TCacheStats;
begin
  Cache := TCacheTest.Create(10);
  try
    Cache.CacheHitRate.Start;

    MyTest := TMyTest.Create; Cache.Put('A', MyTest, 1);
    MyTest := TMyTest.Create; Cache.Put('B', MyTest, 1);
    MyTest := TMyTest.Create; Cache.Put('C', MyTest, 1);

    Cache.Get('A', MyTest);
    Cache.Get('B', MyTest);
    Cache.Get('A', MyTest);
    Cache.Get('C', MyTest);

    Cache.CacheHitRate.Stop;
    Stats := Cache.CacheHitRate.GetCacheStats;

    TAssert.AssertEquals('Hits devem ser 4', Int64(4), Stats.Hits);
    TAssert.AssertEquals('Misses devem ser 3', Int64(3), Stats.Misses);
    TAssert.AssertTrue('Efficiency deve ser > 50%', Stats.Efficiency > 50);
  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestClockCache_HeavyConcurrency_ReadWrite;
type
  TCache = TClockCache<string, IMyTest>;
const
  THREAD_COUNT = 8;
  ITERATIONS_PER_THREAD = 20000;
var
  Threads: array[1..THREAD_COUNT] of TReadWriteStressThread;
  I: Integer;
  Cache: TCache;
begin
  Cache := TCache.Create(10, 3); // Cache pequeno para forçar contenção
  try
    for I := 1 to THREAD_COUNT do
      Threads[I] := TReadWriteStressThread.Create(Cache, ITERATIONS_PER_THREAD);

    for I := 1 to THREAD_COUNT do
    begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;

    // Se chegou aqui sem deadlock ou AV, passou na concorrência pesada
    TAssert.AssertTrue(True);
  finally
    Cache.Free;
  end;
end;

procedure TClockCacheTests.TestClockCache_ReferenceCounting_LeakCheck;
type
  TCache = TClockCache<string, IInterface>;
var
  Cache: TCache;
  Obj: IInterface;
  I: Integer;
begin
  // Garante que começamos do zero
  TAssert.AssertEquals('Deveria haver 0 instâncias no início', 0, TLeakTestObject.InstanceCount);

  Cache := TCache.Create(5);
  try
    // Preenche o cache com objetos de teste
    for I := 1 to 5 do
    begin
      Obj := TLeakTestObject.Create;
      Cache.Put(IntToStr(I), Obj, 1);
      Obj := nil; // Libera a referência local
    end;

    TAssert.AssertEquals('Deveria haver 5 instâncias no cache', 5, TLeakTestObject.InstanceCount);

    // Força a expulsão de todos os itens inserindo novos chaves
    for I := 6 to 10 do
    begin
      Obj := TLeakTestObject.Create;
      Cache.Put(IntToStr(I), Obj, 1);
      Obj := nil;
    end;

    // Após a expulsão, as instâncias antigas devem ter sido destruídas (se foram zeradas no array)
    TAssert.AssertEquals('Deveria haver apenas as 5 novas instâncias', 5, TLeakTestObject.InstanceCount);

  finally
    Cache.Free;
  end;

  // Após liberar o cache, todas as instâncias devem cair para zero
  TAssert.AssertEquals('Deveria haver 0 instâncias após liberar o cache', 0, TLeakTestObject.InstanceCount);
end;

procedure TClockCacheTests.TestClockCache_FullCycle_HandWrapAround;
type
  TCache = TClockCache<string, string>;
var
  Cache: TCache;
  I: Integer;
  Value: string;
begin
  Cache := TCache.Create(3, 1); // Capacidade 3, max lives 1
  try
    // Inserção 1, 2, 3 -> Cache cheio, Hand em 0
    Cache.Put('1', 'V1');
    Cache.Put('2', 'V2');
    Cache.Put('3', 'V3');

    // Inserção 4: Expulsa '1' (Hand=0), insere '4', Hand vai para 1
    Cache.Put('4', 'V4');
    TAssert.AssertFalse('1 deveria ter sido expulso', Cache.Get('1', Value));

    // Inserção 5: Expulsa '2' (Hand=1), insere '5', Hand vai para 2
    Cache.Put('5', 'V5');
    TAssert.AssertFalse('2 deveria ter sido expulso', Cache.Get('2', Value));

    // Inserção 6: Expulsa '3' (Hand=2), insere '6', Hand vai para 0 (Wrap Around!)
    Cache.Put('6', 'V6');
    TAssert.AssertFalse('3 deveria ter sido expulso', Cache.Get('3', Value));

    // Inserção 7: Expulsa '4' (Hand=0 novamente)
    Cache.Put('7', 'V7');
    TAssert.AssertFalse('4 deveria ter sido expulso', Cache.Get('4', Value));

    TAssert.AssertTrue(Cache.Get('7', Value));
    TAssert.AssertTrue(Cache.Get('5', Value));
    TAssert.AssertTrue(Cache.Get('6', Value));
  finally
    Cache.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TClockCacheTests);

end.
