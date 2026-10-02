unit PascalDb.BatchTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.BatchTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for TBatch (PascalDb.Batch) over a recording query: one ExecSql per
  row with that row's values, every parameter type and typed NULLs, a
  parameter missing from a row or set to an Undefined optional going as
  NULL, sends at MaxRows, the guard against values left without AddRow,
  one type per parameter, the native path (rows, types, NULLs and longest
  string handed over in one call), a driver that declines it, a failed send
  dropping its rows, and the mock recording one execution per row.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Variants,
  Generics.Collections,
  PascalDb.Interfaces,
  PascalDb.Optionals,
  PascalDb.Mock,
  PascalDb.Batch;

type
  // Named, because FPC 3.2.2 doesn't parse TObjectList<TDictionary<...>>.Create.
  TRecordedRow = TDictionary<string, Variant>;
  TRecordedRows = TObjectList<TRecordedRow>;

  { TRecordingQuery
    IQuery whose ExecSql keeps a copy of the parameters (TMockParams, keys
    upper-cased) and fails on execution number FailOnExec (1-based; 0 =
    never). With Native set it implements the native batch and keeps the
    IBatchRows it gets. }

  TRecordingQuery = class(TInterfacedObject, IQuery, INativeBatchQuery)
  private
    FParams: IParams;
    FSql: string;
    FExecCount: Integer;
  public
    Native: Boolean;
    FailOnExec: Integer;
    Executions: TRecordedRows;
    Batches: TList<IBatchRows>;
    constructor Create;
    destructor Destroy; override;
    function GetParams: IParams;
    procedure SetSql(const ASql: string);
    function GetSql: string;
    function Open: IQueryResult;
    procedure Close;
    procedure ExecSql;
    function GetConnection: IDBConnection;
    function GetTransaction: ITransaction;
    function SupportsNativeBatch: Boolean;
    procedure ExecBatch(const ARows: IBatchRows);
  end;

  TBatchTests = class(TTestCase)
  published
    procedure Loop_OneExecSqlPerRow_WithThatRowsValues;
    procedure Loop_EveryType_AndTypedNulls;
    procedure Loop_ParamMissingInARow_IsNull;
    procedure Loop_UndefinedOptional_IsNull;
    procedure AddRow_SendsWhenMaxRowsIsReached;
    procedure Execute_WithoutRows_DoesNothing;
    procedure Execute_ValuesWithoutAddRow_Raises;
    procedure Params_DifferentTypeInALaterRow_Raises;
    procedure MaxRows_BelowOne_Raises;
    procedure Params_ReadTheCurrentRow;
    procedure Native_GetsTheRowsInOneCall;
    procedure Native_DeclinedByTheDriver_RunsRowByRow;
    procedure Failure_DropsTheRowsOfThatSend;
    procedure Mock_RecordsOneExecutionPerRow;
  end;

implementation

const
  INSERT_SQL = 'INSERT INTO T (ID, NAME, QTY) VALUES (:ID, :NAME, :QTY)';

{ TRecordingQuery }

constructor TRecordingQuery.Create;
begin
  inherited Create;
  FParams := TMockParams.Create;
  Executions := TRecordedRows.Create;
  Batches := TList<IBatchRows>.Create;
end;

destructor TRecordingQuery.Destroy;
begin
  Batches.Free;
  Executions.Free;
  inherited Destroy;
end;

function TRecordingQuery.GetParams: IParams;
begin
  Result := FParams;
end;

procedure TRecordingQuery.SetSql(const ASql: string);
begin
  FSql := ASql;
end;

function TRecordingQuery.GetSql: string;
begin
  Result := FSql;
end;

function TRecordingQuery.Open: IQueryResult;
begin
  Result := nil;
end;

procedure TRecordingQuery.Close;
begin
end;

procedure TRecordingQuery.ExecSql;
var
  LSnapshot: TRecordedRow;
begin
  Inc(FExecCount);
  if FExecCount = FailOnExec then
    raise EConvertError.Create('row rejected');
  LSnapshot := TRecordedRow.Create;
  Executions.Add(LSnapshot);
  (FParams as TMockParams).CopyTo(LSnapshot);
end;

function TRecordingQuery.GetConnection: IDBConnection;
begin
  Result := nil;
end;

function TRecordingQuery.GetTransaction: ITransaction;
begin
  Result := nil;
end;

function TRecordingQuery.SupportsNativeBatch: Boolean;
begin
  Result := Native;
end;

procedure TRecordingQuery.ExecBatch(const ARows: IBatchRows);
begin
  Batches.Add(ARows);
end;

{ TBatchTests }

procedure TBatchTests.Loop_OneExecSqlPerRow_WithThatRowsValues;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
  I: Integer;
