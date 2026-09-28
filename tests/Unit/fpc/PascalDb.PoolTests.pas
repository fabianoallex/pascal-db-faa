unit PascalDb.PoolTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.PoolTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the connection pool (PascalDb.Pool) over fake connections,
  transactions and queries: acquire/release, limit and timeout, ramp-up with
  the database offline, liveness check, idle sweep (fake clock and real
  thread), discard of a connection broken during use (including an Access
  Violation while reading a field), events, snapshot and concurrency.

  The monotonic clock and Sleep are replaced through PascalDb.SystemContext
  (TFakeTicker, TFakeSleep); events are recorded by TPoolEventRecorder — a method, not a
  closure, because TPoolEventProc is "of object" in FPC 3.2.2.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

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

  { ITestableTransaction — test extension to inspect the recorded commands }

  ITestableTransaction = interface(ITransaction)
    ['{AEB38845-ABBF-4DC2-808F-2EACAC280440}']
    function GetCommands: TStringList;
    function GetCommitCount: Integer;
    function GetRollbackCount: Integer;
  end;

  { TFakeSleep }

  { TPoolEventRecorder

    Records the pool's events in a list, for the tests to inspect afterwards.
    A method (OnEvent) instead of a closure: TPoolEventProc is "of object" in
    FPC 3.2.2 (see PASCALDB_FUNCREFS in pascaldb.inc), and a method is the
    subset that compiles on both compilers. }

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

  { TFakeTicker
    Monotonic clock under the test's control: each NowMs call returns the
    next queued reading, or the default one when the queue is empty. }

  TFakeTicker = class(TInterfacedObject, ITicker)
  private
    FTimes: TQueue<UInt64>;
    FDefaultMs: UInt64;
  public
    constructor Create;
    destructor Destroy; override;
    function NowMs: UInt64;
    procedure EnqueueMs(AMs: UInt64);
    procedure SetDefaultMs(AMs: UInt64);
  end;

  { TJumpingClock
    Wall clock that moves one hour forward on every read, as if the system
    time were changed between any two calls. The pool must not notice it. }

  TJumpingClock = class(TInterfacedObject, IClock)
  private
    FNow: TDateTime;
  public
    constructor Create;
    function Now: TDateTime;
    function Date: TDateTime;
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
    // Mutable on purpose — tests use it to simulate the driver detecting the
    // lost connection (IsConnected = False) after Open/ExecSql fails.
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
    IQueryResult mock whose methods can be configured to raise an exception —
    used to reproduce the real scenario (Access Violation while reading a
    field, after Open had already returned successfully) that
    TQueryWrapper.Open alone didn't cover — see TQueryResultWrapper
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
    // For Test_Pool_ConnectionDiscarded_* / Test_Pool_ConnectionKept_* —
    // makes the next Open raise AExceptionClass instead of returning nil.
    procedure SetRaiseOnOpen(AExceptionClass: ExceptClass; const AMsg: string);
    // Test_Pool_ConnectionDiscarded_ExceptionWhileReadingField — Open returns
    // AResult (instead of nil) when no SetRaiseOnOpen is configured.
    procedure SetOpenResult(AResult: IQueryResult);
  end;

  { TDBFactoryMock }

  TDBFactoryMock = class(TInterfacedObject, IDBFactory)
  private
    // How many upcoming TestConnection calls must fail, decremented on each
    // call until it reaches 0 (see FailNextTestConnections).
    FTestConnectionFailuresRemaining: Integer;
    FTestedConnections: TList<IDBConnection>;
    FLastCreatedConnection: TFakeDBConnection;
    FNextQueryOpenExceptionClass: ExceptClass;
    FNextQueryOpenExceptionMsg: string;
    FNextQueryOpenResult: IQueryResult;
    // Test_Pool_IniConnections_DatabaseOffline_* — how many upcoming calls to
    // CreateConnection must simulate "database offline" (Connect failing),
    // decremented on each call until it reaches 0.
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
    // Consumed once by the next CreateQuery — used by the broken-connection
    // discard tests (see TFakeQuery.SetRaiseOnOpen).
    procedure RaiseOnNextQueryOpen(AExceptionClass: ExceptClass; const AMsg: string = 'fake error');
    // Consumed once by the next CreateQuery — that query's Open returns
    // AResult (successfully) instead of nil (see TFakeQuery.SetOpenResult).
    procedure SetNextQueryOpenResult(AResult: IQueryResult);
    // Makes the next ACount calls to CreateConnection raise an exception
    // (simulates Connect failing because the database is offline).
    procedure SimulateCreateConnectionFail(ACount: Integer);
    // Makes the next ACount calls to TestConnection return False (a dead
    // connection); the ones after that return True again.
    procedure FailNextTestConnections(ACount: Integer);
    property TestedConnections: TList<IDBConnection> read FTestedConnections;
    // Last TFakeDBConnection created by CreateConnection — tests use it to
    // simulate IsConnected dropping after a failure (see TFakeDBConnection.Connected).
    property LastCreatedConnection: TFakeDBConnection read FLastCreatedConnection;
  end;

  { TPoolStressThread
    Acquires and releases pool connections repeatedly to test concurrency. }

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
    procedure MaxConnectionsExceeded_Method;
  published
    procedure Test_Pool_StartsEmpty;
    procedure Test_Pool_IniConnections;
    procedure Test_Pool_MaxConnections_Exceeded;
    procedure Test_Pool_AcquireAndRelease;
    procedure Test_Pool_CreatesNewConnection_WhenEmpty;
    procedure Test_Pool_AcquireQuery;
    procedure Test_Pool_AcquireQueries_SameTransaction;
    procedure Test_Pool_AcquireQueries_DifferentTransactions;
    procedure Test_Pool_SharedTransaction_RecordsCommands;
    procedure Test_Pool_DifferentTransactions_RecordSeparateCommands;
    procedure Test_Pool_IdleConnection120s;
    procedure Test_Pool_IdleConnectionFails;
    procedure Test_Pool_ValidateIdleSeconds_Configurable;
    procedure Test_Pool_WallClockChange_DoesNotAgeConnections;
    procedure Test_Ticker_ElapsedMs_NeverWraps;
    procedure Test_Pool_Concurrency;
    procedure Test_Pool_IdleTimeout_Off_EvictsNothing;
    procedure Test_Pool_IdleTimeout_EvictsOnlyTheOldest;
    procedure Test_Pool_IdleTimeout_RespectsIniConnectionsFloor;
    procedure Test_Pool_SteadyLightLoad_LetsSurplusBeSwept;
    procedure Test_Pool_IdleTimeoutConfig_DefaultsAndValidation;
    procedure Test_Pool_IdleSweep_DestroyDoesNotHang;
    procedure Test_Pool_Concurrency_WithIdleSweepActive;
    procedure Test_Pool_Event_ConnectionCreated_FiresOnGrowth;
    procedure Test_Pool_Event_ConnectionDiscarded_TestConnectionFails;
    procedure Test_Pool_Event_AcquireTimeout_FiresBeforeException;
    procedure Test_Pool_Event_IdleSweepClosed_FiresWithCount;
    procedure Test_Pool_ConnectionDiscarded_ExternalException;
    procedure Test_Pool_ConnectionDiscarded_IsConnectedFalseAfterException;
    procedure Test_Pool_ConnectionKept_BusinessException;
    procedure Test_Pool_ConnectionDiscarded_ExceptionWhileReadingField;
    procedure Test_EDatabaseUnavailableException_PreservesOriginalDetail;
    procedure Test_Pool_IniConnections_DatabaseOffline_DoesNotRaise;
    procedure Test_Pool_IniConnections_DatabaseOffline_RecoversOnNextAcquire;
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
  // No real waiting, but yield the CPU: a waiting thread that retried in a
  // tight loop could burn all its WaitMaxAttemps before the threads holding
  // the connections got scheduled — flaky on Linux containers with few cores.
  TThread.Yield;
