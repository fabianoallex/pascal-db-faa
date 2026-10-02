unit PascalDb.JsonMapper.Optionals;

{$I pascaldb.inc}

{ JSON converter for the optional types of PascalDb.Optionals, for
  pascal-jsonmapper-faa: lets a DTO declare IOptXxx/INullXxx/IOptNullXxx
  properties and read and write them with TJsonMapper.

  It lives in a package of its own (pascal_db_faa_jsonmapper) so that neither
  core depends on the other: the pascal-db-faa core never uses the mapper and
  the mapper never knows these types. Using this unit registers the
  converter on TJsonMapper.Shared; a mapper created by hand gets it from
  RegisterOptionalsConverter.

  One converter covers the 27 interfaces (9 value types x 3 flavors). The
  JSON rules per flavor:

               reading null       writing nil/Undefined   writing Null
    IOptXxx     error              member omitted          null [1]
    INullXxx    Null               null                    null
    IOptNullXxx Null               member omitted          null

  An absent member never reaches the converter: the property keeps the
  DTO's default (nil, which TOptionals.Safe reads as Undefined or Null).
  Inside an array an omitted element becomes null.

  [1] An IOptXxx has no Null state of its own, but TOptNullXxx.Null
  assigned to one compiles (one class implements the three flavors). Its
  Value would be '' or 0, a made-up value, so it is written as null.

  Two of these rules differ from delphi-api-infra-faa's Common.JsonMapper,
  on purpose. null into an IOptXxx is rejected (that mapper stored a Null,
  a state the type can't express: "may be absent, never null" is exactly
  what IOptXxx says). A nil INullXxx is written as null (that mapper omitted
  every nil interface; TOptionals.Safe reads nil as Null for that flavor, so
  null is the consistent output and the member is never missing).

  Values are read and written by delegating to the mapper (ReadValue /
  WriteValue with the same path), so range checks, exact float text, ISO
  8601 dates and error paths are the mapper's own. The exception is TGUID,
  for which the mapper has no rule: it is written with GUIDToString (with
  braces, as Common.JsonMapper did) and read with or without braces.
  DecimalPlaces of Single/Double is not part of the JSON: written values
  are the shortest exact text, and read values get the default (-1).

  Values are fetched through the declared interface (IOptString,
  INullInteger...), never through IOptional<T>: a generic interface's GUID
  is shared by every specialization, so Supports(X, IOptional<string>) can't
  tell string from Integer. }

interface

uses
  SysUtils, TypInfo, Rtti,
  PascalJsonMapper.Json,
  PascalJsonMapper.Mapper,
  PascalDb.Optionals;

type
  TOptionalsJsonConverter = class(TInterfacedObject, IJsonConverter)
  public
    function CanConvert(ATypeInfo: PTypeInfo): Boolean;
    function ReadJson(AMapper: TJsonMapper; AJson: TJsonValue;
      ATypeInfo: PTypeInfo; const APath: string; out AValue: TValue): Boolean;
    function WriteJson(AMapper: TJsonMapper; const AValue: TValue;
      ATypeInfo: PTypeInfo; const APath: string; AWriter: TJsonWriter): Boolean;
  end;

procedure RegisterOptionalsConverter(AMapper: TJsonMapper);

implementation

type
  TOptFlavor = (ofOpt, ofNull, ofOptNull);

procedure RegisterOptionalsConverter(AMapper: TJsonMapper);
begin
  AMapper.RegisterConverter(TOptionalsJsonConverter.Create);
end;

function Match(ATypeInfo, AOpt, ANull, AOptNull, AValueType: PTypeInfo;
  var AFoundType: PTypeInfo; var AFlavor: TOptFlavor): Boolean;
begin
  Result := True;
  if ATypeInfo = AOpt then
    AFlavor := ofOpt
  else if ATypeInfo = ANull then
    AFlavor := ofNull
  else if ATypeInfo = AOptNull then
    AFlavor := ofOptNull
  else
    Result := False;
  if Result then
    AFoundType := AValueType;
