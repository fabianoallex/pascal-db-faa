unit PascalDb.Mock;

{$I pascaldb.inc}

{ In-memory mock of IDBFactory (TMockDBFactory), for testing repositories
  and services without a database.

  Usage flow:
    1. Create a TMockDBFactory.
    2. Register responses with AddResult('SQL.KEY', TMockQueryResult.Xyz)
       (every Open of a key reads its result from the first row), and
       database errors with AddFailure('SQL.KEY', EClass, 'message') (the next
       execution of the key raises it).
    3. Exercise the repository/service.
    4. Inspect the executions with LastExecution / ExecutionCount.

  Lifetime: TMockDBFactory is reference-counted (TInterfacedObject), and a
  repository keeps the factory it receives as an IDBFactory. Hold the mock in
  an IDBFactory variable as well and never call Free: with only a class
  variable, releasing the repository drops the last reference and frees the
  mock, so the next LastExecution reads freed memory.

  Example — testing TCityRepository.Insert (samples/common):

    var
      LMock: TMockDBFactory;
      LFactory: IDBFactory;  // keeps the mock alive
      LRepo: TCityRepository;
    begin
      LMock := TMockDBFactory.Create;
      LFactory := LMock;
      LRepo := TCityRepository.Create(LFactory);
      try
        LRepo.Insert(City('3550308', 'São Paulo', 'sp'));

        Assert.AreEqual('3550308',   LMock.LastExecution('CITY.INSERT').AsString('CODE'));
        Assert.AreEqual('São Paulo', LMock.LastExecution('CITY.INSERT').AsString('NAME'));
        Assert.AreEqual('SP',        LMock.LastExecution('CITY.INSERT').AsString('STATE'));
      finally
        LRepo.Free;
      end;
    end;  // LFactory goes out of scope: the mock is freed here

  Example — testing TCityRepository.FindByState:

    LMock.AddResult('CITY.BY_STATE',
      TMockQueryResult.MultiRows(
        ['CODE', 'NAME', 'STATE'],
        [TArray<Variant>.Create('3509502', 'Campinas', 'SP'),
         TArray<Variant>.Create('3550308', 'São Paulo', 'SP')]));

    LCities := LRepo.FindByState('SP');
    Assert.AreEqual(2, Length(LCities));

  AddResult is needed for every key the code under test Opens (Open raises
  when none was registered); ExecSql needs none. The examples use DUnitX's Assert; the mock itself
  doesn't depend on any test framework (samples/01-mock-repository checks
  with plain code). }

interface

uses
  SysUtils,
  Variants,
  Generics.Collections,
  PascalDb.Optionals,
  PascalDb.Interfaces,
  PascalDb.SqlLoader;

