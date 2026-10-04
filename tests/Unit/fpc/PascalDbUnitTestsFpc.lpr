program PascalDbUnitTestsFpc;

{ FPCUnit runner for the unit tests. Same coverage as the DUnitX suite
  (tests/Unit/PascalDb.UnitTests.dpr): the fixtures in tests/Unit/fpc are
  generated from the DUnitX masters by tools/gen_fpc_mirror.py.

  Console (text output), when called with any parameter:
    .\PascalDbUnitTestsFpc.exe --all --format=plain
  GUI (test tree + green/red bar), with no parameters:
    .\PascalDbUnitTestsFpc.exe
  Outside Windows it always runs in console mode (no LCL/widgetset). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  // Without cwstring, FPC on Unix converts a WideString Variant (varOleStr —
  // what a non-ASCII literal in an "array of Variant" becomes, as in the
  // TMockQueryResult tests) back to string one byte per character (Latin-1),
  // ignoring the UTF-8 code page: 'São' comes back as invalid UTF-8.
  cwstring,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  PascalDb.SqlLoaderTests,
  PascalDb.MockTests,
  PascalDb.PoolTests,
  PascalDb.SqlSourcesTests,
  PascalDb.AdapterBaseTests,
  PascalDb.PagingTests,
  PascalDb.BatchTests;

// SQL resources used by PascalDb.SqlSourcesTests (tools/build_sql_res.py).
{$R ../sql/PascalDbTestSql.res}

var
  ConsoleApp: TTestRunner;
begin
  // Plain FPC console: DefaultSystemCodePage isn't UTF-8 by default, and the
  // tests' accented literals would be transcoded wrongly — same trap
  // documented in pascal-redis-faa.
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
      ConsoleApp.Title := 'pascal-db-faa - unit tests (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
