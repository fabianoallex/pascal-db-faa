unit PascalDb.Migrations;

{$I pascaldb.inc}

{ Versioned migrations engine (TDBMigrationEngine): applies, in order, the
  scripts from a list of TMigrationItem not yet recorded in the
  SCHEMA_MIGRATIONS table, and emits progress events (TMigrationEventProc).

  Append-only pattern: a published script is never changed; a new change is
  always a new script, added at the end of the list, to keep chronological
  order.

  First migration: the engine does NOT create SCHEMA_MIGRATIONS itself. The
  project's MIG.0001 script creates the table with this minimal structure:

    -- Firebird:
    CREATE TABLE SCHEMA_MIGRATIONS (
      VERSION    INTEGER   NOT NULL,
      APPLIED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      CONSTRAINT PK_SCHEMA_MIGRATIONS PRIMARY KEY (VERSION)
    );

    -- PostgreSQL:
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version    INTEGER   NOT NULL,
      applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
      CONSTRAINT pk_schema_migrations PRIMARY KEY (version)
    );

  Baseline (squashing): consolidate old scripts into a baseline when their
  volume makes deploys slow, or at a major version. Before removing the
  earlier scripts, make sure no production database is below the baseline
  version.

  IsDDL on each TMigrationItem:
  - False (default, DML): script + version INSERT in the SAME transaction —
    fully atomic. For seed INSERTs, data UPDATE/DELETE.
  - True (DDL): script in T1 (commit), then the version INSERT in a separate
    T2. For CREATE/ALTER/DROP, CREATE INDEX etc. Reason: in Firebird, DDL
    implicitly commits the active transaction; in PostgreSQL DDL is
    transactional, but two transactions are safe on both databases, so
    IsDDL=True is portable.
  Forgetting IsDDL=True on a DDL script causes "Table unknown" on the version
  INSERT — the error that motivated the flag.

  Without AOnEvent, events become a line of text through SafeWriteln
  (PascalDb.SafeLog). The callback follows PASCALDB_FUNCREFS (pascaldb.inc):
  closure or method in Delphi, method in FPC 3.2.2. }

interface

uses
  Classes,
  SysUtils,
  PascalDb.Interfaces;

type
  TParamReplaceProc = procedure(AScript: TStrings);

  TMigrationItem = record
    Version: Integer;
    ScriptName: string;
    ParamReplaceProc: TParamReplaceProc;
    Terminator: string;
    IsDDL: Boolean;
  end;

  // Each step of Execute fires a TMigrationEvent — the engine neither formats
  // text nor chooses a log destination; the caller gets structured data about
  // the migration in progress and decides how/where to record it (console,
  // log file, metrics, etc.).
  TMigrationEventKind = (
    mekCheck,      // start of Execute: SchemaVersion = version before applying anything
    mekApplying,   // a pending migration is about to run
    mekApplied,    // the migration ran and its version has been recorded
    mekFailed,     // the migration failed (ErrorMessage set); Execute re-raises the exception next
    mekCompleted   // end of Execute: AppliedCount and SchemaVersion reflect the final result
  );

  TMigrationEvent = record
    Kind: TMigrationEventKind;
    Version: Integer;        // version of the migration being processed (mekApplying/mekApplied/mekFailed); 0 otherwise
    ScriptName: string;      // script name (mekApplying/mekApplied/mekFailed); '' otherwise
    IsDDL: Boolean;          // TMigrationItem.IsDDL of the migration being processed
    SchemaVersion: Integer;  // schema version: baseline on mekCheck, final version on mekCompleted
    AppliedCount: Integer;   // how many migrations were applied in this run (mekCompleted)
    ErrorMessage: string;    // exception message (mekFailed)
  end;

  // See PASCALDB_FUNCREFS in pascaldb.inc: "reference to" in Delphi (accepts
  // a closure or a method), "of object" in FPC 3.2.2 — passing a method
  // compiles on both.
  TMigrationEventProc = {$IFDEF PASCALDB_FUNCREFS}reference to procedure(const AEvent: TMigrationEvent)
    {$ELSE}procedure(const AEvent: TMigrationEvent) of object{$ENDIF};

  { TDBMigrationEngine }

  TDBMigrationEngine = class
  private
    FFactory: IDBFactory;
    FOnEvent: TMigrationEventProc;
    function DescribeEvent(const AEvent: TMigrationEvent): string;
    procedure Notify(const AEvent: TMigrationEvent);
    function ResolveMigrationDialect: IMigrationDialect;
    function GetCurrentVersion(AMigDialect: IMigrationDialect): Integer;
    procedure ApplyScript(const AMigration: TMigrationItem; ATransaction: ITransaction);
    procedure InsertVersionRecord(AVersion: Integer; AMigDialect: IMigrationDialect;
      ATransaction: ITransaction = nil);
  public
    // AOnEvent is optional — without it, events become a line of text on
    // the console through SafeWriteln. Pass a callback to get the data of
    // the migration in progress and record it however suits you:
    //
    //   TDBMigrationEngine.Create(LFactory,
    //     procedure(const AEvent: TMigrationEvent)
    //     begin
    //       case AEvent.Kind of
    //         mekApplying: MyLog('Applying %d (%s)', [AEvent.Version, AEvent.ScriptName]);
    //         mekFailed:   MyLog('Failed %d: %s', [AEvent.Version, AEvent.ErrorMessage]);
    //       end;
    //     end);
    //
    // (A closure like this is Delphi-only; on FPC 3.2.2 pass a method.)
    constructor Create(AFactory: IDBFactory; AOnEvent: TMigrationEventProc = nil);
    // Current schema version (last applied migration). Useful at application
    // startup to log/expose the database state before deciding whether to
    // run Execute — it resolves the dialect and queries SCHEMA_MIGRATIONS
    // directly, without needing a prior call to Execute.
    function CurrentVersion: Integer;
    procedure Execute(const AMigrations: array of TMigrationItem);
  end;

