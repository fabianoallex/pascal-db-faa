unit PascalDb.Outbox;

{$I pascaldb.inc}

(* A transactional outbox: an event leaves the database only after the
  transaction that caused it committed, without a second system written in
  the same breath (the dual write).

  Promoted from pascal-agenda-faa (its Agenda.Outbox, decision 10 of its
  M7 review), with its tests; depends on the core and pascal-common-faa
  only. The tables and their SQL are the application's, by name (the
  OUTBOX_SQL_* keys below, read through the factory's SQL loader), so a
  schema, a column type or a claim can follow each database. docs/outbox.md
  has the reference SQL for every database the library supports, in
  docs/outbox/sql (measured by the integration suite on each of them), with
  the parameters each name receives and the columns it returns.

  - TOutbox.Enqueue writes one row on the caller's connection, inside the
    caller's transaction: the event exists exactly when the change does. It
    keeps the current span's traceparent (TPcTracing.Current), so the trace
    goes on where the event is handled.
  - TOutboxRelay.RunOnce is one pass: it claims up to BatchSize pending
    events with a lease (one UPDATE: owner and until when; a row whose lease
    ran out is pending again, so a relay that died loses nothing), then hands
    each to an IOutboxSink and marks it delivered in one transaction with
    what the sink wrote. A sink that raises leaves the event pending, its
    attempts counted and its next try later (TOutboxRetry: doubling from
    BaseSeconds up to MaxSeconds); the others in the batch go on. Several
    relays may run: the claim's UPDATE names the lease it found expired, so
    two never hold one row. Where the database can, the reference claims
    skip rows another relay is claiming instead of waiting for them
    (PostgreSQL, MySQL and MariaDB: SKIP LOCKED; SQL Server: READPAST).
  - Delivery is at-least-once: a relay that dies after the sink and before
    the commit delivers again. Whoever handles an event deduplicates by its
    id. Order is the creation order within a batch, not a promise across
    batches, retries or relays.
  - TOutboxLocalSink is the sink without a broker: it writes one delivery per
    handler that accepts the event's kind (OUTBOX_DELIVERIES, in the relay's
    transaction), and its RunOnce runs them, each retried on its own, dead
    after MaxAttempts, so a failing handler neither blocks nor repeats the
    others. A handler runs outside any transaction (it may send an email)
    and inside a span that continues the event's trace.
  - The passes don't sleep or loop: the caller's thread calls the relay's
    and the local sink's RunOnce on its schedule. Times are Unix seconds,
    passed in, so tests choose them.
  - Metrics, in pascal-common-faa's PcMetrics, OpenTelemetry names:
    outbox.events.delivered and outbox.events.failed (by
    outbox.event.kind), the relay's; outbox.handler.runs (by outbox.handler,
    outbox.event.kind and outbox.result: done, retried, dead), the local
    sink's; outbox.events.pending and outbox.events.oldest_age (s), gauges
    TOutbox.MeasurePending sets when the caller asks (a query per call).

  Found while building it in the agenda: a method named Dispatch hides
  TObject.Dispatch (an FPC warning), so the local sink's pass is RunOnce, as
  the relay's. TOutboxErrorProc follows PASCALDB_FUNCREFS (a method compiles
  on both compilers). *)

interface

uses
  SysUtils,
  PascalDb.Interfaces;