type
  TMockDBFactory = class; // forward

  // Snapshot of the parameters captured at execution time (Open or ExecSql).
  // Use AsString/AsInteger/etc. in test assertions.
  TMockExecution = class
  private
    FKey: string;
    FWasOpen: Boolean;
    FParams: TDictionary<string, Variant>;
    function GetVariant(const AName: string): Variant;
  public
    constructor Create(const AKey: string; ASnapshot: TDictionary<string, Variant>; AWasOpen: Boolean);
    destructor Destroy; override;
    function AsString(const AName: string): string;
    function AsInteger(const AName: string): Integer;
    function AsInt64(const AName: string): Int64;
    function AsBoolean(const AName: string): Boolean;
    function AsCurrency(const AName: string): Currency;
    function AsDateTime(const AName: string): TDateTime;
    function HasParam(const AName: string): Boolean;
    function IsNull(const AName: string): Boolean;
    property Key: string read FKey;
    property WasOpen: Boolean read FWasOpen;
  end;

  // Internal: lets TMockQuery.Open put a registered result back on its first
  // row, so every Open of a key reads the rows from the start, as a new query
  // on a database would.
  IMockRewindable = interface
    ['{9BE5F64A-CC50-48C8-8D50-E41086FE25CC}']
    procedure Rewind;
  end;

  // IQueryResult built from controlled data.
  // Use the class functions to build the expected results before the test.
  TMockQueryResult = class(TInterfacedObject, IQueryResult, IMockRewindable)
  private
    FColumns: TArray<string>;
    FRows: TArray<TArray<Variant>>;
    FCursor: Integer;
    function ColIndex(const AName: string): Integer;
    function CurrentVariant(const AName: string): Variant;
    procedure Rewind;
  public
    constructor Create(const AColumns: TArray<string>; const ARows: TArray<TArray<Variant>>);

    class function Empty: IQueryResult;
    class function SingleRow(const AFields: array of string;
      const AValues: array of Variant): IQueryResult;
    class function MultiRows(const AFields: array of string;
      const AData: array of TArray<Variant>): IQueryResult;

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

  // IParams backed by an internal Variant store (keys upper-cased).
  // Optional/Nullable wrappers are unpacked on Set and repacked on Get.
  TMockParams = class(TInterfacedObject, IParams)
  private
    FValues: TDictionary<string, Variant>;
    function GetV(const AName: string): Variant;
    procedure PutV(const AName: string; const AValue: Variant);
  public
    constructor Create;
    destructor Destroy; override;
    procedure CopyTo(ADest: TDictionary<string, Variant>);
    // IParams — plain getters
    function GetString(const AName: string): string;
    function GetBoolean(const AName: string): Boolean;
    function GetDateTime(const AName: string): TDateTime;
    function GetInteger(const AName: string): Integer;
    function GetInt64(const AName: string): Int64;
    function GetDouble(const AName: string): Double;
    function GetCurrency(const AName: string): Currency;
    // IParams — Opt getters
    function GetOptString(const AName: string): IOptString;
    function GetOptBoolean(const AName: string): IOptBoolean;
    function GetOptDateTime(const AName: string): IOptDateTime;
    function GetOptInteger(const AName: string): IOptInteger;
    function GetOptInt64(const AName: string): IOptInt64;
    function GetOptDouble(const AName: string): IOptDouble;
    function GetOptCurrency(const AName: string): IOptCurrency;
    // IParams — Null getters
    function GetNullString(const AName: string): INullString;
    function GetNullBoolean(const AName: string): INullBoolean;
    function GetNullDateTime(const AName: string): INullDateTime;
    function GetNullInteger(const AName: string): INullInteger;
    function GetNullInt64(const AName: string): INullInt64;
    function GetNullDouble(const AName: string): INullDouble;
    function GetNullCurrency(const AName: string): INullCurrency;
    // IParams — OptNull getters
    function GetOptNullString(const AName: string): IOptNullString;
    function GetOptNullBoolean(const AName: string): IOptNullBoolean;
    function GetOptNullDateTime(const AName: string): IOptNullDateTime;
    function GetOptNullInteger(const AName: string): IOptNullInteger;
    function GetOptNullInt64(const AName: string): IOptNullInt64;
    function GetOptNullDouble(const AName: string): IOptNullDouble;
    function GetOptNullCurrency(const AName: string): IOptNullCurrency;
    // IParams — plain setters
    procedure SetString(const AName: string; AValue: string);
    procedure SetBoolean(const AName: string; AValue: Boolean);
    procedure SetDateTime(const AName: string; AValue: TDateTime);
    procedure SetInteger(const AName: string; AValue: Integer);
    procedure SetInt64(const AName: string; AValue: Int64);
    procedure SetDouble(const AName: string; AValue: Double);
    procedure SetCurrency(const AName: string; AValue: Currency);
    // IParams — Opt setters (undefined = not stored)
    procedure SetOptString(const AName: string; AValue: IOptString);
    procedure SetOptBoolean(const AName: string; AValue: IOptBoolean);
    procedure SetOptDateTime(const AName: string; AValue: IOptDateTime);
    procedure SetOptInteger(const AName: string; AValue: IOptInteger);
    procedure SetOptInt64(const AName: string; AValue: IOptInt64);
    procedure SetOptDouble(const AName: string; AValue: IOptDouble);
    procedure SetOptCurrency(const AName: string; AValue: IOptCurrency);
    // IParams — Null setters (null = stores a Null variant)
    procedure SetNullString(const AName: string; AValue: INullString);
    procedure SetNullBoolean(const AName: string; AValue: INullBoolean);
    procedure SetNullDateTime(const AName: string; AValue: INullDateTime);
    procedure SetNullInteger(const AName: string; AValue: INullInteger);
    procedure SetNullInt64(const AName: string; AValue: INullInt64);
    procedure SetNullDouble(const AName: string; AValue: INullDouble);
    procedure SetNullCurrency(const AName: string; AValue: INullCurrency);
    // IParams — OptNull setters (undefined = not stored; null = Null variant)
    procedure SetOptNullString(const AName: string; AValue: IOptNullString);
    procedure SetOptNullBoolean(const AName: string; AValue: IOptNullBoolean);
    procedure SetOptNullDateTime(const AName: string; AValue: IOptNullDateTime);
    procedure SetOptNullInteger(const AName: string; AValue: IOptNullInteger);
    procedure SetOptNullInt64(const AName: string; AValue: IOptNullInt64);
    procedure SetOptNullDouble(const AName: string; AValue: IOptNullDouble);
    procedure SetOptNullCurrency(const AName: string; AValue: IOptNullCurrency);
  end;

  // IQuery that dispatches Open/ExecSql to TMockDBFactory
  TMockQuery = class(TInterfacedObject, IQuery)
  private
    FOwner: TMockDBFactory;
    FParams: IParams;
    FSql: string;
  public
    constructor Create(AOwner: TMockDBFactory);
    function GetParams: IParams;
    procedure SetSql(const ASql: string);
    function GetSql: string;
    function Open: IQueryResult;
    procedure Close;
    procedure ExecSql;
    function GetConnection: IDBConnection;
    function GetTransaction: ITransaction;
  end;

  // No-op IScopeTransaction — StartTransaction/Commit/Rollback do nothing
  TMockScopeTransaction = class(TInterfacedObject, IScopeTransaction)
  private
    FTransaction: ITransaction;
  public
    constructor Create;
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;
    function IsMain: Boolean;
    function GetOriginalTransaction: ITransaction;
  end;

  // IDBConnectionPool that creates a TMockQuery on AcquireQuery
  TMockConnectionPool = class(TInterfacedObject, IDBConnectionPool)
  private
    FOwner: TMockDBFactory;
  public
    constructor Create(AOwner: TMockDBFactory);
    function AcquireConnection: IDBConnection;
    function GetWaitMaxAttemps: Integer;
    function GetWaitMilliseconds: Integer;
    function AcquireQuery(out AQuery: IQuery; ATransaction: ITransaction = nil): IScopeTransaction;
    function GetActiveConnections: Integer;
    function GetPoolSize: Integer;
    function GetSnapshot: TPoolSnapshot;
  end;

  // Dialect of the mock connection: no savepoint SQL (the mock scope runs
  // none) and a LIMIT/OFFSET paging clause, so code calling PdbPagingClause
  // runs against the mock. The mock's SQL loader returns the key itself, so
  // the clause never reaches what LastExecution records.
  TMockSQLDialect = class(TInterfacedObject, ISQLDialect, IPagingDialect)
  public
    function GetSavepointSQL(const AName: string): string;
    function GetRollbackToSavepointSQL(const AName: string): string;
    function GetReleaseSavepointSQL(const AName: string): string;
    function SupportsRelease: Boolean;
    function GetPingSQL: string;
    function GetPagingClause(ALimit: Integer; AOffset: Int64): string;
  end;

  // Minimal IDBConnection — every operation is a no-op
  TMockDBConnection = class(TInterfacedObject, IDBConnection)
  public
    function GetNativeConnection: TObject;
    function IsConnected: Boolean;
    procedure Connect;
    procedure Commit;
    procedure Rollback;
    procedure Disconnect(Force: Boolean = False);
    function GetSQLDialect: ISQLDialect;
  end;

  // Minimal ITransaction — every operation is a no-op
  TMockTransaction = class(TInterfacedObject, ITransaction)
  public
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;
    function GetConnection: IDBConnection;
    function GetNativeTransaction: TObject;
    procedure ExecSql(const ASql: string);
  end;

  // TSQLLoader that bypasses resource loading.
  // GetSql returns the key name itself as the SQL text, no .res needed.
  // ReplaceLiteral and ProcessTag have no effect on a plain key name.
  TMockSQLLoader = class(TSQLLoader)
  protected
    function GetSql(const AResourceName: string): TSQLResult; override;
  public
    constructor Create;
  end;

  // The mock's central factory. Configure the results before using the
  // repository; inspect the executions with LastExecution / ExecutionCount.
  TMockFailure = record
    Key: string;
    ExceptionClass: ExceptClass;
    Message: string;
  end;

  TMockDBFactory = class(TInterfacedObject, IDBFactory)
  private
    FPool: IDBConnectionPool;
    FSqlLoader: TMockSQLLoader;
    FResults: TDictionary<string, IQueryResult>;
    FExecutions: TObjectList<TMockExecution>;
    FFailures: TList<TMockFailure>;
  public
    constructor Create;
    destructor Destroy; override;

    // Registers the IQueryResult to return when ASqlKey is queried via Open.
    // Every Open of the key reads it from the first row.
    // Pass nil or TMockQueryResult.Empty for calls that only use ExecSql.
    procedure AddResult(const ASqlKey: string; AResult: IQueryResult);

    // Makes the NEXT execution of ASqlKey (Open or ExecSql) raise
    // AExceptionClass.Create(AMessage), as a database rejecting the statement
    // would (a constraint violation, say). The execution is still recorded
    // (LastExecution/ExecutionCount), then the exception is raised. Each call
    // is used once; call it again for more failures, which are used in order.
    procedure AddFailure(const ASqlKey: string; AExceptionClass: ExceptClass;
      const AMessage: string);

    // Internal use: called by TMockQuery. Raises the pending failure for
    // ASqlKey, if any.
    procedure RaisePendingFailure(const ASqlKey: string);

    // Returns the last execution record for ASqlKey (Open or ExecSql), or nil.
    function LastExecution(const ASqlKey: string): TMockExecution;

    // Returns how many times ASqlKey was executed (Open + ExecSql).
    function ExecutionCount(const ASqlKey: string): Integer;

    // Internal use: called by TMockQuery
    function GetResult(const ASqlKey: string): IQueryResult;
    procedure RecordExecution(const ASqlKey: string; AParams: TMockParams; AWasOpen: Boolean);

    // IDBFactory
    function SqlLoader: TSQLLoader;
    function GetPool: IDBConnectionPool;
    function CreateConnection: IDBConnection;
    function CreateTransaction(AConn: IDBConnection): ITransaction;
    function CreateScopeTransaction(ATransaction: ITransaction): IScopeTransaction;
    function CreateQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function CreateSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
    function TestConnection(AConn: IDBConnection): Boolean;
  end;