begin
  LRec := TRecordingQuery.Create;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  TAssert.AssertEquals('The batch sets the query''s SQL', INSERT_SQL, LQuery.Sql);
  TAssert.AssertFalse('A query without INativeBatchQuery support runs row by row', LBatch.IsNative);
  for I := 1 to 3 do
  begin
    LBatch.Params.Integers['ID'] := I;
    LBatch.Params.Strings['NAME'] := 'name ' + IntToStr(I);
    LBatch.AddRow;
  end;
  TAssert.AssertEquals('Nothing is sent before Execute (MaxRows not reached)', 0, LRec.Executions.Count);
  TAssert.AssertEquals(3, LBatch.PendingRows);
  LBatch.Execute;
  TAssert.AssertEquals(0, LBatch.PendingRows);
  TAssert.AssertEquals('One ExecSql per row', 3, LRec.Executions.Count);
  for I := 1 to 3 do
  begin
    TAssert.AssertEquals(I, Integer(LRec.Executions[I - 1]['ID']));
    TAssert.AssertEquals('name ' + IntToStr(I), VarToStr(LRec.Executions[I - 1]['NAME']));
  end;
end;

procedure TBatchTests.Loop_EveryType_AndTypedNulls;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
  LWhen: TDateTime;
  LRow: TRecordedRow;
begin
  LWhen := EncodeDate(2026, 10, 2) + EncodeTime(8, 9, 10, 0);
  LRec := TRecordingQuery.Create;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, 'INSERT ...');
  LBatch.Params.Strings['S'] := 'São Paulo';
  LBatch.Params.Booleans['B'] := True;
  LBatch.Params.DateTimes['D'] := LWhen;
  LBatch.Params.Doubles['F'] := 0.125;
  LBatch.Params.Integers['I'] := -7;
  LBatch.Params.Int64s['L'] := 9000000000;
  LBatch.Params.Currencies['C'] := 12.34;
  LBatch.AddRow;
  LBatch.Params.NullStrings['S'] := TOptNullString.Null;
  LBatch.Params.NullBooleans['B'] := TOptNullBoolean.Null;
  LBatch.Params.NullDateTimes['D'] := TOptNullDateTime.Null;
  LBatch.Params.NullDoubles['F'] := TOptNullDouble.Null;
  LBatch.Params.NullIntegers['I'] := TOptNullInteger.Null;
  LBatch.Params.OptNullInt64['L'] := TOptNullInt64.Null;
  LBatch.Params.NullCurrencies['C'] := TOptNullCurrency.Null;
  LBatch.AddRow;
  LBatch.Execute;
  TAssert.AssertEquals(2, LRec.Executions.Count);
  LRow := LRec.Executions[0];
  TAssert.AssertEquals('São Paulo', VarToStr(LRow['S']));
  TAssert.AssertTrue(Boolean(LRow['B']));
  TAssert.AssertEquals(LWhen, VarToDateTime(LRow['D']), 0);
  TAssert.AssertEquals(0.125, Double(LRow['F']), 0);
  TAssert.AssertEquals(-7, Integer(LRow['I']));
  TAssert.AssertEquals(Int64(9000000000), Int64(LRow['L']));
  TAssert.AssertEquals(Currency(12.34), Currency(LRow['C']));
  LRow := LRec.Executions[1];
  TAssert.AssertTrue('S must be NULL', VarIsNull(LRow['S']));
  TAssert.AssertTrue('B must be NULL', VarIsNull(LRow['B']));
  TAssert.AssertTrue('D must be NULL', VarIsNull(LRow['D']));
  TAssert.AssertTrue('F must be NULL', VarIsNull(LRow['F']));
  TAssert.AssertTrue('I must be NULL', VarIsNull(LRow['I']));
  TAssert.AssertTrue('L must be NULL', VarIsNull(LRow['L']));
  TAssert.AssertTrue('C must be NULL', VarIsNull(LRow['C']));
end;

procedure TBatchTests.Loop_ParamMissingInARow_IsNull;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
begin
  // QTY is set in the first row only: the second must not reuse it, and a
  // parameter first set in a later row (NAME) is NULL in the rows before.
  LRec := TRecordingQuery.Create;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  LBatch.Params.Integers['ID'] := 1;
  LBatch.Params.Integers['QTY'] := 7;
  LBatch.AddRow;
  LBatch.Params.Integers['ID'] := 2;
  LBatch.Params.Strings['NAME'] := 'second';
  LBatch.AddRow;
  LBatch.Execute;
  TAssert.AssertEquals(7, Integer(LRec.Executions[0]['QTY']));
  TAssert.AssertTrue('NAME, first set in row 2, is NULL in row 1', VarIsNull(LRec.Executions[0]['NAME']));
  TAssert.AssertTrue('QTY, not set in row 2, is NULL there', VarIsNull(LRec.Executions[1]['QTY']));
  TAssert.AssertEquals('second', VarToStr(LRec.Executions[1]['NAME']));
