unit PascalDb.Adapter.Base;

{$I pascaldb.inc}

{ Driver-agnostic building blocks shared by every adapter, so that an adapter
  only has to wrap its driver's connection, transaction and query:

  - TDatabaseConfig — IDatabaseConfig: pool settings, SQL dialect, SQL
    directory and source, and the driver's connection settings as
    Name=Value lines. Declare the variable as IDatabaseConfig: the
    properties exist on the interface only (LConfig.ConnectionParams doesn't
    compile on a TDatabaseConfig variable), and the object is
    reference-counted.
  - TTransactionBase — ITransaction skeleton: keeps the in-transaction flag
    and routes every native failure (start, commit, rollback, ExecSql)
    through BuildDatabaseException, so a dropped connection is classified the
    same way on every driver. Subclasses only make the native calls.
  - TScopeTransaction — IScopeTransaction: the outermost scope owns the real
    transaction; nested scopes use savepoints from the SQL dialect. While
    TPcTracing.Enabled (PascalCommon.Tracing), the outermost scope's
    transaction is a span, from StartTransaction to Commit or Rollback (or
    to the scope's release, "abandoned"). A detached span: it never becomes
    the thread's current span, so the transaction may end on any thread; the
    scope hangs it on the ITransaction (ITransactionSpan, which
    TTransactionBase implements) and the pooled statements inside name it
    as their parent (see the tracing note in PascalDb.Pool).
  - TSqlScript — ISqlScript: splits a script on a terminator and runs each
    statement through ITransaction.ExecSql.
  - TParamsBase — IParams: the whole IOptXxx/INullXxx/IOptNullXxx semantics
    written once on top of a few primitives (exists, is null, write null,
    read/write each type) that a driver implements.
  - TDBFactory — IDBFactory: builds the pool and the SQL loader from the
    config, and delegates connections/transactions/queries to the adapter's
    IDBComponentProvider. TestConnection runs the dialect's ping SQL, so it
    works on any driver.
  - PdbPreloadClientLibrary — makes a client library given by full path
    loadable on Windows even when its own dependencies aren't on the search
    path.
  - PdbMySQLPluginDir — the plugin folder next to a MySQL/MariaDB client
    library given by full path.
  - PdbFirebirdConstraintKind and the like — which constraint a database
    error code means (EConstraintViolationException), per database, for the
    adapters' IsConstraintViolationError.

  Nothing here references a database driver or Data.DB/db; the TDataSet-based
  pieces live in PascalDb.Adapter.DataSet. }

interface

uses
  Classes,
  SysUtils,
  PascalDb.Interfaces,
  PascalCommon.Optionals,
  PascalCommon.Tracing,
  PascalDb.SqlSources,
  PascalDb.SqlLoader,
  PascalDb.Pool;

type
  { TDatabaseConfig
    Declare the variable as IDatabaseConfig, never TDatabaseConfig:
      LConfig: IDatabaseConfig;
      LConfig := TDatabaseConfig.Create;
    The class has no properties on purpose, only the interface's getters
    and setters: it is reference-counted, and a class variable handed to a
    factory (which keeps it as an interface) frees the object when the
    factory lets go, leaving the variable dangling. With a class variable,
    LConfig.ConnectionParams is an "undeclared identifier": the fix is the
    variable's type. }

  TDatabaseConfig = class(TInterfacedObject, IDatabaseConfig)
  private
    FConnectionParams: TStrings;
    FSQLDirectory: string;
    FSQLDialect: string;
    FSqlSource: ISqlSource;
    FPoolWaitMaxAttemps: Integer;
    FPoolWaitMilliseconds: Integer;
    FPoolMaxConnections: Integer;
    FPoolIniConnections: Integer;
    FPoolIdleTimeoutSeconds: Integer;
    FPoolIdleCheckIntervalMs: Integer;
    FPoolValidateIdleSeconds: Integer;
    FPoolKeepaliveSeconds: Integer;
    FLockTimeoutMs: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    function GetPoolIniConnections: Integer;
    function GetPoolMaxConnections: Integer;
    function GetPoolWaitMaxAttemps: Integer;
    function GetPoolWaitMilliseconds: Integer;
    function GetPoolIdleTimeoutSeconds: Integer;
    function GetPoolIdleCheckIntervalMs: Integer;
    function GetPoolValidateIdleSeconds: Integer;
    function GetPoolKeepaliveSeconds: Integer;
    function GetLockTimeoutMs: Integer;
    function GetSQLDialect: string;
    procedure SetPoolIniConnections(AValue: Integer);
    procedure SetPoolMaxConnections(AValue: Integer);
    procedure SetPoolWaitMaxAttemps(AValue: Integer);
    procedure SetPoolWaitMilliseconds(AValue: Integer);
    procedure SetPoolIdleTimeoutSeconds(AValue: Integer);
    procedure SetPoolIdleCheckIntervalMs(AValue: Integer);
    procedure SetPoolValidateIdleSeconds(AValue: Integer);
    procedure SetPoolKeepaliveSeconds(AValue: Integer);
    procedure SetLockTimeoutMs(AValue: Integer);
    procedure SetSQLDialect(AValue: string);
    function GetSQLDirectory: string;
    procedure SetSQLDirectory(const AValue: string);
    function GetSqlSource: ISqlSource;
    procedure SetSqlSource(const AValue: ISqlSource);
    function GetConnectionParams: TStrings;
  end;

  { TTransactionBase }

  TTransactionBase = class(TInterfacedObject, ITransaction, ITransactionSpan)
  private
    FConn: IDBConnection;
    FInTransaction: Boolean;
    FSpan: IPcSpan;
  protected
    procedure DoStartTransaction; virtual; abstract;
    procedure DoCommit; virtual; abstract;
    procedure DoRollback; virtual; abstract;
    procedure DoExecSql(const ASql: string); virtual; abstract;
    /// Runs ASql (as DoExecSql) and returns the rows it affected, or -1 when
    /// the driver can't tell; ExecSql calls this one. The default calls
    /// DoExecSql and returns -1; an adapter whose driver counts overrides it
    /// (and can implement DoExecSql by calling it).
    function DoExecSqlRows(const ASql: string): Int64; virtual;
    /// True when E is one of the driver's lock conflict errors (see
    /// ELockConflictException); ExecSql then raises ELockConflictException
    /// instead. The default recognizes nothing.
    function IsLockConflictError(E: Exception): Boolean; virtual;
    /// True when E is one of the driver's constraint violations, with its
    /// kind in AKind (see EConstraintViolationException); ExecSql and Commit
    /// then raise EConstraintViolationException instead. Checked after
    /// IsLockConflictError. The default recognizes nothing.
    function IsConstraintViolationError(E: Exception; out AKind: TConstraintViolationKind): Boolean; virtual;
  public
    constructor Create(const AConn: IDBConnection);
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;
    function GetConnection: IDBConnection;
    function GetNativeTransaction: TObject; virtual; abstract;
    function ExecSql(const ASql: string): Int64;
    // ITransactionSpan (PascalDb.Pool): set and cleared by TScopeTransaction.
    function GetSpan: IPcSpan;
    procedure SetSpan(const ASpan: IPcSpan);
  end;

  { ITracedScopeTransaction
    How TDBFactory.CreateScopeTransaction gives the scope an adapter built
    (IDBComponentProvider.BuildScopeTransaction) the db.system.name of its
    span, which only the factory's config knows. A scope without it gets a
    span without the attribute. }

  ITracedScopeTransaction = interface
    ['{46C6B3E8-E7E2-4A7F-9E9D-1ECDC977F3B4}']
    procedure SetDbSystem(const ADbSystem: string);
  end;

  { TScopeTransaction
    The transaction span (see the unit comment) is detached: the scope may
    commit, roll back or be released on any thread. }

  TScopeTransaction = class(TInterfacedObject, IScopeTransaction, ITracedScopeTransaction)
  private
    FOriginalTransaction: ITransaction;
    FSavepointName: string;
    FIsMain: Boolean;
    FStarted: Boolean;
    FContextTransaction: IContextTransaction;
    FDbSystem: string;
    FSpan: IPcSpan;
    procedure FinishSpan(const AOutcome: string; AError: Exception);
  public
    constructor Create(const AOriginalTransaction: ITransaction; const AContextTransaction: IContextTransaction);
    destructor Destroy; override;
    procedure SetDbSystem(const ADbSystem: string);
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;
    function IsMain: Boolean;
    function GetOriginalTransaction: ITransaction;
  end;

  { TSqlScript }

  TSqlScript = class(TInterfacedObject, ISqlScript)
  private
    FScript: TStringList;
    FConn: IDBConnection;
    FTransaction: ITransaction;
  public
    constructor Create(const AConn: IDBConnection; const ATransaction: ITransaction);
    destructor Destroy; override;
    /// Splits the script on ATerminator (default ';') and runs each non-empty
    /// statement through the transaction. The split is textual: a terminator
    /// inside a string literal or comment also splits — pick a terminator
    /// that doesn't appear in the statements (Firebird DDL scripts use '^').
    class function SplitStatements(const AScript, ATerminator: string): TArray<string>; static;
    procedure ExecuteScript(ATerminator: string = ';');
    function GetConnection: IDBConnection;
    function GetScript: TStrings;
    function GetTransaction: ITransaction;
    procedure SetScript(AValue: TStrings);
  end;

  /// Declared in PascalDb.Interfaces (batches use it too); kept here so code
  /// that names it through this unit still compiles.
  TPdbParamType = PascalDb.Interfaces.TPdbParamType;

  { TParamsBase
    The setters read a nil optional the way TOptionals.Safe does (and the
    mock's params): nil IOptXxx/IOptNullXxx = Undefined, the parameter is
    left untouched; nil INullXxx = NULL. An interface field of a record or
    class starts as nil, so this is the common case, not an edge. }

  TParamsBase = class(TInterfacedObject, IParams)
  protected
    function ParamExists(const AName: string): Boolean; virtual; abstract;
    function ParamIsNull(const AName: string): Boolean; virtual; abstract;
    procedure WriteNull(const AName: string; AType: TPdbParamType); virtual; abstract;
    function ReadString(const AName: string): string; virtual; abstract;
    function ReadBoolean(const AName: string): Boolean; virtual; abstract;
    function ReadDateTime(const AName: string): TDateTime; virtual; abstract;
    function ReadDouble(const AName: string): Double; virtual; abstract;
    function ReadInteger(const AName: string): Integer; virtual; abstract;
    function ReadInt64(const AName: string): Int64; virtual; abstract;
    function ReadCurrency(const AName: string): Currency; virtual; abstract;
    procedure WriteString(const AName: string; AValue: string); virtual; abstract;
    procedure WriteBoolean(const AName: string; AValue: Boolean); virtual; abstract;
    procedure WriteDateTime(const AName: string; AValue: TDateTime); virtual; abstract;
    procedure WriteDouble(const AName: string; AValue: Double); virtual; abstract;
    procedure WriteInteger(const AName: string; AValue: Integer); virtual; abstract;
    procedure WriteInt64(const AName: string; AValue: Int64); virtual; abstract;
    procedure WriteCurrency(const AName: string; AValue: Currency); virtual; abstract;
  public
    // plain
    function GetString(const AName: string): string;
    function GetBoolean(const AName: string): Boolean;
    function GetDateTime(const AName: string): TDateTime;
    function GetDouble(const AName: string): Double;
    function GetInteger(const AName: string): Integer;
    function GetInt64(const AName: string): Int64;
    function GetCurrency(const AName: string): Currency;
    procedure SetString(const AName: string; AValue: string);
    procedure SetBoolean(const AName: string; AValue: Boolean);
    procedure SetDateTime(const AName: string; AValue: TDateTime);
    procedure SetDouble(const AName: string; AValue: Double);
    procedure SetInteger(const AName: string; AValue: Integer);
    procedure SetInt64(const AName: string; AValue: Int64);
    procedure SetCurrency(const AName: string; AValue: Currency);
    // OptNull: Undefined -> skip, Null -> NULL, value -> set
    function GetOptNullString(const AName: string): IOptNullString;
    function GetOptNullBoolean(const AName: string): IOptNullBoolean;
    function GetOptNullDateTime(const AName: string): IOptNullDateTime;
    function GetOptNullDouble(const AName: string): IOptNullDouble;
    function GetOptNullInteger(const AName: string): IOptNullInteger;
    function GetOptNullInt64(const AName: string): IOptNullInt64;
    function GetOptNullCurrency(const AName: string): IOptNullCurrency;
    procedure SetOptNullString(const AName: string; AValue: IOptNullString);
    procedure SetOptNullBoolean(const AName: string; AValue: IOptNullBoolean);
    procedure SetOptNullDateTime(const AName: string; AValue: IOptNullDateTime);
    procedure SetOptNullDouble(const AName: string; AValue: IOptNullDouble);
    procedure SetOptNullInteger(const AName: string; AValue: IOptNullInteger);
    procedure SetOptNullInt64(const AName: string; AValue: IOptNullInt64);
    procedure SetOptNullCurrency(const AName: string; AValue: IOptNullCurrency);
    // Null: Null -> NULL, value -> set (never skipped)
    function GetNullString(const AName: string): INullString;
    function GetNullBoolean(const AName: string): INullBoolean;
    function GetNullDateTime(const AName: string): INullDateTime;
    function GetNullDouble(const AName: string): INullDouble;
    function GetNullInteger(const AName: string): INullInteger;
    function GetNullInt64(const AName: string): INullInt64;
    function GetNullCurrency(const AName: string): INullCurrency;
    procedure SetNullString(const AName: string; AValue: INullString);
    procedure SetNullBoolean(const AName: string; AValue: INullBoolean);
    procedure SetNullDateTime(const AName: string; AValue: INullDateTime);
    procedure SetNullDouble(const AName: string; AValue: INullDouble);
    procedure SetNullInteger(const AName: string; AValue: INullInteger);
    procedure SetNullInt64(const AName: string; AValue: INullInt64);
    procedure SetNullCurrency(const AName: string; AValue: INullCurrency);
    // Opt: Undefined -> skip, value -> set (IsNull does not apply)
    function GetOptString(const AName: string): IOptString;
    function GetOptBoolean(const AName: string): IOptBoolean;
    function GetOptDateTime(const AName: string): IOptDateTime;
    function GetOptDouble(const AName: string): IOptDouble;
    function GetOptInteger(const AName: string): IOptInteger;
    function GetOptInt64(const AName: string): IOptInt64;
    function GetOptCurrency(const AName: string): IOptCurrency;
    procedure SetOptString(const AName: string; AValue: IOptString);
    procedure SetOptBoolean(const AName: string; AValue: IOptBoolean);
    procedure SetOptDateTime(const AName: string; AValue: IOptDateTime);
    procedure SetOptDouble(const AName: string; AValue: IOptDouble);
    procedure SetOptInteger(const AName: string; AValue: IOptInteger);
    procedure SetOptInt64(const AName: string; AValue: IOptInt64);
    procedure SetOptCurrency(const AName: string; AValue: IOptCurrency);
  end;

  { TDBFactory }

  TDBFactory = class(TInterfacedObject, IDBFactory, IDBComponentProviderSupport)
  private
    FSqlLoader: TSQLLoader;
    FPool: IDBConnectionPool;
    FConfig: IDatabaseConfig;
    FComponentProvider: IDBComponentProvider;
    FContextTransactionProvider: IContextTransactionProvider;
  public
    /// AProvider: the adapter's driver-specific part. AOnPoolEvent and
    /// AOnStatement are passed straight to TConnectionPool.Create (see
    /// TPoolEventKind and TStatementInfo).
    constructor Create(const AConfig: IDatabaseConfig; const AProvider: IDBComponentProvider;
      const AContextTransactionProvider: IContextTransactionProvider = nil;
      AOnPoolEvent: TPoolEventProc = nil; AOnStatement: TStatementEventProc = nil);
    destructor Destroy; override;
    function GetProvider: IDBComponentProvider;
    procedure SetProvider(AProvider: IDBComponentProvider);
    function SqlLoader: TSQLLoader;
    function GetPool: IDBConnectionPool;
    function CreateConnection: IDBConnection;
    function CreateTransaction(AConn: IDBConnection): ITransaction;
    function CreateScopeTransaction(ATransaction: ITransaction): IScopeTransaction;
    function CreateQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function CreateSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
    /// Runs the dialect's ping SQL on AConn (connecting first if needed) in a
    /// throwaway transaction; False on any failure.
    function TestConnection(AConn: IDBConnection): Boolean;
    property Config: IDatabaseConfig read FConfig;
  end;

/// Windows: loads the client library ALibrary (a full path) with its own
/// folder searched for its dependencies, and keeps it loaded. A driver that
/// then loads the same path gets this module. Without it, a library such as
/// libpq.dll — which needs libssl, libcrypto, libintl, ... from its own
/// folder — fails to load unless that folder is on PATH (observed: "Can not
/// load PostgreSQL client library" with the full path of an installed
/// libpq.dll). Adapters call this for the client library path they are
/// given; no-op for '' or a bare file name, when the library is already
/// loaded, and outside Windows. A failure is left for the driver to report.
/// Forward slashes are accepted (turned into backslashes: LoadLibraryEx
/// doesn't define its behavior with them).
procedure PdbPreloadClientLibrary(const ALibrary: string);

/// The "plugin" folder next to ALibrary, a MySQL/MariaDB client library given
/// by full path, when it exists; '' otherwise. The client loads its
/// authentication plugins from there (MariaDB Connector/C and MySQL both
/// install them in lib\plugin, next to the library), but looks in a folder
/// fixed when it was built: a MySQL 8.4 server, whose default authentication
/// is caching_sha2_password, refused every connection from a MariaDB
/// Connector/C 3.4.11 copied to another folder ("Plugin caching_sha2_password
/// could not be loaded", measured on Windows). Adapters pass it as the
/// MYSQL_PLUGIN_DIR connection option unless the settings give one.
/// On Windows, forward slashes in ALibrary are accepted: Delphi's
/// ExtractFilePath knows only the backslash there, so 'C:/libs/libmariadb.dll'
/// gave 'C:' and the folder was never found (measured: every connection to
/// MySQL 8.4 failed, FireDAC and Zeos, Delphi Win32 and Win64). FPC's accepts
/// both separators (SQLdb passed with forward slashes before the fix).
function PdbMySQLPluginDir(const ALibrary: string): string;

/// The constraint violations behind each database's error codes (see
/// EConstraintViolationException), shared by the adapters: each returns True
/// with the kind in AKind when the code is one, False otherwise. Measured
/// with the contract suite on every database the adapters are tested with.
///
/// Firebird: the first GDS code of the status vector (isc_unique_key_violation,
/// isc_no_dup, isc_foreign_key, isc_check_constraint; isc_not_valid is a NOT
/// NULL column when the message has "*** null ***", a domain's CHECK
/// otherwise).
function PdbFirebirdConstraintKind(AGdsCode: Integer; const AMessage: string;
  out AKind: TConstraintViolationKind): Boolean;
/// PostgreSQL: the SQLSTATE (23505, 23503, 23502, 23514).
function PdbPostgresConstraintKind(const ASqlState: string; out AKind: TConstraintViolationKind): Boolean;
/// MySQL and MariaDB: the server's error number (ER_DUP_ENTRY and the like;
/// MySQL's ER_CHECK_CONSTRAINT_VIOLATED, MariaDB's ER_CONSTRAINT_FAILED).
function PdbMySQLConstraintKind(AErrorCode: Integer; out AKind: TConstraintViolationKind): Boolean;
/// SQL Server: the error number (2627, 2601, 515; 547 is a foreign key or a
/// CHECK, told apart by the message).
function PdbSqlServerConstraintKind(AErrorCode: Integer; const AMessage: string;
  out AKind: TConstraintViolationKind): Boolean;
/// SQLite: the extended result code when the driver has it (2067, 1555,
/// 787, 1299, 275), otherwise the message ("UNIQUE constraint failed", ...).
function PdbSQLiteConstraintKind(AErrorCode: Integer; const AMessage: string;
  out AKind: TConstraintViolationKind): Boolean;

implementation

uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  PascalDb.SqlDialect;

// Windows: a path written with forward slashes, as the system's own. Delphi's
// ExtractFilePath and LoadLibraryEx expect backslashes (see PdbMySQLPluginDir).
function NativeLibraryPath(const ALibrary: string): string;
begin
  {$IFDEF MSWINDOWS}
  Result := StringReplace(ALibrary, '/', '\', [rfReplaceAll]);
  {$ELSE}
  Result := ALibrary;
  {$ENDIF}
end;

procedure PdbPreloadClientLibrary(const ALibrary: string);
{$IFDEF MSWINDOWS}
var
  LPath: UnicodeString;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if ExtractFilePath(NativeLibraryPath(ALibrary)) = '' then
    Exit;
  LPath := UnicodeString(NativeLibraryPath(ALibrary));
  if GetModuleHandleW(PWideChar(LPath)) = 0 then
    LoadLibraryExW(PWideChar(LPath), 0, LOAD_WITH_ALTERED_SEARCH_PATH);
  {$ENDIF}
end;

function PdbMySQLPluginDir(const ALibrary: string): string;
var
  LFolder: string;
begin
  Result := '';
  LFolder := ExtractFilePath(NativeLibraryPath(ALibrary));
  if LFolder = '' then
    Exit;
  Result := LFolder + 'plugin';
  if not DirectoryExists(Result) then
    Result := '';
end;

{ TDatabaseConfig }

constructor TDatabaseConfig.Create;
begin
  inherited Create;
  FConnectionParams := TStringList.Create;
  // A config nobody tuned must still work: with every pool setting at 0 the
  // first acquire timed out at once ("Pool: 0/0 active").
  FPoolIniConnections := 1;
  FPoolMaxConnections := 10;
  FPoolWaitMaxAttemps := 50;    // a caller waits up to 50 x 100 ms for a free connection
  FPoolWaitMilliseconds := 100;
  FPoolIdleCheckIntervalMs := 30000; // only matters if PoolIdleTimeoutSeconds or PoolKeepaliveSeconds > 0
  FPoolValidateIdleSeconds := 120;
end;

destructor TDatabaseConfig.Destroy;
begin
  FConnectionParams.Free;
  inherited Destroy;
end;

function TDatabaseConfig.GetPoolIniConnections: Integer;
begin
  Result := FPoolIniConnections;
end;

function TDatabaseConfig.GetPoolMaxConnections: Integer;
begin
  Result := FPoolMaxConnections;
end;

function TDatabaseConfig.GetPoolWaitMaxAttemps: Integer;
begin
  Result := FPoolWaitMaxAttemps;
end;

function TDatabaseConfig.GetPoolWaitMilliseconds: Integer;
begin
  Result := FPoolWaitMilliseconds;
end;

function TDatabaseConfig.GetPoolIdleTimeoutSeconds: Integer;
begin
  Result := FPoolIdleTimeoutSeconds;
end;

function TDatabaseConfig.GetPoolIdleCheckIntervalMs: Integer;
begin
  Result := FPoolIdleCheckIntervalMs;
end;

function TDatabaseConfig.GetPoolValidateIdleSeconds: Integer;
begin
  Result := FPoolValidateIdleSeconds;
end;

function TDatabaseConfig.GetPoolKeepaliveSeconds: Integer;
begin
  Result := FPoolKeepaliveSeconds;
end;

function TDatabaseConfig.GetLockTimeoutMs: Integer;
begin
  Result := FLockTimeoutMs;
end;

function TDatabaseConfig.GetSQLDialect: string;
begin
  Result := FSQLDialect;
end;

procedure TDatabaseConfig.SetPoolIniConnections(AValue: Integer);
begin
  FPoolIniConnections := AValue;
end;

procedure TDatabaseConfig.SetPoolMaxConnections(AValue: Integer);
begin
  FPoolMaxConnections := AValue;
end;

procedure TDatabaseConfig.SetPoolWaitMaxAttemps(AValue: Integer);
begin
  FPoolWaitMaxAttemps := AValue;
end;

procedure TDatabaseConfig.SetPoolWaitMilliseconds(AValue: Integer);
begin
  FPoolWaitMilliseconds := AValue;
end;

procedure TDatabaseConfig.SetPoolIdleTimeoutSeconds(AValue: Integer);
begin
  if AValue >= 0 then
    FPoolIdleTimeoutSeconds := AValue;
end;

procedure TDatabaseConfig.SetPoolIdleCheckIntervalMs(AValue: Integer);
begin
  if AValue > 0 then
    FPoolIdleCheckIntervalMs := AValue;
end;

procedure TDatabaseConfig.SetPoolValidateIdleSeconds(AValue: Integer);
begin
  FPoolValidateIdleSeconds := AValue; // every value means something; see the property
end;

procedure TDatabaseConfig.SetPoolKeepaliveSeconds(AValue: Integer);
begin
  if AValue >= 0 then
    FPoolKeepaliveSeconds := AValue;
end;

procedure TDatabaseConfig.SetLockTimeoutMs(AValue: Integer);
begin
  if AValue >= 0 then
    FLockTimeoutMs := AValue;
end;

procedure TDatabaseConfig.SetSQLDialect(AValue: string);
begin
  FSQLDialect := AValue;
end;

function TDatabaseConfig.GetSQLDirectory: string;
begin
  Result := FSQLDirectory;
end;

procedure TDatabaseConfig.SetSQLDirectory(const AValue: string);
begin
  FSQLDirectory := AValue;
end;

function TDatabaseConfig.GetSqlSource: ISqlSource;
begin
  Result := FSqlSource;
end;

procedure TDatabaseConfig.SetSqlSource(const AValue: ISqlSource);
begin
  FSqlSource := AValue;
end;

function TDatabaseConfig.GetConnectionParams: TStrings;
begin
  Result := FConnectionParams;
end;

function PdbFirebirdConstraintKind(AGdsCode: Integer; const AMessage: string;
  out AKind: TConstraintViolationKind): Boolean;
const
  ISC_NOT_VALID = 335544347;            // "validation error for column ..."
  ISC_NO_DUP = 335544349;               // "attempt to store duplicate value ... in unique index"
  ISC_FOREIGN_KEY = 335544466;          // "violation of FOREIGN KEY constraint"
  ISC_CHECK_CONSTRAINT = 335544558;     // "Operation violates CHECK constraint"
  ISC_UNIQUE_KEY_VIOLATION = 335544665; // "violation of PRIMARY or UNIQUE KEY constraint"
begin
  Result := True;
  AKind := cvUnique;
  case AGdsCode of
    ISC_UNIQUE_KEY_VIOLATION, ISC_NO_DUP: AKind := cvUnique;
    ISC_FOREIGN_KEY: AKind := cvForeignKey;
    ISC_CHECK_CONSTRAINT: AKind := cvCheck;
    ISC_NOT_VALID:
      if Pos('*** null ***', AMessage) > 0 then
        AKind := cvNotNull
      else
        AKind := cvCheck;
  else
    Result := False;
  end;
end;

function PdbPostgresConstraintKind(const ASqlState: string; out AKind: TConstraintViolationKind): Boolean;
begin
  Result := True;
  AKind := cvUnique;
  if ASqlState = '23505' then // unique_violation
    AKind := cvUnique
  else if ASqlState = '23503' then // foreign_key_violation
    AKind := cvForeignKey
  else if ASqlState = '23502' then // not_null_violation
    AKind := cvNotNull
  else if ASqlState = '23514' then // check_violation
    AKind := cvCheck
  else
    Result := False;
end;

function PdbMySQLConstraintKind(AErrorCode: Integer; out AKind: TConstraintViolationKind): Boolean;
begin
  Result := True;
  AKind := cvUnique;
  case AErrorCode of
    1062, // ER_DUP_ENTRY
    1586: // ER_DUP_ENTRY_WITH_KEY_NAME
      AKind := cvUnique;
    1216, 1217, // ER_NO_REFERENCED_ROW, ER_ROW_IS_REFERENCED (older servers)
    1451, 1452: // ER_ROW_IS_REFERENCED_2, ER_NO_REFERENCED_ROW_2
      AKind := cvForeignKey;
    1048, // ER_BAD_NULL_ERROR
    1364: // ER_NO_DEFAULT_FOR_FIELD: a NOT NULL column left out
      AKind := cvNotNull;
    3819, // ER_CHECK_CONSTRAINT_VIOLATED (MySQL)
    4025: // ER_CONSTRAINT_FAILED (MariaDB)
      AKind := cvCheck;
  else
    Result := False;
  end;
end;

function PdbSqlServerConstraintKind(AErrorCode: Integer; const AMessage: string;
  out AKind: TConstraintViolationKind): Boolean;
begin
  Result := True;
  AKind := cvUnique;
  case AErrorCode of
    2627, // "Violation of PRIMARY KEY / UNIQUE KEY constraint"
    2601: // "Cannot insert duplicate key row ... with unique index"
      AKind := cvUnique;
    515: // "Cannot insert the value NULL into column"
      AKind := cvNotNull;
    547: // "... conflicted with the FOREIGN KEY / REFERENCE / CHECK constraint"
      if Pos('CHECK constraint', AMessage) > 0 then
        AKind := cvCheck
      else
        AKind := cvForeignKey;
  else
    Result := False;
  end;
end;

function PdbSQLiteConstraintKind(AErrorCode: Integer; const AMessage: string;
  out AKind: TConstraintViolationKind): Boolean;
begin
  Result := True;
  AKind := cvUnique;
  case AErrorCode of
    2067, 1555: AKind := cvUnique; // SQLITE_CONSTRAINT_UNIQUE, SQLITE_CONSTRAINT_PRIMARYKEY
    787: AKind := cvForeignKey;     // SQLITE_CONSTRAINT_FOREIGNKEY
    1299: AKind := cvNotNull;       // SQLITE_CONSTRAINT_NOTNULL
    275: AKind := cvCheck;          // SQLITE_CONSTRAINT_CHECK
  else
    // Without extended result codes: SQLITE_CONSTRAINT (19) and the message.
    if Pos('UNIQUE constraint failed', AMessage) > 0 then
      AKind := cvUnique
    else if Pos('FOREIGN KEY constraint failed', AMessage) > 0 then
      AKind := cvForeignKey
    else if Pos('NOT NULL constraint failed', AMessage) > 0 then
      AKind := cvNotNull
    else if Pos('CHECK constraint failed', AMessage) > 0 then
      AKind := cvCheck
    else
      Result := False;
  end;
end;

{ TTransactionBase }

constructor TTransactionBase.Create(const AConn: IDBConnection);
begin
  inherited Create;
  FConn := AConn;
end;

// Every native call below is wrapped the same way: BuildDatabaseException
// (PascalDb.Interfaces) marks a broken connection for discard and returns a
// NEW EDatabaseUnavailableException to raise, or nil for a normal data error.
// Never "raise E;" from another frame (AV in Delphi) — only a new exception
// or a bare "raise;" lexically inside the except block.

procedure TTransactionBase.StartTransaction;
var
  LNewE: Exception;
begin
  if FInTransaction then
    Exit;
  try
    DoStartTransaction;
  except
    on E: Exception do
    begin
      LNewE := BuildDatabaseException(FConn, E);
      if Assigned(LNewE) then
        raise LNewE;
      raise;
    end;
  end;
  FInTransaction := True;
end;

procedure TTransactionBase.Commit;
var
  LNewE: Exception;
  LKind: TConstraintViolationKind;
begin
  try
    DoCommit;
  except
    on E: Exception do
    begin
      // A deferred constraint is checked here.
      if IsConstraintViolationError(E, LKind) then
        raise EConstraintViolationException.Create(LKind, E);
      LNewE := BuildDatabaseException(FConn, E);
      if Assigned(LNewE) then
        raise LNewE;
      raise;
    end;
  end;
  FInTransaction := False;
end;

procedure TTransactionBase.Rollback;
var
  LNewE: Exception;
begin
  try
    DoRollback;
  except
    on E: Exception do
    begin
      LNewE := BuildDatabaseException(FConn, E);
      if Assigned(LNewE) then
        raise LNewE;
      raise;
    end;
  end;
  FInTransaction := False;
end;

function TTransactionBase.ExecSql(const ASql: string): Int64;
var
  LNewE: Exception;
  LKind: TConstraintViolationKind;
begin
  try
    Result := DoExecSqlRows(ASql);
  except
    on E: Exception do
    begin
      if IsLockConflictError(E) then
        raise ELockConflictException.Create(E);
      if IsConstraintViolationError(E, LKind) then
        raise EConstraintViolationException.Create(LKind, E);
      LNewE := BuildDatabaseException(FConn, E);
      if Assigned(LNewE) then
        raise LNewE;
      raise;
    end;
  end;
end;

function TTransactionBase.IsLockConflictError(E: Exception): Boolean;
begin
  Result := False;
end;

function TTransactionBase.DoExecSqlRows(const ASql: string): Int64;
begin
  DoExecSql(ASql);
  Result := -1;
end;

function TTransactionBase.IsConstraintViolationError(E: Exception;
  out AKind: TConstraintViolationKind): Boolean;
begin
  AKind := cvUnique;
  Result := False;
end;

function TTransactionBase.InTransaction: Boolean;
begin
  Result := FInTransaction;
end;

function TTransactionBase.GetSpan: IPcSpan;
begin
  Result := FSpan;
end;

procedure TTransactionBase.SetSpan(const ASpan: IPcSpan);
begin
  FSpan := ASpan;
end;

function TTransactionBase.GetConnection: IDBConnection;
begin
  Result := FConn;
end;

{ TScopeTransaction }

constructor TScopeTransaction.Create(const AOriginalTransaction: ITransaction;
  const AContextTransaction: IContextTransaction);
begin
  inherited Create;
  FContextTransaction := AContextTransaction;
  FOriginalTransaction := AOriginalTransaction;
  FIsMain := not AOriginalTransaction.InTransaction;
end;

destructor TScopeTransaction.Destroy;
begin
  // Released without Commit or Rollback: the pool rolls the transaction back.
  FinishSpan('abandoned', nil);
  inherited Destroy;
end;

procedure TScopeTransaction.SetDbSystem(const ADbSystem: string);
begin
  FDbSystem := ADbSystem;
end;

procedure TScopeTransaction.FinishSpan(const AOutcome: string; AError: Exception);
var
  LTxSpan: ITransactionSpan;
begin
  if FSpan = nil then
    Exit;
  if Supports(FOriginalTransaction, ITransactionSpan, LTxSpan) and (LTxSpan.GetSpan = FSpan) then
    LTxSpan.SetSpan(nil);
  if AOutcome <> '' then
    FSpan.SetAttribute('pascaldb.transaction.outcome', AOutcome);
  PdbFinishSpan(FSpan, AError);
  FSpan := nil;
end;

procedure TScopeTransaction.StartTransaction;
var
  LTxSpan: ITransactionSpan;
begin
  if FIsMain and (FSpan = nil) and TPcTracing.Enabled then
  begin
    // A child of the thread's current span (the request's), never current
    // itself: see the unit comment.
    FSpan := TPcTracing.StartDetachedSpan('transaction', skInternal);
    if FDbSystem <> '' then
      FSpan.SetAttribute('db.system.name', FDbSystem);
    if Supports(FOriginalTransaction, ITransactionSpan, LTxSpan) then
      LTxSpan.SetSpan(FSpan);
  end;

  try
    FOriginalTransaction.StartTransaction;
  except
    on E: Exception do
    begin
      FinishSpan('', E);
      raise;
    end;
  end;

  if Assigned(FContextTransaction) then
    FContextTransaction.Apply(FOriginalTransaction);

  if not FIsMain then
  begin
    FSavepointName := 'sp_' + IntToHex(NativeInt(Self), 8);
    FOriginalTransaction.ExecSql(
      FOriginalTransaction.GetConnection.GetSQLDialect.GetSavepointSQL(FSavepointName));
  end;

  FStarted := True;
end;

procedure TScopeTransaction.Commit;
begin
  if not FStarted then
    Exit;

  if FIsMain then
  begin
    try
      FOriginalTransaction.Commit;
    except
      on E: Exception do
      begin
        FinishSpan('commit', E);
        raise;
      end;
    end;
    FinishSpan('commit', nil);
  end
  else if FOriginalTransaction.GetConnection.GetSQLDialect.SupportsRelease then
  begin
    FOriginalTransaction.ExecSql(
      FOriginalTransaction.GetConnection.GetSQLDialect.GetReleaseSavepointSQL(FSavepointName));
    FStarted := False;
  end;
end;

procedure TScopeTransaction.Rollback;
begin
  if not FStarted then
    Exit;

  if FIsMain then
  begin
    try
      FOriginalTransaction.Rollback;
    except
      on E: Exception do
      begin
        FinishSpan('rollback', E);
        raise;
      end;
    end;
    FinishSpan('rollback', nil);
  end
  else
  begin
    FOriginalTransaction.ExecSql(
      FOriginalTransaction.GetConnection.GetSQLDialect.GetRollbackToSavepointSQL(FSavepointName));
    FStarted := False;
  end;
end;

function TScopeTransaction.InTransaction: Boolean;
begin
  Result := FOriginalTransaction.InTransaction;
end;

function TScopeTransaction.IsMain: Boolean;
begin
  Result := FIsMain;
end;

function TScopeTransaction.GetOriginalTransaction: ITransaction;
begin
  Result := FOriginalTransaction;
end;

{ TSqlScript }

constructor TSqlScript.Create(const AConn: IDBConnection; const ATransaction: ITransaction);
begin
  inherited Create;
  FScript := TStringList.Create;
  FConn := AConn;
  FTransaction := ATransaction;
end;

destructor TSqlScript.Destroy;
begin
  FScript.Free;
  inherited Destroy;
end;

class function TSqlScript.SplitStatements(const AScript, ATerminator: string): TArray<string>;
var
  LTerminator, LRest, LPart: string;
  LPos, LCount: Integer;
begin
  Result := nil;
  LTerminator := ATerminator;
  if LTerminator = '' then
    LTerminator := ';';
  LCount := 0;
  LRest := AScript;
  repeat
    LPos := Pos(LTerminator, LRest);
    if LPos > 0 then
    begin
      LPart := Trim(Copy(LRest, 1, LPos - 1));
      LRest := Copy(LRest, LPos + Length(LTerminator), MaxInt);
    end
    else
    begin
      LPart := Trim(LRest);
      LRest := '';
    end;
    if LPart <> '' then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := LPart;
      Inc(LCount);
    end;
  until LPos = 0;
end;

procedure TSqlScript.ExecuteScript(ATerminator: string);
var
  LStatement: string;
begin
  for LStatement in SplitStatements(FScript.Text, ATerminator) do
    FTransaction.ExecSql(LStatement);
end;

function TSqlScript.GetConnection: IDBConnection;
begin
  Result := FConn;
end;

function TSqlScript.GetScript: TStrings;
begin
  Result := FScript;
end;

function TSqlScript.GetTransaction: ITransaction;
begin
  Result := FTransaction;
end;

procedure TSqlScript.SetScript(AValue: TStrings);
begin
  FScript.Assign(AValue);
end;

{ TParamsBase }

function TParamsBase.GetString(const AName: string): string;
begin
  Result := ReadString(AName);
end;

function TParamsBase.GetBoolean(const AName: string): Boolean;
begin
  Result := ReadBoolean(AName);
end;

function TParamsBase.GetDateTime(const AName: string): TDateTime;
begin
  Result := ReadDateTime(AName);
end;

function TParamsBase.GetDouble(const AName: string): Double;
begin
  Result := ReadDouble(AName);
end;

function TParamsBase.GetInteger(const AName: string): Integer;
begin
  Result := ReadInteger(AName);
end;

function TParamsBase.GetInt64(const AName: string): Int64;
begin
  Result := ReadInt64(AName);
end;

function TParamsBase.GetCurrency(const AName: string): Currency;
begin
  Result := ReadCurrency(AName);
end;

procedure TParamsBase.SetString(const AName: string; AValue: string);
begin
  WriteString(AName, AValue);
end;

procedure TParamsBase.SetBoolean(const AName: string; AValue: Boolean);
begin
  WriteBoolean(AName, AValue);
end;

procedure TParamsBase.SetDateTime(const AName: string; AValue: TDateTime);
begin
  WriteDateTime(AName, AValue);
end;

procedure TParamsBase.SetDouble(const AName: string; AValue: Double);
begin
  WriteDouble(AName, AValue);
end;

procedure TParamsBase.SetInteger(const AName: string; AValue: Integer);
begin
  WriteInteger(AName, AValue);
end;

procedure TParamsBase.SetInt64(const AName: string; AValue: Int64);
begin
  WriteInt64(AName, AValue);
end;

procedure TParamsBase.SetCurrency(const AName: string; AValue: Currency);
begin
  WriteCurrency(AName, AValue);
end;

function TParamsBase.GetOptNullString(const AName: string): IOptNullString;
begin
  if not ParamExists(AName) then
    Exit(TOptNullString.Undefined);
  if ParamIsNull(AName) then
    Exit(TOptNullString.Null);
  Result := TOptNullString.From(ReadString(AName));
end;

function TParamsBase.GetOptNullBoolean(const AName: string): IOptNullBoolean;
begin
  if not ParamExists(AName) then
    Exit(TOptNullBoolean.Undefined);
  if ParamIsNull(AName) then
    Exit(TOptNullBoolean.Null);
  Result := TOptNullBoolean.From(ReadBoolean(AName));
end;

function TParamsBase.GetOptNullDateTime(const AName: string): IOptNullDateTime;
begin
  if not ParamExists(AName) then
    Exit(TOptNullDateTime.Undefined);
  if ParamIsNull(AName) then
    Exit(TOptNullDateTime.Null);
  Result := TOptNullDateTime.From(ReadDateTime(AName));
end;

function TParamsBase.GetOptNullDouble(const AName: string): IOptNullDouble;
begin
  if not ParamExists(AName) then
    Exit(TOptNullDouble.Undefined);
  if ParamIsNull(AName) then
    Exit(TOptNullDouble.Null);
  Result := TOptNullDouble.From(ReadDouble(AName));
end;

function TParamsBase.GetOptNullInteger(const AName: string): IOptNullInteger;
begin
  if not ParamExists(AName) then
    Exit(TOptNullInteger.Undefined);
  if ParamIsNull(AName) then
    Exit(TOptNullInteger.Null);
  Result := TOptNullInteger.From(ReadInteger(AName));
end;

function TParamsBase.GetOptNullInt64(const AName: string): IOptNullInt64;
begin
  if not ParamExists(AName) then
    Exit(TOptNullInt64.Undefined);
  if ParamIsNull(AName) then
    Exit(TOptNullInt64.Null);
  Result := TOptNullInt64.From(ReadInt64(AName));
end;

function TParamsBase.GetOptNullCurrency(const AName: string): IOptNullCurrency;
begin
  if not ParamExists(AName) then
    Exit(TOptNullCurrency.Undefined);
  if ParamIsNull(AName) then
    Exit(TOptNullCurrency.Null);
  Result := TOptNullCurrency.From(ReadCurrency(AName));
end;

procedure TParamsBase.SetOptNullString(const AName: string; AValue: IOptNullString);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  if AValue.IsNull then
    WriteNull(AName, pptString)
  else
    WriteString(AName, AValue.Value);
end;

procedure TParamsBase.SetOptNullBoolean(const AName: string; AValue: IOptNullBoolean);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  if AValue.IsNull then
    WriteNull(AName, pptBoolean)
  else
    WriteBoolean(AName, AValue.Value);
end;

procedure TParamsBase.SetOptNullDateTime(const AName: string; AValue: IOptNullDateTime);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  if AValue.IsNull then
    WriteNull(AName, pptDateTime)
  else
    WriteDateTime(AName, AValue.Value);
end;

procedure TParamsBase.SetOptNullDouble(const AName: string; AValue: IOptNullDouble);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  if AValue.IsNull then
    WriteNull(AName, pptDouble)
  else
    WriteDouble(AName, AValue.Value);
end;

procedure TParamsBase.SetOptNullInteger(const AName: string; AValue: IOptNullInteger);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  if AValue.IsNull then
    WriteNull(AName, pptInteger)
  else
    WriteInteger(AName, AValue.Value);
end;

procedure TParamsBase.SetOptNullInt64(const AName: string; AValue: IOptNullInt64);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  if AValue.IsNull then
    WriteNull(AName, pptInt64)
  else
    WriteInt64(AName, AValue.Value);
end;

procedure TParamsBase.SetOptNullCurrency(const AName: string; AValue: IOptNullCurrency);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  if AValue.IsNull then
    WriteNull(AName, pptCurrency)
  else
    WriteCurrency(AName, AValue.Value);
end;

function TParamsBase.GetNullString(const AName: string): INullString;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullString.Null);
  Result := TOptNullString.From(ReadString(AName));
end;

function TParamsBase.GetNullBoolean(const AName: string): INullBoolean;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullBoolean.Null);
  Result := TOptNullBoolean.From(ReadBoolean(AName)) as INullBoolean;
end;

function TParamsBase.GetNullDateTime(const AName: string): INullDateTime;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullDateTime.Null);
  Result := TOptNullDateTime.From(ReadDateTime(AName));
end;

function TParamsBase.GetNullDouble(const AName: string): INullDouble;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullDouble.Null);
  Result := TOptNullDouble.From(ReadDouble(AName));