end;

{ TFakeTicker }

constructor TFakeTicker.Create;
begin
  FTimes := TQueue<UInt64>.Create;
  FDefaultMs := 0;
end;

destructor TFakeTicker.Destroy;
begin
  FTimes.Free;
  inherited Destroy;
end;

function TFakeTicker.NowMs: UInt64;
begin
  if FTimes.Count > 0 then
    Result := FTimes.Dequeue
  else
    Result := FDefaultMs;
end;

procedure TFakeTicker.EnqueueMs(AMs: UInt64);
begin
  FTimes.Enqueue(AMs);
end;

procedure TFakeTicker.SetDefaultMs(AMs: UInt64);
begin
  FDefaultMs := AMs;
end;

{ TJumpingClock }

constructor TJumpingClock.Create;
begin
  inherited Create;
  FNow := EncodeDate(2025, 12, 28) + EncodeTime(11, 44, 18, 0);
end;

function TJumpingClock.Now: TDateTime;
begin
  FNow := FNow + (1 / 24);
  Result := FNow;
end;

function TJumpingClock.Date: TDateTime;
begin
  Result := Trunc(Now);
end;

// Ticker reading ASeconds after an arbitrary origin (T0), the unit the tests
// reason in. T0 isn't 0 so that "before T0" would still be a valid reading.
function T0Plus(ASeconds: Integer): UInt64;
begin
  Result := UInt64(1000000) + UInt64(ASeconds) * 1000;
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
  FTestedConnections := TList<IDBConnection>.Create;
end;

destructor TDBFactoryMock.Destroy;
begin
  FTestedConnections.Free;
  inherited Destroy;
end;

function TDBFactoryMock.CreateConnection: IDBConnection;
var
  LConn: TFakeDBConnection;
begin
  if FCreateConnectionFailuresRemaining > 0 then
  begin
    Dec(FCreateConnectionFailuresRemaining);
    raise Exception.Create('fake connect failure (database offline)');
  end;

  // The pool calls this from several threads at once (outside its lock).
  // Result must come from the local, never from re-reading the shared
  // field: another thread may have overwritten it in between, leaving this
  // connection unreferenced (a leak) and handing the other one out twice
  // (freed while still in use: EInvalidPointer).
  LConn := TFakeDBConnection.Create;
  Result := LConn;
  FLastCreatedConnection := LConn;
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
  Result := FTestConnectionFailuresRemaining <= 0;
  if not Result then
    Dec(FTestConnectionFailuresRemaining);
end;

procedure TDBFactoryMock.FailNextTestConnections(ACount: Integer);
begin
  FTestConnectionFailuresRemaining := ACount;
end;

{ TPoolTests }

procedure TPoolTests.MaxConnectionsExceeded_Method;
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

procedure TPoolTests.Test_Pool_StartsEmpty;
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

  TAssert.AssertEquals('Empty pool: GetPoolSize must be 0 when IniConnections = 0', 0, LPool.GetPoolSize);
end;

procedure TPoolTests.Test_Pool_IniConnections;
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

  TAssert.AssertEquals('The pool must have 5 initial connections', 5, LPool.GetPoolSize);
end;

procedure TPoolTests.Test_Pool_IniConnections_DatabaseOffline_DoesNotRaise;
var
  LConfig: IConnectionPoolConfig;
  LMockFactory: TDBFactoryMock;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
  I: Integer;
begin
  // Simulates the factory being created with the database completely
  // offline: all 3 attempts of the initial ramp-up fail. The pool constructor
  // must not let the exception propagate (see CreateInitialConnections) —
  // that is exactly what guarantees that building the factory doesn't bring
  // down the whole application at boot.
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

    TAssert.AssertEquals('No connection may survive the ramp-up with the database offline', 0, LPool.GetPoolSize);
    TAssert.AssertEquals('FActiveConnections must go back to 0 after each failure (no count leak)', 0, LPool.GetActiveConnections);

    TAssert.AssertEquals('Each failure of the initial ramp-up must produce 1 pekConnectionDiscarded event', 3, LEvents.Count);
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

procedure TPoolTests.Test_Pool_IniConnections_DatabaseOffline_RecoversOnNextAcquire;
var
  LConfig: IConnectionPoolConfig;
  LMockFactory: TDBFactoryMock;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LConn: IDBConnection;
begin
  // The database comes back right after boot: the initial ramp-up fails
  // (2 attempts), but the next real AcquireConnection (first request/health
  // check) no longer has a simulated failure and must succeed normally.
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 2;
  LConfig.MaxConnections := 10;

  LMockFactory := TDBFactoryMock.Create;
  LMockFactory.SimulateCreateConnectionFail(2);
  LFactory := LMockFactory;

  LPool := TConnectionPool.Create(LFactory, LConfig);

  TAssert.AssertEquals('The initial ramp-up failed completely — the pool starts empty, not broken', 0, LPool.GetActiveConnections);

  LConn := LPool.AcquireConnection;

  TAssert.AssertTrue('Database responding again: AcquireConnection must succeed normally', Assigned(LConn));
  TAssert.AssertEquals(1, LPool.GetActiveConnections);
  TAssert.AssertEquals(Int64(1), LPool.GetSnapshot.TotalCreated);
