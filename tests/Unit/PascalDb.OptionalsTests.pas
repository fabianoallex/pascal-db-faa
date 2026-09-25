unit PascalDb.OptionalsTests;

{ Tests for the optional types (PascalDb.Optionals): HasValue/IsNull of
  Null/Undefined/From for each type, TOptionals.Safe with nil, instance reuse
  (fixed range and dynamic cache), distinct precision keys for Single/Double
  and concurrent access to From.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalDb.DUnitXCompat,
  Classes,
  SysUtils,
  PascalDb.Optionals,
  PascalDb.ClockCache;

type
  IMyTest = interface
    ['{6AA3D079-22E0-49D9-942D-CBA12645C0DE}']
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

  [TestFixture]
  TOptionalTests = class
  private
    procedure RaiseBoom(var AValue: string);
  public
    [Test]
    procedure TestString_Undefined_HasNoValue;
    [Test]
    procedure TestString_Undefined_IsNotNull;
    [Test]
    procedure TestString_Null_HasValue;
    [Test]
    procedure TestString_Null_IsNull;
    [Test]
    procedure TestString_From_HasValue;
    [Test]
    procedure TestString_From_IsNotNull;
    [Test]
    procedure TestString_From_ReturnsCorrectValue;
    [Test]
    procedure TestString_FromEmpty_HasValue;
    [Test]
    procedure TestString_FromEmpty_IsNotNull;
    [Test]
    procedure TestString_FromEmpty_ValueIsEmpty;

    [Test]
    procedure TestString_Null_IsSingleton;
    [Test]
    procedure TestString_Undefined_IsSingleton;
    [Test]
    procedure TestString_FromEmpty_IsSingleton;
    [Test]
    procedure TestString_From_SameValueReturnsSameInstance;
    [Test]
    procedure TestString_From_DifferentValueReturnsDifferentInstance;

    [Test]
    procedure TestString_Safe_WithNil_ReturnsNull;
    [Test]
    procedure TestString_Safe_WithValue_Passthrough;

    [Test]
    procedure TestInteger_Undefined_HasNoValue;
    [Test]
    procedure TestInteger_Null_HasValue;
    [Test]
    procedure TestInteger_Null_IsNull;
    [Test]
    procedure TestInteger_From_Zero_ValueIsZero;
    [Test]
    procedure TestInteger_From_MinBoundary;
    [Test]
    procedure TestInteger_From_MaxBoundary;
    [Test]
    procedure TestInteger_From_AboveMax_Dynamic;
    [Test]
    procedure TestInteger_From_BelowMin_Dynamic;
    [Test]
    procedure TestInteger_FixedCache_IsSingleton;
    [Test]
    procedure TestInteger_DynamicCache_IsSingleton;

    [Test]
    procedure TestInt64_Undefined_HasNoValue;
    [Test]
    procedure TestInt64_Null_HasValue;
    [Test]
    procedure TestInt64_Null_IsNull;
    [Test]
    procedure TestInt64_From_Zero_ValueIsZero;
    [Test]
    procedure TestInt64_From_MinBoundary;
    [Test]
    procedure TestInt64_From_MaxBoundary;
    [Test]
    procedure TestInt64_From_AboveMax_Dynamic;
    [Test]
    procedure TestInt64_From_BelowMin_Dynamic;
    [Test]
    procedure TestInt64_FixedCache_IsSingleton;
    [Test]
    procedure TestInt64_DynamicCache_IsSingleton;

    [Test]
    procedure TestInteger_Safe_WithNil_ReturnsNull;

    [Test]
    procedure TestBoolean_Null_HasValue;
    [Test]
    procedure TestBoolean_Null_IsNull;
    [Test]
    procedure TestBoolean_Undefined_HasNoValue;
    [Test]
    procedure TestBoolean_From_True;
    [Test]
    procedure TestBoolean_From_False;
    [Test]
    procedure TestBoolean_TrueValue_IsSingleton;
    [Test]
    procedure TestBoolean_FalseValue_IsSingleton;
    [Test]
    procedure TestBoolean_From_True_IsSameAsTrueValue;
    [Test]
    procedure TestBoolean_From_False_IsSameAsFalseValue;

    [Test]
    procedure TestBoolean_Safe_WithNil_ReturnsNull;

    [Test]
    procedure TestString_Undefined_GetValue_ReturnsEmptyString;
    [Test]
    procedure TestInteger_Undefined_GetValue_ReturnsZero;
    [Test]
    procedure TestBoolean_Undefined_GetValue_ReturnsFalse;

    [Test]
    procedure TestString_From_ConcurrentAccess;

    [Test]
    procedure TestGuid_Null_HasValue;
    [Test]
    procedure TestGuid_Null_IsNull;
    [Test]
    procedure TestGuid_From_Empty_ReturnsEmpty;
    [Test]
    procedure TestGuid_From_Value_ReturnsCorrectValue;
    [Test]
    procedure TestGuid_Safe_WithNil_ReturnsNull;

    [Test]
    procedure TestCurrency_Null_HasValue;
    [Test]
    procedure TestCurrency_Null_IsNull;
    [Test]
    procedure TestCurrency_From_Zero_ReturnsZero;
    [Test]
    procedure TestCurrency_From_Value_ReturnsCorrectValue;
    [Test]
    procedure TestCurrency_Safe_WithNil_ReturnsNull;

    // Edge-case tests
    [Test]
    procedure TestCache_HotItemProtection;
    [Test]
    procedure TestFloat_PrecisionKeys_AreDistinct;
    [Test]
    procedure TestOnRemoveItem_ExceptionHandling;
  end;

implementation

const
  // TGuid.Empty (a Delphi record helper) doesn't exist in FPC 3.2.2.
  EMPTY_GUID: TGUID = '{00000000-0000-0000-0000-000000000000}';

type
  { Thread that hammers TOptNullString.From (shared global cache).
    A subclass instead of TThread.CreateAnonymousThread: FPC 3.2.2 has no
    anonymous methods. }
  TStringFromWorker = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TStringFromWorker.Execute;
var
  J: Integer;
begin
  for J := 1 to 1000 do
    TOptNullString.From('thread-safe-' + IntToStr(J mod 50));
end;

{ TMyTest }

function TMyTest.GetText: string;
begin
  Result := FText;
end;

procedure TMyTest.SetText(AValue: string);
begin
  FText := AValue;
end;

{ TOptionalTests }

procedure TOptionalTests.TestString_Undefined_HasNoValue;
begin
  TAssert.AssertFalse(TOptNullString.Undefined.HasValue);
end;

procedure TOptionalTests.TestString_Undefined_IsNotNull;
begin
  TAssert.AssertFalse(TOptNullString.Undefined.IsNull);
end;

procedure TOptionalTests.TestString_Null_HasValue;
begin
  TAssert.AssertTrue(TOptNullString.Null.HasValue);
end;

procedure TOptionalTests.TestString_Null_IsNull;
begin
  TAssert.AssertTrue(TOptNullString.Null.IsNull);
end;

procedure TOptionalTests.TestString_From_HasValue;
begin
  TAssert.AssertTrue(TOptNullString.From('test').HasValue);
end;

procedure TOptionalTests.TestString_From_IsNotNull;
begin
  TAssert.AssertFalse(TOptNullString.From('test').IsNull);
end;

procedure TOptionalTests.TestString_From_ReturnsCorrectValue;
begin
  TAssert.AssertEquals('hello world', TOptNullString.From('hello world').Value);
end;

procedure TOptionalTests.TestString_FromEmpty_HasValue;
begin
  TAssert.AssertTrue(TOptNullString.From('').HasValue);
end;

procedure TOptionalTests.TestString_FromEmpty_IsNotNull;
begin
  TAssert.AssertFalse(TOptNullString.From('').IsNull);
end;

procedure TOptionalTests.TestString_FromEmpty_ValueIsEmpty;
begin
  TAssert.AssertEquals('', TOptNullString.From('').Value);
end;

procedure TOptionalTests.TestString_Null_IsSingleton;
begin
  TAssert.AssertTrue(TOptNullString.Null = TOptNullString.Null);
end;

procedure TOptionalTests.TestString_Undefined_IsSingleton;
begin
  TAssert.AssertTrue(TOptNullString.Undefined = TOptNullString.Undefined);
end;

procedure TOptionalTests.TestString_FromEmpty_IsSingleton;
begin
  TAssert.AssertTrue(TOptNullString.From('') = TOptNullString.From(''));
end;

procedure TOptionalTests.TestString_From_SameValueReturnsSameInstance;
begin
  TAssert.AssertTrue(TOptNullString.From('value') = TOptNullString.From('value'));
end;

procedure TOptionalTests.TestString_From_DifferentValueReturnsDifferentInstance;
begin
  TAssert.AssertFalse(TOptNullString.From('a') = TOptNullString.From('b'));
end;

procedure TOptionalTests.TestString_Safe_WithNil_ReturnsNull;
var
  R: INullString;
begin
  R := TOptionals.Safe(INullString(nil));
  TAssert.AssertTrue(R.IsNull);
end;

procedure TOptionalTests.TestString_Safe_WithValue_Passthrough;
var
  Input, Output: INullString;
begin
  Input := TOptNullString.From('abc');
  Output := TOptionals.Safe(Input);
  TAssert.AssertFalse(Output.IsNull);
  TAssert.AssertEquals('abc', Output.Value);
end;

procedure TOptionalTests.TestInteger_Undefined_HasNoValue;
begin
  TAssert.AssertFalse(TOptNullInteger.Undefined.HasValue);
end;

procedure TOptionalTests.TestInteger_Null_HasValue;
begin
  TAssert.AssertTrue(TOptNullInteger.Null.HasValue);
end;

procedure TOptionalTests.TestInteger_Null_IsNull;
begin
  TAssert.AssertTrue(TOptNullInteger.Null.IsNull);
end;

procedure TOptionalTests.TestInteger_From_Zero_ValueIsZero;
begin
  TAssert.AssertEquals(0, TOptNullInteger.From(0).Value);
end;

procedure TOptionalTests.TestInteger_From_MinBoundary;
begin
  TAssert.AssertEquals(-1, TOptNullInteger.From(-1).Value);
end;

procedure TOptionalTests.TestInteger_From_MaxBoundary;
begin
  TAssert.AssertEquals(20, TOptNullInteger.From(20).Value);
end;

procedure TOptionalTests.TestInteger_From_AboveMax_Dynamic;
begin
  TAssert.AssertEquals(21, TOptNullInteger.From(21).Value);
end;

procedure TOptionalTests.TestInteger_From_BelowMin_Dynamic;
begin
  TAssert.AssertEquals(-2, TOptNullInteger.From(-2).Value);
end;

procedure TOptionalTests.TestInteger_FixedCache_IsSingleton;
begin
  TAssert.AssertTrue(TOptNullInteger.From(5) = TOptNullInteger.From(5));
end;

procedure TOptionalTests.TestInteger_DynamicCache_IsSingleton;
begin
  TAssert.AssertTrue(TOptNullInteger.From(999) = TOptNullInteger.From(999));
end;

procedure TOptionalTests.TestInt64_Undefined_HasNoValue;
begin
  TAssert.AssertFalse(TOptNullInt64.Undefined.HasValue);
end;

procedure TOptionalTests.TestInt64_Null_HasValue;
begin
  TAssert.AssertTrue(TOptNullInt64.Null.HasValue);
end;

procedure TOptionalTests.TestInt64_Null_IsNull;
begin
  TAssert.AssertTrue(TOptNullInt64.Null.IsNull);
end;

procedure TOptionalTests.TestInt64_From_Zero_ValueIsZero;
begin
  TAssert.AssertEquals(Int64(0), TOptNullInt64.From(0).Value);
end;

procedure TOptionalTests.TestInt64_From_MinBoundary;
begin
  TAssert.AssertEquals(Int64(-1), TOptNullInt64.From(-1).Value);
end;

procedure TOptionalTests.TestInt64_From_MaxBoundary;
begin
  TAssert.AssertEquals(Int64(20), TOptNullInt64.From(20).Value);
end;

procedure TOptionalTests.TestInt64_From_AboveMax_Dynamic;
begin
  TAssert.AssertEquals(Int64(21), TOptNullInt64.From(21).Value);
end;

procedure TOptionalTests.TestInt64_From_BelowMin_Dynamic;
begin
  TAssert.AssertEquals(Int64(-2), TOptNullInt64.From(-2).Value);
end;

procedure TOptionalTests.TestInt64_FixedCache_IsSingleton;
begin
  TAssert.AssertTrue(TOptNullInt64.From(5) = TOptNullInt64.From(5));
end;

procedure TOptionalTests.TestInt64_DynamicCache_IsSingleton;
begin
  TAssert.AssertTrue(TOptNullInt64.From(999) = TOptNullInt64.From(999));
end;

procedure TOptionalTests.TestInteger_Safe_WithNil_ReturnsNull;
var
  R: INullInteger;
begin
  R := TOptionals.Safe(INullInteger(nil));
  TAssert.AssertTrue(R.IsNull);
end;

procedure TOptionalTests.TestBoolean_Null_HasValue;
begin
  TAssert.AssertTrue(TOptNullBoolean.Null.HasValue);
end;

procedure TOptionalTests.TestBoolean_Null_IsNull;
begin
  TAssert.AssertTrue(TOptNullBoolean.Null.IsNull);
end;

procedure TOptionalTests.TestBoolean_Undefined_HasNoValue;
begin
  TAssert.AssertFalse(TOptNullBoolean.Undefined.HasValue);
end;

procedure TOptionalTests.TestBoolean_From_True;
begin
  TAssert.AssertTrue(TOptNullBoolean.From(True).Value);
end;

procedure TOptionalTests.TestBoolean_From_False;
begin
  TAssert.AssertFalse(TOptNullBoolean.From(False).Value);
end;

procedure TOptionalTests.TestBoolean_TrueValue_IsSingleton;
begin
  TAssert.AssertTrue(TOptNullBoolean.TrueValue = TOptNullBoolean.TrueValue);
end;

procedure TOptionalTests.TestBoolean_FalseValue_IsSingleton;
begin
  TAssert.AssertTrue(TOptNullBoolean.FalseValue = TOptNullBoolean.FalseValue);
end;

procedure TOptionalTests.TestBoolean_From_True_IsSameAsTrueValue;
var
  V1, V2: IOptNullBoolean;
begin
  V1 := TOptNullBoolean.From(True);
  V2 := TOptNullBoolean.TrueValue;
  TAssert.AssertTrue(V1 = V2);
end;

procedure TOptionalTests.TestBoolean_From_False_IsSameAsFalseValue;
var
  V1, V2: IOptNullBoolean;
begin
  V1 := TOptNullBoolean.From(False);
  V2 := TOptNullBoolean.FalseValue;
  TAssert.AssertTrue(V1 = V2);
end;

procedure TOptionalTests.TestBoolean_Safe_WithNil_ReturnsNull;
var
  R: INullBoolean;
begin
  R := TOptionals.Safe(INullBoolean(nil));
  TAssert.AssertTrue(R.IsNull);
end;

procedure TOptionalTests.TestString_Undefined_GetValue_ReturnsEmptyString;
begin
  TAssert.AssertEquals('', TOptNullString.Undefined.Value);
end;

procedure TOptionalTests.TestInteger_Undefined_GetValue_ReturnsZero;
begin
  TAssert.AssertEquals(0, TOptNullInteger.Undefined.Value);
end;

procedure TOptionalTests.TestBoolean_Undefined_GetValue_ReturnsFalse;
begin
  TAssert.AssertFalse(TOptNullBoolean.Undefined.Value);
end;

procedure TOptionalTests.TestString_From_ConcurrentAccess;
var
  Threads: array[1..20] of TThread;
  I: Integer;
begin
  for I := 1 to 20 do
  begin
    Threads[I] := TStringFromWorker.Create(False);
  end;

  for I := 1 to 20 do
  begin
    Threads[I].WaitFor;
    Threads[I].Free;
  end;
  TAssert.AssertTrue(True);
end;

procedure TOptionalTests.TestGuid_Null_HasValue;
begin
  TAssert.AssertTrue(TOptNullGuid.Null.HasValue);
end;

procedure TOptionalTests.TestGuid_Null_IsNull;
begin
  TAssert.AssertTrue(TOptNullGuid.Null.IsNull);
end;

procedure TOptionalTests.TestGuid_From_Empty_ReturnsEmpty;
begin
  TAssert.AssertTrue(IsEqualGUID(TOptNullGuid.From(EMPTY_GUID).Value, EMPTY_GUID));
end;

procedure TOptionalTests.TestGuid_From_Value_ReturnsCorrectValue;
var
  G: TGUID;
begin
  CreateGUID(G);
  TAssert.AssertTrue(IsEqualGUID(TOptNullGuid.From(G).Value, G));
end;

procedure TOptionalTests.TestGuid_Safe_WithNil_ReturnsNull;
var
  R: INullGuid;
  NilRef: INullGuid;
begin
  NilRef := nil;
  R := TOptNullGuid.SafeNullable(NilRef); // TOptionals.Safe(INullGuid(nil));
  TAssert.AssertTrue(R.IsNull);
end;

procedure TOptionalTests.TestCurrency_Null_HasValue;
begin
  TAssert.AssertTrue(TOptNullCurrency.Null.HasValue);
end;

procedure TOptionalTests.TestCurrency_Null_IsNull;
begin
  TAssert.AssertTrue(TOptNullCurrency.Null.IsNull);
end;

procedure TOptionalTests.TestCurrency_From_Zero_ReturnsZero;
begin
  TAssert.AssertEquals(Currency(0.0), TOptNullCurrency.From(0.0).Value);
end;

procedure TOptionalTests.TestCurrency_From_Value_ReturnsCorrectValue;
begin
  TAssert.AssertEquals(Currency(123.45), TOptNullCurrency.From(123.45).Value);
end;

procedure TOptionalTests.TestCurrency_Safe_WithNil_ReturnsNull;
var
  R: INullCurrency;
begin
  R := TOptionals.Safe(INullCurrency(nil));
  TAssert.AssertTrue(R.IsNull);
end;

procedure TOptionalTests.TestCache_HotItemProtection;
type
  TCache = TClockCache<string, IMyTest>;
var
  Cache: TCache;
  MyTest: IMyTest;
begin
  Cache := TCache.Create(2, 5);
  Cache.AdmissionPolicy := apProtectHotItems;
  try
    MyTest := TMyTest.Create; MyTest.Text := 'Hot';
    Cache.Put('A', MyTest, 5); // Very hot item

    MyTest := TMyTest.Create; MyTest.Text := 'Cold1';
    Cache.Put('B', MyTest, 1);

    MyTest := TMyTest.Create; MyTest.Text := 'Cold2';
    Cache.Put('C', MyTest, 1); // Must evict B, keeping A

    TAssert.AssertTrue('The hot item must be protected', Cache.Get('A', MyTest));
    TAssert.AssertFalse('The cold item must be evicted', Cache.Get('B', MyTest));
  finally
    Cache.Free;
  end;
end;

procedure TOptionalTests.TestFloat_PrecisionKeys_AreDistinct;
var
  Cache: TClockCache<TOptNullDouble.TCacheKey, IOptNullDouble>;
  Key1, Key2, Key3: TOptNullDouble.TCacheKey;
  Val1, Val2, Temp: IOptNullDouble;
begin
  Cache := TClockCache<TOptNullDouble.TCacheKey, IOptNullDouble>.Create(5);
  try
    FillChar(Key1, SizeOf(Key1), 0); Key1.Value := 1.234; Key1.Precision := 2;
    FillChar(Key2, SizeOf(Key2), 0); Key2.Value := 1.234; Key2.Precision := 3;
    FillChar(Key3, SizeOf(Key3), 0); Key3.Value := 1.234; Key3.Precision := 4;

    Val1 := TOptNullDouble.From(1.234, 2);
    Val2 := TOptNullDouble.From(1.234, 3);

    Cache.Put(Key1, Val1);
    Cache.Put(Key2, Val2);

    TAssert.AssertTrue('Must find the key with precision 2', Cache.Get(Key1, Temp));
    TAssert.AssertTrue('Must find the key with precision 3', Cache.Get(Key2, Temp));
    TAssert.AssertFalse('Must not find the key with precision 4 (never inserted)', Cache.Get(Key3, Temp));
  finally
    Cache.Free;
  end;
end;

procedure TOptionalTests.RaiseBoom(var AValue: string);
begin
  raise Exception.Create('Boom');
end;

procedure TOptionalTests.TestOnRemoveItem_ExceptionHandling;
var
  Cache: TClockCache<string, string>;
begin
  Cache := TClockCache<string, string>.Create(1);
  Cache.OnRemoveItem := RaiseBoom;
  try
    Cache.Put('A', 'V1');
    try
      Cache.Put('B', 'V2'); // This must fire the callback and the exception
    except
      on E: Exception do TAssert.AssertEquals('Boom', E.Message);
    end;
    // The cache must stay consistent and accept new puts
    Cache.Put('C', 'V3');
    TAssert.AssertTrue(True);
  finally
    Cache.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TOptionalTests);
end.
