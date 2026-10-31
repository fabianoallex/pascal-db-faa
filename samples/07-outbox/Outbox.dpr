program Outbox;

{ Sample 07: a transactional outbox (PascalDb.Outbox, docs/outbox.md).

  An order and the event that announces it are written in one transaction:
  the event exists exactly when the order does (an order rolled back leaves
  no event behind), with no second system written in the same breath. A
  relay then claims the pending events and hands them to a sink; here the
  local sink, which runs the program's own handlers (no broker), one
  delivery per event and handler: the "stock" handler works at once, the
  "email" handler fails its first two tries (its server is down) and is
  retried on its own after TOutboxRetry's delay, without running "stock"
  again. At the end the delivered events are purged.

  The passes don't sleep or loop: a real program calls TOutboxRelay.RunOnce
  and the local sink's RunOnce on a timer or a worker thread, with the
  current Unix time. This sample passes the times itself (1000, 1002,
  1005) so its output is the same on every run.

  SQL: the outbox's tables and statements are the application's, read by
  name through the factory's loader. This sample embeds the reference SQL of
  docs/outbox/sql unchanged (sql/OutboxSql.res, built by
  tools/build_sql_res.py from that folder): the database's own folder (PG,
  FB, SQLITE, MYSQL or MSSQL, from Samples.Env), then COMMON. After editing
  a file there, rebuild the .res:
    python tools/build_sql_res.py docs/outbox/sql samples/07-outbox/sql/OutboxSql.res
  An application copies those files into its own SQL folder and runs
  OUTBOX.SCHEMA as a DDL migration; this sample drops and creates its tables
  on every run instead (SAMPLE_ORDERS, OUTBOX, OUTBOX_DELIVERIES), so it
  leaves the samples' SCHEMA_MIGRATIONS (sample 03's) alone.

  Same source for Delphi (Outbox.dproj) and Lazarus/FPC (Outbox.lpi);
  connection settings as in sample 02. The handlers and the error callback
  are methods: TOutboxErrorProc is "reference to" on Delphi and "of object"
  on FPC 3.2.2, and a method compiles on both. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

// Not "Outbox.res": the Delphi IDE writes one next to this file, and FPC with
// a unit output folder (-FU) links a same-named .res from the program's folder
// instead of the path given here (CLAUDE.md, gotcha 19).
{$R 'sql/OutboxSql.res'}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring, // FPC on Unix: needed for non-ASCII text in Variants (see CLAUDE.md)
  {$ENDIF}
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Outbox,
  Samples.Env;

const
  TENANT = 'shop';
  KIND_ORDER_PLACED = 'order.placed';

type
  /// Sends the order's confirmation; its server is down for the first
  /// FailsLeft tries.
  TEmailHandler = class(TInterfacedObject, IOutboxHandler)
  private
    FFailsLeft: Integer;
  public
    constructor Create(AFails: Integer);
    function Name: string;
    function Accepts(const AKind: string): Boolean;
    procedure Handle(const AEvent: TOutboxEvent);
  end;

  /// Reserves the order's items.
  TStockHandler = class(TInterfacedObject, IOutboxHandler)
  public
    function Name: string;
    function Accepts(const AKind: string): Boolean;
    procedure Handle(const AEvent: TOutboxEvent);
  end;

  TOutboxLog = class
  public
    procedure OnError(const AEvent: TOutboxEvent; const AHandler, AMessage: string);
  end;

constructor TEmailHandler.Create(AFails: Integer);
begin
  inherited Create;
  FFailsLeft := AFails;
end;

function TEmailHandler.Name: string;
begin
  Result := 'email';
end;

function TEmailHandler.Accepts(const AKind: string): Boolean;
begin
  Result := AKind = KIND_ORDER_PLACED;
end;

procedure TEmailHandler.Handle(const AEvent: TOutboxEvent);
begin
  if FFailsLeft > 0 then
  begin
    Dec(FFailsLeft);
    raise Exception.Create('SMTP server unavailable');
  end;
  // A handler may run twice for one event (delivery is at-least-once): a
  // real one remembers AEvent.Id, or its side effect tolerates a repeat.
  Writeln('  email: confirmation sent for ', AEvent.Payload);
end;

function TStockHandler.Name: string;
begin
  Result := 'stock';
end;

function TStockHandler.Accepts(const AKind: string): Boolean;
begin
  Result := AKind = KIND_ORDER_PLACED;
end;

procedure TStockHandler.Handle(const AEvent: TOutboxEvent);
begin
  Writeln('  stock: items reserved for ', AEvent.Payload);
end;

procedure TOutboxLog.OnError(const AEvent: TOutboxEvent; const AHandler, AMessage: string);
begin
  // AMessage is "<exception class>: <message>".
  Writeln('  ', AHandler, ' failed for ', AEvent.Payload, ' (attempt ', AEvent.Attempts + 1,
    '): ', AMessage);
end;

