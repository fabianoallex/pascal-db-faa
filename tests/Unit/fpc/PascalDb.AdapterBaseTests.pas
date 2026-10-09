unit PascalDb.AdapterBaseTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.AdapterBaseTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the driver-agnostic adapter building blocks, without a database:
  TSqlScript.SplitStatements, the IOptXxx/INullXxx/IOptNullXxx semantics of
  TDBParams over a standalone TParams (typed NULLs and nil optionals
  included), TDatabaseConfig's pool defaults and TDBFactory's refusal of a
  pool with no connections or an unknown SQL dialect, dialect lookup by name
  (case, unknown and empty names, duplicates), the savepoint SQL TScopeTransaction issues
  for nested scopes and its transaction span (with TFakeSpanExporter from
  PascalDb.PoolTests). The same blocks
  are exercised against a real database by the integration contract tests.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  Classes,
  SysUtils,
  DB,
  PascalDb.Interfaces,
  PascalCommon.Optionals,
  PascalDb.SqlDialect,
  PascalDb.Adapter.Base,
  PascalDb.Adapter.DataSet,
  PascalCommon.Tracing,
  PascalDb.Pool,
  PascalDb.PoolTests;

type
  { TRecordingConnection
    IDBConnection that only hands out a SQL dialect. }
  TRecordingConnection = class(TInterfacedObject, IDBConnection)
  private
    FDialect: ISQLDialect;
  public
    constructor Create(const ADialect: ISQLDialect);
    function GetNativeConnection: TObject;
    function IsConnected: Boolean;
    procedure Connect;
    procedure Commit;
    procedure Rollback;
    procedure Disconnect(Force: Boolean = False);
    function GetSQLDialect: ISQLDialect;
  end;

  { TRecordingTransaction
    TTransactionBase whose native calls are recorded as text. }
  TRecordingTransaction = class(TTransactionBase)
  private
    FLog: TStringList;
  protected
    procedure DoStartTransaction; override;
    procedure DoCommit; override;
    procedure DoRollback; override;
    procedure DoExecSql(const ASql: string); override;
  public
    constructor Create(const AConn: IDBConnection);
    destructor Destroy; override;
    function GetNativeTransaction: TObject; override;
    property Log: TStringList read FLog;
  end;

  { TUnusedProvider
    IDBComponentProvider for tests that must fail before any connection is
    built: every call raises. }
  TUnusedProvider = class(TInterfacedObject, IDBComponentProvider)
  public
    function BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
    function BuildTransaction(AConn: IDBConnection): ITransaction;
    function BuildScopeTransaction(ATransaction: ITransaction; AContextTransaction: IContextTransaction): IScopeTransaction;
    function BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
  end;

  { TCommitThread
    Commits a scope and releases it, on its own thread (a TThread subclass:
    no anonymous threads on FPC 3.2.2). }
  TCommitThread = class(TThread)
  private
    FScope: IScopeTransaction;
  protected
    procedure Execute; override;
  public
    constructor Create(const AScope: IScopeTransaction);
  end;

  TAdapterBaseTests = class(TTestCase)
  private
    FParams: TParams;
    FIntf: IParams;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published

    procedure Split_UsesTerminatorAndTrims;
    procedure Split_IgnoresEmptyStatements;
    procedure Split_WithoutTerminatorIsOneStatement;
    procedure Split_CustomTerminator;
    procedure Params_PlainValues_RoundTrip;
    procedure Params_OptNullNull_WritesTypedNull;
    procedure Params_OptUndefined_LeavesParamUntouched;
    procedure Params_NullValue_WritesValue;
    procedure Params_GetOptNull_MissingParamIsUndefined;
    procedure Params_GetNull_NullParamIsNull;
    procedure Params_NilOpt_LeavesParamUntouched;
    procedure Params_NilOptNull_LeavesParamUntouched;
    procedure Params_NilNull_WritesTypedNull;
    procedure Config_Defaults_GiveAUsablePool;
    procedure Factory_PoolMaxZero_RaisesClearError;
    procedure Factory_UnknownDialect_RaisesOnCreate;
    procedure Dialect_NameIgnoresCase;
    procedure Dialect_Unknown_ListsRegisteredOnes;
    procedure Dialect_Empty_SaysItIsNotSet;
    procedure Dialect_RegisterSameNameAnyCase_Raises;
    procedure Scope_Main_CommitsTheTransaction;
    procedure Scope_Nested_UsesSavepoints;
    procedure Scope_Nested_NoRelease_CommitRunsNothing;
    procedure Scope_Tracing_TransactionSpan_ParentOfTheStatements;
    procedure Scope_Tracing_RollbackAndAbandoned_NestedHasNoSpan;
    procedure Scope_Tracing_CommitOnAnotherThread;
    procedure PluginDir_NextToLibrary_AnySlash;
    procedure PluginDir_NoFolder_IsEmpty;
  end;