end;

function TParamsBase.GetNullInteger(const AName: string): INullInteger;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullInteger.Null);
  Result := TOptNullInteger.From(ReadInteger(AName));
end;

function TParamsBase.GetNullInt64(const AName: string): INullInt64;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullInt64.Null);
  Result := TOptNullInt64.From(ReadInt64(AName));
end;

function TParamsBase.GetNullCurrency(const AName: string): INullCurrency;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullCurrency.Null);
  Result := TOptNullCurrency.From(ReadCurrency(AName));
end;

procedure TParamsBase.SetNullString(const AName: string; AValue: INullString);
begin
  if not Assigned(AValue) or AValue.IsNull then
    WriteNull(AName, pptString)
  else
    WriteString(AName, AValue.Value);
end;

procedure TParamsBase.SetNullBoolean(const AName: string; AValue: INullBoolean);
begin
  if not Assigned(AValue) or AValue.IsNull then
    WriteNull(AName, pptBoolean)
  else
    WriteBoolean(AName, AValue.Value);
end;

procedure TParamsBase.SetNullDateTime(const AName: string; AValue: INullDateTime);
begin
  if not Assigned(AValue) or AValue.IsNull then
    WriteNull(AName, pptDateTime)
  else
    WriteDateTime(AName, AValue.Value);