end;

procedure TPoolTests.Test_Pool_MaxConnections_Exceeded;
var
  LRaised: Boolean;
begin
  TSleep.SetSleep(TFakeSleep.Create);
  try
    LRaised := False;
    try
      MaxConnectionsExceeded_Method;
    except
      on E: EPoolTimeoutException do
        LRaised := True;
    end;
    TAssert.AssertTrue('Must raise EPoolTimeoutException when IniConnections > MaxConnections', LRaised);
  finally
    TSleep.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_AcquireAndRelease;
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

  TAssert.AssertEquals('1. The pool must have 3 connections', 3, LPool.GetPoolSize);

  LConn1 := LPool.AcquireConnection;
  TAssert.AssertEquals('2. The pool must have 2 connections after 1 acquire', 2, LPool.GetPoolSize);

  LConn2 := LPool.AcquireConnection;
  TAssert.AssertEquals('3. The pool must have 1 connection after 2 acquires', 1, LPool.GetPoolSize);

  LConn2 := nil;
  TAssert.AssertEquals('4. The pool must have 2 connections after releasing LConn2', 2, LPool.GetPoolSize);

  LConn1 := nil;
  TAssert.AssertEquals('5. The pool must have 3 connections after releasing LConn1', 3, LPool.GetPoolSize);
end;

procedure TPoolTests.Test_Pool_CreatesNewConnection_WhenEmpty;
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

  TAssert.AssertEquals('1. The pool must have 0 idle connections', 0, LPool.GetPoolSize);
  TAssert.AssertEquals('2. The pool must have 0 active connections', 0, LPool.GetActiveConnections);

  LConn := LPool.AcquireConnection;

  TAssert.AssertEquals('3. The pool must still have 0 idle connections', 0, LPool.GetPoolSize);
  TAssert.AssertEquals('4. The pool must have 1 active connection', 1, LPool.GetActiveConnections);

  TAssert.AssertTrue('The connection must not be nil', Assigned(LConn));
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

  TAssert.AssertTrue('The query must not be nil', Assigned(LQuery));
  TAssert.AssertTrue('IScopeTransaction must not be nil', Assigned(LScope));
end;

procedure TPoolTests.Test_Pool_AcquireQueries_SameTransaction;
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

  TAssert.AssertTrue('Query1 must not be nil', Assigned(LQuery1));
  TAssert.AssertTrue('Query2 must not be nil', Assigned(LQuery2));
  TAssert.AssertTrue('The two queries must share the same transaction instance', LScope1.GetOriginalTransaction = LScope2.GetOriginalTransaction);
end;

procedure TPoolTests.Test_Pool_AcquireQueries_DifferentTransactions;
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

  TAssert.AssertTrue('Query1 must not be nil', Assigned(LQuery1));
  TAssert.AssertTrue('Query2 must not be nil', Assigned(LQuery2));
  TAssert.AssertTrue('Scope1 must not be nil', Assigned(LScope1));
  TAssert.AssertTrue('Scope2 must not be nil', Assigned(LScope2));
  TAssert.AssertTrue('The two queries must have different transaction instances', LScope1.GetOriginalTransaction <> LScope2.GetOriginalTransaction);
end;

procedure TPoolTests.Test_Pool_SharedTransaction_RecordsCommands;
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

  TAssert.AssertTrue('The transaction must implement ITestableTransaction', Supports(LScope.GetOriginalTransaction, ITestableTransaction, LTestable));
  TAssert.AssertEquals('Both commands must be recorded in the same shared transaction', 2, LTestable.GetCommands.Count);
end;

procedure TPoolTests.Test_Pool_DifferentTransactions_RecordSeparateCommands;
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

  TAssert.AssertEquals('Transaction 1 must have only 1 command', 1, LTestable1.GetCommands.Count);
  TAssert.AssertEquals('Transaction 2 must have 2 commands', 2, LTestable2.GetCommands.Count);
end;

procedure TPoolTests.Test_Pool_IdleConnection120s;

  procedure CheckSeconds(const AMessage: string; ASeconds: Integer;
    AExpectedTestedCount: Integer);
  var
    LConfig: IConnectionPoolConfig;
    LFactory: IDBFactory;
    LMockFactory: TDBFactoryMock;
    LPool: IDBConnectionPool;
    LConn: IDBConnection;
    LTicker: TFakeTicker;
  begin
    LTicker := TFakeTicker.Create;
    LTicker.SetDefaultMs(T0Plus(0));
    LTicker.EnqueueMs(T0Plus(0));          // release in CreateInitialConnections
    LTicker.EnqueueMs(T0Plus(ASeconds));   // check in AcquireConnection

    TTicker.SetTicker(LTicker);
    try
      LConfig := TConnectionPoolConfig.Create;
      LConfig.IniConnections := 1;
      LConfig.MaxConnections := 10;

      LMockFactory := TDBFactoryMock.Create;
      LFactory := LMockFactory;
      LPool := TConnectionPool.Create(LFactory, LConfig);

      TAssert.AssertEquals('No connection may have been tested before the acquire', 0, LMockFactory.TestedConnections.Count);

      LConn := LPool.AcquireConnection;

      TAssert.AssertEquals(AMessage, AExpectedTestedCount, LMockFactory.TestedConnections.Count);
    finally
      TTicker.Reset;
    end;
  end;

begin
  CheckSeconds('At 120s: must test the connection (Count=1)',  120, 1);
  CheckSeconds('At 119s: must not test (Count=0)',        119, 0);
  CheckSeconds('At 1s: must not test (Count=0)',            1, 0);
  CheckSeconds('At 5280s: must test the connection (Count=1)', 5280, 1);
end;

procedure TPoolTests.Test_Pool_IdleConnectionFails;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LMockFactory: TDBFactoryMock;
  LPool: IDBConnectionPool;
  LConn: IDBConnection;
  LTicker: TFakeTicker;
