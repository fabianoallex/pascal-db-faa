unit PascalDb.SqlLoader;

{$I pascaldb.inc}

(* SQL lives in files, not in code: TSQLLoader loads the text of a resource
  embedded in the executable (named SQL_<DIRECTORY>_<NAME>, with a global
  thread-safe cache), and TSQLResult processes the template before execution:

  - [TAG {] ... [} TAG] — block kept or removed by ProcessTag(TAG, Keep); the
    same tag may appear in several places and one call decides all of them;
  - ${LITERAL} — replaced by ReplaceLiteral (ApplyOperator/ApplyFilter are
    shortcuts for the _OP suffix);
  - [COMMENTS {] ... [} COMMENTS] and unprocessed tags are removed when .SQL
    is read.

  Dual-compiler: FindResource/TResourceStream are portable, but RT_RCDATA
  doesn't live in the same place in both RTLs (Winapi.Windows in Delphi; in
  FPC 3.2.2 only in the system unit of non-Windows targets) — hence the local
  constant SQL_RESOURCE_TYPE. Producing the .res differs too (brcc32 in
  Delphi, fpcres/windres in FPC); that is an open design item recorded in
  CLAUDE.md.

  This comment uses parenthesis-asterisk instead of braces because it quotes
  the tag syntax, which contains "}" and would close a brace comment. *)

interface

uses
  Classes,
  SysUtils,
  StrUtils,
  SyncObjs,
  Generics.Collections
  {$IFNDEF FPC}, Winapi.Windows{$ENDIF};

type
  ESQLLoaderException = class(Exception);

  (*
    SELECT *
    FROM
      TB_ENTITY
    WHERE 1=1
      [ENTITY_NAME {] AND ENTITY_NAME = :ENTITY_NAME [} ENTITY_NAME]
      [PK_FIELD {] AND PK_FIELD <= :PK_FIELD [} PK_FIELD]

    [ENTITY_NAME {] --> START TAG
    [} ENTITY_NAME] --> END TAG

    ProcessTag decides whether the condition between the tags is kept or
    removed
  *)

  TSQLCache = TDictionary<string, string>;

  { TSQLResult }

  TSQLResult = record
  public
    class operator Explicit(a: TSQLResult): string;
    class function From(const ASQL: string): TSQLResult; static;
  private
    FSQL: string;
    function GetSQL: string;
  public
    function ProcessTag(const ATag: string; Keep: Boolean): TSQLResult;
    function ReplaceLiteral(const ATag, AValue: string): TSQLResult;
    function ApplyOperator(const ATag: string; const AOperator: string): TSQLResult;
    function ApplyFilter(const Tag: string; const OperatorSQL: string; HasValue: Boolean): TSQLResult;
    property SQL: string read GetSQL;
  end;

  { TSQLLoader }

  TSQLLoader = class
  private
    class var FCache: TSQLCache;
    class var FLock: TCriticalSection;
    class function GetInternal(ASQLDirectory, AResourceName: string): string;
    class function GetFromCacheOrResource(ASQLDirectory, AResourceName: string): string;
  public
    class constructor Create;
    class destructor Destroy;
    class procedure ClearCache;
    class function Load(ASQLDirectory, AResourceName: string): TSQLResult;
  private
    FSQLDirectory: string;
  protected
    function GetSql(const AResourceName: string): TSQLResult; virtual;
  public
    constructor Create(ASQLDirectory: string);
    property SQLDirectory: string read FSQLDirectory;
    property Sql[const AResourceName: string]: TSQLResult read GetSql; default;
  end;

implementation

const
  // RT_RCDATA comes from Winapi.Windows in Delphi; in FPC 3.2.2 it is only in
  // the system unit on non-Windows targets (on Windows it lives in the
  // Windows unit). MAKEINTRESOURCE(10) is the same value on every platform.
  SQL_RESOURCE_TYPE = {$IFDEF FPC}PChar(10){$ELSE}RT_RCDATA{$ENDIF};

{ TSQLResult }

class function TSQLResult.From(const ASQL: string): TSQLResult;
begin
  Result.FSQL := ASQL;
end;

function TSQLResult.ProcessTag(const ATag: string; Keep: Boolean): TSQLResult;
var
  Prefix, EndTag: string;
  P1, P2, P1Len: Integer;

  function FindStartTag: Integer;
  var
    I, J: Integer;
  begin
    Result := 0;
    P1Len  := 0;
    I := Pos(Prefix, FSQL);
    while I > 0 do
    begin
      J := I + Length(Prefix);
      while (J <= Length(FSQL)) and (FSQL[J] = ' ') do
        Inc(J);
      if (J < Length(FSQL)) and (FSQL[J] = '{') and (FSQL[J + 1] = ']') then
      begin
        P1Len  := (J + 1) - I + 1;
        Result := I;
        Exit;
      end;
      I := PosEx(Prefix, FSQL, I + 1);
    end;
  end;

