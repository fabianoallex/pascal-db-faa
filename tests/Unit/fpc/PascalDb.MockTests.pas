unit PascalDb.MockTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.MockTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the database mock (PascalDb.Mock): TMockQueryResult (rows,
  columns, nulls, unknown column), TMockParams (every type, including
  IOptXxx/INullXxx/IOptNullXxx), TMockSQLLoader and TMockDBFactory (responses
  registered by key, recorded executions, descriptive error for a key with no
  response).

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Variants,
  PascalCommon.Optionals,
  PascalDb.Interfaces,
  PascalDb.SqlLoader,
  PascalDb.Mock;

type
  TMockQueryResultTests = class(TTestCase)
  published
    procedure Empty_IsEmpty_True;
    procedure Empty_Eof_True;
    procedure SingleRow_IsEmpty_False;
    procedure SingleRow_FieldCount;
    procedure SingleRow_ReadValues;
    procedure SingleRow_Eof_AfterNext;
    procedure MultiRows_RecordCount;
    procedure MultiRows_CursorNavigation;
    procedure MultiRows_GetNullableString_Null;
    procedure MultiRows_ColumnNameCaseInsensitive;
    procedure UnknownColumn_Raises;
  end;

  TMockParamsTests = class(TTestCase)
  published
    procedure SetGetString;
    procedure SetGetInteger;
    procedure SetGetInt64;
    procedure SetGetBoolean;
    procedure SetGetCurrency;
    procedure SetGetDateTime;
    procedure SetOptString_HasValue_Stores;
    procedure SetOptString_Undefined_DoesNotStore;
    procedure SetNullString_Null_StoresNull;
    procedure SetNullString_WithValue_Stores;
    procedure SetOptNullString_Undefined_DoesNotStore;
    procedure SetOptNullString_Null_StoresNull;
    procedure SetOptNullString_WithValue_Stores;
    procedure KeyNormalization_CaseInsensitive;
  end;

  TMockSQLLoaderTests = class(TTestCase)
  published
    procedure GetSql_ReturnsKeyAsSQL;
    procedure GetSql_ReplaceLiteralNoOp;
    procedure GetSql_ProcessTagNoOp;
  end;

  TMockDBFactoryTests = class(TTestCase)
  published
    procedure AddResult_OpenReturnsConfiguredResult;
    procedure Open_NoResultConfigured_Raises;
    procedure ExecSql_RecordsExecution;
    procedure Open_RecordsExecution_WasOpen_True;
    procedure ExecSql_WasOpen_False;
    procedure ExecutionCount_MultipleCalls;
    procedure LastExecution_ReturnsLast;
    procedure LastExecution_UnknownKey_ReturnsNil;
    procedure RecordExecution_CapturesParams;
    procedure SqlLoader_ReturnsMockLoader;
    procedure TestConnection_ReturnsTrue;
    procedure AcquireQuery_ReturnsQuery;
    procedure Open_SameKeyAgain_ReadsFromFirstRow;
    procedure AddFailure_ExecSql_RaisesAndRecords;
    procedure AddFailure_Open_Raises;
    procedure AddFailure_IsUsedOnce_OtherKeysUnaffected;
    procedure AddConstraintViolation_RaisesItsKindOnce;
    procedure ExecSql_RowsAffected_DefaultAndConfigured;
  end;

implementation

{ TMockQueryResultTests }

procedure TMockQueryResultTests.Empty_IsEmpty_True;
begin
  TAssert.AssertTrue('Empty must be IsEmpty=True', TMockQueryResult.Empty.IsEmpty);
end;

procedure TMockQueryResultTests.Empty_Eof_True;
begin
  TAssert.AssertTrue('Empty must be Eof=True immediately', TMockQueryResult.Empty.Eof);
end;

procedure TMockQueryResultTests.SingleRow_IsEmpty_False;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['ID'], [42]);
  TAssert.AssertFalse('SingleRow must not be IsEmpty', R.IsEmpty);
end;

procedure TMockQueryResultTests.SingleRow_FieldCount;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['ID', 'NAME', 'ACTIVE'], [1, 'Test', True]);
  TAssert.AssertEquals('FieldCount must be 3', 3, R.FieldCount);
end;