const
  OUTBOX_SQL_INSERT = 'OUTBOX.INSERT';
  OUTBOX_SQL_CLAIM = 'OUTBOX.CLAIM';
  OUTBOX_SQL_CLAIMED = 'OUTBOX.CLAIMED';
  OUTBOX_SQL_DELIVERED = 'OUTBOX.DELIVERED';
  OUTBOX_SQL_FAILED = 'OUTBOX.FAILED';
  OUTBOX_SQL_PURGE_DELIVERIES = 'OUTBOX.PURGE_DELIVERIES';
  OUTBOX_SQL_PURGE = 'OUTBOX.PURGE';
  OUTBOX_SQL_PENDING = 'OUTBOX.PENDING';
  OUTBOX_SQL_DELIVERY_INSERT = 'OUTBOX_DELIVERY.INSERT';
  OUTBOX_SQL_DELIVERY_CLAIM = 'OUTBOX_DELIVERY.CLAIM';
  OUTBOX_SQL_DELIVERY_CLAIMED = 'OUTBOX_DELIVERY.CLAIMED';
  OUTBOX_SQL_DELIVERY_DONE = 'OUTBOX_DELIVERY.DONE';
  OUTBOX_SQL_DELIVERY_FAILED = 'OUTBOX_DELIVERY.FAILED';

  OUTBOX_DELIVERY_PENDING = 'pending';
  OUTBOX_DELIVERY_DONE = 'done';
  OUTBOX_DELIVERY_DEAD = 'dead';

  OUTBOX_DEFAULT_BATCH_SIZE = 50;
  OUTBOX_DEFAULT_LEASE_SECONDS = 60;
  OUTBOX_DEFAULT_RETRY_SECONDS = 5;
  OUTBOX_DEFAULT_MAX_RETRY_SECONDS = 600;
  OUTBOX_DEFAULT_MAX_ATTEMPTS = 10;
  /// LAST_ERROR keeps at most this many characters.
  OUTBOX_MAX_ERROR_CHARS = 500;

