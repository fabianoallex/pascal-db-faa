unit PascalDb.OutboxUnitTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.OutboxUnitTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the parts of PascalDb.Outbox that need no database: the retry
  delay, the default options, the lease owner's shape, a handler name taken
  twice, and what TOutbox.Enqueue writes (on TMockDBFactory: the parameters
  and the TRACE tag, with and without a current span). The relay, the local
  sink, the purge and the metrics run against every database in the
  integration suite (tests/Integration/PascalDb.OutboxTests.pas), with the
  reference SQL.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.Mock,
  PascalDb.Outbox;

type
  TOutboxUnitTests = class(TTestCase)
  published
    procedure Retry_Doubles_UpToMax;
    procedure Options_Default;
    procedure NewOwner_PrefixAndRandomHex;
    procedure LocalSink_SameHandlerNameTwice_Raises;
    procedure Enqueue_BindsTheEvent;
    procedure Enqueue_InASpan_KeepsItsTraceParent;
  end;

implementation

uses
  PascalCommon.Tracing;

type
  TNamedHandler = class(TInterfacedObject, IOutboxHandler)
  private
    FName: string;
  public
    constructor Create(const AName: string);
    function Name: string;
    function Accepts(const AKind: string): Boolean;
    procedure Handle(const AEvent: TOutboxEvent);
  end;

constructor TNamedHandler.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

function TNamedHandler.Name: string;
begin
  Result := FName;
end;

function TNamedHandler.Accepts(const AKind: string): Boolean;
begin
  Result := True;
end;

procedure TNamedHandler.Handle(const AEvent: TOutboxEvent);
begin
end;

function IsLowerHex(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := AText <> '';
  for I := 1 to Length(AText) do
    if not CharInSet(AText[I], ['0'..'9', 'a'..'f']) then
      Exit(False);
end;

// Enqueues one event on a mock and returns the mock's record of it.
function EnqueueOnMock(const AMock: TMockDBFactory; const AFactory: IDBFactory;
  out AId: string): TMockExecution;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  AId := TOutbox.Enqueue(AFactory, LQuery, 'acme', 'order.placed', '{"id":7}', 1700000000);
  LScope.Commit;
  Result := AMock.LastExecution(OUTBOX_SQL_INSERT);
end;

{ TOutboxUnitTests }

procedure TOutboxUnitTests.Retry_Doubles_UpToMax;
var
  LRetry: TOutboxRetry;
begin
  LRetry.BaseSeconds := 5;
  LRetry.MaxSeconds := 30;
  TAssert.AssertEquals(Int64(5), LRetry.DelayAfter(1));
  TAssert.AssertEquals(Int64(10), LRetry.DelayAfter(2));
  TAssert.AssertEquals(Int64(20), LRetry.DelayAfter(3));
  TAssert.AssertEquals(Int64(30), LRetry.DelayAfter(4));
  TAssert.AssertEquals(Int64(30), LRetry.DelayAfter(50));
  TAssert.AssertEquals('zero attempts: the base', Int64(5), LRetry.DelayAfter(0));
  LRetry.BaseSeconds := 0;
  TAssert.AssertEquals('a base below 1 counts as 1', Int64(1), LRetry.DelayAfter(1));
end;

procedure TOutboxUnitTests.Options_Default;
var
  LOptions: TOutboxOptions;
begin
  LOptions := TOutboxOptions.Default;
  TAssert.AssertEquals(OUTBOX_DEFAULT_BATCH_SIZE, LOptions.BatchSize);
  TAssert.AssertEquals(OUTBOX_DEFAULT_LEASE_SECONDS, LOptions.LeaseSeconds);
  TAssert.AssertEquals(OUTBOX_DEFAULT_MAX_ATTEMPTS, LOptions.MaxAttempts);
  TAssert.AssertEquals(OUTBOX_DEFAULT_RETRY_SECONDS, LOptions.Retry.BaseSeconds);
  TAssert.AssertEquals(OUTBOX_DEFAULT_MAX_RETRY_SECONDS, LOptions.Retry.MaxSeconds);
end;

procedure TOutboxUnitTests.NewOwner_PrefixAndRandomHex;
var
  LOwner: string;
begin
  LOwner := PdbOutboxNewOwner('relay');
  TAssert.AssertEquals('relay-', Copy(LOwner, 1, 6));
  TAssert.AssertEquals(6 + 16, Length(LOwner));
  TAssert.AssertTrue(LOwner, IsLowerHex(Copy(LOwner, 7, MaxInt)));
  TAssert.AssertTrue('a new one each time', LOwner <> PdbOutboxNewOwner('relay'));
end;

procedure TOutboxUnitTests.LocalSink_SameHandlerNameTwice_Raises;
var
  LMock: TMockDBFactory;
  LFactory: IDBFactory;
  LSink: IOutboxLocalSink;
  LSecond: IOutboxHandler;
  LRaised: Boolean;
begin
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  LSink := TOutboxLocalSink.Create(LFactory, 's1', TOutboxOptions.Default);
  LSink.AddHandler(TNamedHandler.Create('email'));
  LRaised := False;
  // In a variable: a new object passed straight to a const interface
  // parameter is never freed when the call raises before keeping it.
  LSecond := TNamedHandler.Create('email');
  try
    LSink.AddHandler(LSecond);
  except
    on E: EArgumentException do
      LRaised := Pos('"email"', E.Message) > 0;
  end;
  TAssert.AssertTrue('EArgumentException naming the handler', LRaised);
  LSink.AddHandler(TNamedHandler.Create('audit'));
end;

procedure TOutboxUnitTests.Enqueue_BindsTheEvent;
var
  LMock: TMockDBFactory;
  LFactory: IDBFactory;
  LExec: TMockExecution;
  LId: string;
begin
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  LExec := EnqueueOnMock(LMock, LFactory, LId);
  TAssert.AssertTrue('executed', LExec <> nil);
  TAssert.AssertFalse('through ExecSql', LExec.WasOpen);
  TAssert.AssertEquals(32, Length(LId));
  TAssert.AssertTrue(LId, IsLowerHex(LId));
  TAssert.AssertEquals(LId, LExec.AsString('ID'));
  TAssert.AssertEquals('acme', LExec.AsString('TENANT_ID'));
  TAssert.AssertEquals('order.placed', LExec.AsString('KIND'));
  TAssert.AssertEquals('{"id":7}', LExec.AsString('PAYLOAD'));
  TAssert.AssertEquals(Int64(1700000000), LExec.AsInt64('CREATED_AT'));
  TAssert.AssertFalse('no span: no trace', LExec.HasParam('TRACE_PARENT'));
end;

procedure TOutboxUnitTests.Enqueue_InASpan_KeepsItsTraceParent;
var
  LMock: TMockDBFactory;
  LFactory: IDBFactory;
  LSpan: IPcSpan;
  LTrace, LId: string;
  LExec: TMockExecution;
begin
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  LSpan := TPcTracing.StartSpan('request');
  try
    LTrace := LSpan.TraceParent;
    LExec := EnqueueOnMock(LMock, LFactory, LId);
  finally
    LSpan.Finish;
    LSpan := nil;
  end;
  TAssert.AssertEquals(55, Length(LTrace));
  TAssert.AssertEquals(LTrace, LExec.AsString('TRACE_PARENT'));
end;

initialization
  RegisterTest(TOutboxUnitTests);

end.
