unit PascalDb.OutboxTests;

{ Tests for PascalDb.Outbox against a real database (PascalDb.IntegrationEnv,
  PASCALDB_IT_ENGINE), with the reference SQL of docs/outbox/sql as an
  application would copy it: the database's folder (PG, FB, SQLITE, MYSQL or
  MSSQL), then COMMON (TFallbackSqlSource over a TDirectorySqlSource). So
  each run checks the library's passes and that database's statements
  together. The tables come from that folder's OUTBOX.SCHEMA, created once
  per run in the integration database; each test starts with them empty.
  The folder is found by walking up from the executable (the runners sit at
  different depths, and the Linux script copies docs/ next to the runner).

  Covered: an event rolled back with its transaction; delivery in creation
  order, once; a failing sink retried after its delay while the rest of the
  batch goes on; a lease held by another relay; the batch size; the trace
  kept from the enqueuing span; the local sink (one delivery per accepting
  handler, a failing handler retried apart and then dead, an event no
  handler wants); the purge keeping events with a pending delivery; the
  metrics; and two relays' worth of concurrency: a claim meeting a row
  another transaction holds locked (skipped where the database can skip
  locked rows; elsewhere the pass gives up with ELockConflictException after
  the lock timeout) and an event enqueued in a transaction still open not
  stalling the relay (every database but SQLite, which has one writer at a
  time). The pure
  parts (the retry delay, the owner, the options) are in the unit suite's
  PascalDb.OutboxUnitTests.

  Ported from pascal-agenda-faa's tests/Unit/Agenda.OutboxTests.pas, which
  ran them on SQLite only.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Integration/fpc is generated
  from the master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalDb.DUnitXCompat,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.Outbox;

type
  [TestFixture]
  TOutboxTests = class
  private
    FFactory: IDBFactory;
    FErrors: Integer;
    FLastError: string;
    function Enqueue(const AKind: string; ANow: Int64; ACommit: Boolean = True): string;
    function Count(const ASql: string): Integer;
    procedure Exec(const ASql: string);
    procedure CountError(const AEvent: TOutboxEvent; const AHandler, AMessage: string);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure Enqueue_RolledBack_NothingToDeliver;
    [Test]
    procedure Relay_DeliversInOrder_Once;
    [Test]
    procedure Relay_SinkFails_RetriedLater_OthersGoOn;
    [Test]
    procedure Relay_LeasedElsewhere_SkippedUntilLeaseEnds;
    [Test]
    procedure Relay_BatchSize;
    [Test]
    procedure Enqueue_KeepsTheTrace;
    [Test]
    procedure LocalSink_OneDeliveryPerHandler;
    [Test]
    procedure LocalSink_FailingHandler_RetriedApart_ThenDead;
    [Test]
    procedure LocalSink_GiveUp_DeadAtOnce;
    [Test]
    procedure LocalSink_NoHandler_Delivered;
    [Test]
    procedure Purge_KeepsPendingDeliveries;
    [Test]
    procedure Metrics_Relay_Handlers_Pending;
    [Test]
    procedure Relay_RowLockedElsewhere_ClaimsTheOthers;
    [Test]
    procedure Relay_UncommittedEnqueue_DoesNotStall;
  end;

implementation

uses
  PascalDb.SqlSources,
  PascalCommon.Metrics,
  PascalCommon.Tracing,
  PascalDb.IntegrationEnv;

const
  TENANT = 'demo';
  REFERENCE_SQL = 'docs' + PathDelim + 'outbox' + PathDelim + 'sql';
  // Long enough for a busy CI machine, short enough that a claim waiting
  // for a lock it should have skipped fails the test instead of hanging it.
  LOCK_TIMEOUT_MS = 5000;

var
  GSchemaReady: Boolean = False;

// docs/outbox/sql, looked for from the executable's folder upwards.
function ReferenceSqlFolder: string;
var
  LDir: string;
  I: Integer;
