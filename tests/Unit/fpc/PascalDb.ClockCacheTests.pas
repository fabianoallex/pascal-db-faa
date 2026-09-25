unit PascalDb.ClockCacheTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.ClockCacheTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for TClockCache (PascalDb.ClockCache): Put/Get, eviction by lives
  under both admission policies, lives cap, removal callback, full wrap-around
  of the hand, reference counting of the values (no leaks) and multithreaded
  read/write stress.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
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

  TClockCacheTests = class(TTestCase)
  private
    FRemovedCount: Integer;
    FLastRemovedText: string;
    procedure OnItemRemoved(var AValue: IMyTest);
    procedure TestEvict(const ATestName: string; ACacheSize: Integer;
      AElementsCount: Integer; ALives: array of Byte;
      AExpectedInCache: array of Boolean; AAdmissionPolicy: TAdmissionPolicy);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published

    procedure TestClockCache;
    procedure TestClockCache_Evict_SameLives;
    procedure TestClockCache_Evict_DifferentLives;
    procedure TestClockCache_Evict_DifferentLives_MultiTests;
    procedure TestClockCache_MultiThreadStress;
    procedure TestOnRemoveItem_CallbackFiredOnEviction;
    procedure TestMaxLives_Cap;
    procedure TestPut_UpdateExistingKey_AccumulatesLives;
    procedure TestCacheHitRate_TracksHitsAndMisses;

    // Additional tests
    procedure TestClockCache_HeavyConcurrency_ReadWrite;
    procedure TestClockCache_ReferenceCounting_LeakCheck;
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

    // Simulates a mixed read/write load
    if Random(100) < 70 then // 70% reads
    begin
      FCache.Get(Key, MyTest);
    end
    else // 30% writes
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

  // Uses a smaller key set to force collisions and contention
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
    TAssert.AssertFalse('BooleanResult should be False', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := '444';
    Cache.Put('A', MyTest);
    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertTrue('BooleanResult should be True', BooleanResult);
    TAssert.AssertEquals('MyTest.Text differs from the expected value', '444', MyTest.Text);

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertFalse('BooleanResult should be False', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := '555';
    Cache.Put('B', MyTest);
    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult should be True', BooleanResult);
    TAssert.AssertEquals('MyTest.Text differs from the expected value', '555', MyTest.Text);

    // try A again
    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertTrue('BooleanResult should be True', BooleanResult);
    TAssert.AssertEquals('MyTest.Text differs from the expected value', '444', MyTest.Text);

    // try B again
    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult should be True', BooleanResult);
    TAssert.AssertEquals('MyTest.Text differs from the expected value', '555', MyTest.Text);

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
    TAssert.AssertTrue('BooleanResult A should be True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'BBB';
    Cache.Put('B', MyTest);

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult B should be True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'CCC';
    Cache.Put('C', MyTest);

    BooleanResult := Cache.Get('C', MyTest);
    TAssert.AssertTrue('BooleanResult C should be True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'DDD';
    Cache.Put('D', MyTest);         // must remove A from the cache

    //--------------

    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertFalse('BooleanResult A should be False', BooleanResult);

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult B should be True', BooleanResult);

    BooleanResult := Cache.Get('C', MyTest);
    TAssert.AssertTrue('BooleanResult C should be True', BooleanResult);

    BooleanResult := Cache.Get('D', MyTest);
    TAssert.AssertTrue('BooleanResult D should be True', BooleanResult);
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
      Key := Chr(65 + I); // Produces 'A', 'B', 'C', 'D'...
      MyTest := TMyTest.Create;
      MyTest.Text := 'Content ' + Key;
      Cache.Put(Key, MyTest, ALives[I]);
    end;

    for I := 0 to AElementsCount - 1 do
    begin
      Key := Chr(65 + I);
      TAssert.AssertEquals(ATestName + '. ' + Format('Unexpected result for key %s', [Key]), AExpectedInCache[I], Cache.Get(Key, MyTest));
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
    Cache.Put('A', MyTest);  // 'A' Lives goes to 1

    MyTest := TMyTest.Create;
    MyTest.Text := 'AAA';
    Cache.Put('A', MyTest);  // 'A' Lives goes to 2

    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertTrue('BooleanResult A should be True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'BBB';
    Cache.Put('B', MyTest);  // 'B' Lives goes to 1

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertTrue('BooleanResult B should be True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'CCC';
    Cache.Put('C', MyTest);  // 'C' Lives goes to 1

    BooleanResult := Cache.Get('C', MyTest);
    TAssert.AssertTrue('BooleanResult C should be True', BooleanResult);

    MyTest := TMyTest.Create;
    MyTest.Text := 'DDD';
    Cache.Put('D', MyTest);         // must remove B from the cache, since A has one more life

    //--------------

    BooleanResult := Cache.Get('A', MyTest);
    TAssert.AssertTrue('BooleanResult A should be True', BooleanResult);

    BooleanResult := Cache.Get('B', MyTest);
    TAssert.AssertFalse('BooleanResult B should be False', BooleanResult);

    BooleanResult := Cache.Get('C', MyTest);
    TAssert.AssertTrue('BooleanResult C should be True', BooleanResult);

    BooleanResult := Cache.Get('D', MyTest);
    TAssert.AssertTrue('BooleanResult D should be True', BooleanResult);
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

    TAssert.AssertTrue('The map should not be empty', Cache.CacheHitRate.Hits + Cache.CacheHitRate.Misses > 0);
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

    TAssert.AssertEquals('No eviction yet', 0, FRemovedCount);

    MyTest := TMyTest.Create; MyTest.Text := 'CCC';
    Cache.Put('C', MyTest);

    TAssert.AssertEquals('OnRemoveItem must have been called once', 1, FRemovedCount);
    TAssert.AssertEquals('The evicted item must be AAA', 'AAA', FLastRemovedText);
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

    TAssert.AssertFalse('B must have been evicted in the 1st round', Cache.Get('B', MyTest));
    TAssert.AssertFalse('A must have been evicted in the 2nd round (the cap worked)', Cache.Get('A', MyTest));
    TAssert.AssertTrue('D must be in the cache', Cache.Get('D', MyTest));
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
    MyTest := TMyTest.Create; MyTest.Text := 'version 1';
    Cache.Put('A', MyTest, 1);

    MyTest := TMyTest.Create; MyTest.Text := 'version 2';
    Cache.Put('A', MyTest, 2);

    TAssert.AssertTrue('A must be in the cache', Cache.Get('A', MyTest));
    TAssert.AssertEquals('The value must be version 2', 'version 2', MyTest.Text);

    MyTest := TMyTest.Create; MyTest.Text := 'B';
    Cache.Put('B', MyTest, 1);
    MyTest := TMyTest.Create; MyTest.Text := 'C';
    Cache.Put('C', MyTest, 1);

    MyTest := TMyTest.Create; MyTest.Text := 'D';
    Cache.Put('D', MyTest, 1);

    TAssert.AssertTrue('A must survive', Cache.Get('A', MyTest));
    TAssert.AssertFalse('B must have been evicted', Cache.Get('B', MyTest));
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

    TAssert.AssertEquals('Hits must be 4', Int64(4), Stats.Hits);
    TAssert.AssertEquals('Misses must be 3', Int64(3), Stats.Misses);
    TAssert.AssertTrue('Efficiency must be > 50%', Stats.Efficiency > 50);
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
  Cache := TCache.Create(10, 3); // Small cache to force contention
  try
    for I := 1 to THREAD_COUNT do
      Threads[I] := TReadWriteStressThread.Create(Cache, ITERATIONS_PER_THREAD);

    for I := 1 to THREAD_COUNT do
    begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;

    // Reaching this point without a deadlock or AV means it passed the heavy concurrency
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
  // Make sure we start from zero
  TAssert.AssertEquals('There should be 0 instances at the start', 0, TLeakTestObject.InstanceCount);

  Cache := TCache.Create(5);
  try
    // Fill the cache with test objects
    for I := 1 to 5 do
    begin
      Obj := TLeakTestObject.Create;
      Cache.Put(IntToStr(I), Obj, 1);
      Obj := nil; // Release the local reference
    end;

    TAssert.AssertEquals('There should be 5 instances in the cache', 5, TLeakTestObject.InstanceCount);

    // Force eviction of every item by inserting new keys
    for I := 6 to 10 do
    begin
      Obj := TLeakTestObject.Create;
      Cache.Put(IntToStr(I), Obj, 1);
      Obj := nil;
    end;

    // After eviction, the old instances must have been destroyed (if they were cleared in the array)
    TAssert.AssertEquals('There should be only the 5 new instances', 5, TLeakTestObject.InstanceCount);

  finally
    Cache.Free;
  end;

  // After freeing the cache, every instance count must drop to zero
  TAssert.AssertEquals('There should be 0 instances after freeing the cache', 0, TLeakTestObject.InstanceCount);
end;

procedure TClockCacheTests.TestClockCache_FullCycle_HandWrapAround;
type
  TCache = TClockCache<string, string>;
var
  Cache: TCache;
  I: Integer;
  Value: string;
begin
  Cache := TCache.Create(3, 1); // Capacity 3, max lives 1
  try
    // Inserts 1, 2, 3 -> cache full, Hand at 0
    Cache.Put('1', 'V1');
    Cache.Put('2', 'V2');
    Cache.Put('3', 'V3');

    // Insert 4: evicts '1' (Hand=0), inserts '4', Hand goes to 1
    Cache.Put('4', 'V4');
    TAssert.AssertFalse('1 should have been evicted', Cache.Get('1', Value));

    // Insert 5: evicts '2' (Hand=1), inserts '5', Hand goes to 2
    Cache.Put('5', 'V5');
    TAssert.AssertFalse('2 should have been evicted', Cache.Get('2', Value));

    // Insert 6: evicts '3' (Hand=2), inserts '6', Hand goes to 0 (wrap-around!)
    Cache.Put('6', 'V6');
    TAssert.AssertFalse('3 should have been evicted', Cache.Get('3', Value));

    // Insert 7: evicts '4' (Hand=0 again)
    Cache.Put('7', 'V7');
    TAssert.AssertFalse('4 should have been evicted', Cache.Get('4', Value));

    TAssert.AssertTrue(Cache.Get('7', Value));
    TAssert.AssertTrue(Cache.Get('5', Value));
    TAssert.AssertTrue(Cache.Get('6', Value));
  finally
    Cache.Free;
  end;
end;

initialization
  RegisterTest(TClockCacheTests);

end.
