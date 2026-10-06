unit PascalDb.Interfaces;

{$I pascaldb.inc}

{ The library's driver-agnostic contracts: connection, transaction (and
  scope transaction), query, result, parameters, script, pool, configuration
  and the factory (IDBFactory) that ties them together. No driver unit is
  referenced here — FireDAC, Zeos, SQLdb or any other comes in through an
  adapter that implements IDBComponentProvider/IDBFactory.

  It also owns the "broken connection" classification: when a native
  operation fails, IsConnectionBrokenError/MarkConnectionBrokenIfNeeded decide
  whether the physical connection must be discarded by the pool, and
  BuildDatabaseException replaces the driver's low-level exception (Access
  Violation included) with EDatabaseUnavailableException, whose message is
  safe to expose, with the original detail kept in
  OriginalClassName/OriginalMessage.

  IParams and IQueryResult expose the PascalCommon.Optionals types (IOptXxx,
  INullXxx, IOptNullXxx): an optional parameter is only bound when HasValue,
  and a nullable column is read as INullXxx.

  The minimum pascal-common-faa version is checked here, since every user of
  the library compiles this unit: an older copy of pascal-common-faa provided
  by the application fails the build with that message instead of a missing
  identifier somewhere inside the library. The library's own version is in
  PascalDb.Version (used here so it is always compiled; a consumer that
  checks it uses that unit). }

interface

uses
  Classes,
  SysUtils,
  PascalCommon.Version,
  PascalDb.Version,
  PascalCommon.Optionals,
  PascalDb.SqlSources,
  PascalDb.SqlLoader;

{$IF PASCALCOMMON_VERSION < 10300}
  {$MESSAGE FATAL 'pascal-db-faa needs pascal-common-faa 1.3.0 or later'}
{$IFEND}

