unit PascalDb.SqlLoader;

{$I pascaldb.inc}

(* SQL lives in files, not in code: TSQLLoader asks an ISqlSource for the text
  of <DIRECTORY>/<NAME> (see PascalDb.SqlSources — embedded resources by
  default, or a directory, memory, or a composite of those), caches it per
  loader (thread-safe), and TSQLResult processes the template before
  execution:

  - [TAG {] ... [} TAG] — block kept or removed by ProcessTag(TAG, Keep); the
    same tag may appear in several places and one call decides all of them;
  - ${LITERAL} — replaced by ReplaceLiteral (ApplyOperator/ApplyFilter are
    shortcuts for the _OP suffix);
  - [COMMENTS {] ... [} COMMENTS] blocks are removed when .SQL is read; a
    tag nobody processed loses only its markers, and its content STAYS in the
    SQL (a forgotten ProcessTag leaves, e.g., a :PARAM nobody binds).

  The text is returned exactly as stored (original line endings, no trailing
  line break added); a leading UTF-8 BOM is dropped.

  This comment uses parenthesis-asterisk instead of braces because it quotes
  the tag syntax, which contains "}" and would close a brace comment. *)

interface

uses
  Classes,
  SysUtils,
  StrUtils,
  SyncObjs,
  Generics.Collections,
  PascalDb.SqlSources;

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
    FSQLDirectory: string;
    FSource: ISqlSource;
    FCache: TSQLCache;
    FLock: TCriticalSection;
    function LoadText(const AResourceName: string): string;
  protected
    function GetSql(const AResourceName: string): TSQLResult; virtual;
  public
    /// ASQLDirectory: the logical SQL directory (e.g. 'FB', 'PG') — the
    /// first part of the resource name / the sub-folder on disk.
    /// ASource: where the text comes from; nil = TResourceSqlSource.
    constructor Create(const ASQLDirectory: string; const ASource: ISqlSource = nil);
    destructor Destroy; override;
    /// Drops the cached texts (each loader caches what it has loaded).
    procedure ClearCache;
    property SQLDirectory: string read FSQLDirectory;
    property Source: ISqlSource read FSource;
    property Sql[const AResourceName: string]: TSQLResult read GetSql; default;
  end;

implementation

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

constructor TSQLLoader.Create(const ASQLDirectory: string; const ASource: ISqlSource);
begin
  inherited Create;
  FSQLDirectory := ASQLDirectory;
  if Assigned(ASource) then
    FSource := ASource
  else
    FSource := TResourceSqlSource.Create;
  FCache := TSQLCache.Create;
  FLock := TCriticalSection.Create;
end;

destructor TSQLLoader.Destroy;
begin
  FCache.Free;
  FLock.Free;
  inherited;
end;

procedure TSQLLoader.ClearCache;
begin
  FLock.Enter;
  try
    FCache.Clear;
  finally
    FLock.Leave;
  end;
end;

function TSQLLoader.LoadText(const AResourceName: string): string;
var
  LKey: string;
  LValue: string;
begin
  if (FSQLDirectory = '') or (AResourceName = '') then
    raise ESQLLoaderException.Create('The SQL directory and the SQL name are required');

  LKey := UpperCase(AResourceName);

  FLock.Enter;
  try
    if FCache.TryGetValue(LKey, LValue) then
      Exit(LValue);
  finally
    FLock.Leave;
  end;

  if not FSource.TryGetSql(FSQLDirectory, AResourceName, Result) then
    raise ESQLLoaderException.CreateFmt('SQL not found: %s/%s. Looked in: %s',
      [FSQLDirectory, AResourceName, FSource.Describe(FSQLDirectory, AResourceName)]);

  // Double-checked locking: another thread may have loaded it meanwhile
  FLock.Enter;
  try
    if FCache.TryGetValue(LKey, LValue) then
      Exit(LValue);
    FCache.Add(LKey, Result);
  finally
    FLock.Leave;
  end;
end;

function TSQLLoader.GetSql(const AResourceName: string): TSQLResult;
begin
  Result := TSQLResult.From(LoadText(AResourceName));
end;

end.
