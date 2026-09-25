unit PascalDb.SafeLog;

{$I pascaldb.inc}

{ SafeWriteln: Writeln no console protegido por uma seção crítica global.

  Código que roda fora da main thread (handlers de servidor HTTP, callbacks de
  pipe/mensageria, threads do pool) não pode usar Writeln direto: sob
  concorrência ele corrompe o buffer do console.

  Num binário sem console (sem a diretiva APPTYPE CONSOLE: serviço Windows,
  app VCL/LCL/FMX) não existe saída padrão, e Writeln(Output) levanta EInOutError
  (105) na primeira chamada. O guard IsConsole torna SafeWriteln um no-op
  nesses binários, para o mesmo código de startup servir aos dois. A
  consequência é que diagnóstico que só passa por aqui some sem aviso num
  serviço — por isso quem precisa de log persistente deve informar os
  callbacks de evento (pool, migrations) em vez de depender deste fallback. }

interface

/// Escreve no console protegido por uma seção crítica global.
///
/// Handlers HTTP (Horse) e OnRequest de pipe-server rodam em thread pool —
/// Writeln direto nesse contexto corrompe o buffer do console sob
/// concorrência. Use SafeWriteln em qualquer ponto que possa ser chamado
/// fora da main thread.
///
/// Num binário SEM {$APPTYPE CONSOLE} (serviço Windows, app VCL/FMX) não existe
/// handle de saída padrão: `Writeln(Output)` levanta EInOutError (I/O error 105)
/// na primeira chamada. O guard `IsConsole` torna SafeWriteln um no-op nesses
/// binários, para que o mesmo código de startup sirva ao executável console e ao
/// serviço sem derrubar o segundo. Log persistente é responsabilidade do
/// Common.FileLog — que grava igual nos dois.
procedure SafeWriteln(const AText: string); overload;
procedure SafeWriteln(const AFormatStr: string; const AArgs: array of const); overload;

implementation

uses
  SysUtils,
  SyncObjs;

var
  GConsoleLock: TCriticalSection;

procedure SafeWriteln(const AText: string);
begin
  // sem console não há Output associado — Writeln levantaria EInOutError (105)
  if not IsConsole then
    Exit;

  GConsoleLock.Enter;
  try
    Writeln(AText);
  finally
    GConsoleLock.Leave;
  end;
end;

procedure SafeWriteln(const AFormatStr: string; const AArgs: array of const);
begin
  // checa antes do Format: sem console a formatação também é trabalho jogado fora
  if not IsConsole then
    Exit;

  SafeWriteln(Format(AFormatStr, AArgs));
end;

initialization
  GConsoleLock := TCriticalSection.Create;

finalization
  GConsoleLock.Free;

end.
