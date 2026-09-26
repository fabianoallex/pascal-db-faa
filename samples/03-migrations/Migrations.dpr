program Migrations;

{ Sample 03: versioned migrations, with SQL kept in .sql files and embedded
  in the executable.

  SQL: sql/PG, sql/FB and sql/SQLITE hold one .sql file per script; the name
  of the file is the key the program asks for (MIG.0001, PRODUCT.LIST, ...),
  and the factory's SQL directory (PG, FB or SQLITE, from Samples.Env) picks
  the folder.
  tools/build_sql_res.py turns the tree into sql/MigrationsSql.res, which the
  $R directive below links into the program on both compilers; TResourceSqlSource
  reads it back. Rebuild the .res after editing a .sql file:
    python tools/build_sql_res.py samples/03-migrations/sql samples/03-migrations/sql/MigrationsSql.res
  During development, set PASCALDB_SAMPLE_SQL_DIR to the sql folder: a
  TDirectorySqlSource then answers first and the embedded copy is only the
  fallback (TCompositeSqlSource), so an edited .sql takes effect without
  rebuilding.

  Migrations: TDBMigrationEngine applies, in order, every TMigrationItem
  whose version isn't in SCHEMA_MIGRATIONS yet (the table MIG.0001 creates),
  so running it again applies nothing. IsDDL decides the transactions: a DDL
  script (IsDDL = True) commits before its version is recorded, because
  Firebird can't use a table or column in the transaction that created it; a
  DML script (IsDDL = False) and its version record share one transaction,
  all or nothing. That is why adding the ACTIVE column (MIG.0004, DDL) and
  filling it (MIG.0005, DML) are two migrations. Published migrations are
  never edited: a change is always a new script at the end of the list.

  Scripts are split at each Terminator (';' here) without looking at quotes
  or comments: no ';' inside a string literal or a comment, and no comment
  after the last statement.

  Progress arrives as events through a method (TMigrationLog.OnEvent), the
  form that compiles on both: Delphi also accepts a closure, FPC 3.2.2 has
  none.

  Run with --reset to drop the sample's tables first and watch every
  migration apply again. Same source for Delphi (Migrations.dproj) and
  Lazarus/FPC (Migrations.lpi); connection settings as in sample 02. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

// Not "Migrations.res": the Delphi IDE writes one next to this file, and FPC
// with a unit output folder (-FU, as lazbuild uses) links a same-named .res
// from the program's folder instead of the path given here (CLAUDE.md,
// gotcha 19).
{$R 'sql/MigrationsSql.res'}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring, // FPC on Unix: needed for non-ASCII text in Variants (see CLAUDE.md)
  {$ENDIF}
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Migrations,
  Samples.Env;

const
  ALL_MIGRATIONS: array[0..4] of TMigrationItem = (
    (Version: 1; ScriptName: 'MIG.0001'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: True),   // SCHEMA_MIGRATIONS
    (Version: 2; ScriptName: 'MIG.0002'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: True),   // SAMPLE_PRODUCTS
    (Version: 3; ScriptName: 'MIG.0003'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: False),  // seed rows
    (Version: 4; ScriptName: 'MIG.0004'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: True),   // ACTIVE column
    (Version: 5; ScriptName: 'MIG.0005'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: False)); // fill ACTIVE

type
  TMigrationLog = class
  public
    procedure OnEvent(const AEvent: TMigrationEvent);
  end;

procedure TMigrationLog.OnEvent(const AEvent: TMigrationEvent);
const
  KINDS: array[Boolean] of string = ('DML', 'DDL');
begin
  case AEvent.Kind of
    mekCheck:
      Writeln('  schema version before: ', AEvent.SchemaVersion);
    mekApplying:
      Writeln('  applying ', AEvent.Version, ' ', AEvent.ScriptName, ' (', KINDS[AEvent.IsDDL], ')');
    mekFailed:
      Writeln('  FAILED ', AEvent.Version, ' ', AEvent.ScriptName, ': ', AEvent.ErrorMessage);
    mekCompleted:
      Writeln('  applied ', AEvent.AppliedCount, '; schema version now: ', AEvent.SchemaVersion);
  end;
end;

function BuildSqlSource: ISqlSource;
var
  LDir: string;
begin
  LDir := GetEnvironmentVariable('PASCALDB_SAMPLE_SQL_DIR');
  if LDir = '' then
  begin
    Writeln('SQL: embedded resources');
    Result := TResourceSqlSource.Create;
  end
  else
  begin
    // TDirectorySqlSource resolves a relative root against the executable's
    // folder (a service's working directory is System32); a path typed in a
    // shell is meant relative to the current one.
    LDir := ExpandFileName(LDir);
    Writeln('SQL: ', LDir, ', then embedded resources');
    Result := TCompositeSqlSource.Create([TDirectorySqlSource.Create(LDir), TResourceSqlSource.Create]);
  end;
end;

procedure ExecIgnoringErrors(const AFactory: IDBFactory; const ASql: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := ASql;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback; // the table didn't exist: nothing to drop
  end;
end;

procedure ListProducts(const AFactory: IDBFactory);
const
  STATES: array[Boolean] of string = ('inactive', 'active');
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LPrice: Double;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader['PRODUCT.LIST'].SQL;
    LResult := LQuery.Open;
    while not LResult.Eof do
    begin
      // An assignment converts; a Double(...) typecast of a Currency does not
      // on FPC for Linux (it prints 125000.00 for 12.50).
      LPrice := LResult.Currencies['PRICE'];
      Writeln(Format('  %d  %-15s %8.2f  %s', [LResult.Integers['ID'], LResult.Strings['NAME'],
        LPrice, STATES[LResult.Booleans['ACTIVE']]]));
      LResult.Next;
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure Run;
var
  LFactory: IDBFactory;
  LLog: TMigrationLog;
  LEngine: TDBMigrationEngine;
begin
  Writeln('Target: ', SampleTarget);
  LFactory := NewSampleFactory(BuildSqlSource);
  CheckSampleConnection(LFactory);

  if (ParamCount > 0) and SameText(ParamStr(1), '--reset') then
  begin
    Writeln('Reset: dropping SAMPLE_PRODUCTS and SCHEMA_MIGRATIONS');
    ExecIgnoringErrors(LFactory, 'DROP TABLE SAMPLE_PRODUCTS');
    ExecIgnoringErrors(LFactory, 'DROP TABLE SCHEMA_MIGRATIONS');
  end;
  Writeln;

  LLog := TMigrationLog.Create;
  LEngine := TDBMigrationEngine.Create(LFactory, LLog.OnEvent);
  try
    Writeln('Migrating:');
    LEngine.Execute(ALL_MIGRATIONS);
    Writeln('Migrating again (nothing is pending now):');
    LEngine.Execute(ALL_MIGRATIONS);
    Writeln('CurrentVersion: ', LEngine.CurrentVersion);
  finally
    LEngine.Free;
    LLog.Free;
  end;
  Writeln;

  Writeln('Products:');
  ListProducts(LFactory);
end;

begin
  {$IFDEF FPC}
  // Plain FPC console programs don't run in UTF-8 by default; without this,
  // reading a non-ASCII .sql file (MIG.0003) raises ESqlSourceException
  // instead of corrupting the text (see CLAUDE.md). Delphi doesn't need it.
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ELSE}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  try
    Run;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