begin
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(T0Plus(0));
  // Releases during CreateInitialConnections (2 connections, in index order)
  LTicker.EnqueueMs(T0Plus(0));      // LastRelease conn1
  LTicker.EnqueueMs(T0Plus(50));     // LastRelease conn2
  // Checks in AcquireConnection (LIFO: conn2 first)
  LTicker.EnqueueMs(T0Plus(200));    // 150s for conn2 → tested → fails → removed
  LTicker.EnqueueMs(T0Plus(201));    // 201s for conn1 → tested → passes → used

  TTicker.SetTicker(LTicker);
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 2;
    LConfig.MaxConnections := 10;

    LMockFactory := TDBFactoryMock.Create;
    LFactory := LMockFactory;
    LPool := TConnectionPool.Create(LFactory, LConfig);

    TAssert.AssertEquals('The pool must have 2 active connections after initialization', 2, LPool.GetActiveConnections);

    LMockFactory.FailNextTestConnections(1);

    LConn := LPool.AcquireConnection;

    TAssert.AssertEquals('Both connections were idle long enough to be tested', 2, LMockFactory.TestedConnections.Count);
    TAssert.AssertEquals('After removing the failed connection, 1 active connection must remain', 1, LPool.GetActiveConnections);

    TAssert.AssertTrue('Must return the second (healthy) connection', Assigned(LConn));
  finally
    TTicker.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_ValidateIdleSeconds_Configurable;

  procedure Check(const AMessage: string; AValidateIdleSeconds, AIdleSeconds: Integer;
    AExpectedTestedCount: Integer);
  var
    LConfig: IConnectionPoolConfig;
    LFactory: IDBFactory;
    LMockFactory: TDBFactoryMock;
    LPool: IDBConnectionPool;
    LConn: IDBConnection;
    LTicker: TFakeTicker;
  begin
    LTicker := TFakeTicker.Create;
    LTicker.SetDefaultMs(T0Plus(0));
    LTicker.EnqueueMs(T0Plus(0));             // release in CreateInitialConnections
    LTicker.EnqueueMs(T0Plus(AIdleSeconds));  // check in AcquireConnection

    TTicker.SetTicker(LTicker);
    try
      LConfig := TConnectionPoolConfig.Create;
      LConfig.IniConnections := 1;
      LConfig.MaxConnections := 10;
      LConfig.ValidateIdleSeconds := AValidateIdleSeconds;

      LMockFactory := TDBFactoryMock.Create;
      LFactory := LMockFactory;
      LPool := TConnectionPool.Create(LFactory, LConfig);

      LConn := LPool.AcquireConnection;

      TAssert.AssertEquals(AMessage, AExpectedTestedCount, LMockFactory.TestedConnections.Count);
    finally
      TTicker.Reset;
    end;
  end;

var
  LConfig: IConnectionPoolConfig;
begin
  LConfig := TConnectionPoolConfig.Create;
  TAssert.AssertEquals('ValidateIdleSeconds must default to 120', 120, LConfig.ValidateIdleSeconds);
  LConfig.ValidateIdleSeconds := -1;
  TAssert.AssertEquals('A negative ValidateIdleSeconds must be kept (it means never)', -1, LConfig.ValidateIdleSeconds);

  Check('0 = always: a connection idle for 0s must be tested',         0,    0, 1);
  Check('30: idle for 30s must be tested',                            30,   30, 1);
  Check('30: idle for 29s must not be tested',                        30,   29, 0);
  Check('Negative = never: idle for 5280s must not be tested',        -1, 5280, 0);
end;

procedure TPoolTests.Test_Pool_WallClockChange_DoesNotAgeConnections;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LMockFactory: TDBFactoryMock;
  LPoolIntf: IDBConnectionPool; // see the comment in Test_Pool_IdleTimeout_Off_EvictsNothing
  LPool: TConnectionPool;
  LConn: IDBConnection;
  LTicker: TFakeTicker;
begin
  // The wall clock moves an hour on every read; the monotonic one stands
  // still. With idle times measured on the wall clock, the acquire below
  // pinged the connection (an hour "idle") and the sweep closed it.
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(T0Plus(0));
  TTicker.SetTicker(LTicker);
  TClock.SetClock(TJumpingClock.Create);
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 0;
    LConfig.MaxConnections := 10;

    LMockFactory := TDBFactoryMock.Create;
    LFactory := LMockFactory;
    LPoolIntf := TConnectionPool.Create(LFactory, LConfig);
    LPool := LPoolIntf as TConnectionPool;

    LConn := LPoolIntf.AcquireConnection;
    LConn := nil;
    LConn := LPoolIntf.AcquireConnection;
    TAssert.AssertEquals('A wall-clock change must not trigger the liveness check', 0, LMockFactory.TestedConnections.Count);
    LConn := nil;

    LPool.SweepIdleConnections(60);
    TAssert.AssertEquals('A wall-clock change must not make the sweep close anything', 1, LPoolIntf.GetPoolSize);
  finally
    TClock.Reset;
    TTicker.Reset;
  end;
end;

procedure TPoolTests.Test_Ticker_ElapsedMs_NeverWraps;
var
  LTicker: TFakeTicker;
begin
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(T0Plus(10));
  TTicker.SetTicker(LTicker);
  try
    TAssert.AssertTrue('Elapsed time from 4s before now must be 4000ms', TTicker.ElapsedMs(T0Plus(6)) = 4000);
    TAssert.AssertTrue('Elapsed time from now must be 0', TTicker.ElapsedMs(T0Plus(10)) = 0);
    TAssert.AssertTrue('A start ahead of now must give 0, not a wrapped UInt64', TTicker.ElapsedMs(T0Plus(20)) = 0);
  finally
    TTicker.Reset;
  end;
end;

{ TPoolStressThread }

constructor TPoolStressThread.Create(APool: IDBConnectionPool; AIterations: Integer);
begin
  inherited Create(True); // suspended — waits for an explicit call to Start
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
      LConn := nil; // release immediately → back to the pool
    end;
  except
    on E: Exception do
    begin
      FErrorOccurred := True;
      FErrorMessage := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

procedure TPoolTests.Test_Pool_Concurrency;
const
  NUM_THREADS = 20;
  ITERATIONS   = 50;
  MAX_CONNS   = 5;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LThreads: array[1..NUM_THREADS] of TPoolStressThread;
  I: Integer;
