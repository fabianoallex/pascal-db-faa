program PascalDbUnitTestsFpc;

{ Runner FPCUnit dos testes unitários. Mesma cobertura da suíte DUnitX
  (tests/Unit/PascalDb.UnitTests.dpr): os fixtures em tests/Unit/fpc são
  gerados a partir dos mestres DUnitX por tools/gen_fpc_mirror.py.

  Console (saída de texto), quando chamado com qualquer parâmetro:
    .\PascalDbUnitTestsFpc.exe --all --format=plain
  GUI (árvore de testes + barra verde/vermelha), sem parâmetros:
    .\PascalDbUnitTestsFpc.exe
  Fora do Windows roda sempre em modo console (sem LCL/widgetset). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  PascalDb.OptionalsTests,
  PascalDb.ClockCacheTests,
  PascalDb.SqlLoaderTests,
  PascalDb.MockTests,
  PascalDb.PoolTests;

var
  ConsoleApp: TTestRunner;
begin
  // Console FPC puro: DefaultSystemCodePage nao e' UTF-8 por padrao, e os
  // literais acentuados dos testes seriam transcodificados errado — mesma
  // armadilha documentada no pascal-redis-faa.
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
      ConsoleApp.Title := 'pascal-db-faa - testes unitarios (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
