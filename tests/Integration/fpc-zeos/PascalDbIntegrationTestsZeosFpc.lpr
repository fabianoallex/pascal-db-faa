program PascalDbIntegrationTestsZeosFpc;

{ FPCUnit runner for the integration (contract) tests on the Zeos adapter,
  against a local Firebird server — see PascalDb.IntegrationEnv for the
  settings. Same fixtures as the SQLdb runner (tests/Integration/fpc, generated
  from the DUnitX masters by tools/gen_fpc_mirror.py); the project defines
  PASCALDB_IT_ZEOS, which makes PascalDb.IntegrationEnv build a TZeosFactory.

  Console (text output), when called with any parameter:
    .\PascalDbIntegrationTestsZeosFpc.exe --all --format=plain
  GUI (test tree + green/red bar), with no parameters:
    .\PascalDbIntegrationTestsZeosFpc.exe
  Outside Windows it always runs in console mode (no LCL/widgetset). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  // Without cwstring, FPC on Unix converts a WideString Variant (varOleStr)
  // back to string one byte per character (Latin-1), ignoring the UTF-8 code
  // page — see CLAUDE.md, "Runtime requirements for FPC applications".
  cwstring,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  PascalDb.ContractTests;

var
  ConsoleApp: TTestRunner;
begin
  // Plain FPC console: DefaultSystemCodePage isn't UTF-8 by default, and
  // non-ASCII text would be turned into "?" — see CLAUDE.md.
  SetMultiByteConversionCodePage(CP_UTF8);

  {$IFDEF MSWINDOWS}
  if ParamCount = 0 then
  begin
    Application.Initialize;
    Application.CreateForm(TGUITestRunner, TestRunner);
    Application.Run;
  end
  else
  {$ENDIF}
  begin
    DefaultFormat := fPlain;
    DefaultRunAllTests := True;
    ConsoleApp := TTestRunner.Create(nil);
    try
      ConsoleApp.Initialize;
      ConsoleApp.Title := 'pascal-db-faa - integration tests, Zeos (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
