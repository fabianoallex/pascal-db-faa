unit PascalDb.AfterCommitTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.AfterCommitTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the after-commit actions (PascalDb.AfterCommit), without a
  database: TTransactionBase and TScopeTransaction over TRecordingTransaction
  (from PascalDb.AdapterBaseTests) for the order, the main and nested
  commits and rollbacks, a failed commit, an action that raises (the next
  ones run, the failure is reported, EExternal propagates) and adding one
  outside a transaction; the pool's pekAfterCommitFailed event; and the
  mock's scope (TMockDBFactory), so a service's tests can see its actions
  run; and PdbInvalidateAfterCommit (PascalDb.Cache) with a
  TPcMemoryCacheStore: the entry is read until the commit, not after, and a
  rollback keeps it. The same behaviour is checked against every database by the
  integration contract tests (AfterCommit_*).

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  Classes,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlDialect,
  PascalDb.SqlLoader,
  PascalDb.Adapter.Base,
  PascalDb.AfterCommit,
  PascalDb.Pool,
  PascalDb.Mock,
  PascalDb.Cache,
  PascalCommon.Cache,
  PascalDb.PoolTests,
  PascalDb.AdapterBaseTests;

type
  { TActionLog
    The actions' callbacks, as methods (TAfterCommitProc is "of object" on
    FPC 3.2.2). Each call is a line of Lines. }
  TActionLog = class
  private
    FLines: TStringList;
    FTransaction: ITransaction;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Log(const AArg: string);
    procedure Fail(const AArg: string);
    procedure Crash(const AArg: string);
    /// Commits FTransaction again from inside an action.
    procedure Recommit(const AArg: string);
    procedure Failure(const AErrorClass, AErrorMessage: string);
    property Lines: TStringList read FLines;
    property Transaction: ITransaction read FTransaction write FTransaction;
  end;

  { TLogAction
    An IAfterCommitAction object, for PdbAfterCommitAction. }
  TLogAction = class(TInterfacedObject, IAfterCommitAction)
  private
    FLog: TActionLog;
    FText: string;
  public
    constructor Create(ALog: TActionLog; const AText: string);
    procedure Run;
  end;

  { TFailingCommitTransaction
    A TRecordingTransaction whose native commit fails. }
  TFailingCommitTransaction = class(TRecordingTransaction)
  protected
    procedure DoCommit; override;
  end;

  { TAfterCommitFactory
    TDBFactoryMock (PascalDb.PoolTests) with TTransactionBase transactions
    and real scopes, so the pool hands out transactions that keep actions. }
  TAfterCommitFactory = class(TInterfacedObject, IDBFactory)
  private
    FInner: IDBFactory;
  public
    constructor Create;
    function SqlLoader: TSQLLoader;
    function GetPool: IDBConnectionPool;
    function CreateConnection: IDBConnection;
    function CreateTransaction(AConn: IDBConnection): ITransaction;
    function CreateScopeTransaction(ATransaction: ITransaction): IScopeTransaction;
    function CreateQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function CreateSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
    function TestConnection(AConn: IDBConnection): Boolean;
  end;

  TAfterCommitTests = class(TTestCase)
  published
    procedure MainCommit_RunsActionsInOrder;
    procedure MainRollback_DropsActions;
    procedure NestedCommit_WaitsForTheMainCommit;
    procedure NestedRollback_DropsOnlyItsOwnActions;
    procedure NestedRollback_InsideACommittedNestedScope;
    procedure NoRelease_NestedCommit_WaitsForTheMainCommit;
    procedure FailedCommit_DropsActions;
    procedure ActionRaises_NextRun_CommitSucceeds_FailureReported;
    procedure ActionRaisesEExternal_Propagates;
    procedure ActionCommitsAgain_ListRunsOnce;
    procedure ObjectAction_Runs;
    procedure OutsideATransaction_Raises;
    procedure TransactionWithoutActions_Raises;
    procedure Pool_ActionRaises_ReportsEvent;
    procedure Mock_CommitRuns_RollbackDrops;
    procedure Mock_BeforeStart_Raises;
    procedure Cache_InvalidatedOnlyAfterTheCommit;
    procedure Cache_RollbackKeepsTheEntry;
    procedure Cache_NilCacheOrNoTags_DoesNothing;
  end;