type
  ISQLDialect = interface
    ['{5209436D-A6C9-4AA2-9258-BE8E5EE7A999}']
    function GetSavepointSQL(const AName: string): string;
    function GetRollbackToSavepointSQL(const AName: string): string;
    function GetReleaseSavepointSQL(const AName: string): string;
    function SupportsRelease: Boolean;
    /// Cheapest statement that forces a round-trip to the server — used to
    /// check whether an idle pooled connection is still alive.
    function GetPingSQL: string;
  end;

  IMigrationDialect = interface
    ['{A5F2C9E1-3B7D-4F8A-92C6-1E4D8B5F3A2C}']
    // Returns 1/0 in the "EXISTS" column — whether the SCHEMA_MIGRATIONS table exists
    function GetMigrationTableExistsSQL: string;
    // Returns the highest applied VERSION in the "VERSION" column (0 if empty)
    function GetMigrationLastVersionSQL: string;
    // INSERT with the named parameter :VERSION
    function GetMigrationInsertVersionSQL: string;
  end;

  // A separate interface, like IMigrationDialect, so a dialect registered by
  // an application before it existed still compiles; PdbPagingClause
  // (PascalDb.Paging) says so when a dialect doesn't implement it.
  IPagingDialect = interface
    ['{C3E81A57-6B2D-4F0E-9A14-7D5B2E8C9F31}']
    // Clause that goes after ORDER BY and returns at most ALimit rows,
    // skipping the first AOffset. ALimit >= 1, AOffset >= 0.
    function GetPagingClause(ALimit: Integer; AOffset: Int64): string;
  end;

  IDBConnection = interface
    ['{0763D2A3-9EAE-4F40-8580-E5F742C82105}']
    function GetNativeConnection: TObject;
    function IsConnected: Boolean;
    procedure Connect;
    procedure Commit;
    procedure Rollback;
    procedure Disconnect(Force: Boolean = False);
    function GetSQLDialect: ISQLDialect;
  end;

  IUnwrapDBConnection = interface
    ['{2F9E7DBA-9C39-4576-BAFB-4BA68819D35C}']
    function GetRealConnection: IDBConnection;
  end;

  // Raised (via BuildDatabaseException) instead of the native exception
  // (driver exception or EExternal/AV) whenever IsConnectionBrokenError
  // classifies the failure as a broken connection. It should never reach a
  // client or the logs as a context-free "Access violation at address ..." —
  // this class gives a stable, recognizable type to what is, in fact, always
  // the same root cause (database server down / connection lost), no matter
  // which native call happened to crash. `Message` is generic on purpose
  // (safe to expose to a client); the original detail (class + text of the
  // native exception, AV address included) is kept only in
  // OriginalClassName/OriginalMessage, for whoever logs/investigates — Delphi
  // has no native "inner exception", so this is how the context is preserved
  // without leaking noise to the client. An HTTP layer on top of this library
  // would typically map this class to 503.
  EDatabaseUnavailableException = class(Exception)
  private
    FOriginalClassName: string;
    FOriginalMessage: string;
  public
    constructor Create(AOriginalException: Exception);
    property OriginalClassName: string read FOriginalClassName;
    property OriginalMessage: string read FOriginalMessage;
  end;

  // Raised by the pool's AcquireConnection/AcquireQuery when opening a new
  // connection fails, instead of the driver's own exception (a different class
  // for each driver, which made a retry loop depend on the adapter). A
  // subclass of EDatabaseUnavailableException, so one handler covers "lost in
  // use" and "could not connect"; catch this class first to tell them apart.
  // The acquire can't tell "server down" from "wrong password" or "client
  // library missing" portably, so the message doesn't promise that trying
  // again helps: OriginalClassName/OriginalMessage have the driver's detail.
  // Opening a connection outside the pool (IDBFactory.CreateConnection) still
  // raises the driver's exception.
  EDatabaseConnectException = class(EDatabaseUnavailableException)
  public
    constructor Create(AOriginalException: Exception);
  end;

  // Raised by Open/ExecSql instead of the driver's exception when a statement
  // couldn't change data because of another transaction: it waited for that
  // transaction's lock longer than IDatabaseConfig.LockTimeoutMs, the driver
  // doesn't wait at all (Zeos on Firebird without LockTimeoutMs), the row was
  // changed by a transaction that committed meanwhile (update conflict), or
  // the database detected a deadlock. One class for all of them because
  // Firebird 3+ reports an expired lock timeout with the same codes as an
  // update conflict (deadlock, update conflict, concurrent transaction), and
  // the remedy is the same: roll back and, if it makes sense, repeat the
  // whole unit of work. The database is fine and the connection stays in
  // the pool. Each adapter recognizes its driver's errors (Firebird GDS
  // codes, PostgreSQL SQLSTATE 55P03/40P01/40001, SQLite SQLITE_BUSY and
  // SQLITE_LOCKED); OriginalClassName/OriginalMessage keep the driver's
  // detail. An HTTP layer would typically answer 409.
  ELockConflictException = class(Exception)
  private
    FOriginalClassName: string;
    FOriginalMessage: string;
  public
    constructor Create(AOriginalException: Exception);
    property OriginalClassName: string read FOriginalClassName;
    property OriginalMessage: string read FOriginalMessage;
  end;

  // Which kind of constraint a statement violated (see
  // EConstraintViolationException).
  TConstraintViolationKind = (
    cvUnique,      // a primary key or unique constraint: the value already exists
    cvForeignKey,  // a reference to a row that doesn't exist, or a delete/update of a referenced row
    cvNotNull,     // NULL in a NOT NULL column
    cvCheck);      // a CHECK constraint

  // Raised by Open/ExecSql (and batches, and a commit that checks deferred
  // constraints) instead of the driver's exception when a statement violated
  // a constraint: the data the caller sent is what's wrong, so retrying the
  // same statement fails again. Kind says which constraint; the message is
  // generic on purpose (safe to expose to a client), and
  // OriginalClassName/OriginalMessage keep the driver's detail (constraint
  // name included). The database is fine and the connection stays in the
  // pool; on PostgreSQL the transaction can only be rolled back. Each adapter
  // recognizes its driver's errors (Firebird GDS codes, PostgreSQL SQLSTATE
  // class 23, MySQL/MariaDB and SQL Server error numbers, SQLite's
  // constraint errors; FireDAC's own error kinds). An HTTP layer would
  // typically answer 409 for cvUnique/cvForeignKey and 422 for the others.
  EConstraintViolationException = class(Exception)
  private
    FKind: TConstraintViolationKind;
    FOriginalClassName: string;
    FOriginalMessage: string;
  public
    constructor Create(AKind: TConstraintViolationKind; AOriginalException: Exception);
    property Kind: TConstraintViolationKind read FKind;
    property OriginalClassName: string read FOriginalClassName;
    property OriginalMessage: string read FOriginalMessage;
  end;

  // Implemented only by the wrapper the pool returns from AcquireConnection
  // (PascalDb.Pool.TConnectionWrapper) — never by the "real" adapters, which
  // know nothing about the pool. See MarkConnectionBrokenIfNeeded below: it is
  // the single point that decides when to call MarkForDiscard, from the
  // places where the library touches the native driver (Query.Open/ExecSql,
  // transaction Commit/Rollback).
  IDiscardableConnection = interface
    ['{6C8B2E39-6D40-4C4E-9E77-8B5B0DDE9E56}']
    procedure MarkForDiscard;
    function ShouldDiscard: Boolean;
  end;

  ITransaction = interface
    ['{DE6B1218-7FCD-4729-8D58-3CBCB3E2BCD4}']
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;
    function GetConnection: IDBConnection;
    function GetNativeTransaction: TObject;
    /// Runs a statement that returns no rows; returns the rows it inserted,
    /// updated or deleted, or -1 when the driver can't tell (see IQuery.ExecSql).
    function ExecSql(const ASql: string): Int64;
  end;

  IScopeTransaction = interface
    ['{27E0E126-6765-434E-9342-33A83468DE23}']
    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;
    function IsMain: Boolean;
    function GetOriginalTransaction: ITransaction;
    property OriginalTransaction: ITransaction read GetOriginalTransaction;
  end;

  { IQueryResult }

  IQueryResult = interface
    ['{6F5B03E4-49C4-487C-8AB8-742BAA268906}']
    function GetAsBoolean(const AName: string): Boolean;
    function GetAsDateTime(const AName: string): TDateTime;
    function GetAsInteger(const AName: string): Integer;
    function GetAsInt64(const AName: string): Int64;
    function GetAsString(const AName: string): string;
    function GetAsCurrency(const AName: string): Currency;
    function GetNullableBoolean(const AName: string): INullBoolean;
    function GetNullableDateTime(const AName: string): INullDateTime;
    function GetNullableInteger(const AName: string): INullInteger;
    function GetNullableInt64(const AName: string): INullInt64;
    function GetNullableString(const AName: string): INullString;
    function GetNullableCurrency(const AName: string): INullCurrency;
    function IsEmpty: Boolean;
    function FieldCount: Integer;
    function FieldValue(AIndex: Integer): Variant;
    function RecordCount: Integer;
    procedure Next;
    function Eof: Boolean;
    property NullableStrings[const AName: string]: INullString read GetNullableString;
    property NullableIntegers[const AName: string]: INullInteger read GetNullableInteger;
    property NullableInt64[const AName: string]: INullInt64 read GetNullableInt64;
    property NullableDateTimes[const AName: string]: INullDateTime read GetNullableDateTime;
    property NullableBooleans[const AName: string]: INullBoolean read GetNullableBoolean;
    property NullableCurrencies[const AName: string]: INullCurrency read GetNullableCurrency;
    property Strings[const AName: string]: string read GetAsString;
    property Integers[const AName: string]: Integer read GetAsInteger;
    property Int64s[const AName: string]: Int64 read GetAsInt64;
    property DateTimes[const AName: string]: TDateTime read GetAsDateTime;
    property Booleans[const AName: string]: Boolean read GetAsBoolean;
    property Currencies[const AName: string]: Currency read GetAsCurrency;
  end;

  { IParams }

  IParams = interface
    ['{4A386E9D-10C0-485C-83DC-8A8B663EE8BB}']
    function GetString(const AName: string): string;
    function GetBoolean(const AName: string): Boolean;
    function GetDateTime(const AName: string): TDateTime;
    function GetInteger(const AName: string): Integer;
    function GetInt64(const AName: string): Int64;
    function GetDouble(const AName: string): Double;
    function GetCurrency(const AName: string): Currency;

    function GetOptNullString(const AName: string): IOptNullString;
    function GetOptNullBoolean(const AName: string): IOptNullBoolean;
    function GetOptNullDateTime(const AName: string): IOptNullDateTime;
    function GetOptNullInteger(const AName: string): IOptNullInteger;
    function GetOptNullInt64(const AName: string): IOptNullInt64;
    function GetOptNullDouble(const AName: string): IOptNullDouble;
    function GetOptNullCurrency(const AName: string): IOptNullCurrency;

    function GetNullString(const AName: string): INullString;
    function GetNullBoolean(const AName: string): INullBoolean;
    function GetNullDateTime(const AName: string): INullDateTime;
    function GetNullInteger(const AName: string): INullInteger;
    function GetNullInt64(const AName: string): INullInt64;
    function GetNullDouble(const AName: string): INullDouble;
    function GetNullCurrency(const AName: string): INullCurrency;

    function GetOptString(const AName: string): IOptString;
    function GetOptBoolean(const AName: string): IOptBoolean;
    function GetOptDateTime(const AName: string): IOptDateTime;
    function GetOptInteger(const AName: string): IOptInteger;
    function GetOptInt64(const AName: string): IOptInt64;
    function GetOptDouble(const AName: string): IOptDouble;
    function GetOptCurrency(const AName: string): IOptCurrency;

    procedure SetString(const AName: string; AValue: string);
    procedure SetBoolean(const AName: string; AValue: Boolean);
    procedure SetDateTime(const AName: string; AValue: TDateTime);
    procedure SetInteger(const AName: string; AValue: Integer);
    procedure SetInt64(const AName: string; AValue: Int64);
    procedure SetDouble(const AName: string; AValue: Double);
    procedure SetCurrency(const AName: string; AValue: Currency);

    procedure SetOptNullBoolean(const AName: string; AValue: IOptNullBoolean);
    procedure SetOptNullDateTime(const AName: string; AValue: IOptNullDateTime);
    procedure SetOptNullInteger(const AName: string; AValue: IOptNullInteger);
    procedure SetOptNullInt64(const AName: string; AValue: IOptNullInt64);
    procedure SetOptNullString(const AName: string; AValue: IOptNullString);
    procedure SetOptNullDouble(const AName: string; AValue: IOptNullDouble);
    procedure SetOptNullCurrency(const AName: string; AValue: IOptNullCurrency);

    procedure SetNullBoolean(const AName: string; AValue: INullBoolean);
    procedure SetNullDateTime(const AName: string; AValue: INullDateTime);
    procedure SetNullInteger(const AName: string; AValue: INullInteger);
    procedure SetNullInt64(const AName: string; AValue: INullInt64);
    procedure SetNullString(const AName: string; AValue: INullString);
    procedure SetNullDouble(const AName: string; AValue: INullDouble);
    procedure SetNullCurrency(const AName: string; AValue: INullCurrency);

    procedure SetOptBoolean(const AName: string; AValue: IOptBoolean);
    procedure SetOptDateTime(const AName: string; AValue: IOptDateTime);
    procedure SetOptInteger(const AName: string; AValue: IOptInteger);
    procedure SetOptInt64(const AName: string; AValue: IOptInt64);
    procedure SetOptString(const AName: string; AValue: IOptString);
    procedure SetOptDouble(const AName: string; AValue: IOptDouble);
    procedure SetOptCurrency(const AName: string; AValue: IOptCurrency);

    property OptNullStrings[const AName: string]: IOptNullString read GetOptNullString write SetOptNullString;
    property OptNullIntegers[const AName: string]: IOptNullInteger read GetOptNullInteger write SetOptNullInteger;
    property OptNullInt64[const AName: string]: IOptNullInt64 read GetOptNullInt64 write SetOptNullInt64;
    property OptNullDateTimes[const AName: string]: IOptNullDateTime read GetOptNullDateTime write SetOptNullDateTime;
    property OptNullBooleans[const AName: string]: IOptNullBoolean read GetOptNullBoolean write SetOptNullBoolean;
    property OptNullDoubles[const AName: string]: IOptNullDouble read GetOptNullDouble write SetOptNullDouble;
    property OptNullCurrencies[const AName: string]: IOptNullCurrency read GetOptNullCurrency write SetOptNullCurrency;

    property NullStrings[const AName: string]: INullString read GetNullString write SetNullString;
    property NullIntegers[const AName: string]: INullInteger read GetNullInteger write SetNullInteger;
    property NullInt64[const AName: string]: INullInt64 read GetNullInt64 write SetNullInt64;
    property NullDateTimes[const AName: string]: INullDateTime read GetNullDateTime write SetNullDateTime;
    property NullBooleans[const AName: string]: INullBoolean read GetNullBoolean write SetNullBoolean;
    property NullDoubles[const AName: string]: INullDouble read GetNullDouble write SetNullDouble;
    property NullCurrencies[const AName: string]: INullCurrency read GetNullCurrency write SetNullCurrency;

    property OptStrings[const AName: string]: IOptString read GetOptString write SetOptString;
    property OptIntegers[const AName: string]: IOptInteger read GetOptInteger write SetOptInteger;
    property OptInt64[const AName: string]: IOptInt64 read GetOptInt64 write SetOptInt64;
    property OptDateTimes[const AName: string]: IOptDateTime read GetOptDateTime write SetOptDateTime;
    property OptBooleans[const AName: string]: IOptBoolean read GetOptBoolean write SetOptBoolean;
    property OptDoubles[const AName: string]: IOptDouble read GetOptDouble write SetOptDouble;
    property OptCurrencies[const AName: string]: IOptCurrency read GetOptCurrency write SetOptCurrency;

    property Strings[const AName: string]: string read GetString write SetString;
    property Integers[const AName: string]: Integer read GetInteger write SetInteger;
    property Int64s[const AName: string]: Int64 read GetInt64 write SetInt64;
    property DateTimes[const AName: string]: TDateTime read GetDateTime write SetDateTime;
    property Booleans[const AName: string]: Boolean read GetBoolean write SetBoolean;
    property Doubles[const AName: string]: Double read GetDouble write SetDouble;
    property Currencies[const AName: string]: Currency read GetCurrency write SetCurrency;
  end;

  IQuery = interface
    ['{1FA6B8E8-750E-4748-825D-E83C980C02D8}']
    function GetParams: IParams;
    procedure SetSql(const ASql: string);
    function GetSql: string;
    function Open: IQueryResult;
    procedure Close;
    /// Runs a statement that returns no rows; returns the rows it inserted,
    /// updated or deleted, or -1 when the driver can't tell (DDL, for
    /// example). An UPDATE counts every row its WHERE matched, including rows
    /// whose values didn't change — MySQL/MariaDB too (their default is to
    /// count only changed rows; the adapters ask for matched rows), so 0 means
    /// "nothing matched" on every database. Calling it as a statement
    /// (LQuery.ExecSql;) still compiles.
    function ExecSql: Int64;
    function GetConnection: IDBConnection;
    function GetTransaction: ITransaction;
    property Sql: string read GetSql write SetSql;
    property Params: IParams read GetParams;
  end;

  /// The value type a parameter is meant to hold — lets a driver set the
  /// right DataType on a NULL parameter (some drivers reject untyped NULLs)
  /// and type a batch's parameter arrays.
  TPdbParamType = (pptString, pptBoolean, pptDateTime, pptDouble, pptInteger, pptInt64, pptCurrency);

  { IBatch
    One statement run for many rows of parameters (TBatch.New, in
    PascalDb.Batch): set a row's values through Params, call AddRow, repeat,
    then Execute. Rows are sent MaxRows at a time, in the query's
    transaction; where the driver can, as one array operation (see
    INativeBatchQuery), otherwise one ExecSql per row. }

  IBatch = interface
    ['{04B873B6-AD25-48E0-A726-D11E328AAFF0}']
    function GetParams: IParams;
    function GetMaxRows: Integer;
    procedure SetMaxRows(AValue: Integer);
    /// Ends the current row: its values are kept, Params starts empty for the
    /// next one. Sends the pending rows when they reach MaxRows.
    procedure AddRow;
    /// Rows added and not sent yet.
    function PendingRows: Integer;
    /// Sends the pending rows (none: does nothing).
    procedure Execute;
    /// True when the rows go to the database as an array operation, False
    /// when they go one ExecSql at a time.
    function IsNative: Boolean;
    property Params: IParams read GetParams;
    property MaxRows: Integer read GetMaxRows write SetMaxRows;
  end;

  { IBatchRows
    The rows a batch hands to INativeBatchQuery.ExecBatch: a fixed list of
    parameters, each with one type, and a value or NULL for each of them in
    every row. Reading a NULL with AsXxx is an error; check IsNull first. }

  IBatchRows = interface
    ['{817B34EB-5334-472D-B1DF-D3BE71DBC256}']
    function RowCount: Integer;
    function ParamCount: Integer;
    function ParamName(AParam: Integer): string;
    function ParamType(AParam: Integer): TPdbParamType;
    function IsNull(ARow, AParam: Integer): Boolean;
    function AsString(ARow, AParam: Integer): string;
    function AsBoolean(ARow, AParam: Integer): Boolean;
    function AsDateTime(ARow, AParam: Integer): TDateTime;
    function AsDouble(ARow, AParam: Integer): Double;
    function AsInteger(ARow, AParam: Integer): Integer;
    function AsInt64(ARow, AParam: Integer): Int64;
    function AsCurrency(ARow, AParam: Integer): Currency;
    /// The longest string of a pptString parameter (0 when every row is NULL).
    function MaxLength(AParam: Integer): Integer;
  end;

  { INativeBatchQuery
    Optional, on an adapter's IQuery: runs the query's SQL once for every row
    of ARows as one driver operation (FireDAC's Array DML). TBatch uses it
    when SupportsNativeBatch is True and runs one
    ExecSql per row otherwise, so an adapter without it still runs batches.
    The pool's query wrapper forwards it. }

  INativeBatchQuery = interface
    ['{798E4071-150E-48AF-8F53-C068F15366E7}']
    function SupportsNativeBatch: Boolean;
    procedure ExecBatch(const ARows: IBatchRows);
  end;

  { ISqlScript }

  ISqlScript = interface
    ['{2AC04627-1987-44A7-9A00-7685D6B05D98}']
    procedure ExecuteScript(ATerminator: string = ';');
    function GetConnection: IDBConnection;
    function GetScript: TStrings;
    function GetTransaction: ITransaction;
    procedure SetScript(AValue: TStrings);
    property Script: TStrings read GetScript write SetScript;
  end;

  // Counters accumulated since the pool was created + current state — meant
  // for periodic reading (health check, metrics timer), not for reacting to
  // each change. Complements TPoolEvent (PascalDb.Pool): the event covers
  // "it happened now", the snapshot covers "how much has happened in total
  // and what it looks like now".
  TPoolSnapshot = record
    ActiveConnections: Integer;  // live physical connections now (idle + in use)
    PoolSize: Integer;           // idle connections in the pool now
    MaxConnections: Integer;
    IniConnections: Integer;
    TotalCreated: Int64;         // physical connections created since start (ramp-up + growth under load)
    TotalDiscarded: Int64;       // connections discarded after a failed reconnect or liveness check
    TotalTimeouts: Int64;        // AcquireConnection calls that ran out of wait attempts (EPoolTimeoutException)
    TotalIdleSwept: Int64;       // connections closed by PoolIdleTimeoutSeconds
  end;

  { IDBConnectionPool }

  IDBConnectionPool = interface
    ['{B4214985-5C99-4323-AD5F-3DC4B5AB1194}']
    function AcquireConnection: IDBConnection;
    function GetWaitMaxAttemps: Integer;
    function GetWaitMilliseconds: Integer;
    function AcquireQuery(out AQuery: IQuery; ATransaction: ITransaction = nil): IScopeTransaction;
    function GetActiveConnections: Integer;
    function GetPoolSize: Integer;
    // Current state + accumulated counters, for periodic logging/metrics
    // (see TPoolSnapshot). Implementations that don't track the totals (e.g.
    // test/mock pools) may return the counters as zero.
    function GetSnapshot: TPoolSnapshot;
    property WaitMaxAttemps: Integer read GetWaitMaxAttemps;
    property WaitMilliseconds: Integer read GetWaitMilliseconds;
  end;

  IDBConnectionPoolInternalActions = interface
    ['{C1EA34EC-6E45-4B99-A2D2-2AEAB4BF382D}']
    procedure ReleaseConnection(AConn: IDBConnection);
    // End of life of a connection that came back marked via
    // IDiscardableConnection (MarkConnectionBrokenIfNeeded) — discards it
    // instead of re-queueing, without waiting for the next AcquireConnection
    // to prove it is dead.
    procedure DiscardConnection(AConn: IDBConnection);
    procedure ReleaseQuery(var AQuery: IQuery);
  end;

  { IDatabaseConfig }

  IDatabaseConfig = interface
    ['{1B2EB232-446B-4F04-8A1B-11757D7B6F17}']
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
    property PoolWaitMaxAttemps: Integer read GetPoolWaitMaxAttemps write SetPoolWaitMaxAttemps;
    property PoolWaitMilliseconds: Integer read GetPoolWaitMilliseconds write SetPoolWaitMilliseconds;
    property PoolMaxConnections: Integer read GetPoolMaxConnections write SetPoolMaxConnections;
    property PoolIniConnections: Integer read GetPoolIniConnections write SetPoolIniConnections;
    /// Seconds a connection may stay idle in the pool before being closed
    /// (never below PoolIniConnections). 0 (default) = off, identical to the
    /// behavior before this property existed.
    property PoolIdleTimeoutSeconds: Integer read GetPoolIdleTimeoutSeconds write SetPoolIdleTimeoutSeconds;
    /// Interval between runs of the pool's background thread (idle sweep and
    /// keepalive). Only matters when PoolIdleTimeoutSeconds > 0 or
    /// PoolKeepaliveSeconds > 0. Values <= 0 fall back to the default
    /// (30000ms).
    property PoolIdleCheckIntervalMs: Integer read GetPoolIdleCheckIntervalMs write SetPoolIdleCheckIntervalMs;
    /// An idle connection not known to work for at least this many seconds
    /// (since its release or its last keepalive ping) gets the dialect's ping
    /// before it is handed out, and is discarded if the ping fails.
    /// 120 (default); 0 = ping on every acquire (one extra round trip each
    /// time); negative = never.
    property PoolValidateIdleSeconds: Integer read GetPoolValidateIdleSeconds write SetPoolValidateIdleSeconds;
    /// The pool's background thread pings idle connections not known to work
    /// for this many seconds, and discards the ones that fail. Checked every
    /// PoolIdleCheckIntervalMs. 0 (default) = off; negative values are ignored.
    property PoolKeepaliveSeconds: Integer read GetPoolKeepaliveSeconds write SetPoolKeepaliveSeconds;
    /// The longest a statement waits for a lock held by another transaction
    /// (a row being updated, SQLite's write lock) before failing with
    /// ELockConflictException. 0 (default) = each database's own behavior:
    /// Firebird and PostgreSQL wait until the lock is released, SQLite waits
    /// the adapter's busy timeout (5000 ms). Firebird counts whole seconds,
    /// so the value is rounded up. Negative values are ignored.
    property LockTimeoutMs: Integer read GetLockTimeoutMs write SetLockTimeoutMs;
    property SQLDialect: string read GetSQLDialect write SetSQLDialect;
    /// Logical SQL directory handed to the factory's TSQLLoader (e.g. 'FB').
    property SQLDirectory: string read GetSQLDirectory write SetSQLDirectory;
    /// Where the factory's TSQLLoader reads SQL from; nil = embedded resources.
    property SqlSource: ISqlSource read GetSqlSource write SetSqlSource;
    /// Driver connection settings as Name=Value lines; each adapter documents
    /// the names it understands.
    property ConnectionParams: TStrings read GetConnectionParams;
  end;

  IContextTransaction = interface
    ['{2DE17937-9016-4766-B186-B91033EDD8E4}']
    procedure Apply(ATransaction: ITransaction);
  end;

  IContextTransactionProvider = interface
    ['{F96AB110-4A2A-4286-A941-0C5A24FC50AB}']
    function GetContextTransaction: IContextTransaction;
  end;

  IDBComponentProvider = interface
    ['{A4738719-3191-4BA0-81A0-12AB8AE80483}']
    function BuildConnection(AConfig: IDatabaseConfig): IDBConnection;
    function BuildTransaction(AConn: IDBConnection): ITransaction;
    function BuildScopeTransaction(ATransaction: ITransaction; AContextTransaction: IContextTransaction): IScopeTransaction;
    function BuildQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function BuildSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
  end;

  IDBComponentProviderSupport = interface
    ['{10C14706-ABF5-4238-ADEF-FA41C679A555}']
    function GetProvider: IDBComponentProvider;
    procedure SetProvider(AProvider: IDBComponentProvider);
  end;

  IDBFactory = interface
    ['{7FF3BE63-5205-48AF-B52F-59F927787AE8}']
    function SqlLoader: TSQLLoader;
    function GetPool: IDBConnectionPool;
    function CreateConnection: IDBConnection;
    function CreateTransaction(AConn: IDBConnection): ITransaction;
    function CreateScopeTransaction(ATransaction: ITransaction): IScopeTransaction;
    function CreateQuery(AConn: IDBConnection; ATransaction: ITransaction): IQuery;
    function CreateSqlScript(AConn: IDBConnection; ATransaction: ITransaction): ISqlScript;
    function TestConnection(AConn: IDBConnection): Boolean;
  end;

// Classifies whether an exception raised during a database operation
// (Query, Commit, Rollback) means the physical connection was left in a
// compromised state and must not be reused:
// - EExternal (base of EAccessViolation, EStackOverflow, EPrivilege, ...) —
//   the CPU faulted inside a native call; the connection object can no
//   longer be trusted, whatever IsConnected reports afterwards (hence the
//   short-circuit "or": IsConnected is never called after an EExternal).
// - Any other exception followed by IsConnected = False — the connection
//   really dropped (e.g. server unavailable).
// It deliberately does NOT cover "normal" data exceptions (constraint
// violation, invalid type, etc.) while the connection is still
// IsConnected = True — the connection is still healthy there, only the
// operation failed; discarding in that case would churn connections on
// every common business error (e.g. duplicate key) for no reason.
function IsConnectionBrokenError(E: Exception; AConn: IDBConnection): Boolean;

// Marks AConn for discard (via IDiscardableConnection) if E indicates a
// broken connection — see IsConnectionBrokenError. Returns whether it marked
// it; becomes a no-op (returns False) if AConn doesn't implement
// IDiscardableConnection (connection obtained outside the pool, or a
// test/mock adapter) or isn't Assigned.
function MarkConnectionBrokenIfNeeded(AConn: IDBConnection; E: Exception): Boolean;

// Called wherever the library touches the native driver: TQueryWrapper.Open/
// ExecSql and TQueryResultWrapper (field reads on the IQueryResult returned
// by Open — covers the AV that only happens mid-fetch, after Open already
// returned successfully) in PascalDb.Pool; and, in adapters, the
// transaction's StartTransaction/Commit/Rollback/ExecSql — StartTransaction
// is the first real round-trip to the server when a repository calls
// LScope.StartTransaction explicitly BEFORE its try/except (a common pattern
// for Insert/Update, also used by Find/Get code that opens a transaction
// early).
//
// Marks the connection (MarkConnectionBrokenIfNeeded) and returns the
// exception to re-raise: a NEW EDatabaseUnavailableException if E was
// classified as a broken connection (never lets an EAccessViolation or any
// other low-level driver exception leak to the caller as is — that is what
// used to reach HTTP clients as a context-free "Access violation at address
// ..." before this function existed), or nil otherwise (a normal data error,
// e.g. a constraint violation — the caller must re-raise E as is).
//
// Why it returns instead of re-raising itself: "raise E;" (re-raising BY
// REFERENCE an object caught in ANOTHER procedure's frame) causes an Access
// Violation in this Delphi version — the only safe options are raising a NEW
// exception (`raise Result;`, safe from any frame) or a bare "raise;"
// LEXICALLY inside the catcher's own except block. That is why every call
// site follows the pattern:
//   except
//     on E: Exception do
//     begin
//       LNewE := BuildDatabaseException(AConn, E);
//       if Assigned(LNewE) then raise LNewE;
//       raise;
//     end;
//   end;
function BuildDatabaseException(AConn: IDBConnection; E: Exception): Exception;

implementation

function IsConnectionBrokenError(E: Exception; AConn: IDBConnection): Boolean;
begin
  Result := (E is EExternal) or (Assigned(AConn) and (not AConn.IsConnected));
end;

function MarkConnectionBrokenIfNeeded(AConn: IDBConnection; E: Exception): Boolean;
var
  LDiscardable: IDiscardableConnection;
begin
  Result := Assigned(AConn) and IsConnectionBrokenError(E, AConn);
  if Result and Supports(AConn, IDiscardableConnection, LDiscardable) then
    LDiscardable.MarkForDiscard;
end;

function BuildDatabaseException(AConn: IDBConnection; E: Exception): Exception;
begin
  if MarkConnectionBrokenIfNeeded(AConn, E) then
    Result := EDatabaseUnavailableException.Create(E)
  else
    Result := nil;
end;

{ EDatabaseUnavailableException }

constructor EDatabaseUnavailableException.Create(AOriginalException: Exception);
begin
  inherited Create('Database unavailable or connection lost. Please try again shortly.');
  if Assigned(AOriginalException) then
  begin
    FOriginalClassName := AOriginalException.ClassName;
    FOriginalMessage := AOriginalException.Message;
  end;
end;

{ ELockConflictException }

constructor ELockConflictException.Create(AOriginalException: Exception);
begin
  inherited Create('The data is locked or was changed by another transaction.');
  if Assigned(AOriginalException) then
  begin
    FOriginalClassName := AOriginalException.ClassName;
    FOriginalMessage := AOriginalException.Message;
  end;
end;

{ EConstraintViolationException }

constructor EConstraintViolationException.Create(AKind: TConstraintViolationKind;
  AOriginalException: Exception);
const
  MESSAGES: array[TConstraintViolationKind] of string = (
    'A record with the same key already exists.',
    'The record refers to a record that doesn''t exist, or is referred to by another record.',
    'A required value is missing.',
    'A value breaks a rule of the table.');
begin
  inherited Create(MESSAGES[AKind]);
  FKind := AKind;
  if Assigned(AOriginalException) then
  begin
    FOriginalClassName := AOriginalException.ClassName;
    FOriginalMessage := AOriginalException.Message;
  end;
end;

{ EDatabaseConnectException }

constructor EDatabaseConnectException.Create(AOriginalException: Exception);
begin
  inherited Create(AOriginalException);
  Message := 'Could not connect to the database.';
end;

end.