procedure TMockQueryResultTests.SingleRow_ReadValues;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['ID', 'NAME'], [7, 'São Paulo']);
  TAssert.AssertEquals('ID must be 7', 7, R.GetAsInteger('ID'));
  TAssert.AssertEquals('NAME must be São Paulo', 'São Paulo', R.GetAsString('NAME'));
end;

procedure TMockQueryResultTests.SingleRow_Eof_AfterNext;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['ID'], [1]);
  TAssert.AssertFalse('Must not be Eof before Next', R.Eof);
  R.Next;
  TAssert.AssertTrue('Must be Eof after Next on the only row', R.Eof);
end;

procedure TMockQueryResultTests.MultiRows_RecordCount;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.MultiRows(
    ['ID', 'NAME'],
    [TArray<Variant>.Create(1, 'Alpha'),
     TArray<Variant>.Create(2, 'Beta'),
     TArray<Variant>.Create(3, 'Gamma')]);
  TAssert.AssertEquals('RecordCount must be 3', 3, R.RecordCount);
end;

procedure TMockQueryResultTests.MultiRows_CursorNavigation;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.MultiRows(
    ['ID'],
    [TArray<Variant>.Create(10),
     TArray<Variant>.Create(20)]);
  TAssert.AssertEquals('Cursor on row 0 must return 10', 10, R.GetAsInteger('ID'));
  R.Next;
  TAssert.AssertEquals('Cursor on row 1 must return 20', 20, R.GetAsInteger('ID'));
  R.Next;
  TAssert.AssertTrue('Must be Eof after 2 Next calls', R.Eof);
end;

procedure TMockQueryResultTests.MultiRows_GetNullableString_Null;
var
  R: IQueryResult;
  V: INullString;
begin
  R := TMockQueryResult.SingleRow(['NAME'], [Null]);
  V := R.GetNullableString('NAME');
  TAssert.AssertTrue('A Null variant must return INullString.IsNull=True', V.IsNull);
end;

procedure TMockQueryResultTests.MultiRows_ColumnNameCaseInsensitive;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['name'], ['Value']);
  TAssert.AssertEquals('The column must be accessible in upper case', 'Value', R.GetAsString('NAME'));
  TAssert.AssertEquals('The column must be accessible in lower case', 'Value', R.GetAsString('name'));
end;

procedure TMockQueryResultTests.UnknownColumn_Raises;
var
  R: IQueryResult;
  LRaised: Boolean;
begin
  R := TMockQueryResult.SingleRow(['ID'], [1]);
  LRaised := False;
  try
    R.GetAsString('INEXISTENTE');
  except
    on E: Exception do
      LRaised := True;
  end;
  TAssert.AssertTrue('An unknown column must raise an exception', LRaised);
end;

{ TMockParamsTests }

procedure TMockParamsTests.SetGetString;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetString('NAME', 'Fabiano');
  TAssert.AssertEquals('Fabiano', P.GetString('NAME'));
end;

procedure TMockParamsTests.SetGetInteger;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetInteger('ID', 42);
  TAssert.AssertEquals(42, P.GetInteger('ID'));
end;

procedure TMockParamsTests.SetGetInt64;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetInt64('BIG', 9999999999);
  TAssert.AssertEquals(Int64(9999999999), P.GetInt64('BIG'));
end;

procedure TMockParamsTests.SetGetBoolean;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetBoolean('ACTIVE', True);
  TAssert.AssertTrue(P.GetBoolean('ACTIVE'));
end;

procedure TMockParamsTests.SetGetCurrency;
var
  P: IParams;
  V: Currency;
begin
  P := TMockParams.Create;
  P.SetCurrency('PRICE', 19.99);
  V := P.GetCurrency('PRICE');
  TAssert.AssertEquals('The Currency value must be preserved', Currency(19.99), V);
end;

procedure TMockParamsTests.SetGetDateTime;
var
  P: IParams;
  D: TDateTime;
begin
  P := TMockParams.Create;
  D := EncodeDate(2025, 5, 26);
  P.SetDateTime('DT', D);
  TAssert.AssertEquals('The TDateTime must be preserved', D, P.GetDateTime('DT'), 0);
end;

procedure TMockParamsTests.SetOptString_HasValue_Stores;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptString('FIELD', TOptNullString.From('ok'));
  TAssert.AssertEquals('ok', P.GetOptString('FIELD').Value);