implementation

function NewTransaction: TRecordingTransaction;
begin
  Result := TRecordingTransaction.Create(
    TRecordingConnection.Create(TSQLDialectFactory.GetDialect('Firebird')));
end;

{ TActionLog }

constructor TActionLog.Create;
begin
  inherited Create;
  FLines := TStringList.Create;
end;

destructor TActionLog.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

procedure TActionLog.Log(const AArg: string);
begin
  FLines.Add(AArg);
end;

procedure TActionLog.Fail(const AArg: string);
begin
  raise EConvertError.Create(AArg);
end;

procedure TActionLog.Crash(const AArg: string);
begin
  raise EAccessViolation.Create(AArg);
end;

procedure TActionLog.Recommit(const AArg: string);
begin
  FLines.Add(AArg);
  FTransaction.StartTransaction;
  FTransaction.Commit;
end;

procedure TActionLog.Failure(const AErrorClass, AErrorMessage: string);
begin
  FLines.Add('failure ' + AErrorClass + ': ' + AErrorMessage);
end;

{ TLogAction }

constructor TLogAction.Create(ALog: TActionLog; const AText: string);
begin
  inherited Create;
  FLog := ALog;
  FText := AText;
end;

procedure TLogAction.Run;
begin
  FLog.Log(FText);
end;

{ TFailingCommitTransaction }

procedure TFailingCommitTransaction.DoCommit;
begin
  raise Exception.Create('commit failed');
end;

{ TAfterCommitFactory }

constructor TAfterCommitFactory.Create;
begin
  inherited Create;
  FInner := TDBFactoryMock.Create;
end;

function TAfterCommitFactory.SqlLoader: TSQLLoader;
begin
  Result := FInner.SqlLoader;
end;

function TAfterCommitFactory.GetPool: IDBConnectionPool;
begin
  Result := nil;
end;

function TAfterCommitFactory.CreateConnection: IDBConnection;
begin
  Result := FInner.CreateConnection;
end;

function TAfterCommitFactory.CreateTransaction(AConn: IDBConnection): ITransaction;
begin
  Result := TRecordingTransaction.Create(AConn);
end;

function TAfterCommitFactory.CreateScopeTransaction(ATransaction: ITransaction): IScopeTransaction;
begin
  Result := TScopeTransaction.Create(ATransaction, nil);
end;

function TAfterCommitFactory.CreateQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
begin
  Result := FInner.CreateQuery(AConn, ATransaction);
end;

function TAfterCommitFactory.CreateSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
begin
  Result := FInner.CreateSqlScript(AConn, ATransaction);
end;

function TAfterCommitFactory.TestConnection(AConn: IDBConnection): Boolean;
begin
  Result := FInner.TestConnection(AConn);
end;

{ TAfterCommitTests }