type
  TOutboxEvent = record
    TenantId: string;
    /// 32 hex digits, random: what a consumer deduplicates by.
    Id: string;
    Kind: string;
    Payload: string;
    /// The W3C traceparent of the span that enqueued it; '' for none.
    TraceParent: string;
    CreatedAt: Int64;
    /// Failed tries so far: the event's on a sink, the delivery's on a
    /// handler.
    Attempts: Integer;
  end;

  TOutboxEvents = TArray<TOutboxEvent>;

  /// Where the relay hands an event.
  IOutboxSink = interface
    ['{9C0B7D3E-4A8F-4E61-B2D5-7F31A6C90E48}']
    /// AQuery is on the connection whose transaction then marks AEvent
    /// delivered: what the sink writes there commits with it (the local
    /// sink's deliveries). The transaction is open while Deliver runs, so a
    /// slow sink holds it (on SQLite, the database's one write lock). Raise
    /// to leave the event pending.
    procedure Deliver(const AQuery: IQuery; const AEvent: TOutboxEvent; ANow: Int64);
  end;

  /// One reaction to events, run by TOutboxLocalSink.
  IOutboxHandler = interface
    ['{4E2A9B61-0C7D-4F38-9A15-D6B83E07C2F4}']
    /// Stored with each delivery (OUTBOX_DELIVERIES.HANDLER, 60 characters):
    /// keep it once deliveries exist.
    function Name: string;
    function Accepts(const AKind: string): Boolean;
    /// Raise to fail this try. Runs outside any transaction.
    procedure Handle(const AEvent: TOutboxEvent);
  end;

  /// A failed try: AHandler is '' for a sink's failure. "reference to" on
  /// Delphi, "of object" on FPC 3.2.2 (PASCALDB_FUNCREFS): pass a method.
  TOutboxErrorProc = {$IFDEF PASCALDB_FUNCREFS}reference to procedure(const AEvent: TOutboxEvent;
    const AHandler, AMessage: string)
    {$ELSE}procedure(const AEvent: TOutboxEvent; const AHandler, AMessage: string) of object{$ENDIF};

  TOutboxRetry = record
    BaseSeconds: Integer;
    MaxSeconds: Integer;
    /// The wait before the next try after AAttempts failed ones (1 or
    /// more): BaseSeconds doubled each time, at most MaxSeconds.
    function DelayAfter(AAttempts: Integer): Int64;
  end;

  TOutboxOptions = record
    BatchSize: Integer;
    LeaseSeconds: Integer;
    /// A handler's tries before its delivery is dead (the local sink). A
    /// sink's event is never dead: a broker that is down comes back.
    MaxAttempts: Integer;
    Retry: TOutboxRetry;
    class function Default: TOutboxOptions; static;
  end;

  TOutbox = class
  public
    /// Writes an event on AQuery's connection, in the transaction the caller
    /// has open there (it commits or rolls back with the caller's change),
    /// and returns its id. AQuery's SQL is replaced. The trace is the current
    /// span's, when there is one.
    class function Enqueue(const AFactory: IDBFactory; const AQuery: IQuery;
      const ATenantId, AKind, APayload: string; ANow: Int64): string; static;
    /// Deletes events delivered before ABefore whose deliveries are all
    /// done or dead, with those deliveries. Returns the events deleted.
    class function Purge(const AFactory: IDBFactory; ABefore: Int64): Integer; static;
    /// Sets the gauges outbox.events.pending (events not delivered yet) and
    /// outbox.events.oldest_age (seconds since the oldest of them was
    /// written, 0 when none) and returns the first.
    class function MeasurePending(const AFactory: IDBFactory; ANow: Int64): Integer; static;
  end;

  TOutboxRelay = class
  private
    FFactory: IDBFactory;
    FSink: IOutboxSink;
    FOwner: string;
    FOptions: TOutboxOptions;
    FOnError: TOutboxErrorProc;
    function Claim(ANow: Int64): TOutboxEvents;
    function DeliverOne(const AEvent: TOutboxEvent; ANow: Int64): Boolean;
    procedure Failed(const AEvent: TOutboxEvent; const AMessage: string; ANow: Int64);
  public
    /// AOwner names this relay in the leases (PdbOutboxNewOwner): unique per
    /// running relay.
    constructor Create(const AFactory: IDBFactory; const ASink: IOutboxSink;
      const AOwner: string; const AOptions: TOutboxOptions);
    /// One pass; returns the events delivered.
    function RunOnce(ANow: Int64): Integer;
    property Owner: string read FOwner;
    property OnError: TOutboxErrorProc read FOnError write FOnError;
  end;

  IOutboxLocalSink = interface(IOutboxSink)
    ['{B7F04C2D-91E3-4A6B-8D07-3E5C1A92F6B0}']
    /// Before the first event; not while RunOnce runs.
    procedure AddHandler(const AHandler: IOutboxHandler);
    /// One pass over the pending deliveries; returns the ones done.
    function RunOnce(ANow: Int64): Integer;
    procedure SetOnError(const AValue: TOutboxErrorProc);
  end;

  TOutboxLocalSink = class(TInterfacedObject, IOutboxSink, IOutboxLocalSink)
  private
    FFactory: IDBFactory;
    FOwner: string;
    FOptions: TOutboxOptions;
    FHandlers: array of IOutboxHandler;
    FOnError: TOutboxErrorProc;
    function FindHandler(const AName: string): IOutboxHandler;
    function Claim(ANow: Int64; out AHandlers: TArray<string>): TOutboxEvents;
    procedure Finish(const AEvent: TOutboxEvent; const AHandler, AStatus, AError: string;
      AAttempts: Integer; AAvailableAt, ANow: Int64);
  public
    constructor Create(const AFactory: IDBFactory; const AOwner: string;
      const AOptions: TOutboxOptions);
    procedure AddHandler(const AHandler: IOutboxHandler);
    procedure Deliver(const AQuery: IQuery; const AEvent: TOutboxEvent; ANow: Int64);
    function RunOnce(ANow: Int64): Integer;
    procedure SetOnError(const AValue: TOutboxErrorProc);
  end;

/// APrefix and 16 random hex digits: a lease owner for one running relay.
function PdbOutboxNewOwner(const APrefix: string): string;

implementation

uses
  PascalDb.Paging,
  PascalCommon.Crypto,
  PascalCommon.Random,
  PascalCommon.Metrics,
  PascalCommon.Tracing;

const
  RESULT_DONE = 'done';
  RESULT_RETRIED = 'retried';
  RESULT_DEAD = 'dead';

function DeliveredCounter: TPcCounter;
begin
  Result := PcMetrics.Counter('outbox.events.delivered', '{event}',
    'Outbox events handed to the sink and marked delivered', ['outbox.event.kind']);
end;

function FailedCounter: TPcCounter;
begin
  Result := PcMetrics.Counter('outbox.events.failed', '{event}',
    'Outbox events the sink refused (each is tried again later)', ['outbox.event.kind']);
end;