begin
  // Real (1 ms) waits on purpose, not TFakeSleep: with instant retries a
  // waiting thread could burn all its attempts before the threads holding
  // the connections got scheduled — the test then depended on the OS
  // scheduler and was flaky on Linux. 2000 × 1 ms is a generous budget.
  TSleep.Reset;
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections  := 0;
    LConfig.MaxConnections  := MAX_CONNS;
    LConfig.WaitMaxAttemps  := 2000;
    LConfig.WaitMilliseconds := 1;

    LFactory := TDBFactoryMock.Create;
    LPool := TConnectionPool.Create(LFactory, LConfig);

    // Create every thread suspended
    for I := 1 to NUM_THREADS do
      LThreads[I] := TPoolStressThread.Create(LPool, ITERATIONS);

    // Start them all at once to force real concurrency
    for I := 1 to NUM_THREADS do
      LThreads[I].Start;

    // Wait for each thread and check it didn't report an error
    for I := 1 to NUM_THREADS do
    begin
      LThreads[I].WaitFor;
      TAssert.AssertFalse(Format('Thread %d reported an error: %s', [I, LThreads[I].ErrorMessage]), LThreads[I].ErrorOccurred);
      LThreads[I].Free;
    end;

    // After every thread finishes, no connection may still be in use:
    // GetPoolSize (idle) must equal GetActiveConnections (total physical created)
    TAssert.AssertEquals('Every physical connection must be back in the pool — no leak', LPool.GetActiveConnections, LPool.GetPoolSize);

    TAssert.AssertTrue('The pool must never have created more connections than the maximum', LPool.GetActiveConnections <= MAX_CONNS);
  finally
    TSleep.Reset;
  end;
end;

{ TPoolTests — idle timeout }

procedure TPoolTests.Test_Pool_IdleTimeout_Off_EvictsNothing;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  // LPoolIntf holds the counted reference from start to end (same pattern as
  // the original tests, e.g. Test_Pool_AcquireAndRelease) — without it, the
  // Acquire/release cycles below drop TConnectionPool's count to zero in the
  // middle of the test and TInterfacedObject's automatic _Release destroys
  // the pool right there; the explicit LPool.Free at the end becomes a double
  // free. LPool is just a "view" of the concrete class, to call
  // SweepIdleConnections (which isn't part of IDBConnectionPool) — never Free
  // it.
  LPoolIntf: IDBConnectionPool;
  LPool: TConnectionPool;
  LTicker: TFakeTicker;
  LConn1, LConn2: IDBConnection;
begin
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(T0Plus(0));
  TTicker.SetTicker(LTicker);
  try
    // IdleTimeoutSeconds not configured -> stays 0 = off (default)
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 0;
    LConfig.MaxConnections := 10;

    LFactory := TDBFactoryMock.Create;
    LPoolIntf := TConnectionPool.Create(LFactory, LConfig);
    LPool := LPoolIntf as TConnectionPool;

    LConn1 := LPoolIntf.AcquireConnection;
    LConn2 := LPoolIntf.AcquireConnection;
    LConn1 := nil;
    LConn2 := nil; // 2 idle connections in the pool

    TAssert.AssertEquals('Precondition: 2 idle connections', 2, LPoolIntf.GetPoolSize);

    LTicker.SetDefaultMs(T0Plus(100000)); // well beyond any reasonable limit
    LPool.SweepIdleConnections;

    TAssert.AssertEquals('IdleTimeoutSeconds=0 (default): SweepIdleConnections must not remove anything', 2, LPoolIntf.GetPoolSize);
    TAssert.AssertEquals('IdleTimeoutSeconds=0 (default): the active count must not change', 2, LPoolIntf.GetActiveConnections);
  finally
    TTicker.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_IdleTimeout_EvictsOnlyTheOldest;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPoolIntf: IDBConnectionPool; // see the comment in Test_Pool_IdleTimeout_Off_EvictsNothing
  LPool: TConnectionPool;
  LTicker: TFakeTicker;
  LConn1, LConn2, LConn3: IDBConnection;
begin
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(T0Plus(0));
  TTicker.SetTicker(LTicker);
  try
    // IdleTimeoutSeconds stays 0 (default) on purpose: that way NO sweep
    // thread is created — the test calls SweepIdleConnections(60) directly,
    // on the test's own thread, with TFakeTicker. Deterministic, with no
    // concurrency involved at all.
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 0;
    LConfig.MaxConnections := 10;

    LFactory := TDBFactoryMock.Create;
    LPoolIntf := TConnectionPool.Create(LFactory, LConfig);
    LPool := LPoolIntf as TConnectionPool;

    LConn1 := LPoolIntf.AcquireConnection;
    LConn2 := LPoolIntf.AcquireConnection;
    LConn3 := LPoolIntf.AcquireConnection;
    TAssert.AssertEquals('Precondition: 3 active connections', 3, LPoolIntf.GetActiveConnections);

    LTicker.SetDefaultMs(T0Plus(0));
    LConn1 := nil; // LastRelease = T0        (65s old at the sweep below)
    LTicker.SetDefaultMs(T0Plus(10));
    LConn2 := nil; // LastRelease = T0+10s     (55s old — must NOT go)
    LTicker.SetDefaultMs(T0Plus(20));
    LConn3 := nil; // LastRelease = T0+20s     (45s old — must NOT go)

    TAssert.AssertEquals('Precondition: 3 idle connections in the pool', 3, LPoolIntf.GetPoolSize);

    LTicker.SetDefaultMs(T0Plus(65)); // "now" = T0+65s
    LPool.SweepIdleConnections(60);

    TAssert.AssertEquals('Only the connection released at T0 (65s old, >=60) must be removed', 2, LPoolIntf.GetPoolSize);
    TAssert.AssertEquals('FActiveConnections must follow the removal', 2, LPoolIntf.GetActiveConnections);
  finally
    TTicker.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_IdleTimeout_RespectsIniConnectionsFloor;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPoolIntf: IDBConnectionPool; // see the comment in Test_Pool_IdleTimeout_Off_EvictsNothing
  LPool: TConnectionPool;
  LTicker: TFakeTicker;
  LConn1, LConn2, LConn3: IDBConnection;
begin
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(T0Plus(0));
  TTicker.SetTicker(LTicker);
  try
    // IdleTimeoutSeconds stays 0 (default) on purpose — see the comment in
    // Test_Pool_IdleTimeout_EvictsOnlyTheOldest.
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 2; // floor: never evict below this
    LConfig.MaxConnections := 10;

    LFactory := TDBFactoryMock.Create;
    LPoolIntf := TConnectionPool.Create(LFactory, LConfig);
    LPool := LPoolIntf as TConnectionPool;

    // CreateInitialConnections already left 2 idle (LastRelease = T0).
    // Drain both (reuse) and force the creation of a new 3rd one, then
    // release all 3 — to have 3 really idle connections, all old enough.
    LConn1 := LPoolIntf.AcquireConnection; // reuses one of the 2 in the pool
    LConn2 := LPoolIntf.AcquireConnection; // reuses the other
    LConn3 := LPoolIntf.AcquireConnection; // pool empty now -> creates a new one (3rd physical)
    LConn1 := nil;
    LConn2 := nil;
    LConn3 := nil;
    TAssert.AssertEquals('Precondition: 3 idle connections', 3, LPoolIntf.GetPoolSize);

    // All of them WAY past the 60s limit — without a floor, it would evict everything.
    LTicker.SetDefaultMs(T0Plus(100000));
    LPool.SweepIdleConnections(60);

    TAssert.AssertEquals('Must never evict below IniConnections, even with all of them old', 2, LPoolIntf.GetPoolSize);
    TAssert.AssertEquals('FActiveConnections must stop at the floor too', 2, LPoolIntf.GetActiveConnections);
  finally
    TTicker.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_SteadyLightLoad_LetsSurplusBeSwept;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPoolIntf: IDBConnectionPool; // see the comment in Test_Pool_IdleTimeout_Off_EvictsNothing
  LPool: TConnectionPool;
  LTicker: TFakeTicker;
  LConn1, LConn2, LConn3: IDBConnection;
  I: Integer;