procedure TAfterCommitTests.MainCommit_RunsActionsInOrder;
var
  LLog: TActionLog;
  LTransaction: TRecordingTransaction;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LTransaction := NewTransaction;
    LIntf := LTransaction;
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Log, 'first');
    PdbAfterCommit(LScope, LLog.Log, 'second');
    TAssert.AssertEquals('Nothing runs before the commit', 0, LLog.Lines.Count);
    LScope.Commit;
    TAssert.AssertEquals('first' + sLineBreak + 'second' + sLineBreak, LLog.Lines.Text);
    TAssert.AssertEquals('After the native commit', 'START' + sLineBreak + 'COMMIT' + sLineBreak,
      LTransaction.Log.Text);
    TAssert.AssertEquals('The list is empty after running', 0, (LIntf as IAfterCommitActions).Count);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.MainRollback_DropsActions;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := NewTransaction;
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Log, 'dropped');
    LScope.Rollback;
    TAssert.AssertEquals('The rollback drops the actions', 0, (LIntf as IAfterCommitActions).Count);
    // A later transaction on the same object doesn't run them either.
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    LScope.Commit;
    TAssert.AssertEquals('Nothing ran', 0, LLog.Lines.Count);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.NestedCommit_WaitsForTheMainCommit;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LOuter, LInner: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := NewTransaction;
    LOuter := TScopeTransaction.Create(LIntf, nil);
    LOuter.StartTransaction;
    LInner := TScopeTransaction.Create(LIntf, nil);
    LInner.StartTransaction;
    PdbAfterCommit(LInner, LLog.Log, 'inner');
    LInner.Commit;
    TAssert.AssertEquals('A nested commit is a savepoint release: nothing runs', 0, LLog.Lines.Count);
    LOuter.Commit;
    TAssert.AssertEquals('inner' + sLineBreak, LLog.Lines.Text);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.NestedRollback_DropsOnlyItsOwnActions;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LOuter, LInner: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := NewTransaction;
    LOuter := TScopeTransaction.Create(LIntf, nil);
    LOuter.StartTransaction;
    PdbAfterCommit(LOuter, LLog.Log, 'before');
    LInner := TScopeTransaction.Create(LIntf, nil);
    LInner.StartTransaction;
    PdbAfterCommit(LInner, LLog.Log, 'undone');
    LInner.Rollback;
    PdbAfterCommit(LOuter, LLog.Log, 'after');
    LOuter.Commit;
    TAssert.AssertEquals('before' + sLineBreak + 'after' + sLineBreak, LLog.Lines.Text);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.NestedRollback_InsideACommittedNestedScope;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LOuter, LMiddle, LInner: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := NewTransaction;
    LOuter := TScopeTransaction.Create(LIntf, nil);
    LOuter.StartTransaction;
    PdbAfterCommit(LOuter, LLog.Log, 'outer');
    LMiddle := TScopeTransaction.Create(LIntf, nil);
    LMiddle.StartTransaction;
    PdbAfterCommit(LMiddle, LLog.Log, 'middle');
    LInner := TScopeTransaction.Create(LIntf, nil);
    LInner.StartTransaction;
    PdbAfterCommit(LInner, LLog.Log, 'inner');
    LInner.Rollback;
    LMiddle.Commit;
    LOuter.Commit;
    TAssert.AssertEquals('outer' + sLineBreak + 'middle' + sLineBreak, LLog.Lines.Text);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.NoRelease_NestedCommit_WaitsForTheMainCommit;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LOuter, LInner: IScopeTransaction;
begin
  // SQL Server: a nested commit runs no statement at all.
  LLog := TActionLog.Create;
  try
    LIntf := TRecordingTransaction.Create(
      TRecordingConnection.Create(TSQLDialectFactory.GetDialect('mssql')));
    LOuter := TScopeTransaction.Create(LIntf, nil);
    LOuter.StartTransaction;
    LInner := TScopeTransaction.Create(LIntf, nil);
    LInner.StartTransaction;
    PdbAfterCommit(LInner, LLog.Log, 'inner');
    LInner.Commit;
    TAssert.AssertEquals('Nothing runs on the nested commit', 0, LLog.Lines.Count);
    LOuter.Commit;
    TAssert.AssertEquals('inner' + sLineBreak, LLog.Lines.Text);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.FailedCommit_DropsActions;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := TFailingCommitTransaction.Create(
      TRecordingConnection.Create(TSQLDialectFactory.GetDialect('Firebird')));
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Log, 'dropped');
    try
      LScope.Commit;
      TAssert.Fail('The commit must fail');
    except
      on E: Exception do
        TAssert.AssertEquals('commit failed', E.Message);
    end;
    TAssert.AssertEquals('Nothing ran', 0, LLog.Lines.Count);
    TAssert.AssertEquals('The actions are dropped', 0, (LIntf as IAfterCommitActions).Count);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.ActionRaises_NextRun_CommitSucceeds_FailureReported;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := NewTransaction;
    (LIntf as IAfterCommitActions).SetOnFailure(LLog.Failure);
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Fail, 'broken');
    PdbAfterCommit(LScope, LLog.Log, 'next');
    LScope.Commit;
    TAssert.AssertEquals('failure EConvertError: broken' + sLineBreak + 'next' + sLineBreak,
      LLog.Lines.Text);
    TAssert.AssertFalse('The transaction is committed', LIntf.InTransaction);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.ActionRaisesEExternal_Propagates;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := NewTransaction;
    (LIntf as IAfterCommitActions).SetOnFailure(LLog.Failure);
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Crash, 'memory');
    PdbAfterCommit(LScope, LLog.Log, 'never');
    try
      LScope.Commit;
      TAssert.Fail('An EExternal must propagate');
    except
      on E: EAccessViolation do
        TAssert.AssertEquals('memory', E.Message);
    end;
    TAssert.AssertEquals('Not reported, and the next action doesn''t run', 0, LLog.Lines.Count);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.ActionCommitsAgain_ListRunsOnce;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := NewTransaction;
    LLog.Transaction := LIntf;
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Recommit, 'once');
    LScope.Commit;
    LLog.Transaction := nil;
    TAssert.AssertEquals('once' + sLineBreak, LLog.Lines.Text);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.ObjectAction_Runs;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
  LAction: IAfterCommitAction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := NewTransaction;
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    LAction := TLogAction.Create(LLog, 'object');
    PdbAfterCommitAction(LScope, LAction);
    LAction := nil;
    LScope.Commit;
    TAssert.AssertEquals('object' + sLineBreak, LLog.Lines.Text);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.OutsideATransaction_Raises;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LIntf := NewTransaction;
    LScope := TScopeTransaction.Create(LIntf, nil);
    try
      PdbAfterCommit(LScope, LLog.Log, 'x');
      TAssert.Fail('Adding an action before StartTransaction must raise');
    except
      on E: EAfterCommitException do
        TAssert.AssertEquals(PDB_AFTER_COMMIT_NO_TRANSACTION, E.Message);
    end;
    LScope.StartTransaction;
    LScope.Commit;
    try
      PdbAfterCommit(LScope, LLog.Log, 'x');
      TAssert.Fail('Adding an action after the commit must raise');
    except
      on E: EAfterCommitException do
        TAssert.AssertEquals(PDB_AFTER_COMMIT_NO_TRANSACTION, E.Message);
    end;
    TAssert.AssertEquals('Nothing ran', 0, LLog.Lines.Count);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.TransactionWithoutActions_Raises;
