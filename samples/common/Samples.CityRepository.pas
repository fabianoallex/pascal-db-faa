unit Samples.CityRepository;

{ The repository the samples share: cities stored in a SAMPLE_CITIES table.

  It only knows IDBFactory, so the same class runs against the in-memory mock
  (sample 01, no database) and against a real adapter (sample 02). SQL comes
  from the factory's SQL loader by key (CITY.INSERT, CITY.BY_STATE, ...):
  with a real factory the key names a script in the configured SQL source;
  with TMockDBFactory the key itself is the SQL text, which is what the mock
  matches its canned results and recorded executions against.

  FindByStatePaged shows offset paging (PascalDb.Paging): a COUNT with the
  same filter, then the page query with the clause the connection's dialect
  writes into its PAGE literal. With the mock, the clause never reaches
  the key, so a test registers the rows of the page it checks.

  Every method follows the library's usage pattern: acquire a query from the
  pool together with its scope transaction, start the transaction, commit on
  success and roll back on any exception. The query and its connection go
  back to the pool when the interface variables leave scope. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.Paging;

type
  TCity = record
    Code: string;   // IBGE code, e.g. '3550308'
    Name: string;
    State: string;  // two-letter abbreviation, e.g. 'SP'
  end;

  ECityValidation = class(Exception);

  TCityRepository = class
  private
    FFactory: IDBFactory;
    class function Normalized(const ACity: TCity): TCity; static;
    class function ReadCities(const AResult: IQueryResult): TArray<TCity>; static;
  public
    constructor Create(const AFactory: IDBFactory);
    /// Validates and inserts one city (State is trimmed and upper-cased).
    procedure Insert(const ACity: TCity);
    /// Inserts every city in a single transaction: all of them or none.
    procedure InsertAll(const ACities: array of TCity);
    /// Cities of AState, ordered by name.
    function FindByState(const AState: string): TArray<TCity>;
    /// One page of the cities of AState, ordered by name, with the total.
    function FindByStatePaged(const AState: string; const APage: TPageRequest): TPage<TCity>;
    function Count: Integer;
  end;

function City(const ACode, AName, AState: string): TCity;

implementation

function City(const ACode, AName, AState: string): TCity;
begin
  Result.Code := ACode;
  Result.Name := AName;
  Result.State := AState;
end;

{ TCityRepository }

constructor TCityRepository.Create(const AFactory: IDBFactory);
begin
  inherited Create;
  FFactory := AFactory;
end;

class function TCityRepository.Normalized(const ACity: TCity): TCity;
begin
  Result.Code := Trim(ACity.Code);
  Result.Name := Trim(ACity.Name);
  Result.State := UpperCase(Trim(ACity.State));
  if Result.Code = '' then
    raise ECityValidation.Create('City code is required');
  if Result.Name = '' then
    raise ECityValidation.Create('City name is required');
  if Length(Result.State) <> 2 then
    raise ECityValidation.CreateFmt('State must have two letters, not "%s"', [ACity.State]);
end;

procedure TCityRepository.Insert(const ACity: TCity);
begin
  InsertAll([ACity]);
end;

procedure TCityRepository.InsertAll(const ACities: array of TCity);
var
  LCities: TArray<TCity>;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  I: Integer;
begin
  // Validate everything before touching the database.
  SetLength(LCities, Length(ACities));
  for I := 0 to High(ACities) do
    LCities[I] := Normalized(ACities[I]);

  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    for I := 0 to High(LCities) do
    begin
      LQuery.Sql := FFactory.SqlLoader['CITY.INSERT'].SQL;
      LQuery.Params.Strings['CODE'] := LCities[I].Code;
      LQuery.Params.Strings['NAME'] := LCities[I].Name;
      LQuery.Params.Strings['STATE'] := LCities[I].State;
      LQuery.ExecSql;
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

class function TCityRepository.ReadCities(const AResult: IQueryResult): TArray<TCity>;
var
  LCount: Integer;
begin
  SetLength(Result, AResult.RecordCount);
  LCount := 0;
  while not AResult.Eof do
  begin
    Result[LCount] := City(AResult.Strings['CODE'], AResult.Strings['NAME'],
      AResult.Strings['STATE']);
    Inc(LCount);
    AResult.Next;
  end;
  SetLength(Result, LCount);
end;

function TCityRepository.FindByState(const AState: string): TArray<TCity>;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.BY_STATE'].SQL;
    LQuery.Params.Strings['STATE'] := UpperCase(Trim(AState));
    Result := ReadCities(LQuery.Open);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

function TCityRepository.FindByStatePaged(const AState: string;
  const APage: TPageRequest): TPage<TCity>;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LState: string;
begin
  LState := UpperCase(Trim(AState));
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    // The total, with the same filter; in the same transaction as the page.
    LQuery.Sql := FFactory.SqlLoader['CITY.COUNT_BY_STATE'].SQL;
    LQuery.Params.Strings['STATE'] := LState;
    Result.Meta := TPageMeta.Create(APage, LQuery.Open.Int64s['TOTAL']);

    // The page: LIMIT/OFFSET, ROWS or OFFSET/FETCH, as the database needs.
    LQuery.Sql := FFactory.SqlLoader['CITY.BY_STATE_PAGED']
      .ReplaceLiteral('PAGE', PdbPagingClause(LScope, APage)).SQL;
    LQuery.Params.Strings['STATE'] := LState;
    Result.Items := ReadCities(LQuery.Open);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

function TCityRepository.Count: Integer;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.COUNT'].SQL;
    Result := LQuery.Open.Integers['TOTAL'];
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

end.