begin
  Prefix := '[' + ATag;
  EndTag := '[} ' + ATag + ']';

  while True do
  begin
    P1 := FindStartTag;
    P2 := Pos(EndTag, FSQL);

    if (P1 = 0) or (P2 = 0) then Break;

    if Keep then
    begin
      Delete(FSQL, P2, Length(EndTag));
      Delete(FSQL, P1, P1Len);
    end
    else
      Delete(FSQL, P1, (P2 + Length(EndTag)) - P1);
  end;
  Result := Self;
end;

function TSQLResult.ReplaceLiteral(const ATag, AValue: string): TSQLResult;
begin
  FSQL := StringReplace(FSQL, '${' + ATag + '}', AValue, [rfReplaceAll]);
  Result := Self;
end;

function TSQLResult.ApplyOperator(const ATag: string; const AOperator: string): TSQLResult;
begin
  Result := ReplaceLiteral(ATag + '_OP', AOperator);
end;

function TSQLResult.ApplyFilter(const Tag: string; const OperatorSQL: string; HasValue: Boolean): TSQLResult;
begin
  Result := ProcessTag(Tag, HasValue);
  if HasValue then
    Result := ReplaceLiteral(Tag + '_OP', OperatorSQL);
end;

class operator TSQLResult.Explicit(a: TSQLResult): string;
begin
  Result := a.FSQL;
end;

function TSQLResult.GetSQL: string;
var
  P1, P2: Integer;
begin
  ProcessTag('COMMENTS', False);

  Result := FSQL;

  while True do
  begin
    P2 := Pos(' {]', Result);
    if P2 = 0 then Break;

    P1 := P2;
    while (P1 > 1) and (Result[P1] <> '[') do
      Dec(P1);

    if Result[P1] = '[' then
      Delete(Result, P1, (P2 + 3) - P1);
  end;

  while True do
  begin
    P1 := Pos('[} ', Result);
    if P1 = 0 then Break;

    P2 := P1;
    while (P2 < Length(Result)) and (Result[P2] <> ']') do
      Inc(P2);

    if Result[P2] = ']' then
      Delete(Result, P1, (P2 - P1) + 1);
  end;
end;

{ TSQLLoader }

class constructor TSQLLoader.Create;
begin
  FCache := TSQLCache.Create;
  FLock  := TCriticalSection.Create;
end;

class destructor TSQLLoader.Destroy;
begin
  FCache.Free;
  FLock.Free;
end;

class procedure TSQLLoader.ClearCache;
begin
  FLock.Enter;
  try
    FCache.Clear;
  finally
    FLock.Leave;
  end;
end;

class function TSQLLoader.Load(ASQLDirectory, AResourceName: string): TSQLResult;
begin
  if ASQLDirectory.IsEmpty or AResourceName.IsEmpty then
    raise ESQLLoaderException.Create(
      'ASQLDirectory and AResourceName are required'
    );

  Result.FSQL := GetFromCacheOrResource(ASQLDirectory, AResourceName);
end;

function TSQLLoader.GetSql(const AResourceName: string): TSQLResult;
begin
  Result := TSQLLoader.Load(FSQLDirectory, AResourceName);
end;

constructor TSQLLoader.Create(ASQLDirectory: string);
begin
  FSQLDirectory := ASQLDirectory;
end;

class function TSQLLoader.GetFromCacheOrResource(ASQLDirectory, AResourceName: string): string;
var
  LKey: string;
  LValue: string;
begin
  LKey := ASQLDirectory + AResourceName;

  FLock.Enter;
  try
    if FCache.TryGetValue(LKey, LValue) then
      Exit(LValue);
  finally
    FLock.Leave;
  end;

  Result := GetInternal(ASQLDirectory, AResourceName);

  // Double-checked locking: another thread may have loaded it while we were in GetInternal
  FLock.Enter;
  try
    if FCache.TryGetValue(LKey, LValue) then
      Exit(LValue);

    FCache.Add(LKey, Result);
  finally
    FLock.Leave;
  end;
end;

class function TSQLLoader.GetInternal(ASQLDirectory, AResourceName: string): string;
var
  RS: TResourceStream;
  SL: TStringList;
  RSName: string;
begin
  Result := '';

  RSName := 'SQL_'
    + ASQLDirectory + '_'
    + StringReplace(AResourceName, '.', '_', [rfReplaceAll]);

  if FindResource(HInstance, PChar(RSName), SQL_RESOURCE_TYPE) = 0 then
    raise ESQLLoaderException.CreateFmt(
      'SQL resource not found: %s. Looked for: %s',
      [AResourceName, RSName]
    );

  RS := TResourceStream.Create(HInstance, RSName, SQL_RESOURCE_TYPE);
  SL := TStringList.Create;
  try
    SL.LoadFromStream(RS, TEncoding.UTF8);
    Result := SL.Text;
  finally
    SL.Free;
    RS.Free;
  end;
end;

end.
