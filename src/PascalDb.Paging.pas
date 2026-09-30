unit PascalDb.Paging;

{$I pascaldb.inc}

(* Offset paging: the page a caller asks for (TPageRequest), what is known
  about the whole result (TPageMeta), a page of items with its metadata
  (TPage<T>), and the clause that limits a query to the page, in the syntax
  of the connection's database (PdbPagingClause, through IPagingDialect).

  The clause goes into the SQL through a template literal, so the SQL says
  where it goes and the library never parses SQL:

    SELECT CODE, NAME FROM CITIES WHERE STATE = :STATE ORDER BY NAME, CODE ${PAGE}

    LQuery.Sql := FFactory.SqlLoader['CITY.BY_STATE_PAGED']
      .ReplaceLiteral('PAGE', PdbPagingClause(LScope, APage)).SQL;

  The ORDER BY must name a unique set of columns: without it, rows can move
  between pages from one query to the next (and SQL Server refuses the
  clause). The total is a separate COUNT query written by the caller; the
  library doesn't derive it from the page query, which would mean parsing
  SQL (an ORDER BY inside a derived table is an error on SQL Server, for
  one).

  Nothing here knows HTTP or JSON: turning query-string values into a
  TPageRequest and TPageMeta into a response envelope is the API's job. *)

interface

uses
  SysUtils,
  PascalDb.Interfaces;

const
  PDB_PAGE_DEFAULT_LIMIT = 20;
  PDB_PAGE_MAX_LIMIT = 100;

type
  { A page number (1-based) and a page size, already normalized: build it
    with Create, which never gives a Page below 1 or a Limit outside
    1..AMaxLimit, whatever the caller passed. }
  TPageRequest = record
    Page: Integer;
    Limit: Integer;
    // Rows before this page: (Page - 1) * Limit, in Int64 so a large page
    // number can't overflow.
    function Offset: Int64;
    // APage < 1 becomes 1; ALimit < 1 becomes ADefaultLimit; a limit above
    // AMaxLimit becomes AMaxLimit (so does ADefaultLimit). AMaxLimit < 1
    // raises EArgumentException.
    class function Create(APage, ALimit: Integer;
      ADefaultLimit: Integer = PDB_PAGE_DEFAULT_LIMIT;
      AMaxLimit: Integer = PDB_PAGE_MAX_LIMIT): TPageRequest; static;
  end;

  { The page that was returned and the total number of rows. An empty result
    has one (empty) page: TotalPages is never below 1. }
  TPageMeta = record
    Page: Integer;
    Limit: Integer;
    Total: Int64;
    function TotalPages: Int64;
    function HasNext: Boolean;
    function HasPrev: Boolean;
    class function Create(const ARequest: TPageRequest; ATotal: Int64): TPageMeta; static;
  end;

  TPage<T> = record
    Items: TArray<T>;
    Meta: TPageMeta;
  end;

// The dialect of the connection a scope runs on (from AcquireQuery). Raises
// EArgumentException when the scope has no connection behind it.
function PdbDialectOf(const AScope: IScopeTransaction): ISQLDialect;

// The clause that limits a query to APage, for ADialect. Raises
// EArgumentException when APage wasn't built by TPageRequest.Create (Limit
// below 1) or the dialect doesn't implement IPagingDialect.
function PdbPagingClause(const ADialect: ISQLDialect; const APage: TPageRequest): string; overload;
// The same, for the dialect of the scope's connection.
function PdbPagingClause(const AScope: IScopeTransaction; const APage: TPageRequest): string; overload;

implementation

{ TPageRequest }

class function TPageRequest.Create(APage, ALimit, ADefaultLimit,
  AMaxLimit: Integer): TPageRequest;
begin
  if AMaxLimit < 1 then
    raise EArgumentException.CreateFmt('TPageRequest.Create: AMaxLimit must be at least 1 (got %d)',
      [AMaxLimit]);
  if ADefaultLimit < 1 then
    ADefaultLimit := 1;
  if ADefaultLimit > AMaxLimit then
    ADefaultLimit := AMaxLimit;

  if APage < 1 then
    Result.Page := 1
  else
    Result.Page := APage;

  if ALimit < 1 then
    Result.Limit := ADefaultLimit
  else if ALimit > AMaxLimit then
    Result.Limit := AMaxLimit
  else
    Result.Limit := ALimit;
end;

function TPageRequest.Offset: Int64;
begin
  Result := Int64(Page - 1) * Limit;
end;

{ TPageMeta }

class function TPageMeta.Create(const ARequest: TPageRequest; ATotal: Int64): TPageMeta;
begin
  Result.Page := ARequest.Page;
  Result.Limit := ARequest.Limit;
  Result.Total := ATotal;
end;

function TPageMeta.TotalPages: Int64;
begin
  if (Limit <= 0) or (Total <= 0) then
    Exit(1);
  Result := (Total + Limit - 1) div Limit;
end;

function TPageMeta.HasNext: Boolean;
begin
  Result := Page < TotalPages;
end;

function TPageMeta.HasPrev: Boolean;
begin
  Result := Page > 1;
end;

{ Functions }

function PdbDialectOf(const AScope: IScopeTransaction): ISQLDialect;
var
  LTransaction: ITransaction;
  LConnection: IDBConnection;
begin
  Result := nil;
  if Assigned(AScope) then
    LTransaction := AScope.OriginalTransaction
  else
    LTransaction := nil;
  if Assigned(LTransaction) then
    LConnection := LTransaction.GetConnection
  else
    LConnection := nil;
  if Assigned(LConnection) then
    Result := LConnection.GetSQLDialect;
  if not Assigned(Result) then
    raise EArgumentException.Create('PdbDialectOf: the scope has no connection with a SQL dialect ' +
      '(pass the IScopeTransaction returned by AcquireQuery)');
end;

function PdbPagingClause(const ADialect: ISQLDialect; const APage: TPageRequest): string;
var
  LPaging: IPagingDialect;
begin
  if APage.Limit < 1 then
    raise EArgumentException.CreateFmt('PdbPagingClause: the page limit is %d; build the page with ' +
      'TPageRequest.Create', [APage.Limit]);
  if not Supports(ADialect, IPagingDialect, LPaging) then
    raise EArgumentException.Create('PdbPagingClause: the SQL dialect does not implement IPagingDialect. ' +
      'The built-in dialects do; a dialect registered with TSQLDialectFactory.RegisterDialect must ' +
      'implement it to page queries.');
  Result := LPaging.GetPagingClause(APage.Limit, APage.Offset);
end;

function PdbPagingClause(const AScope: IScopeTransaction; const APage: TPageRequest): string;
begin
  Result := PdbPagingClause(PdbDialectOf(AScope), APage);
end;

end.
