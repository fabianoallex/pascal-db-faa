unit PascalDb.Adapter.DataSet;

{$I pascaldb.inc}

{ TDataSet-based building blocks for adapters whose driver exposes queries as
  TDataSet descendants — FireDAC (TFDQuery), Zeos (TZQuery) and SQLdb
  (TSQLQuery) all do. Uses only Data.DB (Delphi) / db (FPC), which have the
  same TDataSet/TField/TParams API for what is used here.

  - TDBParams — TParamsBase (PascalDb.Adapter.Base) over a Data.DB/db
    TParams collection, the parameter type of SQLdb (and of any driver built
    on TParams). A NULL parameter gets the DataType of the value it stands
    for. Zeos 8 has its own TZParams: its adapter implements TParamsBase
    directly.
  - TDataSetQueryBase — IQuery + IQueryResult over the driver's query
    dataset. A driver subclass only says which dataset it is, where its SQL
    text lives, how to execute a statement and which IParams to use.

  Reading non-nullable values uses TField semantics: a NULL column reads as
  '' / 0 / False instead of raising (the origin library converted through
  Variant, and a Null Variant raises on Delphi). Use the NullableXxx getters
  for nullable columns. Booleans are converted through Variant, so a
  Firebird 2.5 "boolean" stored as an integer (or 'S'/'N'-style text
  understood by the Variant conversion) still reads. }

interface

uses
  Classes,
  SysUtils,
  Variants,
  DB,
  PascalDb.Interfaces,
  PascalDb.Optionals,
  PascalDb.Adapter.Base;

type
  { TDBParams }

  TDBParams = class(TParamsBase)
  private
    FParams: TParams;
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
    /// AParams is not owned (it belongs to the query).
    constructor Create(AParams: TParams);
    class function FieldTypeOf(AType: TPdbParamType): TFieldType; static;
  end;

  { TDataSetQueryBase }

  TDataSetQueryBase = class(TInterfacedObject, IQuery, IQueryResult)
  private
    FConn: IDBConnection;
    FTransaction: ITransaction;
    FParams: IParams;
    function Field(const AName: string): TField;
  protected
    /// The driver's query component (a TDataSet descendant).
    function DataSet: TDataSet; virtual; abstract;
    /// The query component's SQL lines (TFDQuery.SQL, TSQLQuery.SQL, ...).
    function SqlLines: TStrings; virtual; abstract;
    /// Executes a statement that returns no rows (the driver's ExecSQL).
    procedure DoExecSql; virtual; abstract;
    /// Opens the dataset (DataSet.Open); an adapter overrides it to handle a
    /// driver-specific failure (e.g. retrying once).
    procedure DoOpen; virtual;
    /// Drops the parameters of the previous SQL before new SQL is set.
    procedure DoClearParams; virtual; abstract;
    /// The IParams over the query's parameters; called once, lazily.
    function CreateParams: IParams; virtual; abstract;
  public
    constructor Create(const AConn: IDBConnection; const ATransaction: ITransaction);
    // IQuery
    function GetParams: IParams;
    procedure SetSql(const ASql: string);
    function GetSql: string;
    /// Starts the transaction if needed, (re)opens the dataset and returns
    /// this same object as the result.
    function Open: IQueryResult;
    procedure Close;
    procedure ExecSql;
    function GetConnection: IDBConnection;
    function GetTransaction: ITransaction;
    // IQueryResult
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

implementation

{ TDBParams }

constructor TDBParams.Create(AParams: TParams);
begin
  inherited Create;
  FParams := AParams;
end;

class function TDBParams.FieldTypeOf(AType: TPdbParamType): TFieldType;
begin
  case AType of
    // Delphi: ftWideString, because a ftString (ANSI) parameter is converted
    // to the ANSI code page and characters outside it reach the database as
    // "?" (observed with FireDAC). FPC: string is already UTF-8 (see
    // CLAUDE.md, "Runtime requirements for FPC applications").
    pptString: Result := {$IFDEF FPC}ftString{$ELSE}ftWideString{$ENDIF};
    pptBoolean: Result := ftBoolean;
    pptDateTime: Result := ftDateTime;
    pptDouble: Result := ftFloat;
    pptInteger: Result := ftInteger;
    pptInt64: Result := ftLargeint;
    pptCurrency: Result := ftCurrency;
  else
    Result := ftUnknown;
  end;
