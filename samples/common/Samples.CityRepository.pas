unit Samples.CityRepository;

{ The repository the samples share: cities stored in a SAMPLE_CITIES table.

  It only knows IDBFactory, so the same class runs against the in-memory mock
  (sample 01, no database) and against a real adapter (sample 02). SQL comes
  from the factory's SQL loader by key (CITY.INSERT, CITY.BY_STATE, ...):
  with a real factory the key names a script in the configured SQL source;
  with TMockDBFactory the key itself is the SQL text, which is what the mock
  matches its canned results and recorded executions against.

  Every method follows the library's usage pattern: acquire a query from the
  pool together with its scope transaction, start the transaction, commit on
  success and roll back on any exception. The query and its connection go
  back to the pool when the interface variables leave scope. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils,
  PascalDb.Interfaces;

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
  public
    constructor Create(const AFactory: IDBFactory);
    /// Validates and inserts one city (State is trimmed and upper-cased).
    procedure Insert(const ACity: TCity);
    /// Inserts every city in a single transaction: all of them or none.
    procedure InsertAll(const ACities: array of TCity);
    /// Cities of AState, ordered by name.
    function FindByState(const AState: string): TArray<TCity>;
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

function TCityRepository.FindByState(const AState: string): TArray<TCity>;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LCount: Integer;
begin
  Result := nil;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.BY_STATE'].SQL;
    LQuery.Params.Strings['STATE'] := UpperCase(Trim(AState));
    LResult := LQuery.Open;
    SetLength(Result, LResult.RecordCount);
    LCount := 0;
    while not LResult.Eof do
    begin
      Result[LCount] := City(LResult.Strings['CODE'], LResult.Strings['NAME'],
        LResult.Strings['STATE']);
      Inc(LCount);
      LResult.Next;
    end;
    SetLength(Result, LCount);
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
