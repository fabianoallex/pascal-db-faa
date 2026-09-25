program PascalDb.IntegrationTests;

{ DUnitX runner for the integration (contract) tests, on the FireDAC adapter,
  against a real Firebird database — see PascalDb.IntegrationEnv for the
  settings (a default Firebird 2.5 install is found automatically; a Win32
  build uses its 32-bit client from the WOW64 folder).

  The sibling FPCUnit suite (SQLdb adapter) lives in tests/Integration/fpc,
  generated from these masters by tools/gen_fpc_mirror.py. }

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  FireDAC.ConsoleUI.Wait,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  PascalDb.Adapter.FireDAC in '..\..\adapters\firedac\PascalDb.Adapter.FireDAC.pas',
  PascalDb.DUnitXCompat in '..\Unit\PascalDb.DUnitXCompat.pas',
  PascalDb.IntegrationEnv in 'PascalDb.IntegrationEnv.pas',
  PascalDb.ContractTests in 'PascalDb.ContractTests.pas';

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