end;

function TDBParams.ParamExists(const AName: string): Boolean;
begin
  Result := FParams.FindParam(AName) <> nil;
end;

function TDBParams.ParamIsNull(const AName: string): Boolean;
begin
  Result := FParams.ParamByName(AName).IsNull;
end;

procedure TDBParams.WriteNull(const AName: string; AType: TPdbParamType);
var
  LParam: TParam;
begin
  LParam := FParams.ParamByName(AName);
  LParam.DataType := FieldTypeOf(AType);
  LParam.Clear;
end;

function TDBParams.ReadString(const AName: string): string;
begin
  Result := FParams.ParamByName(AName).AsString;
end;

function TDBParams.ReadBoolean(const AName: string): Boolean;
begin
  Result := FParams.ParamByName(AName).AsBoolean;
end;

function TDBParams.ReadDateTime(const AName: string): TDateTime;
begin
  Result := FParams.ParamByName(AName).AsDateTime;
end;

function TDBParams.ReadDouble(const AName: string): Double;
begin
  Result := FParams.ParamByName(AName).AsFloat;
end;

function TDBParams.ReadInteger(const AName: string): Integer;
begin
  Result := FParams.ParamByName(AName).AsInteger;
end;

function TDBParams.ReadInt64(const AName: string): Int64;
begin
  Result := FParams.ParamByName(AName).AsLargeInt;
end;

function TDBParams.ReadCurrency(const AName: string): Currency;
begin
  Result := FParams.ParamByName(AName).AsCurrency;
end;

procedure TDBParams.WriteString(const AName: string; AValue: string);
begin
  // AsWideString on Delphi — see FieldTypeOf.
  {$IFDEF FPC}
  FParams.ParamByName(AName).AsString := AValue;
  {$ELSE}
  FParams.ParamByName(AName).AsWideString := AValue;
  {$ENDIF}
end;

procedure TDBParams.WriteBoolean(const AName: string; AValue: Boolean);
begin
  FParams.ParamByName(AName).AsBoolean := AValue;
end;

procedure TDBParams.WriteDateTime(const AName: string; AValue: TDateTime);
begin
  FParams.ParamByName(AName).AsDateTime := AValue;
end;

procedure TDBParams.WriteDouble(const AName: string; AValue: Double);
begin
  FParams.ParamByName(AName).AsFloat := AValue;
end;

procedure TDBParams.WriteInteger(const AName: string; AValue: Integer);
begin
  FParams.ParamByName(AName).AsInteger := AValue;
end;

procedure TDBParams.WriteInt64(const AName: string; AValue: Int64);
begin
  FParams.ParamByName(AName).AsLargeInt := AValue;
end;

procedure TDBParams.WriteCurrency(const AName: string; AValue: Currency);
begin
  FParams.ParamByName(AName).AsCurrency := AValue;
end;

{ TDataSetQueryBase }

constructor TDataSetQueryBase.Create(const AConn: IDBConnection; const ATransaction: ITransaction);
begin
  inherited Create;
  FConn := AConn;
  FTransaction := ATransaction;
end;

function TDataSetQueryBase.Field(const AName: string): TField;
begin
  Result := DataSet.FieldByName(AName);
end;

function TDataSetQueryBase.GetParams: IParams;
begin
  if not Assigned(FParams) then
    FParams := CreateParams;
  Result := FParams;
end;

procedure TDataSetQueryBase.SetSql(const ASql: string);
begin
  if DataSet.Active then
    DataSet.Close;
  DoClearParams;
  // Clear first, so the driver always sees a change and re-creates the
  // parameters: Zeos doesn't re-parse an SQL text equal to the current one,
  // and the parameters DoClearParams just removed would never come back.
  SqlLines.Clear;
  SqlLines.Text := ASql;
end;

function TDataSetQueryBase.GetSql: string;
begin
  Result := SqlLines.Text;
end;

