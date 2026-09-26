program PoolUnderLoad;

{ Sample 05: the connection pool under concurrent load, watched through its
  events and snapshots.

  The pool here is deliberately small: 1 connection opened up front, at most
  3, a caller waits up to 20 x 100 ms for a free one, and a connection idle
  for 2 s is closed (never below the initial 1). Worker threads each take a
  query from the pool, run the dialect's ping and hold the connection for a
  while, as a request doing real work would. Three phases:
    1. 6 workers holding 200 ms: the pool grows to 3 and the other three
       wait their turn; nobody times out.
    2. 6 workers holding 4 s: three get a connection, the other three give up
       after 2 s with EPoolTimeoutException.
    3. nothing for 3.5 s: the idle sweep closes the two extra connections.

  Observing the pool: events (TPoolEvent) report only what isn't the happy
  path (growth, waiting, timeouts, discards, sweeps), never an ordinary
  acquire or release, and the pool has no default output for them. They
  arrive on whichever thread caused them (a worker, the sweep thread), so
  the handler must be thread-safe: here every console line goes through one
  lock. GetSnapshot gives the current state plus counters since the pool was
  created, for periodic reads (a health check, a metrics timer).

  Dual-compiler notes: workers are a TThread subclass (FPC 3.2.2 has no
  anonymous methods, so no TThread.CreateAnonymousThread), and the event
  handler is a method, which both compilers accept for TPoolEventProc.
  EPoolTimeoutException is the pool's own exception: the caller decides
  what a timeout means (an HTTP layer would usually answer 503).

  Timing is kept loose on purpose so the phases behave the same on a busy
  machine. Same source for Delphi (PoolUnderLoad.dproj) and Lazarus/FPC
  (PoolUnderLoad.lpi); connection settings as in sample 02. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring, // FPC on Unix: needed for non-ASCII text in Variants (see CLAUDE.md)
  {$ENDIF}
  Classes,
  SysUtils,
  SyncObjs,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Pool,
  Samples.Env;

var
  GConsole: TCriticalSection;

// Every console line, from any thread, goes through here. The Flush matters:
// on FPC, Output is per thread (a threadvar), and with the output redirected
// each thread's buffer reaches the file whenever it fills, so lines from two
// threads came out cut in the middle on Linux despite the lock (CLAUDE.md,
// gotcha 20).
procedure Say(const AText: string);
begin
  GConsole.Enter;
  try
    Writeln(AText);
    Flush(Output);
  finally
    GConsole.Leave;
  end;
end;

type
  TPoolLog = class
  private
    FLock: TCriticalSection;
    FThrottled: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    /// The TPoolEventProc handed to the factory; runs on the thread that
    /// caused the event.
    procedure OnEvent(const AEvent: TPoolEvent);
    /// How many acquires waited and then got a connection, since the last call.
    function TakeThrottled: Integer;
  end;

  TOutcome = (ocDone, ocTimedOut, ocFailed);

  TWorker = class(TThread)
  private
    FFactory: IDBFactory;
    FHoldMs: Integer;
    FOutcome: TOutcome;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFactory: IDBFactory; AHoldMs: Integer);
    property Outcome: TOutcome read FOutcome;
    property Error: string read FError;
  end;

{ TPoolLog }

constructor TPoolLog.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TPoolLog.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TPoolLog.OnEvent(const AEvent: TPoolEvent);
const
  REASONS: array[TPoolDiscardReason] of string = ('connect failed', 'liveness check failed', 'broken during use');
begin
  case AEvent.Kind of
    pekConnectionCreated:
      // ActiveConnections also counts connections other threads are still opening.
      Say(Format('  [event] connection created (%d open or opening, max %d)', [AEvent.ActiveConnections, AEvent.MaxConnections]));
    pekAcquireThrottled:
      begin
        // One per acquire that waited and then got a connection (one that
        // gives up raises pekAcquireTimeout instead): counted, not printed.
        FLock.Enter;
        try
          Inc(FThrottled);
        finally
          FLock.Leave;
        end;
      end;
    pekAcquireTimeout:
      Say(Format('  [event] acquire timed out after %d attempts', [AEvent.WaitAttempts]));
    pekConnectionDiscarded:
      Say(Format('  [event] connection discarded (%s) %s', [REASONS[AEvent.DiscardReason], AEvent.ErrorMessage]));
    pekIdleSweepClosed:
      Say(Format('  [event] idle sweep closed %d connection(s)', [AEvent.ClosedCount]));
  end;
end;

function TPoolLog.TakeThrottled: Integer;
begin
  FLock.Enter;
  try
    Result := FThrottled;
    FThrottled := 0;
  finally
    FLock.Leave;
  end;
end;

{ TWorker }

constructor TWorker.Create(const AFactory: IDBFactory; AHoldMs: Integer);
begin
  FFactory := AFactory;
  FHoldMs := AHoldMs;
  inherited Create(False);
end;

