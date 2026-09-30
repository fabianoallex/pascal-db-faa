program Optionals;

(* Sample 04: optional and nullable values, and SQL templates shaped by them.

  Three kinds of value, all from PascalDb.Optionals (one class per type,
  TOptNullXxx, implements the three interfaces):
    INullXxx     "is it NULL?"       (IsNull)   a nullable column or parameter
    IOptXxx      "was it given?"     (HasValue) an optional filter
    IOptNullXxx  both                           a field in a partial update:
                 Undefined = leave the column alone, Null = set it to NULL,
                 From(X) = set it to X
  As parameters, INullXxx is always bound (NULL or the value); IOptXxx and
  IOptNullXxx are bound only when HasValue, so the SQL must not mention a
  parameter that wasn't given. That is what the template tags are for:
    [NAME {] ... [} NAME]  ProcessTag('NAME', Keep) keeps or removes the block
    ${NAME_OP}            ReplaceLiteral / ApplyOperator put text in place
    ApplyFilter('NAME', Op, HasValue) does both at once.
  A tag nobody processed loses only its markers when .SQL is read: the block
  itself stays. Process every tag the SQL has. ${...} is pasted into the SQL
  as is: fill it from code (an operator, a column name), never from user
  input; values always go through parameters.

  Steps: insert customers with INullString parameters, search with optional
  filters, apply partial updates (printing the SQL each one produced), and
  read nullable columns with NullableStrings. The SQL lives in a
  TMemorySqlSource so the templates sit next to the code that fills them
  (sample 03 shows .sql files); the same text serves every database,
  except CREATE TABLE.

  Same source for Delphi (Optionals.dproj) and Lazarus/FPC (Optionals.lpi);
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
  Samples.Env;

type
  // Search criteria: each one is optional.
  TCustomerFilter = record
    Name: IOptString;      // exact, or a prefix when it ends with '%'
    City: IOptString;
    WithoutEmail: Boolean;
  end;

  // A partial update: only the fields that are defined change.
  TCustomerPatch = record
    Name: IOptString;      // NAME is NOT NULL: optional, but never null
    Email: IOptNullString;
    Phone: IOptNullString;
  end;

function BuildSqlSource: ISqlSource;
const
  TABLE_COLUMNS = '(ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(100)%0:s NOT NULL, ' +
    'CITY VARCHAR(60)%0:s, EMAIL VARCHAR(100)%0:s, PHONE VARCHAR(30)%0:s)';
var
  LSource: TMemorySqlSource;
  LDir: string;
begin
  LSource := TMemorySqlSource.Create;
  Result := LSource;
  LSource.Add(SQL_DIR_POSTGRESQL, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_CUSTOMERS ' + Format(TABLE_COLUMNS, ['']));
  LSource.Add(SQL_DIR_SQLITE, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_CUSTOMERS ' + Format(TABLE_COLUMNS, ['']));
  // MySQL/MariaDB: utf8mb4 declared, since a server's default varies.
  LSource.Add(SQL_DIR_MYSQL, 'SCHEMA.CREATE',
    'CREATE TABLE IF NOT EXISTS SAMPLE_CUSTOMERS ' + Format(TABLE_COLUMNS, ['']) + ' DEFAULT CHARSET=utf8mb4');
  LSource.Add(SQL_DIR_FIREBIRD, 'SCHEMA.CREATE',
    'RECREATE TABLE SAMPLE_CUSTOMERS ' + Format(TABLE_COLUMNS, [' CHARACTER SET UTF8']));
  // SQL Server: no CREATE TABLE IF NOT EXISTS; NVARCHAR for text outside the
  // collation's code page (1252 by default).
  LSource.Add(SQL_DIR_MSSQL, 'SCHEMA.CREATE',
    'IF OBJECT_ID(''SAMPLE_CUSTOMERS'', ''U'') IS NULL CREATE TABLE SAMPLE_CUSTOMERS ' +
    '(ID INTEGER NOT NULL PRIMARY KEY, NAME NVARCHAR(100) NOT NULL, ' +
    'CITY NVARCHAR(60), EMAIL NVARCHAR(100), PHONE NVARCHAR(30))');
  for LDir in TArray<string>.Create(SQL_DIR_POSTGRESQL, SQL_DIR_FIREBIRD, SQL_DIR_SQLITE, SQL_DIR_MYSQL,
    SQL_DIR_MSSQL) do
    LSource
      .Add(LDir, 'CUSTOMER.DELETE_ALL', 'DELETE FROM SAMPLE_CUSTOMERS')
      .Add(LDir, 'CUSTOMER.INSERT',
        'INSERT INTO SAMPLE_CUSTOMERS (ID, NAME, CITY, EMAIL, PHONE) ' +
        'VALUES (:ID, :NAME, :CITY, :EMAIL, :PHONE)')
      // "WHERE 1 = 1" lets every optional condition start with AND.
      .Add(LDir, 'CUSTOMER.FIND',
        '[COMMENTS {] Removed from the SQL when it is read; documents the template. [} COMMENTS]' + sLineBreak +
        'SELECT ID, NAME, CITY, EMAIL, PHONE FROM SAMPLE_CUSTOMERS WHERE 1 = 1' + sLineBreak +
        '  [NAME {] AND NAME ${NAME_OP} :NAME [} NAME]' + sLineBreak +
        '  [CITY {] AND CITY = :CITY [} CITY]' + sLineBreak +
        '  [NO_EMAIL {] AND EMAIL IS NULL [} NO_EMAIL]' + sLineBreak +
        'ORDER BY ID')
      // "SET ID = ID" lets every optional assignment start with a comma.
      .Add(LDir, 'CUSTOMER.UPDATE',
        'UPDATE SAMPLE_CUSTOMERS SET ID = ID' + sLineBreak +
        '  [NAME {], NAME = :NAME [} NAME]' + sLineBreak +
        '  [EMAIL {], EMAIL = :EMAIL [} EMAIL]' + sLineBreak +
        '  [PHONE {], PHONE = :PHONE [} PHONE]' + sLineBreak +
        'WHERE ID = :ID');
end;

// One line, single spaces: easier to read in the console.
function Compact(const ASql: string): string;
var
  I: Integer;
begin
  Result := Trim(StringReplace(StringReplace(ASql, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]));
  repeat
    I := Pos('  ', Result);
    if I > 0 then
      Delete(Result, I, 1);
  until I = 0;
end;

function Show(const AValue: INullString): string;
begin
  if AValue.IsNull then
    Result := '(null)'
  else
    Result := AValue.Value;
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

// INullString parameters are always bound: NULL or the value.
procedure InsertCustomer(const AFactory: IDBFactory; AId: Integer; const AName: string;
  const ACity, AEmail, APhone: INullString);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader['CUSTOMER.INSERT'].SQL;
    LQuery.Params.Integers['ID'] := AId;
    LQuery.Params.Strings['NAME'] := AName;
    LQuery.Params.NullStrings['CITY'] := ACity;
    LQuery.Params.NullStrings['EMAIL'] := AEmail;
    LQuery.Params.NullStrings['PHONE'] := APhone;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure FindCustomers(const AFactory: IDBFactory; const ATitle: string; const AFilter: TCustomerFilter);
var
  LName, LCity: IOptString;
  LSql: TSQLResult;
  LOperator: string;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  // A record's interface fields start as nil: Safe turns nil into Undefined.
  LName := TOptionals.Safe(AFilter.Name);
  LCity := TOptionals.Safe(AFilter.City);

  if LName.HasValue and (Pos('%', LName.Value) > 0) then
    LOperator := 'LIKE'
  else
    LOperator := '=';
  LSql := AFactory.SqlLoader['CUSTOMER.FIND']
    .ApplyFilter('NAME', LOperator, LName.HasValue)
    .ProcessTag('CITY', LCity.HasValue)
    .ProcessTag('NO_EMAIL', AFilter.WithoutEmail);

  Writeln(ATitle);
  Writeln('  SQL: ', Compact(LSql.SQL));
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := LSql.SQL;
    // Bound only when HasValue, matching the blocks kept above.
    LQuery.Params.OptStrings['NAME'] := LName;
    LQuery.Params.OptStrings['CITY'] := LCity;
    LResult := LQuery.Open;
    while not LResult.Eof do
    begin
      Writeln(Format('  %d  %-11s city=%-10s email=%-17s phone=%s', [LResult.Integers['ID'],
        LResult.Strings['NAME'], Show(LResult.NullableStrings['CITY']),
        Show(LResult.NullableStrings['EMAIL']), Show(LResult.NullableStrings['PHONE'])]));
      LResult.Next;
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  Writeln;
end;

procedure UpdateCustomer(const AFactory: IDBFactory; AId: Integer; const ATitle: string;
  const APatch: TCustomerPatch);
var
  LName: IOptString;
  LEmail, LPhone: IOptNullString;
  LSql: TSQLResult;
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LName := TOptionals.Safe(APatch.Name);
  LEmail := TOptionals.Safe(APatch.Email);
  LPhone := TOptionals.Safe(APatch.Phone);

  Writeln(ATitle);
  if not (LName.HasValue or LEmail.HasValue or LPhone.HasValue) then
  begin
    Writeln('  nothing to change: no UPDATE sent');
    Writeln;
    Exit;
  end;

  LSql := AFactory.SqlLoader['CUSTOMER.UPDATE']
    .ProcessTag('NAME', LName.HasValue)
    .ProcessTag('EMAIL', LEmail.HasValue)
    .ProcessTag('PHONE', LPhone.HasValue);
  Writeln('  SQL: ', Compact(LSql.SQL));

  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := LSql.SQL;
    LQuery.Params.Integers['ID'] := AId;
    LQuery.Params.OptStrings['NAME'] := LName;
    // Undefined: not bound (its block is gone). Null: bound as NULL.
    LQuery.Params.OptNullStrings['EMAIL'] := LEmail;
    LQuery.Params.OptNullStrings['PHONE'] := LPhone;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  Writeln;
end;

procedure Run;
var
  LFactory: IDBFactory;
  LFilter: TCustomerFilter;
  LPatch: TCustomerPatch;
begin
  Writeln('Target: ', SampleTarget);
  LFactory := NewSampleFactory(BuildSqlSource);
  CheckSampleConnection(LFactory);
  RunScript(LFactory, 'SCHEMA.CREATE');
  RunScript(LFactory, 'CUSTOMER.DELETE_ALL');

  InsertCustomer(LFactory, 1, 'Maria', TOptNullString.From('Campinas'),
    TOptNullString.From('maria@example.com'), TOptNullString.From('19 5555-0101'));
  InsertCustomer(LFactory, 2, 'Marcos', TOptNullString.From('São Paulo'),
    TOptNullString.Null, TOptNullString.From('11 5555-0102'));
  InsertCustomer(LFactory, 3, 'Ana', TOptNullString.From('Campinas'),
    TOptNullString.Null, TOptNullString.Null);
  InsertCustomer(LFactory, 4, 'Pedro', TOptNullString.Null,
    TOptNullString.From('pedro@example.com'), TOptNullString.Null);
  Writeln('Inserted 4 customers; some columns NULL.');
  Writeln;

  // Default(...) zeroes the record: its interface fields start as nil.
  LFilter := Default(TCustomerFilter);
  FindCustomers(LFactory, 'All customers (no filter):', LFilter);

  LFilter := Default(TCustomerFilter);
  LFilter.City := TOptNullString.From('Campinas');
  FindCustomers(LFactory, 'City = Campinas:', LFilter);

  LFilter := Default(TCustomerFilter);
  LFilter.Name := TOptNullString.From('Mar%');
  LFilter.WithoutEmail := True;
  FindCustomers(LFactory, 'Name starting with "Mar", without an e-mail:', LFilter);

  LPatch := Default(TCustomerPatch);
  LPatch.Email := TOptNullString.From('ana@example.com');
  UpdateCustomer(LFactory, 3, 'Ana: set the e-mail, leave the phone as it is:', LPatch);

  LPatch := Default(TCustomerPatch);
  LPatch.Phone := TOptNullString.Null;
  LPatch.Name := TOptNullString.From('Maria Silva');
  UpdateCustomer(LFactory, 1, 'Maria: rename, clear the phone (Null), leave the e-mail:', LPatch);

  LPatch := Default(TCustomerPatch);
  UpdateCustomer(LFactory, 2, 'Marcos: an empty patch:', LPatch);

  LFilter := Default(TCustomerFilter);
  FindCustomers(LFactory, 'All customers after the updates:', LFilter);
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
