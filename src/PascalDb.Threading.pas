unit PascalDb.Threading;

{$I pascaldb.inc}

{ Primitivas de concorrência compartilhadas entre Delphi e Free Pascal:
  operações atômicas (PdbAtomicXxx) e milissegundos monotônicos (PdbTickMs).

  A lib não usa TInterlocked nem TStopwatch porque nenhum dos dois existe no
  FPC. Em vez disso, wrappers finos sobre os intrinsics de cada compilador
  (AtomicXxx no Delphi, InterLockedXxx no FPC) — mesmo padrão de
  Redis.Threading/AMQP.Threading nas libs irmãs.

  Os de 64 bits importam no Win32/Linux-32: um load/store cru de 64 bits pode
  ser "torn" (lido pela metade enquanto outra thread escreve). }

interface

function PdbAtomicInc(var ATarget: Integer): Integer;
function PdbAtomicDec(var ATarget: Integer): Integer;
function PdbAtomicInc64(var ATarget: Int64): Int64;
function PdbAtomicRead64(var ATarget: Int64): Int64;

/// Milissegundos monotonicos (GetTickCount64), para medir duracao sem
/// depender de relogio de parede. TStopwatch (System.Diagnostics) e'
/// exclusivo do Delphi.
function PdbTickMs: UInt64;

implementation

uses
  SysUtils,
  Classes;

function PdbAtomicInc(var ATarget: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedIncrement(ATarget);
  {$ELSE}
  Result := AtomicIncrement(ATarget);
  {$ENDIF}
end;

function PdbAtomicDec(var ATarget: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedDecrement(ATarget);
  {$ELSE}
  Result := AtomicDecrement(ATarget);
  {$ENDIF}
end;

function PdbAtomicInc64(var ATarget: Int64): Int64;
begin
  {$IFDEF FPC}
  Result := InterLockedIncrement64(ATarget);
  {$ELSE}
  Result := AtomicIncrement(ATarget);
  {$ENDIF}
end;

function PdbAtomicRead64(var ATarget: Int64): Int64;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange64(ATarget, 0, 0);
  {$ELSE}
  Result := AtomicCmpExchange(ATarget, 0, 0);
  {$ENDIF}
end;

function PdbTickMs: UInt64;
begin
  {$IFDEF FPC}
  Result := GetTickCount64;
  {$ELSE}
  Result := TThread.GetTickCount64;
  {$ENDIF}
end;

end.
