unit PascalDb.ContractTests;

{ Contract tests for an adapter, against a real Firebird database: only
  IDBFactory, IQuery, IParams, IQueryResult and the scope transactions are
  used, so the same bodies validate every adapter (the factory comes from
  PascalDb.IntegrationEnv). Covered: connection ping, migrations (through the
  library's own engine), a round trip of every parameter type, typed NULLs,
  optional columns through SQL tags, INSERT ... RETURNING, UTF-8 text,
  commit/rollback, nested scopes with savepoints, a constraint violation
  that must not discard the connection, scripts, and row counts.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Integration/fpc is generated
  from the master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalDb.DUnitXCompat,
  Classes,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.Optionals,
  PascalDb.Migrations,
  PascalDb.IntegrationEnv;

type
  [TestFixture]
  TContractTests = class
  private
    FFactory: IDBFactory;
    procedure ExecCommitted(const ASql: string);
    function CountRows(const AWhere: string): Integer;
    procedure InsertItem(AId: Integer; const AName: string);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure Ping_ReturnsTrue;
    [Test] procedure Migrations_ReportCurrentVersion;
    [Test] procedure Params_EveryType_RoundTrip;
    [Test] procedure Params_TypedNulls_AreStoredAsNull;
    [Test] procedure OptionalColumn_OmittedByTag_UsesDefault;
    [Test] procedure OptionalColumn_ProvidedByTag_IsStored;
    [Test] procedure InsertReturning_ViaOpen;
    [Test] procedure Utf8Text_RoundTrip;
    [Test] procedure Commit_Persists;
    [Test] procedure Rollback_Discards;
    [Test] procedure NestedScope_RollbackToSavepoint_KeepsOuterWork;
    [Test] procedure ConstraintViolation_RaisesDataError_KeepsConnection;
    [Test] procedure SqlScript_RunsEveryStatement;
    [Test] procedure RecordCount_CountsEveryRow;
  end;

implementation

{ TContractTests }

procedure TContractTests.Setup;
begin
  FFactory := IntegrationFactory;
  ExecCommitted('DELETE FROM ITEMS');
  ExecCommitted('DELETE FROM LOG_LINES');
end;

procedure TContractTests.TearDown;
begin
  // Release the factory: the test framework keeps fixture objects alive
  // until after PascalDb.IntegrationEnv is finalized, and a factory held
  // here would keep pooled connections open and make the final DROP fail.
  FFactory := nil;
end;

procedure TContractTests.ExecCommitted(const ASql: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
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

function TContractTests.CountRows(const AWhere: string): Integer;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'SELECT COUNT(*) AS TOTAL FROM ITEMS WHERE ' + AWhere;
    Result := LQuery.Open.Integers['TOTAL'];
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.InsertItem(AId: Integer; const AName: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME) VALUES (:ID, :NAME)';
    LQuery.Params.Integers['ID'] := AId;
    LQuery.Params.Strings['NAME'] := AName;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.Ping_ReturnsTrue;
begin
  TAssert.AssertTrue('TestConnection must succeed on a fresh connection',
    FFactory.TestConnection(FFactory.CreateConnection));
end;

procedure TContractTests.Migrations_ReportCurrentVersion;
var
  LEngine: TDBMigrationEngine;
begin
  LEngine := TDBMigrationEngine.Create(FFactory, nil);
  try
    TAssert.AssertEquals('Every migration must have been applied',
      IntegrationSchemaVersion, LEngine.CurrentVersion);
  finally
    LEngine.Free;
  end;
end;

procedure TContractTests.Params_EveryType_RoundTrip;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LWhen: TDateTime;
begin
  LWhen := EncodeDate(2026, 9, 25) + EncodeTime(10, 11, 12, 0);
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME, QTY, BIG, PRICE, RATIO, CREATED_AT, ACTIVE) ' +
      'VALUES (:ID, :NAME, :QTY, :BIG, :PRICE, :RATIO, :CREATED_AT, :ACTIVE)';
    LQuery.Params.Integers['ID'] := 1;
    LQuery.Params.Strings['NAME'] := 'pen';
    LQuery.Params.Integers['QTY'] := -7;
    LQuery.Params.Int64s['BIG'] := 9000000000;
    LQuery.Params.Currencies['PRICE'] := 12.34;
    LQuery.Params.Doubles['RATIO'] := 0.125;
    LQuery.Params.DateTimes['CREATED_AT'] := LWhen;
    LQuery.Params.Integers['ACTIVE'] := 1;
    LQuery.ExecSql;

    LQuery.Sql := 'SELECT * FROM ITEMS WHERE ID = :ID';
    LQuery.Params.Integers['ID'] := 1;
    LResult := LQuery.Open;
    TAssert.AssertEquals('pen', LResult.Strings['NAME']);
    TAssert.AssertEquals(-7, LResult.Integers['QTY']);
    TAssert.AssertEquals(Int64(9000000000), LResult.Int64s['BIG']);
    TAssert.AssertEquals(Currency(12.34), LResult.Currencies['PRICE']);
    TAssert.AssertEquals('Double must round-trip', 0.125, LResult.FieldValue(5), 0);
    TAssert.AssertEquals('Timestamp must round-trip', LWhen, LResult.DateTimes['CREATED_AT'], 1 / 86400000);
    TAssert.AssertTrue('A SMALLINT 1 must read as True', LResult.Booleans['ACTIVE']);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.Params_TypedNulls_AreStoredAsNull;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME, QTY, BIG, PRICE, CREATED_AT, NOTE) ' +
      'VALUES (:ID, :NAME, :QTY, :BIG, :PRICE, :CREATED_AT, :NOTE)';
    LQuery.Params.Integers['ID'] := 2;
    LQuery.Params.NullStrings['NAME'] := TOptNullString.Null;
    LQuery.Params.NullIntegers['QTY'] := TOptNullInteger.Null;
    LQuery.Params.OptNullInt64['BIG'] := TOptNullInt64.Null;
    LQuery.Params.NullCurrencies['PRICE'] := TOptNullCurrency.Null;
    LQuery.Params.NullDateTimes['CREATED_AT'] := TOptNullDateTime.Null;
    LQuery.Params.OptNullStrings['NOTE'] := TOptNullString.Null;
    LQuery.ExecSql;

    LQuery.Sql := 'SELECT * FROM ITEMS WHERE ID = :ID';
    LQuery.Params.Integers['ID'] := 2;
    LResult := LQuery.Open;
    TAssert.AssertTrue('NAME must be NULL', LResult.NullableStrings['NAME'].IsNull);
    TAssert.AssertTrue('QTY must be NULL', LResult.NullableIntegers['QTY'].IsNull);
    TAssert.AssertTrue('BIG must be NULL', LResult.NullableInt64['BIG'].IsNull);
    TAssert.AssertTrue('PRICE must be NULL', LResult.NullableCurrencies['PRICE'].IsNull);
    TAssert.AssertTrue('CREATED_AT must be NULL', LResult.NullableDateTimes['CREATED_AT'].IsNull);
    TAssert.AssertTrue('An explicit NULL must override the column default', LResult.NullableStrings['NOTE'].IsNull);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.OptionalColumn_OmittedByTag_UsesDefault;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LNote: IOptString;
begin
  LNote := TOptNullString.Undefined;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['ITEMS.INSERT'].ProcessTag('NOTE', LNote.HasValue).SQL;
    LQuery.Params.Integers['ID'] := 3;
    LQuery.Params.Strings['NAME'] := 'no note';
    LQuery.Params.Integers['QTY'] := 1;
    LQuery.Params.Int64s['BIG'] := 1;
    LQuery.Params.Currencies['PRICE'] := 1;
    LQuery.Params.Doubles['RATIO'] := 1;
    LQuery.Params.DateTimes['CREATED_AT'] := Now;
    LQuery.Params.Integers['ACTIVE'] := 0;
    LQuery.Params.OptStrings['NOTE'] := LNote;
    TAssert.AssertEquals('The column default must apply when the tag removes it',
      'default note', LQuery.Open.Strings['NOTE']);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.OptionalColumn_ProvidedByTag_IsStored;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LNote: IOptString;
begin
  LNote := TOptNullString.From('given');
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['ITEMS.INSERT'].ProcessTag('NOTE', LNote.HasValue).SQL;
    LQuery.Params.Integers['ID'] := 4;
    LQuery.Params.Strings['NAME'] := 'with note';
    LQuery.Params.Integers['QTY'] := 1;
    LQuery.Params.Int64s['BIG'] := 1;
    LQuery.Params.Currencies['PRICE'] := 1;
    LQuery.Params.Doubles['RATIO'] := 1;
    LQuery.Params.DateTimes['CREATED_AT'] := Now;
    LQuery.Params.Integers['ACTIVE'] := 0;
    LQuery.Params.OptStrings['NOTE'] := LNote;
    TAssert.AssertEquals('given', LQuery.Open.Strings['NOTE']);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.InsertReturning_ViaOpen;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME) VALUES (:ID, :NAME) RETURNING ID, NAME';
    LQuery.Params.Integers['ID'] := 5;
    LQuery.Params.Strings['NAME'] := 'returned';
    LResult := LQuery.Open;
    TAssert.AssertFalse('RETURNING must produce a row', LResult.IsEmpty);
    TAssert.AssertEquals(5, LResult.Integers['ID']);
    TAssert.AssertEquals('returned', LResult.Strings['NAME']);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  TAssert.AssertEquals('The returned row must be committed', 1, CountRows('ID = 5'));