function HandlerRuns: TPcCounter;
begin
  Result := PcMetrics.Counter('outbox.handler.runs', '{run}',
    'Local sink: handler runs by result (done, retried, dead)',
    ['outbox.handler', 'outbox.event.kind', 'outbox.result']);
end;

function PdbOutboxNewOwner(const APrefix: string): string;
begin
  Result := APrefix + '-' + LowerCase(PcBytesToHex(PcRandomBytes(8)));
end;

function ErrorText(const AMessage: string): string;
begin
  Result := Copy(AMessage, 1, OUTBOX_MAX_ERROR_CHARS);
end;

function BatchClause(const AScope: IScopeTransaction; ASize: Integer): string;
begin
  Result := PdbPagingClause(AScope, TPageRequest.Create(1, ASize, ASize, ASize));
end;

{ TOutboxRetry }

function TOutboxRetry.DelayAfter(AAttempts: Integer): Int64;
var
  I: Integer;
begin
  Result := BaseSeconds;
  if Result < 1 then
    Result := 1;
  I := 1;
  while (I < AAttempts) and (Result < MaxSeconds) do
  begin
    Result := Result * 2;
    Inc(I);
  end;
  if Result > MaxSeconds then
    Result := MaxSeconds;
end;

{ TOutboxOptions }

class function TOutboxOptions.Default: TOutboxOptions;
begin
  Result.BatchSize := OUTBOX_DEFAULT_BATCH_SIZE;
  Result.LeaseSeconds := OUTBOX_DEFAULT_LEASE_SECONDS;
  Result.MaxAttempts := OUTBOX_DEFAULT_MAX_ATTEMPTS;
  Result.Retry.BaseSeconds := OUTBOX_DEFAULT_RETRY_SECONDS;
  Result.Retry.MaxSeconds := OUTBOX_DEFAULT_MAX_RETRY_SECONDS;
end;

{ TOutbox }

class function TOutbox.Enqueue(const AFactory: IDBFactory; const AQuery: IQuery;
  const ATenantId, AKind, APayload: string; ANow: Int64): string;
var
  LSpan: IPcSpan;
  LTrace: string;
begin
  Result := LowerCase(PcBytesToHex(PcRandomBytes(16)));
  LTrace := '';
  LSpan := TPcTracing.Current;
  if LSpan <> nil then
    LTrace := LSpan.TraceParent;
  AQuery.Sql := AFactory.SqlLoader[OUTBOX_SQL_INSERT].ProcessTag('TRACE', LTrace <> '').SQL;
  AQuery.Params.Strings['TENANT_ID'] := ATenantId;
  AQuery.Params.Strings['ID'] := Result;
  AQuery.Params.Strings['KIND'] := AKind;
  AQuery.Params.Strings['PAYLOAD'] := APayload;
  if LTrace <> '' then
    AQuery.Params.Strings['TRACE_PARENT'] := LTrace;
  AQuery.Params.Int64s['CREATED_AT'] := ANow;
  AQuery.ExecSql;
end;

class function TOutbox.Purge(const AFactory: IDBFactory; ABefore: Int64): Integer;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := AFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader[OUTBOX_SQL_PURGE_DELIVERIES].SQL;
    LQuery.Params.Int64s['BEFORE'] := ABefore;
    LQuery.Params.Strings['PENDING'] := OUTBOX_DELIVERY_PENDING;
    LQuery.ExecSql;
    LQuery.Sql := AFactory.SqlLoader[OUTBOX_SQL_PURGE].SQL;
    LQuery.Params.Int64s['BEFORE'] := ABefore;
    Result := Integer(LQuery.ExecSql);
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

class function TOutbox.MeasurePending(const AFactory: IDBFactory; ANow: Int64): Integer;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LAge: Int64;
begin
  LTx := AFactory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := AFactory.SqlLoader[OUTBOX_SQL_PENDING].SQL;
  LResult := LQuery.Open;
  // COUNT is a bigint on PostgreSQL.
  Result := Integer(LResult.Int64s['PENDING']);
  LAge := 0;
  // MIN is NULL only when no row counted.
  if Result > 0 then
    LAge := ANow - LResult.Int64s['OLDEST'];
  if LAge < 0 then
    LAge := 0;
  PcMetrics.Gauge('outbox.events.pending', '{event}',
    'Outbox events not delivered yet', []).SetValue(Result);
  PcMetrics.Gauge('outbox.events.oldest_age', 's',
    'Seconds since the oldest event not delivered yet was written (0 when none)', [])
    .SetValue(LAge);
