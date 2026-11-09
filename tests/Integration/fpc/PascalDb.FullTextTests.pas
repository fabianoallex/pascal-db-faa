unit PascalDb.FullTextTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Integration/PascalDb.FullTextTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for full-text search against a real database (PascalDb.IntegrationEnv,
  PASCALDB_IT_ENGINE), with the reference SQL of docs/fulltext/sql as an
  application would copy it: the database's folder (PG, MYSQL, SQLITE, FB or
  MSSQL), through a TDirectorySqlSource. So each run checks the values
  PdbFullTextQuery writes and that database's index and query together. The
  ARTICLES table comes from the folder's FULLTEXT.SCHEMA (statements ended by
  a caret line), created once per run; each test starts with the same five
  rows. Where the dialect has no full-text search (Firebird, SQL Server) the
  search goes through LIKE with PdbLikeContains, as docs/fulltext.md says.

  Covered: all words, any word with the best match first, a prefix on the
  last word, case and accents, stopwords in the text, hostile input with
  every combination of the options (operators, quotes, emoji, a very long
  word: none may fail), text with nothing to search for, updates and
  deletes reaching the index, and a row written in the same transaction,
  which MySQL and MariaDB don't see before the commit. The pure parts (the
  words, each syntax) are in the unit suite's PascalDb.FullTextTests.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Integration/fpc is generated
  from the master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.FullText;