end;

procedure TParamsBase.SetNullDouble(const AName: string; AValue: INullDouble);
begin
  if not Assigned(AValue) or AValue.IsNull then
    WriteNull(AName, pptDouble)
  else
    WriteDouble(AName, AValue.Value);
end;

procedure TParamsBase.SetNullInteger(const AName: string; AValue: INullInteger);
begin
  if not Assigned(AValue) or AValue.IsNull then
    WriteNull(AName, pptInteger)
  else
    WriteInteger(AName, AValue.Value);
end;

procedure TParamsBase.SetNullInt64(const AName: string; AValue: INullInt64);
begin
  if not Assigned(AValue) or AValue.IsNull then
    WriteNull(AName, pptInt64)
  else
    WriteInt64(AName, AValue.Value);
end;

procedure TParamsBase.SetNullCurrency(const AName: string; AValue: INullCurrency);
begin
  if not Assigned(AValue) or AValue.IsNull then
    WriteNull(AName, pptCurrency)
  else
    WriteCurrency(AName, AValue.Value);
end;

function TParamsBase.GetOptString(const AName: string): IOptString;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullString.Undefined);
  Result := TOptNullString.From(ReadString(AName));
end;

function TParamsBase.GetOptBoolean(const AName: string): IOptBoolean;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullBoolean.Undefined);
  Result := TOptNullBoolean.From(ReadBoolean(AName)) as IOptBoolean;
