program PascalDb.IntegrationTestsZeos;

{ DUnitX runner for the integration (contract) tests, on the Zeos adapter,
  against a local Firebird server — see PascalDb.IntegrationEnv for the
  settings (a default Firebird 2.5 install is found automatically; a Win32
  build uses its 32-bit client from the WOW64 folder). The project defines
  PASCALDB_IT_ZEOS, which makes PascalDb.IntegrationEnv build a TZeosFactory.

  ZeosLib 8 is compiled from source: set the ZEOSDBO environment variable
  (Tools > Options > IDE > Environment Variables, or the OS environment) to
  the ZeosLib folder — the one containing src\core, src\dbc, ...

  The FPCUnit sibling on Zeos lives in tests/Integration/fpc-zeos. }

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  PascalDb.Adapter.Zeos in '..\..\adapters\zeos\PascalDb.Adapter.Zeos.pas',
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