var
  LLog: TActionLog;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  // TMockTransaction doesn't descend from TTransactionBase.
  LLog := TActionLog.Create;
  try
    LIntf := TMockTransaction.Create;
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    try
      PdbAfterCommit(LScope, LLog.Log, 'x');
      TAssert.Fail('A transaction without IAfterCommitActions must raise');
    except
      on E: EAfterCommitException do
        TAssert.AssertTrue('The message names the interface: ' + E.Message,
          Pos('IAfterCommitActions', E.Message) > 0);
    end;
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.Pool_ActionRaises_ReportsEvent;
var
  LLog: TActionLog;
  LRecorder: TPoolEventRecorder;
  LConfig: IConnectionPoolConfig;
  LFactory: IDBFactory;
  LPool: IDBConnectionPool;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  I, LFound: Integer;
begin
  LLog := TActionLog.Create;
  LRecorder := TPoolEventRecorder.Create;
  try
    LConfig := TConnectionPoolConfig.Create;
    LConfig.IniConnections := 0;
    LConfig.MaxConnections := 2;
    LFactory := TAfterCommitFactory.Create;
    LPool := TConnectionPool.Create(LFactory, LConfig, LRecorder.OnEvent);

    LScope := LPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Fail, 'action broke');
    PdbAfterCommit(LScope, LLog.Log, 'next');
    LScope.Commit;
    LQuery := nil;
    LScope := nil;

    TAssert.AssertEquals('The next action ran', 'next' + sLineBreak, LLog.Lines.Text);
    LFound := -1;
    for I := 0 to LRecorder.Events.Count - 1 do
      if LRecorder.Events[I].Kind = pekAfterCommitFailed then
      begin
        TAssert.AssertEquals('Exactly one pekAfterCommitFailed event', -1, LFound);
        LFound := I;
      end;
    TAssert.AssertTrue('The pool must report the failure', LFound >= 0);
    TAssert.AssertEquals('EConvertError', LRecorder.Events[LFound].ErrorClass);
    TAssert.AssertEquals('action broke', LRecorder.Events[LFound].ErrorMessage);
    LPool := nil;
    LFactory := nil;
  finally
    LRecorder.Free;
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.Mock_CommitRuns_RollbackDrops;
var
  LLog: TActionLog;
  LFactory: IDBFactory;
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LFactory := TMockDBFactory.Create;
    LScope := LFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Log, 'committed');
    TAssert.AssertEquals('Nothing runs before the commit', 0, LLog.Lines.Count);
    LScope.Commit;
    TAssert.AssertEquals('committed' + sLineBreak, LLog.Lines.Text);

    LScope := LFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Log, 'rolled back');
    LScope.Rollback;
    LScope.StartTransaction;
    LScope.Commit;
    TAssert.AssertEquals('The rollback dropped it', 'committed' + sLineBreak, LLog.Lines.Text);

    LScope := LFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    PdbAfterCommit(LScope, LLog.Log, 'abandoned');
    LScope := nil;
    TAssert.AssertEquals('A scope released without commit drops it', 'committed' + sLineBreak,
      LLog.Lines.Text);
  finally
    LLog.Free;
  end;