procedure Exec(const AFactory: IDBFactory; const ASql: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := ASql;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure ExecIgnoringErrors(const AFactory: IDBFactory; const ASql: string);
begin
  try
    Exec(AFactory, ASql);
  except
    // the table didn't exist: nothing to drop
  end;
end;

// Fresh tables on every run. OUTBOX.SCHEMA is split at ';', as a migration
// with that terminator would, and each statement committed on its own
// (Firebird can't use a table in the transaction that created it).
procedure CreateTables(const AFactory: IDBFactory);
var
  LScript: string;
  P: Integer;
begin
  ExecIgnoringErrors(AFactory, 'DROP TABLE OUTBOX_DELIVERIES');
  ExecIgnoringErrors(AFactory, 'DROP TABLE OUTBOX');
  ExecIgnoringErrors(AFactory, 'DROP TABLE SAMPLE_ORDERS');
  LScript := AFactory.SqlLoader['OUTBOX.SCHEMA'].SQL;
  P := Pos(';', LScript);
  while P > 0 do
  begin
    if Trim(Copy(LScript, 1, P - 1)) <> '' then
      Exec(AFactory, Copy(LScript, 1, P - 1));
    Delete(LScript, 1, P);
    P := Pos(';', LScript);
  end;
  if Trim(LScript) <> '' then
    Exec(AFactory, LScript);
  Exec(AFactory, 'CREATE TABLE SAMPLE_ORDERS (ID INTEGER NOT NULL PRIMARY KEY, ' +
    'TOTAL_CENTS INTEGER NOT NULL)');
end;

// The order and its event in one transaction: both or neither.
procedure PlaceOrder(const AFactory: IDBFactory; AId, ATotalCents: Integer; ANow: Int64;
  ACommit: Boolean);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LEventId: string;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'INSERT INTO SAMPLE_ORDERS (ID, TOTAL_CENTS) VALUES (:ID, :TOTAL_CENTS)';
    LQuery.Params.Integers['ID'] := AId;
    LQuery.Params.Integers['TOTAL_CENTS'] := ATotalCents;
    LQuery.ExecSql;
    // Same query, same transaction: Enqueue replaces its SQL.
    LEventId := TOutbox.Enqueue(AFactory, LQuery, TENANT, KIND_ORDER_PLACED,
      Format('{"orderId":%d}', [AId]), ANow);
    if ACommit then
    begin
      LScope.Commit;
      Writeln('order ', AId, ' placed, event ', LEventId);
    end
    else
    begin
      LScope.Rollback;
      Writeln('order ', AId, ' rolled back: its event went with it');
    end;
  except
    LScope.Rollback;
    raise;
  end;
end;

function CountRows(const AFactory: IDBFactory; const AFromWhere: string): Integer;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'SELECT COUNT(*) AS N FROM ' + AFromWhere;
    Result := Integer(LQuery.Open.Int64s['N']);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

procedure Run;
var
  LFactory: IDBFactory;
  LOptions: TOutboxOptions;
  LSink: IOutboxLocalSink;
  LRelay: TOutboxRelay;
  LLog: TOutboxLog;
  LDone: Integer;
begin
  Writeln('Target: ', SampleTarget);
  LFactory := NewSampleFactory(TFallbackSqlSource.Create(TResourceSqlSource.Create, 'COMMON'));
  CheckSampleConnection(LFactory);
  CreateTables(LFactory);
  Writeln;

  PlaceOrder(LFactory, 1, 4990, 990, True);
  PlaceOrder(LFactory, 2, 1500, 991, False);
  PlaceOrder(LFactory, 3, 12000, 995, True);
  Writeln('pending events: ', TOutbox.MeasurePending(LFactory, 1000));
  Writeln;

  LOptions := TOutboxOptions.Default;
  LOptions.Retry.BaseSeconds := 5;
  LLog := TOutboxLog.Create;
  // Each running relay and sink names its leases: PdbOutboxNewOwner makes
  // the name unique.
  LSink := TOutboxLocalSink.Create(LFactory, PdbOutboxNewOwner('sink'), LOptions);
  LSink.SetOnError(LLog.OnError);
  LSink.AddHandler(TEmailHandler.Create(2));
  LSink.AddHandler(TStockHandler.Create);
  LRelay := TOutboxRelay.Create(LFactory, LSink, PdbOutboxNewOwner('relay'), LOptions);
  try
    LRelay.OnError := LLog.OnError;
    // Each pass's result goes to a variable first: the handlers print while
    // RunOnce runs.
    LDone := LRelay.RunOnce(1000);
    Writeln('t=1000 relay: ', LDone, ' delivered, ', CountRows(LFactory, 'OUTBOX_DELIVERIES'),
      ' handler deliveries written');
    Writeln('t=1000 local sink:');
    LDone := LSink.RunOnce(1000);
    Writeln('t=1000 local sink: ', LDone, ' done');
    LDone := LSink.RunOnce(1002);
    Writeln('t=1002 local sink: ', LDone, ' done (the retries wait until 1005)');
    Writeln('t=1005 local sink:');
    LDone := LSink.RunOnce(1005);
    Writeln('t=1005 local sink: ', LDone, ' done');
  finally
    LRelay.Free;
  end;
  Writeln('pending events: ', TOutbox.MeasurePending(LFactory, 1010), ', deliveries done: ',
    CountRows(LFactory, 'OUTBOX_DELIVERIES WHERE STATUS = ''done'''));
  Writeln('purged: ', TOutbox.Purge(LFactory, 2000), ' events');
  LSink := nil;
  LLog.Free;
end;

begin
  {$IFDEF FPC}
  // Plain FPC console programs don't run in UTF-8 by default (see CLAUDE.md).
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