implementation

{ TRecordingConnection }

constructor TRecordingConnection.Create(const ADialect: ISQLDialect);
begin
  inherited Create;
  FDialect := ADialect;
end;

function TRecordingConnection.GetNativeConnection: TObject;
begin
  Result := nil;
end;

function TRecordingConnection.IsConnected: Boolean;
begin
  Result := True;
end;

procedure TRecordingConnection.Connect;
begin
end;

procedure TRecordingConnection.Commit;
begin
end;

procedure TRecordingConnection.Rollback;
begin
end;

procedure TRecordingConnection.Disconnect(Force: Boolean);
begin
end;

function TRecordingConnection.GetSQLDialect: ISQLDialect;
begin
  Result := FDialect;
end;

{ TRecordingTransaction }

constructor TRecordingTransaction.Create(const AConn: IDBConnection);
begin
  inherited Create(AConn);
  FLog := TStringList.Create;
end;

destructor TRecordingTransaction.Destroy;
begin
  FLog.Free;
  inherited Destroy;
end;

procedure TRecordingTransaction.DoStartTransaction;
begin
  FLog.Add('START');
end;

procedure TRecordingTransaction.DoCommit;
begin
  FLog.Add('COMMIT');
end;

procedure TRecordingTransaction.DoRollback;
begin
  FLog.Add('ROLLBACK');
end;

procedure TRecordingTransaction.DoExecSql(const ASql: string);
begin
  FLog.Add(ASql);
end;

function TRecordingTransaction.GetNativeTransaction: TObject;
begin
  Result := nil;
end;

{ TUnusedProvider }

function TUnusedProvider.BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
begin
  Result := nil;
  raise Exception.Create('TUnusedProvider: not expected to be called');
end;

function TUnusedProvider.BuildTransaction(AConn: IDBConnection): ITransaction;
begin
  Result := nil;
  raise Exception.Create('TUnusedProvider: not expected to be called');
end;

function TUnusedProvider.BuildScopeTransaction(ATransaction: ITransaction;
  AContextTransaction: IContextTransaction): IScopeTransaction;
begin
  Result := nil;
  raise Exception.Create('TUnusedProvider: not expected to be called');
end;

function TUnusedProvider.BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
begin
  Result := nil;
  raise Exception.Create('TUnusedProvider: not expected to be called');
end;

function TUnusedProvider.BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
begin
  Result := nil;
  raise Exception.Create('TUnusedProvider: not expected to be called');
end;

{ TAdapterBaseTests }

procedure TAdapterBaseTests.Setup;
begin
  FParams := TParams.Create(nil);
  FParams.CreateParam(ftUnknown, 'A', ptInput);
  FIntf := TDBParams.Create(FParams);
end;

procedure TAdapterBaseTests.TearDown;
begin
  FIntf := nil;
  FParams.Free;
end;

procedure TAdapterBaseTests.Split_UsesTerminatorAndTrims;
var
  LParts: TArray<string>;
begin
  LParts := TSqlScript.SplitStatements('SELECT 1;  SELECT 2 ;', ';');
  TAssert.AssertEquals(2, Length(LParts));
  TAssert.AssertEquals('SELECT 1', LParts[0]);
  TAssert.AssertEquals('SELECT 2', LParts[1]);
end;

procedure TAdapterBaseTests.Split_IgnoresEmptyStatements;
var
  LParts: TArray<string>;
begin
  LParts := TSqlScript.SplitStatements(';;SELECT 1;' + sLineBreak + ';', ';');
  TAssert.AssertEquals('Empty statements between terminators must be skipped', 1, Length(LParts));