end;

{ TOutboxRelay }

constructor TOutboxRelay.Create(const AFactory: IDBFactory; const ASink: IOutboxSink;
  const AOwner: string; const AOptions: TOutboxOptions);
begin
  inherited Create;
  FFactory := AFactory;
  FSink := ASink;
  FOwner := AOwner;
  FOptions := AOptions;
end;

function ReadEvent(const AResult: IQueryResult): TOutboxEvent;
begin
  Result.TenantId := AResult.Strings['TENANT_ID'];
  Result.Id := AResult.Strings['ID'];
  Result.Kind := AResult.Strings['KIND'];
  Result.Payload := AResult.Strings['PAYLOAD'];
  Result.TraceParent := AResult.NullableStrings['TRACE_PARENT'].ValueOr('');
  Result.CreatedAt := AResult.Int64s['CREATED_AT'];
  Result.Attempts := AResult.Integers['ATTEMPTS'];
end;

function TOutboxRelay.Claim(ANow: Int64): TOutboxEvents;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LUntil: Int64;
  LCount: Integer;
begin
  Result := nil;
  LUntil := ANow + FOptions.LeaseSeconds;
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[OUTBOX_SQL_CLAIM]
      .ReplaceLiteral('PAGE', BatchClause(LTx, FOptions.BatchSize)).SQL;
    LQuery.Params.Strings['OWNER'] := FOwner;
    LQuery.Params.Int64s['LEASE_UNTIL'] := LUntil;
    LQuery.Params.Int64s['NOW'] := ANow;
    LCount := Integer(LQuery.ExecSql);
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LCount = 0 then
    Exit;
  LQuery.Sql := FFactory.SqlLoader[OUTBOX_SQL_CLAIMED].SQL;
  LQuery.Params.Strings['OWNER'] := FOwner;
  LQuery.Params.Int64s['LEASE_UNTIL'] := LUntil;
  LResult := LQuery.Open;
  LCount := 0;
  while not LResult.Eof do
  begin
    SetLength(Result, LCount + 1);
    Result[LCount] := ReadEvent(LResult);
    Inc(LCount);
    LResult.Next;
  end;
end;

procedure TOutboxRelay.Failed(const AEvent: TOutboxEvent; const AMessage: string; ANow: Int64);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[OUTBOX_SQL_FAILED].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AEvent.TenantId;
    LQuery.Params.Strings['ID'] := AEvent.Id;
    LQuery.Params.Strings['OWNER'] := FOwner;
    LQuery.Params.Int64s['AVAILABLE_AT'] := ANow + FOptions.Retry.DelayAfter(AEvent.Attempts + 1);
    LQuery.Params.Strings['LAST_ERROR'] := ErrorText(AMessage);
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

function TOutboxRelay.DeliverOne(const AEvent: TOutboxEvent; ANow: Int64): Boolean;
var
  LSpan: IPcSpan;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LError: string;
begin
  Result := False;
  LError := '';
  LSpan := TPcTracing.StartSpanFromParent(AEvent.TraceParent, '', 'outbox ' + AEvent.Kind,
    skProducer);
  try
    LSpan.SetAttribute('outbox.event_id', AEvent.Id);
    try
      LTx := FFactory.GetPool.AcquireQuery(LQuery);
      LTx.StartTransaction;
      try
        FSink.Deliver(LQuery, AEvent, ANow);
        LQuery.Sql := FFactory.SqlLoader[OUTBOX_SQL_DELIVERED].SQL;
        LQuery.Params.Strings['TENANT_ID'] := AEvent.TenantId;
        LQuery.Params.Strings['ID'] := AEvent.Id;
        LQuery.Params.Strings['OWNER'] := FOwner;
        LQuery.Params.Int64s['NOW'] := ANow;
        // No row: the lease ran out and another relay has the event.
        Result := LQuery.ExecSql > 0;
        if Result then
          LTx.Commit
        else
          LTx.Rollback;
      except
        LTx.Rollback;
        raise;
      end;
    except
      on E: Exception do
        LError := E.ClassName + ': ' + E.Message;
    end;
    LQuery := nil;
    LTx := nil;
    if Result then
      DeliveredCounter.Labels([AEvent.Kind]).Inc;
    if LError <> '' then
    begin
      FailedCounter.Labels([AEvent.Kind]).Inc;
      LSpan.SetStatus(ssError, LError);
      Failed(AEvent, LError, ANow);
      if Assigned(FOnError) then
        FOnError(AEvent, '', LError);
    end;
  finally
    LSpan.Finish;
  end;
