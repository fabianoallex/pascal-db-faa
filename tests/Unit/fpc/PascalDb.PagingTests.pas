unit PascalDb.PagingTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.PagingTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for offset paging without a database (PascalDb.Paging): how
  TPageRequest normalizes page and limit, the offset of a large page,
  TPageMeta's page count and next/previous flags, the clause each built-in
  dialect generates, the refusals (a page not built by TPageRequest.Create,
  a dialect without IPagingDialect, a scope without a connection), and
  PdbPagingClause on a TMockDBFactory scope. The clause running on each
  database is covered by the integration contract tests.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlDialect,
  PascalDb.Mock,
  PascalDb.Paging;

type
  { TNoPagingDialect
    A dialect registered before IPagingDialect existed. }
  TNoPagingDialect = class(TInterfacedObject, ISQLDialect)
  public
    function GetSavepointSQL(const AName: string): string;
    function GetRollbackToSavepointSQL(const AName: string): string;
    function GetReleaseSavepointSQL(const AName: string): string;
    function SupportsRelease: Boolean;
    function GetPingSQL: string;
  end;

  TPagingTests = class(TTestCase)
  published
    procedure Request_MissingValues_UseDefaults;
    procedure Request_LimitAboveMax_IsCapped;
    procedure Request_DefaultAboveMax_IsCapped;
    procedure Request_MaxBelowOne_Raises;
    procedure Request_Offset_LargePageDoesNotOverflow;
    procedure Meta_PartialLastPage;
    procedure Meta_ExactMultiple;
    procedure Meta_EmptyResult_HasOnePage;
    procedure Clause_EachBuiltInDialect;
    procedure Clause_Firebird_FirstPage;
    procedure Clause_PageNotFromCreate_Raises;
    procedure Clause_DialectWithoutPaging_Raises;
    procedure Clause_MockScope;
    procedure DialectOf_NilScope_Raises;
    procedure Page_HoldsItemsAndMeta;
  end;

implementation

{ TNoPagingDialect }

function TNoPagingDialect.GetSavepointSQL(const AName: string): string;           begin Result := ''; end;
function TNoPagingDialect.GetRollbackToSavepointSQL(const AName: string): string; begin Result := ''; end;
function TNoPagingDialect.GetReleaseSavepointSQL(const AName: string): string;    begin Result := ''; end;
function TNoPagingDialect.SupportsRelease: Boolean;                               begin Result := False; end;
function TNoPagingDialect.GetPingSQL: string;                                     begin Result := 'SELECT 1'; end;

{ TPagingTests }

procedure TPagingTests.Request_MissingValues_UseDefaults;
var
  LPage: TPageRequest;
begin
  LPage := TPageRequest.Create(0, 0);
  TAssert.AssertEquals('Page', 1, LPage.Page);
  TAssert.AssertEquals('Limit', PDB_PAGE_DEFAULT_LIMIT, LPage.Limit);
  TAssert.AssertEquals('Offset', Int64(0), LPage.Offset);

  LPage := TPageRequest.Create(-3, -5, 10, 50);
  TAssert.AssertEquals('Negative page', 1, LPage.Page);
  TAssert.AssertEquals('Negative limit', 10, LPage.Limit);
end;

procedure TPagingTests.Request_LimitAboveMax_IsCapped;
var
  LPage: TPageRequest;
begin
  LPage := TPageRequest.Create(3, 500);
  TAssert.AssertEquals('Page', 3, LPage.Page);
  TAssert.AssertEquals('Limit', PDB_PAGE_MAX_LIMIT, LPage.Limit);
  TAssert.AssertEquals('Offset', Int64(2 * PDB_PAGE_MAX_LIMIT), LPage.Offset);
end;

procedure TPagingTests.Request_DefaultAboveMax_IsCapped;
begin
  TAssert.AssertEquals('Limit', 30, TPageRequest.Create(1, 0, 50, 30).Limit);
end;

procedure TPagingTests.Request_MaxBelowOne_Raises;
begin
  try
    TPageRequest.Create(1, 10, 10, 0);
    TAssert.Fail('AMaxLimit = 0 must raise');
  except
    on E: EArgumentException do
      TAssert.AssertTrue('The message must name AMaxLimit: ' + E.Message, Pos('AMaxLimit', E.Message) > 0);
  end;
end;

procedure TPagingTests.Request_Offset_LargePageDoesNotOverflow;
begin
  TAssert.AssertEquals('Offset', Int64(MaxInt - 1) * 100, TPageRequest.Create(MaxInt, 100).Offset);
end;

procedure TPagingTests.Meta_PartialLastPage;
var
  LMeta: TPageMeta;
begin
  LMeta := TPageMeta.Create(TPageRequest.Create(1, 20), 45);
  TAssert.AssertEquals('TotalPages', Int64(3), LMeta.TotalPages);
  TAssert.AssertTrue('Page 1 has a next page', LMeta.HasNext);
  TAssert.AssertFalse('Page 1 has no previous page', LMeta.HasPrev);

  LMeta := TPageMeta.Create(TPageRequest.Create(3, 20), 45);
  TAssert.AssertFalse('Page 3 has no next page', LMeta.HasNext);
  TAssert.AssertTrue('Page 3 has a previous page', LMeta.HasPrev);