end;

procedure TAdapterBaseTests.Split_WithoutTerminatorIsOneStatement;
var
  LParts: TArray<string>;
begin
  LParts := TSqlScript.SplitStatements('SELECT 1', ';');
  TAssert.AssertEquals(1, Length(LParts));
  TAssert.AssertEquals('SELECT 1', LParts[0]);
end;

procedure TAdapterBaseTests.Split_CustomTerminator;
var
  LParts: TArray<string>;
begin
  LParts := TSqlScript.SplitStatements('SET TERM x;^SELECT 2^', '^');
  TAssert.AssertEquals('Only the given terminator splits', 2, Length(LParts));
  TAssert.AssertEquals('SET TERM x;', LParts[0]);
end;

procedure TAdapterBaseTests.Params_PlainValues_RoundTrip;
begin
  FIntf.Integers['A'] := 42;
  TAssert.AssertEquals(42, FIntf.Integers['A']);
  FIntf.Strings['A'] := 'text';
  TAssert.AssertEquals('text', FIntf.Strings['A']);
end;

procedure TAdapterBaseTests.Params_OptNullNull_WritesTypedNull;
begin
  FIntf.OptNullIntegers['A'] := TOptNullInteger.Null;
  TAssert.AssertTrue('An OptNull Null must write NULL', FParams.ParamByName('A').IsNull);
  TAssert.AssertTrue('The NULL must carry the value type (Integer)',
    FParams.ParamByName('A').DataType = ftInteger);
end;

procedure TAdapterBaseTests.Params_OptUndefined_LeavesParamUntouched;
begin
  FIntf.Integers['A'] := 7;
  FIntf.OptIntegers['A'] := TOptNullInteger.Undefined;
  TAssert.AssertEquals('An Undefined optional must not overwrite the parameter', 7, FIntf.Integers['A']);
end;

procedure TAdapterBaseTests.Params_NullValue_WritesValue;
begin
  FIntf.NullStrings['A'] := TOptNullString.From('given');
  TAssert.AssertFalse(FParams.ParamByName('A').IsNull);
  TAssert.AssertEquals('given', FIntf.Strings['A']);
end;

procedure TAdapterBaseTests.Params_GetOptNull_MissingParamIsUndefined;
begin
  TAssert.AssertFalse('A parameter that doesn''t exist must read as Undefined',
    FIntf.OptNullStrings['MISSING'].HasValue);
end;

procedure TAdapterBaseTests.Params_GetNull_NullParamIsNull;
begin
  FIntf.NullIntegers['A'] := TOptNullInteger.Null;
  TAssert.AssertTrue(FIntf.NullIntegers['A'].IsNull);
end;

procedure TAdapterBaseTests.Params_NilOpt_LeavesParamUntouched;
var
  LNil: IOptString;
begin
  LNil := nil;
  FIntf.Strings['A'] := 'kept';
  FIntf.OptStrings['A'] := LNil;
  TAssert.AssertEquals('A nil IOpt must read as Undefined', 'kept', FIntf.Strings['A']);
end;

procedure TAdapterBaseTests.Params_NilOptNull_LeavesParamUntouched;
var
  LNil: IOptNullInteger;
begin
  LNil := nil;
  FIntf.Integers['A'] := 7;
  FIntf.OptNullIntegers['A'] := LNil;
  TAssert.AssertEquals('A nil IOptNull must read as Undefined', 7, FIntf.Integers['A']);
end;

procedure TAdapterBaseTests.Params_NilNull_WritesTypedNull;
var
  LNil: INullCurrency;
begin
  LNil := nil;
  FIntf.Integers['A'] := 7;
  FIntf.NullCurrencies['A'] := LNil;
  TAssert.AssertTrue('A nil INull must write NULL', FParams.ParamByName('A').IsNull);
  TAssert.AssertTrue('The NULL must carry the value type (Currency)',
    FParams.ParamByName('A').DataType = ftCurrency);
end;

procedure TAdapterBaseTests.Config_Defaults_GiveAUsablePool;
var
  LConfig: IDatabaseConfig;
