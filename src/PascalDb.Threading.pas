unit PascalDb.Threading;

{$I pascaldb.inc}

{ Concurrency primitives shared between Delphi and Free Pascal: atomic
  operations (PdbAtomicXxx), monotonic milliseconds (PdbTickMs) and
  monotonic microseconds (PdbTickUs).

  The library doesn't use TInterlocked or TStopwatch because neither exists
  in FPC. Instead, thin wrappers over each compiler's intrinsics (AtomicXxx in
  Delphi, InterLockedXxx in FPC) — same pattern as Redis.Threading and
  AMQP.Threading in the sibling libraries.

  The 64-bit ones matter on Win32/Linux-32: a raw 64-bit load/store can be
  "torn" (read halfway while another thread writes it).

  PdbTickMs is GetTickCount64, which on Windows advances in steps of 15-16
  ms (measured): fine for timeouts and idle ages, useless for timing a
  statement that takes 2 ms. PdbTickUs reads QueryPerformanceCounter on
  Windows (10 MHz measured on Windows 11), TStopwatch's timestamp on
  Delphi elsewhere, and CLOCK_MONOTONIC on FPC for Linux; on other FPC
  targets it falls back to GetTickCount64 * 1000. }

interface

function PdbAtomicInc(var ATarget: Integer): Integer;
function PdbAtomicDec(var ATarget: Integer): Integer;
function PdbAtomicInc64(var ATarget: Int64): Int64;
/// Adds ADelta atomically; returns the new value.
function PdbAtomicAdd64(var ATarget: Int64; ADelta: Int64): Int64;
function PdbAtomicRead64(var ATarget: Int64): Int64;

/// Monotonic milliseconds (GetTickCount64), for measuring durations without
/// depending on the wall clock. TStopwatch (System.Diagnostics) is
/// Delphi-only.
function PdbTickMs: UInt64;

/// Monotonic microseconds, for timing short operations (see the unit
/// header for the source on each platform). Only differences between two
/// calls mean anything.
function PdbTickUs: Int64;

implementation

uses
  {$IFDEF FPC}
    {$IFDEF MSWINDOWS}Windows,{$ENDIF}
    {$IFDEF LINUX}Linux, UnixType,{$ENDIF}
  {$ELSE}
  System.Diagnostics,
  {$ENDIF}
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

function PdbAtomicAdd64(var ATarget: Int64; ADelta: Int64): Int64;
begin
  {$IFDEF FPC}
  Result := InterLockedExchangeAdd64(ATarget, ADelta) + ADelta;
  {$ELSE}
  Result := AtomicIncrement(ATarget, ADelta);
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

{$IF DEFINED(FPC) and DEFINED(MSWINDOWS)}
var
  GPerfFrequency: Int64 = 0;
{$IFEND}

function PdbTickUs: Int64;
{$IF DEFINED(FPC) and DEFINED(MSWINDOWS)}
var
  LCount: Int64;
begin
  if GPerfFrequency = 0 then
    QueryPerformanceFrequency(GPerfFrequency);  // the same value every time: a race is harmless
  QueryPerformanceCounter(LCount);
  Result := (LCount div GPerfFrequency) * 1000000 + (LCount mod GPerfFrequency) * 1000000 div GPerfFrequency;
end;
{$ELSEIF DEFINED(FPC) and DEFINED(LINUX)}
var
  LTime: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @LTime);
  Result := Int64(LTime.tv_sec) * 1000000 + LTime.tv_nsec div 1000;
end;
{$ELSEIF DEFINED(FPC)}
begin
  Result := Int64(GetTickCount64) * 1000;
end;
{$ELSE}
var
  LStamp: Int64;
begin
  LStamp := TStopwatch.GetTimeStamp;
  Result := (LStamp div TStopwatch.Frequency) * 1000000 +
    (LStamp mod TStopwatch.Frequency) * 1000000 div TStopwatch.Frequency;
end;
{$IFEND}

end.
