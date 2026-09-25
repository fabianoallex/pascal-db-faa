unit PascalDb.Threading;

{$I pascaldb.inc}

{ Concurrency primitives shared between Delphi and Free Pascal: atomic
  operations (PdbAtomicXxx) and monotonic milliseconds (PdbTickMs).

  The library doesn't use TInterlocked or TStopwatch because neither exists
  in FPC. Instead, thin wrappers over each compiler's intrinsics (AtomicXxx in
  Delphi, InterLockedXxx in FPC) — same pattern as Redis.Threading and
  AMQP.Threading in the sibling libraries.

  The 64-bit ones matter on Win32/Linux-32: a raw 64-bit load/store can be
  "torn" (read halfway while another thread writes it). }

interface

function PdbAtomicInc(var ATarget: Integer): Integer;
function PdbAtomicDec(var ATarget: Integer): Integer;
function PdbAtomicInc64(var ATarget: Int64): Int64;
function PdbAtomicRead64(var ATarget: Int64): Int64;

/// Monotonic milliseconds (GetTickCount64), for measuring durations without
/// depending on the wall clock. TStopwatch (System.Diagnostics) is
/// Delphi-only.
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