begin
  LConfig := TDatabaseConfig.Create;
  TAssert.AssertEquals('PoolIniConnections', 1, LConfig.PoolIniConnections);
  TAssert.AssertEquals('PoolMaxConnections', 10, LConfig.PoolMaxConnections);
  TAssert.AssertEquals('PoolWaitMaxAttemps', 50, LConfig.PoolWaitMaxAttemps);
  TAssert.AssertEquals('PoolWaitMilliseconds', 100, LConfig.PoolWaitMilliseconds);
  TAssert.AssertEquals('PoolIdleTimeoutSeconds', 0, LConfig.PoolIdleTimeoutSeconds);
  TAssert.AssertEquals('PoolValidateIdleSeconds', 120, LConfig.PoolValidateIdleSeconds);
  TAssert.AssertEquals('PoolKeepaliveSeconds', 0, LConfig.PoolKeepaliveSeconds);
  TAssert.AssertEquals('LockTimeoutMs', 0, LConfig.LockTimeoutMs);
  LConfig.LockTimeoutMs := -1;
  TAssert.AssertEquals('A negative LockTimeoutMs must be ignored', 0, LConfig.LockTimeoutMs);
end;

procedure TAdapterBaseTests.Factory_PoolMaxZero_RaisesClearError;
var
  LConfig: IDatabaseConfig;
  LProvider: IDBComponentProvider;
  LFactory: IDBFactory;
begin
  LConfig := TDatabaseConfig.Create;
  LConfig.PoolMaxConnections := 0;
  // In a variable: a new object passed straight to a const interface
  // parameter is never released.
  LProvider := TUnusedProvider.Create;
  try
    LFactory := TDBFactory.Create(LConfig, LProvider, nil, nil);
    TAssert.Fail('A factory with PoolMaxConnections = 0 must not be created');
  except
    on E: EArgumentException do
      TAssert.AssertTrue('The message must name the setting: ' + E.Message,
        Pos('PoolMaxConnections', E.Message) > 0);
  end;
end;

procedure TAdapterBaseTests.Factory_UnknownDialect_RaisesOnCreate;
var
  LConfig: IDatabaseConfig;
  LProvider: IDBComponentProvider;
  LFactory: IDBFactory;
begin
  LConfig := TDatabaseConfig.Create;
  LConfig.PoolIniConnections := 0;
  LConfig.SQLDialect := 'NoSuchDatabase';
  LProvider := TUnusedProvider.Create;
  try
    LFactory := TDBFactory.Create(LConfig, LProvider, nil, nil);
    TAssert.Fail('A factory with an unknown SQL dialect must not be created');
  except
    on E: EArgumentException do
      TAssert.AssertTrue('The message must name the dialect: ' + E.Message,
        Pos('NoSuchDatabase', E.Message) > 0);
  end;
end;

procedure TAdapterBaseTests.Dialect_NameIgnoresCase;
begin
  TAssert.AssertTrue('''firebird'' must find the Firebird dialect',
    Pos('RDB$DATABASE', UpperCase(TSQLDialectFactory.GetDialect('firebird').GetPingSQL)) > 0);
  TAssert.AssertTrue('''POSTGRESQL'' must find the PostgreSQL dialect',
    Assigned(TSQLDialectFactory.GetDialect('POSTGRESQL')));
end;

procedure TAdapterBaseTests.Dialect_Unknown_ListsRegisteredOnes;
begin
  try
    TSQLDialectFactory.GetDialect('Oracle');
    TAssert.Fail('An unregistered dialect must raise');
  except
    on E: EArgumentException do
    begin
      TAssert.AssertTrue('The message must name the dialect: ' + E.Message, Pos('"Oracle"', E.Message) > 0);
      TAssert.AssertTrue('The message must list the registered ones: ' + E.Message,
        (Pos('Firebird', E.Message) > 0) and (Pos('PostgreSQL', E.Message) > 0) and (Pos('SQLite', E.Message) > 0));
    end;
  end;
end;

procedure TAdapterBaseTests.Dialect_Empty_SaysItIsNotSet;
begin
  try
    TSQLDialectFactory.GetDialect('');
    TAssert.Fail('An empty dialect name must raise');
  except
    on E: EArgumentException do
      TAssert.AssertTrue('The message must point at the setting: ' + E.Message,
        Pos('IDatabaseConfig.SQLDialect is empty', E.Message) > 0);
  end;