end;

function TParamsBase.GetOptDateTime(const AName: string): IOptDateTime;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullDateTime.Undefined);
  Result := TOptNullDateTime.From(ReadDateTime(AName));
end;

function TParamsBase.GetOptDouble(const AName: string): IOptDouble;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullDouble.Undefined);
  Result := TOptNullDouble.From(ReadDouble(AName));
end;

function TParamsBase.GetOptInteger(const AName: string): IOptInteger;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullInteger.Undefined);
  Result := TOptNullInteger.From(ReadInteger(AName));
end;

function TParamsBase.GetOptInt64(const AName: string): IOptInt64;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullInt64.Undefined);
  Result := TOptNullInt64.From(ReadInt64(AName));
end;

function TParamsBase.GetOptCurrency(const AName: string): IOptCurrency;
begin
  if (not ParamExists(AName)) or ParamIsNull(AName) then
    Exit(TOptNullCurrency.Undefined);
  Result := TOptNullCurrency.From(ReadCurrency(AName));
end;

procedure TParamsBase.SetOptString(const AName: string; AValue: IOptString);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  WriteString(AName, AValue.Value);
end;

procedure TParamsBase.SetOptBoolean(const AName: string; AValue: IOptBoolean);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  WriteBoolean(AName, AValue.Value);
end;