end;

procedure TPagingTests.Meta_ExactMultiple;
var
  LMeta: TPageMeta;
begin
  LMeta := TPageMeta.Create(TPageRequest.Create(2, 20), 40);
  TAssert.AssertEquals('TotalPages', Int64(2), LMeta.TotalPages);
  TAssert.AssertFalse('The last full page has no next page', LMeta.HasNext);
end;

procedure TPagingTests.Meta_EmptyResult_HasOnePage;
var
  LMeta: TPageMeta;
begin
  LMeta := TPageMeta.Create(TPageRequest.Create(1, 20), 0);
  TAssert.AssertEquals('TotalPages', Int64(1), LMeta.TotalPages);
  TAssert.AssertFalse('HasNext', LMeta.HasNext);
  TAssert.AssertFalse('HasPrev', LMeta.HasPrev);
end;

procedure TPagingTests.Clause_EachBuiltInDialect;
var
  LPage: TPageRequest;
begin
  LPage := TPageRequest.Create(3, 20);
  TAssert.AssertEquals('PostgreSQL', 'LIMIT 20 OFFSET 40',
    PdbPagingClause(TSQLDialectFactory.GetDialect('PostgreSQL'), LPage));
  TAssert.AssertEquals('SQLite', 'LIMIT 20 OFFSET 40',
    PdbPagingClause(TSQLDialectFactory.GetDialect('SQLite'), LPage));
  TAssert.AssertEquals('MySQL', 'LIMIT 20 OFFSET 40',
    PdbPagingClause(TSQLDialectFactory.GetDialect('MySQL'), LPage));
  TAssert.AssertEquals('MariaDB', 'LIMIT 20 OFFSET 40',
    PdbPagingClause(TSQLDialectFactory.GetDialect('MariaDB'), LPage));
  TAssert.AssertEquals('Firebird', 'ROWS 41 TO 60',
    PdbPagingClause(TSQLDialectFactory.GetDialect('Firebird'), LPage));
  TAssert.AssertEquals('SQL Server', 'OFFSET 40 ROWS FETCH NEXT 20 ROWS ONLY',
    PdbPagingClause(TSQLDialectFactory.GetDialect('SQLServer'), LPage));
end;

procedure TPagingTests.Clause_Firebird_FirstPage;
begin
  TAssert.AssertEquals('ROWS 1 TO 10',
    PdbPagingClause(TSQLDialectFactory.GetDialect('Firebird'), TPageRequest.Create(1, 10)));
end;

procedure TPagingTests.Clause_PageNotFromCreate_Raises;
begin
  try
    PdbPagingClause(TSQLDialectFactory.GetDialect('PostgreSQL'), Default(TPageRequest));
    TAssert.Fail('A page with Limit = 0 must raise');
  except
    on E: EArgumentException do
      TAssert.AssertTrue('The message must point to TPageRequest.Create: ' + E.Message,
        Pos('TPageRequest.Create', E.Message) > 0);
  end;
end;

procedure TPagingTests.Clause_DialectWithoutPaging_Raises;
begin
  try
    PdbPagingClause(TNoPagingDialect.Create as ISQLDialect, TPageRequest.Create(1, 10));
    TAssert.Fail('A dialect without IPagingDialect must raise');
  except
    on E: EArgumentException do
      TAssert.AssertTrue('The message must name IPagingDialect: ' + E.Message,
        Pos('IPagingDialect', E.Message) > 0);
  end;
end;

procedure TPagingTests.Clause_MockScope;
var
  LFactory: IDBFactory;
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LFactory := TMockDBFactory.Create;
  LScope := LFactory.GetPool.AcquireQuery(LQuery);
  TAssert.AssertEquals('LIMIT 20 OFFSET 40', PdbPagingClause(LScope, TPageRequest.Create(3, 20)));
end;

procedure TPagingTests.DialectOf_NilScope_Raises;
begin
  try
    PdbDialectOf(nil);
    TAssert.Fail('A nil scope must raise');
  except
    on E: EArgumentException do
      TAssert.AssertTrue('The message must name PdbDialectOf: ' + E.Message,
        Pos('PdbDialectOf', E.Message) > 0);
  end;
end;

procedure TPagingTests.Page_HoldsItemsAndMeta;
var
  LPage: TPage<string>;
begin
  LPage.Items := TArray<string>.Create('a', 'b');
  LPage.Meta := TPageMeta.Create(TPageRequest.Create(2, 2), 5);
  TAssert.AssertEquals('Items', 2, Integer(Length(LPage.Items)));
  TAssert.AssertEquals('Second item', 'b', LPage.Items[1]);
  TAssert.AssertEquals('TotalPages', Int64(3), LPage.Meta.TotalPages);
end;

initialization
  RegisterTest(TPagingTests);

end.