end;

procedure TAdapterBaseTests.Dialect_RegisterSameNameAnyCase_Raises;
begin
  try
    TSQLDialectFactory.RegisterDialect('FIREBIRD', TFirebirdDialect);
    TAssert.Fail('Registering a name that differs only in case must raise');
  except
    on E: EArgumentException do
      TAssert.AssertTrue('The message must name the dialect: ' + E.Message, Pos('FIREBIRD', E.Message) > 0);
  end;
end;

procedure TAdapterBaseTests.Scope_Main_CommitsTheTransaction;
var
  LTransaction: TRecordingTransaction;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
begin
  LTransaction := TRecordingTransaction.Create(
    TRecordingConnection.Create(TSQLDialectFactory.GetDialect('Firebird')));
  LIntf := LTransaction;
  LScope := TScopeTransaction.Create(LIntf, nil);
  TAssert.AssertTrue('A scope over an idle transaction is the main one', LScope.IsMain);
  LScope.StartTransaction;
  LScope.Commit;
  TAssert.AssertEquals('START' + sLineBreak + 'COMMIT' + sLineBreak, LTransaction.Log.Text);
end;

procedure TAdapterBaseTests.Scope_Nested_UsesSavepoints;
var
  LTransaction: TRecordingTransaction;
  LIntf: ITransaction;
  LOuter, LInner: IScopeTransaction;
begin
  LTransaction := TRecordingTransaction.Create(
    TRecordingConnection.Create(TSQLDialectFactory.GetDialect('Firebird')));
  LIntf := LTransaction;
  LOuter := TScopeTransaction.Create(LIntf, nil);
  LOuter.StartTransaction;
  LInner := TScopeTransaction.Create(LIntf, nil);
  TAssert.AssertFalse('A scope over a running transaction is nested', LInner.IsMain);
  LInner.StartTransaction;
  LInner.Rollback;
  LOuter.Commit;
  TAssert.AssertEquals('Log lines', 4, LTransaction.Log.Count);
  TAssert.AssertEquals('START', LTransaction.Log[0]);
  TAssert.AssertTrue('The nested scope must create a savepoint', Pos('SAVEPOINT', LTransaction.Log[1]) = 1);
  TAssert.AssertTrue('The nested rollback must roll back to it', Pos('ROLLBACK TO SAVEPOINT', LTransaction.Log[2]) = 1);
  TAssert.AssertEquals('COMMIT', LTransaction.Log[3]);
end;

procedure TAdapterBaseTests.Scope_Nested_NoRelease_CommitRunsNothing;
var
  LTransaction: TRecordingTransaction;
  LIntf: ITransaction;
  LOuter, LInner: IScopeTransaction;
begin
  // SQL Server has no statement to release a savepoint: a nested scope that
  // commits leaves it in place until the transaction ends.
  LTransaction := TRecordingTransaction.Create(
    TRecordingConnection.Create(TSQLDialectFactory.GetDialect('mssql')));
  LIntf := LTransaction;
  LOuter := TScopeTransaction.Create(LIntf, nil);
  LOuter.StartTransaction;
  LInner := TScopeTransaction.Create(LIntf, nil);
  LInner.StartTransaction;
  LInner.Commit;
  LOuter.Commit;
  TAssert.AssertEquals('Log lines', 3, LTransaction.Log.Count);
  TAssert.AssertEquals('START', LTransaction.Log[0]);
  TAssert.AssertTrue('The nested scope must create a savepoint: ' + LTransaction.Log[1],
    Pos('SAVE TRANSACTION sp_', LTransaction.Log[1]) = 1);
  TAssert.AssertEquals('COMMIT', LTransaction.Log[2]);
end;

procedure TAdapterBaseTests.Scope_Tracing_TransactionSpan_ParentOfTheStatements;
var
  LTransaction: TRecordingTransaction;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
  LFake: TFakeSpanExporter;
  LExporter: IPcSpanExporter;
  LStatement: IPcSpan;
  LSpan: TPcSpanData;
