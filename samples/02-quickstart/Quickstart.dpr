program Quickstart;

{ Sample 02: the library against a real database, from configuration to
  transactions.

  Steps: build the factory (Samples.Env: adapter and connection settings),
  connect (saying which settings to check when that fails), create the
  table, then use the same TCityRepository
  that sample 01 tests against the mock: insert a batch, query it, watch
  a failing batch roll back as a whole, and read a state's cities a page at
  a time (the paging clause comes from the database's dialect, so the page
  query is the same text for every database).

  The SQL lives in a TMemorySqlSource to keep the sample in one file; each
  script is registered under the engine's SQL directory (PG, FB or SQLITE), so the
  one statement that differs between the databases (the CREATE TABLE) has
  one version per database under the same key. A real program
  would usually embed .sql files as resources instead (TResourceSqlSource,
  the default; see tools/build_sql_res.py).

  Error handling: creating the factory never fails because the server is
  down (the pool's initial connections are retried on the next acquire).
  Opening a new connection that fails (server down, wrong port, missing
  client library) raises EDatabaseConnectException from AcquireQuery. A
  connection that drops while in use raises EDatabaseUnavailableException
  (its parent class), and the pool discards that connection. Both have a
  Message safe to show to a user, with the driver's error kept in
  OriginalMessage. A constraint violation (a duplicate key, below) raises
  EConstraintViolationException, whose Kind says which constraint, whatever
  the driver. Any other exception (a SQL error) arrives as the driver
  raised it.

  Runs against a local PostgreSQL by default:
    docker run -d --name pascaldb-sample-pg -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:17
  Other targets: see the environment variables in Samples.Env.

  Same source for Delphi (Quickstart.dproj, FireDAC) and Lazarus/FPC
  (Quickstart.lpi, SQLdb). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring, // FPC on Unix: needed for non-ASCII text in Variants (see CLAUDE.md)
  {$ENDIF}
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Paging,
  Samples.Env,
  Samples.CityRepository;

function BuildSqlSource: ISqlSource;
const
  TABLE_COLUMNS = '(CODE VARCHAR(7) NOT NULL PRIMARY KEY, NAME VARCHAR(100)%s NOT NULL, STATE VARCHAR(2) NOT NULL)';
var
  LSource: TMemorySqlSource;
  LDir: string;
begin
  LSource := TMemorySqlSource.Create;
  Result := LSource;
  // PostgreSQL: the database encoding applies to every column. SQLite: text
  // is UTF-8. MySQL/MariaDB: the database's character set (utf8mb4 on
  // current servers).
  LSource.Add(SQL_DIR_POSTGRESQL, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_CITIES ' + Format(TABLE_COLUMNS, ['']));
  LSource.Add(SQL_DIR_SQLITE, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_CITIES ' + Format(TABLE_COLUMNS, ['']));
  // MySQL/MariaDB: utf8mb4 declared, since a server's default varies.
  LSource.Add(SQL_DIR_MYSQL, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_CITIES ' + Format(TABLE_COLUMNS, ['']) + ' DEFAULT CHARSET=utf8mb4');
  // SQL Server has no CREATE TABLE IF NOT EXISTS either, and needs NVARCHAR
  // for text outside its collation's code page (1252 by default).
  LSource.Add(SQL_DIR_MSSQL, 'SCHEMA.CREATE',
    'IF OBJECT_ID(''SAMPLE_CITIES'', ''U'') IS NULL CREATE TABLE SAMPLE_CITIES ' +
    '(CODE NVARCHAR(7) NOT NULL PRIMARY KEY, NAME NVARCHAR(100) NOT NULL, STATE NVARCHAR(2) NOT NULL)');
  // Firebird has no CREATE TABLE IF NOT EXISTS; RECREATE drops and creates.
  // Text columns declare UTF8 because a database's default character set
  // may be NONE.
  LSource.Add(SQL_DIR_FIREBIRD, 'SCHEMA.CREATE',
    'RECREATE TABLE SAMPLE_CITIES ' + Format(TABLE_COLUMNS, [' CHARACTER SET UTF8']));
  // The rest is standard SQL: the same text for all.
  for LDir in TArray<string>.Create(SQL_DIR_POSTGRESQL, SQL_DIR_FIREBIRD, SQL_DIR_SQLITE, SQL_DIR_MYSQL,
    SQL_DIR_MSSQL) do
    LSource
      .Add(LDir, 'CITY.DELETE_ALL', 'DELETE FROM SAMPLE_CITIES')
      .Add(LDir, 'CITY.INSERT', 'INSERT INTO SAMPLE_CITIES (CODE, NAME, STATE) VALUES (:CODE, :NAME, :STATE)')
      .Add(LDir, 'CITY.BY_STATE', 'SELECT CODE, NAME, STATE FROM SAMPLE_CITIES WHERE STATE = :STATE ORDER BY NAME')
      .Add(LDir, 'CITY.COUNT', 'SELECT COUNT(*) AS TOTAL FROM SAMPLE_CITIES')
      .Add(LDir, 'CITY.COUNT_BY_STATE', 'SELECT COUNT(*) AS TOTAL FROM SAMPLE_CITIES WHERE STATE = :STATE')
      // The key ends the ORDER BY so no two rows tie: a tie could put a row
      // on two pages, or on none.
      .Add(LDir, 'CITY.BY_STATE_PAGED',
        'SELECT CODE, NAME, STATE FROM SAMPLE_CITIES WHERE STATE = :STATE ORDER BY NAME, CODE ${PAGE}');
end;

// The basic pattern, with nothing around it: a query from the pool, its
// transaction, commit or roll back.
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

procedure PrintState(ARepo: TCityRepository; const AState: string);
var
  LCity: TCity;
begin
  Writeln('Cities in ', AState, ':');
  for LCity in ARepo.FindByState(AState) do
    Writeln('  ', LCity.Code, '  ', LCity.Name);
end;

procedure PrintStatePages(ARepo: TCityRepository; const AState: string; ALimit: Integer);
var
  LPage: TPage<TCity>;
  LNumber, I: Integer;
  LLine: string;
begin
  Writeln('Cities in ', AState, ', ', ALimit, ' per page:');
  LNumber := 1;
  repeat
    LPage := ARepo.FindByStatePaged(AState, TPageRequest.Create(LNumber, ALimit));
    LLine := '';
    for I := 0 to High(LPage.Items) do
    begin
      if I > 0 then
        LLine := LLine + ', ';
      LLine := LLine + LPage.Items[I].Name;
    end;
    Writeln('  page ', LPage.Meta.Page, ' of ', LPage.Meta.TotalPages, ': ', LLine);
    Inc(LNumber);
  until not LPage.Meta.HasNext;
  Writeln('  (', LPage.Meta.Total, ' cities)');
end;

procedure Run;
var
  LFactory: IDBFactory;
  LRepo: TCityRepository;
begin
  Writeln('Target: ', SampleTarget);
  LFactory := NewSampleFactory(BuildSqlSource);
  // Connect before any SQL; on failure, lists the settings to check.
  CheckSampleConnection(LFactory);
  Writeln('Connected.');

  // DDL runs in its own transaction: Firebird can't use a table in the
  // transaction that created it.
  RunScript(LFactory, 'SCHEMA.CREATE');
  RunScript(LFactory, 'CITY.DELETE_ALL');
  Writeln('Table SAMPLE_CITIES ready and empty.');
  Writeln;

  LRepo := TCityRepository.Create(LFactory);
  try
    LRepo.InsertAll([
      City('3550308', 'São Paulo', 'SP'),
      City('3509502', 'Campinas', 'sp'),
      City('3304557', 'Rio de Janeiro', 'RJ')]);
    Writeln('Inserted 3 cities in one transaction.');
    PrintState(LRepo, 'SP');
    Writeln;

    // The second city repeats a primary key: the database rejects it, and
    // the first one, already inserted in the same transaction, goes too.
    Writeln('Inserting Santos and a duplicate of São Paulo in one batch...');
    try
      LRepo.InsertAll([
        City('3548500', 'Santos', 'SP'),
        City('3550308', 'São Paulo (again)', 'SP')]);
      Writeln('  unexpected: the batch was accepted');
    except
      on E: EConstraintViolationException do
        if E.Kind = cvUnique then
          Writeln('  rejected: a duplicate key (', E.ClassName, '); the batch was rolled back.')
        else
          raise;
    end;
    Writeln('Cities stored: ', LRepo.Count);
    PrintState(LRepo, 'SP');
    Writeln;

    LRepo.InsertAll([
      City('3548500', 'Santos', 'SP'),
      City('3518800', 'Guarulhos', 'SP'),
      City('3534401', 'Osasco', 'SP')]);
    PrintStatePages(LRepo, 'SP', 2);
  finally
    LRepo.Free;
  end;
end;

begin
  {$IFDEF FPC}
  // Plain FPC console programs don't run in UTF-8 by default; without this,
  // non-ASCII text becomes "?" on its way to the database (see CLAUDE.md).
  // Delphi doesn't need it.
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ELSE}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  try
    Run;
  except
    // The subclass first: a failed connect was already explained by
    // CheckSampleConnection (settings in use and the driver's error).
    on E: EDatabaseConnectException do
      ExitCode := 1;
    on E: EDatabaseUnavailableException do
    begin
      // Message is generic and safe to show; the driver's detail is for logs.
      Writeln(E.Message);
      Writeln('  driver: ', E.OriginalClassName, ': ', E.OriginalMessage);
      ExitCode := 1;
    end;
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