begin
  LDir := ExtractFilePath(ParamStr(0));
  for I := 0 to 6 do
  begin
    if DirectoryExists(LDir + REFERENCE_SQL) then
      Exit(LDir + REFERENCE_SQL);
    LDir := ExtractFilePath(ExcludeTrailingPathDelimiter(LDir));
  end;
  raise Exception.CreateFmt('%s not found above %s', [REFERENCE_SQL, ExtractFilePath(ParamStr(0))]);
end;

function NewOutboxFactory: IDBFactory;
begin
  Result := SqlSourceFactory(
    TFallbackSqlSource.Create(TDirectorySqlSource.Create(ReferenceSqlFolder), 'COMMON'),
    EngineSqlDirectory, LOCK_TIMEOUT_MS);
end;

type
  /// Keeps what it was given; fails FailsLeft times for FailKind.
  TRecordingSink = class(TInterfacedObject, IOutboxSink)
  public
    Events: TOutboxEvents;
    FailKind: string;
    FailsLeft: Integer;
    procedure Deliver(const AQuery: IQuery; const AEvent: TOutboxEvent; ANow: Int64);
  end;

  /// Accepts one kind; fails FailsLeft times (-1: always), with
  /// EOutboxGiveUp when GiveUp.
  TTestHandler = class(TInterfacedObject, IOutboxHandler)
  private
    FName, FKind: string;
  public
    FailsLeft: Integer;
    GiveUp: Boolean;
    Tries: Integer;
    Handled: Integer;
    constructor Create(const AName, AKind: string; AFails: Integer = 0);
    function Name: string;
    function Accepts(const AKind: string): Boolean;
    procedure Handle(const AEvent: TOutboxEvent);
  end;

procedure TRecordingSink.Deliver(const AQuery: IQuery; const AEvent: TOutboxEvent; ANow: Int64);
var
  LCount: Integer;
begin
  if (AEvent.Kind = FailKind) and (FailsLeft > 0) then
  begin
    Dec(FailsLeft);
    raise Exception.Create('the sink is down');
  end;
  LCount := Length(Events);
  SetLength(Events, LCount + 1);
  Events[LCount] := AEvent;
end;

constructor TTestHandler.Create(const AName, AKind: string; AFails: Integer);
begin
  inherited Create;
  FName := AName;
  FKind := AKind;
  FailsLeft := AFails;
end;

function TTestHandler.Name: string;
begin
  Result := FName;
end;

function TTestHandler.Accepts(const AKind: string): Boolean;
begin
  Result := AKind = FKind;
end;

procedure TTestHandler.Handle(const AEvent: TOutboxEvent);
begin
  Inc(Tries);
  if FailsLeft <> 0 then
  begin
    if FailsLeft > 0 then
      Dec(FailsLeft);
    if GiveUp then
      raise EOutboxGiveUp.Create(FName + ' gave up');
    raise Exception.Create(FName + ' failed');
  end;
  Inc(Handled);
end;

// A metric's value now in PcMetrics: a counter's or a gauge's series with
// these label values, 0 when the series doesn't exist yet. The registry is
// the process's, so the tests compare before and after.
function MetricValue(const AName: string; const ALabels: array of string): Double;
var
  LMetrics: TPcMetricList;
  LPoints: TPcMetricPoints;
  I, J, K: Integer;
  LSame: Boolean;
begin
  Result := 0;
  LMetrics := PcMetrics.Metrics;
  for I := 0 to High(LMetrics) do
    if LMetrics[I].Name = AName then
    begin
      LPoints := LMetrics[I].Snapshot;
      for J := 0 to High(LPoints) do
      begin
        LSame := Length(LPoints[J].LabelValues) = Length(ALabels);
        if LSame then
          for K := 0 to High(ALabels) do
            if LPoints[J].LabelValues[K] <> ALabels[K] then
              LSame := False;
        if LSame then
          Exit(LPoints[J].Value);
      end;
    end;
end;

function SmallOptions: TOutboxOptions;
begin
  Result := TOutboxOptions.Default;
  Result.Retry.BaseSeconds := 5;
  Result.Retry.MaxSeconds := 30;
