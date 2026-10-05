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

  Both markers follow one rule, in ProcessTag and in the cleanup alike:
  spaces are optional around the tag name, so [TAG{], [ TAG {], [}TAG] and
  [} TAG ] are all valid. ProcessTag pairs each opening marker with the next
  closing one and raises ESQLLoaderException on a closing marker with no
  opening before it, an opening with no closing after it, or the same tag
  nested in itself. It used to look both markers up from the start of the
  text independently: a closing marker it didn't recognize (it wanted
  exactly one space) made it pair an opening with another block's closing
  and delete the SQL between them, or loop forever when that closing came
  first.

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

function IsTagNameChar(C: Char): Boolean;
begin
  Result := not ((C = ' ') or (C = #9) or (C = #10) or (C = #13) or
    (C = '[') or (C = ']') or (C = '{') or (C = '}'));
end;

procedure SkipSpaces(const S: string; var I: Integer);
begin
  while (I <= Length(S)) and (S[I] = ' ') do
    Inc(I);
end;

// S[AStart] is '['. Opening marker: [ name {]; closing marker: [} name ];
// spaces optional around the name. AName = '' matches any name. On a match,
// AEnd is the index of the marker's last character (its ']').
function MatchMarker(const S, AName: string; AOpening: Boolean;
  AStart: Integer; out AEnd: Integer): Boolean;
var
  J, LNameStart: Integer;
begin
  Result := False;
  AEnd := 0;
  J := AStart + 1;
  if not AOpening then
  begin
    if (J > Length(S)) or (S[J] <> '}') then Exit;
    Inc(J);
  end;
  SkipSpaces(S, J);
  if AName <> '' then
  begin
    if Copy(S, J, Length(AName)) <> AName then Exit;
    Inc(J, Length(AName));
  end
  else
  begin
    LNameStart := J;
    while (J <= Length(S)) and IsTagNameChar(S[J]) do
      Inc(J);
    if J = LNameStart then Exit;
  end;
  SkipSpaces(S, J);
  if AOpening then
  begin
    if (J >= Length(S)) or (S[J] <> '{') or (S[J + 1] <> ']') then Exit;
    Inc(J);
  end
  else if (J > Length(S)) or (S[J] <> ']') then
    Exit;
  AEnd := J;
  Result := True;
end;

// First marker at or after AFrom; AStart = 0 when there is none.
function FindMarker(const S, AName: string; AOpening: Boolean; AFrom: Integer;
  out AStart, AEnd: Integer): Boolean;
begin
  AStart := PosEx('[', S, AFrom);
  while AStart > 0 do
  begin
    if MatchMarker(S, AName, AOpening, AStart, AEnd) then
      Exit(True);
    AStart := PosEx('[', S, AStart + 1);
  end;
  AEnd := 0;
  Result := False;
end;

function TSQLResult.ProcessTag(const ATag: string; Keep: Boolean): TSQLResult;
var
  LFrom, LOpenStart, LOpenEnd, LCloseStart, LCloseEnd, LNextStart, LNextEnd: Integer;
begin
  if ATag = '' then
    raise ESQLLoaderException.Create('ProcessTag: the tag name is required');

  // Everything before LFrom has been processed and holds no marker of ATag.
  LFrom := 1;
  while True do
  begin
    if not FindMarker(FSQL, ATag, True, LFrom, LOpenStart, LOpenEnd) then
    begin
      if FindMarker(FSQL, ATag, False, LFrom, LCloseStart, LCloseEnd) then
        raise ESQLLoaderException.CreateFmt(
          'SQL tag %s: closing marker with no opening marker before it', [ATag]);
      Break;
    end;

    if FindMarker(FSQL, ATag, False, LFrom, LCloseStart, LCloseEnd) and
       (LCloseStart < LOpenStart) then
      raise ESQLLoaderException.CreateFmt(
        'SQL tag %s: closing marker with no opening marker before it', [ATag]);

    if not FindMarker(FSQL, ATag, False, LOpenEnd + 1, LCloseStart, LCloseEnd) then
      raise ESQLLoaderException.CreateFmt(
        'SQL tag %s: opening marker with no closing marker after it', [ATag]);

    if FindMarker(FSQL, ATag, True, LOpenEnd + 1, LNextStart, LNextEnd) and
       (LNextStart < LCloseStart) then
      raise ESQLLoaderException.CreateFmt(
        'SQL tag %s: a block of this tag is nested in another one', [ATag]);

    if Keep then
    begin
      Delete(FSQL, LCloseStart, LCloseEnd - LCloseStart + 1);
      Delete(FSQL, LOpenStart, LOpenEnd - LOpenStart + 1);
      LFrom := LCloseStart - (LOpenEnd - LOpenStart + 1);
    end
    else
    begin
      Delete(FSQL, LOpenStart, LCloseEnd - LOpenStart + 1);
      LFrom := LOpenStart;
    end;
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
  LStart, LEnd: Integer;
begin
  ProcessTag('COMMENTS', False);

  Result := FSQL;

  // Leftover markers of tags nobody processed: drop the markers, keep the content
  LStart := 1;
  while FindMarker(Result, '', True, LStart, LStart, LEnd) do
    Delete(Result, LStart, LEnd - LStart + 1);

  LStart := 1;
  while FindMarker(Result, '', False, LStart, LStart, LEnd) do
    Delete(Result, LStart, LEnd - LStart + 1);
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