procedure TParamsBase.SetOptDateTime(const AName: string; AValue: IOptDateTime);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  WriteDateTime(AName, AValue.Value);
end;

procedure TParamsBase.SetOptDouble(const AName: string; AValue: IOptDouble);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  WriteDouble(AName, AValue.Value);
end;

procedure TParamsBase.SetOptInteger(const AName: string; AValue: IOptInteger);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  WriteInteger(AName, AValue.Value);
end;

procedure TParamsBase.SetOptInt64(const AName: string; AValue: IOptInt64);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  WriteInt64(AName, AValue.Value);
end;

procedure TParamsBase.SetOptCurrency(const AName: string; AValue: IOptCurrency);
begin
  if not Assigned(AValue) or not AValue.HasValue then
    Exit;
  WriteCurrency(AName, AValue.Value);
end;

{ TDBFactory }

constructor TDBFactory.Create(const AConfig: IDatabaseConfig; const AProvider: IDBComponentProvider;
  const AContextTransactionProvider: IContextTransactionProvider; AOnPoolEvent: TPoolEventProc;
  AOnStatement: TStatementEventProc);
var
  LPoolConfig: IConnectionPoolConfig;
begin
  inherited Create;
  if not Assigned(AConfig) then
    raise EArgumentException.Create('TDBFactory: AConfig is required');
  if not Assigned(AProvider) then
    raise EArgumentException.Create('TDBFactory: AProvider is required');
  // Otherwise the pool never opens a connection and every acquire fails
  // with a timeout that hides the cause.
  if AConfig.PoolMaxConnections < 1 then
    raise EArgumentException.CreateFmt(
      'TDBFactory: PoolMaxConnections is %d; it must be at least 1', [AConfig.PoolMaxConnections]);
  // Resolved here too, not only when the first connection is built: a
  // failing initial connection becomes a pool event, so a wrong name would
  // only show up on the first acquire.
  TSQLDialectFactory.GetDialect(AConfig.SQLDialect);
  FConfig := AConfig;
  FComponentProvider := AProvider;
  FContextTransactionProvider := AContextTransactionProvider;

  LPoolConfig := TConnectionPoolConfig.Create;
  LPoolConfig.WaitMaxAttemps := FConfig.PoolWaitMaxAttemps;
  LPoolConfig.WaitMilliseconds := FConfig.PoolWaitMilliseconds;
  LPoolConfig.IniConnections := FConfig.PoolIniConnections;
  LPoolConfig.MaxConnections := FConfig.PoolMaxConnections;
  LPoolConfig.IdleTimeoutSeconds := FConfig.PoolIdleTimeoutSeconds;
  LPoolConfig.IdleCheckIntervalMs := FConfig.PoolIdleCheckIntervalMs;
  LPoolConfig.ValidateIdleSeconds := FConfig.PoolValidateIdleSeconds;
  LPoolConfig.KeepaliveSeconds := FConfig.PoolKeepaliveSeconds;

  // The provider is set before the pool: the pool's initial ramp-up already
  // calls CreateConnection.
  FPool := TConnectionPool.Create(Self, LPoolConfig, AOnPoolEvent, AOnStatement,
    PdbDbSystemName(FConfig.SQLDialect));
  FSqlLoader := TSQLLoader.Create(FConfig.SQLDirectory, FConfig.SqlSource);
