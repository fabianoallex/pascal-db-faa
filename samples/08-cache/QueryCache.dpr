program QueryCache;

{ Sample 08: a cache in front of a query, invalidated after the commit.

  The cache is pascal-common-faa's PascalCommon.Cache (TPcCache over a
  TPcMemoryCacheStore here; pascal-redis-faa's TRedisCacheStore shares it
  between instances). It sits in the service, in front of the repository: a
  hit takes nothing from the pool and runs nothing on the database. The
  value is the result already mapped, as a string (a real program would
  write its DTO as JSON).

  Steps: read a state's cities twice (the first read runs the query, the
  second is a hit); rename a city in a repository whose scope is nested in
  the caller's transaction, and read again before the caller commits (still
  the cached value: the repository's Commit only released a savepoint, and
  PdbInvalidateAfterCommit waits for the real commit); commit and read (the
  query runs, with the new name); rename again and roll back (the entry
  stays, nothing was invalidated).

  Reads for the cache run in a scope of their own, never in a transaction
  that wrote: that one could still roll back (docs/cache.md).

  Runs against a local PostgreSQL by default; other targets: the
  environment variables in Samples.Env. Same source for Delphi
  (QueryCache.dproj, FireDAC) and Lazarus/FPC (QueryCache.lpi, SQLdb). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring, // FPC on Unix: needed for non-ASCII text in Variants (see CLAUDE.md)
  {$ENDIF}
  SysUtils,
  PascalCommon.Cache,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Cache,
  Samples.Env;

type
  { TCityRepository
    The database side. Rename takes the caller's transaction, as a
    repository called from a use case does: its scope is then nested. }
  TCityRepository = class
  private
    FFactory: IDBFactory;
    FCache: IPcCache;
  public
    constructor Create(const AFactory: IDBFactory; const ACache: IPcCache);
    function NamesInState(const AState: string): string;
    procedure Rename(const ACode, AState, AName: string; const ATransaction: ITransaction);
  end;

  { TCityService
    The cache in front of the repository. LoadState is a method, not a
    closure, so it compiles on FPC 3.2.2 too. }
  TCityService = class
  private
    FRepository: TCityRepository;
    FCache: IPcCache;
    FQueries: Integer;
    function LoadState(const AState: string): string;
  public
    constructor Create(ARepository: TCityRepository; const ACache: IPcCache);
    function NamesInState(const AState: string): string;
    /// Queries run since the last call.
    function TakeQueries: Integer;
  end;

function BuildSqlSource: ISqlSource;
var
  LSource: TMemorySqlSource;
  LDir: string;
begin
  LSource := TMemorySqlSource.Create;
  Result := LSource;
  LSource.Add(SQL_DIR_POSTGRESQL, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_CACHED_CITIES ' +
    '(CODE VARCHAR(7) NOT NULL PRIMARY KEY, NAME VARCHAR(100) NOT NULL, STATE VARCHAR(2) NOT NULL)');
  LSource.Add(SQL_DIR_SQLITE, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_CACHED_CITIES ' +
    '(CODE VARCHAR(7) NOT NULL PRIMARY KEY, NAME VARCHAR(100) NOT NULL, STATE VARCHAR(2) NOT NULL)');
  LSource.Add(SQL_DIR_MYSQL, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_CACHED_CITIES ' +
    '(CODE VARCHAR(7) NOT NULL PRIMARY KEY, NAME VARCHAR(100) NOT NULL, STATE VARCHAR(2) NOT NULL) ' +
    'DEFAULT CHARSET=utf8mb4');
  LSource.Add(SQL_DIR_MSSQL, 'SCHEMA.CREATE',
    'IF OBJECT_ID(''SAMPLE_CACHED_CITIES'', ''U'') IS NULL CREATE TABLE SAMPLE_CACHED_CITIES ' +
    '(CODE NVARCHAR(7) NOT NULL PRIMARY KEY, NAME NVARCHAR(100) NOT NULL, STATE NVARCHAR(2) NOT NULL)');
  LSource.Add(SQL_DIR_FIREBIRD, 'SCHEMA.CREATE',
    'RECREATE TABLE SAMPLE_CACHED_CITIES (CODE VARCHAR(7) NOT NULL PRIMARY KEY, ' +
    'NAME VARCHAR(100) CHARACTER SET UTF8 NOT NULL, STATE VARCHAR(2) NOT NULL)');
  for LDir in TArray<string>.Create(SQL_DIR_POSTGRESQL, SQL_DIR_FIREBIRD, SQL_DIR_SQLITE, SQL_DIR_MYSQL,
    SQL_DIR_MSSQL) do
    LSource
      .Add(LDir, 'CITY.DELETE_ALL', 'DELETE FROM SAMPLE_CACHED_CITIES')
      .Add(LDir, 'CITY.INSERT',
        'INSERT INTO SAMPLE_CACHED_CITIES (CODE, NAME, STATE) VALUES (:CODE, :NAME, :STATE)')
      .Add(LDir, 'CITY.NAMES_BY_STATE',
        'SELECT NAME FROM SAMPLE_CACHED_CITIES WHERE STATE = :STATE ORDER BY NAME')
      .Add(LDir, 'CITY.RENAME', 'UPDATE SAMPLE_CACHED_CITIES SET NAME = :NAME WHERE CODE = :CODE');