end;

// Which value type and flavor ATypeInfo is; False if it isn't one of ours.
function Describe(ATypeInfo: PTypeInfo; out AValueType: PTypeInfo;
  out AFlavor: TOptFlavor): Boolean;
begin
  AValueType := nil;
  AFlavor := ofOpt;
  Result :=
    Match(ATypeInfo, TypeInfo(IOptString), TypeInfo(INullString),
      TypeInfo(IOptNullString), TypeInfo(string), AValueType, AFlavor) or
    Match(ATypeInfo, TypeInfo(IOptInteger), TypeInfo(INullInteger),
      TypeInfo(IOptNullInteger), TypeInfo(Integer), AValueType, AFlavor) or
    Match(ATypeInfo, TypeInfo(IOptInt64), TypeInfo(INullInt64),
      TypeInfo(IOptNullInt64), TypeInfo(Int64), AValueType, AFlavor) or
    Match(ATypeInfo, TypeInfo(IOptSingle), TypeInfo(INullSingle),
      TypeInfo(IOptNullSingle), TypeInfo(Single), AValueType, AFlavor) or
    Match(ATypeInfo, TypeInfo(IOptDouble), TypeInfo(INullDouble),
      TypeInfo(IOptNullDouble), TypeInfo(Double), AValueType, AFlavor) or
    Match(ATypeInfo, TypeInfo(IOptCurrency), TypeInfo(INullCurrency),
      TypeInfo(IOptNullCurrency), TypeInfo(Currency), AValueType, AFlavor) or
    Match(ATypeInfo, TypeInfo(IOptDateTime), TypeInfo(INullDateTime),
      TypeInfo(IOptNullDateTime), TypeInfo(TDateTime), AValueType, AFlavor) or
    Match(ATypeInfo, TypeInfo(IOptBoolean), TypeInfo(INullBoolean),
      TypeInfo(IOptNullBoolean), TypeInfo(Boolean), AValueType, AFlavor) or
    Match(ATypeInfo, TypeInfo(IOptGuid), TypeInfo(INullGuid),
      TypeInfo(IOptNullGuid), TypeInfo(TGUID), AValueType, AFlavor);
end;

function NewNull(AValueType: PTypeInfo): IInterface;
begin
  if AValueType = TypeInfo(string) then
    Result := TOptNullString.Null
  else if AValueType = TypeInfo(Integer) then
    Result := TOptNullInteger.Null
  else if AValueType = TypeInfo(Int64) then
    Result := TOptNullInt64.Null
  else if AValueType = TypeInfo(Single) then
    Result := TOptNullSingle.Null
  else if AValueType = TypeInfo(Double) then
    Result := TOptNullDouble.Null
  else if AValueType = TypeInfo(Currency) then
    Result := TOptNullCurrency.Null
  else if AValueType = TypeInfo(TDateTime) then
    Result := TOptNullDateTime.Null
  else if AValueType = TypeInfo(Boolean) then
    Result := TOptNullBoolean.Null
  else
    Result := TOptNullGuid.Null;
end;

function ParseGuid(const AText: string): TGUID;
var
  Text: string;
begin
  Text := AText;
  if (Length(Text) = 36) and (Text[1] <> '{') then
    Text := '{' + Text + '}';
  try
    Result := StringToGUID(Text);
  except
    on E: EConvertError do
      raise EJsonError.Create('invalid GUID: "' + AText + '"');
  end;
end;

// The value read by the mapper (of type AValueType) wrapped in an optional.
// TValue's raw data is used as the mapper itself does: TValue.AsType<T>
// isn't available on FPC 3.2.2 for every type.
function NewFrom(AValueType: PTypeInfo; const AValue: TValue): IInterface;
var
  Data: Pointer;
