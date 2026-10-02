unit PascalDb.Batch;

{$I pascaldb.inc}

{ TBatch, the IBatch over an IQuery: one statement run for many rows of
  parameters.

  The rows are kept in memory (each value with its parameter type) and sent
  MaxRows at a time: AddRow sends them when they reach MaxRows, Execute sends
  what is left. When the query implements INativeBatchQuery and its driver
  supports it, a batch of rows goes to the database as one array operation;
  otherwise each row is one ExecSql of the same query, which the adapters
  keep prepared. Measured, 10000 INSERTs in one transaction (probe in
  .ci/probe-batch): FireDAC's Array DML took 0.15 s instead of 0.63 s on a
  local Firebird 2.5, 0.56 s instead of 6.1 s on PostgreSQL and 0.17 s
  instead of 26 s on MySQL (both in Docker on the same Windows machine).
  SQLdb has no array operation and Zeos's didn't hold up (docs/gotchas.md,
  gotcha 44): both run row by row.

  Row semantics: Params starts empty for every row. A parameter set in some
  row of the batch and not in another (or set to an Undefined optional) is
  NULL in that one, so no value leaks from a row to the next. A parameter
  keeps the type of its first value or NULL (Strings, NullIntegers, ...), and
  a different type in a later row raises EArgumentException: an array
  operation has one type per parameter.

  Failures: a row the database rejects fails the whole Execute (or the
  AddRow that sent it) with the same exceptions as ExecSql
  (ELockConflictException, EDatabaseUnavailableException, the driver's). The
  rows of that send are dropped, the rows sent before are already in the
  transaction: roll it back. Rows added and never sent (no Execute) are
  dropped with the batch. }

interface

uses
  Classes,
  SysUtils,
  Variants,
  Generics.Collections,
  PascalDb.Interfaces,
  PascalDb.Optionals,
  PascalDb.Adapter.Base;

const
  PDB_BATCH_DEFAULT_MAX_ROWS = 1000;

type
  // Named, because FPC 3.2.2 doesn't parse TList<TArray<Variant>>.Create.
  TPdbBatchRow = TArray<Variant>;
  TPdbBatchRowList = TList<TPdbBatchRow>;

  { TBatch }

  TBatch = class(TInterfacedObject, IBatch)
  private
    FQuery: IQuery;
    FNative: INativeBatchQuery;
    FIsNative: Boolean;
    FParams: IParams;
    FNames: TList<string>;
    FTypes: TList<TPdbParamType>;
    FIndex: TDictionary<string, Integer>; // upper-case name -> column
    FRows: TPdbBatchRowList;
    FCurrent: TPdbBatchRow;
    FMaxRows: Integer;
    function ColumnOf(const AName: string): Integer;
    function CurrentValue(const AName: string): Variant;
    procedure PutValue(const AName: string; AType: TPdbParamType; const AValue: Variant);
    function CurrentRowHasValues: Boolean;
    procedure ExecLoop(const ARows: IBatchRows);
  public
    /// Sets ASql on AQuery and returns a batch over it. AQuery stays usable
    /// for other statements once the batch is done, but not in between: the
    /// batch keeps its SQL and parameters. AMaxRows: rows per send (>= 1).
    class function New(const AQuery: IQuery; const ASql: string;
      AMaxRows: Integer = PDB_BATCH_DEFAULT_MAX_ROWS): IBatch;
    constructor Create(const AQuery: IQuery; const ASql: string; AMaxRows: Integer);
    destructor Destroy; override;
    function GetParams: IParams;
    function GetMaxRows: Integer;
    procedure SetMaxRows(AValue: Integer);
    procedure AddRow;
    function PendingRows: Integer;
    procedure Execute;
    function IsNative: Boolean;
  end;

  { TBatchRows
    IBatchRows over a copy of the rows of one send. A row shorter than the
    parameter list (a parameter first set in a later row) is NULL in the
    missing parameters. Public so adapter tests can build one. }

  TBatchRows = class(TInterfacedObject, IBatchRows)
  private
    FNames: TArray<string>;
    FTypes: TArray<TPdbParamType>;
    FRows: TArray<TPdbBatchRow>;
    function Value(ARow, AParam: Integer): Variant;
  public
    constructor Create(const ANames: TArray<string>; const ATypes: TArray<TPdbParamType>;
      const ARows: TArray<TPdbBatchRow>);
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
    function MaxLength(AParam: Integer): Integer;
  end;

/// The type's name in messages ('String', 'Integer', ...).
function PdbParamTypeName(AType: TPdbParamType): string;

implementation

const
  PARAM_TYPE_NAMES: array[TPdbParamType] of string =
    ('String', 'Boolean', 'DateTime', 'Double', 'Integer', 'Int64', 'Currency');

function PdbParamTypeName(AType: TPdbParamType): string;
begin
  Result := PARAM_TYPE_NAMES[AType];
end;

type
  { TBatchRowParams
    The IParams of a batch: the current row's values, kept by the batch.
    Holds the batch without a reference count: the batch owns it. }

  TBatchRowParams = class(TParamsBase)
  private
    FOwner: TBatch;
    function Current(const AName: string): Variant;
  protected
    function ParamExists(const AName: string): Boolean; override;
    function ParamIsNull(const AName: string): Boolean; override;
    procedure WriteNull(const AName: string; AType: TPdbParamType); override;
    function ReadString(const AName: string): string; override;
    function ReadBoolean(const AName: string): Boolean; override;
    function ReadDateTime(const AName: string): TDateTime; override;
    function ReadDouble(const AName: string): Double; override;
    function ReadInteger(const AName: string): Integer; override;
    function ReadInt64(const AName: string): Int64; override;
    function ReadCurrency(const AName: string): Currency; override;
    procedure WriteString(const AName: string; AValue: string); override;
    procedure WriteBoolean(const AName: string; AValue: Boolean); override;
    procedure WriteDateTime(const AName: string; AValue: TDateTime); override;
    procedure WriteDouble(const AName: string; AValue: Double); override;
    procedure WriteInteger(const AName: string; AValue: Integer); override;
    procedure WriteInt64(const AName: string; AValue: Int64); override;
    procedure WriteCurrency(const AName: string; AValue: Currency); override;
  public
    constructor Create(AOwner: TBatch);
  end;

{ TBatchRowParams }

constructor TBatchRowParams.Create(AOwner: TBatch);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TBatchRowParams.Current(const AName: string): Variant;
begin
  Result := FOwner.CurrentValue(AName);
  if VarIsEmpty(Result) then
    raise EArgumentException.CreateFmt('TBatch: parameter "%s" has no value in this row', [AName]);
end;

function TBatchRowParams.ParamExists(const AName: string): Boolean;
begin
  Result := not VarIsEmpty(FOwner.CurrentValue(AName));
end;

function TBatchRowParams.ParamIsNull(const AName: string): Boolean;
begin
  Result := VarIsNull(FOwner.CurrentValue(AName));
end;

procedure TBatchRowParams.WriteNull(const AName: string; AType: TPdbParamType);
begin
  FOwner.PutValue(AName, AType, Null);
end;

function TBatchRowParams.ReadString(const AName: string): string;
begin
  Result := VarToStr(Current(AName));
end;

function TBatchRowParams.ReadBoolean(const AName: string): Boolean;
begin
  Result := Current(AName);
end;

function TBatchRowParams.ReadDateTime(const AName: string): TDateTime;
begin
  Result := VarToDateTime(Current(AName));
end;

function TBatchRowParams.ReadDouble(const AName: string): Double;
begin
  Result := Current(AName);
end;

function TBatchRowParams.ReadInteger(const AName: string): Integer;
begin
  Result := Current(AName);
end;

function TBatchRowParams.ReadInt64(const AName: string): Int64;
begin
  Result := Current(AName);
end;

function TBatchRowParams.ReadCurrency(const AName: string): Currency;
begin
  Result := Current(AName);
end;

procedure TBatchRowParams.WriteString(const AName: string; AValue: string);
begin
  FOwner.PutValue(AName, pptString, AValue);
end;

procedure TBatchRowParams.WriteBoolean(const AName: string; AValue: Boolean);
begin
  FOwner.PutValue(AName, pptBoolean, AValue);
end;

procedure TBatchRowParams.WriteDateTime(const AName: string; AValue: TDateTime);
begin
  FOwner.PutValue(AName, pptDateTime, VarFromDateTime(AValue));
end;

procedure TBatchRowParams.WriteDouble(const AName: string; AValue: Double);
begin
  FOwner.PutValue(AName, pptDouble, AValue);
end;

procedure TBatchRowParams.WriteInteger(const AName: string; AValue: Integer);
begin
  FOwner.PutValue(AName, pptInteger, AValue);
end;

procedure TBatchRowParams.WriteInt64(const AName: string; AValue: Int64);
begin
  FOwner.PutValue(AName, pptInt64, AValue);
end;

procedure TBatchRowParams.WriteCurrency(const AName: string; AValue: Currency);
begin
  FOwner.PutValue(AName, pptCurrency, AValue);
end;

{ TBatch }

class function TBatch.New(const AQuery: IQuery; const ASql: string; AMaxRows: Integer): IBatch;
begin
  Result := TBatch.Create(AQuery, ASql, AMaxRows);
end;

constructor TBatch.Create(const AQuery: IQuery; const ASql: string; AMaxRows: Integer);
begin
  inherited Create;
  if not Assigned(AQuery) then
    raise EArgumentException.Create('TBatch: the query is nil');
  FNames := TList<string>.Create;
  FTypes := TList<TPdbParamType>.Create;
  FIndex := TDictionary<string, Integer>.Create;
  FRows := TPdbBatchRowList.Create;
  SetMaxRows(AMaxRows);
  FQuery := AQuery;
  FQuery.Sql := ASql;
  FIsNative := Supports(FQuery, INativeBatchQuery, FNative) and FNative.SupportsNativeBatch;
  FParams := TBatchRowParams.Create(Self);
end;

destructor TBatch.Destroy;
begin
  FParams := nil;
  FRows.Free;
  FIndex.Free;
  FTypes.Free;
  FNames.Free;
  inherited Destroy;
end;

function TBatch.ColumnOf(const AName: string): Integer;
begin
  if not FIndex.TryGetValue(UpperCase(AName), Result) then
    Result := -1;
end;

function TBatch.CurrentValue(const AName: string): Variant;
var
  LCol: Integer;
begin
  LCol := ColumnOf(AName);
  if (LCol < 0) or (LCol >= Length(FCurrent)) then
    Result := Unassigned
  else
    Result := FCurrent[LCol];
end;

procedure TBatch.PutValue(const AName: string; AType: TPdbParamType; const AValue: Variant);
var
  LCol: Integer;
begin
  LCol := ColumnOf(AName);
  if LCol < 0 then
  begin
    LCol := FNames.Add(AName);
    FTypes.Add(AType);
    FIndex.Add(UpperCase(AName), LCol);
  end
  else if FTypes[LCol] <> AType then
    raise EArgumentException.CreateFmt(
      'TBatch: parameter "%s" is %s in this batch, not %s: use the same type in every row',
      [AName, PdbParamTypeName(FTypes[LCol]), PdbParamTypeName(AType)]);
  if Length(FCurrent) <= LCol then
    SetLength(FCurrent, LCol + 1);
  FCurrent[LCol] := AValue;
end;

function TBatch.CurrentRowHasValues: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FCurrent) do
    if not VarIsEmpty(FCurrent[I]) then
      Exit(True);
  Result := False;