end;

procedure RunScript(const AFactory: IDBFactory; const AKey: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader[AKey].SQL;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure InsertCities(const AFactory: IDBFactory);
const
  CITIES: array[0..2, 0..2] of string = (
    ('3509502', 'Campinas', 'SP'),
    ('3548500', 'Santos', 'SP'),
    ('3304557', 'Rio de Janeiro', 'RJ'));
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  I: Integer;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader['CITY.INSERT'].SQL;
    for I := Low(CITIES) to High(CITIES) do
    begin
      LQuery.Params.Strings['CODE'] := CITIES[I, 0];
      LQuery.Params.Strings['NAME'] := CITIES[I, 1];
      LQuery.Params.Strings['STATE'] := CITIES[I, 2];
      LQuery.ExecSql;
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

{ TCityRepository }

constructor TCityRepository.Create(const AFactory: IDBFactory; const ACache: IPcCache);
begin
  inherited Create;
  FFactory := AFactory;
  FCache := ACache;
end;

function TCityRepository.NamesInState(const AState: string): string;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := '';
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.NAMES_BY_STATE'].SQL;
    LQuery.Params.Strings['STATE'] := AState;
    LResult := LQuery.Open;
    while not LResult.Eof do
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + LResult.Strings['NAME'];
      LResult.Next;
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TCityRepository.Rename(const ACode, AState, AName: string;
  const ATransaction: ITransaction);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery, ATransaction);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.RENAME'].SQL;
    LQuery.Params.Strings['CODE'] := ACode;
    LQuery.Params.Strings['NAME'] := AName;
    LQuery.ExecSql;
    // Waits for the real commit: with ATransaction running, the Commit
    // below only releases a savepoint.
    PdbInvalidateAfterCommit(LScope, FCache, ['city:' + ACode, 'cities.state:' + AState]);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

{ TCityService }

constructor TCityService.Create(ARepository: TCityRepository; const ACache: IPcCache);
begin
  inherited Create;
  FRepository := ARepository;
  FCache := ACache;
end;

function TCityService.LoadState(const AState: string): string;
begin
  Inc(FQueries);
  Result := FRepository.NamesInState(AState);
end;

function TCityService.NamesInState(const AState: string): string;
var
  LKey: string;
begin
  LKey := FCache.Key('cities.by_state:' + AState, ['cities', 'cities.state:' + AState]);
  Result := FCache.GetOrLoad(LKey, 300, LoadState, AState);
end;

function TCityService.TakeQueries: Integer;
begin
  Result := FQueries;
  FQueries := 0;
end;

procedure ShowState(AService: TCityService; const AWhen: string);
var
  LNames: string;
begin
  LNames := AService.NamesInState('SP');
  if AService.TakeQueries > 0 then
    Writeln('  ', AWhen, ': ', LNames, ' (query ran)')
  else
    Writeln('  ', AWhen, ': ', LNames, ' (cache hit)');
end;

procedure Run;
var
  LFactory: IDBFactory;
  LCache: IPcCache;
  LRepository: TCityRepository;
  LService: TCityService;
  LQuery: IQuery;
  LUseCase: IScopeTransaction;
begin
  Writeln('Target: ', SampleTarget);
  LFactory := NewSampleFactory(BuildSqlSource);
  CheckSampleConnection(LFactory);
  RunScript(LFactory, 'SCHEMA.CREATE');
  RunScript(LFactory, 'CITY.DELETE_ALL');
  InsertCities(LFactory);
  Writeln('Table SAMPLE_CACHED_CITIES ready with 3 cities.');

  LCache := TPcCache.Create(TPcMemoryCacheStore.Create(1000), 'sample-08');
  LRepository := TCityRepository.Create(LFactory, LCache);
  LService := TCityService.Create(LRepository, LCache);
  try
    Writeln('Cities in SP:');
    ShowState(LService, 'first read');
    ShowState(LService, 'second read');

    // A use case with its own transaction calls the repository, whose scope
    // is nested in it.
    LUseCase := LFactory.GetPool.AcquireQuery(LQuery);
    LUseCase.StartTransaction;
    try
      LRepository.Rename('3509502', 'SP', 'Campinas (renamed)', LUseCase.OriginalTransaction);
      ShowState(LService, 'renamed, not committed yet');
      LUseCase.Commit;
    except
      LUseCase.Rollback;
      raise;
    end;
    LQuery := nil;
    LUseCase := nil;
    ShowState(LService, 'after the commit');

    LUseCase := LFactory.GetPool.AcquireQuery(LQuery);
    LUseCase.StartTransaction;
    LRepository.Rename('3548500', 'SP', 'Santos (never)', LUseCase.OriginalTransaction);
    LUseCase.Rollback;
    LQuery := nil;
    LUseCase := nil;
    ShowState(LService, 'after a rolled back rename');
  finally
    LService.Free;
    LRepository.Free;
  end;
end;

begin
  {$IFDEF FPC}
  // Plain FPC console programs don't run in UTF-8 by default (see CLAUDE.md).
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ELSE}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  try
    Run;
  except
    on E: EDatabaseConnectException do
      ExitCode := 1;
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