end;

procedure ExecDdl(const AFactory: IDBFactory; const ASql: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  if Trim(ASql) = '' then
    Exit;
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := ASql;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

// The database's OUTBOX.SCHEMA, one statement at a time (split at ';', as a
// migration with that terminator would), each committed: Firebird can't use a
// table in the transaction that created it.
procedure CreateSchema(const AFactory: IDBFactory);
var
  LScript: string;
  P: Integer;
begin
  LScript := AFactory.SqlLoader['OUTBOX.SCHEMA'].SQL;
  P := Pos(';', LScript);
  while P > 0 do
  begin
    ExecDdl(AFactory, Copy(LScript, 1, P - 1));
    Delete(LScript, 1, P);
    P := Pos(';', LScript);
  end;
  ExecDdl(AFactory, LScript);
end;

{ TOutboxTests }

procedure TOutboxTests.Setup;
begin
  FErrors := 0;
  FLastError := '';
  IntegrationFactory;
  FFactory := NewOutboxFactory;
  if not GSchemaReady then
  begin
    CreateSchema(FFactory);
    GSchemaReady := True;
  end;
  Exec('DELETE FROM OUTBOX_DELIVERIES');
  Exec('DELETE FROM OUTBOX');
end;

procedure TOutboxTests.TearDown;
begin
  FFactory := nil;
end;

procedure TOutboxTests.Exec(const ASql: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := ASql;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

function TOutboxTests.Count(const ASql: string): Integer;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := 'SELECT COUNT(*) AS N FROM ' + ASql;
    // COUNT is a bigint on PostgreSQL, MySQL and Firebird.
    Result := Integer(LQuery.Open.Int64s['N']);
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

function TOutboxTests.Enqueue(const AKind: string; ANow: Int64; ACommit: Boolean): string;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    Result := TOutbox.Enqueue(FFactory, LQuery, TENANT, AKind, '{"n":1}', ANow);
    if ACommit then
      LTx.Commit
    else
      LTx.Rollback;
  except
    LTx.Rollback;
    raise;
  end;
end;

procedure TOutboxTests.CountError(const AEvent: TOutboxEvent; const AHandler, AMessage: string);
begin
  Inc(FErrors);
  FLastError := AMessage;
end;

procedure TOutboxTests.Enqueue_RolledBack_NothingToDeliver;
var
  LSink: TRecordingSink;
  LSinkIntf: IOutboxSink;
  LRelay: TOutboxRelay;
begin
  LSink := TRecordingSink.Create;
  LSinkIntf := LSink;
  Enqueue('a', 100, False);
  TAssert.AssertEquals('no row', 0, Count('OUTBOX'));
  LRelay := TOutboxRelay.Create(FFactory, LSinkIntf, 'r1', SmallOptions);
  try
    TAssert.AssertEquals(0, LRelay.RunOnce(200));
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals(0, Length(LSink.Events));
end;

procedure TOutboxTests.Relay_DeliversInOrder_Once;
var
  LSink: TRecordingSink;
  LSinkIntf: IOutboxSink;
  LRelay: TOutboxRelay;
  LId: string;
begin
  LSink := TRecordingSink.Create;
  LSinkIntf := LSink;
  Enqueue('c', 102);
  LId := Enqueue('a', 100);
  Enqueue('b', 101);
  LRelay := TOutboxRelay.Create(FFactory, LSinkIntf, 'r1', SmallOptions);
  try
    TAssert.AssertEquals('delivered', 3, LRelay.RunOnce(200));
    TAssert.AssertEquals('a second pass', 0, LRelay.RunOnce(201));
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals(3, Length(LSink.Events));
  TAssert.AssertEquals('a', LSink.Events[0].Kind);
  TAssert.AssertEquals('b', LSink.Events[1].Kind);
  TAssert.AssertEquals('c', LSink.Events[2].Kind);
  TAssert.AssertEquals(LId, LSink.Events[0].Id);
  TAssert.AssertEquals(32, Length(LId));
  TAssert.AssertEquals(TENANT, LSink.Events[0].TenantId);
  TAssert.AssertEquals('{"n":1}', LSink.Events[0].Payload);
  TAssert.AssertEquals(Int64(100), LSink.Events[0].CreatedAt);
  TAssert.AssertEquals('marked', 3, Count('OUTBOX WHERE DELIVERED_AT = 200 AND LEASE_OWNER IS NULL'));
end;

procedure TOutboxTests.Relay_SinkFails_RetriedLater_OthersGoOn;
var
  LSink: TRecordingSink;
  LSinkIntf: IOutboxSink;
  LRelay: TOutboxRelay;
begin
  LSink := TRecordingSink.Create;
  LSinkIntf := LSink;
  LSink.FailKind := 'bad';
  LSink.FailsLeft := 1;
  Enqueue('bad', 100);
  Enqueue('good', 101);
  LRelay := TOutboxRelay.Create(FFactory, LSinkIntf, 'r1', SmallOptions);
  try
    LRelay.OnError := CountError;
    TAssert.AssertEquals('the other one', 1, LRelay.RunOnce(200));
    TAssert.AssertEquals('reported', 1, FErrors);
    TAssert.AssertTrue(FLastError, Pos('the sink is down', FLastError) > 0);
    TAssert.AssertEquals('kept for later', 1, Count('OUTBOX WHERE KIND = ''bad'' AND ' +
      'ATTEMPTS = 1 AND AVAILABLE_AT = 205 AND DELIVERED_AT IS NULL AND LEASE_OWNER IS NULL ' +
      'AND LAST_ERROR LIKE ''%the sink is down%'''));
    TAssert.AssertEquals('not before its time', 0, LRelay.RunOnce(204));
    TAssert.AssertEquals('at its time', 1, LRelay.RunOnce(205));
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals(2, Length(LSink.Events));
  TAssert.AssertEquals('good', LSink.Events[0].Kind);
  TAssert.AssertEquals('bad', LSink.Events[1].Kind);
  TAssert.AssertEquals(1, LSink.Events[1].Attempts);
end;

procedure TOutboxTests.Relay_LeasedElsewhere_SkippedUntilLeaseEnds;
var
  LSink: TRecordingSink;
  LSinkIntf: IOutboxSink;
  LRelay: TOutboxRelay;
begin
  LSink := TRecordingSink.Create;
  LSinkIntf := LSink;
  Enqueue('a', 100);
  // Another relay holds it until 300.
  Exec('UPDATE OUTBOX SET LEASE_OWNER = ''r2'', LEASE_UNTIL = 300');
  LRelay := TOutboxRelay.Create(FFactory, LSinkIntf, 'r1', SmallOptions);
  try
    TAssert.AssertEquals('leased', 0, LRelay.RunOnce(200));
    TAssert.AssertEquals('still leased at 300', 0, LRelay.RunOnce(300));
    TAssert.AssertEquals('the lease ran out', 1, LRelay.RunOnce(301));
  finally
    LRelay.Free;
  end;
end;

procedure TOutboxTests.Relay_BatchSize;
var
  LSink: TRecordingSink;
  LSinkIntf: IOutboxSink;
  LRelay: TOutboxRelay;
  LOptions: TOutboxOptions;
begin
  LSink := TRecordingSink.Create;
  LSinkIntf := LSink;
  Enqueue('a', 100);
  Enqueue('b', 101);
  Enqueue('c', 102);
  LOptions := SmallOptions;
  LOptions.BatchSize := 2;
  LRelay := TOutboxRelay.Create(FFactory, LSinkIntf, 'r1', LOptions);
  try
    TAssert.AssertEquals(2, LRelay.RunOnce(200));
    TAssert.AssertEquals(1, LRelay.RunOnce(200));
    TAssert.AssertEquals(0, LRelay.RunOnce(200));
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals('c', LSink.Events[2].Kind);
end;

procedure TOutboxTests.Enqueue_KeepsTheTrace;
var
  LSink: TRecordingSink;
  LSinkIntf: IOutboxSink;
  LRelay: TOutboxRelay;
  LSpan: IPcSpan;
  LTrace: string;
begin
  LSink := TRecordingSink.Create;
  LSinkIntf := LSink;
  LSpan := TPcTracing.StartSpan('request');
  try
    LTrace := LSpan.TraceParent;
    Enqueue('traced', 100);
  finally
    LSpan.Finish;
    LSpan := nil;
  end;
  Enqueue('untraced', 101);
  LRelay := TOutboxRelay.Create(FFactory, LSinkIntf, 'r1', SmallOptions);
  try
    TAssert.AssertEquals(2, LRelay.RunOnce(200));
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals(55, Length(LTrace));
  TAssert.AssertEquals(LTrace, LSink.Events[0].TraceParent);
  TAssert.AssertEquals('', LSink.Events[1].TraceParent);
end;

procedure TOutboxTests.LocalSink_OneDeliveryPerHandler;
var
  LSink: IOutboxLocalSink;
  LH1, LH2, LH3: TTestHandler;
  LIntf1, LIntf2, LIntf3: IOutboxHandler;
  LRelay: TOutboxRelay;
begin
  LSink := TOutboxLocalSink.Create(FFactory, 's1', SmallOptions);
  LH1 := TTestHandler.Create('email', 'a');
  LIntf1 := LH1;
  LH2 := TTestHandler.Create('audit', 'a');
  LIntf2 := LH2;
  LH3 := TTestHandler.Create('other', 'b');
  LIntf3 := LH3;
  LSink.AddHandler(LIntf1);
  LSink.AddHandler(LIntf2);
  LSink.AddHandler(LIntf3);
  Enqueue('a', 100);
  LRelay := TOutboxRelay.Create(FFactory, LSink, 'r1', SmallOptions);
  try
    TAssert.AssertEquals(1, LRelay.RunOnce(200));
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals('one per accepting handler', 2,
    Count('OUTBOX_DELIVERIES WHERE STATUS = ''pending'''));
  TAssert.AssertEquals('run', 2, LSink.RunOnce(200));
  TAssert.AssertEquals(1, LH1.Handled);
  TAssert.AssertEquals(1, LH2.Handled);
  TAssert.AssertEquals(0, LH3.Tries);
  TAssert.AssertEquals('once', 0, LSink.RunOnce(201));
  TAssert.AssertEquals(2, Count('OUTBOX_DELIVERIES WHERE STATUS = ''done'' AND LEASE_OWNER IS NULL'));
end;

procedure TOutboxTests.LocalSink_FailingHandler_RetriedApart_ThenDead;
var
  LSink: IOutboxLocalSink;
  LBad, LGood: TTestHandler;
  LIntf1, LIntf2: IOutboxHandler;
  LRelay: TOutboxRelay;
  LOptions: TOutboxOptions;
begin
  LOptions := SmallOptions;
  LOptions.MaxAttempts := 2;
  LSink := TOutboxLocalSink.Create(FFactory, 's1', LOptions);
  LSink.SetOnError(CountError);
  LBad := TTestHandler.Create('bad', 'a', -1);
  LIntf1 := LBad;
  LGood := TTestHandler.Create('good', 'a');
  LIntf2 := LGood;
  LSink.AddHandler(LIntf1);
  LSink.AddHandler(LIntf2);
  Enqueue('a', 100);
  LRelay := TOutboxRelay.Create(FFactory, LSink, 'r1', LOptions);
  try
    LRelay.RunOnce(200);
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals('the good one', 1, LSink.RunOnce(200));
  TAssert.AssertEquals(1, FErrors);
  TAssert.AssertEquals('retried later', 1, Count('OUTBOX_DELIVERIES WHERE HANDLER = ''bad'' ' +
    'AND STATUS = ''pending'' AND ATTEMPTS = 1 AND AVAILABLE_AT = 205'));
  TAssert.AssertEquals('not before', 0, LSink.RunOnce(204));
  TAssert.AssertEquals(1, LBad.Tries);
  TAssert.AssertEquals('second try fails', 0, LSink.RunOnce(205));
  TAssert.AssertEquals(2, LBad.Tries);
  TAssert.AssertEquals('dead', 1, Count('OUTBOX_DELIVERIES WHERE HANDLER = ''bad'' ' +
    'AND STATUS = ''dead'' AND ATTEMPTS = 2 AND LAST_ERROR LIKE ''%bad failed%'''));
  TAssert.AssertEquals('never again', 0, LSink.RunOnce(10000));
  TAssert.AssertEquals(2, LBad.Tries);
  TAssert.AssertEquals('the good one ran once', 1, LGood.Tries);
end;

procedure TOutboxTests.LocalSink_GiveUp_DeadAtOnce;
var
  LSink: IOutboxLocalSink;
  LBad: TTestHandler;
  LIntf: IOutboxHandler;
  LRelay: TOutboxRelay;
  LDeadBefore: Double;
begin
  LSink := TOutboxLocalSink.Create(FFactory, 's1', SmallOptions);
  LSink.SetOnError(CountError);
  LBad := TTestHandler.Create('bad', 'a', -1);
  LBad.GiveUp := True;
  LIntf := LBad;
  LSink.AddHandler(LIntf);
  Enqueue('a', 100);
  LRelay := TOutboxRelay.Create(FFactory, LSink, 'r1', SmallOptions);
  try
    LRelay.RunOnce(200);
  finally
    LRelay.Free;
  end;
  LDeadBefore := MetricValue('outbox.handler.runs', ['bad', 'a', 'dead']);
  TAssert.AssertEquals(0, LSink.RunOnce(200));
  TAssert.AssertEquals('reported', 1, FErrors);
  TAssert.AssertEquals('dead at the first try, MaxAttempts not used', 1,
    Count('OUTBOX_DELIVERIES WHERE HANDLER = ''bad'' AND STATUS = ''dead'' AND ATTEMPTS = 1 ' +
    'AND LAST_ERROR LIKE ''%EOutboxGiveUp: bad gave up%'''));
  TAssert.AssertEquals('counted as dead', LDeadBefore + 1, MetricValue('outbox.handler.runs', ['bad', 'a', 'dead']), 0.001);
  TAssert.AssertEquals('never again', 0, LSink.RunOnce(10000));
  TAssert.AssertEquals(1, LBad.Tries);
end;

procedure TOutboxTests.LocalSink_NoHandler_Delivered;
var
  LSink: IOutboxLocalSink;
  LRelay: TOutboxRelay;
begin
  LSink := TOutboxLocalSink.Create(FFactory, 's1', SmallOptions);
  LSink.AddHandler(TTestHandler.Create('email', 'a'));
  Enqueue('nobody', 100);
  LRelay := TOutboxRelay.Create(FFactory, LSink, 'r1', SmallOptions);
  try
    TAssert.AssertEquals(1, LRelay.RunOnce(200));
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals(0, Count('OUTBOX_DELIVERIES'));
  TAssert.AssertEquals(1, Count('OUTBOX WHERE DELIVERED_AT = 200'));
end;

procedure TOutboxTests.Purge_KeepsPendingDeliveries;
var
  LSink: IOutboxLocalSink;
  LRelay: TOutboxRelay;
begin
  LSink := TOutboxLocalSink.Create(FFactory, 's1', SmallOptions);
  LSink.AddHandler(TTestHandler.Create('ok', 'a'));
  LSink.AddHandler(TTestHandler.Create('failing', 'b', -1));
  Enqueue('a', 100);
  Enqueue('b', 101);
  Enqueue('later', 102);
  LRelay := TOutboxRelay.Create(FFactory, LSink, 'r1', SmallOptions);
  try
    LRelay.RunOnce(200);
  finally
    LRelay.Free;
  end;
  // A fourth one, enqueued after the pass: not delivered.
  Enqueue('waiting', 250);
  LSink.RunOnce(200);
  TAssert.AssertEquals('none delivered before 150', 0, TOutbox.Purge(FFactory, 150));
  TAssert.AssertEquals('a and later', 2, TOutbox.Purge(FFactory, 300));
  TAssert.AssertEquals('b (pending) and waiting', 2, Count('OUTBOX'));
  TAssert.AssertEquals('b''s delivery', 1, Count('OUTBOX_DELIVERIES WHERE STATUS = ''pending'''));
  TAssert.AssertEquals('a''s went with it', 0, Count('OUTBOX_DELIVERIES WHERE STATUS = ''done'''));
end;

procedure TOutboxTests.Metrics_Relay_Handlers_Pending;
var
  LRecording: TRecordingSink;
  LRecordingIntf: IOutboxSink;
  LLocal: IOutboxLocalSink;
  LHandler: TTestHandler;
  LHandlerIntf: IOutboxHandler;
  LRelay: TOutboxRelay;
  LDelivered, LFailed, LRuns: Double;
begin
  LDelivered := MetricValue('outbox.events.delivered', ['m.ok']);
  LFailed := MetricValue('outbox.events.failed', ['m.bad']);
  LRuns := MetricValue('outbox.handler.runs', ['m.handler', 'm.local', 'done']);
  Enqueue('m.ok', 100);
  Enqueue('m.bad', 150);
  TAssert.AssertEquals('pending', 2, TOutbox.MeasurePending(FFactory, 200));
  TAssert.AssertEquals(2, MetricValue('outbox.events.pending', []), 0);
  TAssert.AssertEquals('the oldest, written at 100', 100,
    MetricValue('outbox.events.oldest_age', []), 0);

  LRecording := TRecordingSink.Create;
  LRecordingIntf := LRecording;
  LRecording.FailKind := 'm.bad';
  LRecording.FailsLeft := 1;
  LRelay := TOutboxRelay.Create(FFactory, LRecordingIntf, 'r1', SmallOptions);
  try
    LRelay.RunOnce(200);
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals('delivered', LDelivered + 1,
    MetricValue('outbox.events.delivered', ['m.ok']), 0);
  TAssert.AssertEquals('failed', LFailed + 1, MetricValue('outbox.events.failed', ['m.bad']), 0);
  TAssert.AssertEquals('one left', 1, TOutbox.MeasurePending(FFactory, 250));
  TAssert.AssertEquals(100, MetricValue('outbox.events.oldest_age', []), 0);

  // The local sink: a handler's run, by result.
  LLocal := TOutboxLocalSink.Create(FFactory, 's1', SmallOptions);
  LHandler := TTestHandler.Create('m.handler', 'm.local');
  LHandlerIntf := LHandler;
  LLocal.AddHandler(LHandlerIntf);
  Enqueue('m.local', 300);
  LRelay := TOutboxRelay.Create(FFactory, LLocal, 'r2', SmallOptions);
  try
    LRelay.RunOnce(300);
  finally
    LRelay.Free;
  end;
  TAssert.AssertEquals(1, LLocal.RunOnce(300));
  TAssert.AssertEquals('a run done', LRuns + 1,
    MetricValue('outbox.handler.runs', ['m.handler', 'm.local', 'done']), 0);

  Exec('UPDATE OUTBOX SET DELIVERED_AT = 400');
  TAssert.AssertEquals('none', 0, TOutbox.MeasurePending(FFactory, 400));
  TAssert.AssertEquals(0, MetricValue('outbox.events.oldest_age', []), 0);
end;

procedure TOutboxTests.Relay_RowLockedElsewhere_ClaimsTheOthers;
var
  LSink: TRecordingSink;
  LSinkIntf: IOutboxSink;
  LRelay: TOutboxRelay;
  LLocker: IQuery;
  LLockerTx: IScopeTransaction;
  LFirst, LRaised: string;
  LOpen: Boolean;
begin
  LSink := TRecordingSink.Create;
  LSinkIntf := LSink;
  LFirst := Enqueue('a', 100);
  Enqueue('b', 101);
  Enqueue('c', 102);
  // Another transaction holds the first row locked, as a relay in the
  // middle of its claim would. By its key: MySQL locks every row an UPDATE
  // scans.
  LLockerTx := FFactory.GetPool.AcquireQuery(LLocker);
  LLockerTx.StartTransaction;
  LOpen := True;
  try
    LLocker.Sql := 'UPDATE OUTBOX SET ATTEMPTS = ATTEMPTS WHERE TENANT_ID = :TENANT_ID AND ID = :ID';
    LLocker.Params.Strings['TENANT_ID'] := TENANT;
    LLocker.Params.Strings['ID'] := LFirst;
    LLocker.ExecSql;
    LRelay := TOutboxRelay.Create(FFactory, LSinkIntf, 'r1', SmallOptions);
    try
      if SkipsLockedRows then
        TAssert.AssertEquals('the two not locked', 2, LRelay.RunOnce(200))
      else
      begin
        // Firebird waits for the row and SQLite for the database's one
        // write lock, up to the lock timeout: the pass fails, nothing is
        // claimed, and the next pass tries again.
        LRaised := '';
        try
          LRelay.RunOnce(200);
        except
          on E: Exception do
            LRaised := E.ClassName;
        end;
        TAssert.AssertEquals('the claim gives up', 'ELockConflictException', LRaised);
      end;
      LOpen := False;
      LLockerTx.Commit;
      if SkipsLockedRows then
        TAssert.AssertEquals('the locked one, once free', 1, LRelay.RunOnce(201))
      else
        TAssert.AssertEquals('all three, once free', 3, LRelay.RunOnce(201));
    finally
      LRelay.Free;
    end;
  finally
    if LOpen then
      LLockerTx.Rollback;
  end;
  TAssert.AssertEquals(3, Length(LSink.Events));
  if SkipsLockedRows then
  begin
    TAssert.AssertEquals('b', LSink.Events[0].Kind);
    TAssert.AssertEquals('c', LSink.Events[1].Kind);
    TAssert.AssertEquals('a', LSink.Events[2].Kind);
  end
  else
    TAssert.AssertEquals('a', LSink.Events[0].Kind);
end;

procedure TOutboxTests.Relay_UncommittedEnqueue_DoesNotStall;
var
  LSink: TRecordingSink;
  LSinkIntf: IOutboxSink;
  LRelay: TOutboxRelay;
  LWriter: IQuery;
  LWriterTx: IScopeTransaction;
  LOpen: Boolean;
begin
  // SQLite: the application's open transaction holds the write lock, and
  // the relay's claim waits for it (busy timeout).
  if not AllowsConcurrentWriters then
    Exit;
  LSink := TRecordingSink.Create;
  LSinkIntf := LSink;
  Enqueue('committed', 100);
  // An application's transaction, still open, has just written an event.
  LWriterTx := FFactory.GetPool.AcquireQuery(LWriter);
  LWriterTx.StartTransaction;
  LOpen := True;
  try
    TOutbox.Enqueue(FFactory, LWriter, TENANT, 'open', '{}', 150);
    LRelay := TOutboxRelay.Create(FFactory, LSinkIntf, 'r1', SmallOptions);
    try
      TAssert.AssertEquals('the committed one, without waiting', 1, LRelay.RunOnce(200));
      TAssert.AssertEquals('pending: committed events only', 0, TOutbox.MeasurePending(FFactory, 200));
      LOpen := False;
      LWriterTx.Commit;
      TAssert.AssertEquals('the other, once committed', 1, LRelay.RunOnce(201));
    finally
      LRelay.Free;
    end;
  finally
    if LOpen then
      LWriterTx.Rollback;
  end;
  TAssert.AssertEquals(2, Length(LSink.Events));
  TAssert.AssertEquals('committed', LSink.Events[0].Kind);
  TAssert.AssertEquals('open', LSink.Events[1].Kind);
  TAssert.AssertEquals('{}', LSink.Events[1].Payload);
end;

initialization
  TDUnitX.RegisterTestFixture(TOutboxTests);

end.