begin
  LFake := TFakeSpanExporter.Create;
  LExporter := LFake;
  TPcTracing.Start(TPcTracingOptions.Default('adapter-tests', ''), LExporter, False);
  try
    LTransaction := TRecordingTransaction.Create(
      TRecordingConnection.Create(TSQLDialectFactory.GetDialect('Firebird')));
    LIntf := LTransaction;
    LScope := TScopeTransaction.Create(LIntf, nil);
    // What TDBFactory.CreateScopeTransaction does with its config's dialect.
    (LScope as ITracedScopeTransaction).SetDbSystem('firebirdsql');
    LScope.StartTransaction;
    TAssert.AssertTrue('The transaction span is detached, never current', TPcTracing.Current = nil);
    TAssert.AssertTrue('The transaction carries its span',
      (LIntf as ITransactionSpan).GetSpan <> nil);
    // What a pooled statement inside the transaction does (PascalDb.Pool).
    LStatement := TPcTracing.StartChildSpan((LIntf as ITransactionSpan).GetSpan, 'UPDATE', skClient);
    LStatement.Finish;
    LStatement := nil;
    LScope.Commit;
    TAssert.AssertTrue('The commit takes the span off the transaction',
      (LIntf as ITransactionSpan).GetSpan = nil);
    TAssert.AssertTrue('Nothing left current after the commit', TPcTracing.Current = nil);
    LScope := nil;
    TPcTracing.FlushNow;

    TAssert.AssertEquals(2, Length(LFake.Spans));
    LSpan := LFake.Find('transaction');
    TAssert.AssertEquals(Ord(skInternal), Ord(LSpan.Kind));
    TAssert.AssertEquals('commit', TFakeSpanExporter.Attribute(LSpan, 'pascaldb.transaction.outcome'));
    TAssert.AssertEquals('firebirdsql', TFakeSpanExporter.Attribute(LSpan, 'db.system.name'));
    TAssert.AssertEquals(Ord(ssUnset), Ord(LSpan.Status));
    TAssert.AssertEquals('The statement is a child of the transaction',
      LSpan.SpanId, LFake.Find('UPDATE').ParentSpanId);
  finally
    LStatement := nil;
    LScope := nil;
    TPcTracing.Shutdown;
  end;
end;

procedure TAdapterBaseTests.Scope_Tracing_RollbackAndAbandoned_NestedHasNoSpan;
var
  LTransaction: TRecordingTransaction;
  LIntf: ITransaction;
  LOuter, LInner: IScopeTransaction;
  LFake: TFakeSpanExporter;
  LExporter: IPcSpanExporter;
begin
  LFake := TFakeSpanExporter.Create;
  LExporter := LFake;
  TPcTracing.Start(TPcTracingOptions.Default('adapter-tests', ''), LExporter, False);
  try
    LTransaction := TRecordingTransaction.Create(
      TRecordingConnection.Create(TSQLDialectFactory.GetDialect('Firebird')));
    LIntf := LTransaction;
    // Rolled back, with a nested scope (a savepoint) inside: one span.
    LOuter := TScopeTransaction.Create(LIntf, nil);
    LOuter.StartTransaction;
    LInner := TScopeTransaction.Create(LIntf, nil);
    LInner.StartTransaction;
    LInner.Commit;
    LInner := nil;
    LOuter.Rollback;
    LOuter := nil;
    TPcTracing.FlushNow;
    TAssert.AssertEquals('Only the outermost scope has a span', 1, Length(LFake.Spans));
    TAssert.AssertEquals('rollback',
      TFakeSpanExporter.Attribute(LFake.Spans[0], 'pascaldb.transaction.outcome'));

    // Released without Commit or Rollback.
    LOuter := TScopeTransaction.Create(LIntf, nil);
    LOuter.StartTransaction;
    LOuter := nil;
    TAssert.AssertTrue('Nothing left current', TPcTracing.Current = nil);
    TPcTracing.FlushNow;
    TAssert.AssertEquals(2, Length(LFake.Spans));
    TAssert.AssertEquals('abandoned',
      TFakeSpanExporter.Attribute(LFake.Spans[1], 'pascaldb.transaction.outcome'));
    TAssert.AssertEquals('No db.system.name unless the factory sets it', '',
      TFakeSpanExporter.Attribute(LFake.Spans[1], 'db.system.name'));
  finally
    LInner := nil;
    LOuter := nil;
    TPcTracing.Shutdown;
  end;
