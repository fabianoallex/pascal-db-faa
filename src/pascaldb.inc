{ Shared compiler directives (dual Delphi / Free Pascal).

  Every unit of the library includes this file right after 'unit ...;'. On
  Delphi it doesn't change the mode; on FPC it enables Delphi mode (long
  strings, Delphi-style generics, advanced records).

  PASCALDB_WINDOWS: defined when the target is Windows, on either compiler
  (Delphi defines MSWINDOWS; FPC defines WINDOWS). }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{$IFDEF MSWINDOWS}
  {$DEFINE PASCALDB_WINDOWS}
{$ENDIF}
{$IFDEF WINDOWS}
  {$IFNDEF PASCALDB_WINDOWS}
    {$DEFINE PASCALDB_WINDOWS}
  {$ENDIF}
{$ENDIF}

{ PASCALDB_FUNCREFS: the library's public callbacks (pool events, migration
  events) are "reference to" — they accept a closure OR a method. Always on
  in Delphi. FPC 3.2.2 (stable) has no "reference to", so the same types
  become "of object" there: the portable subset is "pass a method".
  FPC compiler with function references (trunk/3.3+): define
  PASCALDB_FPC_FUNCREFS in the project to get the same API as Delphi — same
  pattern as Horse's HORSE_FPC_FUNCTIONREFERENCES. }
{$IFNDEF FPC}
  {$DEFINE PASCALDB_FUNCREFS}
{$ELSE}
  {$IFDEF PASCALDB_FPC_FUNCREFS}
    {$MODESWITCH FUNCTIONREFERENCES}
    {$MODESWITCH ANONYMOUSFUNCTIONS}
    {$DEFINE PASCALDB_FUNCREFS}
  {$ENDIF}
{$ENDIF}