end;

procedure TBatchTests.Loop_UndefinedOptional_IsNull;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
begin
  LRec := TRecordingQuery.Create;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  LBatch.Params.Integers['ID'] := 1;
  LBatch.Params.OptStrings['NAME'] := TOptNullString.From('given');
  LBatch.AddRow;
  LBatch.Params.Integers['ID'] := 2;
  LBatch.Params.OptStrings['NAME'] := TOptNullString.Undefined;
  LBatch.AddRow;
  LBatch.Execute;
  TAssert.AssertEquals('given', VarToStr(LRec.Executions[0]['NAME']));
  TAssert.AssertTrue('An Undefined optional is NULL in its row, not the previous value',
    VarIsNull(LRec.Executions[1]['NAME']));
end;

procedure TBatchTests.AddRow_SendsWhenMaxRowsIsReached;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
  I: Integer;
begin
  LRec := TRecordingQuery.Create;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL, 2);
  TAssert.AssertEquals(2, LBatch.MaxRows);
  for I := 1 to 5 do
  begin
    LBatch.Params.Integers['ID'] := I;
    LBatch.AddRow;
    TAssert.AssertEquals('Rows sent after row ' + IntToStr(I), (I div 2) * 2, LRec.Executions.Count);
    TAssert.AssertEquals('Rows pending after row ' + IntToStr(I), I mod 2, LBatch.PendingRows);
  end;
  LBatch.Execute;
  TAssert.AssertEquals(5, LRec.Executions.Count);
  TAssert.AssertEquals(5, Integer(LRec.Executions[4]['ID']));
end;

procedure TBatchTests.Execute_WithoutRows_DoesNothing;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
begin
  LRec := TRecordingQuery.Create;
  LRec.Native := True;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  LBatch.Execute;
  TAssert.AssertEquals('No ExecSql', 0, LRec.Executions.Count);
  TAssert.AssertEquals('No ExecBatch', 0, LRec.Batches.Count);
end;

procedure TBatchTests.Execute_ValuesWithoutAddRow_Raises;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
  LRaised: string;
begin
  LRec := TRecordingQuery.Create;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  LBatch.Params.Integers['ID'] := 1;
  LBatch.AddRow;
  LBatch.Params.Integers['ID'] := 2; // the last row, without AddRow
  LRaised := '';
  try
    LBatch.Execute;
  except
    on E: Exception do
      LRaised := E.ClassName;
  end;
  TAssert.AssertEquals('A row with values and no AddRow must not be dropped silently',
    'EInvalidOpException', LRaised);
  TAssert.AssertEquals('Nothing is sent', 0, LRec.Executions.Count);
end;

procedure TBatchTests.Params_DifferentTypeInALaterRow_Raises;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
  LRaised: string;
begin
  LRec := TRecordingQuery.Create;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  LBatch.Params.Integers['QTY'] := 1;
  LBatch.AddRow;
  LRaised := '';
  try
    LBatch.Params.Int64s['QTY'] := 2;
  except
    on E: EArgumentException do
      LRaised := E.Message;
  end;
  TAssert.AssertTrue('An Int64 after an Integer must raise EArgumentException naming both: ' + LRaised,
    (Pos('QTY', LRaised) > 0) and (Pos('Integer', LRaised) > 0) and (Pos('Int64', LRaised) > 0));
end;

procedure TBatchTests.MaxRows_BelowOne_Raises;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LRaised: Boolean;
begin
  LRec := TRecordingQuery.Create;
  LQuery := LRec;
  LRaised := False;
  try
    TBatch.New(LQuery, INSERT_SQL, 0);
  except
    on E: EArgumentException do
      LRaised := True;
  end;
  TAssert.AssertTrue('MaxRows 0 must raise EArgumentException', LRaised);
end;

procedure TBatchTests.Params_ReadTheCurrentRow;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
begin
  LRec := TRecordingQuery.Create;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  LBatch.Params.Strings['NAME'] := 'first';
  TAssert.AssertEquals('first', LBatch.Params.Strings['NAME']);
  LBatch.AddRow;
  TAssert.AssertFalse('A new row starts empty', LBatch.Params.OptStrings['NAME'].HasValue);
  LBatch.Params.NullStrings['NAME'] := TOptNullString.Null;
  TAssert.AssertTrue(LBatch.Params.OptNullStrings['NAME'].IsNull);
  LBatch.AddRow;
end;

procedure TBatchTests.Native_GetsTheRowsInOneCall;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
  LRows: IBatchRows;
  I: Integer;
