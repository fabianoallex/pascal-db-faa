program PascalDb.UnitTests;

{ DUnitX runner for the unit tests. No database needed: everything runs on
  TMockDBFactory and in-memory fakes.

  The sibling FPCUnit suite lives in tests/Unit/fpc — same coverage and
  identical test bodies: the files there are GENERATED from these by
  tools/gen_fpc_mirror.py (PascalDb.DUnitXCompat exists for that). Always
  edit the DUnitX masters here and regenerate the mirror. }

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  PascalDb.Threading in '..\..\src\PascalDb.Threading.pas',
  PascalDb.SystemContext in '..\..\src\PascalDb.SystemContext.pas',
  PascalDb.ClockCache in '..\..\src\PascalDb.ClockCache.pas',
  PascalDb.Optionals in '..\..\src\PascalDb.Optionals.pas',
  PascalDb.SqlSources in '..\..\src\PascalDb.SqlSources.pas',
  PascalDb.SqlLoader in '..\..\src\PascalDb.SqlLoader.pas',
  PascalDb.Interfaces in '..\..\src\PascalDb.Interfaces.pas',
  PascalDb.SqlDialect in '..\..\src\PascalDb.SqlDialect.pas',
  PascalDb.Paging in '..\..\src\PascalDb.Paging.pas',
  PascalDb.Registry in '..\..\src\PascalDb.Registry.pas',
  PascalDb.SafeLog in '..\..\src\PascalDb.SafeLog.pas',
  PascalDb.Mock in '..\..\src\PascalDb.Mock.pas',
  PascalDb.Pool in '..\..\src\PascalDb.Pool.pas',
  PascalDb.Migrations in '..\..\src\PascalDb.Migrations.pas',
  PascalDb.Adapter.Base in '..\..\src\PascalDb.Adapter.Base.pas',
  PascalDb.Adapter.DataSet in '..\..\src\PascalDb.Adapter.DataSet.pas',
  PascalDb.DUnitXCompat in 'PascalDb.DUnitXCompat.pas',
  PascalDb.OptionalsTests in 'PascalDb.OptionalsTests.pas',
  PascalDb.ClockCacheTests in 'PascalDb.ClockCacheTests.pas',
  PascalDb.SqlLoaderTests in 'PascalDb.SqlLoaderTests.pas',
  PascalDb.MockTests in 'PascalDb.MockTests.pas',
  PascalDb.PoolTests in 'PascalDb.PoolTests.pas',
  PascalDb.SqlSourcesTests in 'PascalDb.SqlSourcesTests.pas',
  PascalDb.AdapterBaseTests in 'PascalDb.AdapterBaseTests.pas',
  PascalDb.PagingTests in 'PascalDb.PagingTests.pas';

// SQL resources used by PascalDb.SqlSourcesTests (tools/build_sql_res.py).
{$R 'sql\PascalDbTestSql.res'}

var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger: ITestLogger;
begin
  // Acceptance criterion on both sides: 0 leaks (FastMM here, heaptrc on FPC).
  ReportMemoryLeaksOnShutdown := True;
  try
    TDUnitX.CheckCommandLine;

    if TDUnitX.Options.Include = '' then
      TDUnitX.Options.Include := '.';

    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    runner.FailsOnNoAsserts := False;

    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      logger := TDUnitXConsoleLogger.Create(
        TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      runner.AddLogger(logger);
    end;

    nunitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    runner.AddLogger(nunitLogger);

    results := runner.Execute;

    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;

    if (TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause) and IsConsole then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
end.