begin
  // A peak opened 3 connections; after it, one request every 10 s, which
  // one connection serves easily. When the pool was FIFO, the requests went
  // round the 3 connections, each was idle only 30 s at a time, and a 60 s
  // sweep never closed any of them. LIFO keeps reusing the same one, so the
  // other two age out.
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(T0Plus(0));
  TTicker.SetTicker(LTicker);
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 0;
    LConfig.MaxConnections := 10;

    LFactory := TDBFactoryMock.Create;
    LPoolIntf := TConnectionPool.Create(LFactory, LConfig);
    LPool := LPoolIntf as TConnectionPool;

    LConn1 := LPoolIntf.AcquireConnection;
    LConn2 := LPoolIntf.AcquireConnection;
    LConn3 := LPoolIntf.AcquireConnection;
    LConn1 := nil;
    LConn2 := nil;
    LConn3 := nil;
    TAssert.AssertEquals('Precondition: 3 idle connections after the peak', 3, LPoolIntf.GetPoolSize);

    for I := 1 to 10 do
    begin
      LTicker.SetDefaultMs(T0Plus(I * 10));
      LConn1 := LPoolIntf.AcquireConnection;
      LConn1 := nil;
    end;

    LPool.SweepIdleConnections(60); // "now" = T0+100s
    TAssert.AssertEquals('Only the connection doing the work may stay open', 1, LPoolIntf.GetPoolSize);
    TAssert.AssertEquals('The swept connections must leave the active count', 1, LPoolIntf.GetActiveConnections);
  finally
    TTicker.Reset;
  end;
end;

procedure TPoolTests.Test_Pool_IdleTimeoutConfig_DefaultsAndValidation;
var
  LConfig: IConnectionPoolConfig;
begin
  LConfig := TConnectionPoolConfig.Create;

  TAssert.AssertEquals('IdleTimeoutSeconds must default to 0 (off)', 0, LConfig.IdleTimeoutSeconds);
  TAssert.AssertEquals('IdleCheckIntervalMs must default to 30000ms', 30000, LConfig.IdleCheckIntervalMs);

  LConfig.IdleCheckIntervalMs := 0;
  TAssert.AssertEquals('IdleCheckIntervalMs <= 0 must be ignored (keeps the default)', 30000, LConfig.IdleCheckIntervalMs);

  LConfig.IdleCheckIntervalMs := -5;
  TAssert.AssertEquals('A negative IdleCheckIntervalMs must be ignored', 30000, LConfig.IdleCheckIntervalMs);

  LConfig.IdleCheckIntervalMs := 5000;
  TAssert.AssertEquals('A valid IdleCheckIntervalMs must be accepted', 5000, LConfig.IdleCheckIntervalMs);

  LConfig.IdleTimeoutSeconds := -1;
  TAssert.AssertEquals('A negative IdleTimeoutSeconds must be ignored', 0, LConfig.IdleTimeoutSeconds);

  LConfig.IdleTimeoutSeconds := 45;
  TAssert.AssertEquals('A valid IdleTimeoutSeconds (>=0) must be accepted', 45, LConfig.IdleTimeoutSeconds);
end;

procedure TPoolTests.Test_Pool_IdleSweep_DestroyDoesNotHang;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: TConnectionPool;
  LStart, LElapsed: UInt64;
begin
  // No TFakeTicker/TFakeSleep here on purpose: we want the REAL sweep thread
  // running, to prove Destroy neither hangs nor raises an AV with it alive.
  LConfig := TConnectionPoolConfig.Create;
  LConfig.IniConnections := 1;
  LConfig.MaxConnections := 10;
  LConfig.IdleTimeoutSeconds := 1;
  LConfig.IdleCheckIntervalMs := 5000; // irrelevant: SetEvent wakes it immediately, it doesn't wait this long

  LFactory := TDBFactoryMock.Create;
  LPool := TConnectionPool.Create(LFactory, LConfig);

  LStart := PdbTickMs;
  LPool.Free;
  LElapsed := PdbTickMs - LStart;

  TAssert.AssertTrue(Format('Destroy with an active sweep should be almost instant (SetEvent), took %dms',
      [LElapsed]), LElapsed < 2000);
end;

procedure TPoolTests.Test_Pool_Concurrency_WithIdleSweepActive;
const
  NUM_THREADS = 20;
  ITERATIONS   = 50;
  MAX_CONNS   = 5;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LThreads: array[1..NUM_THREADS] of TPoolStressThread;
  I: Integer;
begin
  // Same as Test_Pool_Concurrency, but with the REAL sweep thread active and
  // running in parallel (short interval) — covers the lock between
  // concurrent Acquire/Release and SweepIdleConnections at the same time.
  // Real 1 ms waits for the same reason as in Test_Pool_Concurrency.
  TSleep.Reset;
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections  := 0;
    LConfig.MaxConnections  := MAX_CONNS;
    LConfig.WaitMaxAttemps  := 2000;
    LConfig.WaitMilliseconds := 1;
    LConfig.IdleTimeoutSeconds := 1;
    LConfig.IdleCheckIntervalMs := 5;

    LFactory := TDBFactoryMock.Create;
    LPool := TConnectionPool.Create(LFactory, LConfig);

    for I := 1 to NUM_THREADS do
      LThreads[I] := TPoolStressThread.Create(LPool, ITERATIONS);

    for I := 1 to NUM_THREADS do
      LThreads[I].Start;

    for I := 1 to NUM_THREADS do
    begin
      LThreads[I].WaitFor;
      TAssert.AssertFalse(Format('Thread %d reported an error: %s', [I, LThreads[I].ErrorMessage]), LThreads[I].ErrorOccurred);
      LThreads[I].Free;
    end;

    TAssert.AssertEquals('Even with a concurrent sweep, every physical connection must be either active or in the pool — no leak', LPool.GetActiveConnections, LPool.GetPoolSize);
    TAssert.AssertTrue('The pool must never have created more connections than the maximum', LPool.GetActiveConnections <= MAX_CONNS);
  finally
    TSleep.Reset;
  end;
