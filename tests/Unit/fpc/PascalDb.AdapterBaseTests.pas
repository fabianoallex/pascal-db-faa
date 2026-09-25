unit PascalDb.AdapterBaseTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.AdapterBaseTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the driver-agnostic adapter building blocks, without a database:
  TSqlScript.SplitStatements, the IOptXxx/INullXxx/IOptNullXxx semantics of
  TDBParams over a standalone TParams (typed NULLs included), and the
  savepoint SQL TScopeTransaction issues for nested scopes. The same blocks
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
  PascalDb.Optionals,
  PascalDb.SqlDialect,
  PascalDb.Adapter.Base,
  PascalDb.Adapter.DataSet;

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
    procedure Scope_Main_CommitsTheTransaction;
    procedure Scope_Nested_UsesSavepoints;
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

initialization
  RegisterTest(TAdapterBaseTests);

end.