implementation

uses
  PascalDb.SafeLog;

{ TDBMigrationEngine }

constructor TDBMigrationEngine.Create(AFactory: IDBFactory; AOnEvent: TMigrationEventProc);
begin
  FFactory := AFactory;
  FOnEvent := AOnEvent;
end;

function TDBMigrationEngine.DescribeEvent(const AEvent: TMigrationEvent): string;
begin
  case AEvent.Kind of
    mekCheck:
      Result := Format('Checking migrations. Current version: %d', [AEvent.SchemaVersion]);
    mekApplying:
      Result := Format('Applying migration %d (%s)...', [AEvent.Version, AEvent.ScriptName]);
    mekApplied:
      Result := Format('Migration %d (%s) applied successfully.', [AEvent.Version, AEvent.ScriptName]);
    mekFailed:
      Result := Format('Failed to apply migration %d (%s): %s',
        [AEvent.Version, AEvent.ScriptName, AEvent.ErrorMessage]);
    mekCompleted:
      if AEvent.AppliedCount = 0 then
        Result := Format('No pending migrations. Current version: %d', [AEvent.SchemaVersion])
      else
        Result := Format('Migrations finished: %d applied. Final version: %d',
          [AEvent.AppliedCount, AEvent.SchemaVersion]);
  else
    Result := '';
  end;
end;

procedure TDBMigrationEngine.Notify(const AEvent: TMigrationEvent);
begin
  if Assigned(FOnEvent) then
    FOnEvent(AEvent)
  else
    SafeWriteln(Format('[%s] %s',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), DescribeEvent(AEvent)]));
end;

function TDBMigrationEngine.CurrentVersion: Integer;
begin
  Result := GetCurrentVersion(ResolveMigrationDialect);
end;

function TDBMigrationEngine.ResolveMigrationDialect: IMigrationDialect;
var
  LConn: IDBConnection;
begin
  LConn := FFactory.GetPool.AcquireConnection;
  try
    if not Supports(LConn.GetSQLDialect, IMigrationDialect, Result) then
      raise Exception.Create(
        'The configured SQL dialect does not implement IMigrationDialect. ' +
        'Check IDatabaseConfig.SQLDialect (the built-in ones are Firebird, PostgreSQL ' +
        'and SQLite); a dialect registered with TSQLDialectFactory.RegisterDialect must ' +
        'implement IMigrationDialect to run migrations.');
  finally
    LConn := nil; // returns it to the pool
  end;
end;

function TDBMigrationEngine.GetCurrentVersion(AMigDialect: IMigrationDialect): Integer;
var
  LScope: IScopeTransaction;
  LQuery: IQuery;
  LResult: IQueryResult;
  LTableExists: Boolean;
begin
  // Check that the control table exists
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AMigDialect.GetMigrationTableExistsSQL;
    LResult := LQuery.Open;
    LTableExists := LResult.Booleans['EXISTS'];
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;

  if not LTableExists then
  begin
    Result := 0;
    Exit;
  end;

  // Read the current version
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AMigDialect.GetMigrationLastVersionSQL;
    LResult := LQuery.Open;
    Result := LResult.Integers['VERSION'];
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure TDBMigrationEngine.ApplyScript(const AMigration: TMigrationItem;
  ATransaction: ITransaction);
var
  LScript: TStrings;
  LSqlScript: ISqlScript;