end;

{ TPoolTests — events and snapshot }

procedure TPoolTests.Test_Pool_Event_ConnectionCreated_FiresOnGrowth;
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

    TAssert.AssertEquals('Without IniConnections, building the pool must not fire events', 0, LEvents.Count);

    LConn := LPool.AcquireConnection;

    TAssert.AssertEquals('Creating 1 physical connection must fire exactly 1 pekConnectionCreated event', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekConnectionCreated), Ord(LEvents[0].Kind));
    TAssert.AssertEquals(1, LEvents[0].ActiveConnections);
    TAssert.AssertEquals(10, LEvents[0].MaxConnections);

    TAssert.AssertEquals(Int64(1), LPool.GetSnapshot.TotalCreated);
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_Event_ConnectionDiscarded_TestConnectionFails;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LMockFactory: TDBFactoryMock;
  LPool: IDBConnectionPool;
  LConn: IDBConnection;
  LTicker: TFakeTicker;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
begin
  // Same scenario as Test_Pool_IdleConnectionFails: 2 connections in the
  // ramp-up, the 1st tested fails the liveness check (>=120s idle) and is
  // discarded, the 2nd passes and is reused.
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(T0Plus(0));
  LTicker.EnqueueMs(T0Plus(0));      // LastRelease conn1
  LTicker.EnqueueMs(T0Plus(50));     // LastRelease conn2
  LTicker.EnqueueMs(T0Plus(200));    // 150s for conn2 → tested → fails → removed
  LTicker.EnqueueMs(T0Plus(201));    // 201s for conn1 → tested → passes → used

  TTicker.SetTicker(LTicker);
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

    LEvents.Clear; // drop the 2 pekConnectionCreated events from the initial ramp-up

    LMockFactory.FailNextTestConnections(1);
    LConn := LPool.AcquireConnection;

    TAssert.AssertEquals('Discarding the dead connection must fire exactly 1 pekConnectionDiscarded event', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekConnectionDiscarded), Ord(LEvents[0].Kind));
    TAssert.AssertEquals(Ord(pdrStaleCheckFailed), Ord(LEvents[0].DiscardReason));
    TAssert.AssertEquals('After the discard, ActiveConnections must reflect only the remaining connection', 1, LEvents[0].ActiveConnections);

    TAssert.AssertEquals(Int64(2), LPool.GetSnapshot.TotalCreated);
    TAssert.AssertEquals(Int64(1), LPool.GetSnapshot.TotalDiscarded);
  finally
    TTicker.Reset;
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_Event_AcquireTimeout_FiresBeforeException;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
  LEvent: TPoolEvent;
  LRaised: Boolean;
  LTimeoutCount: Integer;
begin
  // Same scenario as Test_Pool_MaxConnections_Exceeded: IniConnections (5) >
  // MaxConnections (3) forces the ramp-up to raise EPoolTimeoutException.
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

    TAssert.AssertTrue('Should have raised EPoolTimeoutException', LRaised);

    LTimeoutCount := 0;
    for LEvent in LEvents do
      if LEvent.Kind = pekAcquireTimeout then
        Inc(LTimeoutCount);

    TAssert.AssertEquals('Must fire exactly 1 pekAcquireTimeout event, right before the exception', 1, LTimeoutCount);
  finally
    TSleep.Reset;
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_Event_IdleSweepClosed_FiresWithCount;
var
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPoolIntf: IDBConnectionPool; // see the comment in Test_Pool_IdleTimeout_Off_EvictsNothing
  LPool: TConnectionPool;
  LTicker: TFakeTicker;
  LConn1, LConn2, LConn3: IDBConnection;
  LEvents: TList<TPoolEvent>;
  LRecorder: TPoolEventRecorder;
begin
  // Same scenario as Test_Pool_IdleTimeout_EvictsOnlyTheOldest: only the
  // connection released the longest ago must be closed by the sweep.
  LTicker := TFakeTicker.Create;
  LTicker.SetDefaultMs(T0Plus(0));
  TTicker.SetTicker(LTicker);
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

    LTicker.SetDefaultMs(T0Plus(0));
    LConn1 := nil; // LastRelease = T0        (65s old at the sweep below)
    LTicker.SetDefaultMs(T0Plus(10));
    LConn2 := nil; // LastRelease = T0+10s     (55s old — must NOT go)
    LTicker.SetDefaultMs(T0Plus(20));
    LConn3 := nil; // LastRelease = T0+20s     (45s old — must NOT go)

    LEvents.Clear; // drop the 3 pekConnectionCreated events from the growth above

    LTicker.SetDefaultMs(T0Plus(65)); // "now" = T0+65s
    LPool.SweepIdleConnections(60);

    TAssert.AssertEquals('A sweep that closes connections must fire exactly 1 pekIdleSweepClosed event', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekIdleSweepClosed), Ord(LEvents[0].Kind));
    TAssert.AssertEquals('Only the oldest connection (65s old, >=60) must have been closed', 1, LEvents[0].ClosedCount);

    TAssert.AssertEquals(Int64(1), LPoolIntf.GetSnapshot.TotalIdleSwept);
  finally
    TTicker.Reset;
    LRecorder.Free;
  end;
end;

{ TPoolTests — discard of a connection broken during use }