end;

procedure TMockParamsTests.SetOptString_Undefined_DoesNotStore;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptString('FIELD', TOptNullString.Undefined);
  TAssert.AssertFalse('Undefined must not be stored', P.GetOptString('FIELD').HasValue);
end;

procedure TMockParamsTests.SetNullString_Null_StoresNull;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetNullString('FIELD', TOptNullString.Null);
  TAssert.AssertTrue('Null must be stored as IsNull=True', P.GetNullString('FIELD').IsNull);
end;

procedure TMockParamsTests.SetNullString_WithValue_Stores;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetNullString('FIELD', TOptNullString.From('text'));
  TAssert.AssertEquals('text', P.GetNullString('FIELD').Value);
end;

procedure TMockParamsTests.SetOptNullString_Undefined_DoesNotStore;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptNullString('FIELD', TOptNullString.Undefined);
  TAssert.AssertFalse('Undefined must not be stored', P.GetOptNullString('FIELD').HasValue);
end;

procedure TMockParamsTests.SetOptNullString_Null_StoresNull;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptNullString('FIELD', TOptNullString.Null);
  TAssert.AssertTrue('OptNull Null must be stored', P.GetOptNullString('FIELD').IsNull);
end;

procedure TMockParamsTests.SetOptNullString_WithValue_Stores;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptNullString('FIELD', TOptNullString.From('value'));
  TAssert.AssertEquals('value', P.GetOptNullString('FIELD').Value);
end;

procedure TMockParamsTests.KeyNormalization_CaseInsensitive;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetString('name', 'x');
  TAssert.AssertEquals('The key must be case-insensitive', 'x', P.GetString('NAME'));
  TAssert.AssertEquals('The key must be case-insensitive', 'x', P.GetString('Name'));
end;

{ TMockSQLLoaderTests }

procedure TMockSQLLoaderTests.GetSql_ReturnsKeyAsSQL;
var
  L: TMockSQLLoader;
  S: TSQLResult;
begin
  L := TMockSQLLoader.Create;
  try
    S := L.Sql['ORDER.FIND'];
    TAssert.AssertEquals('TMockSQLLoader must return the key name as the SQL', 'ORDER.FIND', S.SQL);
  finally
    L.Free;
  end;
end;

procedure TMockSQLLoaderTests.GetSql_ReplaceLiteralNoOp;
var
  L: TMockSQLLoader;
  S: string;
begin
  L := TMockSQLLoader.Create;
  try
    S := L.Sql['ORDER.FIND'].ReplaceLiteral('LIMIT', '20').SQL;
    TAssert.AssertEquals('ReplaceLiteral without ${...} in the key name must not change anything', 'ORDER.FIND', S);
  finally
    L.Free;
  end;
end;

procedure TMockSQLLoaderTests.GetSql_ProcessTagNoOp;
var
  L: TMockSQLLoader;
  S: string;
begin
  L := TMockSQLLoader.Create;
  try
    S := L.Sql['ORDER.FIND'].ProcessTag('SEARCH', True).SQL;
    TAssert.AssertEquals('ProcessTag without tags in the key name must not change anything', 'ORDER.FIND', S);
  finally
    L.Free;
  end;
end;

{ TMockDBFactoryTests }

