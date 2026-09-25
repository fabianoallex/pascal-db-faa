program PascalDb.UnitTests;

{ Runner DUnitX dos testes unitários. Não precisa de banco: tudo roda sobre
  TMockDBFactory e fakes em memória.

  A suíte irmã em FPCUnit fica em tests/Unit/fpc — mesma cobertura e corpo
  dos testes idêntico: os arquivos de lá são GERADOS a partir destes por
  tools/gen_fpc_mirror.py (o PascalDb.DUnitXCompat existe para isso). Edite
  sempre os mestres DUnitX daqui e regenere o espelho. }

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
  PascalDb.SqlLoader in '..\..\src\PascalDb.SqlLoader.pas',
  PascalDb.Interfaces in '..\..\src\PascalDb.Interfaces.pas',
  PascalDb.SqlDialect in '..\..\src\PascalDb.SqlDialect.pas',
  PascalDb.Registry in '..\..\src\PascalDb.Registry.pas',
  PascalDb.SafeLog in '..\..\src\PascalDb.SafeLog.pas',
  PascalDb.Mock in '..\..\src\PascalDb.Mock.pas',
  PascalDb.Pool in '..\..\src\PascalDb.Pool.pas',
  PascalDb.Migrations in '..\..\src\PascalDb.Migrations.pas',
  PascalDb.DUnitXCompat in 'PascalDb.DUnitXCompat.pas',
  PascalDb.OptionalsTests in 'PascalDb.OptionalsTests.pas',
  PascalDb.ClockCacheTests in 'PascalDb.ClockCacheTests.pas',
  PascalDb.SqlLoaderTests in 'PascalDb.SqlLoaderTests.pas',
  PascalDb.MockTests in 'PascalDb.MockTests.pas',
  PascalDb.PoolTests in 'PascalDb.PoolTests.pas';

var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger: ITestLogger;
begin
  // Criterio de aceite dos dois lados: 0 leaks (FastMM aqui, heaptrc no FPC).
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