procedure TPoolTests.Test_Pool_ConnectionDiscarded_ExternalException;
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
  // Reproduces the real scenario: Query.Open blows up with EAccessViolation
  // (native driver hitting a server that went down mid-call) — the
  // connection must be discarded even if IsConnected still reports True
  // (in-memory state, not a real round-trip). BuildDatabaseException swaps
  // the AV for EDatabaseUnavailableException before re-raising — that is what
  // must reach the caller, never the raw AV (see PascalDb.Interfaces).
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
    LEvents.Clear; // drop the pekConnectionCreated event from the ramp-up

    TAssert.AssertEquals('Precondition: 1 idle connection', 1, LPool.GetPoolSize);

    LMockFactory.RaiseOnNextQueryOpen(EAccessViolation, 'fake AV');
    LQuery := nil;
    LScope := LPool.AcquireQuery(LQuery);
    TAssert.AssertEquals('The connection left the pool for the query', 0, LPool.GetPoolSize);

    LRaised := False;

    try

      LQuery.Open;

    except

      on E: EDatabaseUnavailableException do

        LRaised := True;

    end;

    TAssert.AssertTrue('Open must propagate EDatabaseUnavailableException, not the raw EAccessViolation', LRaised);

    LQuery := nil;
    LScope := nil; // release both references holding the connection

    TAssert.AssertEquals('A connection that hit EAccessViolation must not go back to the pool', 0, LPool.GetPoolSize);
    TAssert.AssertEquals('A discarded connection no longer counts as active', 0, LPool.GetActiveConnections);
    TAssert.AssertEquals('Must fire exactly 1 pekConnectionDiscarded event', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekConnectionDiscarded), Ord(LEvents[0].Kind));
    TAssert.AssertEquals(Ord(pdrBrokenAfterUse), Ord(LEvents[0].DiscardReason));
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_ConnectionDiscarded_IsConnectedFalseAfterException;
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
  // A "normal" driver exception (not EExternal), but the connection already
  // reports IsConnected=False right after — a sign of a real drop (e.g.
  // "unavailable database"), even without an AV.
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

    // Simulates the driver detecting the drop at the moment of the failure
    LMockFactory.LastCreatedConnection.Connected := False;

    LRaised := False;

    try

      LQuery.Open;

    except

      on E: EDatabaseUnavailableException do

        LRaised := True;

    end;

    TAssert.AssertTrue('Open must propagate EDatabaseUnavailableException, not the raw driver exception', LRaised);

    LQuery := nil;
    LScope := nil;

    TAssert.AssertEquals('A connection with IsConnected=False after the failure must not go back to the pool', 0, LPool.GetPoolSize);
    TAssert.AssertEquals('Must fire exactly 1 pekConnectionDiscarded event', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pdrBrokenAfterUse), Ord(LEvents[0].DiscardReason));
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_ConnectionKept_BusinessException;
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
  // Negative case, the most important of the three: a common data exception
  // (e.g. constraint violation, duplicate key) while the connection is still
  // IsConnected=True must NOT discard the connection — otherwise every
  // ordinary business error would churn connections in the pool.
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

    TAssert.AssertEquals('Precondition: 1 idle connection', 1, LPool.GetPoolSize);

    LMockFactory.RaiseOnNextQueryOpen(Exception, 'violation of PRIMARY or UNIQUE KEY constraint');
    LQuery := nil;
    LScope := LPool.AcquireQuery(LQuery);
    // LastCreatedConnection.Connected stays True (default) — the connection
    // is still healthy, only the operation failed.

    // A direct try/except (not a flag-only check) — it must confirm that the
    // propagated exception is NOT EDatabaseUnavailableException; expecting
    // just "Exception" would let even a wrong reclassification pass, since
    // EDatabaseUnavailableException also "is Exception".
    try
      LQuery.Open;
      TAssert.Fail('Open should have propagated the simulated exception');
    except
      on E: EDatabaseUnavailableException do
        TAssert.Fail('A normal data error must not become EDatabaseUnavailableException — ' +
          'the connection is healthy, only the operation failed');
      on E: Exception do
        ; // expected: the original exception, not reclassified
    end;

    LQuery := nil;
    LScope := nil;

    TAssert.AssertEquals('A business exception with a still-healthy connection must not discard the connection', 1, LPool.GetPoolSize);
    TAssert.AssertEquals('No pekConnectionDiscarded event may fire for a normal data error', 0, LEvents.Count);
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_Pool_ConnectionDiscarded_ExceptionWhileReadingField;
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
  // Reproduces the real gap found in production: Open returns successfully
  // (the server went down only later, in the middle of fetching the fields)
  // — the AV happens in a GetAsXxx/GetNullableXxx called by the repository
  // while building the response DTO, not inside Open itself. Without
  // TQueryResultWrapper, that point had no classification at all.
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
    LFakeResult.SetRaiseOnAnyCall(EAccessViolation, 'fake AV in fetch');
    LMockFactory.SetNextQueryOpenResult(LFakeResult);

    LQuery := nil;
    LScope := LPool.AcquireQuery(LQuery);

    LResult := LQuery.Open;
    TAssert.AssertTrue('Open must return successfully (the failure is only in the field read)', Assigned(LResult));

    // A direct try/except, kept inline so no extra reference to LResult is
    // held anywhere else (see the GetActiveConnections diagnostic below,
    // which tells "leaked a reference" apart from "discarded but the event
    // didn't fire"). Expects EDatabaseUnavailableException
    // (BuildDatabaseException swaps the raw AV for it before re-raising).
    LRaised := False;
    try
      LResult.GetAsString('ANY_FIELD');
    except
      on E: EDatabaseUnavailableException do
        LRaised := True;
    end;
    TAssert.AssertTrue('The field read must propagate EDatabaseUnavailableException, not the raw AV', LRaised);

    LResult := nil;
    LQuery := nil;
    LScope := nil;

    TAssert.AssertEquals('A connection that hit EAccessViolation in a field read must leave the active count (0), not stay stuck as if still in use', 0, LPool.GetActiveConnections);
    TAssert.AssertEquals('A connection that hit EAccessViolation in a field read must not go back to the pool', 0, LPool.GetPoolSize);
    TAssert.AssertEquals('Must fire exactly 1 pekConnectionDiscarded event', 1, LEvents.Count);
    TAssert.AssertEquals(Ord(pekConnectionDiscarded), Ord(LEvents[0].Kind));
    TAssert.AssertEquals(Ord(pdrBrokenAfterUse), Ord(LEvents[0].DiscardReason));
  finally
    LRecorder.Free;
  end;
end;

procedure TPoolTests.Test_EDatabaseUnavailableException_PreservesOriginalDetail;
var
  LOriginal: Exception;
  LWrapped: EDatabaseUnavailableException;
begin
  LOriginal := EAccessViolation.Create(
    'Access violation at address 00D5D0F6 in module ''App.exe''. Read of address 005B005D');
  try
    LWrapped := EDatabaseUnavailableException.Create(LOriginal);
    try
      TAssert.AssertEquals('OriginalClassName must preserve the native exception class', 'EAccessViolation', LWrapped.OriginalClassName);
      TAssert.AssertEquals('OriginalMessage must preserve the original text (AV address included)', LOriginal.Message, LWrapped.OriginalMessage);
      TAssert.AssertEquals('The public Message must not leak the AV technical text to the client', 0, Pos('Access violation', LWrapped.Message));
      TAssert.AssertTrue('The public Message must be generic and non-empty', Length(LWrapped.Message) > 0);
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
