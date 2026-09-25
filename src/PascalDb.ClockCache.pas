unit PascalDb.ClockCache;

{$I pascaldb.inc}

{ Cache flyweight genérico (TClockCache<K, V>), thread-safe e de latência
  previsível, pensado para processos que rodam sem parar. É o que sustenta o
  cache de instâncias dos tipos opcionais (PascalDb.Optionals).

  Evicção por "G-Clock híbrido com busca de vítima amortizada", em vez de LRU
  (caro sob concorrência) ou FIFO (ineficiente):

  - Ciclo único: com o cache cheio, o Put dá no máximo UM giro completo no anel
    de slots (FCapacity), então a latência é constante e previsível (O(N)).
  - Vidas: cada item tem um contador. Get/Update incrementam (recompensa por
    frequência, até AMaxLives); o giro de evicção decrementa (punição por
    ociosidade).
  - Vítima: durante o giro, procura um item com 0 vidas. Se não achar nenhum,
    sacrifica o de menor contagem visto no giro.
  - Admissão (AdmissionPolicy): apAlwaysAdmit sempre admite o item novo,
    substituindo o menos "quente" mesmo que ainda tenha vidas;
    apProtectHotItems só admite se algum item já estiver com 0 vidas.

  Memória fixa definida no Create (slots pré-alocados, sem fragmentação), e
  valores pensados para interfaces (contagem de referência). TCacheHitRate
  mede hits/misses para acompanhar a eficiência em produção.

  Dual-compiler: o comparador opcional do construtor nunca é repassado como
  nil ao TDictionary (o do FPC 3.2.2 guarda o nil e dá Access Violation; o do
  Delphi troca por Default), e os contadores usam PascalDb.Threading em vez de
  TInterlocked, que não existe no FPC. }

interface

uses
  Classes, SysUtils, Generics.Collections, PascalDb.SystemContext, 
  SyncObjs, Math, Generics.Defaults, PascalDb.Threading;

type
  TClockItem<K, V> = record
    Key: K;
    Value: V;
    Lives: Integer;     // Contador de frequência (G-Clock)
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
    TMap = TDictionary<K, Integer>; // Mapeia Chave -> Índice no Array
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
  // Nao repassar AComparer = nil: o TDictionary do Delphi troca nil pelo
  // comparador padrao, mas o do FPC 3.2.2 (rtl-generics) guarda o nil e da'
  // Access Violation no primeiro Add/TryGetValue (GetHashCode sobre nil).
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
    // 1. Cache ainda tem posições sem uso
    if not FItems[FHand].InUse then
      Exit(True);

    // 2. Já achamos alguém que morreu naturalmente?
    if FItems[FHand].Lives = 0 then
    begin
      Eject;
      Exit(True);
    end;

    // 3. Senão, monitoramos quem é o mais fraco deste ciclo
    if FItems[FHand].Lives < MinLives then
    begin
      MinLives := FItems[FHand].Lives;
      WeakestIdx := FHand;
    end;

    Dec(FItems[FHand].Lives);  // Segunda chance: tira a marcação
    FHand := (FHand + 1) mod FCapacity;
  end;

  if FAdmissionPolicy = apProtectHotItems then
  begin
    if MinLives > 1 then
      Exit(False);
  end;

  FHand := WeakestIdx; // posiciona o hand
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

    // O Evict parou no FHand que deve ser usado.
    FItems[FHand].Key := AKey;
    FItems[FHand].Value := AValue;
    FItems[FHand].Lives := Math.Min(FMaxLives, AInitialLives);
    FItems[FHand].InUse := True;

    FMap.AddOrSetValue(AKey, FHand);

    // Avança o ponteiro APÓS a inserção ter sido concluída no mapa
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
      if FItems[Idx].Lives < FMaxLives then  // limite
        PdbAtomicInc(FItems[Idx].Lives);

      CacheHitRate.IncHits;
    end;
  finally
    FLock.EndRead;
  end;
end;

end.