procedure TWorker.Execute;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  {$IFDEF FPC}
  I: Integer;
  {$ENDIF}
begin
  try
    // Waits (up to the pool's limit) when all connections are in use.
    LScope := FFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    try
      LQuery.Sql := LQuery.GetConnection.GetSQLDialect.GetPingSQL;
      LQuery.Open;
      Sleep(FHoldMs); // the "work": the connection stays taken meanwhile
      LScope.Commit;
    except
      LScope.Rollback;
      raise;
    end;
    FOutcome := ocDone;
  except
    on EPoolTimeoutException do
      FOutcome := ocTimedOut;
    on E: Exception do
    begin
      FOutcome := ocFailed;
      FError := E.ClassName + ': ' + E.Message;
      {$IFDEF FPC}
      // Where it happened (with line numbers when built with -gl): kept to
      // diagnose a rare access violation seen once on Zeos + Firebird under
      // this load (CLAUDE.md, "Known open items").
      FError := FError + LineEnding + BackTraceStrFunc(ExceptAddr);
      for I := 0 to ExceptFrameCount - 1 do
        FError := FError + LineEnding + BackTraceStrFunc(ExceptFrames[I]);
      {$ENDIF}
    end;
  end;
  // LQuery and LScope are released here: the connection goes back to the pool.
end;

procedure SaySnapshot(const APool: IDBConnectionPool);
var
  LSnap: TPoolSnapshot;
begin
  LSnap := APool.GetSnapshot;
  Say(Format('  pool: %d open (%d idle), max %d; since start: %d created, %d timeouts, %d swept, %d discarded',
    [LSnap.ActiveConnections, LSnap.PoolSize, LSnap.MaxConnections, LSnap.TotalCreated,
     LSnap.TotalTimeouts, LSnap.TotalIdleSwept, LSnap.TotalDiscarded]));
end;

procedure RunPhase(const AFactory: IDBFactory; ALog: TPoolLog; const ATitle: string;
  AWorkers, AHoldMs: Integer);
var
  LWorkers: array of TWorker;
  I, LDone, LTimedOut: Integer;
begin
  Say(ATitle);
  SetLength(LWorkers, AWorkers);
  for I := 0 to High(LWorkers) do
    LWorkers[I] := TWorker.Create(AFactory, AHoldMs);
  LDone := 0;
  LTimedOut := 0;
  for I := 0 to High(LWorkers) do
  begin
    LWorkers[I].WaitFor;
    case LWorkers[I].Outcome of
      ocDone: Inc(LDone);
      ocTimedOut: Inc(LTimedOut);
      ocFailed: Say('  worker failed: ' + LWorkers[I].Error);
    end;
    LWorkers[I].Free;
  end;
  Say(Format('  result: %d done, %d timed out; %d acquire(s) waited, then got a connection',
    [LDone, LTimedOut, ALog.TakeThrottled]));
  SaySnapshot(AFactory.GetPool);
  Say('');
end;

procedure Run;
var
  LLog: TPoolLog;
  LConfig: IDatabaseConfig;
  LFactory: IDBFactory;
begin
  Say('Target: ' + SampleTarget);
  LLog := TPoolLog.Create;
  try
    LConfig := NewSampleConfig(TMemorySqlSource.Create); // no SQL scripts: only the dialect's ping
    LConfig.PoolIniConnections := 1;
    LConfig.PoolMaxConnections := 3;
    LConfig.PoolWaitMaxAttemps := 20;
    LConfig.PoolWaitMilliseconds := 100;
    LConfig.PoolIdleTimeoutSeconds := 2;
    LConfig.PoolIdleCheckIntervalMs := 500;
    Say('Pool: 1 initial, max 3, waits up to 20 x 100 ms, closes connections idle for 2 s');
    // The initial connection is opened here (an event, if the handler is set).
    LFactory := NewSampleFactory(LConfig, LLog.OnEvent);
    try
      CheckSampleConnection(LFactory);
      SaySnapshot(LFactory.GetPool);
      Say('');

      RunPhase(LFactory, LLog, 'Phase 1: 6 workers, each holding a connection for 200 ms', 6, 200);
      RunPhase(LFactory, LLog, 'Phase 2: 6 workers, each holding a connection for 4 s', 6, 4000);

      Say('Phase 3: idle for 3.5 s');
      Sleep(3500);
      SaySnapshot(LFactory.GetPool);
    finally
      // Releasing the factory stops the sweep thread and closes the pool;
      // the handler must outlive it.
      LFactory := nil;
    end;
  finally
    LLog.Free;
  end;
end;

begin
  {$IFDEF FPC}
  // Plain FPC console programs don't run in UTF-8 by default (see CLAUDE.md).
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ELSE}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  GConsole := TCriticalSection.Create;
  try
    try
      Run;
    except
      on E: Exception do
      begin
        Say(E.ClassName + ': ' + E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    GConsole.Free;
  end;
end.