end;

procedure TContractTests.Utf8Text_RoundTrip;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  InsertItem(6, 'São Paulo → ok');
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'SELECT NAME FROM ITEMS WHERE ID = 6';
    TAssert.AssertEquals('Non-ASCII text must survive the database round trip',
      'São Paulo → ok', LQuery.Open.Strings['NAME']);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.Commit_Persists;
begin
  InsertItem(7, 'committed');
  TAssert.AssertEquals(1, CountRows('ID = 7'));
end;

procedure TContractTests.Rollback_Discards;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME) VALUES (8, ''rolled back'')';
  LQuery.ExecSql;
  LScope.Rollback;
  LQuery := nil;
  LScope := nil;
  TAssert.AssertEquals('A rolled-back insert must not persist', 0, CountRows('ID = 8'));
end;

procedure TContractTests.NestedScope_RollbackToSavepoint_KeepsOuterWork;
var
  LOuterQuery, LInnerQuery: IQuery;
  LOuter, LInner: IScopeTransaction;
begin
  LOuter := FFactory.GetPool.AcquireQuery(LOuterQuery);
  LOuter.StartTransaction;
  try
    LOuterQuery.Sql := 'INSERT INTO ITEMS (ID, NAME) VALUES (9, ''outer'')';
    LOuterQuery.ExecSql;

    // Same transaction, nested scope: must use a savepoint.
    LInner := FFactory.GetPool.AcquireQuery(LInnerQuery, LOuter.OriginalTransaction);
    TAssert.AssertFalse('The nested scope must not be the main one', LInner.IsMain);
    LInner.StartTransaction;
    LInnerQuery.Sql := 'INSERT INTO ITEMS (ID, NAME) VALUES (10, ''inner'')';
    LInnerQuery.ExecSql;
    LInner.Rollback;

    LOuter.Commit;
  except
    LOuter.Rollback;
    raise;
  end;
  TAssert.AssertEquals('The outer insert must be committed', 1, CountRows('ID = 9'));
  TAssert.AssertEquals('The inner insert must be rolled back to the savepoint', 0, CountRows('ID = 10'));