type
  TFullTextTests = class(TTestCase)
  private
    FFactory: IDBFactory;
    function NativeSearch: Boolean;
    function SearchIn(const AQuery: IQuery; const AScope: IScopeTransaction; const AText: string;
      const AOptions: TFullTextOptions; ASorted: Boolean): string;
    function Search(const AText: string; const AOptions: TFullTextOptions; ASorted: Boolean = True): string; overload;
    function Search(const AText: string): string; overload;
    procedure Exec(const ASql: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SupportsFullText_ByDatabase;
    procedure Search_AllWords;
    procedure Search_AnyWord_BestMatchFirst;
    procedure Search_PrefixLastWord;
    procedure Search_IgnoresCaseAndAccents;
    procedure Search_StopwordsInTheText;
    procedure Search_HostileInput_NeverFails;
    procedure Search_NothingToSearch_EmptyValue;
    procedure Search_FollowsUpdatesAndDeletes;
    procedure Search_RowWrittenInTheSameTransaction;
  end;

implementation

uses
  Classes,
  PascalDb.SqlSources,
  PascalDb.SqlLoader,
  PascalDb.IntegrationEnv;

const
  REFERENCE_SQL = 'docs' + PathDelim + 'fulltext' + PathDelim + 'sql';
  LOCK_TIMEOUT_MS = 5000;

var
  GSchemaReady: Boolean = False;

// docs/fulltext/sql, looked for from the executable's folder upwards.
function ReferenceSqlFolder: string;
var
  LDir: string;
  I: Integer;
begin
  LDir := ExtractFilePath(ParamStr(0));
  for I := 0 to 6 do
  begin
    if DirectoryExists(LDir + REFERENCE_SQL) then
      Exit(LDir + REFERENCE_SQL);
    LDir := ExtractFilePath(ExcludeTrailingPathDelimiter(LDir));
  end;
  raise Exception.CreateFmt('%s not found above %s', [REFERENCE_SQL, ExtractFilePath(ParamStr(0))]);
end;

procedure ExecDdl(const AFactory: IDBFactory; const ASql: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  if Trim(ASql) = '' then
    Exit;
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := ASql;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

// The database's FULLTEXT.SCHEMA, one statement at a time (ended by a line
// holding a caret, as a migration with that terminator would), each
// committed.
procedure CreateSchema(const AFactory: IDBFactory);
var
  LLines: TStringList;
  LStatement: string;
  I: Integer;
begin
  LLines := TStringList.Create;
  try
    LLines.Text := AFactory.SqlLoader['FULLTEXT.SCHEMA'].SQL;
    LStatement := '';
    for I := 0 to LLines.Count - 1 do
      if Trim(LLines[I]) = '^' then
      begin
        ExecDdl(AFactory, LStatement);
        LStatement := '';
      end
      else if Copy(TrimLeft(LLines[I]), 1, 2) <> '--' then
        LStatement := LStatement + LLines[I] + sLineBreak;
    ExecDdl(AFactory, LStatement);
  finally
    LLines.Free;
  end;
end;

procedure InsertArticle(const AQuery: IQuery; AId: Integer; const ATitle, ABody: string);
begin
  AQuery.Sql := 'INSERT INTO ARTICLES (ID, TITLE, BODY) VALUES (:ID, :TITLE, :BODY)';
  AQuery.Params.Integers['ID'] := AId;
  AQuery.Params.Strings['TITLE'] := ATitle;
  AQuery.Params.Strings['BODY'] := ABody;
  AQuery.ExecSql;
end;

function Options(AMatch: TFullTextMatch; APrefix: Boolean): TFullTextOptions;
begin
  Result := TFullTextOptions.Default;
  Result.Match := AMatch;
  Result.PrefixLastWord := APrefix;
end;

{ TFullTextTests }

procedure TFullTextTests.Setup;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  IntegrationFactory;
  FFactory := SqlSourceFactory(TDirectorySqlSource.Create(ReferenceSqlFolder), EngineSqlDirectory,
    LOCK_TIMEOUT_MS);
  if not GSchemaReady then
  begin
    CreateSchema(FFactory);
    GSchemaReady := True;
  end;
  Exec('DELETE FROM ARTICLES');
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    InsertArticle(LQuery, 1, 'Café com leite', 'Bebida quente servida no café da manhã');
    InsertArticle(LQuery, 2, 'Pão de queijo', 'Receita mineira com polvilho');
    InsertArticle(LQuery, 3, 'Café preto', 'Sem açúcar, forte, 50% arábica');
    InsertArticle(LQuery, 4, 'Água de coco', 'Bebida gelada, um copo d''água');
    InsertArticle(LQuery, 5, 'Pé de moleque', 'Doce de amendoim com rapadura');
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TFullTextTests.TearDown;
begin
  FFactory := nil;
end;

procedure TFullTextTests.Exec(const ASql: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := ASql;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

function TFullTextTests.NativeSearch: Boolean;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  Result := PdbSupportsFullText(LScope);
end;

// The ids FULLTEXT.SEARCH returns for AText, comma-separated, in the query's
// order or ascending; '' for no row. Full-text value where the dialect has
// it, a LIKE pattern otherwise.
function TFullTextTests.SearchIn(const AQuery: IQuery; const AScope: IScopeTransaction;
  const AText: string; const AOptions: TFullTextOptions; ASorted: Boolean): string;
var
  LValue: string;
  LResult: IQueryResult;
  LIds: TArray<Integer>;
  I, J, T: Integer;
begin
  Result := '';
  if PdbSupportsFullText(AScope) then
    LValue := PdbFullTextQuery(AScope, AText, AOptions)
  else
    LValue := PdbLikeContains(AText);
  if LValue = '' then
    Exit;
  AQuery.Sql := FFactory.SqlLoader['FULLTEXT.SEARCH'].SQL;
  AQuery.Params.Strings['Q'] := LValue;
  LResult := AQuery.Open;
  SetLength(LIds, 0);
  while not LResult.Eof do
  begin
    SetLength(LIds, Length(LIds) + 1);
    LIds[High(LIds)] := LResult.Integers['ID'];
    LResult.Next;
  end;
  if ASorted then
    for I := 1 to High(LIds) do
    begin
      T := LIds[I];
      J := I - 1;
      while (J >= 0) and (LIds[J] > T) do
      begin
        LIds[J + 1] := LIds[J];
        Dec(J);
      end;
      LIds[J + 1] := T;
    end;
  for I := 0 to High(LIds) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + IntToStr(LIds[I]);
  end;
end;

function TFullTextTests.Search(const AText: string; const AOptions: TFullTextOptions; ASorted: Boolean): string;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    Result := SearchIn(LQuery, LScope, AText, AOptions, ASorted);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

function TFullTextTests.Search(const AText: string): string;
begin
  Result := Search(AText, TFullTextOptions.Default);
end;

procedure TFullTextTests.SupportsFullText_ByDatabase;
var
  LDir: string;
begin
  LDir := EngineSqlDirectory;
  TAssert.AssertEquals(LDir, (LDir <> 'FB') and (LDir <> 'MSSQL'), NativeSearch);
end;

procedure TFullTextTests.Search_AllWords;
begin
  TAssert.AssertEquals('3', Search('café preto'));
  TAssert.AssertEquals('1', Search('Café com leite'));
  TAssert.AssertEquals('', Search('café xyz'));
end;

procedure TFullTextTests.Search_AnyWord_BestMatchFirst;
var
  LIds: string;
begin
  // LIKE matches the text as a whole: there is no "any word"
  if not NativeSearch then
    Exit;
  TAssert.AssertEquals('1,3', Search('leite preto', Options(ftmAnyWord, False)));
  // "café" twice and "leite" in row 1, "café" once in row 3
  LIds := Search('café leite', Options(ftmAnyWord, False), False);
  TAssert.AssertEquals('best match first: ' + LIds, '1,3', LIds);
end;

procedure TFullTextTests.Search_PrefixLastWord;
begin
  TAssert.AssertEquals('2', Search('polvi', Options(ftmAllWords, True)));
  TAssert.AssertEquals('5', Search('moleq', Options(ftmAnyWord, True)));
  if NativeSearch then
  begin
    TAssert.AssertEquals('whole words only without the prefix', '', Search('polvi'));
    TAssert.AssertEquals('2', Search('receita polvi', Options(ftmAllWords, True)));
  end;
end;

procedure TFullTextTests.Search_IgnoresCaseAndAccents;
begin
  TAssert.AssertEquals('1,3', Search('CAFÉ'));
  // LIKE keeps the accents (docs/fulltext.md)
  if NativeSearch then
  begin
    TAssert.AssertEquals('1,3', Search('CAFE'));
    TAssert.AssertEquals('4', Search('agua'));
    TAssert.AssertEquals('3', Search('acucar'));
  end;
end;

procedure TFullTextTests.Search_StopwordsInTheText;
begin
  // a stopword on MySQL/MariaDB and PostgreSQL, an ordinary word on SQLite
  TAssert.AssertEquals('2', Search('pão de queijo'));
end;

procedure TFullTextTests.Search_HostileInput_NeverFails;
const
  INPUTS: array[0..21] of string = (
    '"café', 'café)', '-café', 'café -preto', 'caf*', '*', '+', 'café OR leite',
    'NEAR(café preto)', 'a & b', 'café:*', '50%', 'd''água', '!(x) <-> y', '\''', '@2 ~x <y >z',
    '😀', 'café 😀', '«café»—preto…', 'Café-com-leite', '', '   ');
var
  LInput, LLong: string;
  K: Integer;

  procedure Check(const AText: string);
  var
    LOptions: TFullTextOptions;
    K2: Integer;
  begin
    for K2 := 0 to 3 do
    begin
      LOptions := Options(TFullTextMatch(K2 div 2), Odd(K2));
      try
        Search(AText, LOptions);
      except
        on E: Exception do
          TAssert.Fail(Format('[%s] match=%d prefix=%s: %s: %s', [Copy(AText, 1, 40), K2 div 2,
            BoolToStr(Odd(K2), True), E.ClassName, DescribeDriverError(E)]));
      end;
    end;
  end;

begin
  for LInput in INPUTS do
    Check(LInput);
  LLong := '';
  for K := 1 to 3000 do
    LLong := LLong + 'a';
  Check('café ' + LLong);
end;

procedure TFullTextTests.Search_NothingToSearch_EmptyValue;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  if not NativeSearch then
    Exit;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  TAssert.AssertEquals('', PdbFullTextQuery(LScope, '"*+ () -'));
  TAssert.AssertEquals('', PdbFullTextQuery(LScope, '😀'));
end;

procedure TFullTextTests.Search_FollowsUpdatesAndDeletes;
begin
  Exec('UPDATE ARTICLES SET BODY = ''Receita mineira, acompanha goiabada'' WHERE ID = 2');
  TAssert.AssertEquals('2', Search('goiabada'));
  TAssert.AssertEquals('', Search('polvilho'));
  Exec('DELETE FROM ARTICLES WHERE ID = 2');
  TAssert.AssertEquals('', Search('goiabada'));
  TAssert.AssertEquals('', Search('queijo'));
end;

procedure TFullTextTests.Search_RowWrittenInTheSameTransaction;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LExpected: string;
begin
  // InnoDB's full-text index only sees committed rows (docs/fulltext.md)
  if EngineSqlDirectory = 'MYSQL' then
    LExpected := ''
  else
    LExpected := '99';
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    InsertArticle(LQuery, 99, 'Xícara nova', 'Porcelana branca');
    TAssert.AssertEquals('before the commit', LExpected,
      SearchIn(LQuery, LScope, 'porcelana', TFullTextOptions.Default, True));
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  TAssert.AssertEquals('after the commit', '99', Search('porcelana'));
end;

initialization
  RegisterTest(TFullTextTests);

end.
