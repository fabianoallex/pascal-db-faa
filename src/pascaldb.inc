{ Diretivas de compilacao compartilhadas (dual Delphi / Free Pascal).

  Cada unit da lib inclui este arquivo logo apos o 'unit ...;'. No Delphi ele
  nao tem efeito de modo; no FPC ativa o mode Delphi (strings longas, generics
  estilo Delphi, advanced records).

  PASCALDB_WINDOWS: definido quando o alvo e' Windows, em qualquer compilador
  (Delphi define MSWINDOWS; FPC define WINDOWS). }

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

{ PASCALDB_FUNCREFS: callbacks publicos da lib (eventos do pool, eventos de
  migration) sao "reference to" — aceitam closure E metodo. Ligado sempre no
  Delphi. No FPC 3.2.2 (estavel) nao existe "reference to", entao os mesmos
  tipos viram "of object": o subconjunto portavel e' "passe um metodo".
  Compilador FPC com function references (trunk/3.3+): defina
  PASCALDB_FPC_FUNCREFS no projeto para ter a mesma API do Delphi — mesmo
  padrao do HORSE_FPC_FUNCTIONREFERENCES do Horse. }
{$IFNDEF FPC}
  {$DEFINE PASCALDB_FUNCREFS}
{$ELSE}
  {$IFDEF PASCALDB_FPC_FUNCREFS}
    {$MODESWITCH FUNCTIONREFERENCES}
    {$MODESWITCH ANONYMOUSFUNCTIONS}
    {$DEFINE PASCALDB_FUNCREFS}
  {$ENDIF}
{$ENDIF}