implementation

{ ---- helpers ---- }

function NormKey(const AName: string): string;
begin
  Result := AnsiUpperCase(AName);
end;

{ TMockExecution }

constructor TMockExecution.Create(const AKey: string;
  ASnapshot: TDictionary<string, Variant>; AWasOpen: Boolean);
begin
  FKey     := AKey;
  FWasOpen := AWasOpen;
  FParams  := ASnapshot;
end;

destructor TMockExecution.Destroy;
begin
  FParams.Free;
  inherited;
end;

function TMockExecution.GetVariant(const AName: string): Variant;
begin
  if not FParams.TryGetValue(NormKey(AName), Result) then
    Result := Unassigned;
end;

function TMockExecution.AsString(const AName: string): string;
var
  V: Variant;
begin
  V := GetVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := '' else Result := VarToStr(V);
end;

function TMockExecution.AsInteger(const AName: string): Integer;
var
  V: Variant;
begin
  V := GetVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := 0 else Result := V;
end;

function TMockExecution.AsInt64(const AName: string): Int64;
var
  V: Variant;
begin
  V := GetVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := 0 else Result := V;
end;

function TMockExecution.AsBoolean(const AName: string): Boolean;
var
  V: Variant;
begin
  V := GetVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := False else Result := V;