begin
  Data := AValue.GetReferenceToRawData;
  if AValueType = TypeInfo(string) then
    Result := TOptNullString.From(AValue.AsString)
  else if AValueType = TypeInfo(Integer) then
    Result := TOptNullInteger.From(PInteger(Data)^)
  else if AValueType = TypeInfo(Int64) then
    Result := TOptNullInt64.From(PInt64(Data)^)
  else if AValueType = TypeInfo(Single) then
    Result := TOptNullSingle.From(PSingle(Data)^)
  else if AValueType = TypeInfo(Double) then
    Result := TOptNullDouble.From(PDouble(Data)^)
  else if AValueType = TypeInfo(Currency) then
    Result := TOptNullCurrency.From(PCurrency(Data)^)
  else if AValueType = TypeInfo(TDateTime) then
    Result := TOptNullDateTime.From(PDateTime(Data)^)
  else
    Result := TOptNullBoolean.From(PBoolean(Data)^);
end;

// The value held by AIntf (declared as ATypeInfo), as a TValue of AValueType.
function ValueOf(const AIntf: IInterface; AFlavor: TOptFlavor;
  AValueType: PTypeInfo): TValue;
var
  S: string;
  I: Integer;
  I64: Int64;
  Sgl: Single;
  Dbl: Double;
  Cur: Currency;
  Dt: TDateTime;
  B: Boolean;
  G: TGUID;
begin
  if AValueType = TypeInfo(string) then
  begin
    case AFlavor of
      ofOpt: S := (AIntf as IOptString).Value;
      ofNull: S := (AIntf as INullString).Value;
    else
      S := (AIntf as IOptNullString).Value;
    end;
    TValue.Make(@S, AValueType, Result);
  end
  else if AValueType = TypeInfo(Integer) then
  begin
    case AFlavor of
      ofOpt: I := (AIntf as IOptInteger).Value;
      ofNull: I := (AIntf as INullInteger).Value;
    else
      I := (AIntf as IOptNullInteger).Value;
    end;
    TValue.Make(@I, AValueType, Result);
  end
  else if AValueType = TypeInfo(Int64) then
  begin
    case AFlavor of
      ofOpt: I64 := (AIntf as IOptInt64).Value;
      ofNull: I64 := (AIntf as INullInt64).Value;
    else
      I64 := (AIntf as IOptNullInt64).Value;
    end;
    TValue.Make(@I64, AValueType, Result);
  end
  else if AValueType = TypeInfo(Single) then
  begin
    case AFlavor of
      ofOpt: Sgl := (AIntf as IOptSingle).Value;
      ofNull: Sgl := (AIntf as INullSingle).Value;
    else
      Sgl := (AIntf as IOptNullSingle).Value;
    end;
    TValue.Make(@Sgl, AValueType, Result);
  end
  else if AValueType = TypeInfo(Double) then
  begin
    case AFlavor of
      ofOpt: Dbl := (AIntf as IOptDouble).Value;
      ofNull: Dbl := (AIntf as INullDouble).Value;
    else
      Dbl := (AIntf as IOptNullDouble).Value;
    end;
    TValue.Make(@Dbl, AValueType, Result);
  end
  else if AValueType = TypeInfo(Currency) then
  begin
    case AFlavor of
      ofOpt: Cur := (AIntf as IOptCurrency).Value;
      ofNull: Cur := (AIntf as INullCurrency).Value;
    else
      Cur := (AIntf as IOptNullCurrency).Value;
    end;
    TValue.Make(@Cur, AValueType, Result);
  end
  else if AValueType = TypeInfo(TDateTime) then
  begin
    case AFlavor of
      ofOpt: Dt := (AIntf as IOptDateTime).Value;
      ofNull: Dt := (AIntf as INullDateTime).Value;
    else
      Dt := (AIntf as IOptNullDateTime).Value;
    end;
    TValue.Make(@Dt, AValueType, Result);
  end
  else if AValueType = TypeInfo(Boolean) then
  begin
    case AFlavor of
      ofOpt: B := (AIntf as IOptBoolean).Value;
      ofNull: B := (AIntf as INullBoolean).Value;
    else
      B := (AIntf as IOptNullBoolean).Value;
    end;
    TValue.Make(@B, AValueType, Result);
  end
  else
  begin
    // TGUID goes out as text: the mapper has no rule for the record.
    case AFlavor of
      ofOpt: G := (AIntf as IOptGuid).Value;
      ofNull: G := (AIntf as INullGuid).Value;
    else
      G := (AIntf as IOptNullGuid).Value;
    end;
    S := GUIDToString(G);
    TValue.Make(@S, TypeInfo(string), Result);
  end;