end;

function TOutboxRelay.RunOnce(ANow: Int64): Integer;
var
  LEvents: TOutboxEvents;
  I: Integer;
begin
  Result := 0;
  LEvents := Claim(ANow);
  for I := 0 to High(LEvents) do
    if DeliverOne(LEvents[I], ANow) then
      Inc(Result);
end;

{ TOutboxLocalSink }

constructor TOutboxLocalSink.Create(const AFactory: IDBFactory; const AOwner: string;
  const AOptions: TOutboxOptions);
begin
  inherited Create;
  FFactory := AFactory;
  FOwner := AOwner;
  FOptions := AOptions;
end;

procedure TOutboxLocalSink.AddHandler(const AHandler: IOutboxHandler);
var
  LCount: Integer;
begin
  if FindHandler(AHandler.Name) <> nil then
    raise EArgumentException.CreateFmt('TOutboxLocalSink: a handler named "%s" is already there',
      [AHandler.Name]);
  LCount := Length(FHandlers);
  SetLength(FHandlers, LCount + 1);
  FHandlers[LCount] := AHandler;
end;

procedure TOutboxLocalSink.SetOnError(const AValue: TOutboxErrorProc);
begin
  FOnError := AValue;
end;

function TOutboxLocalSink.FindHandler(const AName: string): IOutboxHandler;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(FHandlers) do
    if FHandlers[I].Name = AName then
      Exit(FHandlers[I]);
end;

procedure TOutboxLocalSink.Deliver(const AQuery: IQuery; const AEvent: TOutboxEvent;
  ANow: Int64);
var
  I: Integer;
begin
  for I := 0 to High(FHandlers) do
    if FHandlers[I].Accepts(AEvent.Kind) then
    begin
      AQuery.Sql := FFactory.SqlLoader[OUTBOX_SQL_DELIVERY_INSERT].SQL;
      AQuery.Params.Strings['TENANT_ID'] := AEvent.TenantId;
      AQuery.Params.Strings['EVENT_ID'] := AEvent.Id;
      AQuery.Params.Strings['HANDLER'] := FHandlers[I].Name;
      AQuery.Params.Strings['STATUS'] := OUTBOX_DELIVERY_PENDING;
      AQuery.Params.Int64s['NOW'] := ANow;
      AQuery.ExecSql;
    end;
end;

function TOutboxLocalSink.Claim(ANow: Int64; out AHandlers: TArray<string>): TOutboxEvents;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LUntil: Int64;
  LCount: Integer;
begin
  Result := nil;
  AHandlers := nil;
  LUntil := ANow + FOptions.LeaseSeconds;
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[OUTBOX_SQL_DELIVERY_CLAIM]
      .ReplaceLiteral('PAGE', BatchClause(LTx, FOptions.BatchSize)).SQL;
    LQuery.Params.Strings['OWNER'] := FOwner;
    LQuery.Params.Int64s['LEASE_UNTIL'] := LUntil;
    LQuery.Params.Int64s['NOW'] := ANow;
    LQuery.Params.Strings['PENDING'] := OUTBOX_DELIVERY_PENDING;
    LCount := Integer(LQuery.ExecSql);
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LCount = 0 then
    Exit;
  LQuery.Sql := FFactory.SqlLoader[OUTBOX_SQL_DELIVERY_CLAIMED].SQL;
  LQuery.Params.Strings['OWNER'] := FOwner;
  LQuery.Params.Int64s['LEASE_UNTIL'] := LUntil;
  LQuery.Params.Strings['PENDING'] := OUTBOX_DELIVERY_PENDING;
  LResult := LQuery.Open;
  LCount := 0;
  while not LResult.Eof do
  begin
    SetLength(Result, LCount + 1);
    SetLength(AHandlers, LCount + 1);
    Result[LCount] := ReadEvent(LResult);
    AHandlers[LCount] := LResult.Strings['HANDLER'];
    Inc(LCount);
    LResult.Next;
  end;