end;

{ TCommitThread }

constructor TCommitThread.Create(const AScope: IScopeTransaction);
begin
  FScope := AScope;
  inherited Create(False);
end;

procedure TCommitThread.Execute;
begin
  FScope.Commit;
  FScope := nil;
end;

procedure TAdapterBaseTests.Scope_Tracing_CommitOnAnotherThread;
var
  LTransaction: TRecordingTransaction;
  LIntf: ITransaction;
  LScope: IScopeTransaction;
  LFake: TFakeSpanExporter;
  LExporter: IPcSpanExporter;
  LRequest, LAfter: IPcSpan;
  LThread: TCommitThread;
begin
  // Started here, committed and released on another thread: the span (and
  // the scope holding it) is freed there. This thread must come out with its
  // own current span intact, and start new spans from it.
  LFake := TFakeSpanExporter.Create;
  LExporter := LFake;
  TPcTracing.Start(TPcTracingOptions.Default('adapter-tests', ''), LExporter, False);
  try
    LRequest := TPcTracing.StartSpan('request', skServer);
    LTransaction := TRecordingTransaction.Create(
      TRecordingConnection.Create(TSQLDialectFactory.GetDialect('Firebird')));
    LIntf := LTransaction;
    LScope := TScopeTransaction.Create(LIntf, nil);
    LScope.StartTransaction;
    LThread := TCommitThread.Create(LScope);
    LScope := nil;
    try
      LThread.WaitFor;
    finally
      LThread.Free;
    end;
    TAssert.AssertTrue('The request is still the current span', TPcTracing.Current = LRequest);
    LAfter := TPcTracing.StartSpan('after');
    LAfter.Finish;
    LAfter := nil;
    LRequest.Finish;
    LRequest := nil;
    TAssert.AssertTrue('Nothing left current', TPcTracing.Current = nil);
    TPcTracing.FlushNow;

    TAssert.AssertEquals(3, Length(LFake.Spans));
    TAssert.AssertEquals('commit',
      TFakeSpanExporter.Attribute(LFake.Find('transaction'), 'pascaldb.transaction.outcome'));
    TAssert.AssertEquals(LFake.Find('request').SpanId, LFake.Find('transaction').ParentSpanId);
    TAssert.AssertEquals(LFake.Find('request').SpanId, LFake.Find('after').ParentSpanId);
  finally
    LAfter := nil;
    LScope := nil;
    LRequest := nil;
    TPcTracing.Shutdown;
  end;
end;

// A folder next to the test executable, removed by the caller.
function PluginTestFolder: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'pdb_plugin_dir_test' + PathDelim;
end;

procedure TAdapterBaseTests.PluginDir_NextToLibrary_AnySlash;
var
  LBase, LSlashed: string;
begin
  LBase := PluginTestFolder;
  ForceDirectories(LBase + 'plugin');
  try
    TAssert.AssertEquals(LBase + 'plugin', PdbMySQLPluginDir(LBase + 'libmariadb.dll'));
    // Forward slashes, as a path often arrives from a shell or a config
    // file: on Windows, Delphi's ExtractFilePath knew only the backslash.
    LSlashed := StringReplace(LBase, '\', '/', [rfReplaceAll]);
    TAssert.AssertTrue('The plugin folder must be found with forward slashes too: ' +
      PdbMySQLPluginDir(LSlashed + 'libmariadb.dll'),
      DirectoryExists(PdbMySQLPluginDir(LSlashed + 'libmariadb.dll')));
  finally
    RemoveDir(LBase + 'plugin');
    RemoveDir(LBase);
  end;
end;

procedure TAdapterBaseTests.PluginDir_NoFolder_IsEmpty;
var
  LBase: string;
begin
  TAssert.AssertEquals('A bare file name has no folder', '', PdbMySQLPluginDir('libmariadb.dll'));
  LBase := PluginTestFolder;
  ForceDirectories(LBase);
  try
    TAssert.AssertEquals('No plugin folder next to the library', '',
      PdbMySQLPluginDir(LBase + 'libmariadb.dll'));
  finally
    RemoveDir(LBase);
  end;
end;

initialization
  RegisterTest(TAdapterBaseTests);

end.
