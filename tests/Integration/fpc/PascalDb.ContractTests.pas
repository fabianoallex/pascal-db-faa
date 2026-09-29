unit PascalDb.ContractTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.ContractTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Contract tests for an adapter, against a real Firebird or PostgreSQL
  database (PascalDb.IntegrationEnv, PASCALDB_IT_ENGINE): only
  IDBFactory, IQuery, IParams, IQueryResult and the scope transactions are
  used, so the same bodies validate every adapter (the factory comes from
  PascalDb.IntegrationEnv). Covered: connection ping, migrations (through the
  library's own engine), a round trip of every parameter type, typed NULLs,
  optional columns through SQL tags, INSERT ... RETURNING, UTF-8 text,
  commit/rollback, nested scopes with savepoints, a constraint violation
  that must not discard the connection, scripts, row counts, parameters
  after the same SQL text is assigned again (still bound, without the
  previous run's values), one query run in several transactions in a row,
  a string parameter that grows
  while the statement stays prepared, requests staying on the pool's own
  server sessions, concurrent writers (SQLite
  allows one at a time: the others must wait for the lock, not fail), a
  statement waiting for another transaction's lock giving up after
  LockTimeoutMs with ELockConflictException, and a failed connect surfacing
  as EDatabaseConnectException whatever the driver.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Integration/fpc is generated
  from the master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  Classes,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.Optionals,
  PascalDb.Migrations,
  PascalDb.Threading,
  PascalDb.IntegrationEnv;

type
  TContractTests = class(TTestCase)
  private
    FFactory: IDBFactory;
    procedure ExecCommitted(const ASql: string);
    function CountRows(const AWhere: string): Integer;
    procedure InsertItem(AId: Integer; const AName: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published

    procedure Ping_ReturnsTrue;
    procedure Migrations_ReportCurrentVersion;
    procedure Params_EveryType_RoundTrip;
    procedure Params_TypedNulls_AreStoredAsNull;
    procedure OptionalColumn_OmittedByTag_UsesDefault;
    procedure OptionalColumn_ProvidedByTag_IsStored;
    procedure InsertReturning_ViaOpen;
    procedure Utf8Text_RoundTrip;
    procedure Commit_Persists;
    procedure Rollback_Discards;
    procedure NestedScope_RollbackToSavepoint_KeepsOuterWork;
    procedure ConstraintViolation_RaisesDataError_KeepsConnection;
    procedure SqlScript_RunsEveryStatement;
    procedure RecordCount_CountsEveryRow;
    procedure SameSqlReassigned_ParamsStillBind;
    procedure SameSqlReassigned_PreviousValuesDontLeak;
    procedure SameQuery_AcrossTransactions;
    procedure SameQuery_GrowingStringParam_Binds;
    procedure Requests_StayOnPooledConnections;
    procedure ConcurrentWriters_AllCommit;
    procedure LockWait_GivesUpAfterLockTimeout;
    procedure Unreachable_AcquireRaisesConnectException;
  end;

implementation

type
  // One writer of ConcurrentWriters_AllCommit: inserts a row and keeps its
  // transaction (and, on SQLite, the database's write lock) open for a while.
  TContractWriter = class(TThread)
  private
    FFactory: IDBFactory;
    FId: Integer;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFactory: IDBFactory; AId: Integer);
    property Error: string read FError;
  end;

constructor TContractWriter.Create(const AFactory: IDBFactory; AId: Integer);
begin
  FFactory := AFactory;
  FId := AId;
  inherited Create(False);
end;

procedure TContractWriter.Execute;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  try
    LScope := FFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    try
      LQuery.Sql := 'INSERT INTO LOG_LINES (ID, TXT) VALUES (:ID, :TXT)';
      LQuery.Params.Integers['ID'] := FId;
      LQuery.Params.Strings['TXT'] := 'writer ' + IntToStr(FId);
      LQuery.ExecSql;
      Sleep(150);
      LScope.Commit;
    except
      LScope.Rollback;
      raise;
    end;
  except
    // The driver's detail too: EDatabaseUnavailableException's Message is generic.
    on E: EDatabaseUnavailableException do
      FError := E.ClassName + ': ' + E.Message + ' (' + E.OriginalClassName + ': ' + E.OriginalMessage + ')';
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
end;

type
  // The waiting side of LockWait_GivesUpAfterLockTimeout: updates a row
  // another transaction holds, and records how long it took and what it
  // raised.
  TLockWaiter = class(TThread)
  private
    FFactory: IDBFactory;
    FElapsedMs: UInt64;
    FErrorClass: string;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFactory: IDBFactory);
    property ElapsedMs: UInt64 read FElapsedMs;
    property ErrorClass: string read FErrorClass;
    property Error: string read FError;
  end;

constructor TLockWaiter.Create(const AFactory: IDBFactory);
begin
  FFactory := AFactory;
  inherited Create(False);
end;

procedure TLockWaiter.Execute;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LStart: UInt64;
begin
  LStart := 0;
  try
    LScope := FFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    try
      LQuery.Sql := 'UPDATE ITEMS SET QTY = 2 WHERE ID = 700';
      LStart := PdbTickMs;
      LQuery.ExecSql;
      FElapsedMs := PdbTickMs - LStart;
      LScope.Commit;
    except
      if LStart <> 0 then
        FElapsedMs := PdbTickMs - LStart;
      LScope.Rollback;
      raise;
    end;
  except
    on E: Exception do
    begin
      FErrorClass := E.ClassName;
      FError := E.ClassName + ': ' + E.Message;
      if E is EDatabaseUnavailableException then
        FError := FError + ' (' + EDatabaseUnavailableException(E).OriginalClassName + ': ' +
          EDatabaseUnavailableException(E).OriginalMessage + ')';
    end;
  end;
  LQuery := nil;
  LScope := nil;
  FFactory := nil;
end;

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

// Assigning Sql resets the parameters; assigning the same text again (a loop
// that sets Sql on every iteration) must still leave them bindable. Zeos
// doesn't re-parse an unchanged SQL text, so the adapter base used to lose
// them there ("Parameter "ID" not found").
procedure TContractTests.SameSqlReassigned_ParamsStillBind;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  I: Integer;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    for I := 1 to 3 do
    begin
      LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME) VALUES (:ID, :NAME)';
      LQuery.Params.Integers['ID'] := 200 + I;
      LQuery.Params.Strings['NAME'] := 'again ' + IntToStr(I);
      LQuery.ExecSql;
    end;
    for I := 1 to 3 do
    begin
      LQuery.Sql := 'SELECT NAME FROM ITEMS WHERE ID = :ID';
      LQuery.Params.Integers['ID'] := 200 + I;
      TAssert.AssertEquals('again ' + IntToStr(I), LQuery.Open.Strings['NAME']);
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.SameSqlReassigned_PreviousValuesDontLeak;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LRan: Boolean;
begin
  // Setting the same SQL again keeps the parameters (and the prepared
  // statement) but must clear their values: a parameter the caller doesn't
  // set this time must not reach the database with the previous value.
  // Whether the driver then sends NULL or refuses an unset parameter varies;
  // either way, QTY must not be 7. (QTY, not NAME: NAME is UNIQUE, and a
  // leaked name would fail the insert for another reason.)
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME, QTY) VALUES (:ID, :NAME, :QTY)';
    LQuery.Params.Integers['ID'] := 501;
    LQuery.Params.Strings['NAME'] := 'first';
    LQuery.Params.Integers['QTY'] := 7;
    LQuery.ExecSql;

    LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME, QTY) VALUES (:ID, :NAME, :QTY)';
    LQuery.Params.Integers['ID'] := 502;
    LQuery.Params.Strings['NAME'] := 'second';
    LRan := True;
    try
      LQuery.ExecSql;
    except
      LRan := False; // the driver refused the unset parameter: nothing leaked
    end;
    if LRan then
    begin
      LQuery.Sql := 'SELECT QTY FROM ITEMS WHERE ID = :ID';
      LQuery.Params.Integers['ID'] := 502;
      LResult := LQuery.Open;
      TAssert.AssertFalse('QTY must not keep the previous run''s value',
        (not LResult.Eof) and (LResult.Integers['QTY'] = 7));
    end;
    LScope.Rollback;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.SameQuery_AcrossTransactions;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  I: Integer;
