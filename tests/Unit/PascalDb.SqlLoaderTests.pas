unit PascalDb.SqlLoaderTests;

{ Tests for SQL template processing (TSQLResult, in PascalDb.SqlLoader):
  ProcessTag keeping and removing blocks, repeated tags, optional spaces in
  both markers, pairing each opening with its own closing, the errors for
  malformed blocks, removal of COMMENTS and of leftover tags, ReplaceLiteral,
  ApplyOperator and ApplyFilter. Resource loading is not covered.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalDb.DUnitXCompat,
  SysUtils,
  PascalDb.SqlLoader;

type
  [TestFixture]
  TSQLLoaderTests = class
  public
    { ProcessTag: removes the block when Keep=False }
    [Test] procedure Test_ProcessTag_False_RemovesBlock;

    { ProcessTag: keeps the content and removes only the tags when Keep=True }
    [Test] procedure Test_ProcessTag_True_KeepsContent;

    { GetSQL: unprocessed tags are removed automatically }
    [Test] procedure Test_GetSQL_CleansLeftoverTags;

    { ProcessTag: the same tag appearing twice in the SQL }
    [Test] procedure Test_ProcessTag_Twice_Keep;

    { GetSQL: the COMMENTS tag is always removed }
    [Test] procedure Test_GetSQL_CommentRemoved;

    { ProcessTag: opening tag with multiple spaces, Keep=False }
    [Test] procedure Test_ProcessTag_MultipleSpaces_False;

    { ProcessTag: opening tag with multiple spaces, Keep=True }
    [Test] procedure Test_ProcessTag_MultipleSpaces_True;

    (* ProcessTag: the closing marker accepts no space or several, like the
       opening one: [}FILTER], [}   FILTER ] *)
    [Test] procedure Test_ProcessTag_ClosingSpaces_False;
    [Test] procedure Test_ProcessTag_ClosingSpaces_True;

    (* ProcessTag: spaces after the opening bracket: [ FILTER{] *)
    [Test] procedure Test_ProcessTag_SpaceAfterOpeningBracket;

    { ProcessTag: a tag whose name starts with another tag's name is left alone }
    [Test] procedure Test_ProcessTag_LongerTagNameUntouched;

    { ProcessTag(False): removes each block, never the SQL between two blocks }
    [Test] procedure Test_ProcessTag_KeepsSqlBetweenBlocks;

    { GetSQL: leftover markers are removed whatever their spacing }
    [Test] procedure Test_GetSQL_CleansLeftoverTags_AnySpacing;

    { ProcessTag: a closing marker before any opening one raises (it used to loop forever) }
    [Test] procedure Test_ProcessTag_ClosingBeforeOpening_Raises;

    { ProcessTag: an opening marker with no closing one raises }
    [Test] procedure Test_ProcessTag_MissingClosing_Raises;

    { ProcessTag: a block nested in a block of the same tag raises }
    [Test] procedure Test_ProcessTag_Nested_Raises;

    (* ReplaceLiteral: replaces ${TAG} with the given value *)
    [Test] procedure Test_ReplaceLiteral_Simple;

    (* ApplyOperator: replaces ${TAG_OP} with the operator *)
    [Test] procedure Test_ApplyOperator;

    { ApplyFilter: combines ProcessTag + ReplaceLiteral when HasValue=True }
    [Test] procedure Test_ApplyFilter_WithValue;

    { ApplyFilter: removes the block when HasValue=False }
    [Test] procedure Test_ApplyFilter_WithoutValue;
  end;

implementation

const
  SQL_TAGS =
    'SELECT * FROM CUSTOMERS WHERE 1=1 [FILTER {]AND ACTIVE = ''S''[} FILTER]';

  SQL_TAGS_MULTISPACE =
    'SELECT * FROM CUSTOMERS WHERE 1=1 [FILTER    {]AND ACTIVE = ''S''[} FILTER]';

  SQL_SAME_TAG_TWICE =
    'SELECT * FROM CUSTOMERS WHERE 1=1 [FILTER {] AND 2=2 [} FILTER] [FILTER {] AND 3=3 [} FILTER]';

  SQL_COMMENTS =
    'SELECT * FROM CUSTOMERS [COMMENTS {] This is a comment [} COMMENTS]';

  SQL_LITERAL =
    'SELECT * FROM ${TABLE} WHERE FIELD ${FIELD_OP} :FIELD';

// The message of the ESQLLoaderException ProcessTag raised, or '' if none.
function ProcessTagError(const ASql, ATag: string; AKeep: Boolean): string;
begin
  Result := '';
  try
    TSQLResult.From(ASql).ProcessTag(ATag, AKeep);
  except
    on E: ESQLLoaderException do
      Result := E.Message;
  end;
end;

{ TSQLLoaderTests }

procedure TSQLLoaderTests.Test_ProcessTag_False_RemovesBlock;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_TAGS).ProcessTag('FILTER', False).SQL;
  TAssert.AssertEquals('ProcessTag(False) must remove the whole block', 'SELECT * FROM CUSTOMERS WHERE 1=1', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ProcessTag_True_KeepsContent;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_TAGS).ProcessTag('FILTER', True).SQL;
  TAssert.AssertEquals('ProcessTag(True) must keep the content and remove the tags', 'SELECT * FROM CUSTOMERS WHERE 1=1 AND ACTIVE = ''S''', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_GetSQL_CleansLeftoverTags;
var
  LResult: string;
begin
  // Without calling ProcessTag: GetSQL must remove the leftover tags, keeping the content
  LResult := TSQLResult.From(SQL_TAGS).SQL;
  TAssert.AssertEquals('GetSQL must clean unprocessed tags, keeping the content', 'SELECT * FROM CUSTOMERS WHERE 1=1 AND ACTIVE = ''S''', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ProcessTag_Twice_Keep;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_SAME_TAG_TWICE)
    .ProcessTag('FILTER', True)
    .SQL;
  TAssert.AssertEquals('ProcessTag(True) must process every occurrence of the same tag', 'SELECT * FROM CUSTOMERS WHERE 1=1  AND 2=2   AND 3=3', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_GetSQL_CommentRemoved;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_COMMENTS).SQL;
  TAssert.AssertEquals('The COMMENTS block must be removed automatically by GetSQL', 'SELECT * FROM CUSTOMERS', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ProcessTag_MultipleSpaces_False;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_TAGS_MULTISPACE).ProcessTag('FILTER', False).SQL;
  TAssert.AssertEquals('ProcessTag(False) must recognize tags with extra spaces before {]', 'SELECT * FROM CUSTOMERS WHERE 1=1', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ProcessTag_MultipleSpaces_True;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_TAGS_MULTISPACE).ProcessTag('FILTER', True).SQL;
  TAssert.AssertEquals('ProcessTag(True) must keep the content even with extra spaces in the opening tag', 'SELECT * FROM CUSTOMERS WHERE 1=1 AND ACTIVE = ''S''', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ProcessTag_ClosingSpaces_False;
var
  LResult: string;
begin
  LResult := TSQLResult.From('W [FILTER {]A[}FILTER] X [FILTER {]B[}   FILTER ] Y')
    .ProcessTag('FILTER', False).SQL;
  TAssert.AssertEquals('ProcessTag(False) must recognize closing markers with no space or several', 'W  X  Y', LResult);
end;

procedure TSQLLoaderTests.Test_ProcessTag_ClosingSpaces_True;
var
  LResult: string;
begin
  LResult := TSQLResult.From('W [FILTER {]A[}FILTER] X [FILTER {]B[}   FILTER ] Y')
    .ProcessTag('FILTER', True).SQL;
  TAssert.AssertEquals('ProcessTag(True) must remove closing markers with no space or several', 'W A X B Y', LResult);
end;

procedure TSQLLoaderTests.Test_ProcessTag_SpaceAfterOpeningBracket;
var
  LResult: string;
begin
  LResult := TSQLResult.From('W [ FILTER{]A[} FILTER] Y').ProcessTag('FILTER', True).SQL;
  TAssert.AssertEquals('ProcessTag must accept spaces between [ and the tag name', 'W A Y', LResult);
end;

procedure TSQLLoaderTests.Test_ProcessTag_LongerTagNameUntouched;
var
  LResult: string;
begin
  LResult := TSQLResult.From('W [FILTER_X {]A[} FILTER_X] Y').ProcessTag('FILTER', False).SQL;
  TAssert.AssertEquals('ProcessTag(FILTER) must not touch a FILTER_X block', 'W A Y', LResult);
end;

procedure TSQLLoaderTests.Test_ProcessTag_KeepsSqlBetweenBlocks;
var
  LResult: string;
begin
  LResult := TSQLResult.From('W [F {]A[}F] X [F {]B[} F] Y').ProcessTag('F', False).SQL;
  TAssert.AssertEquals('ProcessTag(False) must keep the SQL between two blocks', 'W  X  Y', LResult);
end;

procedure TSQLLoaderTests.Test_GetSQL_CleansLeftoverTags_AnySpacing;
var
  LResult: string;
begin
  LResult := TSQLResult.From('W [FILTER{]A[}FILTER] X [ OTHER  {]B[}  OTHER ] Y').SQL;
  TAssert.AssertEquals('GetSQL must remove leftover markers whatever their spacing', 'W A X B Y', LResult);
end;

procedure TSQLLoaderTests.Test_ProcessTag_ClosingBeforeOpening_Raises;
var
  LMessage: string;
begin
  LMessage := ProcessTagError('W [} F] X [F {]B[} F] Y', 'F', False);
  TAssert.AssertTrue('A closing marker before any opening must raise ESQLLoaderException', LMessage <> '');
  TAssert.AssertTrue('The message must name the tag', Pos('SQL tag F:', LMessage) > 0);
end;

procedure TSQLLoaderTests.Test_ProcessTag_MissingClosing_Raises;
var
  LMessage: string;
begin
  LMessage := ProcessTagError('W [F {]A[} F] X [F {]B Y', 'F', True);
  TAssert.AssertTrue('An opening marker with no closing must raise ESQLLoaderException', LMessage <> '');
  TAssert.AssertTrue('The message must say the closing marker is missing', Pos('no closing marker', LMessage) > 0);
end;

procedure TSQLLoaderTests.Test_ProcessTag_Nested_Raises;
var
  LMessage: string;
begin
  LMessage := ProcessTagError('W [F {]A [F {]B[} F] C[} F] Y', 'F', False);
  TAssert.AssertTrue('A block nested in a block of the same tag must raise ESQLLoaderException', LMessage <> '');
  TAssert.AssertTrue('The message must say the block is nested', Pos('nested', LMessage) > 0);
end;

procedure TSQLLoaderTests.Test_ReplaceLiteral_Simple;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_LITERAL)
    .ReplaceLiteral('TABLE', 'TB_CUSTOMERS')
    .SQL;
  TAssert.AssertTrue('ReplaceLiteral must replace ${TABLE} with TB_CUSTOMERS', Pos('TB_CUSTOMERS', LResult) > 0);
  TAssert.AssertTrue('The ${TABLE} marker must no longer exist after ReplaceLiteral', Pos('${TABLE}', LResult) = 0);
end;

procedure TSQLLoaderTests.Test_ApplyOperator;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_LITERAL)
    .ApplyOperator('FIELD', '=')
    .SQL;
  TAssert.AssertTrue('ApplyOperator must replace ${FIELD_OP}', Pos('${FIELD_OP}', LResult) = 0);
  TAssert.AssertTrue('The = operator must have been inserted', Pos('= :FIELD', LResult) > 0);
end;

procedure TSQLLoaderTests.Test_ApplyFilter_WithValue;
var
  LResult: string;
begin
  // HasValue=True: keeps the block and replaces the operator
  LResult := TSQLResult.From(SQL_TAGS)
    .ApplyFilter('FILTER', '=', True)
    .SQL;
  TAssert.AssertEquals('ApplyFilter(True) must keep the FILTER block', 'SELECT * FROM CUSTOMERS WHERE 1=1 AND ACTIVE = ''S''', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ApplyFilter_WithoutValue;
var
  LResult: string;
begin
  // HasValue=False: removes the whole block
  LResult := TSQLResult.From(SQL_TAGS)
    .ApplyFilter('FILTER', '=', False)
    .SQL;
  TAssert.AssertEquals('ApplyFilter(False) must remove the FILTER block', 'SELECT * FROM CUSTOMERS WHERE 1=1', Trim(LResult));
end;

initialization
  TDUnitX.RegisterTestFixture(TSQLLoaderTests);

end.