begin
  LScript := TStringList.Create;
  try
    LScript.Text := FFactory.SqlLoader[AMigration.ScriptName].SQL;

    if Assigned(AMigration.ParamReplaceProc) then
      AMigration.ParamReplaceProc(LScript);

    if Trim(LScript.Text) = '' then
      raise Exception.CreateFmt('Empty script: %s', [AMigration.ScriptName]);

    LSqlScript := FFactory.CreateSqlScript(ATransaction.GetConnection, ATransaction);
    LSqlScript.Script := LScript;
    LSqlScript.ExecuteScript(AMigration.Terminator);
  finally
    LScript.Free;
  end;
end;

procedure TDBMigrationEngine.InsertVersionRecord(AVersion: Integer;
  AMigDialect: IMigrationDialect; ATransaction: ITransaction);
var
  LScope: IScopeTransaction;
  LQuery: IQuery;
begin
  if Assigned(ATransaction) then
  begin
    // DML: INSERT in the script's own transaction to guarantee atomicity.
    // Uses CreateQuery directly so it doesn't interfere with the caller's IScopeTransaction.
    LQuery := FFactory.CreateQuery(ATransaction.GetConnection, ATransaction);
    LQuery.Sql := AMigDialect.GetMigrationInsertVersionSQL;
    LQuery.Params.Integers['VERSION'] := AVersion;
    LQuery.ExecSql;
  end
  else
  begin
    // DDL: Firebird auto-commits DDL; we need a new transaction to see the
    // table created by the previous script.
    LScope := FFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    try
      LQuery.Sql := AMigDialect.GetMigrationInsertVersionSQL;
      LQuery.Params.Integers['VERSION'] := AVersion;
      LQuery.ExecSql;
      LScope.Commit;
    except
      LScope.Rollback;
      raise;
    end;
  end;
end;

procedure TDBMigrationEngine.Execute(const AMigrations: array of TMigrationItem);
var
  LMigDialect: IMigrationDialect;
  LCurrentVersion: Integer;
  LLastAppliedVersion: Integer;
  LAppliedCount: Integer;
  LMigration: TMigrationItem;
  LScope: IScopeTransaction;
  LQuery: IQuery;
  LEvent: TMigrationEvent;
begin
  LMigDialect := ResolveMigrationDialect;
  LCurrentVersion := GetCurrentVersion(LMigDialect);
  LLastAppliedVersion := LCurrentVersion;
  LAppliedCount := 0;

  LEvent := Default(TMigrationEvent);
  LEvent.Kind := mekCheck;
  LEvent.SchemaVersion := LCurrentVersion;
  Notify(LEvent);

  for LMigration in AMigrations do
  begin
    if LMigration.Version <= LCurrentVersion then
      Continue;

    LEvent := Default(TMigrationEvent);
    LEvent.Kind := mekApplying;
    LEvent.Version := LMigration.Version;
    LEvent.ScriptName := LMigration.ScriptName;
    LEvent.IsDDL := LMigration.IsDDL;
    Notify(LEvent);

    try
      if LMigration.IsDDL then
      begin
        // T1: run the DDL and commit (Firebird auto-commits; PostgreSQL commits here)
        LScope := FFactory.GetPool.AcquireQuery(LQuery);
        LScope.StartTransaction;
        try
          ApplyScript(LMigration, LScope.GetOriginalTransaction);
          LScope.Commit;
        except
          LScope.Rollback;
          raise;
        end;

        // T2: record the version — a new transaction sees the table created above
        InsertVersionRecord(LMigration.Version, LMigDialect, nil);
      end
      else
      begin
        // DML: script + version in a single (atomic) transaction
        LScope := FFactory.GetPool.AcquireQuery(LQuery);
        LScope.StartTransaction;
        try
          ApplyScript(LMigration, LScope.GetOriginalTransaction);
          InsertVersionRecord(LMigration.Version, LMigDialect,
            LScope.GetOriginalTransaction);
          LScope.Commit;
        except
          LScope.Rollback;
          raise;
        end;
      end;
    except
      on E: Exception do
      begin
        LEvent := Default(TMigrationEvent);
        LEvent.Kind := mekFailed;
        LEvent.Version := LMigration.Version;
        LEvent.ScriptName := LMigration.ScriptName;
        LEvent.IsDDL := LMigration.IsDDL;
        LEvent.ErrorMessage := E.Message;
        Notify(LEvent);
        raise;
      end;
    end;

    LLastAppliedVersion := LMigration.Version;
    Inc(LAppliedCount);

    LEvent := Default(TMigrationEvent);
    LEvent.Kind := mekApplied;
    LEvent.Version := LMigration.Version;
    LEvent.ScriptName := LMigration.ScriptName;
    LEvent.IsDDL := LMigration.IsDDL;
    Notify(LEvent);
  end;

  LEvent := Default(TMigrationEvent);
  LEvent.Kind := mekCompleted;
  LEvent.SchemaVersion := LLastAppliedVersion;
  LEvent.AppliedCount := LAppliedCount;
  Notify(LEvent);
end;

end.