end;

procedure TOutboxLocalSink.Finish(const AEvent: TOutboxEvent; const AHandler, AStatus,
  AError: string; AAttempts: Integer; AAvailableAt, ANow: Int64);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    if AStatus = OUTBOX_DELIVERY_DONE then
      LQuery.Sql := FFactory.SqlLoader[OUTBOX_SQL_DELIVERY_DONE].SQL
    else
    begin
      LQuery.Sql := FFactory.SqlLoader[OUTBOX_SQL_DELIVERY_FAILED].SQL;
      LQuery.Params.Integers['ATTEMPTS'] := AAttempts;
      LQuery.Params.Int64s['AVAILABLE_AT'] := AAvailableAt;
      LQuery.Params.Strings['LAST_ERROR'] := ErrorText(AError);
    end;
    LQuery.Params.Strings['STATUS'] := AStatus;
    LQuery.Params.Strings['TENANT_ID'] := AEvent.TenantId;
    LQuery.Params.Strings['EVENT_ID'] := AEvent.Id;
    LQuery.Params.Strings['HANDLER'] := AHandler;
    LQuery.Params.Strings['OWNER'] := FOwner;
    LQuery.Params.Int64s['NOW'] := ANow;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if AStatus = OUTBOX_DELIVERY_DONE then
    HandlerRuns.Labels([AHandler, AEvent.Kind, RESULT_DONE]).Inc
  else if AStatus = OUTBOX_DELIVERY_DEAD then
    HandlerRuns.Labels([AHandler, AEvent.Kind, RESULT_DEAD]).Inc
  else
    HandlerRuns.Labels([AHandler, AEvent.Kind, RESULT_RETRIED]).Inc;
end;

function TOutboxLocalSink.RunOnce(ANow: Int64): Integer;
var
  LEvents: TOutboxEvents;
  LNames: TArray<string>;
  LHandler: IOutboxHandler;
  LSpan: IPcSpan;
  LError, LStatus: string;
  LAttempts, I: Integer;
begin
  Result := 0;
  LEvents := Claim(ANow, LNames);
  for I := 0 to High(LEvents) do
  begin
    LError := '';
    LHandler := FindHandler(LNames[I]);
    LSpan := TPcTracing.StartSpanFromParent(LEvents[I].TraceParent, '',
      LNames[I] + ' ' + LEvents[I].Kind, skConsumer);
    try
      LSpan.SetAttribute('outbox.event_id', LEvents[I].Id);
      if LHandler = nil then
        LError := Format('No handler named "%s" in this process.', [LNames[I]])
      else
        try
          LHandler.Handle(LEvents[I]);
        except
          on E: Exception do
            LError := E.ClassName + ': ' + E.Message;
        end;
      if LError = '' then
      begin
        Finish(LEvents[I], LNames[I], OUTBOX_DELIVERY_DONE, '', 0, 0, ANow);
        Inc(Result);
      end
      else
      begin
        LSpan.SetStatus(ssError, LError);
        LAttempts := LEvents[I].Attempts + 1;
        if (LHandler = nil) or (LAttempts >= FOptions.MaxAttempts) then
          LStatus := OUTBOX_DELIVERY_DEAD
        else
          LStatus := OUTBOX_DELIVERY_PENDING;
        Finish(LEvents[I], LNames[I], LStatus, LError, LAttempts,
          ANow + FOptions.Retry.DelayAfter(LAttempts), ANow);
        if Assigned(FOnError) then
          FOnError(LEvents[I], LNames[I], LError);
      end;
    finally
      LSpan.Finish;
      LSpan := nil;
    end;
  end;
end;

end.
