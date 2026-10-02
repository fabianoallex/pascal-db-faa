program JsonApi;

(* Sample 06: optional values between JSON and the database, with
  pascal-jsonmapper-faa (the git submodule in external/) and the bridge unit
  PascalDb.JsonMapper.Optionals.

  It plays the part of a small HTTP API without a server: the request bodies
  are strings, and each "endpoint" is a procedure that answers with what an
  API would send back. The point is that the same optional types travel the
  whole way: a column read with NullableStrings goes into a DTO property and
  out as JSON, and a JSON member comes into a DTO property and goes into a
  parameter, with no "if Assigned" field by field.

    POST  JSON -> ICustomer -> INSERT. A member that isn't in the body is nil
          in the DTO; TOptionals.Safe reads it as Null, so the column gets NULL.
    GET   SELECT -> NullableStrings / NullableCurrencies -> ICustomer -> JSON.
          A NULL column is written as null (INullXxx is never omitted).
    PATCH JSON -> ICustomerPatch -> UPDATE with only the blocks of the members
          that came (ProcessTag, as in sample 04). The three states of
          IOptNullXxx map one to one: absent = leave the column alone,
          null = set it to NULL, a value = set it.
          null for the name (an IOptString: may be absent, never null) and a
          value of the wrong type are rejected by the mapper with the JSON
          path: what an API would answer with a 400.

  The DTOs are interfaces registered with RegisterMapping; the mapper maps
  the published properties of the class ({$M+}). A real application
  registers them in the initialization of the unit that declares them.

  Same source for Delphi (JsonApi.dproj) and Lazarus/FPC (JsonApi.lpi);
  connection settings as in sample 02. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring, // FPC on Unix: needed for non-ASCII text in Variants (see CLAUDE.md)
  {$ENDIF}
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.Optionals,
  PascalDb.SqlLoader,
  PascalDb.SqlSources,
  PascalJsonMapper.Mapper,
  PascalDb.JsonMapper.Optionals, // using it registers the converter on TJsonMapper.Shared
  Samples.Env;

type
  // What GET returns and POST receives.
  ICustomer = interface
    ['{4D3A7E21-9B6C-4F18-A2E5-7C0D1B8F3E62}']
    function GetId: Integer;
    function GetName: string;
    function GetEmail: INullString;
    function GetCredit: INullCurrency;
    property Id: Integer read GetId;
    property Name: string read GetName;
    property Email: INullString read GetEmail;
    property Credit: INullCurrency read GetCredit;
  end;

  TCustomerArray = array of ICustomer;

  ICustomerList = interface
    ['{9E1B5C47-3A2D-4E86-B0F4-6D8C2A7E1F35}']
  end;

  // What PATCH receives: every member may be absent.
  ICustomerPatch = interface
    ['{B7F2D094-1C6E-4A53-8E3B-2F9A5D0C7B18}']
    function GetName: IOptString;
    function GetEmail: IOptNullString;
    function GetCredit: IOptNullCurrency;
    property Name: IOptString read GetName;        // NAME is NOT NULL: never null
    property Email: IOptNullString read GetEmail;
    property Credit: IOptNullCurrency read GetCredit;
  end;

{$M+}
  TCustomer = class(TInterfacedObject, ICustomer)
  private
    FId: Integer;
    FName: string;
    FEmail: INullString;
    FCredit: INullCurrency;
  public
    function GetId: Integer;
    function GetName: string;
    function GetEmail: INullString;
    function GetCredit: INullCurrency;
  published
    property Id: Integer read FId write FId;
    property Name: string read FName write FName;
    property Email: INullString read FEmail write FEmail;
    property Credit: INullCurrency read FCredit write FCredit;
  end;

  TCustomerList = class(TInterfacedObject, ICustomerList)
  private
    FItems: TCustomerArray;
  published
    property Items: TCustomerArray read FItems write FItems;
  end;

  TCustomerPatch = class(TInterfacedObject, ICustomerPatch)
  private
    FName: IOptString;
    FEmail: IOptNullString;
    FCredit: IOptNullCurrency;
  public
    function GetName: IOptString;
    function GetEmail: IOptNullString;
    function GetCredit: IOptNullCurrency;
  published
    property Name: IOptString read FName write FName;
    property Email: IOptNullString read FEmail write FEmail;
    property Credit: IOptNullCurrency read FCredit write FCredit;
  end;
{$M-}

function TCustomer.GetId: Integer;
begin
  Result := FId;
end;

function TCustomer.GetName: string;
begin
  Result := FName;
end;

function TCustomer.GetEmail: INullString;
begin
  Result := FEmail;
end;

function TCustomer.GetCredit: INullCurrency;
begin
  Result := FCredit;
end;

function TCustomerPatch.GetName: IOptString;
begin
  Result := FName;
end;

function TCustomerPatch.GetEmail: IOptNullString;
begin
  Result := FEmail;
end;

function TCustomerPatch.GetCredit: IOptNullCurrency;
begin
  Result := FCredit;
end;

function BuildSqlSource: ISqlSource;
const
  TABLE_COLUMNS = '(ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(100)%0:s NOT NULL, ' +
    'EMAIL VARCHAR(100)%0:s, CREDIT NUMERIC(15,2))';
var
  LSource: TMemorySqlSource;
  LDir: string;
begin
  LSource := TMemorySqlSource.Create;
  Result := LSource;
  LSource.Add(SQL_DIR_POSTGRESQL, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_JSON_CUSTOMERS ' + Format(TABLE_COLUMNS, ['']));
  LSource.Add(SQL_DIR_SQLITE, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_JSON_CUSTOMERS ' + Format(TABLE_COLUMNS, ['']));
  // MySQL/MariaDB: utf8mb4 declared, since a server's default varies.
  LSource.Add(SQL_DIR_MYSQL, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_JSON_CUSTOMERS ' + Format(TABLE_COLUMNS, ['']) +
    ' DEFAULT CHARSET=utf8mb4');
  LSource.Add(SQL_DIR_FIREBIRD, 'SCHEMA.CREATE',
    'RECREATE TABLE SAMPLE_JSON_CUSTOMERS ' + Format(TABLE_COLUMNS, [' CHARACTER SET UTF8']));
  // SQL Server: no CREATE TABLE IF NOT EXISTS; NVARCHAR for non-ASCII text.
  LSource.Add(SQL_DIR_MSSQL, 'SCHEMA.CREATE',
    'IF OBJECT_ID(''SAMPLE_JSON_CUSTOMERS'', ''U'') IS NULL CREATE TABLE SAMPLE_JSON_CUSTOMERS ' +
    '(ID INTEGER NOT NULL PRIMARY KEY, NAME NVARCHAR(100) NOT NULL, ' +
    'EMAIL NVARCHAR(100), CREDIT NUMERIC(15,2))');
  for LDir in TArray<string>.Create(SQL_DIR_POSTGRESQL, SQL_DIR_FIREBIRD, SQL_DIR_SQLITE,
    SQL_DIR_MYSQL, SQL_DIR_MSSQL) do
    LSource
      .Add(LDir, 'CUSTOMER.DELETE_ALL', 'DELETE FROM SAMPLE_JSON_CUSTOMERS')
      .Add(LDir, 'CUSTOMER.INSERT',
        'INSERT INTO SAMPLE_JSON_CUSTOMERS (ID, NAME, EMAIL, CREDIT) ' +
        'VALUES (:ID, :NAME, :EMAIL, :CREDIT)')
      .Add(LDir, 'CUSTOMER.LIST',
        'SELECT ID, NAME, EMAIL, CREDIT FROM SAMPLE_JSON_CUSTOMERS ORDER BY ID')
      // "SET ID = ID" lets every optional assignment start with a comma.
      .Add(LDir, 'CUSTOMER.UPDATE',
        'UPDATE SAMPLE_JSON_CUSTOMERS SET ID = ID' + sLineBreak +
        '  [NAME {], NAME = :NAME [} NAME]' + sLineBreak +
        '  [EMAIL {], EMAIL = :EMAIL [} EMAIL]' + sLineBreak +
        '  [CREDIT {], CREDIT = :CREDIT [} CREDIT]' + sLineBreak +
        'WHERE ID = :ID');
end;

procedure RunScript(const AFactory: IDBFactory; const AKey: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader[AKey].SQL;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

// POST /customers
procedure PostCustomer(const AFactory: IDBFactory; const ABody: string);
var
  LCustomer: ICustomer;
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  Writeln('POST /customers ', ABody);
  LCustomer := TJsonMapper.Shared.FromJson<ICustomer>(ABody);
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader['CUSTOMER.INSERT'].SQL;
    LQuery.Params.Integers['ID'] := LCustomer.Id;
    LQuery.Params.Strings['NAME'] := LCustomer.Name;
    // A member missing from the body is nil: Safe makes it Null -> NULL.
    LQuery.Params.NullStrings['EMAIL'] := TOptionals.Safe(LCustomer.Email);
    LQuery.Params.NullCurrencies['CREDIT'] := TOptionals.Safe(LCustomer.Credit);
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  Writeln('  201 Created');
end;

// GET /customers
procedure GetCustomers(const AFactory: IDBFactory);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LItems: TCustomerArray;
  LCustomer: TCustomer;
  LList: TCustomerList;
  LListIntf: ICustomerList;
begin
  Writeln('GET /customers');
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader['CUSTOMER.LIST'].SQL;
    LResult := LQuery.Open;
    while not LResult.Eof do
    begin
      LCustomer := TCustomer.Create;
      SetLength(LItems, Length(LItems) + 1);
      LItems[High(LItems)] := LCustomer;
      LCustomer.Id := LResult.Integers['ID'];
      LCustomer.Name := LResult.Strings['NAME'];
      // The nullable column reads go straight into the DTO.
      LCustomer.Email := LResult.NullableStrings['EMAIL'];
      LCustomer.Credit := LResult.NullableCurrencies['CREDIT'];
      LResult.Next;
    end;
    LScope.Commit; // read the result before committing
  except
    LScope.Rollback;
    raise;
  end;
  LList := TCustomerList.Create;
  LListIntf := LList;
  LList.Items := LItems;
  Writeln('  200 ', TJsonMapper.Shared.ToJson<ICustomerList>(LListIntf));
end;

// PATCH /customers/{id}
procedure PatchCustomer(const AFactory: IDBFactory; AId: Integer; const ABody: string);
var
  LPatch: ICustomerPatch;
  LName: IOptString;
  LEmail: IOptNullString;
  LCredit: IOptNullCurrency;
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  Writeln('PATCH /customers/', AId, ' ', ABody);
  try
    LPatch := TJsonMapper.Shared.FromJson<ICustomerPatch>(ABody);
  except
    // The mapper's message starts with the JSON path of the bad member.
    on E: EJsonMapperError do
    begin
      Writeln('  400 Bad Request: ', E.Message);
      Exit;
    end;
  end;
  // Absent members are nil: Safe turns them into Undefined.
  LName := TOptionals.Safe(LPatch.Name);
  LEmail := TOptionals.Safe(LPatch.Email);
  LCredit := TOptionals.Safe(LPatch.Credit);
  if not (LName.HasValue or LEmail.HasValue or LCredit.HasValue) then
  begin
    Writeln('  204 No Content (nothing to change: no UPDATE sent)');
    Exit;
  end;

  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader['CUSTOMER.UPDATE']
      .ProcessTag('NAME', LName.HasValue)
      .ProcessTag('EMAIL', LEmail.HasValue)
      .ProcessTag('CREDIT', LCredit.HasValue).SQL;
    LQuery.Params.Integers['ID'] := AId;
    // Undefined: not bound (its block is gone). Null: bound as NULL.
    LQuery.Params.OptStrings['NAME'] := LName;
    LQuery.Params.OptNullStrings['EMAIL'] := LEmail;
    LQuery.Params.OptNullCurrencies['CREDIT'] := LCredit;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  Writeln('  204 No Content');
end;

procedure Run;
var
  LFactory: IDBFactory;
begin
  // A real application does this in the initialization of the DTO unit.
  TJsonMapper.Shared.RegisterMapping<ICustomer, TCustomer>;
  TJsonMapper.Shared.RegisterMapping<ICustomerList, TCustomerList>;
  TJsonMapper.Shared.RegisterMapping<ICustomerPatch, TCustomerPatch>;

  Writeln('Target: ', SampleTarget);
  LFactory := NewSampleFactory(BuildSqlSource);
  CheckSampleConnection(LFactory);
  RunScript(LFactory, 'SCHEMA.CREATE');
  RunScript(LFactory, 'CUSTOMER.DELETE_ALL');
  Writeln;

  PostCustomer(LFactory, '{"id":1,"name":"Maria","email":"maria@example.com","credit":150.5}');
  PostCustomer(LFactory, '{"id":2,"name":"João","email":null}');   // no credit: NULL
  PostCustomer(LFactory, '{"id":3,"name":"Ana","credit":80}');     // no e-mail: NULL
  GetCustomers(LFactory);
  Writeln;

  PatchCustomer(LFactory, 1, '{"email":null}');                    // clear the e-mail
  PatchCustomer(LFactory, 3, '{"name":"Ana Souza","credit":200}'); // e-mail untouched
  PatchCustomer(LFactory, 2, '{}');
  PatchCustomer(LFactory, 2, '{"name":null}');                     // IOptString: never null
  PatchCustomer(LFactory, 2, '{"credit":"a lot"}');
  GetCustomers(LFactory);
end;

begin
  {$IFDEF FPC}
  // Plain FPC console programs don't run in UTF-8 by default; without this,
  // non-ASCII text becomes "?" on its way to the database (see CLAUDE.md).
  // Delphi doesn't need it.
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ELSE}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  try
    Run;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