end;

{ TOptionalsJsonConverter }

function TOptionalsJsonConverter.CanConvert(ATypeInfo: PTypeInfo): Boolean;
var
  ValueType: PTypeInfo;
  Flavor: TOptFlavor;
begin
  Result := Describe(ATypeInfo, ValueType, Flavor);
end;

function TOptionalsJsonConverter.ReadJson(AMapper: TJsonMapper; AJson: TJsonValue;
  ATypeInfo: PTypeInfo; const APath: string; out AValue: TValue): Boolean;
var
  ValueType: PTypeInfo;
  Flavor: TOptFlavor;
  Inner: TValue;
  Obj, Intf: IInterface;
begin
  Describe(ATypeInfo, ValueType, Flavor);
  if AJson.IsNull then
  begin
    if Flavor = ofOpt then
      raise EJsonError.Create('null is not allowed here (optional, not nullable)');
    Obj := NewNull(ValueType);
  end
  else if ValueType = TypeInfo(TGUID) then
  begin
    AMapper.ReadValue(AJson, TypeInfo(string), APath, Inner);
    Obj := TOptNullGuid.From(ParseGuid(Inner.AsString));
  end
  else
  begin
    // The mapper's own rules for the value, errors included (it adds APath).
    AMapper.ReadValue(AJson, ValueType, APath, Inner);
    Obj := NewFrom(ValueType, Inner);
  end;
  // TOptNullXxx implements all three flavors; hand back the declared one.
  if not Supports(Obj, GetTypeData(ATypeInfo)^.Guid, Intf) then
    raise EJsonError.Create('optional does not implement ' + JsonTypeName(ATypeInfo));
  TValue.Make(@Intf, ATypeInfo, AValue);
  Result := True;
end;

function TOptionalsJsonConverter.WriteJson(AMapper: TJsonMapper; const AValue: TValue;
  ATypeInfo: PTypeInfo; const APath: string; AWriter: TJsonWriter): Boolean;
var
  ValueType: PTypeInfo;
  Flavor: TOptFlavor;
  Intf: IInterface;
  Opt: IOptionalBase;
  Nul: INullableBase;
  Absent, IsNull: Boolean;
  Value: TValue;
begin
  Describe(ATypeInfo, ValueType, Flavor);
  Intf := nil;
  if not AValue.IsEmpty then
    Intf := AValue.AsInterface;

  // nil means "never set": absent for the Opt flavors, null for INullXxx
  // (the reading TOptionals.Safe gives it). State is read through the base
  // interfaces, so another implementation of one flavor works too.
  Absent := (Intf = nil) or (Supports(Intf, IOptionalBase, Opt) and not Opt.HasValue);
  IsNull := (Intf = nil) or (Supports(Intf, INullableBase, Nul) and Nul.IsNull);

  case Flavor of
    ofNull:
      if IsNull then
      begin
        AWriter.WriteNull;
        Exit(True);
      end;
    // ofOpt too: TOptNullXxx.Null assigned to an IOptXxx compiles, and its
    // Value ('' or 0) would be a made-up value. It goes out as null, even
    // though reading null back into an IOptXxx is an error.
    ofOpt, ofOptNull:
      if Absent then
        Exit(False)
      else if IsNull then
      begin
        AWriter.WriteNull;
        Exit(True);
      end;
  end;
  Value := ValueOf(Intf, Flavor, ValueType);
  Result := AMapper.WriteValue(AWriter, Value, Value.TypeInfo, APath);
end;

initialization
  RegisterOptionalsConverter(TJsonMapper.Shared);

end.
