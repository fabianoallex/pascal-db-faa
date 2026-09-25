unit PascalDb.SafeLog;

{$I pascaldb.inc}

{ SafeWriteln: Writeln to the console, guarded by a global critical section.

  Code that runs off the main thread (HTTP server handlers, pipe/messaging
  callbacks, pool threads) must not call Writeln directly: under concurrency
  it corrupts the console buffer.

  In a binary without a console (no APPTYPE CONSOLE directive: Windows
  service, VCL/LCL/FMX app) there is no standard output, and Writeln(Output)
  raises EInOutError (105) on the first call. The IsConsole guard turns
  SafeWriteln into a no-op in those binaries, so the same startup code serves
  both. The consequence is that diagnostics that only go through here vanish
  silently in a service — anyone who needs persistent logging should pass the
  event callbacks (pool, migrations) instead of relying on this fallback. }

interface

/// Writes to the console guarded by a global critical section. Safe to call
/// from any thread; a no-op in binaries without a console (see the unit
/// header).
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
  // no console means no Output handle — Writeln would raise EInOutError (105)
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
  // check before Format: without a console, formatting is wasted work too
  if not IsConsole then
    Exit;

  SafeWriteln(Format(AFormatStr, AArgs));
end;

initialization
  GConsoleLock := TCriticalSection.Create;

finalization
  GConsoleLock.Free;

end.
