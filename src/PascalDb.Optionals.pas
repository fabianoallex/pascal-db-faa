unit PascalDb.Optionals;

{$I pascaldb.inc}

{ Optional and nullable types used in parameters, DTOs and column reads:
  IOptXxx ("was it provided?" — HasValue), INullXxx ("is it null?" —
  IsNull) and IOptNullXxx (both), for String, Integer, Int64, Single, Double,
  Currency, TDateTime, Boolean and TGUID. A single class per type
  (TOptNullXxx) implements all three interfaces.

  TOptionals.Safe(X) never returns nil: with X = nil it returns Undefined
  (HasValue = False) for IOptXxx/IOptNullXxx and Null (IsNull = True) for
  INullXxx. That is the guard that lets consuming code test just
  .HasValue/.IsNull, without Assigned checks field by field.

  Instances are immutable and shared: Null/Undefined are singletons, and
  From(Value) reuses instances through a global per-type cache (a fixed range
  for small integers + TClockCache for the rest), with its own lock — which
  is why From is safe under concurrency.

  Dual-compiler: the cache-key comparers for Single/Double are named
  functions (TEqualityComparer<T>.Construct doesn't accept a closure on FPC
  3.2.2, and the IEqualityComparer<T> signature differs — constref/UInt32 on
  FPC), and the empty GUID is a local constant (TGuid.Empty is a Delphi
  helper). }

interface

uses
  Classes, SysUtils, SyncObjs, PascalDb.SystemContext,
  PascalDb.ClockCache, Generics.Defaults;