begin
  // One query, the SQL set once, run in three transactions in a row: a
  // driver that keeps the statement prepared must still run it after the
  // transaction it was prepared in has ended.
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := 'INSERT INTO LOG_LINES (ID, TXT) VALUES (:ID, :TXT)';
  for I := 1 to 3 do
  begin
    LScope.StartTransaction;
    try
      LQuery.Params.Integers['ID'] := 600 + I;
      LQuery.Params.Strings['TXT'] := 'txn ' + IntToStr(I);
      LQuery.ExecSql;
      LScope.Commit;
    except
      LScope.Rollback;
      raise;
    end;
  end;
  LScope.StartTransaction;
  try
    LQuery.Sql := 'SELECT COUNT(*) AS TOTAL FROM LOG_LINES WHERE ID BETWEEN 601 AND 603';
    TAssert.AssertEquals('Every transaction must have committed its row', 3, LQuery.Open.Integers['TOTAL']);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.SameQuery_GrowingStringParam_Binds;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  I: Integer;
begin
  // The SQL is assigned once and the query run again with a longer string
  // each time: the driver keeps the statement prepared, and FireDAC on
  // PostgreSQL kept the first value's size for the parameter, so the second
  // row failed with "Data too large for variable [NAME]".
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO ITEMS (ID, NAME) VALUES (:ID, :NAME)';
    for I := 1 to 40 do
    begin
      LQuery.Params.Integers['ID'] := 400 + I;
      LQuery.Params.Strings['NAME'] := StringOfChar('n', I);
      LQuery.ExecSql;
    end;
    LQuery.Sql := 'SELECT ID FROM ITEMS WHERE NAME = :NAME';
    for I := 1 to 40 do
    begin
      LQuery.Params.Strings['NAME'] := StringOfChar('n', I);
      TAssert.AssertEquals('Row with a ' + IntToStr(I) + '-character name', 400 + I,
        LQuery.Open.Integers['ID']);
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.Requests_StayOnPooledConnections;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LSessions: TStringList;
  I: Integer;
