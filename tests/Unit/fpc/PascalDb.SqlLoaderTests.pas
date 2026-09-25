unit PascalDb.SqlLoaderTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.SqlLoaderTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for SQL template processing (TSQLResult, in PascalDb.SqlLoader):
  ProcessTag keeping and removing blocks, repeated tags, extra spaces in the
  tag, removal of COMMENTS and of leftover tags, ReplaceLiteral,
  ApplyOperator and ApplyFilter. Resource loading is not covered.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalDb.SqlLoader;

type
  TSQLLoaderTests = class(TTestCase)
  published
    { ProcessTag: removes the block when Keep=False }
    procedure Test_ProcessTag_False_RemovesBlock;

    { ProcessTag: keeps the content and removes only the tags when Keep=True }
    procedure Test_ProcessTag_True_KeepsContent;

    { GetSQL: unprocessed tags are removed automatically }
    procedure Test_GetSQL_CleansLeftoverTags;

    { ProcessTag: the same tag appearing twice in the SQL }
    procedure Test_ProcessTag_Twice_Keep;

    { GetSQL: the COMMENTS tag is always removed }
    procedure Test_GetSQL_CommentRemoved;

    { ProcessTag: opening tag with multiple spaces, Keep=False }
    procedure Test_ProcessTag_MultipleSpaces_False;

    { ProcessTag: opening tag with multiple spaces, Keep=True }
    procedure Test_ProcessTag_MultipleSpaces_True;

    (* ReplaceLiteral: replaces ${TAG} with the given value *)
    procedure Test_ReplaceLiteral_Simple;

    (* ApplyOperator: replaces ${TAG_OP} with the operator *)
    procedure Test_ApplyOperator;

    { ApplyFilter: combines ProcessTag + ReplaceLiteral when HasValue=True }
    procedure Test_ApplyFilter_WithValue;

    { ApplyFilter: removes the block when HasValue=False }
    procedure Test_ApplyFilter_WithoutValue;
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
  RegisterTest(TSQLLoaderTests);

end.