type
  IOptionalBase = interface
    ['{E4F4A971-9D82-4072-9FCD-B94B3534D00B}']
    function HasValue: Boolean;
  end;

  INullableBase = interface
    ['{FF676337-9F25-4E4E-987B-759175358B7E}']
    function IsNull: Boolean;
  end;

  IOptionalNullableBase = interface
    ['{F991DB80-57A5-49FA-812F-70692A6893C8}']
    function IsNull: Boolean;
    function HasValue: Boolean;
  end;

  IOptional<T> = interface(IOptionalBase)
    ['{ED862237-1C8B-4B92-95D1-65E47B4D83B7}']
    function GetValue: T;
    property Value: T read GetValue;
  end;

  INullable<T> = interface(INullableBase)
    ['{676D05B3-6E6F-4F82-A9AB-455E9464F866}']
    function GetValue: T;
    property Value: T read GetValue;
  end;

  IOptionalNullable<T> = interface(IOptionalNullableBase)
    ['{B27511F9-7746-4432-9165-CF31D058053A}']
    function GetValue: T;
    property Value: T read GetValue;
  end;

  { string interfaces }

  IOptString = interface(IOptional<string>)
    ['{A761330C-AA4B-44A5-A617-C79E3F745A23}']
  end;

  INullString = interface(INullable<string>)
    ['{C86A1566-0B19-4BE2-B780-D22C3ED385F6}']
  end;

  IOptNullString = interface(IOptionalNullable<string>)
    ['{E166D638-8A7C-4143-A0EE-22161499F6A8}']
  end;

  { Integers interfaces }

  IOptInteger = interface(IOptional<Integer>)
    ['{472AF43B-BC8E-42A5-B275-2D9B0BEE6667}']
  end;

  INullInteger = interface(INullable<Integer>)
    ['{C040BEFA-C342-4F0A-92AD-6FA7711FA002}']
  end;

  IOptNullInteger = interface(IOptionalNullable<Integer>)
    ['{6092BDE1-A122-4BFB-AF50-4947884DA9FD}']
  end;

  { Int64 interfaces }

  IOptInt64 = interface(IOptional<Int64>)
    ['{A6307E45-A804-4B1B-BE27-8FB393CC80F5}']
  end;

  INullInt64 = interface(INullable<Int64>)
    ['{A497772F-B7B2-448E-8191-CE4EEEE0B6C6}']
  end;

  IOptNullInt64 = interface(IOptionalNullable<Int64>)
    ['{78F13E94-E8CB-463E-B5A2-A4EC93D20D9D}']
  end;

  { DateTime interfaces }

  IOptDateTime = interface(IOptional<TDateTime>)
    ['{764BCB67-F040-4BA1-B127-BA6A5BB5CEF6}']
  end;

  INullDateTime = interface(INullable<TDateTime>)
    ['{107CDFB4-20E1-4887-A1D3-9DD247798F9D}']
  end;

  IOptNullDateTime = interface(IOptionalNullable<TDateTime>)
    ['{1C1A3315-7A2A-4764-8E0D-40166907A10B}']
  end;

  { Boolean interfaces }

  IOptBoolean = interface(IOptional<Boolean>)
    ['{E7274751-2E3F-49FF-9DC0-6ED268F400F8}']
  end;

  INullBoolean = interface(INullable<Boolean>)
    ['{07ED6DF4-64E8-4246-BA8F-D232B6336888}']
  end;

  IOptNullBoolean = interface(IOptionalNullable<Boolean>)
    ['{E1FF6455-38A6-4999-B63D-3A1D48F54A9B}']
  end;

  { GUID interfaces }

  IOptGuid = interface(IOptional<TGUID>)
    ['{A8135F04-35BF-43EE-B345-85C784E583E0}']
  end;

  INullGuid = interface(INullable<TGUID>)
    ['{AD57F2C9-083B-42AE-8980-6B3CD3CE3382}']
  end;

  IOptNullGuid = interface(IOptionalNullable<TGUID>)
    ['{8B4F0499-ECE5-4881-A6AF-F9B7DD875477}']
  end;

  { Currency interfaces }

  IOptCurrency = interface(IOptional<Currency>)
    ['{79A63721-7A39-44F0-A3A8-E0C79A81432E}']
  end;

  INullCurrency = interface(INullable<Currency>)
    ['{487532A1-9B21-4E65-B8A2-C1D826B74312}']
  end;

  IOptNullCurrency = interface(IOptionalNullable<Currency>)
    ['{C781A329-8E2B-4F54-9321-A3C9E23D5F11}']
  end;

  IDecimalPrecision = interface
    ['{84D64E10-8D21-4E2F-A2BE-EB399AF77B45}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
  end;

  { Single interfaces }

  IOptSingle = interface(IOptional<Single>)
    ['{52B5032D-B7AD-4A12-B7C1-36D6E146D783}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
  end;

  INullSingle = interface(INullable<Single>)
    ['{315FF86F-2214-4250-865C-172898105578}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
  end;

  IOptNullSingle = interface(IOptionalNullable<Single>)
    ['{CF6A4091-6C5B-4CEE-8344-0BC3C6F02567}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
  end;

  { Double interfaces }

  IOptDouble = interface(IOptional<Double>)
    ['{6645BB6E-7837-4A4E-90B5-F1B887C9B0C2}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
  end;

  INullDouble = interface(INullable<Double>)
    ['{01368222-01F7-4698-8ECB-45AC8D6FA901}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
  end;

  IOptNullDouble = interface(IOptionalNullable<Double>)
    ['{3C030269-23A9-4379-B64F-74B3EE9EAE66}']
    function GetDecimalPlaces: Integer;
    property DecimalPlaces: Integer read GetDecimalPlaces;
  end;

  { TOptionals Helper }

  TOptionals = class
  public
    // String
    class function Safe(const AValue: IOptString): IOptString; overload; static;
    class function Safe(const AValue: INullString): INullString; overload; static;
    class function Safe(const AValue: IOptNullString): IOptNullString; overload; static;
    // Integer
    class function Safe(const AValue: IOptInteger): IOptInteger; overload; static;
    class function Safe(const AValue: INullInteger): INullInteger; overload; static;
    class function Safe(const AValue: IOptNullInteger): IOptNullInteger; overload; static;
    // Int64
    class function Safe(const AValue: IOptInt64): IOptInt64; overload; static;
    class function Safe(const AValue: INullInt64): INullInt64; overload; static;
    class function Safe(const AValue: IOptNullInt64): IOptNullInt64; overload; static;
    // Single
    class function Safe(const AValue: IOptSingle): IOptSingle; overload; static;
    class function Safe(const AValue: INullSingle): INullSingle; overload; static;
    class function Safe(const AValue: IOptNullSingle): IOptNullSingle; overload; static;
    // Double
    class function Safe(const AValue: IOptDouble): IOptDouble; overload; static;
    class function Safe(const AValue: INullDouble): INullDouble; overload; static;
    class function Safe(const AValue: IOptNullDouble): IOptNullDouble; overload; static;
    // DateTime
    class function Safe(const AValue: IOptDateTime): IOptDateTime; overload; static;
    class function Safe(const AValue: INullDateTime): INullDateTime; overload; static;
    class function Safe(const AValue: IOptNullDateTime): IOptNullDateTime; overload; static;
    // Boolean
    class function Safe(const AValue: IOptBoolean): IOptBoolean; overload; static;
    class function Safe(const AValue: INullBoolean): INullBoolean; overload; static;
    class function Safe(const AValue: IOptNullBoolean): IOptNullBoolean; overload; static;
    // Guid
    class function Safe(const AValue: IOptGuid): IOptGuid; overload; static;
    class function Safe(const AValue: INullGuid): INullGuid; overload; static;
    class function Safe(const AValue: IOptNullGuid): IOptNullGuid; overload; static;
    // Currency
    class function Safe(const AValue: IOptCurrency): IOptCurrency; overload; static;
    class function Safe(const AValue: INullCurrency): INullCurrency; overload; static;
    class function Safe(const AValue: IOptNullCurrency): IOptNullCurrency; overload; static;
  end;

  { TOptionalNullableBase }

  TOptionalNullableBase = class(TInterfacedObject,
    IOptionalBase,
    INullableBase,
    IOptionalNullableBase
  )
  private
    FIsNull: Boolean;
    FHasValue: Boolean;
  public
    constructor Create; overload;      // undefined
    constructor CreateNull; overload;  // null
  public
    function IsNull: Boolean;
    function HasValue: Boolean;
  end;

  TOptionalNullable<T> = class(TOptionalNullableBase,
    IOptional<T>,
    INullable<T>,
    IOptionalNullable<T>
  )
  private
    FValue: T;
  public
    constructor Create(AValue: T); overload;
    function GetValue: T;
    property Value: T read GetValue;
  end;

  { TOptNullString }

  TOptNullString = class(TOptionalNullable<string>,
    IOptString, INullString, IOptNullString)
  type
    TCache = TClockCache<string, IOptNullString>;
  private
    const CACHE_SIZE = 2000;
    class var FGlobalNull: IOptNullString;
    class var FGlobalUndefined: IOptNullString;
    class var FGlobalEmpty: IOptNullString;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullString; static;
    class function Undefined: TOptNullString; static;
    class function From(AValue: string): TOptNullString; static;
    class function SafeNullable(AValue: INullString): INullString; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptional(AValue: IOptString): IOptString; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptNull(AValue: IOptNullString): IOptNullString; deprecated 'Use TOptionals.Safe instead'; static;
  end;

  { TOptNullInteger }

  TOptNullInteger = class(TOptionalNullable<Integer>,
    IOptInteger, INullInteger, IOptNullInteger)
  type
    TCache = TClockCache<Integer, IOptNullInteger>;
  private
    const FIXED_CACHE_MIN = -1;
    const FIXED_CACHE_MAX = 20;
    const CACHE_SIZE = 2000;
    class var FGlobalNull: IOptNullInteger;
    class var FGlobalUndefined: IOptNullInteger;
    class var FGlobalCacheFixed: array[FIXED_CACHE_MIN..FIXED_CACHE_MAX] of IOptNullInteger;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullInteger; static;
    class function Undefined: TOptNullInteger; static;
    class function From(AValue: Integer): TOptNullInteger; static;
    class function SafeNullable(AValue: INullInteger): INullInteger; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptional(AValue: IOptInteger): IOptInteger; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptNull(AValue: IOptNullInteger): IOptNullInteger; deprecated 'Use TOptionals.Safe instead'; static;
  end;

  { TOptNullInt64 }

  TOptNullInt64 = class(TOptionalNullable<Int64>,
    IOptInt64, INullInt64, IOptNullInt64)
  type
    TCache = TClockCache<Int64, IOptNullInt64>;
  private
    const FIXED_CACHE_MIN = -1;
    const FIXED_CACHE_MAX = 20;
    const CACHE_SIZE = 100;
    class var FGlobalNull: IOptNullInt64;
    class var FGlobalUndefined: IOptNullInt64;
    class var FGlobalCacheFixed: array[FIXED_CACHE_MIN..FIXED_CACHE_MAX] of IOptNullInt64;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullInt64; static;
    class function Undefined: TOptNullInt64; static;
    class function From(AValue: Int64): TOptNullInt64; static;
    class function SafeNullable(AValue: INullInt64): INullInt64; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptional(AValue: IOptInt64): IOptInt64; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptNull(AValue: IOptNullInt64): IOptNullInt64; deprecated 'Use TOptionals.Safe instead'; static;
  end;

  { TOptNullSingle }

  TOptNullSingle = class(TOptionalNullable<Single>,
    IOptSingle, INullSingle, IOptNullSingle, IDecimalPrecision)
  type
    TCacheKey = record
      Value: Single;
      Precision: Integer;
      class operator Equal(const A, B: TCacheKey): Boolean;
    end;
    TCache = TClockCache<TCacheKey, IOptNullSingle>;
  private
    FDecimalPlaces: Integer;
  public
    constructor Create(AValue: Single; ADecimalPlaces: Integer); overload;
    function GetDecimalPlaces: Integer;
  private
    const CACHE_SIZE = 2000;
    class var FGlobalNull: IOptNullSingle;
    class var FGlobalUndefined: IOptNullSingle;
    class var FGlobalZero: IOptNullSingle;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullSingle; static;
    class function Undefined: TOptNullSingle; static;
    class function From(AValue: Single; ADecimalPlaces: Integer=-1): TOptNullSingle; static;
    class function SafeNullable(AValue: INullSingle): INullSingle; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptional(AValue: IOptSingle): IOptSingle; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptNull(AValue: IOptNullSingle): IOptNullSingle; deprecated 'Use TOptionals.Safe instead'; static;
  end;

  { TOptNullDouble }

  TOptNullDouble = class(TOptionalNullable<Double>,
    IOptDouble, INullDouble, IOptNullDouble, IDecimalPrecision)
  type
    TCacheKey = record
      Value: Double;
      Precision: Integer;
      class operator Equal(const A, B: TCacheKey): Boolean;
    end;
    TCache = TClockCache<TCacheKey, IOptNullDouble>;
  private
    FDecimalPlaces: Integer;
  public
    constructor Create(AValue: Double; ADecimalPlaces: Integer); overload;
    function GetDecimalPlaces: Integer;
  private
    const CACHE_SIZE = 2000;
    class var FGlobalNull: IOptNullDouble;
    class var FGlobalUndefined: IOptNullDouble;
    class var FGlobalZero: IOptNullDouble;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullDouble; static;
    class function Undefined: TOptNullDouble; static;
    class function From(AValue: Double; ADecimalPlaces: Integer=-1): TOptNullDouble; static;
    class function SafeNullable(AValue: INullDouble): INullDouble; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptional(AValue: IOptDouble): IOptDouble; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptNull(AValue: IOptNullDouble): IOptNullDouble; deprecated 'Use TOptionals.Safe instead'; static;
  end;

  { TOptNullDateTime }

  TOptNullDateTime = class(TOptionalNullable<TDateTime>,
    IOptDateTime, INullDateTime, IOptNullDateTime)
  type
    TCache = TClockCache<TDateTime, IOptNullDateTime>;
  private
    const CACHE_SIZE_DATE = 500;
    const CACHE_SIZE_TIME = 1000;
    class var FGlobalNull: IOptNullDateTime;
    class var FGlobalUndefined: IOptNullDateTime;
    class var FGlobalCacheDate: TCache;
    class var FLockCacheDate: TCriticalSection;
    class var FGlobalCacheTime: TCache;
    class var FLockCacheTime: TCriticalSection;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullDateTime; static;
    class function Undefined: TOptNullDateTime; static;
    class function From(AValue: TDateTime): TOptNullDateTime; static;
    class function SafeNullable(AValue: INullDateTime): INullDateTime; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptional(AValue: IOptDateTime): IOptDateTime; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptNull(AValue: IOptNullDateTime): IOptNullDateTime; deprecated 'Use TOptionals.Safe instead'; static;
  end;

  { TOptNullBoolean }

  TOptNullBoolean = class(TOptionalNullable<Boolean>,
    IOptBoolean, INullBoolean, IOptNullBoolean)
  private
    class var FGlobalNull: IOptNullBoolean;
    class var FGlobalUndefined: IOptNullBoolean;
    class var FGlobalTrue: IOptNullBoolean;
    class var FGlobalFalse: IOptNullBoolean;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullBoolean; static;
    class function Undefined: TOptNullBoolean; static;
    class function TrueValue: TOptNullBoolean; static;
    class function FalseValue: TOptNullBoolean; static;
    class function From(AValue: Boolean): IOptNullBoolean; static;
    class function SafeNullable(AValue: INullBoolean): INullBoolean; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptional(AValue: IOptBoolean): IOptBoolean; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptNull(AValue: IOptNullBoolean): IOptNullBoolean; deprecated 'Use TOptionals.Safe instead'; static;
  end;

  { TOptNullGuid }

  TOptNullGuid = class(TOptionalNullable<TGUID>,
    IOptGuid, INullGuid, IOptNullGuid)
  type
    TCache = TClockCache<TGUID, IOptNullGuid>;
  private
    const CACHE_SIZE = 100;
    class var FGlobalNull: IOptNullGuid;
    class var FGlobalUndefined: IOptNullGuid;
    class var FGlobalEmpty: IOptNullGuid;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullGuid; static;
    class function Undefined: TOptNullGuid; static;
    class function From(AValue: TGUID): TOptNullGuid; static;
    class function SafeNullable(AValue: INullGuid): INullGuid; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptional(AValue: IOptGuid): IOptGuid; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptNull(AValue: IOptNullGuid): IOptNullGuid; deprecated 'Use TOptionals.Safe instead'; static;
  end;

  { TOptNullCurrency }

  TOptNullCurrency = class(TOptionalNullable<Currency>,
    IOptCurrency, INullCurrency, IOptNullCurrency)
  type
    TCache = TClockCache<Currency, IOptNullCurrency>;
  private
    const CACHE_SIZE = 500;
    class var FGlobalNull: IOptNullCurrency;
    class var FGlobalUndefined: IOptNullCurrency;
    class var FGlobalZero: IOptNullCurrency;
    class var FGlobalCache: TCache;
    class var FLockCache: TCriticalSection;
  public
    class constructor Create;
    class destructor Destroy;
    class function Null: TOptNullCurrency; static;
    class function Undefined: TOptNullCurrency; static;
    class function From(AValue: Currency): TOptNullCurrency; static;
    class function SafeNullable(AValue: INullCurrency): INullCurrency; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptional(AValue: IOptCurrency): IOptCurrency; deprecated 'Use TOptionals.Safe instead'; static;
    class function SafeOptNull(AValue: IOptNullCurrency): IOptNullCurrency; deprecated 'Use TOptionals.Safe instead'; static;
  end;

implementation

const
  // TGuid.Empty comes from Delphi's TGuidHelper record helper, which doesn't
  // exist in FPC 3.2.2 — a typed constant works on both.
  EMPTY_GUID: TGUID = '{00000000-0000-0000-0000-000000000000}';

{ Comparers for the TOptNullSingle/TOptNullDouble cache keys.

  Named functions instead of closures: TEqualityComparer<T>.Construct accepts
  "reference to function" in Delphi, but FPC 3.2.2 only accepts a plain
  function pointer or "of object" (there are no anonymous functions in the
  stable compiler). A named function is accepted by both. The signature
  differs too: FPC's rtl-generics declares IEqualityComparer<T> with
  "constref" and a UInt32 hash; Delphi uses "const" and an Integer hash. }

function SingleKeyEquals({$IFDEF FPC}constref{$ELSE}const{$ENDIF} L, R: TOptNullSingle.TCacheKey): Boolean;
begin
  Result := (L.Value = R.Value) and (L.Precision = R.Precision);
end;

function SingleKeyHash({$IFDEF FPC}constref{$ELSE}const{$ENDIF} V: TOptNullSingle.TCacheKey): {$IFDEF FPC}UInt32{$ELSE}Integer{$ENDIF};
var
  LHash: Integer;
begin
  LHash := BobJenkinsHash(V.Value, SizeOf(Single), 0);
  LHash := BobJenkinsHash(V.Precision, SizeOf(Integer), LHash);
  Result := {$IFDEF FPC}UInt32(LHash){$ELSE}LHash{$ENDIF};
end;

function DoubleKeyEquals({$IFDEF FPC}constref{$ELSE}const{$ENDIF} L, R: TOptNullDouble.TCacheKey): Boolean;
begin
  Result := (L.Value = R.Value) and (L.Precision = R.Precision);
end;

function DoubleKeyHash({$IFDEF FPC}constref{$ELSE}const{$ENDIF} V: TOptNullDouble.TCacheKey): {$IFDEF FPC}UInt32{$ELSE}Integer{$ENDIF};
var
  LHash: Integer;
begin
  LHash := BobJenkinsHash(V.Value, SizeOf(Double), 0);
  LHash := BobJenkinsHash(V.Precision, SizeOf(Integer), LHash);
  Result := {$IFDEF FPC}UInt32(LHash){$ELSE}LHash{$ENDIF};
end;

{ TOptionals }

class function TOptionals.Safe(const AValue: IOptString): IOptString;
begin
  Result := TOptNullString.SafeOptional(AValue);
end;

class function TOptionals.Safe(const AValue: INullString): INullString;
begin
  Result := TOptNullString.SafeNullable(AValue);
end;

class function TOptionals.Safe(const AValue: IOptNullString): IOptNullString;
begin
  Result := TOptNullString.SafeOptNull(AValue);
end;

class function TOptionals.Safe(const AValue: IOptInteger): IOptInteger;
begin
  Result := TOptNullInteger.SafeOptional(AValue);
end;

class function TOptionals.Safe(const AValue: INullInteger): INullInteger;
begin
  Result := TOptNullInteger.SafeNullable(AValue);
end;

class function TOptionals.Safe(const AValue: IOptNullInteger): IOptNullInteger;
begin
  Result := TOptNullInteger.SafeOptNull(AValue);
end;

class function TOptionals.Safe(const AValue: IOptInt64): IOptInt64;
begin
  Result := TOptNullInt64.SafeOptional(AValue);
end;

class function TOptionals.Safe(const AValue: INullInt64): INullInt64;
begin
  Result := TOptNullInt64.SafeNullable(AValue);
end;

class function TOptionals.Safe(const AValue: IOptNullInt64): IOptNullInt64;
begin
  Result := TOptNullInt64.SafeOptNull(AValue);
end;

class function TOptionals.Safe(const AValue: IOptSingle): IOptSingle;
begin
  Result := TOptNullSingle.SafeOptional(AValue);
end;

class function TOptionals.Safe(const AValue: INullSingle): INullSingle;
begin
  Result := TOptNullSingle.SafeNullable(AValue);
end;

class function TOptionals.Safe(const AValue: IOptNullSingle): IOptNullSingle;
begin
  Result := TOptNullSingle.SafeOptNull(AValue);
end;

class function TOptionals.Safe(const AValue: IOptDouble): IOptDouble;
begin
  Result := TOptNullDouble.SafeOptional(AValue);
end;

class function TOptionals.Safe(const AValue: INullDouble): INullDouble;
begin
  Result := TOptNullDouble.SafeNullable(AValue);
end;

class function TOptionals.Safe(const AValue: IOptNullDouble): IOptNullDouble;
begin
  Result := TOptNullDouble.SafeOptNull(AValue);
end;

class function TOptionals.Safe(const AValue: IOptDateTime): IOptDateTime;
begin
  Result := TOptNullDateTime.SafeOptional(AValue);
end;

class function TOptionals.Safe(const AValue: INullDateTime): INullDateTime;
begin
  Result := TOptNullDateTime.SafeNullable(AValue);
end;

class function TOptionals.Safe(const AValue: IOptNullDateTime): IOptNullDateTime;
begin
  Result := TOptNullDateTime.SafeOptNull(AValue);
end;

class function TOptionals.Safe(const AValue: IOptBoolean): IOptBoolean;
begin
  Result := TOptNullBoolean.SafeOptional(AValue);
end;

class function TOptionals.Safe(const AValue: INullBoolean): INullBoolean;
begin
  Result := TOptNullBoolean.SafeNullable(AValue);
end;

class function TOptionals.Safe(const AValue: IOptNullBoolean): IOptNullBoolean;
begin
  Result := TOptNullBoolean.SafeOptNull(AValue);
end;

class function TOptionals.Safe(const AValue: IOptGuid): IOptGuid;
begin
  Result := TOptNullGuid.SafeOptional(AValue);
end;

class function TOptionals.Safe(const AValue: INullGuid): INullGuid;
begin
  Result := TOptNullGuid.SafeNullable(AValue);
end;

class function TOptionals.Safe(const AValue: IOptNullGuid): IOptNullGuid;
begin
  Result := TOptNullGuid.SafeOptNull(AValue);
end;

class function TOptionals.Safe(const AValue: IOptCurrency): IOptCurrency;
begin
  Result := TOptNullCurrency.SafeOptional(AValue);
end;

class function TOptionals.Safe(const AValue: INullCurrency): INullCurrency;
begin
  Result := TOptNullCurrency.SafeNullable(AValue);
end;

class function TOptionals.Safe(const AValue: IOptNullCurrency): IOptNullCurrency;
begin
  Result := TOptNullCurrency.SafeOptNull(AValue);
end;

{ TOptionalNullableBase }

constructor TOptionalNullableBase.Create;
begin
  FHasValue := False;
  FIsNull := False;
end;

constructor TOptionalNullableBase.CreateNull;
begin
  FHasValue := True;
  FIsNull := True;
end;

function TOptionalNullableBase.IsNull: Boolean;
begin
  Result := FIsNull;
end;

function TOptionalNullableBase.HasValue: Boolean;
begin
  Result := FHasValue;
end;

{ TOptionalNullable<T> }

constructor TOptionalNullable<T>.Create(AValue: T);
begin
  inherited Create;
  FValue := AValue;
  FIsNull := False;
  FHasValue := True;
end;

function TOptionalNullable<T>.GetValue: T;
begin
  Result := FValue;
end;

{ TOptNullString }

class destructor TOptNullString.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalEmpty := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullString.Create;
begin
  FGlobalNull := TOptNullString.CreateNull;
  FGlobalUndefined := TOptNullString.Create;
  FGlobalEmpty := TOptNullString.Create(EmptyStr);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullString.Null: TOptNullString;
begin
  Result := FGlobalNull as TOptNullString;
end;

class function TOptNullString.Undefined: TOptNullString;
begin
  Result := FGlobalUndefined as TOptNullString;
end;

class function TOptNullString.From(AValue: string): TOptNullString;
var
  Obj: IOptNullString;
begin
  if AValue = EmptyStr then
    Exit(FGlobalEmpty as TOptNullString);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullString.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullString;
end;

class function TOptNullString.SafeNullable(AValue: INullString): INullString;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullString.Null;
end;

class function TOptNullString.SafeOptional(AValue: IOptString): IOptString;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullString.Undefined;
end;

class function TOptNullString.SafeOptNull(AValue: IOptNullString): IOptNullString;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullString.Undefined;
end;

{ TOptNullInteger }

class destructor TOptNullInteger.Destroy;
var
  I: Integer;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  for I := FIXED_CACHE_MIN to FIXED_CACHE_MAX do
    FGlobalCacheFixed[I] := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullInteger.Create;
var
  I: Integer;
begin
  FGlobalNull := TOptNullInteger.CreateNull;
  FGlobalUndefined := TOptNullInteger.Create;
  for I := FIXED_CACHE_MIN to FIXED_CACHE_MAX do
    FGlobalCacheFixed[I] := TOptNullInteger.Create(I);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullInteger.Null: TOptNullInteger;
begin
  Result := FGlobalNull as TOptNullInteger;
end;

class function TOptNullInteger.Undefined: TOptNullInteger;
begin
  Result := FGlobalUndefined as TOptNullInteger;
end;

class function TOptNullInteger.From(AValue: Integer): TOptNullInteger;
var
  Obj: IOptNullInteger;
begin
  if (AValue >= FIXED_CACHE_MIN) and (AValue <= FIXED_CACHE_MAX) then
    Exit(FGlobalCacheFixed[AValue] as TOptNullInteger);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullInteger.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullInteger;
end;

class function TOptNullInteger.SafeNullable(AValue: INullInteger): INullInteger;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInteger.Null;
end;

class function TOptNullInteger.SafeOptional(AValue: IOptInteger): IOptInteger;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInteger.Undefined;
end;

class function TOptNullInteger.SafeOptNull(AValue: IOptNullInteger): IOptNullInteger;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInteger.Undefined;
end;

{ TOptNullInt64 }

class constructor TOptNullInt64.Create;
var
  I: Integer;
begin
  FGlobalNull := TOptNullInt64.CreateNull;
  FGlobalUndefined := TOptNullInt64.Create;
  for I := FIXED_CACHE_MIN to FIXED_CACHE_MAX do
    FGlobalCacheFixed[I] := TOptNullInt64.Create(I);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class destructor TOptNullInt64.Destroy;
var
  I: Integer;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  for I := FIXED_CACHE_MIN to FIXED_CACHE_MAX do
    FGlobalCacheFixed[I] := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class function TOptNullInt64.Null: TOptNullInt64;
begin
  Result := FGlobalNull as TOptNullInt64;
end;

class function TOptNullInt64.Undefined: TOptNullInt64;
begin
  Result := FGlobalUndefined as TOptNullInt64;
end;

class function TOptNullInt64.From(AValue: Int64): TOptNullInt64;
var
  Obj: IOptNullInt64;
begin
  if (AValue >= FIXED_CACHE_MIN) and (AValue <= FIXED_CACHE_MAX) then
    Exit(FGlobalCacheFixed[AValue] as TOptNullInt64);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullInt64.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullInt64;
end;

class function TOptNullInt64.SafeNullable(AValue: INullInt64): INullInt64;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInt64.Null;
end;

class function TOptNullInt64.SafeOptional(AValue: IOptInt64): IOptInt64;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInt64.Undefined;
end;

class function TOptNullInt64.SafeOptNull(AValue: IOptNullInt64): IOptNullInt64;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullInt64.Undefined;
end;

{ TOptNullSingle }

class operator TOptNullSingle.TCacheKey.Equal(const A, B: TCacheKey): Boolean;
begin
  Result := (A.Value = B.Value) and (A.Precision = B.Precision);
end;

constructor TOptNullSingle.Create(AValue: Single; ADecimalPlaces: Integer);
begin
  inherited Create(AValue);
  FDecimalPlaces := ADecimalPlaces;
end;

function TOptNullSingle.GetDecimalPlaces: Integer;
begin
  Result := FDecimalPlaces;
end;

class destructor TOptNullSingle.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalZero := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullSingle.Create;
begin
  FGlobalNull := TOptNullSingle.CreateNull;
  FGlobalUndefined := TOptNullSingle.Create;
  FGlobalZero := TOptNullSingle.Create(0.0, -1);
  FGlobalCache := TCache.Create(CACHE_SIZE, 3,
    TEqualityComparer<TCacheKey>.Construct(SingleKeyEquals, SingleKeyHash));
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullSingle.Null: TOptNullSingle;
begin
  Result := FGlobalNull as TOptNullSingle;
end;

class function TOptNullSingle.Undefined: TOptNullSingle;
begin
  Result := FGlobalUndefined as TOptNullSingle;
end;

class function TOptNullSingle.From(AValue: Single; ADecimalPlaces: Integer): TOptNullSingle;
var
  Obj: IOptNullSingle;
  Key: TCacheKey;
begin
  if AValue = 0.0 then
    Exit(FGlobalZero as TOptNullSingle);

  FillChar(Key, SizeOf(Key), 0);
  Key.Value := AValue;
  Key.Precision := ADecimalPlaces;

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(Key, Obj) then
    begin
      Obj := TOptNullSingle.Create(AValue, ADecimalPlaces);
      FGlobalCache.Put(Key, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullSingle;
end;

class function TOptNullSingle.SafeNullable(AValue: INullSingle): INullSingle;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullSingle.Null;
end;

class function TOptNullSingle.SafeOptional(AValue: IOptSingle): IOptSingle;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullSingle.Undefined;
end;

class function TOptNullSingle.SafeOptNull(AValue: IOptNullSingle): IOptNullSingle;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullSingle.Undefined;
end;

{ TOptNullDouble }

class operator TOptNullDouble.TCacheKey.Equal(const A, B: TCacheKey): Boolean;
begin
  Result := (A.Value = B.Value) and (A.Precision = B.Precision);
end;

constructor TOptNullDouble.Create(AValue: Double; ADecimalPlaces: Integer);
begin
  inherited Create(AValue);
  FDecimalPlaces := ADecimalPlaces;
end;

function TOptNullDouble.GetDecimalPlaces: Integer;
begin
  Result := FDecimalPlaces;
end;

class destructor TOptNullDouble.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalZero := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullDouble.Create;
begin
  FGlobalNull := TOptNullDouble.CreateNull;
  FGlobalUndefined := TOptNullDouble.Create;
  FGlobalZero := TOptNullDouble.Create(0.0, -1);
  FGlobalCache := TCache.Create(CACHE_SIZE, 3,
    TEqualityComparer<TCacheKey>.Construct(DoubleKeyEquals, DoubleKeyHash));
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullDouble.Null: TOptNullDouble;
begin
  Result := FGlobalNull as TOptNullDouble;
end;

class function TOptNullDouble.Undefined: TOptNullDouble;
begin
  Result := FGlobalUndefined as TOptNullDouble;
end;

class function TOptNullDouble.From(AValue: Double; ADecimalPlaces: Integer): TOptNullDouble;
var
  Obj: IOptNullDouble;
  Key: TCacheKey;
begin
  if AValue = 0.0 then
    Exit(FGlobalZero as TOptNullDouble);

  Key.Value := AValue;
  Key.Precision := ADecimalPlaces;

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(Key, Obj) then
    begin
      Obj := TOptNullDouble.Create(AValue, ADecimalPlaces);
      FGlobalCache.Put(Key, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullDouble;
end;

class function TOptNullDouble.SafeNullable(AValue: INullDouble): INullDouble;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDouble.Null;
end;

class function TOptNullDouble.SafeOptional(AValue: IOptDouble): IOptDouble;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDouble.Undefined;
end;

class function TOptNullDouble.SafeOptNull(AValue: IOptNullDouble): IOptNullDouble;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDouble.Undefined;
end;

{ TOptNullDateTime }

class destructor TOptNullDateTime.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalCacheDate.Free;
  FLockCacheDate.Free;
  FGlobalCacheTime.Free;
  FLockCacheTime.Free;
end;

class constructor TOptNullDateTime.Create;
begin
  FGlobalNull := TOptNullDateTime.CreateNull;
  FGlobalUndefined := TOptNullDateTime.Create;
  FGlobalCacheDate := TCache.Create(CACHE_SIZE_DATE, 5);
  FLockCacheDate := TCriticalSection.Create;
  FGlobalCacheTime := TCache.Create(CACHE_SIZE_TIME, 2);
  FLockCacheTime := TCriticalSection.Create;
end;

class function TOptNullDateTime.Null: TOptNullDateTime;
begin
  Result := FGlobalNull as TOptNullDateTime;
end;

class function TOptNullDateTime.Undefined: TOptNullDateTime;
begin
  Result := FGlobalUndefined as TOptNullDateTime;
end;

class function TOptNullDateTime.From(AValue: TDateTime): TOptNullDateTime;
var
  OnlyDate: Double;

  function GetFromCache(ACache: TCache; FLock: TCriticalSection): TOptNullDateTime;
  var
    Obj: IOptNullDateTime;
  begin
    FLock.Enter;
    try
      if not ACache.Get(AValue, Obj) then
      begin
        Obj := TOptNullDateTime.Create(AValue);
        ACache.Put(AValue, Obj);
      end;
    finally
      FLock.Leave;
    end;

    Result := Obj as TOptNullDateTime;
  end;

begin
  OnlyDate := Trunc(AValue);

  // separate cache strategies for date-only and date-and-time values
  if OnlyDate = AValue then
    Result := GetFromCache(FGlobalCacheDate, FLockCacheDate)
  else
    Result := GetFromCache(FGlobalCacheTime, FLockCacheTime);
end;

class function TOptNullDateTime.SafeNullable(AValue: INullDateTime): INullDateTime;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDateTime.Null;
end;

class function TOptNullDateTime.SafeOptional(AValue: IOptDateTime): IOptDateTime;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDateTime.Undefined;
end;

class function TOptNullDateTime.SafeOptNull(AValue: IOptNullDateTime): IOptNullDateTime;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullDateTime.Undefined;
end;

{ TOptNullBoolean }

class destructor TOptNullBoolean.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalTrue := nil;
  FGlobalFalse := nil;
end;

class constructor TOptNullBoolean.Create;
begin
  FGlobalNull := TOptNullBoolean.CreateNull;
  FGlobalUndefined := TOptNullBoolean.Create;
  FGlobalTrue := TOptNullBoolean.Create(True);
  FGlobalFalse := TOptNullBoolean.Create(False);
end;

class function TOptNullBoolean.Null: TOptNullBoolean;
begin
  Result := FGlobalNull as TOptNullBoolean;
end;

class function TOptNullBoolean.Undefined: TOptNullBoolean;
begin
  Result := FGlobalUndefined as TOptNullBoolean;
end;

class function TOptNullBoolean.SafeNullable(AValue: INullBoolean): INullBoolean;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullBoolean.Null;
end;

class function TOptNullBoolean.SafeOptional(AValue: IOptBoolean): IOptBoolean;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullBoolean.Undefined;
end;

class function TOptNullBoolean.SafeOptNull(AValue: IOptNullBoolean): IOptNullBoolean;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullBoolean.Undefined;
end;

class function TOptNullBoolean.TrueValue: TOptNullBoolean;
begin
  Result := FGlobalTrue as TOptNullBoolean;
end;

class function TOptNullBoolean.FalseValue: TOptNullBoolean;
begin
  Result := FGlobalFalse as TOptNullBoolean;
end;

class function TOptNullBoolean.From(AValue: Boolean): IOptNullBoolean;
begin
  if AValue then
    Result := TrueValue
  else
    Result := FalseValue;
end;

{ TOptNullGuid }

class destructor TOptNullGuid.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalEmpty := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullGuid.Create;
begin
  FGlobalNull := TOptNullGuid.CreateNull;
  FGlobalUndefined := TOptNullGuid.Create;
  FGlobalEmpty := TOptNullGuid.Create(EMPTY_GUID);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullGuid.Null: TOptNullGuid;
begin
  Result := FGlobalNull as TOptNullGuid;
end;

class function TOptNullGuid.Undefined: TOptNullGuid;
begin
  Result := FGlobalUndefined as TOptNullGuid;
end;

class function TOptNullGuid.From(AValue: TGUID): TOptNullGuid;
var
  Obj: IOptNullGuid;
begin
  if IsEqualGUID(AValue, EMPTY_GUID) then
    Exit(FGlobalEmpty as TOptNullGuid);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullGuid.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullGuid;
end;

class function TOptNullGuid.SafeNullable(AValue: INullGuid): INullGuid;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullGuid.Null;
end;

class function TOptNullGuid.SafeOptional(AValue: IOptGuid): IOptGuid;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullGuid.Undefined;
end;

class function TOptNullGuid.SafeOptNull(AValue: IOptNullGuid): IOptNullGuid;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullGuid.Undefined;
end;

{ TOptNullCurrency }

class destructor TOptNullCurrency.Destroy;
begin
  FGlobalNull := nil;
  FGlobalUndefined := nil;
  FGlobalZero := nil;
  FGlobalCache.Free;
  FLockCache.Free;
end;

class constructor TOptNullCurrency.Create;
begin
  FGlobalNull := TOptNullCurrency.CreateNull;
  FGlobalUndefined := TOptNullCurrency.Create;
  FGlobalZero := TOptNullCurrency.Create(0.0);
  FGlobalCache := TCache.Create(CACHE_SIZE, 5);
  FLockCache := TCriticalSection.Create;
end;

class function TOptNullCurrency.Null: TOptNullCurrency;
begin
  Result := FGlobalNull as TOptNullCurrency;
end;

class function TOptNullCurrency.Undefined: TOptNullCurrency;
begin
  Result := FGlobalUndefined as TOptNullCurrency;
end;

class function TOptNullCurrency.From(AValue: Currency): TOptNullCurrency;
var
  Obj: IOptNullCurrency;
begin
  if AValue = 0.0 then
    Exit(FGlobalZero as TOptNullCurrency);

  FLockCache.Enter;
  try
    if not FGlobalCache.Get(AValue, Obj) then
    begin
      Obj := TOptNullCurrency.Create(AValue);
      FGlobalCache.Put(AValue, Obj);
    end;
  finally
    FLockCache.Leave;
  end;

  Result := Obj as TOptNullCurrency;
end;

class function TOptNullCurrency.SafeNullable(AValue: INullCurrency): INullCurrency;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullCurrency.Null;
end;

class function TOptNullCurrency.SafeOptional(AValue: IOptCurrency): IOptCurrency;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullCurrency.Undefined;
end;

class function TOptNullCurrency.SafeOptNull(AValue: IOptNullCurrency): IOptNullCurrency;
begin
  if Assigned(AValue) then
    Result := AValue
  else
    Result := TOptNullCurrency.Undefined;
end;

end.