end;

function TBatch.GetParams: IParams;
begin
  Result := FParams;
end;

function TBatch.GetMaxRows: Integer;
begin
  Result := FMaxRows;
end;

procedure TBatch.SetMaxRows(AValue: Integer);
begin
  if AValue < 1 then
    raise EArgumentException.CreateFmt('TBatch: MaxRows must be at least 1, not %d', [AValue]);
  FMaxRows := AValue;
end;

procedure TBatch.AddRow;
begin
  FRows.Add(FCurrent);
  FCurrent := nil;
  if FRows.Count >= FMaxRows then
    Execute;
end;

function TBatch.PendingRows: Integer;
begin
  Result := FRows.Count;
end;

procedure TBatch.Execute;
var
  LRows: TArray<TPdbBatchRow>;
  LBatchRows: IBatchRows;
  I: Integer;
begin
  // Values set after the last AddRow would silently stay behind: almost
  // always a missing AddRow for the last row.
  if CurrentRowHasValues then
    raise EInvalidOpException.Create('TBatch.Execute: the current row has values but was not added (AddRow)');
  if FRows.Count = 0 then
    Exit;
  SetLength(LRows, FRows.Count);
  for I := 0 to FRows.Count - 1 do
    LRows[I] := FRows[I];
  // Dropped before sending: a failed send must not be sent again by the next
  // Execute (see the unit header).
  FRows.Clear;
  LBatchRows := TBatchRows.Create(FNames.ToArray, FTypes.ToArray, LRows);
  if FIsNative then
    FNative.ExecBatch(LBatchRows)
  else
    ExecLoop(LBatchRows);