function TDataSetQueryBase.Open: IQueryResult;
begin
  if not FTransaction.InTransaction then
    FTransaction.StartTransaction;
  if DataSet.Active then
    DataSet.Close;
  DoOpen;
  Result := Self;
end;

procedure TDataSetQueryBase.DoOpen;
begin
  DataSet.Open;
end;

procedure TDataSetQueryBase.Close;
begin
  if DataSet.Active then
    DataSet.Close;
end;

procedure TDataSetQueryBase.ExecSql;
begin
  DoExecSql;
end;

function TDataSetQueryBase.GetConnection: IDBConnection;
begin
  Result := FConn;
end;

function TDataSetQueryBase.GetTransaction: ITransaction;
begin
  Result := FTransaction;
end;

function TDataSetQueryBase.GetAsBoolean(const AName: string): Boolean;
var
  LField: TField;
begin
  LField := Field(AName);
  if LField.IsNull then
    Result := False
  else
    Result := LField.AsVariant;
end;

function TDataSetQueryBase.GetAsDateTime(const AName: string): TDateTime;
begin
  Result := Field(AName).AsDateTime;
end;

function TDataSetQueryBase.GetAsInteger(const AName: string): Integer;
begin
  Result := Field(AName).AsInteger;
end;

function TDataSetQueryBase.GetAsInt64(const AName: string): Int64;
begin
  Result := Field(AName).AsLargeInt;
end;

function TDataSetQueryBase.GetAsString(const AName: string): string;
begin
  Result := Field(AName).AsString;
end;

function TDataSetQueryBase.GetAsCurrency(const AName: string): Currency;
begin
  Result := Field(AName).AsCurrency;
end;

function TDataSetQueryBase.GetNullableBoolean(const AName: string): INullBoolean;
begin
  if Field(AName).IsNull then
    Exit(TOptNullBoolean.Null);
  Result := TOptNullBoolean.From(GetAsBoolean(AName)) as INullBoolean;
end;

function TDataSetQueryBase.GetNullableDateTime(const AName: string): INullDateTime;
var
  LField: TField;
begin
  LField := Field(AName);
  if LField.IsNull then
    Exit(TOptNullDateTime.Null);
  Result := TOptNullDateTime.From(LField.AsDateTime);
end;

function TDataSetQueryBase.GetNullableInteger(const AName: string): INullInteger;
var
  LField: TField;
begin
  LField := Field(AName);
  if LField.IsNull then
    Exit(TOptNullInteger.Null);
  Result := TOptNullInteger.From(LField.AsInteger);
end;

function TDataSetQueryBase.GetNullableInt64(const AName: string): INullInt64;
var
  LField: TField;
begin
  LField := Field(AName);
  if LField.IsNull then
    Exit(TOptNullInt64.Null);
  Result := TOptNullInt64.From(LField.AsLargeInt);
end;

function TDataSetQueryBase.GetNullableString(const AName: string): INullString;
var
  LField: TField;
begin
  LField := Field(AName);
  if LField.IsNull then
    Exit(TOptNullString.Null);
  Result := TOptNullString.From(LField.AsString);
end;

function TDataSetQueryBase.GetNullableCurrency(const AName: string): INullCurrency;
var
  LField: TField;
begin
  LField := Field(AName);
  if LField.IsNull then
    Exit(TOptNullCurrency.Null);
  Result := TOptNullCurrency.From(LField.AsCurrency);
end;

function TDataSetQueryBase.IsEmpty: Boolean;
begin
  Result := DataSet.IsEmpty;
end;

function TDataSetQueryBase.FieldCount: Integer;
begin
  Result := DataSet.FieldCount;
end;

function TDataSetQueryBase.FieldValue(AIndex: Integer): Variant;
begin
  Result := DataSet.Fields[AIndex].AsVariant;
end;

function TDataSetQueryBase.RecordCount: Integer;
begin
  Result := DataSet.RecordCount;
end;

procedure TDataSetQueryBase.Next;
begin
  DataSet.Next;
end;

function TDataSetQueryBase.Eof: Boolean;
begin
  Result := DataSet.Eof;
end;

end.