end;

destructor TDBFactory.Destroy;
begin
  FSqlLoader.Free;
  inherited Destroy;
end;

function TDBFactory.GetProvider: IDBComponentProvider;
begin
  Result := FComponentProvider;
end;

procedure TDBFactory.SetProvider(AProvider: IDBComponentProvider);
begin
  if Assigned(AProvider) then
    FComponentProvider := AProvider;
end;

function TDBFactory.SqlLoader: TSQLLoader;
begin
  Result := FSqlLoader;
end;

function TDBFactory.GetPool: IDBConnectionPool;
begin
  Result := FPool;
end;

function TDBFactory.CreateConnection: IDBConnection;
begin
  Result := FComponentProvider.BuildConnection(FConfig);
end;

function TDBFactory.CreateTransaction(AConn: IDBConnection): ITransaction;
begin
  Result := FComponentProvider.BuildTransaction(AConn);
end;

function TDBFactory.CreateScopeTransaction(ATransaction: ITransaction): IScopeTransaction;
var
  LTraced: ITracedScopeTransaction;
begin
  if Assigned(FContextTransactionProvider) then
    Result := FComponentProvider.BuildScopeTransaction(ATransaction,
      FContextTransactionProvider.GetContextTransaction)
  else
    Result := FComponentProvider.BuildScopeTransaction(ATransaction, nil);
  if Supports(Result, ITracedScopeTransaction, LTraced) then
    LTraced.SetDbSystem(PdbDbSystemName(FConfig.SQLDialect));
end;

function TDBFactory.CreateQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
begin
  Result := FComponentProvider.BuildQuery(AConn, ATransaction);
end;

function TDBFactory.CreateSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
begin
  Result := FComponentProvider.BuildSqlScript(AConn, ATransaction);
end;

function TDBFactory.TestConnection(AConn: IDBConnection): Boolean;
var
  LTransaction: ITransaction;
  LQuery: IQuery;
begin
  Result := False;
  try
    if not AConn.IsConnected then
      AConn.Connect;
    LTransaction := FComponentProvider.BuildTransaction(AConn);
    LQuery := FComponentProvider.BuildQuery(AConn, LTransaction);
    LQuery.Sql := AConn.GetSQLDialect.GetPingSQL;
    LQuery.Open;
    LQuery.Close;
    if LTransaction.InTransaction then
      LTransaction.Rollback;
    Result := True;
  except
    // A dead connection is reported by the pool (pdrStaleCheckFailed event).
    on E: Exception do
      Result := False;
  end;
end;

end.