end;

procedure TBatch.ExecLoop(const ARows: IBatchRows);
var
  LParams: IParams;
  R, P: Integer;
  LName: string;
begin
  LParams := FQuery.Params;
  for R := 0 to ARows.RowCount - 1 do
  begin
    // Every parameter of the batch, every row: the previous row's value must
    // never stay bound (see the unit header).
    for P := 0 to ARows.ParamCount - 1 do
    begin
      LName := ARows.ParamName(P);
      if ARows.IsNull(R, P) then
        case ARows.ParamType(P) of
          pptString: LParams.SetNullString(LName, TOptNullString.Null);
          pptBoolean: LParams.SetNullBoolean(LName, TOptNullBoolean.Null);
          pptDateTime: LParams.SetNullDateTime(LName, TOptNullDateTime.Null);
          pptDouble: LParams.SetNullDouble(LName, TOptNullDouble.Null);
          pptInteger: LParams.SetNullInteger(LName, TOptNullInteger.Null);
          pptInt64: LParams.SetNullInt64(LName, TOptNullInt64.Null);
          pptCurrency: LParams.SetNullCurrency(LName, TOptNullCurrency.Null);
        end
      else
        case ARows.ParamType(P) of
          pptString: LParams.SetString(LName, ARows.AsString(R, P));
          pptBoolean: LParams.SetBoolean(LName, ARows.AsBoolean(R, P));
          pptDateTime: LParams.SetDateTime(LName, ARows.AsDateTime(R, P));
          pptDouble: LParams.SetDouble(LName, ARows.AsDouble(R, P));
          pptInteger: LParams.SetInteger(LName, ARows.AsInteger(R, P));
          pptInt64: LParams.SetInt64(LName, ARows.AsInt64(R, P));
          pptCurrency: LParams.SetCurrency(LName, ARows.AsCurrency(R, P));
        end;
    end;
    FQuery.ExecSql;
  end;