end;

function TMockExecution.AsCurrency(const AName: string): Currency;
var
  V: Variant;
begin
  V := GetVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := 0 else Result := V;
end;

function TMockExecution.AsDateTime(const AName: string): TDateTime;
var
  V: Variant;
begin
  V := GetVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := 0
  else Result := TDateTime(Double(V));
end;

function TMockExecution.HasParam(const AName: string): Boolean;
begin
  Result := FParams.ContainsKey(NormKey(AName));
end;

function TMockExecution.IsNull(const AName: string): Boolean;
var
  V: Variant;
begin
  V := GetVariant(AName);
  Result := VarIsNull(V);
end;

{ TMockQueryResult }

constructor TMockQueryResult.Create(const AColumns: TArray<string>;
  const ARows: TArray<TArray<Variant>>);
begin
  FColumns := AColumns;
  FRows    := ARows;
  FCursor  := 0;
end;

class function TMockQueryResult.Empty: IQueryResult;
begin
  Result := TMockQueryResult.Create([], []);
end;

class function TMockQueryResult.SingleRow(const AFields: array of string;
  const AValues: array of Variant): IQueryResult;
var
  LCols: TArray<string>;
  LRow:  TArray<Variant>;
  LRows: TArray<TArray<Variant>>;
  I: Integer;
begin
  SetLength(LCols, Length(AFields));
  for I := 0 to High(AFields) do LCols[I] := AFields[I];
  SetLength(LRow, Length(AValues));
  for I := 0 to High(AValues) do LRow[I] := AValues[I];
  SetLength(LRows, 1);
  LRows[0] := LRow;
  Result := TMockQueryResult.Create(LCols, LRows);
end;

class function TMockQueryResult.MultiRows(const AFields: array of string;
  const AData: array of TArray<Variant>): IQueryResult;
var
  LCols: TArray<string>;
  LRows: TArray<TArray<Variant>>;
  I: Integer;
begin
  SetLength(LCols, Length(AFields));
  for I := 0 to High(AFields) do LCols[I] := AFields[I];
  SetLength(LRows, Length(AData));
  for I := 0 to High(AData) do LRows[I] := AData[I];
  Result := TMockQueryResult.Create(LCols, LRows);
end;

function TMockQueryResult.ColIndex(const AName: string): Integer;
var
  I: Integer;
  LUpper: string;
begin
  LUpper := AnsiUpperCase(AName);
  for I := 0 to High(FColumns) do
    if AnsiUpperCase(FColumns[I]) = LUpper then
      Exit(I);
  raise Exception.CreateFmt('TMockQueryResult: column "%s" not found', [AName]);
end;

function TMockQueryResult.CurrentVariant(const AName: string): Variant;
begin
  if (FCursor < 0) or (FCursor >= Length(FRows)) then
    raise Exception.Create('TMockQueryResult: cursor fora dos limites');
  Result := FRows[FCursor][ColIndex(AName)];
end;

function TMockQueryResult.GetAsString(const AName: string): string;
var V: Variant;
begin
  V := CurrentVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := '' else Result := VarToStr(V);
end;

function TMockQueryResult.GetAsInteger(const AName: string): Integer;
begin
  Result := CurrentVariant(AName);
end;

function TMockQueryResult.GetAsInt64(const AName: string): Int64;
begin
  Result := CurrentVariant(AName);
end;

function TMockQueryResult.GetAsBoolean(const AName: string): Boolean;
begin
  Result := CurrentVariant(AName);
end;

function TMockQueryResult.GetAsCurrency(const AName: string): Currency;
begin
  Result := CurrentVariant(AName);
end;

function TMockQueryResult.GetAsDateTime(const AName: string): TDateTime;
begin
  Result := TDateTime(Double(CurrentVariant(AName)));
end;

function TMockQueryResult.GetNullableString(const AName: string): INullString;
var V: Variant;
begin
  V := CurrentVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullString.Null
  else Result := TOptNullString.From(VarToStr(V));
end;

function TMockQueryResult.GetNullableInteger(const AName: string): INullInteger;
var V: Variant;
begin
  V := CurrentVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullInteger.Null
  else Result := TOptNullInteger.From(Integer(V));
end;

function TMockQueryResult.GetNullableInt64(const AName: string): INullInt64;
var V: Variant;
begin
  V := CurrentVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullInt64.Null
  else Result := TOptNullInt64.From(Int64(V));
end;

function TMockQueryResult.GetNullableBoolean(const AName: string): INullBoolean;
var V: Variant;
begin
  V := CurrentVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullBoolean.Null
  else Result := TOptNullBoolean.From(Boolean(V)) as INullBoolean;
end;

function TMockQueryResult.GetNullableDateTime(const AName: string): INullDateTime;
var V: Variant;
begin
  V := CurrentVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullDateTime.Null
  else Result := TOptNullDateTime.From(TDateTime(Double(V)));
end;

