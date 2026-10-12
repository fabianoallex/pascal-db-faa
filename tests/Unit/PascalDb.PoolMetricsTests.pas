unit PascalDb.PoolMetricsTests;

{ Tests for the pool's metrics (PascalDb.Pool on PascalCommon.Metrics): the
  names, units, descriptions and labels of OpenTelemetry's database client
  connection metrics and of the two pascaldb.* counters; idle and used
  following acquire and release; the ramp-up not counted as use; a destroyed
  pool giving its series back; two pools with the same name adding up;
  pending requests while an acquire waits, and the timeout; the closed
  connections by reason; the pool name, from the constructor and from
  IDatabaseConfig.PoolName through TDBFactory.

  PcMetrics is process-wide and never drops a series, so each test names its
  pool after itself and reads only that pool's series; the counters of a
  name only grow, so a test that runs twice in one process compares
  differences. The fakes (TDBFactoryMock, TFakeSleep, TReleasingSleep,
  TFakeTicker) are PascalDb.PoolTests's, TUnusedProvider
  PascalDb.AdapterBaseTests's.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalDb.DUnitXCompat,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.Pool,
  PascalDb.Adapter.Base,
  PascalCommon.SystemContext,
  PascalCommon.Metrics,
  PascalDb.PoolTests,
  PascalDb.AdapterBaseTests;

type

  { TPendingProbeSleep
    Reads db.client.connection.pending_requests of PoolName on each Sleep (an
    acquire is waiting then), keeping the highest value seen. }

  TPendingProbeSleep = class(TInterfacedObject, ISleep)
  public
    PoolName: string;
    MaxPending: Double;
    procedure Sleep(milliseconds: Cardinal);
  end;

  { TPoolMetricsTests }

  [TestFixture]
  TPoolMetricsTests = class
  public
    [Test] procedure Test_PoolMetrics_NamesUnitsAndDescriptions;
    [Test] procedure Test_PoolMetrics_IdleAndUsed_FollowAcquireAndRelease;
    [Test] procedure Test_PoolMetrics_Destroy_GivesTheSeriesBack;
    [Test] procedure Test_PoolMetrics_TwoPoolsWithTheSameName_AddUp;
    [Test] procedure Test_PoolMetrics_Wait_PendingAndWaitTime;
    [Test] procedure Test_PoolMetrics_Timeout_Counted;
    [Test] procedure Test_PoolMetrics_Closed_ByReason;
    [Test] procedure Test_PoolMetrics_IdleSweep_And_Keepalive;
    [Test] procedure Test_PoolMetrics_PoolName_Default;
    [Test] procedure Test_PoolMetrics_PoolName_FromTheFactoryConfig;
  end;

/// The metric of that name in PcMetrics; nil when there is none.
function FindMetric(const AName: string): TPcMetric;
/// The value of a counter or up-down counter's series (its label values, in
/// the metric's order); 0 when the series doesn't exist.
function MetricValue(const AName: string; const ALabelValues: array of string): Double;
/// The observation count of a histogram's series; 0 when it doesn't exist.
function MetricCount(const AName: string; const ALabelValues: array of string): UInt64;

implementation

const
  POOL_NAME_LABEL = 'db.client.connection.pool.name';

function FindMetric(const AName: string): TPcMetric;
var
  LMetrics: TPcMetricList;
  I: Integer;
begin
  Result := nil;
  LMetrics := PcMetrics.Metrics;
  for I := 0 to High(LMetrics) do
    if LMetrics[I].Name = AName then
      Exit(LMetrics[I]);
end;

function FindPoint(const AName: string; const ALabelValues: array of string;
  out APoint: TPcMetricPoint): Boolean;
var
  LMetric: TPcMetric;
  LPoints: TPcMetricPoints;
  I, J: Integer;
  LSame: Boolean;
begin
  Result := False;
  APoint := Default(TPcMetricPoint);
  LMetric := FindMetric(AName);
  if LMetric = nil then
    Exit;
  LPoints := LMetric.Snapshot;
  for I := 0 to High(LPoints) do
  begin
    if Length(LPoints[I].LabelValues) <> Length(ALabelValues) then
      Continue;
    LSame := True;
    for J := 0 to High(ALabelValues) do
      if LPoints[I].LabelValues[J] <> ALabelValues[J] then
        LSame := False;
    if LSame then
    begin
      APoint := LPoints[I];
      Exit(True);
    end;
  end;
end;

function MetricValue(const AName: string; const ALabelValues: array of string): Double;
var
  LPoint: TPcMetricPoint;
begin
  Result := 0;
  if FindPoint(AName, ALabelValues, LPoint) then
    Result := LPoint.Value;
end;

function MetricCount(const AName: string; const ALabelValues: array of string): UInt64;
var
  LPoint: TPcMetricPoint;
begin
  Result := 0;
  if FindPoint(AName, ALabelValues, LPoint) then
    Result := LPoint.Count;
end;

function Idle(const APool: string): Double;
begin
  Result := MetricValue('db.client.connection.count', ['idle', APool]);
end;

function Used(const APool: string): Double;
begin
  Result := MetricValue('db.client.connection.count', ['used', APool]);
end;

function Closed(const APool, AReason: string): Double;
begin
  Result := MetricValue('pascaldb.client.connection.closed', [AReason, APool]);
end;

// The pool keeps a weak reference to its factory: each one goes in a list
// that lives as long as the tests (a temporary would be freed at once), and
// is released with the unit's globals.
var
  GFactories: array of IDBFactory;

function NewFactory: IDBFactory;
begin
  Result := TDBFactoryMock.Create;
  SetLength(GFactories, Length(GFactories) + 1);
  GFactories[High(GFactories)] := Result;
end;

function NewConfig(AIni, AMax, AWaitMaxAttemps: Integer): IConnectionPoolConfig;
begin
  Result := TConnectionPoolConfig.Create;
  Result.IniConnections := AIni;
  Result.MaxConnections := AMax;
  Result.WaitMaxAttemps := AWaitMaxAttemps;
end;

{ TPendingProbeSleep }

procedure TPendingProbeSleep.Sleep(milliseconds: Cardinal);
var
  LValue: Double;
begin
  LValue := MetricValue('db.client.connection.pending_requests', [PoolName]);
  if LValue > MaxPending then
    MaxPending := LValue;
end;

{ TPoolMetricsTests }

procedure TPoolMetricsTests.Test_PoolMetrics_NamesUnitsAndDescriptions;
const
  NAMES: array[0..9] of string = ('db.client.connection.count', 'db.client.connection.max',
    'db.client.connection.idle.min', 'db.client.connection.pending_requests',
    'db.client.connection.timeouts', 'db.client.connection.wait_time',
    'db.client.connection.create_time', 'db.client.connection.use_time',
    'pascaldb.client.connection.created', 'pascaldb.client.connection.closed');
  KINDS: array[0..9] of TPcMetricKind = (mkUpDownCounter, mkUpDownCounter, mkUpDownCounter,
    mkUpDownCounter, mkCounter, mkHistogram, mkHistogram, mkHistogram, mkCounter, mkCounter);
  UNITS: array[0..9] of string = ('{connection}', '{connection}', '{connection}', '{request}',
    '{timeout}', 's', 's', 's', '{connection}', '{connection}');
  PROMETHEUS: array[0..9] of string = ('db_client_connection_count', 'db_client_connection_max',
    'db_client_connection_idle_min', 'db_client_connection_pending_requests',
    'db_client_connection_timeouts_total', 'db_client_connection_wait_time_seconds',
    'db_client_connection_create_time_seconds', 'db_client_connection_use_time_seconds',
    'pascaldb_client_connection_created_total', 'pascaldb_client_connection_closed_total');
var
  LPool: IDBConnectionPool;
  LMetric: TPcMetric;
  I: Integer;
begin
  LPool := TConnectionPool.Create(NewFactory, NewConfig(0, 2, 1), nil, nil, '',
    'metrics-names');
  for I := 0 to High(NAMES) do
  begin
    LMetric := FindMetric(NAMES[I]);
    TAssert.AssertTrue(NAMES[I] + ' must be registered', LMetric <> nil);
    TAssert.AssertEquals(NAMES[I] + ': kind', Ord(KINDS[I]), Ord(LMetric.Kind));
    TAssert.AssertEquals(NAMES[I] + ': unit', UNITS[I], LMetric.MetricUnit);
    TAssert.AssertTrue(NAMES[I] + ': a description (promtool rejects a metric without help)',
      LMetric.Description <> '');
    TAssert.AssertEquals(NAMES[I] + ': Prometheus name', PROMETHEUS[I], PcPrometheusName(LMetric));
    TAssert.AssertEquals(NAMES[I] + ': the pool name is the last label', POOL_NAME_LABEL,
      LMetric.LabelNames[High(LMetric.LabelNames)]);
  end;
  TAssert.AssertEquals('db.client.connection.state',
    FindMetric('db.client.connection.count').LabelNames[0]);
  TAssert.AssertEquals('pascaldb.close.reason',
    FindMetric('pascaldb.client.connection.closed').LabelNames[0]);
  TAssert.AssertEquals('PC_DURATION_BUCKETS', Length(PC_DURATION_BUCKETS),
    Length(FindMetric('db.client.connection.wait_time').Bounds));
end;

procedure TPoolMetricsTests.Test_PoolMetrics_IdleAndUsed_FollowAcquireAndRelease;
const
  P = 'metrics-acquire';
var
  LPool: IDBConnectionPool;
  LConn1, LConn2, LConn3: IDBConnection;
  LCreated0, LCreate0, LWait0, LUse0: Double;
begin
  LCreated0 := MetricValue('pascaldb.client.connection.created', [P]);
  LCreate0 := MetricCount('db.client.connection.create_time', [P]);
  LWait0 := MetricCount('db.client.connection.wait_time', [P]);
  LUse0 := MetricCount('db.client.connection.use_time', [P]);

  LPool := TConnectionPool.Create(NewFactory, NewConfig(2, 5, 1), nil, nil, '', P);
  TAssert.AssertEquals('max', 5, MetricValue('db.client.connection.max', [P]), 0);
  TAssert.AssertEquals('idle.min', 2, MetricValue('db.client.connection.idle.min', [P]), 0);
  TAssert.AssertEquals('The ramp-up leaves 2 idle', 2, Idle(P), 0);
  TAssert.AssertEquals('Nothing used', 0, Used(P), 0);
  TAssert.AssertEquals('2 created', 2, MetricValue('pascaldb.client.connection.created', [P]) - LCreated0, 0);
  TAssert.AssertEquals('2 create times', 2, MetricCount('db.client.connection.create_time', [P]) - LCreate0, 0);
  TAssert.AssertEquals('The ramp-up is not a wait', 0, MetricCount('db.client.connection.wait_time', [P]) - LWait0, 0);
  TAssert.AssertEquals('The ramp-up is not a use', 0, MetricCount('db.client.connection.use_time', [P]) - LUse0, 0);

  LConn1 := LPool.AcquireConnection;
  TAssert.AssertEquals('1 idle after the first acquire', 1, Idle(P), 0);
  TAssert.AssertEquals('1 used after the first acquire', 1, Used(P), 0);
  LConn2 := LPool.AcquireConnection;
  LConn3 := LPool.AcquireConnection; // a new one: the pool grows
  TAssert.AssertEquals('0 idle', 0, Idle(P), 0);
  TAssert.AssertEquals('3 used', 3, Used(P), 0);
  TAssert.AssertEquals('3 created', 3, MetricValue('pascaldb.client.connection.created', [P]) - LCreated0, 0);
  TAssert.AssertEquals('3 waits observed (none waited)', 3, MetricCount('db.client.connection.wait_time', [P]) - LWait0, 0);

  LConn1 := nil;
  TAssert.AssertEquals('1 idle after a release', 1, Idle(P), 0);
  TAssert.AssertEquals('2 used after a release', 2, Used(P), 0);
  TAssert.AssertEquals('1 use time', 1, MetricCount('db.client.connection.use_time', [P]) - LUse0, 0);
  LConn2 := nil;
  LConn3 := nil;
  TAssert.AssertEquals('3 idle', 3, Idle(P), 0);
  TAssert.AssertEquals('0 used', 0, Used(P), 0);
  TAssert.AssertEquals('3 use times', 3, MetricCount('db.client.connection.use_time', [P]) - LUse0, 0);
  TAssert.AssertEquals('The snapshot agrees', LPool.GetPoolSize, Round(Idle(P)));
end;

procedure TPoolMetricsTests.Test_PoolMetrics_Destroy_GivesTheSeriesBack;
const
  P = 'metrics-destroy';
var
  LPool: IDBConnectionPool;
  LConn: IDBConnection;
  LCreated: Double;
begin
  LPool := TConnectionPool.Create(NewFactory, NewConfig(2, 4, 1), nil, nil, '', P);
  LConn := LPool.AcquireConnection;
  LConn := LPool.AcquireConnection; // the first goes back
  LConn := LPool.AcquireConnection;
  LConn := nil;
  LCreated := MetricValue('pascaldb.client.connection.created', [P]);
  TAssert.AssertTrue('Precondition: idle connections', Idle(P) > 0);
  LPool := nil;
  TAssert.AssertEquals('idle', 0, Idle(P), 0);
  TAssert.AssertEquals('used', 0, Used(P), 0);
  TAssert.AssertEquals('max', 0, MetricValue('db.client.connection.max', [P]), 0);
  TAssert.AssertEquals('idle.min', 0, MetricValue('db.client.connection.idle.min', [P]), 0);
  TAssert.AssertEquals('A counter keeps its total', LCreated,
    MetricValue('pascaldb.client.connection.created', [P]), 0);
end;

procedure TPoolMetricsTests.Test_PoolMetrics_TwoPoolsWithTheSameName_AddUp;
const
  P = 'metrics-shared';
var
  LPool1, LPool2: IDBConnectionPool;
begin
  LPool1 := TConnectionPool.Create(NewFactory, NewConfig(1, 3, 1), nil, nil, '', P);
  LPool2 := TConnectionPool.Create(NewFactory, NewConfig(2, 4, 1), nil, nil, '', P);
  TAssert.AssertEquals('max', 7, MetricValue('db.client.connection.max', [P]), 0);
  TAssert.AssertEquals('idle.min', 3, MetricValue('db.client.connection.idle.min', [P]), 0);
  TAssert.AssertEquals('idle', 3, Idle(P), 0);
  LPool1 := nil;
  TAssert.AssertEquals('max of the one left', 4, MetricValue('db.client.connection.max', [P]), 0);
  TAssert.AssertEquals('idle of the one left', 2, Idle(P), 0);
  LPool2 := nil;
  TAssert.AssertEquals('max', 0, MetricValue('db.client.connection.max', [P]), 0);
end;

procedure TPoolMetricsTests.Test_PoolMetrics_Wait_PendingAndWaitTime;
const
  P = 'metrics-wait';
var
  LPool: IDBConnectionPool;
  LHeld, LConn: IDBConnection;
  LSleep: TReleasingSleep;
  LWait0: Double;
begin
  // As Test_Pool_Tracing_PoolWait_UntilAConnectionIsFree: the fake Sleep
  // releases the held connection, the acquire gets it on its next try.
  LSleep := TReleasingSleep.Create;
  TSleep.SetSleep(LSleep);
  try
    LPool := TConnectionPool.Create(NewFactory, NewConfig(1, 1, 5), nil, nil, '', P);
    LWait0 := MetricCount('db.client.connection.wait_time', [P]);
    LHeld := LPool.AcquireConnection;
    LSleep.Held := LHeld;
    LHeld := nil;
    LConn := LPool.AcquireConnection;
    TAssert.AssertTrue('The second acquire got the released connection', LConn <> nil);
    TAssert.AssertEquals('Nothing pending after it', 0,
      MetricValue('db.client.connection.pending_requests', [P]), 0);
    TAssert.AssertEquals('Both acquires observed', 2,
      MetricCount('db.client.connection.wait_time', [P]) - LWait0, 0);
    TAssert.AssertEquals('1 used', 1, Used(P), 0);
  finally
    LConn := nil;
    LSleep.Held := nil;
    LPool := nil;
    TSleep.Reset;
  end;
end;

procedure TPoolMetricsTests.Test_PoolMetrics_Timeout_Counted;
const
  P = 'metrics-timeout';
var
  LPool: IDBConnectionPool;
  LHeld, LConn: IDBConnection;
  LProbe: TPendingProbeSleep;
  LSleep: ISleep;
  LTimeouts0, LWait0: Double;
  LRaised: Boolean;
begin
  LProbe := TPendingProbeSleep.Create;
  LProbe.PoolName := P;
  LSleep := LProbe;
  TSleep.SetSleep(LSleep);
  try
    LPool := TConnectionPool.Create(NewFactory, NewConfig(1, 1, 3), nil, nil, '', P);
    LTimeouts0 := MetricValue('db.client.connection.timeouts', [P]);
    LWait0 := MetricCount('db.client.connection.wait_time', [P]);
    LHeld := LPool.AcquireConnection;
    LRaised := False;
    try
      LConn := LPool.AcquireConnection;
    except
      on E: EPoolTimeoutException do
        LRaised := True;
    end;
    TAssert.AssertTrue('The acquire must time out', LRaised);
    TAssert.AssertEquals('1 pending while it waited', 1, LProbe.MaxPending, 0);
    TAssert.AssertEquals('None pending after it gave up', 0,
      MetricValue('db.client.connection.pending_requests', [P]), 0);
    TAssert.AssertEquals('1 timeout', 1, MetricValue('db.client.connection.timeouts', [P]) - LTimeouts0, 0);
    TAssert.AssertEquals('Only the successful acquire has a wait time', 1,
      MetricCount('db.client.connection.wait_time', [P]) - LWait0, 0);
  finally
    LConn := nil;
    LHeld := nil;
    LPool := nil;
    TSleep.Reset;
  end;
end;

procedure TPoolMetricsTests.Test_PoolMetrics_Closed_ByReason;
const
  P = 'metrics-closed';
var
  LMock: TDBFactoryMock;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LConn: IDBConnection;
  LConfig: IConnectionPoolConfig;
  LBroken0, LPing0: Double;
  LDiscardable: IDiscardableConnection;
begin
  LMock := TDBFactoryMock.Create;
  LFactory := LMock;
  LConfig := NewConfig(0, 2, 1);
  LConfig.ValidateIdleSeconds := 0; // ping on every acquire from the pool
  LPool := TConnectionPool.Create(LFactory, LConfig, nil, nil, '', P);
  LBroken0 := Closed(P, 'broken');
  LPing0 := Closed(P, 'ping_failed');

  // Broken during use: discarded on release, never idle.
  LConn := LPool.AcquireConnection;
  // Supports, not "as": FPC keeps the temporary of an "as" alive until this
  // routine ends, and the connection wouldn't be released here.
  TAssert.AssertTrue(Supports(LConn, IDiscardableConnection, LDiscardable));
  LDiscardable.MarkForDiscard;
  LDiscardable := nil;
  LConn := nil;
  TAssert.AssertEquals('broken', 1, Closed(P, 'broken') - LBroken0, 0);
  TAssert.AssertEquals('Not idle', 0, Idle(P), 0);
  TAssert.AssertEquals('Not used', 0, Used(P), 0);

  // Fails the ping on acquire: discarded, and a new one is opened.
  LConn := LPool.AcquireConnection;
  LConn := nil;
  LMock.FailNextTestConnections(1);
  LConn := LPool.AcquireConnection;
  TAssert.AssertEquals('ping_failed', 1, Closed(P, 'ping_failed') - LPing0, 0);
  TAssert.AssertEquals('Not idle', 0, Idle(P), 0);
  TAssert.AssertEquals('The new one used', 1, Used(P), 0);
  LConn := nil;
end;

procedure TPoolMetricsTests.Test_PoolMetrics_IdleSweep_And_Keepalive;
const
  P = 'metrics-sweep';
var
  LMock: TDBFactoryMock;
  LFactory: IDBFactory;
  LPoolIntf: IDBConnectionPool;
  LPool: TConnectionPool;
  LTicker: TFakeTicker;
  LConn1, LConn2, LConn3: IDBConnection;
  LSwept0, LPing0: Double;
begin
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(1000000);
  TTicker.SetTicker(LTicker);
  try
    LMock := TDBFactoryMock.Create;
    LFactory := LMock;
    LPoolIntf := TConnectionPool.Create(LFactory, NewConfig(0, 5, 1), nil, nil, '', P);
    LPool := LPoolIntf as TConnectionPool;
    LSwept0 := Closed(P, 'idle_timeout');
    LPing0 := Closed(P, 'ping_failed');
    LConn1 := LPoolIntf.AcquireConnection;
    LConn2 := LPoolIntf.AcquireConnection;
    LConn3 := LPoolIntf.AcquireConnection;
    LConn1 := nil;
    LTicker.SetDefaultMs(1000000 + 50000);
    LConn2 := nil;
    LConn3 := nil;
    TAssert.AssertEquals('Precondition: 3 idle', 3, Idle(P), 0);

    LTicker.SetDefaultMs(1000000 + 65000);
    LPool.SweepIdleConnections(60); // only the first one is 60 s idle
    TAssert.AssertEquals('idle_timeout', 1, Closed(P, 'idle_timeout') - LSwept0, 0);
    TAssert.AssertEquals('2 idle', 2, Idle(P), 0);

    LMock.FailNextTestConnections(1);
    LTicker.SetDefaultMs(1000000 + 200000);
    LPool.KeepaliveIdleConnections(60); // both due, one dies
    TAssert.AssertEquals('ping_failed', 1, Closed(P, 'ping_failed') - LPing0, 0);
    TAssert.AssertEquals('1 idle', 1, Idle(P), 0);
    TAssert.AssertEquals('The snapshot agrees', LPoolIntf.GetPoolSize, Round(Idle(P)));
    TAssert.AssertEquals('Nothing used', 0, Used(P), 0);
  finally
    LConn1 := nil;
    LConn2 := nil;
    LConn3 := nil;
    LPoolIntf := nil;
    TTicker.Reset;
  end;
end;

procedure TPoolMetricsTests.Test_PoolMetrics_PoolName_Default;
var
  LObj: TConnectionPool;
  LPool: IDBConnectionPool;
begin
  LObj := TConnectionPool.Create(NewFactory, NewConfig(0, 1, 1));
  LPool := LObj;
  TAssert.AssertEquals('No name, no db system', 'default', LObj.PoolName);
  LObj := TConnectionPool.Create(NewFactory, NewConfig(0, 1, 1), nil, nil, 'mysql');
  LPool := LObj;
  TAssert.AssertEquals('The db system', 'mysql', LObj.PoolName);
  LObj := TConnectionPool.Create(NewFactory, NewConfig(0, 1, 1), nil, nil, 'mysql', 'orders');
  LPool := LObj;
  TAssert.AssertEquals('The given name', 'orders', LObj.PoolName);
  LPool := nil;
end;

procedure TPoolMetricsTests.Test_PoolMetrics_PoolName_FromTheFactoryConfig;
var
  LConfig: IDatabaseConfig;
  LProvider: IDBComponentProvider;
  LFactory: IDBFactory;
begin
  LConfig := TDatabaseConfig.Create;
  TAssert.AssertEquals('PoolName is empty by default', '', LConfig.PoolName);
  LConfig.PoolIniConnections := 0; // TUnusedProvider opens nothing
  LConfig.PoolMaxConnections := 7;
  LConfig.SQLDialect := 'PostgreSQL';
  LConfig.PoolName := 'metrics-factory';
  // In a variable: a new object passed straight to a const interface
  // parameter is never released.
  LProvider := TUnusedProvider.Create;
  LFactory := TDBFactory.Create(LConfig, LProvider, nil, nil);
  TAssert.AssertEquals('The configured name', 7,
    MetricValue('db.client.connection.max', ['metrics-factory']), 0);
  LFactory := nil;
  TAssert.AssertEquals('Given back', 0, MetricValue('db.client.connection.max', ['metrics-factory']), 0);

  LConfig.PoolName := '';
  LFactory := TDBFactory.Create(LConfig, LProvider, nil, nil);
  TAssert.AssertEquals('Without a name: the db.system.name', 7,
    MetricValue('db.client.connection.max', ['postgresql']), 0);
  LFactory := nil;
end;

initialization
  TDUnitX.RegisterTestFixture(TPoolMetricsTests);

end.