end;

function TBatch.IsNative: Boolean;
begin
  Result := FIsNative;
end;

{ TBatchRows }

constructor TBatchRows.Create(const ANames: TArray<string>; const ATypes: TArray<TPdbParamType>;
  const ARows: TArray<TPdbBatchRow>);
begin
  inherited Create;
  FNames := ANames;
  FTypes := ATypes;
  FRows := ARows;
end;

function TBatchRows.Value(ARow, AParam: Integer): Variant;
begin
  if AParam < Length(FRows[ARow]) then
    Result := FRows[ARow][AParam]
  else
    Result := Unassigned;
end;

function TBatchRows.RowCount: Integer;
begin
  Result := Length(FRows);
end;

function TBatchRows.ParamCount: Integer;
begin
  Result := Length(FNames);
end;

function TBatchRows.ParamName(AParam: Integer): string;
begin
  Result := FNames[AParam];
end;

function TBatchRows.ParamType(AParam: Integer): TPdbParamType;
begin
  Result := FTypes[AParam];
end;

function TBatchRows.IsNull(ARow, AParam: Integer): Boolean;
var
  LValue: Variant;
begin
  LValue := Value(ARow, AParam);
  Result := VarIsNull(LValue) or VarIsEmpty(LValue);
end;

function TBatchRows.AsString(ARow, AParam: Integer): string;
begin
  Result := VarToStr(Value(ARow, AParam));
end;

function TBatchRows.AsBoolean(ARow, AParam: Integer): Boolean;
begin
  Result := Value(ARow, AParam);
end;

function TBatchRows.AsDateTime(ARow, AParam: Integer): TDateTime;
begin
  Result := VarToDateTime(Value(ARow, AParam));
end;

function TBatchRows.AsDouble(ARow, AParam: Integer): Double;
begin
  Result := Value(ARow, AParam);
end;

function TBatchRows.AsInteger(ARow, AParam: Integer): Integer;
begin
  Result := Value(ARow, AParam);
end;

function TBatchRows.AsInt64(ARow, AParam: Integer): Int64;
begin
  Result := Value(ARow, AParam);
end;

function TBatchRows.AsCurrency(ARow, AParam: Integer): Currency;
begin
  Result := Value(ARow, AParam);
end;

function TBatchRows.MaxLength(AParam: Integer): Integer;
var
  R: Integer;
begin
  Result := 0;
  for R := 0 to High(FRows) do
    if not IsNull(R, AParam) then
      if Length(AsString(R, AParam)) > Result then
        Result := Length(AsString(R, AParam));
end;

end.