procedure TMockDBFactoryTests.AddResult_OpenReturnsConfiguredResult;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  R: IQueryResult;
begin
  F := TMockDBFactory.Create;
  try
    F.AddResult('CITY.FIND', TMockQueryResult.SingleRow(['TOTAL'], [5]));
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CITY.FIND');
    R := Q.Open;
    TAssert.AssertTrue('Open must return the configured IQueryResult', Assigned(R));
    TAssert.AssertEquals(5, R.GetAsInteger('TOTAL'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.Open_NoResultConfigured_Raises;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  LRaised: Boolean;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('NAO.EXISTE');
    LRaised := False;
    try
      Q.Open;
    except
      on E: Exception do
        LRaised := True;
    end;
    TAssert.AssertTrue('Open without AddResult must raise a descriptive exception', LRaised);
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.ExecSql_RecordsExecution;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CITY.INSERT');
    Q.Params.SetString('NAME', 'Curitiba');
    Q.ExecSql;
    TAssert.AssertEquals('ExecSql must record 1 execution', 1, F.ExecutionCount('CITY.INSERT'));
    TAssert.AssertEquals('Curitiba', F.LastExecution('CITY.INSERT').AsString('NAME'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.Open_RecordsExecution_WasOpen_True;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    F.AddResult('X.FIND', TMockQueryResult.Empty);
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('X.FIND');
    Q.Open;
    TAssert.AssertTrue('Open must record WasOpen=True', F.LastExecution('X.FIND').WasOpen);
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.ExecSql_WasOpen_False;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('X.DEL');
    Q.ExecSql;
    TAssert.AssertFalse('ExecSql must record WasOpen=False', F.LastExecution('X.DEL').WasOpen);
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.ExecutionCount_MultipleCalls;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  I: Integer;
begin
  F := TMockDBFactory.Create;
  try
    F.AddResult('X.FIND', TMockQueryResult.Empty);
    for I := 1 to 3 do
    begin
      Scope := F.GetPool.AcquireQuery(Q);
      Q.SetSql('X.FIND');
      Q.Open;
    end;
    TAssert.AssertEquals('Must count 3 executions', 3, F.ExecutionCount('X.FIND'));
    TAssert.AssertEquals('A different key must be 0', 0, F.ExecutionCount('OTHER'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.LastExecution_ReturnsLast;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('X.UPD'); Q.Params.SetString('NAME', 'First'); Q.ExecSql;
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('X.UPD'); Q.Params.SetString('NAME', 'Last');   Q.ExecSql;
    TAssert.AssertEquals('LastExecution must return the most recent execution', 'Last', F.LastExecution('X.UPD').AsString('NAME'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.LastExecution_UnknownKey_ReturnsNil;
var
  F: TMockDBFactory;
begin
  F := TMockDBFactory.Create;
  try
    TAssert.AssertTrue('An unknown key must return nil', not Assigned(F.LastExecution('NEVER.EXECUTED')));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.RecordExecution_CapturesParams;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  Ex: TMockExecution;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('PRODUTO.INSERT');
    Q.Params.SetString('NAME',   'Pen');
    Q.Params.SetInteger('QTY',   10);
    Q.Params.SetCurrency('PRICE', 2.50);
    Q.ExecSql;

    Ex := F.LastExecution('PRODUTO.INSERT');
    TAssert.AssertTrue(Assigned(Ex));
    TAssert.AssertTrue('The snapshot must have NAME', Ex.HasParam('NAME'));
    TAssert.AssertTrue('The snapshot must have QTY', Ex.HasParam('QTY'));
    TAssert.AssertTrue('The snapshot must have PRICE', Ex.HasParam('PRICE'));
    TAssert.AssertEquals('Pen', Ex.AsString('NAME'));
    TAssert.AssertEquals(10, Ex.AsInteger('QTY'));
    TAssert.AssertEquals('The price must be preserved', Currency(2.50), Ex.AsCurrency('PRICE'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.SqlLoader_ReturnsMockLoader;
var
  F: TMockDBFactory;
  L: TSQLLoader;
begin
  F := TMockDBFactory.Create;
  try
    L := F.SqlLoader;
    TAssert.AssertTrue('SqlLoader must not return nil', Assigned(L));
    TAssert.AssertTrue('SqlLoader must be a TMockSQLLoader', L is TMockSQLLoader);
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.TestConnection_ReturnsTrue;
var
  F: TMockDBFactory;
begin
  F := TMockDBFactory.Create;
  try
    TAssert.AssertTrue('TestConnection on the mock must return True', F.TestConnection(nil));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.AcquireQuery_ReturnsQuery;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    TAssert.AssertTrue('AcquireQuery must return an IQuery', Assigned(Q));
    TAssert.AssertTrue('AcquireQuery must return an IScopeTransaction', Assigned(Scope));
    TAssert.AssertTrue('IQuery.Params must not be nil', Assigned(Q.Params));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.Open_SameKeyAgain_ReadsFromFirstRow;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  R: IQueryResult;
begin
  F := TMockDBFactory.Create;
  try
    F.AddResult('CITY.LIST', TMockQueryResult.MultiRows(['NAME'],
      [TArray<Variant>.Create('Curitiba'), TArray<Variant>.Create('Londrina')]));
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CITY.LIST');
    R := Q.Open;
    while not R.Eof do
      R.Next;
    // A second Open of the same key, as a repository called twice does.
    R := Q.Open;
    TAssert.AssertFalse('A new Open must not start at Eof', R.Eof);
    TAssert.AssertEquals('A new Open must start at the first row', 'Curitiba', R.GetAsString('NAME'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.AddFailure_ExecSql_RaisesAndRecords;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  LRaised: Boolean;
begin
  F := TMockDBFactory.Create;
  try
    F.AddFailure('CITY.INSERT', EConvertError, 'unique constraint violated');
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CITY.INSERT');
    Q.Params.SetString('NAME', 'Curitiba');
    LRaised := False;
    try
      Q.ExecSql;
    except
      on E: EConvertError do
      begin
        LRaised := True;
        TAssert.AssertEquals('unique constraint violated', E.Message);
      end;
    end;
    TAssert.AssertTrue('ExecSql must raise the registered exception class', LRaised);
    TAssert.AssertEquals('The failed execution must still be recorded', 1, F.ExecutionCount('CITY.INSERT'));
    TAssert.AssertEquals('Curitiba', F.LastExecution('CITY.INSERT').AsString('NAME'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.AddFailure_Open_Raises;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  LRaised: Boolean;
begin
  F := TMockDBFactory.Create;
  try
    F.AddResult('CITY.FIND', TMockQueryResult.SingleRow(['TOTAL'], [5]));
    F.AddFailure('CITY.FIND', EConvertError, 'connection reset');
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CITY.FIND');
    LRaised := False;
    try
      Q.Open;
    except
      on EConvertError do
        LRaised := True;
    end;
    TAssert.AssertTrue('Open must raise the registered failure before returning the result', LRaised);
    TAssert.AssertEquals('The next Open returns the result again', 5, Q.Open.GetAsInteger('TOTAL'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.AddFailure_IsUsedOnce_OtherKeysUnaffected;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  LFailures: Integer;
  I: Integer;
begin
  F := TMockDBFactory.Create;
  try
    F.AddFailure('CITY.INSERT', EConvertError, 'first');
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CITY.DELETE');
    Q.ExecSql; // another key: must not consume or raise the failure
    LFailures := 0;
    Q.SetSql('CITY.INSERT');
    for I := 1 to 3 do
      try
        Q.ExecSql;
      except
        on EConvertError do
          Inc(LFailures);
      end;
    TAssert.AssertEquals('A failure is used by exactly one execution', 1, LFailures);
    TAssert.AssertEquals(3, F.ExecutionCount('CITY.INSERT'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.AddConstraintViolation_RaisesItsKindOnce;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  LKind: Integer;
begin
  F := TMockDBFactory.Create;
  try
    F.AddConstraintViolation('CITY.DELETE', cvForeignKey);
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CITY.DELETE');
    LKind := -1;
    try
      Q.ExecSql;
    except
      on E: EConstraintViolationException do
        LKind := Ord(E.Kind);
    end;
    TAssert.AssertEquals('ExecSql must raise EConstraintViolationException of the registered kind',
      Ord(cvForeignKey), LKind);
    Q.ExecSql; // used once: the next execution succeeds
    TAssert.AssertEquals(2, F.ExecutionCount('CITY.DELETE'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.ExecSql_RowsAffected_DefaultAndConfigured;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CITY.UPDATE');
    TAssert.AssertEquals('Without SetRowsAffected: -1, as a driver that can''t tell', Int64(-1), Q.ExecSql);
    F.SetRowsAffected('city.update', 0);
    TAssert.AssertEquals('The configured count, whatever the key''s case', Int64(0), Q.ExecSql);
    TAssert.AssertEquals('And on every later execution', Int64(0), Q.ExecSql);
    Q.SetSql('CITY.DELETE');
    TAssert.AssertEquals('Other keys are unaffected', Int64(-1), Q.ExecSql);
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TMockQueryResultTests);
  RegisterTest(TMockParamsTests);
  RegisterTest(TMockSQLLoaderTests);
  RegisterTest(TMockDBFactoryTests);

end.