begin
  // Each request is what a server does: acquire, transaction, one SELECT,
  // commit, release. The work must run on the pool's connections: with a
  // Zeos TZTransaction per ITransaction, PostgreSQL got a new session for
  // every request (30 here), and the pool's limit bounded nothing.
  if SessionIdSql = '' then
    Exit; // SQLite: no server sessions to count
  LSessions := TStringList.Create;
  try
    LSessions.Sorted := True;
    LSessions.Duplicates := dupIgnore;
    for I := 1 to 30 do
    begin
      LScope := FFactory.GetPool.AcquireQuery(LQuery);
      LScope.StartTransaction;
      try
        LQuery.Sql := SessionIdSql;
        LSessions.Add(LQuery.Open.Strings['SID']);
        LScope.Commit;
      except
        LScope.Rollback;
        raise;
      end;
      LQuery := nil;
      LScope := nil;
    end;
    TAssert.AssertTrue(Format('30 requests ran on %d server sessions; the pool allows at most %d',
      [LSessions.Count, IntegrationPoolMax]), LSessions.Count <= IntegrationPoolMax);
  finally
    LSessions.Free;
  end;
end;

procedure TContractTests.ConcurrentWriters_AllCommit;
var
  LWriters: array[1..4] of TContractWriter;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LErrors: string;
  I: Integer;
begin
  for I := 1 to 4 do
    LWriters[I] := TContractWriter.Create(FFactory, 300 + I);
  LErrors := '';
  for I := 1 to 4 do
  begin
    LWriters[I].WaitFor;
    if LWriters[I].Error <> '' then
      LErrors := LErrors + ' ' + LWriters[I].Error;
    LWriters[I].Free;
  end;
  TAssert.AssertEquals('Every writer must commit (waiting for the lock if needed):' + LErrors, '', LErrors);
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'SELECT COUNT(*) AS TOTAL FROM LOG_LINES WHERE ID BETWEEN 301 AND 304';
    TAssert.AssertEquals(4, LQuery.Open.Integers['TOTAL']);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TContractTests.LockWait_GivesUpAfterLockTimeout;
const
  LOCK_TIMEOUT_MS = 1000;
  // The holder releases the row after this, so a waiter that ignores the
  // timeout finishes (and fails the test) instead of hanging the suite.
  HOLD_MS = 8000;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LWaiter: TLockWaiter;
  LStart: UInt64;
  LElapsed: UInt64;
  LErrorClass, LError: string;
begin
  InsertItem(700, 'locked row');
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'UPDATE ITEMS SET QTY = 1 WHERE ID = 700';
    LQuery.ExecSql; // this transaction now holds the row (SQLite: the database's write lock)
    LWaiter := TLockWaiter.Create(LockTimeoutFactory(LOCK_TIMEOUT_MS));
    try
      LStart := PdbTickMs;
      while (not LWaiter.Finished) and (PdbTickMs - LStart < HOLD_MS) do
        Sleep(20);
      LScope.Rollback;
      LWaiter.WaitFor;
      LElapsed := LWaiter.ElapsedMs;
      LErrorClass := LWaiter.ErrorClass;
      LError := LWaiter.Error;
    finally
      LWaiter.Free;
    end;
  except
    LScope.Rollback;
    raise;
  end;
  TAssert.AssertEquals('The waiting UPDATE must raise ELockConflictException (got: ' + LError +
    ', after ' + IntToStr(LElapsed) + ' ms)', 'ELockConflictException', LErrorClass);
  TAssert.AssertTrue(Format('It must wait for the lock, not fail at once: %d ms', [Integer(LElapsed)]),
    LElapsed >= LOCK_TIMEOUT_MS div 2);
  TAssert.AssertTrue(Format('It must give up near LockTimeoutMs (%d ms): %d ms', [LOCK_TIMEOUT_MS, Integer(LElapsed)]),
    LElapsed < HOLD_MS div 2);
end;

procedure TContractTests.Unreachable_AcquireRaisesConnectException;
var
  LFactory: IDBFactory;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LOriginal, LGot: string;
begin
  LFactory := UnreachableFactory;
  LGot := 'no exception';
  try
    LScope := LFactory.GetPool.AcquireQuery(LQuery);
  except
    on E: EDatabaseConnectException do
    begin
      LGot := '';
      LOriginal := E.OriginalClassName + ': ' + E.OriginalMessage;
    end;
    on E: Exception do
      LGot := E.ClassName + ': ' + E.Message;
  end;
  TAssert.AssertEquals('AcquireQuery with no reachable database must raise EDatabaseConnectException', '', LGot);
  TAssert.AssertTrue('OriginalMessage must keep the driver''s detail (' + LOriginal + ')',
    Length(LOriginal) > Length(': '));
  TAssert.AssertEquals('The failed attempt must not stay counted as active', 0,
    LFactory.GetPool.GetActiveConnections);
end;

initialization
  RegisterTest(TContractTests);

end.
