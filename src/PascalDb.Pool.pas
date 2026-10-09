unit PascalDb.Pool;

{$I pascaldb.inc}

{ Connection pool (TConnectionPool) on top of any IDBFactory.

  AcquireConnection/AcquireQuery hand out "wrapped" connections: when the
  last reference to the wrapper (connection, query or scope transaction) is
  released, the connection goes back to the pool by itself — or is
  discarded, if it was marked as broken during use (see
  IDiscardableConnection and BuildDatabaseException in PascalDb.Interfaces).

  Behavior configurable through IConnectionPoolConfig:
  - ramp-up of IniConnections in the constructor, which NEVER brings the
    application down if the database is offline — failures become events
    and the next Acquire tries again;
  - on-demand growth up to MaxConnections, with bounded waiting
    (WaitMaxAttemps × WaitMilliseconds) and EPoolTimeoutException when it
    runs out;
  - liveness check (the dialect's ping) of connections idle for
    ValidateIdleSeconds or more, and discard of dead ones; once any
    connection proves dead, every idle one gets the check on its next
    acquire (MarkIdleConnectionsSuspect);
  - sweep of idle connections (IdleTimeoutSeconds), in a dedicated thread
    (TIdleSweepThread) that never closes below IniConnections;
  - keepalive (KeepaliveSeconds): the same thread pings idle connections
    before a firewall or the server's idle limit drops them.

  Idle connections are handed out last in, first out: an acquire takes the
  connection released most recently. The pool used to be FIFO, which spread
  the load over every open connection in turn; under a light, steady load
  none of them was ever idle for IdleTimeoutSeconds, so a pool that grew in a
  peak never shrank back. With LIFO the same few connections do the work and
  the surplus ages out. FPool is kept ordered by LastRelease (a release
  appends): the oldest idle connection is always at index 0, the next one to
  hand out at the end.

  Observability: events (TPoolEventProc) only for what is abnormal or for
  capacity growth, never for the happy path; and GetSnapshot for periodic
  reads of state + accumulated counters.

  Tracing (PascalCommon.Tracing): while TPcTracing.Enabled, every statement
  of a pooled query gets a client span (Open, ExecSql, a native batch), named
  after the statement's first word, with db.system.name, db.query.text and,
  on a failure, error.type and the error status; and an acquire that has to
  wait gets a "pool wait" span, from the first wait until it has a connection
  or gives up. Disabled, nothing is created, not even the ids: a statement
  doesn't pay for tracing it doesn't use. Each span starts and ends inside the
  call, on the caller's thread. A statement inside a transaction is a child
  of the transaction's span (ITransactionSpan; TScopeTransaction in
  PascalDb.Adapter.Base), which is detached and may end on any thread;
  otherwise, and the pool wait always, a child of the thread's current span
  (an HTTP request's). No parameter values, as in TStatementInfo.

  Dual-compiler: the sweep thread is a TThread subclass (not
  CreateAnonymousThread), and TPoolEventProc follows PASCALDB_FUNCREFS
  (pascaldb.inc): closure or method in Delphi, method in FPC 3.2.2. Time and
  waiting go through PascalCommon.SystemContext, so tests control the clock
  and Sleep. Idle times are measured with the monotonic TTicker, never the wall
  clock: changing the system time must not age or rejuvenate a connection. }

interface

uses
  Classes,
  SysUtils,
  Generics.Collections,
  SyncObjs,
  PascalDb.Interfaces,
  PascalCommon.SystemContext,
  PascalCommon.Optionals,
  PascalCommon.Tracing;

type

  { EPoolTimeoutException }

  EPoolTimeoutException = class(Exception)
  public
    constructor Create(Active, Max, InQueue, Attempts: Integer);
  end;

  { TConnectionItem }

  TConnectionItem = record
    Connection: IDBConnection;
    LastRelease: UInt64; // TTicker.NowMs when it came back to the pool (idle since)
    // TTicker.NowMs when it was last known to work: its release or a
    // successful keepalive ping. The acquire check (ValidateIdleSeconds) and
    // the keepalive measure from here; the idle sweep from LastRelease, so a
    // ping never counts as use.
    LastAlive: UInt64;
    class function New(AConn: IDBConnection): TConnectionItem; static;
  end;

  { IConnectionPoolConfig }

  IConnectionPoolConfig = interface
    ['{2AD13457-7932-46C0-B2C4-A9CE804A9672}']
    function GetIniConnections: Integer;
    function GetMaxConnections: Integer;
    function GetWaitMaxAttemps: Integer;
    function GetWaitMilliseconds: Integer;
    function GetIdleTimeoutSeconds: Integer;
    function GetIdleCheckIntervalMs: Integer;
    function GetValidateIdleSeconds: Integer;
    function GetKeepaliveSeconds: Integer;
    procedure SetIniConnections(AValue: Integer);
    procedure SetMaxConnections(AValue: Integer);
    procedure SetWaitMaxAttemps(AValue: Integer);
    procedure SetWaitMilliseconds(AValue: Integer);
    procedure SetIdleTimeoutSeconds(AValue: Integer);
    procedure SetIdleCheckIntervalMs(AValue: Integer);
    procedure SetValidateIdleSeconds(AValue: Integer);
    procedure SetKeepaliveSeconds(AValue: Integer);
    property IniConnections: Integer read GetIniConnections write SetIniConnections;
    property MaxConnections: Integer read GetMaxConnections write SetMaxConnections;
    property WaitMaxAttemps: Integer read GetWaitMaxAttemps write SetWaitMaxAttemps;
    property WaitMilliseconds: Integer read GetWaitMilliseconds write SetWaitMilliseconds;
    /// Seconds a connection may stay idle in the pool before being closed
    /// (never below IniConnections). 0 (default) = off.
    property IdleTimeoutSeconds: Integer read GetIdleTimeoutSeconds write SetIdleTimeoutSeconds;
    /// Interval between runs of the background thread (idle sweep and
    /// keepalive). Only matters when IdleTimeoutSeconds > 0 or
    /// KeepaliveSeconds > 0. Values <= 0 fall back to the default (30000ms).
    property IdleCheckIntervalMs: Integer read GetIdleCheckIntervalMs write SetIdleCheckIntervalMs;
    /// An idle connection not known to work for at least this many seconds
    /// (since its release or its last keepalive ping) gets the dialect's ping
    /// before it is handed out, and is discarded if the ping fails.
    /// 120 (default); 0 = ping on every acquire; negative = never.
    property ValidateIdleSeconds: Integer read GetValidateIdleSeconds write SetValidateIdleSeconds;
    /// The background thread pings idle connections not known to work for
    /// this many seconds, and discards the ones that fail. Keeps firewalls and
    /// server idle limits from dropping them, and spares the acquire the ping.
    /// Checked every IdleCheckIntervalMs. 0 (default) = off; negative values
    /// are ignored.
    property KeepaliveSeconds: Integer read GetKeepaliveSeconds write SetKeepaliveSeconds;
  end;

  { TConnectionPoolConfig }

  TConnectionPoolConfig = class(TInterfacedObject, IConnectionPoolConfig)
  private
    FIniConnections: Integer;
    FMaxConnections: Integer;
    FWaitMaxAttemps: Integer;
    FWaitMilliseconds: Integer;
    FIdleTimeoutSeconds: Integer;
    FIdleCheckIntervalMs: Integer;
    FValidateIdleSeconds: Integer;
    FKeepaliveSeconds: Integer;
    function GetIniConnections: Integer;
    function GetMaxConnections: Integer;
    procedure SetIniConnections(AValue: Integer);
    procedure SetMaxConnections(AValue: Integer);
  public
    constructor Create;
    function GetWaitMaxAttemps: Integer;
    function GetWaitMilliseconds: Integer;
    function GetIdleTimeoutSeconds: Integer;
    function GetIdleCheckIntervalMs: Integer;
    function GetValidateIdleSeconds: Integer;
    function GetKeepaliveSeconds: Integer;
    procedure SetWaitMaxAttemps(AValue: Integer);
    procedure SetWaitMilliseconds(AValue: Integer);
    procedure SetIdleTimeoutSeconds(AValue: Integer);
    procedure SetIdleCheckIntervalMs(AValue: Integer);
    procedure SetValidateIdleSeconds(AValue: Integer);
    procedure SetKeepaliveSeconds(AValue: Integer);
  end;

  // Pool events only cover what signals abnormal operation or capacity
  // growth — never the happy path (acquire/release of a connection already
  // ready in the pool, which happens on every request). Unlike
  // TMigrationEvent (PascalDb.Migrations, which runs a few times at startup),
  // there is NO console-log fallback here when AOnEvent is not provided:
  // silence is the correct behavior of a healthy pool, and notifying on every
  // acquire/release would produce one log line per request.
  TPoolEventKind = (
    pekConnectionCreated,    // new physical connection created (initial ramp-up or growth under load)
    pekConnectionDiscarded,  // a pool connection was discarded (reconnect failed, liveness check failed,
                             // or it came back marked as broken during use — see TPoolDiscardReason)
    pekAcquireThrottled,     // AcquireConnection had to wait (pool at its limit) before getting a connection
    pekAcquireTimeout,       // ran out of wait attempts; EPoolTimeoutException is raised next
    pekIdleSweepClosed       // the idle sweep closed one or more connections
  );
  // A connection that fails the keepalive ping is reported as
  // pekConnectionDiscarded with pdrStaleCheckFailed, like one that fails the
  // ping on acquire.

  TPoolDiscardReason = (
    pdrConnectFailed,     // ConnectionItem.Connection.Connect failed to reconnect, or
                           // AcquireConnection failed to open a new connection during the
                           // initial ramp-up (CreateInitialConnections, database offline at boot)
    pdrStaleCheckFailed,  // FFactory.TestConnection returned False (stale/dead connection),
                           // on acquire or in the keepalive
    pdrBrokenAfterUse     // IsConnectionBrokenError (PascalDb.Interfaces) marked the connection via
                           // IDiscardableConnection during use (Query/Commit/Rollback) —
                           // discarded on release, never goes back idle to the pool
  );

  TPoolEvent = record
    Kind: TPoolEventKind;
    ActiveConnections: Integer;  // FActiveConnections at the time of the event
    PoolSize: Integer;           // idle connections in the pool at the time of the event
    MaxConnections: Integer;
    IniConnections: Integer;
    WaitAttempts: Integer;             // pekAcquireThrottled / pekAcquireTimeout
    ClosedCount: Integer;              // pekIdleSweepClosed
    DiscardReason: TPoolDiscardReason; // pekConnectionDiscarded
    ErrorMessage: string;              // pekConnectionDiscarded (Connect's exception message, if any)
  end;

  // See PASCALDB_FUNCREFS in pascaldb.inc: "reference to" in Delphi (accepts
  // a closure or a method), "of object" in FPC 3.2.2 — passing a method
  // compiles on both.
  TPoolEventProc = {$IFDEF PASCALDB_FUNCREFS}reference to procedure(const AEvent: TPoolEvent)
    {$ELSE}procedure(const AEvent: TPoolEvent) of object{$ENDIF};

  // One statement run through a pooled query (TQueryWrapper): Open, ExecSql
  // or a batch's array operation (skExecBatch, INativeBatchQuery; a batch
  // that runs row by row reports one skExecSql per row), reported after it
  // ends, successfully or not. Unlike TPoolEvent,
  // this is the happy path, once per statement: it has its own callback
  // (AOnStatement), nil by default, and costs nothing when unset.
  TStatementKind = (skOpen, skExecSql, skExecBatch);

  TStatementInfo = record
    Kind: TStatementKind;
    Sql: string;           // the text the query ran, after SQL tags were processed
    ElapsedUs: Int64;      // microseconds (PcTickUs); for Open, includes fetching every row
    Rows: Int64;           // Open: rows fetched (RecordCount); ExecSql: rows affected (what
                           // ExecSql returned; -1 when the driver can't tell, or it failed);
                           // ExecBatch: the rows of parameters sent
    ErrorClass: string;    // '' when it succeeded; otherwise the class the caller gets
    ErrorMessage: string;  // (EDatabaseUnavailableException, ELockConflictException,
                           // EConstraintViolationException, the driver's)
  end;

  // See TPoolEventProc. Called on the thread that ran the statement; an
  // exception it raises is swallowed (a broken logger must not fail the
  // statement).
  TStatementEventProc = {$IFDEF PASCALDB_FUNCREFS}reference to procedure(const AInfo: TStatementInfo)
    {$ELSE}procedure(const AInfo: TStatementInfo) of object{$ENDIF};

  { ITransactionSpan
    The span of the transaction a query runs in, for the query's span to name
    as its parent (see the tracing note in the unit comment). The outermost
    TScopeTransaction (PascalDb.Adapter.Base) sets it on its ITransaction when
    the transaction starts and clears it when it ends; TTransactionBase
    implements it. A transaction without it: the statement spans are children
    of the thread's current span. }

  ITransactionSpan = interface
    ['{05107FD4-F1D0-411A-B00B-C9450B72AC44}']
    function GetSpan: IPcSpan;
    procedure SetSpan(const ASpan: IPcSpan);
  end;

  { TConnectionPool }

  TConnectionPool = class(TInterfacedObject, IDBConnectionPool, IDBConnectionPoolInternalActions)
  private
    FFactory: IDBFactory;
    FMaxConnections: Integer;
    FIniConnections: Integer;
    FPool: TList<TConnectionItem>; // idle connections, by LastRelease; see the unit comment
    FLockPool: TCriticalSection;
    FActiveConnections: Integer;
    FWaitMaxAttemps: Integer;
    FWaitMilliseconds: Integer;
    FIdleTimeoutSeconds: Integer;
    FIdleCheckIntervalMs: Integer;
    FValidateIdleSeconds: Integer;
    FKeepaliveSeconds: Integer;
    FIdleSweepThread: TThread;
    FIdleSweepWake: TEvent;
    FOnEvent: TPoolEventProc;
    FOnStatement: TStatementEventProc;
    FDbSystem: string;
    FTotalCreated: Int64;
    FTotalDiscarded: Int64;
    FTotalTimeouts: Int64;
    FTotalIdleSwept: Int64;
    procedure CreateInitialConnections;
    procedure IncrementActiveConnections;
    procedure DecrementActiveConnections;
    // A connection just proved dead (lost in use, failed to connect, failed a
    // ping): the idle ones share its server and probably died with it (a
    // restart, a failover). Resets their LastAlive, so each one gets the ping
    // before it is handed out (unless ValidateIdleSeconds < 0) and is due for
    // the next keepalive. Without it, after a restart every idle connection
    // failed one request before being discarded.
    procedure MarkIdleConnectionsSuspect;
    function NewConnection: IDBConnection;
    procedure StartIdleSweep;
    procedure StopIdleSweep;
    function BaseEvent(AKind: TPoolEventKind): TPoolEvent;
    procedure Notify(const AEvent: TPoolEvent);
  protected
    procedure ReleaseConnection(AConn: IDBConnection);
    procedure DiscardConnection(AConn: IDBConnection);
    procedure ReleaseQuery(var AQuery: IQuery);
  public
    // AOnEvent is optional — without it, the pool simply doesn't notify
    // anything (see the comment on TPoolEventKind for why there is no
    // console fallback here, unlike TDBMigrationEngine).
    // AOnStatement is optional too: when set, every Open/ExecSql of a query
    // from AcquireQuery reports a TStatementInfo when it ends.
    // ADbSystem: the OpenTelemetry db.system.name of its spans (see
    // PdbDbSystemName); '' leaves the attribute out.
    constructor Create(AFactory: IDBFactory; AConfig: IConnectionPoolConfig = nil;
      AOnEvent: TPoolEventProc = nil; AOnStatement: TStatementEventProc = nil;
      const ADbSystem: string = '');
    destructor Destroy; override;
    function AcquireConnection: IDBConnection;
    function AcquireQuery(out AQuery: IQuery; ATransaction: ITransaction = nil): IScopeTransaction;
    function GetActiveConnections: Integer;
    function GetPoolSize: Integer;
    function GetWaitMaxAttemps: Integer;
    function GetWaitMilliseconds: Integer;
    // Current state + counters accumulated since the pool was created — see
    // TPoolSnapshot (PascalDb.Interfaces) for the purpose of each field.
    function GetSnapshot: TPoolSnapshot;
    /// Immediately closes the pool's oldest idle connections that exceed
    /// IdleTimeoutSeconds, never below IniConnections.
    /// The automatic sweep thread calls the parameterless version
    /// periodically when IdleTimeoutSeconds > 0.
    /// Both are public mainly to allow deterministic tests (with a fake
    /// ITicker) without waiting for the real interval or depending on the
    /// background thread — the parameterized version doesn't even need
    /// IdleTimeoutSeconds configured (nor, therefore, any thread started).
    procedure SweepIdleConnections; overload;
    procedure SweepIdleConnections(AIdleTimeoutSeconds: Integer); overload;
    /// Pings the idle connections not known to work for AKeepaliveSeconds
    /// (see LastAlive) and discards the ones that fail. The ones being pinged
    /// are taken out of the pool meanwhile, so no acquire gets them; the ping
    /// runs outside the pool's lock. The background thread calls the
    /// parameterless version when KeepaliveSeconds > 0; public for tests, as
    /// SweepIdleConnections.
    procedure KeepaliveIdleConnections; overload;
    procedure KeepaliveIdleConnections(AKeepaliveSeconds: Integer); overload;
  end;

/// The OpenTelemetry db.system.name of a dialect name as
/// IDatabaseConfig.SQLDialect has it: 'postgresql', 'firebirdsql', 'sqlite',
/// 'mysql', 'mariadb', 'microsoft.sql_server' (SQLServer and MSSQL); any
/// other name lower-cased, '' for ''.
function PdbDbSystemName(const ADialectName: string): string;

/// The first word of ASql, upper-cased ('SELECT', 'INSERT', 'WITH'), after
/// spaces and opening parentheses; '' when ASql starts with anything else (a
/// comment). A statement span's name.
function PdbSqlOperationName(const ASql: string): string;

/// Ends ASpan (nil: nothing), with error.type and the error status first when
/// AError is given.
procedure PdbFinishSpan(const ASpan: IPcSpan; AError: Exception);

implementation

uses
  PascalCommon.Threading;

function PdbDbSystemName(const ADialectName: string): string;
var
  LName: string;
begin
  LName := LowerCase(Trim(ADialectName));
  if LName = 'firebird' then
    Result := 'firebirdsql'
  else if (LName = 'sqlserver') or (LName = 'mssql') then
    Result := 'microsoft.sql_server'
  else
    Result := LName;
end;

function PdbSqlOperationName(const ASql: string): string;
var
  I, LStart: Integer;
begin
  I := 1;
  while (I <= Length(ASql)) and CharInSet(ASql[I], [' ', #9, #10, #13, '(']) do
    Inc(I);
  LStart := I;
  while (I <= Length(ASql)) and CharInSet(ASql[I], ['A'..'Z', 'a'..'z']) do
    Inc(I);
  Result := UpperCase(Copy(ASql, LStart, I - LStart));
end;

procedure PdbFinishSpan(const ASpan: IPcSpan; AError: Exception);
begin
  if ASpan = nil then
    Exit;
  if Assigned(AError) then
  begin
    ASpan.SetAttribute('error.type', AError.ClassName);
    ASpan.SetStatus(ssError, AError.Message);
  end;
  ASpan.Finish;
end;

type
  { Idle-connection sweep thread.

    A dedicated class instead of TThread.CreateAnonymousThread: FPC 3.2.2 has
    no anonymous methods. It accesses the pool's private members (same unit).
    The lifecycle (Terminate via FIdleSweepWake, a single WaitFor, Free)
    still belongs to TConnectionPool — see StartIdleSweep/StopIdleSweep.
    Each round sweeps first and then runs the keepalive, so a connection
    about to be closed isn't pinged; either one does nothing when it is off.
    A keepalive ping stuck on a dead network holds this thread (and the
    next sweep) until the driver gives up; it never blocks an acquire. }
  TIdleSweepThread = class(TThread)
  private
    FPool: TConnectionPool;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TConnectionPool);
  end;

constructor TIdleSweepThread.Create(APool: TConnectionPool);
begin
  FPool := APool;
  inherited Create(False);
end;

procedure TIdleSweepThread.Execute;
begin
  while FPool.FIdleSweepWake.WaitFor(FPool.FIdleCheckIntervalMs) = wrTimeout do
  begin
    FPool.SweepIdleConnections;
    FPool.KeepaliveIdleConnections;
  end;
end;

type

  { TConnectionWrapper
    Returns the connection to the pool automatically when destroyed. }

  TConnectionWrapper = class(TInterfacedObject, IDBConnection, IUnwrapDBConnection, IDiscardableConnection)
  private
    FPool: IDBConnectionPoolInternalActions;
    FInternalConn: IDBConnection;
    FDiscard: Boolean;
  public
    constructor Create(APool: IDBConnectionPoolInternalActions; ARealConn: IDBConnection);
    destructor Destroy; override;
    procedure Connect;
    procedure Disconnect(Force: Boolean = False);
    function GetNativeConnection: TObject;
    function GetRealConnection: IDBConnection;
    function GetSQLDialect: ISQLDialect;
    function IsConnected: Boolean;
    procedure Commit;
    procedure Rollback;
    // IDiscardableConnection — see the comment on the interface declaration
    // (PascalDb.Interfaces) and MarkConnectionBrokenIfNeeded, called from
    // TQueryWrapper.Open/ExecSql and from the adapter's transaction
    // Commit/Rollback.
    procedure MarkForDiscard;
    function ShouldDiscard: Boolean;
  end;

  { TQueryWrapper
    Returns the query to the pool automatically when destroyed. Forwards
    INativeBatchQuery to the adapter's query, when it has it, with the same
    broken-connection classification and statement event as ExecSql. }

  TQueryWrapper = class(TInterfacedObject, IQuery, INativeBatchQuery)
  private
    FPool: IDBConnectionPoolInternalActions;
    FInternalQuery: IQuery;
    FOnStatement: TStatementEventProc;
    FDbSystem: string;
    procedure NotifyStatement(AKind: TStatementKind; AStartUs: Int64; ARows: Int64;
      AError: Exception);
    // nil when tracing is off (see the unit comment).
    function StartStatementSpan(AKind: TStatementKind): IPcSpan;
  public
    constructor Create(APool: IDBConnectionPoolInternalActions; ARealQuery: IQuery;
      AOnStatement: TStatementEventProc; const ADbSystem: string);
    destructor Destroy; override;
    procedure Close;
    function ExecSql: Int64;
    function GetConnection: IDBConnection;
    function GetParams: IParams;
    function GetSql: string;
    function GetTransaction: ITransaction;
    function Open: IQueryResult;
    procedure SetSql(const ASql: string);
    // INativeBatchQuery
    function SupportsNativeBatch: Boolean;
    procedure ExecBatch(const ARows: IBatchRows);
  end;

  { TQueryResultWrapper
    Wraps the IQueryResult returned by Query.Open. Every field access
    (GetAsXxx, GetNullableXxx, Next, ...) goes through here — the right place
    to apply the same MarkConnectionBrokenIfNeeded classification used in
    TQueryWrapper.Open/ExecSql: an AV or lost connection in the middle of
    reading fields (e.g. the server went down during the fetch, after Open had
    already returned successfully) must mark the connection for discard just
    like a failure in Open itself — without this, TQueryWrapper.Open only
    covers the half of the query's lifecycle that touches the native driver
    the least (most of the data reading happens here, not in Open). }

  TQueryResultWrapper = class(TInterfacedObject, IQueryResult)
  private
    FInternalResult: IQueryResult;
    FConnection: IDBConnection;
    // Returns the exception to re-raise (a new EDatabaseUnavailableException)
    // or nil (re-raise E as is) — it never re-raises it itself. See the
    // comment on BuildDatabaseException (PascalDb.Interfaces): "raise E;" by
    // reference, from Guard's frame (which is not where E was caught), causes
    // an AV in this Delphi version — that's why each method below re-raises
    // locally, lexically inside its own except block.
    function Guard(E: Exception): Exception;
  public
    constructor Create(AResult: IQueryResult; AConnection: IDBConnection);
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
  end;

{ TQueryWrapper }

constructor TQueryWrapper.Create(APool: IDBConnectionPoolInternalActions; ARealQuery: IQuery;
  AOnStatement: TStatementEventProc; const ADbSystem: string);
begin
  FPool := APool;
  FInternalQuery := ARealQuery;
  FOnStatement := AOnStatement;
  FDbSystem := ADbSystem;
end;

function TQueryWrapper.StartStatementSpan(AKind: TStatementKind): IPcSpan;
var
  LSql, LOperation, LName: string;
  LTxSpan: ITransactionSpan;
  LParent: IPcSpan;
begin
  Result := nil;
  if not TPcTracing.Enabled then
    Exit;
  LSql := TrimRight(FInternalQuery.GetSql);
  LOperation := PdbSqlOperationName(LSql);
  // OpenTelemetry's database spans: named after the operation when known,
  // else the database system.
  if LOperation <> '' then
    LName := LOperation
  else if FDbSystem <> '' then
    LName := FDbSystem
  else
    LName := 'db';
  if AKind = skExecBatch then
    LName := 'BATCH ' + LName;
  // Inside a transaction, a child of its span (a detached one: see
  // ITransactionSpan); otherwise of the thread's current span.
  LParent := nil;
  if Supports(FInternalQuery.GetTransaction, ITransactionSpan, LTxSpan) then
    LParent := LTxSpan.GetSpan;
  Result := TPcTracing.StartChildSpan(LParent, LName, skClient);
  if FDbSystem <> '' then
    Result.SetAttribute('db.system.name', FDbSystem);
  if LOperation <> '' then
    Result.SetAttribute('db.operation.name', LOperation);
  Result.SetAttribute('db.query.text', LSql);
end;

procedure TQueryWrapper.NotifyStatement(AKind: TStatementKind; AStartUs: Int64; ARows: Int64;
  AError: Exception);
var
  LInfo: TStatementInfo;
begin
  LInfo.Kind := AKind;
  LInfo.ElapsedUs := PcTickUs - AStartUs;
  LInfo.Rows := ARows;
  if Assigned(AError) then
  begin
    LInfo.ErrorClass := AError.ClassName;
    LInfo.ErrorMessage := AError.Message;
  end
  else
  begin
    LInfo.ErrorClass := '';
    LInfo.ErrorMessage := '';
  end;
  try
    // TrimRight: a dataset's SQL text ends with a line break.
    LInfo.Sql := TrimRight(FInternalQuery.GetSql);
    FOnStatement(LInfo);
  except
    // See TStatementEventProc: never fail the statement because of the callback.
  end;
end;

destructor TQueryWrapper.Destroy;
begin
  if Assigned(FPool) then
    FPool.ReleaseQuery(FInternalQuery);
  inherited Destroy;
end;

procedure TQueryWrapper.Close;
begin
  FInternalQuery.Close;
end;

function TQueryWrapper.ExecSql: Int64;
var
  LNewE, LFailure: Exception;
  LStartUs: Int64;
  LSpan: IPcSpan;
begin
  LStartUs := 0;
  if Assigned(FOnStatement) then
    LStartUs := PcTickUs;
  LSpan := StartStatementSpan(skExecSql);
  try
    Result := FInternalQuery.ExecSql;
  except
    on E: Exception do
    begin
      // See BuildDatabaseException (PascalDb.Interfaces) — never "raise E;"
      // here: re-raising by reference an object caught in ANOTHER
      // procedure's frame causes an Access Violation in this Delphi version.
      // It is only safe to raise a NEW exception (LNewE) or a bare "raise;",
      // lexically inside this very except block.
      LNewE := BuildDatabaseException(FInternalQuery.GetConnection, E);
      if Assigned(LNewE) then
        LFailure := LNewE
      else
        LFailure := E;
      if Assigned(FOnStatement) then
        NotifyStatement(skExecSql, LStartUs, -1, LFailure);
      PdbFinishSpan(LSpan, LFailure);
      if Assigned(LNewE) then
        raise LNewE;
      raise;
    end;
  end;
  if Assigned(FOnStatement) then
    NotifyStatement(skExecSql, LStartUs, Result, nil);
  if Assigned(LSpan) then
  begin
    // No semantic-convention attribute for it yet: this library's own name.
    if Result >= 0 then
      LSpan.SetIntAttribute('pascaldb.rows_affected', Result);
    PdbFinishSpan(LSpan, nil);
  end;
end;

function TQueryWrapper.GetConnection: IDBConnection;
begin
  Result := FInternalQuery.GetConnection;
end;

function TQueryWrapper.GetParams: IParams;
begin
  Result := FInternalQuery.GetParams;
end;

function TQueryWrapper.GetSql: string;
begin
  Result := FInternalQuery.GetSql;
end;

function TQueryWrapper.GetTransaction: ITransaction;
begin
  Result := FInternalQuery.GetTransaction;
end;

function TQueryWrapper.Open: IQueryResult;
var
  LRawResult: IQueryResult;
  LNewE, LFailure: Exception;
  LStartUs: Int64;
  LRows: Int64;
  LSpan: IPcSpan;
begin
  LStartUs := 0;
  if Assigned(FOnStatement) then
    LStartUs := PcTickUs;
  LSpan := StartStatementSpan(skOpen);
  try
    LRawResult := FInternalQuery.Open;
  except
    on E: Exception do
    begin
      // See BuildDatabaseException (PascalDb.Interfaces): it only re-raises
      // as EDatabaseUnavailableException on EExternal (e.g. an Access
      // Violation inside the native call) or if IsConnected turned False —
      // constraint violations and other normal data errors re-raise E as is.
      // Never "raise E;" here (see the comment in TQueryWrapper.ExecSql).
      LNewE := BuildDatabaseException(FInternalQuery.GetConnection, E);
      if Assigned(LNewE) then
        LFailure := LNewE
      else
        LFailure := E;
      if Assigned(FOnStatement) then
        NotifyStatement(skOpen, LStartUs, -1, LFailure);
      PdbFinishSpan(LSpan, LFailure);
      if Assigned(LNewE) then
        raise LNewE;
      raise;
    end;
  end;
  if Assigned(FOnStatement) or Assigned(LSpan) then
  begin
    // Every adapter fetches the whole result on Open: RecordCount is exact.
    LRows := -1;
    if Assigned(LRawResult) then
    try
      LRows := LRawResult.RecordCount;
    except
      // reading it failed: the statement itself worked, report no count
    end;
    if Assigned(FOnStatement) then
      NotifyStatement(skOpen, LStartUs, LRows, nil);
    if Assigned(LSpan) then
    begin
      if LRows >= 0 then
        LSpan.SetIntAttribute('db.response.returned_rows', LRows);
      PdbFinishSpan(LSpan, nil);
    end;
  end;
  // The raw result doesn't go through any pool wrapper — without this, an AV
  // while reading fields (e.g. the server went down mid-fetch, after Open had
  // already returned successfully) would never be classified.
  // See TQueryResultWrapper.
  Result := TQueryResultWrapper.Create(LRawResult, FInternalQuery.GetConnection);
end;

procedure TQueryWrapper.SetSql(const ASql: string);
begin
  FInternalQuery.SetSql(ASql);
end;

function TQueryWrapper.SupportsNativeBatch: Boolean;
var
  LNative: INativeBatchQuery;
begin
  Result := Supports(FInternalQuery, INativeBatchQuery, LNative) and LNative.SupportsNativeBatch;
end;

procedure TQueryWrapper.ExecBatch(const ARows: IBatchRows);
var
  LNative: INativeBatchQuery;
  LNewE, LFailure: Exception;
  LStartUs: Int64;
  LSpan: IPcSpan;
begin
  if not Supports(FInternalQuery, INativeBatchQuery, LNative) then
    raise ENotSupportedException.Create('The adapter''s query has no native batch (INativeBatchQuery)');
  LStartUs := 0;
  if Assigned(FOnStatement) then
    LStartUs := PcTickUs;
  LSpan := StartStatementSpan(skExecBatch);
  if Assigned(LSpan) then
    LSpan.SetIntAttribute('db.operation.batch.size', ARows.RowCount);
  try
    LNative.ExecBatch(ARows);
  except
    on E: Exception do
    begin
      // Same as ExecSql (see there): never "raise E;".
      LNewE := BuildDatabaseException(FInternalQuery.GetConnection, E);
      if Assigned(LNewE) then
        LFailure := LNewE
      else
        LFailure := E;
      if Assigned(FOnStatement) then
        NotifyStatement(skExecBatch, LStartUs, ARows.RowCount, LFailure);
      PdbFinishSpan(LSpan, LFailure);
      if Assigned(LNewE) then
        raise LNewE;
      raise;
    end;
  end;
  if Assigned(FOnStatement) then
    NotifyStatement(skExecBatch, LStartUs, ARows.RowCount, nil);
  PdbFinishSpan(LSpan, nil);
end;

{ TQueryResultWrapper }

constructor TQueryResultWrapper.Create(AResult: IQueryResult; AConnection: IDBConnection);
begin
  FInternalResult := AResult;
  FConnection := AConnection;
end;

function TQueryResultWrapper.Guard(E: Exception): Exception;
begin
  Result := BuildDatabaseException(FConnection, E);
end;

function TQueryResultWrapper.GetAsBoolean(const AName: string): Boolean;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsBoolean(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsDateTime(const AName: string): TDateTime;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsDateTime(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsInteger(const AName: string): Integer;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsInteger(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsInt64(const AName: string): Int64;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsInt64(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsString(const AName: string): string;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsString(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetAsCurrency(const AName: string): Currency;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetAsCurrency(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableBoolean(const AName: string): INullBoolean;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableBoolean(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableDateTime(const AName: string): INullDateTime;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableDateTime(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableInteger(const AName: string): INullInteger;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableInteger(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableInt64(const AName: string): INullInt64;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableInt64(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableString(const AName: string): INullString;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableString(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.GetNullableCurrency(const AName: string): INullCurrency;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.GetNullableCurrency(AName);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.IsEmpty: Boolean;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.IsEmpty;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.FieldCount: Integer;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.FieldCount;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.FieldValue(AIndex: Integer): Variant;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.FieldValue(AIndex);
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.RecordCount: Integer;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.RecordCount;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

procedure TQueryResultWrapper.Next;
var
  LNewE: Exception;
begin
  try
    FInternalResult.Next;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

function TQueryResultWrapper.Eof: Boolean;
var
  LNewE: Exception;
begin
  try
    Result := FInternalResult.Eof;
  except
    on E: Exception do
    begin
      LNewE := Guard(E);
      if Assigned(LNewE) then raise LNewE;
      raise;
    end;
  end;
end;

{ TConnectionWrapper }

constructor TConnectionWrapper.Create(APool: IDBConnectionPoolInternalActions;
  ARealConn: IDBConnection);
begin
  FPool := APool;
  FInternalConn := ARealConn;
end;

destructor TConnectionWrapper.Destroy;
begin
  if Assigned(FPool) then
  begin
    if FDiscard then
      FPool.DiscardConnection(FInternalConn)
    else
      FPool.ReleaseConnection(FInternalConn);
  end;
  inherited Destroy;
end;

procedure TConnectionWrapper.Commit;
begin
  FInternalConn.Commit;
end;

procedure TConnectionWrapper.Connect;
begin
  FInternalConn.Connect;
end;

procedure TConnectionWrapper.Disconnect(Force: Boolean);
begin
  FInternalConn.Disconnect(Force);
end;

function TConnectionWrapper.GetNativeConnection: TObject;
begin
  Result := FInternalConn.GetNativeConnection;
end;

function TConnectionWrapper.GetRealConnection: IDBConnection;
begin
  Result := FInternalConn;
end;

function TConnectionWrapper.GetSQLDialect: ISQLDialect;
begin
  Result := FInternalConn.GetSQLDialect;
end;

function TConnectionWrapper.IsConnected: Boolean;
begin
  Result := FInternalConn.IsConnected;
end;

procedure TConnectionWrapper.Rollback;
begin
  FInternalConn.Rollback;
end;

procedure TConnectionWrapper.MarkForDiscard;
begin
  FDiscard := True;
end;

function TConnectionWrapper.ShouldDiscard: Boolean;
begin
  Result := FDiscard;
end;

{ EPoolTimeoutException }

constructor EPoolTimeoutException.Create(Active, Max, InQueue, Attempts: Integer);
begin
  inherited CreateFmt(
    'Timed out waiting for a connection. Pool: %d/%d active, %d queued. Attempts: %d',
    [Active, Max, InQueue, Attempts]
  );
end;

{ TConnectionItem }

class function TConnectionItem.New(AConn: IDBConnection): TConnectionItem;
begin
  Result.Connection := AConn;
  Result.LastRelease := TTicker.NowMs;
  Result.LastAlive := Result.LastRelease;
end;

{ TConnectionPoolConfig }

constructor TConnectionPoolConfig.Create;
begin
  inherited Create;
  FIdleCheckIntervalMs := 30000; // only matters if IdleTimeoutSeconds or KeepaliveSeconds > 0
  FValidateIdleSeconds := 120;
end;

function TConnectionPoolConfig.GetIniConnections: Integer;
begin
  Result := FIniConnections;
end;

function TConnectionPoolConfig.GetMaxConnections: Integer;
begin
  Result := FMaxConnections;
end;

procedure TConnectionPoolConfig.SetIniConnections(AValue: Integer);
begin
  if AValue >= 0 then
    FIniConnections := AValue;
end;

procedure TConnectionPoolConfig.SetMaxConnections(AValue: Integer);
begin
  if AValue > 0 then
    FMaxConnections := AValue;
end;

function TConnectionPoolConfig.GetWaitMaxAttemps: Integer;
begin
  Result := FWaitMaxAttemps;
end;

function TConnectionPoolConfig.GetWaitMilliseconds: Integer;
begin
  Result := FWaitMilliseconds;
end;

procedure TConnectionPoolConfig.SetWaitMaxAttemps(AValue: Integer);
begin
  FWaitMaxAttemps := AValue;
end;

procedure TConnectionPoolConfig.SetWaitMilliseconds(AValue: Integer);
begin
  FWaitMilliseconds := AValue;
end;

function TConnectionPoolConfig.GetIdleTimeoutSeconds: Integer;
begin
  Result := FIdleTimeoutSeconds;
end;

function TConnectionPoolConfig.GetIdleCheckIntervalMs: Integer;
begin
  Result := FIdleCheckIntervalMs;
end;

procedure TConnectionPoolConfig.SetIdleTimeoutSeconds(AValue: Integer);
begin
  if AValue >= 0 then
    FIdleTimeoutSeconds := AValue;
end;

procedure TConnectionPoolConfig.SetIdleCheckIntervalMs(AValue: Integer);
begin
  if AValue > 0 then
    FIdleCheckIntervalMs := AValue;
end;

function TConnectionPoolConfig.GetValidateIdleSeconds: Integer;
begin
  Result := FValidateIdleSeconds;
end;

procedure TConnectionPoolConfig.SetValidateIdleSeconds(AValue: Integer);
begin
  FValidateIdleSeconds := AValue; // every value means something; see the property
end;

function TConnectionPoolConfig.GetKeepaliveSeconds: Integer;
begin
  Result := FKeepaliveSeconds;
end;

procedure TConnectionPoolConfig.SetKeepaliveSeconds(AValue: Integer);
begin
  if AValue >= 0 then
    FKeepaliveSeconds := AValue;
end;

{ TConnectionPool }

constructor TConnectionPool.Create(AFactory: IDBFactory; AConfig: IConnectionPoolConfig;
  AOnEvent: TPoolEventProc; AOnStatement: TStatementEventProc; const ADbSystem: string);

  // Weak reference to break the TConnectionPool <-> IDBFactory reference cycle
  procedure SetWeak(aInterfaceField: PInterface; const aValue: IInterface);
  begin
    PPointer(aInterfaceField)^ := Pointer(aValue);
  end;

begin
  FOnEvent := AOnEvent;
  FOnStatement := AOnStatement;
  FDbSystem := ADbSystem;

  if Assigned(AConfig) then
  begin
    FIniConnections  := AConfig.IniConnections;
    FMaxConnections  := AConfig.MaxConnections;
    FWaitMilliseconds := AConfig.WaitMilliseconds;
    FWaitMaxAttemps  := AConfig.WaitMaxAttemps;
    FIdleTimeoutSeconds := AConfig.IdleTimeoutSeconds;
    FIdleCheckIntervalMs := AConfig.IdleCheckIntervalMs;
    FValidateIdleSeconds := AConfig.ValidateIdleSeconds;
    FKeepaliveSeconds := AConfig.KeepaliveSeconds;
  end
  else
  begin
    FIniConnections  := 3;
    FMaxConnections  := 20;
    FWaitMilliseconds := 20;
    FWaitMaxAttemps  := 50;
    FIdleTimeoutSeconds := 0; // off by default
    FIdleCheckIntervalMs := 30000;
    FValidateIdleSeconds := 120;
    FKeepaliveSeconds := 0; // off by default
  end;

  if FIdleCheckIntervalMs <= 0 then
    FIdleCheckIntervalMs := 30000; // the config already validated this, but the "no AConfig" branch didn't

  FActiveConnections := 0;

  SetWeak(@FFactory, AFactory);

  FPool     := TList<TConnectionItem>.Create;
  FLockPool := TCriticalSection.Create;

  CreateInitialConnections;

  if (FIdleTimeoutSeconds > 0) or (FKeepaliveSeconds > 0) then
    StartIdleSweep;
end;

destructor TConnectionPool.Destroy;
begin
  // Must stop BEFORE touching FPool/FLockPool — otherwise the sweep thread
  // could fire on fields that were already freed.
  StopIdleSweep;

  // Clear the weak reference before the compiler-generated automatic Release
  PPointer(@FFactory)^ := nil;

  FLockPool.Enter;
  try
    FPool.Clear;
    FPool.Free;
  finally
    FLockPool.Leave;
    FLockPool.Free;
  end;

  inherited Destroy;
end;

function TConnectionPool.BaseEvent(AKind: TPoolEventKind): TPoolEvent;
begin
  Result := Default(TPoolEvent);
  Result.Kind := AKind;
  Result.ActiveConnections := FActiveConnections;
  Result.PoolSize := FPool.Count;
  Result.MaxConnections := FMaxConnections;
  Result.IniConnections := FIniConnections;
end;

procedure TConnectionPool.Notify(const AEvent: TPoolEvent);
begin
  if Assigned(FOnEvent) then
    FOnEvent(AEvent);
end;

function TConnectionPool.GetSnapshot: TPoolSnapshot;
begin
  Result.ActiveConnections := FActiveConnections;
  Result.PoolSize := FPool.Count;
  Result.MaxConnections := FMaxConnections;
  Result.IniConnections := FIniConnections;
  // Incremented from any thread, some outside FLockPool: atomic reads (a
  // plain 64-bit read can be torn on 32-bit targets).
  Result.TotalCreated := PcAtomicRead64(FTotalCreated);
  Result.TotalDiscarded := PcAtomicRead64(FTotalDiscarded);
  Result.TotalTimeouts := PcAtomicRead64(FTotalTimeouts);
  Result.TotalIdleSwept := PcAtomicRead64(FTotalIdleSwept);
end;

procedure TConnectionPool.StartIdleSweep;
begin
  // Manual-reset event: SetEvent on shutdown wakes the thread immediately,
  // without waiting the full interval — same pattern as the reconnect thread
  // in pascal-named-pipes-faa (TPipeClient.FReconnectAbort).
  FIdleSweepWake := TEvent.Create(nil, True, False, '');
  FIdleSweepThread := TIdleSweepThread.Create(Self);
end;

procedure TConnectionPool.StopIdleSweep;
begin
  if not Assigned(FIdleSweepThread) then
    Exit;

  FIdleSweepWake.SetEvent;
  FIdleSweepThread.WaitFor;
  FreeAndNil(FIdleSweepThread);
  FreeAndNil(FIdleSweepWake);
end;

procedure TConnectionPool.SweepIdleConnections;
begin
  SweepIdleConnections(FIdleTimeoutSeconds);
end;

procedure TConnectionPool.SweepIdleConnections(AIdleTimeoutSeconds: Integer);
var
  LToClose: TList<IDBConnection>;
  LItem: TConnectionItem;
  LConn: IDBConnection;
  LEvent: TPoolEvent;
begin
  if AIdleTimeoutSeconds <= 0 then
    Exit;

  LToClose := TList<IDBConnection>.Create;
  try
    // Phase 1 (fast, under the lock): decide what goes. FPool is ordered by
    // increasing LastRelease, so index 0 is always the oldest — just look at
    // it and stop at the first one that isn't idle long enough.
    FLockPool.Enter;
    try
      while (FPool.Count > FIniConnections) and (FPool.Count > 0) do
      begin
        LItem := FPool[0];
        if TTicker.ElapsedMs(LItem.LastRelease) < UInt64(AIdleTimeoutSeconds) * 1000 then
          Break;

        FPool.Delete(0);
        LToClose.Add(LItem.Connection);
        Dec(FActiveConnections); // already under FLockPool; see DecrementActiveConnections
      end;
    finally
      FLockPool.Leave;
    end;

    // Phase 2 (slow, outside the lock): actually disconnect. Never do network
    // IO while holding FLockPool — it would block every concurrent
    // AcquireConnection/ReleaseConnection in the application until the
    // Disconnect finishes.
    for LConn in LToClose do
    begin
      try
        LConn.Disconnect(True);
      except
        // ignore — the connection is being discarded anyway
      end;
    end;

    if LToClose.Count > 0 then
    begin
      PcAtomicAdd64(FTotalIdleSwept, LToClose.Count);
      LEvent := BaseEvent(pekIdleSweepClosed);
      LEvent.ClosedCount := LToClose.Count;
      Notify(LEvent);
    end;
  finally
    LToClose.Free;
  end;
end;

procedure TConnectionPool.KeepaliveIdleConnections;
begin
  KeepaliveIdleConnections(FKeepaliveSeconds);
end;

procedure TConnectionPool.KeepaliveIdleConnections(AKeepaliveSeconds: Integer);
var
  LDue: TList<TConnectionItem>;
  LItem: TConnectionItem;
  LAlive: Boolean;
  LEvent: TPoolEvent;
  I, J: Integer;
begin
  if AKeepaliveSeconds <= 0 then
    Exit;

  LDue := TList<TConnectionItem>.Create;
  try
    // Phase 1 (fast, under the lock): take the due ones out of FPool, so no
    // acquire gets a connection in the middle of its ping. They still count
    // in FActiveConnections: meanwhile the pool may open a new one for an
    // acquire, but never more than MaxConnections in all.
    FLockPool.Enter;
    try
      for I := FPool.Count - 1 downto 0 do
        if TTicker.ElapsedMs(FPool[I].LastAlive) >= UInt64(AKeepaliveSeconds) * 1000 then
        begin
          LDue.Add(FPool[I]);
          FPool.Delete(I);
        end;
    finally
      FLockPool.Leave;
    end;

    // Phase 2 (slow, outside the lock, like the sweep's Disconnect): ping
    // each one. A live one goes back right away, at its LastRelease place, so
    // FPool stays ordered for the sweep and the LIFO acquire; a dead one is
    // discarded as on acquire.
    for I := 0 to LDue.Count - 1 do
    begin
      LItem := LDue[I];
      try
        LAlive := FFactory.TestConnection(LItem.Connection);
      except
        LAlive := False; // TDBFactory's never raises; a third-party factory might
      end;

      if LAlive then
      begin
        LItem.LastAlive := TTicker.NowMs;
        FLockPool.Enter;
        try
          J := FPool.Count;
          while (J > 0) and (FPool[J - 1].LastRelease > LItem.LastRelease) do
            Dec(J);
          FPool.Insert(J, LItem);
        finally
          FLockPool.Leave;
        end;
      end
      else
      begin
        try
          LItem.Connection.Disconnect(True);
        except
          // ignore — the connection is being discarded anyway
        end;
        DecrementActiveConnections;
        PcAtomicInc64(FTotalDiscarded);
        LEvent := BaseEvent(pekConnectionDiscarded);
        LEvent.DiscardReason := pdrStaleCheckFailed;
        Notify(LEvent);
        MarkIdleConnectionsSuspect;
      end;
    end;
  finally
    LDue.Free;
  end;
end;

procedure TConnectionPool.CreateInitialConnections;
var
  I: Integer;
  { Holders keeps the wrappers alive during the loop to force the pool to
    create new physical connections. When the procedure exits, the array
    goes out of scope, every wrapper is released and the connections go back
    to the pool. }
  Holders: TArray<IDBConnection>;
  LEvent: TPoolEvent;
begin
  if FIniConnections <= 0 then
    Exit;

  SetLength(Holders, FIniConnections);
  for I := 0 to FIniConnections - 1 do
  begin
    try
      Holders[I] := AcquireConnection;
    except
      // IniConnections > MaxConnections is a configuration error, not
      // "database offline" — it keeps propagating, as it always did (see
      // Test_Pool_MaxConnections_Exceeded/Test_Pool_Event_AcquireTimeout_*).
      on E: EPoolTimeoutException do
        raise;
      on E: Exception do
      begin
        { Database offline (or unreachable) at boot: don't let the failure
          propagate and bring down TConnectionPool.Create (or the factory
          that creates it) because of the initial ramp-up. Holders[I] stays
          nil (AcquireConnection already reverted FActiveConnections in
          TryGetNewConnection) and the pool starts without this pre-warmed
          connection; the next real AcquireConnection (first request, health
          check, etc.) tries again. }
        PcAtomicInc64(FTotalDiscarded);
        LEvent := BaseEvent(pekConnectionDiscarded);
        LEvent.DiscardReason := pdrConnectFailed;
        // The driver's text, not EDatabaseConnectException's generic one.
        if E is EDatabaseUnavailableException then
          LEvent.ErrorMessage := EDatabaseUnavailableException(E).OriginalMessage
        else
          LEvent.ErrorMessage := E.Message;
        Notify(LEvent);
      end;
    end;
  end;
end;

procedure TConnectionPool.IncrementActiveConnections;
begin
  FLockPool.Enter;
  try
    Inc(FActiveConnections);
  finally
    FLockPool.Leave;
  end;
end;

procedure TConnectionPool.DecrementActiveConnections;
begin
  FLockPool.Enter;
  try
    Dec(FActiveConnections);
  finally
    FLockPool.Leave;
  end;
end;

function TConnectionPool.NewConnection: IDBConnection;
begin
  Result := FFactory.CreateConnection;
end;

function TConnectionPool.AcquireConnection: IDBConnection;
var
  WaitAttempts: Integer;
  ConnectionItem: TConnectionItem;
  ShouldCreateNew: Boolean;
  ShouldUseFromPool: Boolean;
  RealConnection: IDBConnection;
  LThrottleEvent: TPoolEvent;
  LWaitSpan: IPcSpan;

  procedure NotifyThrottledIfWaited;
  begin
    if WaitAttempts = 0 then
      Exit;
    LThrottleEvent := BaseEvent(pekAcquireThrottled);
    LThrottleEvent.WaitAttempts := WaitAttempts;
    Notify(LThrottleEvent);
  end;

  // The "pool wait" span (see the unit comment): opened before the first
  // wait, only while tracing is enabled.
  procedure StartWaitSpan;
  begin
    if (LWaitSpan <> nil) or not TPcTracing.Enabled then
      Exit;
    LWaitSpan := TPcTracing.StartSpan('pool wait', skInternal);
    if FDbSystem <> '' then
      LWaitSpan.SetAttribute('db.system.name', FDbSystem);
    LWaitSpan.SetIntAttribute('pascaldb.pool.max_connections', FMaxConnections);
  end;

  procedure FinishWaitSpan(AError: Exception);
  begin
    if LWaitSpan = nil then
      Exit;
    LWaitSpan.SetIntAttribute('pascaldb.pool.wait_attempts', WaitAttempts);
    PdbFinishSpan(LWaitSpan, AError);
    LWaitSpan := nil;
  end;

  procedure CheckPool;
  begin
    FLockPool.Enter;
    try
      if FPool.Count > 0 then
      begin
        // LIFO: the most recently released connection (see the unit comment).
        ShouldUseFromPool := True;
        ConnectionItem := FPool[FPool.Count - 1];
        FPool.Delete(FPool.Count - 1);
      end
      else if FActiveConnections < FMaxConnections then
      begin
        ShouldCreateNew := True;
        IncrementActiveConnections;
      end;
    finally
      FLockPool.Leave;
    end;
  end;

  function TryGetNewConnection(out AConnection: IDBConnection): Boolean;
  begin
    Result := True;
    try
      AConnection := NewConnection;
    except
      on E: Exception do
      begin
        Result := False;
        DecrementActiveConnections;
        MarkIdleConnectionsSuspect;
        // A new exception, never "raise E" (see BuildDatabaseException in
        // PascalDb.Interfaces); one already classified goes up as is.
        if E is EDatabaseUnavailableException then
          raise;
        raise EDatabaseConnectException.Create(E);
      end;
    end;
    PcAtomicInc64(FTotalCreated);
    Notify(BaseEvent(pekConnectionCreated));
  end;

  function TryGetConnectionFromPool(out AConnection: IDBConnection): Boolean;
  var
    LEvent: TPoolEvent;
  begin
    Result := False;

    if not ConnectionItem.Connection.IsConnected then
    begin
      try
        ConnectionItem.Connection.Connect;
      except
        on E: Exception do
        begin
          try
            ConnectionItem.Connection.Disconnect(True);
          finally
            DecrementActiveConnections;
          end;
          PcAtomicInc64(FTotalDiscarded);
          LEvent := BaseEvent(pekConnectionDiscarded);
          LEvent.DiscardReason := pdrConnectFailed;
          LEvent.ErrorMessage := E.Message;
          Notify(LEvent);
          MarkIdleConnectionsSuspect;
          Exit;
        end;
      end;
    end;

    if (FValidateIdleSeconds >= 0) and
       (TTicker.ElapsedMs(ConnectionItem.LastAlive) >= UInt64(FValidateIdleSeconds) * 1000) then
    begin
      if not FFactory.TestConnection(ConnectionItem.Connection) then
      begin
        try
          ConnectionItem.Connection.Disconnect(True);
        finally
          DecrementActiveConnections;
        end;
        PcAtomicInc64(FTotalDiscarded);
        LEvent := BaseEvent(pekConnectionDiscarded);
        LEvent.DiscardReason := pdrStaleCheckFailed;
        Notify(LEvent);
        MarkIdleConnectionsSuspect;
        Exit;
      end;
    end;

    Result := True;
    AConnection := ConnectionItem.Connection;
  end;

begin
  WaitAttempts := 0;
  LWaitSpan := nil;
  try
    while True do
    begin
      ShouldCreateNew  := False;
      ShouldUseFromPool := False;

      CheckPool;

      if ShouldCreateNew then
      begin
        if TryGetNewConnection(RealConnection) then
        begin
          NotifyThrottledIfWaited;
          FinishWaitSpan(nil);
          Result := TConnectionWrapper.Create(Self, RealConnection);
          Exit;
        end;
        Result := nil;
      end;

      if ShouldUseFromPool then
      begin
        if not TryGetConnectionFromPool(RealConnection) then
        begin
          Result := nil;
          Continue;
        end;
        NotifyThrottledIfWaited;
        FinishWaitSpan(nil);
        Result := TConnectionWrapper.Create(Self, RealConnection);
        Exit;
      end;

      if WaitAttempts >= FWaitMaxAttemps then
      begin
        PcAtomicInc64(FTotalTimeouts);
        LThrottleEvent := BaseEvent(pekAcquireTimeout);
        LThrottleEvent.WaitAttempts := WaitAttempts;
        Notify(LThrottleEvent);
        raise EPoolTimeoutException.Create(
          FActiveConnections, FMaxConnections, FPool.Count, WaitAttempts
        );
      end;

      StartWaitSpan;
      TSleep.Sleep(FWaitMilliseconds);
      Inc(WaitAttempts);
    end;
  except
    // The timeout above, or a failed connect after waiting: the span ends
    // with it. A bare "raise" only (see BuildDatabaseException).
    on E: Exception do
    begin
      FinishWaitSpan(E);
      raise;
    end;
  end;
end;

function TConnectionPool.AcquireQuery(out AQuery: IQuery; ATransaction: ITransaction): IScopeTransaction;
var
  LConn: IDBConnection;
  RealQuery: IQuery;
  LTransaction: ITransaction;
begin
  if Assigned(ATransaction) then
  begin
    LTransaction := ATransaction;
    LConn := ATransaction.GetConnection;
  end
  else
  begin
    LConn := AcquireConnection;
    LTransaction := FFactory.CreateTransaction(LConn);
  end;

  RealQuery := FFactory.CreateQuery(LConn, LTransaction);
  AQuery := TQueryWrapper.Create(Self, RealQuery, FOnStatement, FDbSystem);
  Result := FFactory.CreateScopeTransaction(LTransaction);
end;

function TConnectionPool.GetActiveConnections: Integer;
begin
  Result := FActiveConnections;
end;

function TConnectionPool.GetPoolSize: Integer;
begin
  Result := FPool.Count;
end;

function TConnectionPool.GetWaitMaxAttemps: Integer;
begin
  Result := FWaitMaxAttemps;
end;

function TConnectionPool.GetWaitMilliseconds: Integer;
begin
  Result := FWaitMilliseconds;
end;

procedure TConnectionPool.ReleaseConnection(AConn: IDBConnection);
var
  LUnwrapper: IUnwrapDBConnection;
  LRealConn: IDBConnection;
begin
  if AConn = nil then
    Exit;

  if Supports(AConn, IUnwrapDBConnection, LUnwrapper) then
    LRealConn := LUnwrapper.GetRealConnection
  else
    LRealConn := AConn;

  try
    LRealConn.Rollback;
  except
    // Called from TConnectionWrapper.Destroy (a destructor) — never lets the
    // exception escape from here. A connection that fails on Rollback didn't
    // look broken until now (otherwise it would already have come with
    // FDiscard=True); still, don't risk re-queueing it — discard it.
    DiscardConnection(LRealConn);
    Exit;
  end;

  FLockPool.Enter;
  try
    FPool.Add(TConnectionItem.New(LRealConn));
  finally
    FLockPool.Leave;
  end;
end;

procedure TConnectionPool.DiscardConnection(AConn: IDBConnection);
var
  LUnwrapper: IUnwrapDBConnection;
  LRealConn: IDBConnection;
  LEvent: TPoolEvent;
begin
  if AConn = nil then
    Exit;

  if Supports(AConn, IUnwrapDBConnection, LUnwrapper) then
    LRealConn := LUnwrapper.GetRealConnection
  else
    LRealConn := AConn;

  try
    LRealConn.Disconnect(True);
  except
    // ignore — the connection is being discarded anyway
  end;

  DecrementActiveConnections;
  PcAtomicInc64(FTotalDiscarded);
  LEvent := BaseEvent(pekConnectionDiscarded);
  LEvent.DiscardReason := pdrBrokenAfterUse;
  Notify(LEvent);
  MarkIdleConnectionsSuspect;
end;

procedure TConnectionPool.MarkIdleConnectionsSuspect;
var
  LItem: TConnectionItem;
  I: Integer;
begin
  FLockPool.Enter;
  try
    for I := 0 to FPool.Count - 1 do
    begin
      LItem := FPool[I];
      LItem.LastAlive := 0;
      FPool[I] := LItem;
    end;
  finally
    FLockPool.Leave;
  end;
end;

procedure TConnectionPool.ReleaseQuery(var AQuery: IQuery);
begin
  if not Assigned(AQuery) then
    Exit;

  AQuery.Close;
  AQuery := nil;
end;

end.