end;

procedure TContractTests.ConstraintViolation_RaisesDataError_KeepsConnection;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LRaised: Boolean;
  LUnavailable: Boolean;
  LActiveBefore: Integer;
begin
  InsertItem(11, 'unique name');
  LActiveBefore := FFactory.GetPool.GetActiveConnections;
  LRaised := False;
  LUnavailable := False;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME) VALUES (12, ''unique name'')';
    LQuery.ExecSql;
  except
    on E: EDatabaseUnavailableException do
      LUnavailable := True;
    on E: Exception do
      LRaised := True;
  end;
  LScope.Rollback;
  LQuery := nil;
  LScope := nil;
  TAssert.AssertTrue('A duplicate key must raise', LRaised or LUnavailable);
  TAssert.AssertFalse('A data error must not be reported as an unavailable database', LUnavailable);
  TAssert.AssertEquals('The healthy connection must not be discarded',
    LActiveBefore, FFactory.GetPool.GetActiveConnections);
end;

procedure TContractTests.SqlScript_RunsEveryStatement;
var
  LConn: IDBConnection;
  LTransaction: ITransaction;
  LScript: ISqlScript;
  LQuery: IQuery;
begin
  LConn := FFactory.CreateConnection;
  LTransaction := FFactory.CreateTransaction(LConn);
  LTransaction.StartTransaction;
  LScript := FFactory.CreateSqlScript(LConn, LTransaction);
  LScript.Script.Text :=
    'INSERT INTO LOG_LINES (ID, TXT) VALUES (1, ''a'')^' + sLineBreak +
    'INSERT INTO LOG_LINES (ID, TXT) VALUES (2, ''b'')^' + sLineBreak +
    'INSERT INTO LOG_LINES (ID, TXT) VALUES (3, ''c'')^';
  LScript.ExecuteScript('^');
  LQuery := FFactory.CreateQuery(LConn, LTransaction);
  LQuery.Sql := 'SELECT COUNT(*) AS TOTAL FROM LOG_LINES';
  TAssert.AssertEquals('Every statement of the script must run', 3, LQuery.Open.Integers['TOTAL']);
  LQuery.Close;
  LTransaction.Rollback;
end;

procedure TContractTests.RecordCount_CountsEveryRow;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  I: Integer;
  LResult: IQueryResult;
  LSeen: Integer;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME) VALUES (:ID, :NAME)';
    for I := 100 to 124 do
    begin
      LQuery.Params.Integers['ID'] := I;
      LQuery.Params.Strings['NAME'] := 'row ' + IntToStr(I);
      LQuery.ExecSql;
    end;
    LQuery.Sql := 'SELECT ID FROM ITEMS WHERE ID >= 100 ORDER BY ID';
    LResult := LQuery.Open;
    TAssert.AssertEquals('RecordCount must count every row, not just a fetched packet', 25, LResult.RecordCount);
    LSeen := 0;
    while not LResult.Eof do
    begin
      Inc(LSeen);
      LResult.Next;
    end;
    TAssert.AssertEquals(25, LSeen);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TContractTests);

end.