end;

procedure TAfterCommitTests.Mock_BeforeStart_Raises;
var
  LLog: TActionLog;
  LFactory: IDBFactory;
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LLog := TActionLog.Create;
  try
    LFactory := TMockDBFactory.Create;
    LScope := LFactory.GetPool.AcquireQuery(LQuery);
    try
      PdbAfterCommit(LScope, LLog.Log, 'x');
      TAssert.Fail('Adding an action before StartTransaction must raise');
    except
      on E: EAfterCommitException do
        TAssert.AssertEquals(PDB_AFTER_COMMIT_NO_TRANSACTION, E.Message);
    end;
  finally
    LLog.Free;
  end;
end;

function NewCache: IPcCache;
begin
  Result := TPcCache.Create(TPcMemoryCacheStore.Create(100), 'pdb-after-commit-tests');
end;

procedure TAfterCommitTests.Cache_InvalidatedOnlyAfterTheCommit;
var
  LCache: IPcCache;
  LFactory: IDBFactory;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LValue: string;
begin
  LCache := NewCache;
  LCache.Put(LCache.Key('city:1', ['cities', 'city:1']), 'old', 60);
  LCache.Put(LCache.Key('city:2', ['cities', 'city:2']), 'other', 60);
  LFactory := TMockDBFactory.Create;
  LScope := LFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  PdbInvalidateAfterCommit(LScope, LCache, ['city:1']);
  TAssert.AssertTrue('Still read before the commit',
    LCache.TryGet(LCache.Key('city:1', ['cities', 'city:1']), LValue));
  TAssert.AssertEquals('old', LValue);
  LScope.Commit;
  TAssert.AssertFalse('Not read after the commit',
    LCache.TryGet(LCache.Key('city:1', ['cities', 'city:1']), LValue));
  TAssert.AssertTrue('Another tag is untouched',
    LCache.TryGet(LCache.Key('city:2', ['cities', 'city:2']), LValue));
end;

procedure TAfterCommitTests.Cache_RollbackKeepsTheEntry;
var
  LCache: IPcCache;
  LIntf: ITransaction;
  LOuter, LInner: IScopeTransaction;
  LValue: string;
begin
  LCache := NewCache;
  LCache.Put(LCache.Key('city:1', ['city:1']), 'kept', 60);
  LIntf := NewTransaction;
  LOuter := TScopeTransaction.Create(LIntf, nil);
  LOuter.StartTransaction;
  LInner := TScopeTransaction.Create(LIntf, nil);
  LInner.StartTransaction;
  PdbInvalidateAfterCommit(LInner, LCache, ['city:1']);
  LInner.Rollback;
  LOuter.Commit;
  TAssert.AssertTrue('A rolled-back change doesn''t invalidate',
    LCache.TryGet(LCache.Key('city:1', ['city:1']), LValue));
  TAssert.AssertEquals('kept', LValue);
end;

procedure TAfterCommitTests.Cache_NilCacheOrNoTags_DoesNothing;
var
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  // Not even started: a cache that is off adds nothing to check.
  LIntf := NewTransaction;
  LScope := TScopeTransaction.Create(LIntf, nil);
  PdbInvalidateAfterCommit(LScope, nil, ['city:1']);
  PdbInvalidateAfterCommit(LScope, NewCache, []);
  LScope.StartTransaction;
  PdbInvalidateAfterCommit(LScope, nil, ['city:1']);
  TAssert.AssertEquals('No action added', 0, (LIntf as IAfterCommitActions).Count);
  LScope.Commit;
end;

initialization
  RegisterTest(TAfterCommitTests);

end.
