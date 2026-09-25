unit PascalDb.ClockCache;

{$I pascaldb.inc}

{ Generic flyweight cache (TClockCache<K, V>), thread-safe and with
  predictable latency, meant for processes that run nonstop. It backs the
  instance cache of the optional types (PascalDb.Optionals).

  Eviction is a "hybrid G-Clock with amortized victim search", instead of LRU
  (expensive under concurrency) or FIFO (inefficient):

  - Single sweep: with the cache full, Put makes at most ONE full turn around
    the ring of slots (FCapacity), so latency is constant and predictable
    (O(N)).
  - Lives: each item has a counter. Get/Update increment it (reward for
    frequency, up to AMaxLives); the eviction sweep decrements it (penalty
    for idleness).
  - Victim: during the sweep, it looks for an item with 0 lives. If none is
    found, it sacrifices the one with the lowest count seen during the sweep.
  - Admission (AdmissionPolicy): apAlwaysAdmit always admits the new item,
    replacing the least "hot" one even if it still has lives;
    apProtectHotItems only admits it if some item is already at 0 lives.

  Fixed memory, set in Create (pre-allocated slots, no fragmentation), with
  values designed to be interfaces (reference counted). TCacheHitRate tracks
  hits/misses to monitor efficiency in production.

  Dual-compiler: the constructor's optional comparer is never forwarded to
  TDictionary as nil (FPC 3.2.2's stores the nil and raises an Access
  Violation; Delphi's replaces it with Default), and the counters use
  PascalDb.Threading instead of TInterlocked, which doesn't exist in FPC. }

interface

uses
  Classes, SysUtils, Generics.Collections, PascalDb.SystemContext, 
  SyncObjs, Math, Generics.Defaults, PascalDb.Threading;

type
  TClockItem<K, V> = record
    Key: K;
    Value: V;
    Lives: Integer;     // Frequency counter (G-Clock)
    InUse: Boolean;
  end;

  TCacheStats = record
    Hits: Int64;
    Misses: Int64;
    Efficiency: Double;
    BeginTime: TDateTime;
    EndTime: TDateTime;
    Uptime: TDateTime;
  end;

  { TCacheHitRate }

  TCacheHitRate = class
  private
    FHits: Int64;
    FMisses: Int64;
    FStartTime: TDateTime;
    FStopTime: TDateTime;
    FActive: Boolean;
    procedure SetStartTime(AValue: TDateTime);
  public
    constructor Create;
    procedure Start;
    procedure Stop;
    procedure IncHits;
    procedure IncMisses;
    function GetCacheStats: TCacheStats;
    property Hits: Int64 read FHits;
    property Misses: Int64 read FMisses;
    property StartTime: TDateTime read FStartTime write SetStartTime;
  end;

  TAdmissionPolicy = (apAlwaysAdmit, apProtectHotItems);

  { TClockCache }

  TClockCache<K, V> = class
  type
    TItem = TClockItem<K, V>;
    TMap = TDictionary<K, Integer>; // Maps Key -> index in the array
    TRemoveEvent = procedure(var AValue: V) of object;
  private
    FItems: array of TItem;
    FAdmissionPolicy: TAdmissionPolicy;
    FMap: TMap;
    FCapacity: Integer;
    FHand: Integer;
    FOnRemoveItem: TRemoveEvent;
    FMaxLives: Byte;
    FCacheHitRate: TCacheHitRate;
    FLock: TMultiReadExclusiveWriteSynchronizer;
    function Evict: Boolean;
    procedure Eject;
  public
    constructor Create(ACapacity: Integer; AMaxLives: Byte = 3; const AComparer: IEqualityComparer<K> = nil);
    destructor Destroy; override;
    procedure Put(const AKey: K; const AValue: V; AInitialLives: Byte = 1);
    function Get(const AKey: K; out AValue: V): Boolean;
    property OnRemoveItem: TRemoveEvent read FOnRemoveItem write FOnRemoveItem;
    property CacheHitRate: TCacheHitRate read FCacheHitRate;
    property AdmissionPolicy: TAdmissionPolicy read FAdmissionPolicy write FAdmissionPolicy;
  end;

implementation

{ TCacheHitRate }

procedure TCacheHitRate.SetStartTime(AValue: TDateTime);
begin
  if FStartTime = AValue then Exit;
  FStartTime := AValue;
end;

constructor TCacheHitRate.Create;
begin
  FActive := False;
end;

procedure TCacheHitRate.Start;
begin
  if FActive then Exit;
  FHits := 0;
  FMisses := 0;
  FActive := True;
  FStartTime := TClock.Now;
end;

procedure TCacheHitRate.Stop;
begin
  if not FActive then Exit;
  FActive := False;
  FStopTime := TClock.Now;
end;

procedure TCacheHitRate.IncHits;
begin
  if not FActive then Exit;
  PdbAtomicInc64(FHits);
end;

procedure TCacheHitRate.IncMisses;
begin
  if not FActive then Exit;
  PdbAtomicInc64(FMisses);
end;

function TCacheHitRate.GetCacheStats: TCacheStats;
var
  Total: Int64;
begin
  Result.Hits := FHits;
  Result.Misses := FMisses;

  Total := FHits + FMisses;

  if Total > 0 then
    Result.Efficiency := (FHits / Total) * 100
  else
    Result.Efficiency := 0;

  Result.BeginTime := FStartTime;

  if FActive then
    Result.EndTime := TClock.Now
  else
    Result.EndTime := FStopTime;

  Result.Uptime := Result.EndTime - Result.BeginTime;
end;

{ TClockCache }

constructor TClockCache<K, V>.Create(ACapacity: Integer; AMaxLives: Byte; const AComparer: IEqualityComparer<K>);
begin
  FAdmissionPolicy := apAlwaysAdmit;
  FCacheHitRate := TCacheHitRate.Create;
  FMaxLives := AMaxLives;
  if FMaxLives <= 0 then
    FMaxLives := 1;
  FCapacity := ACapacity;
  SetLength(FItems, FCapacity);
  // Never forward AComparer = nil: Delphi's TDictionary replaces nil with the
  // default comparer, but FPC 3.2.2's (rtl-generics) stores the nil and
  // raises an Access Violation on the first Add/TryGetValue (GetHashCode on
  // nil).
  if Assigned(AComparer) then
    FMap := TMap.Create(AComparer)
  else
    FMap := TMap.Create;
  FLock := TMultiReadExclusiveWriteSynchronizer.Create;
  FHand := 0;
end;

destructor TClockCache<K, V>.Destroy;
var
  I: Integer;
begin
  FLock.Free;
  FMap.Free;
  FCacheHitRate.Free;
  for I := 0 to FCapacity - 1 do
  begin
    FItems[I].Value := Default(V);
    FItems[I].Key := Default(K);
  end;
  inherited;
end;

function TClockCache<K, V>.Evict: Boolean;
var
  WeakestIdx: Integer;
  MinLives: Integer;
  I: Integer;
begin
  WeakestIdx := FHand;
  MinLives := High(Integer);

  for I := 1 to FCapacity do
  begin
    // 1. The cache still has unused slots
    if not FItems[FHand].InUse then
      Exit(True);

    // 2. Did we already find one that died naturally?
    if FItems[FHand].Lives = 0 then
    begin
      Eject;
      Exit(True);
    end;

    // 3. Otherwise, track the weakest one in this sweep
    if FItems[FHand].Lives < MinLives then
    begin
      MinLives := FItems[FHand].Lives;
      WeakestIdx := FHand;
    end;

    Dec(FItems[FHand].Lives);  // Second chance: remove the mark
    FHand := (FHand + 1) mod FCapacity;
  end;

  if FAdmissionPolicy = apProtectHotItems then
  begin
    if MinLives > 1 then
      Exit(False);
  end;

  FHand := WeakestIdx; // position the hand
  Eject;
  Result := True;
end;

procedure TClockCache<K, V>.Eject;
begin
  FMap.Remove(FItems[FHand].Key);

  if Assigned(OnRemoveItem) then
    OnRemoveItem(FItems[FHand].Value);

  FItems[FHand].Value := Default(V);
  FItems[FHand].Key := Default(K);
  FItems[FHand].InUse := False;
end;

procedure TClockCache<K, V>.Put(const AKey: K; const AValue: V; AInitialLives: Byte);
var
  Idx: Integer;
begin
  FLock.BeginWrite;
  try
    if FMap.TryGetValue(AKey, Idx) then
    begin
      FItems[Idx].Value := AValue;
      FItems[Idx].Lives := Math.Min(FMaxLives, FItems[Idx].Lives + AInitialLives);
      Exit;
    end;

    CacheHitRate.IncMisses;

    if FMap.Count >= FCapacity then
      if not Evict then
        Exit;

    // Evict stopped at the FHand that must be used.
    FItems[FHand].Key := AKey;
    FItems[FHand].Value := AValue;
    FItems[FHand].Lives := Math.Min(FMaxLives, AInitialLives);
    FItems[FHand].InUse := True;

    FMap.AddOrSetValue(AKey, FHand);

    // Advance the hand AFTER the insertion into the map has completed
    FHand := (FHand + 1) mod FCapacity;
  finally
    FLock.EndWrite;
  end;
end;

function TClockCache<K, V>.Get(const AKey: K; out AValue: V): Boolean;
var
  Idx: Integer;
begin
  FLock.BeginRead;
  try
    Result := FMap.TryGetValue(AKey, Idx);
    if Result then
    begin
      AValue := FItems[Idx].Value;
      if FItems[Idx].Lives < FMaxLives then  // cap
        PdbAtomicInc(FItems[Idx].Lives);

      CacheHitRate.IncHits;
    end;
  finally
    FLock.EndRead;
  end;
end;

end.