begin
  LRec := TRecordingQuery.Create;
  LRec.Native := True;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  TAssert.AssertTrue(LBatch.IsNative);
  for I := 1 to 3 do
  begin
    LBatch.Params.Integers['ID'] := I;
    if I = 2 then
      LBatch.Params.NullStrings['NAME'] := TOptNullString.Null
    else
      LBatch.Params.Strings['NAME'] := StringOfChar('x', I * 2);
    if I = 3 then
      LBatch.Params.Currencies['PRICE'] := 1.5;
    LBatch.AddRow;
  end;
  LBatch.Execute;
  TAssert.AssertEquals('No ExecSql on the native path', 0, LRec.Executions.Count);
  TAssert.AssertEquals('One ExecBatch', 1, LRec.Batches.Count);
  LRows := LRec.Batches[0];
  TAssert.AssertEquals(3, LRows.RowCount);
  TAssert.AssertEquals(3, LRows.ParamCount);
  TAssert.AssertEquals('ID', LRows.ParamName(0));
  TAssert.AssertEquals(Ord(pptInteger), Ord(LRows.ParamType(0)));
  TAssert.AssertEquals('NAME', LRows.ParamName(1));
  TAssert.AssertEquals(Ord(pptString), Ord(LRows.ParamType(1)));
  TAssert.AssertEquals('PRICE', LRows.ParamName(2));
  TAssert.AssertEquals(Ord(pptCurrency), Ord(LRows.ParamType(2)));
  TAssert.AssertEquals(2, LRows.AsInteger(1, 0));
  TAssert.AssertEquals('xx', LRows.AsString(0, 1));
  TAssert.AssertTrue('NAME of row 2 is NULL', LRows.IsNull(1, 1));
  TAssert.AssertTrue('PRICE, first set in row 3, is NULL in row 1', LRows.IsNull(0, 2));
  TAssert.AssertEquals(Currency(1.5), LRows.AsCurrency(2, 2));
  TAssert.AssertEquals('The longest NAME', 6, LRows.MaxLength(1));
end;

procedure TBatchTests.Native_DeclinedByTheDriver_RunsRowByRow;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
begin
  // Implements INativeBatchQuery but says no (TDataSetQueryBase's default):
  // the batch runs one ExecSql per row.
  LRec := TRecordingQuery.Create;
  LRec.Native := False;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  TAssert.AssertFalse(LBatch.IsNative);
  LBatch.Params.Integers['ID'] := 1;
  LBatch.AddRow;
  LBatch.Params.Integers['ID'] := 2;
  LBatch.AddRow;
  LBatch.Execute;
  TAssert.AssertEquals(0, LRec.Batches.Count);
  TAssert.AssertEquals(2, LRec.Executions.Count);
end;

procedure TBatchTests.Failure_DropsTheRowsOfThatSend;
var
  LRec: TRecordingQuery;
  LQuery: IQuery;
  LBatch: IBatch;
  LRaised: string;
  I: Integer;
begin
  LRec := TRecordingQuery.Create;
  LRec.FailOnExec := 2;
  LQuery := LRec;
  LBatch := TBatch.New(LQuery, INSERT_SQL);
  for I := 1 to 3 do
  begin
    LBatch.Params.Integers['ID'] := I;
    LBatch.AddRow;
  end;
  LRaised := '';
  try
    LBatch.Execute;
  except
    on E: Exception do
      LRaised := E.ClassName + ': ' + E.Message;
  end;
  TAssert.AssertEquals('The driver''s exception reaches the caller', 'EConvertError: row rejected', LRaised);
  TAssert.AssertEquals('Rows before the failure ran', 1, LRec.Executions.Count);
  TAssert.AssertEquals('The failed send''s rows are dropped', 0, LBatch.PendingRows);
  LBatch.Execute;
  TAssert.AssertEquals('A later Execute doesn''t send them again', 1, LRec.Executions.Count);
end;

procedure TBatchTests.Mock_RecordsOneExecutionPerRow;
var
  LMock: TMockDBFactory;
  LFactory: IDBFactory;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LBatch: IBatch;
  I: Integer;
begin
  // Code that uses a batch can be tested with the mock: each row is one
  // recorded execution of the SQL.
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  LScope := LFactory.GetPool.AcquireQuery(LQuery);
  LBatch := TBatch.New(LQuery, 'ITEMS.INSERT');
  for I := 1 to 4 do
  begin
    LBatch.Params.Integers['ID'] := I;
    LBatch.Params.Strings['NAME'] := 'item ' + IntToStr(I);
    LBatch.AddRow;
  end;
  LBatch.Execute;
  TAssert.AssertEquals(4, LMock.ExecutionCount('ITEMS.INSERT'));
  TAssert.AssertEquals(4, LMock.LastExecution('ITEMS.INSERT').AsInteger('ID'));
  TAssert.AssertEquals('item 4', LMock.LastExecution('ITEMS.INSERT').AsString('NAME'));
end;

initialization
  RegisterTest(TBatchTests);

end.