function TMockQueryResult.GetNullableCurrency(const AName: string): INullCurrency;
var V: Variant; LVal: Currency;
begin
  V := CurrentVariant(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullCurrency.Null
  else begin LVal := V; Result := TOptNullCurrency.From(LVal); end;
end;

function TMockQueryResult.IsEmpty: Boolean;
begin
  Result := Length(FRows) = 0;
end;

function TMockQueryResult.Eof: Boolean;
begin
  Result := FCursor >= Length(FRows);
end;

procedure TMockQueryResult.Next;
begin
  Inc(FCursor);
end;

procedure TMockQueryResult.Rewind;
begin
  FCursor := 0;
end;

function TMockQueryResult.FieldCount: Integer;
begin
  Result := Length(FColumns);
end;

function TMockQueryResult.FieldValue(AIndex: Integer): Variant;
begin
  if (FCursor < 0) or (FCursor >= Length(FRows)) then
    raise Exception.Create('TMockQueryResult: cursor fora dos limites');
  Result := FRows[FCursor][AIndex];
end;

function TMockQueryResult.RecordCount: Integer;
begin
  Result := Length(FRows);
end;

{ TMockParams }

constructor TMockParams.Create;
begin
  FValues := TDictionary<string, Variant>.Create;
end;

destructor TMockParams.Destroy;
begin
  FValues.Free;
  inherited;
end;

function TMockParams.GetV(const AName: string): Variant;
begin
  if not FValues.TryGetValue(NormKey(AName), Result) then
    Result := Unassigned;
end;

procedure TMockParams.PutV(const AName: string; const AValue: Variant);
begin
  FValues.AddOrSetValue(NormKey(AName), AValue);
end;

procedure TMockParams.CopyTo(ADest: TDictionary<string, Variant>);
var
  LPair: TPair<string, Variant>;
begin
  for LPair in FValues do
    ADest.AddOrSetValue(LPair.Key, LPair.Value);
end;

{ TMockParams — plain getters }

function TMockParams.GetString(const AName: string): string;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := '' else Result := VarToStr(V);
end;

function TMockParams.GetBoolean(const AName: string): Boolean;
begin
  Result := Boolean(GetV(AName));
end;

function TMockParams.GetDateTime(const AName: string): TDateTime;
begin
  Result := TDateTime(Double(GetV(AName)));
end;

function TMockParams.GetInteger(const AName: string): Integer;
begin
  Result := Integer(GetV(AName));
end;

function TMockParams.GetInt64(const AName: string): Int64;
begin
  Result := Int64(GetV(AName));
end;

function TMockParams.GetDouble(const AName: string): Double;
begin
  Result := Double(GetV(AName));
end;

function TMockParams.GetCurrency(const AName: string): Currency;
var V: Variant;
begin
  V := GetV(AName); Result := V;
end;

{ TMockParams — Opt getters }

function TMockParams.GetOptString(const AName: string): IOptString;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullString.Undefined
  else if VarIsNull(V) then Result := TOptNullString.Null
  else Result := TOptNullString.From(VarToStr(V));
end;

function TMockParams.GetOptInteger(const AName: string): IOptInteger;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullInteger.Undefined
  else if VarIsNull(V) then Result := TOptNullInteger.Null
  else Result := TOptNullInteger.From(Integer(V));
end;

function TMockParams.GetOptInt64(const AName: string): IOptInt64;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullInt64.Undefined
  else if VarIsNull(V) then Result := TOptNullInt64.Null
  else Result := TOptNullInt64.From(Int64(V));
end;

function TMockParams.GetOptBoolean(const AName: string): IOptBoolean;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullBoolean.Undefined
  else if VarIsNull(V) then Result := TOptNullBoolean.Null
  else Result := TOptNullBoolean.From(Boolean(V)) as IOptBoolean;
end;

function TMockParams.GetOptDouble(const AName: string): IOptDouble;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullDouble.Undefined
  else if VarIsNull(V) then Result := TOptNullDouble.Null
  else Result := TOptNullDouble.From(Double(V));
end;

function TMockParams.GetOptCurrency(const AName: string): IOptCurrency;
var V: Variant; LVal: Currency;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullCurrency.Undefined
  else if VarIsNull(V) then Result := TOptNullCurrency.Null
  else begin LVal := V; Result := TOptNullCurrency.From(LVal); end;
end;

function TMockParams.GetOptDateTime(const AName: string): IOptDateTime;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullDateTime.Undefined
  else if VarIsNull(V) then Result := TOptNullDateTime.Null
  else Result := TOptNullDateTime.From(TDateTime(Double(V)));
end;

{ TMockParams — Null getters }

function TMockParams.GetNullString(const AName: string): INullString;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullString.Null
  else Result := TOptNullString.From(VarToStr(V));
end;

function TMockParams.GetNullInteger(const AName: string): INullInteger;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullInteger.Null
  else Result := TOptNullInteger.From(Integer(V));
end;

function TMockParams.GetNullInt64(const AName: string): INullInt64;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullInt64.Null
  else Result := TOptNullInt64.From(Int64(V));
end;

function TMockParams.GetNullBoolean(const AName: string): INullBoolean;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullBoolean.Null
  else Result := TOptNullBoolean.From(Boolean(V)) as INullBoolean;
end;

function TMockParams.GetNullDouble(const AName: string): INullDouble;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullDouble.Null
  else Result := TOptNullDouble.From(Double(V));
end;

function TMockParams.GetNullCurrency(const AName: string): INullCurrency;
var V: Variant; LVal: Currency;
begin
  V := GetV(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullCurrency.Null
  else begin LVal := V; Result := TOptNullCurrency.From(LVal); end;
end;

function TMockParams.GetNullDateTime(const AName: string): INullDateTime;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsNull(V) or VarIsEmpty(V) then Result := TOptNullDateTime.Null
  else Result := TOptNullDateTime.From(TDateTime(Double(V)));
end;

{ TMockParams — OptNull getters }

function TMockParams.GetOptNullString(const AName: string): IOptNullString;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullString.Undefined
  else if VarIsNull(V) then Result := TOptNullString.Null
  else Result := TOptNullString.From(VarToStr(V));
end;

function TMockParams.GetOptNullInteger(const AName: string): IOptNullInteger;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullInteger.Undefined
  else if VarIsNull(V) then Result := TOptNullInteger.Null
  else Result := TOptNullInteger.From(Integer(V));
end;

function TMockParams.GetOptNullInt64(const AName: string): IOptNullInt64;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullInt64.Undefined
  else if VarIsNull(V) then Result := TOptNullInt64.Null
  else Result := TOptNullInt64.From(Int64(V));
end;

function TMockParams.GetOptNullBoolean(const AName: string): IOptNullBoolean;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullBoolean.Undefined
  else if VarIsNull(V) then Result := TOptNullBoolean.Null
  else Result := TOptNullBoolean.From(Boolean(V)) as IOptNullBoolean;
end;

function TMockParams.GetOptNullDouble(const AName: string): IOptNullDouble;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullDouble.Undefined
  else if VarIsNull(V) then Result := TOptNullDouble.Null
  else Result := TOptNullDouble.From(Double(V));
end;

function TMockParams.GetOptNullCurrency(const AName: string): IOptNullCurrency;
var V: Variant; LVal: Currency;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullCurrency.Undefined
  else if VarIsNull(V) then Result := TOptNullCurrency.Null
  else begin LVal := V; Result := TOptNullCurrency.From(LVal); end;
end;

function TMockParams.GetOptNullDateTime(const AName: string): IOptNullDateTime;
var V: Variant;
begin
  V := GetV(AName);
  if VarIsEmpty(V) then Result := TOptNullDateTime.Undefined
  else if VarIsNull(V) then Result := TOptNullDateTime.Null
  else Result := TOptNullDateTime.From(TDateTime(Double(V)));
end;

{ TMockParams — plain setters }

procedure TMockParams.SetString(const AName: string; AValue: string);    begin PutV(AName, AValue);           end;
procedure TMockParams.SetBoolean(const AName: string; AValue: Boolean);  begin PutV(AName, AValue);           end;
procedure TMockParams.SetInteger(const AName: string; AValue: Integer);  begin PutV(AName, AValue);           end;
procedure TMockParams.SetInt64(const AName: string; AValue: Int64);      begin PutV(AName, AValue);           end;
procedure TMockParams.SetDouble(const AName: string; AValue: Double);    begin PutV(AName, AValue);           end;
procedure TMockParams.SetDateTime(const AName: string; AValue: TDateTime);
begin PutV(AName, Double(AValue)); end;

procedure TMockParams.SetCurrency(const AName: string; AValue: Currency);
var V: Variant;
begin
  V := AValue; PutV(AName, V);
end;

{ TMockParams — Opt setters (undefined = not stored) }

procedure TMockParams.SetOptString(const AName: string; AValue: IOptString);
begin
  if Assigned(AValue) and AValue.HasValue then PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptInteger(const AName: string; AValue: IOptInteger);
begin
  if Assigned(AValue) and AValue.HasValue then PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptInt64(const AName: string; AValue: IOptInt64);
begin
  if Assigned(AValue) and AValue.HasValue then PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptBoolean(const AName: string; AValue: IOptBoolean);
begin
  if Assigned(AValue) and AValue.HasValue then PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptDouble(const AName: string; AValue: IOptDouble);
begin
  if Assigned(AValue) and AValue.HasValue then PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptCurrency(const AName: string; AValue: IOptCurrency);
var V: Variant;
begin
  if Assigned(AValue) and AValue.HasValue then begin V := AValue.Value; PutV(AName, V); end;
end;

procedure TMockParams.SetOptDateTime(const AName: string; AValue: IOptDateTime);
begin
  if Assigned(AValue) and AValue.HasValue then PutV(AName, Double(AValue.Value));
end;

{ TMockParams — Null setters }

procedure TMockParams.SetNullString(const AName: string; AValue: INullString);
begin
  if not Assigned(AValue) or AValue.IsNull then PutV(AName, Null)
  else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetNullInteger(const AName: string; AValue: INullInteger);
begin
  if not Assigned(AValue) or AValue.IsNull then PutV(AName, Null)
  else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetNullInt64(const AName: string; AValue: INullInt64);
begin
  if not Assigned(AValue) or AValue.IsNull then PutV(AName, Null)
  else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetNullBoolean(const AName: string; AValue: INullBoolean);
begin
  if not Assigned(AValue) or AValue.IsNull then PutV(AName, Null)
  else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetNullDouble(const AName: string; AValue: INullDouble);
begin
  if not Assigned(AValue) or AValue.IsNull then PutV(AName, Null)
  else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetNullCurrency(const AName: string; AValue: INullCurrency);
var V: Variant;
begin
  if not Assigned(AValue) or AValue.IsNull then PutV(AName, Null)
  else begin V := AValue.Value; PutV(AName, V); end;
end;

procedure TMockParams.SetNullDateTime(const AName: string; AValue: INullDateTime);
begin
  if not Assigned(AValue) or AValue.IsNull then PutV(AName, Null)
  else PutV(AName, Double(AValue.Value));
end;

{ TMockParams — OptNull setters }

procedure TMockParams.SetOptNullString(const AName: string; AValue: IOptNullString);
begin
  if not Assigned(AValue) or not AValue.HasValue then Exit;
  if AValue.IsNull then PutV(AName, Null) else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptNullInteger(const AName: string; AValue: IOptNullInteger);
begin
  if not Assigned(AValue) or not AValue.HasValue then Exit;
  if AValue.IsNull then PutV(AName, Null) else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptNullInt64(const AName: string; AValue: IOptNullInt64);
begin
  if not Assigned(AValue) or not AValue.HasValue then Exit;
  if AValue.IsNull then PutV(AName, Null) else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptNullBoolean(const AName: string; AValue: IOptNullBoolean);
begin
  if not Assigned(AValue) or not AValue.HasValue then Exit;
  if AValue.IsNull then PutV(AName, Null) else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptNullDouble(const AName: string; AValue: IOptNullDouble);
begin
  if not Assigned(AValue) or not AValue.HasValue then Exit;
  if AValue.IsNull then PutV(AName, Null) else PutV(AName, AValue.Value);
end;

procedure TMockParams.SetOptNullCurrency(const AName: string; AValue: IOptNullCurrency);
var V: Variant;
begin
  if not Assigned(AValue) or not AValue.HasValue then Exit;
  if AValue.IsNull then PutV(AName, Null) else begin V := AValue.Value; PutV(AName, V); end;
end;

procedure TMockParams.SetOptNullDateTime(const AName: string; AValue: IOptNullDateTime);
begin
  if not Assigned(AValue) or not AValue.HasValue then Exit;
  if AValue.IsNull then PutV(AName, Null) else PutV(AName, Double(AValue.Value));
end;

{ TMockQuery }

constructor TMockQuery.Create(AOwner: TMockDBFactory);
begin
  FOwner  := AOwner;
  FParams := TMockParams.Create;
  FSql    := '';
end;

function TMockQuery.GetParams: IParams;  begin Result := FParams; end;
procedure TMockQuery.SetSql(const ASql: string); begin FSql := ASql; end;
function TMockQuery.GetSql: string;      begin Result := FSql; end;
procedure TMockQuery.Close;              begin end;
function TMockQuery.GetConnection: IDBConnection; begin Result := nil; end;
function TMockQuery.GetTransaction: ITransaction; begin Result := nil; end;

function TMockQuery.Open: IQueryResult;
var
  LRewindable: IMockRewindable;
begin
  FOwner.RecordExecution(FSql, FParams as TMockParams, True);
  FOwner.RaisePendingFailure(FSql);
  Result := FOwner.GetResult(FSql);
  if not Assigned(Result) then
    raise Exception.CreateFmt(
      'TMockDBFactory: no result configured for "%s". ' +
      'Call AddResult(''%s'', ...) before exercising the repository.',
      [FSql, FSql]);
  // The same registered result serves every Open of the key: start it over.
  if Supports(Result, IMockRewindable, LRewindable) then
    LRewindable.Rewind;
end;

procedure TMockQuery.ExecSql;
begin
  FOwner.RecordExecution(FSql, FParams as TMockParams, False);
  FOwner.RaisePendingFailure(FSql);
end;

{ TMockScopeTransaction }

constructor TMockScopeTransaction.Create;
begin
  FTransaction := TMockTransaction.Create;
end;

procedure TMockScopeTransaction.StartTransaction; begin end;
procedure TMockScopeTransaction.Commit;           begin end;
procedure TMockScopeTransaction.Rollback;         begin end;

function TMockScopeTransaction.InTransaction: Boolean; begin Result := False; end;
function TMockScopeTransaction.IsMain: Boolean;        begin Result := True;  end;

function TMockScopeTransaction.GetOriginalTransaction: ITransaction;
begin
  Result := FTransaction;
end;

{ TMockConnectionPool }

constructor TMockConnectionPool.Create(AOwner: TMockDBFactory);
begin
  FOwner := AOwner;
end;

function TMockConnectionPool.AcquireConnection: IDBConnection;
begin
  Result := TMockDBConnection.Create;
end;

function TMockConnectionPool.AcquireQuery(out AQuery: IQuery;
  ATransaction: ITransaction): IScopeTransaction;
begin
  AQuery := TMockQuery.Create(FOwner);
  Result := TMockScopeTransaction.Create;
end;

function TMockConnectionPool.GetActiveConnections: Integer; begin Result := 0; end;
function TMockConnectionPool.GetPoolSize: Integer;          begin Result := 0; end;
function TMockConnectionPool.GetWaitMaxAttemps: Integer;    begin Result := 0; end;
function TMockConnectionPool.GetWaitMilliseconds: Integer;  begin Result := 0; end;
function TMockConnectionPool.GetSnapshot: TPoolSnapshot;    begin Result := Default(TPoolSnapshot); end;

{ TMockSQLDialect }

function TMockSQLDialect.GetSavepointSQL(const AName: string): string;           begin Result := ''; end;
function TMockSQLDialect.GetRollbackToSavepointSQL(const AName: string): string; begin Result := ''; end;
function TMockSQLDialect.GetReleaseSavepointSQL(const AName: string): string;    begin Result := ''; end;
function TMockSQLDialect.SupportsRelease: Boolean;                               begin Result := False; end;
function TMockSQLDialect.GetPingSQL: string;                                     begin Result := 'SELECT 1'; end;

function TMockSQLDialect.GetPagingClause(ALimit: Integer; AOffset: Int64): string;
begin
  Result := Format('LIMIT %d OFFSET %d', [ALimit, AOffset]);
end;

{ TMockDBConnection }

procedure TMockDBConnection.Connect;                       begin end;
procedure TMockDBConnection.Commit;                        begin end;
procedure TMockDBConnection.Rollback;                      begin end;
procedure TMockDBConnection.Disconnect(Force: Boolean);    begin end;
function TMockDBConnection.GetNativeConnection: TObject;   begin Result := nil;  end;
function TMockDBConnection.GetSQLDialect: ISQLDialect;     begin Result := TMockSQLDialect.Create; end;
function TMockDBConnection.IsConnected: Boolean;           begin Result := True; end;

{ TMockTransaction }

procedure TMockTransaction.StartTransaction;               begin end;
procedure TMockTransaction.Commit;                         begin end;
procedure TMockTransaction.Rollback;                       begin end;
procedure TMockTransaction.ExecSql(const ASql: string);    begin end;
function TMockTransaction.InTransaction: Boolean;          begin Result := False; end;
function TMockTransaction.GetConnection: IDBConnection;    begin Result := TMockDBConnection.Create; end;
function TMockTransaction.GetNativeTransaction: TObject;   begin Result := nil;   end;

{ TMockSQLLoader }

constructor TMockSQLLoader.Create;
begin
  inherited Create('');
end;

function TMockSQLLoader.GetSql(const AResourceName: string): TSQLResult;
begin
  Result := TSQLResult.From(AResourceName);
end;

{ TMockDBFactory }

constructor TMockDBFactory.Create;
begin
  FPool       := TMockConnectionPool.Create(Self);
  FSqlLoader  := TMockSQLLoader.Create;
  FResults    := TDictionary<string, IQueryResult>.Create;
  FExecutions := TObjectList<TMockExecution>.Create(True);
  FFailures   := TList<TMockFailure>.Create;
end;

destructor TMockDBFactory.Destroy;
begin
  FSqlLoader.Free;
  FResults.Free;
  FExecutions.Free;
  FFailures.Free;
  inherited;
end;

procedure TMockDBFactory.AddResult(const ASqlKey: string; AResult: IQueryResult);
begin
  FResults.AddOrSetValue(AnsiUpperCase(ASqlKey), AResult);
end;

procedure TMockDBFactory.AddFailure(const ASqlKey: string; AExceptionClass: ExceptClass;
  const AMessage: string);
var
  LFailure: TMockFailure;
begin
  LFailure.Key := ASqlKey;
  LFailure.ExceptionClass := AExceptionClass;
  LFailure.Message := AMessage;
  FFailures.Add(LFailure);
end;

procedure TMockDBFactory.RaisePendingFailure(const ASqlKey: string);
var
  I: Integer;
  LFailure: TMockFailure;
begin
  for I := 0 to FFailures.Count - 1 do
    if SameText(FFailures[I].Key, ASqlKey) then
    begin
      LFailure := FFailures[I];
      FFailures.Delete(I);
      raise LFailure.ExceptionClass.Create(LFailure.Message);
    end;
end;

function TMockDBFactory.GetResult(const ASqlKey: string): IQueryResult;
begin
  if not FResults.TryGetValue(AnsiUpperCase(ASqlKey), Result) then
    Result := nil;
end;

procedure TMockDBFactory.RecordExecution(const ASqlKey: string;
  AParams: TMockParams; AWasOpen: Boolean);
var
  LSnapshot: TDictionary<string, Variant>;
begin
  LSnapshot := TDictionary<string, Variant>.Create;
  AParams.CopyTo(LSnapshot);
  FExecutions.Add(TMockExecution.Create(ASqlKey, LSnapshot, AWasOpen));
end;

function TMockDBFactory.LastExecution(const ASqlKey: string): TMockExecution;
var
  I: Integer;
begin
  Result := nil;
  for I := FExecutions.Count - 1 downto 0 do
    if SameText(FExecutions[I].Key, ASqlKey) then
    begin
      Result := FExecutions[I];
      Break;
    end;
end;

function TMockDBFactory.ExecutionCount(const ASqlKey: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FExecutions.Count - 1 do
    if SameText(FExecutions[I].Key, ASqlKey) then
      Inc(Result);
end;

function TMockDBFactory.SqlLoader: TSQLLoader;
begin
  Result := FSqlLoader;
end;

function TMockDBFactory.GetPool: IDBConnectionPool;
begin
  Result := FPool;
end;

function TMockDBFactory.CreateConnection: IDBConnection;
begin
  Result := TMockDBConnection.Create;
end;

function TMockDBFactory.CreateTransaction(AConn: IDBConnection): ITransaction;
begin
  Result := TMockTransaction.Create;
end;

function TMockDBFactory.CreateScopeTransaction(ATransaction: ITransaction): IScopeTransaction;
begin
  Result := TMockScopeTransaction.Create;
end;

function TMockDBFactory.CreateQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
begin
  Result := TMockQuery.Create(Self);
end;

function TMockDBFactory.CreateSqlScript(AConn: IDBConnection;
  ATransaction: ITransaction): ISqlScript;
begin
  Result := nil; // never reached; keeps FPC from warning that the result isn't set
  raise Exception.Create('PascalDb.Mock: ISqlScript is not supported by TMockDBFactory');
end;

function TMockDBFactory.TestConnection(AConn: IDBConnection): Boolean;
begin
  Result := True;
end;

end.
