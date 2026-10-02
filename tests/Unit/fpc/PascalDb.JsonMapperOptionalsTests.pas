unit PascalDb.JsonMapperOptionalsTests;

{$mode delphi}{$H+}

{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from
  tests/Unit/PascalDb.JsonMapperOptionalsTests.pas (DUnitX). Do not edit by hand: edit the DUnitX
  master and run the script again. }

{ Tests for the pascal-jsonmapper-faa bridge (PascalDb.JsonMapper.Optionals):
  the 27 optional interfaces read and written through TJsonMapper.Shared, as
  an application would, with three DTOs (one per flavor, the 9 value types
  in each).

  Pinned here, because delphi-api-infra-faa's Common.JsonMapper did
  otherwise: null into an IOptXxx raises EJsonMapperError with the path, and
  a nil INullXxx is written as null (not omitted). Also covered: absent
  members leave nil (TOptionals.Safe then gives Undefined/Null), Undefined
  omitted, Null written, a Null instance held by an IOptXxx written as null,
  every value type's text, GUIDs with or without braces, errors from the
  mapper's own rules carrying the path, arrays of optionals, DecimalPlaces
  staying out of the JSON and a mapper created by hand knowing nothing until
  RegisterOptionalsConverter.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  DateUtils,
  PascalJsonMapper.Mapper,
  PascalDb.Optionals,
  PascalDb.JsonMapper.Optionals;

type
  IOptDto = interface
    ['{5B0D7C61-2E4A-4F8B-9C3D-1A6E8F0B2D47}']
  end;

  INullDto = interface
    ['{8E2F4A93-6C1B-4D7E-A05F-3B9C7D1E6F28}']
  end;

  IOptNullDto = interface
    ['{C3A91E07-4B5D-4F62-8E1A-9D7B2C6F0A35}']
  end;

  TOptNullIntegerArray = array of IOptNullInteger;

{$M+}
  TOptDto = class(TInterfacedObject, IOptDto)
  private
    FText: IOptString;
    FCount: IOptInteger;
    FBig: IOptInt64;
    FRatio: IOptSingle;
    FAmount: IOptDouble;
    FPrice: IOptCurrency;
    FWhen: IOptDateTime;
    FFlag: IOptBoolean;
    FId: IOptGuid;
  published
    property Text: IOptString read FText write FText;
    property Count: IOptInteger read FCount write FCount;
    property Big: IOptInt64 read FBig write FBig;
    property Ratio: IOptSingle read FRatio write FRatio;
    property Amount: IOptDouble read FAmount write FAmount;
    property Price: IOptCurrency read FPrice write FPrice;
    property When: IOptDateTime read FWhen write FWhen;
    property Flag: IOptBoolean read FFlag write FFlag;
    property Id: IOptGuid read FId write FId;
  end;

  TNullDto = class(TInterfacedObject, INullDto)
  private
    FText: INullString;
    FCount: INullInteger;
    FBig: INullInt64;
    FRatio: INullSingle;
    FAmount: INullDouble;
    FPrice: INullCurrency;
    FWhen: INullDateTime;
    FFlag: INullBoolean;
    FId: INullGuid;
  published
    property Text: INullString read FText write FText;
    property Count: INullInteger read FCount write FCount;
    property Big: INullInt64 read FBig write FBig;
    property Ratio: INullSingle read FRatio write FRatio;
    property Amount: INullDouble read FAmount write FAmount;
    property Price: INullCurrency read FPrice write FPrice;
    property When: INullDateTime read FWhen write FWhen;
    property Flag: INullBoolean read FFlag write FFlag;
    property Id: INullGuid read FId write FId;
  end;

  TOptNullDto = class(TInterfacedObject, IOptNullDto)
  private
    FText: IOptNullString;
    FCount: IOptNullInteger;
    FBig: IOptNullInt64;
    FRatio: IOptNullSingle;
    FAmount: IOptNullDouble;
    FPrice: IOptNullCurrency;
    FWhen: IOptNullDateTime;
    FFlag: IOptNullBoolean;
    FId: IOptNullGuid;
    FScores: TOptNullIntegerArray;
  published
    property Text: IOptNullString read FText write FText;
    property Count: IOptNullInteger read FCount write FCount;
    property Big: IOptNullInt64 read FBig write FBig;
    property Ratio: IOptNullSingle read FRatio write FRatio;
    property Amount: IOptNullDouble read FAmount write FAmount;
    property Price: IOptNullCurrency read FPrice write FPrice;
    property When: IOptNullDateTime read FWhen write FWhen;
    property Flag: IOptNullBoolean read FFlag write FFlag;
    property Id: IOptNullGuid read FId write FId;
    property Scores: TOptNullIntegerArray read FScores write FScores;
  end;
{$M-}

  TJsonMapperOptionalsTests = class(TTestCase)
  private
    procedure AssertOptReadFails(const AJson, AExpectedPath: string);
    procedure AssertOptNullReadFails(const AJson, AExpectedPath: string);
    procedure AssertMessageStartsWith(const AMessage, AExpectedPath: string);
  published
    procedure Read_Values_EachFlavor;
    procedure Read_Null_NullableFlavors;
    procedure Read_NullIntoOptional_RaisesWithPath;
    procedure Read_Absent_LeavesNil;
    procedure Read_WrongValue_RaisesWithPath;
    procedure Read_Guid_WithOrWithoutBraces;
    procedure Read_Guid_Invalid_RaisesWithPath;
    procedure Write_NeverSet_NullableIsNull;
    procedure Write_UndefinedOmitted_NullWritten;
    procedure Write_NullHeldByOptional_IsNull;
    procedure Write_Values_EachFlavor;
    procedure Write_DecimalPlaces_NotInJson;
    procedure Array_ReadAndWrite;
    procedure RoundTrip;
    procedure MapperCreatedByHand_NeedsRegister;
  end;

implementation

const
  ValuesJson =
    '{"text":"São Paulo","count":-7,"big":9007199254740993,"ratio":0.5,' +
    '"amount":0.1,"price":12.3456,"when":"2026-10-02T13:45:10.500",' +
    '"flag":true,"id":"{0F8FAD5B-D9CB-469F-A165-70867728950E}"}';
  AllNullJson =
    '{"text":null,"count":null,"big":null,"ratio":null,"amount":null,' +
    '"price":null,"when":null,"flag":null,"id":null}';
  SomeGuid = '{0F8FAD5B-D9CB-469F-A165-70867728950E}';

{ TJsonMapperOptionalsTests }

procedure TJsonMapperOptionalsTests.AssertMessageStartsWith(const AMessage,
  AExpectedPath: string);
begin
  TAssert.AssertTrue('Message "' + AMessage + '" must start with "' +
    AExpectedPath + ':"', Pos(AExpectedPath + ':', AMessage) = 1);
end;

procedure TJsonMapperOptionalsTests.AssertOptReadFails(const AJson,
  AExpectedPath: string);
var
  Dto: IOptDto;
begin
  try
    Dto := TJsonMapper.Shared.FromJson<IOptDto>(AJson);
    TAssert.Fail('Must raise: ' + AJson);
  except
    on E: EJsonMapperError do
      AssertMessageStartsWith(E.Message, AExpectedPath);
  end;
end;

procedure TJsonMapperOptionalsTests.AssertOptNullReadFails(const AJson,
  AExpectedPath: string);
var
  Dto: IOptNullDto;
begin
  try
    Dto := TJsonMapper.Shared.FromJson<IOptNullDto>(AJson);
    TAssert.Fail('Must raise: ' + AJson);
  except
    on E: EJsonMapperError do
      AssertMessageStartsWith(E.Message, AExpectedPath);
  end;
end;

procedure TJsonMapperOptionalsTests.Read_Values_EachFlavor;
var
  Opt: IOptDto;
  Nul: INullDto;
  OptNul: IOptNullDto;
  O: TOptDto;
  N: TNullDto;
  B: TOptNullDto;
begin
  Opt := TJsonMapper.Shared.FromJson<IOptDto>(ValuesJson);
  O := Opt as TOptDto;
  TAssert.AssertTrue(O.Text.HasValue);
  TAssert.AssertEquals('São Paulo', O.Text.Value);
  TAssert.AssertEquals(-7, O.Count.Value);
  TAssert.AssertEquals(Int64(9007199254740993), O.Big.Value);
  TAssert.AssertEquals(0.5, O.Ratio.Value, 0);
  TAssert.AssertEquals(0.1, O.Amount.Value, 0);
  TAssert.AssertTrue(O.Price.Value = 12.3456);
  TAssert.AssertEquals(EncodeDateTime(2026, 10, 2, 13, 45, 10, 500), O.When.Value, 0);
  TAssert.AssertTrue(O.Flag.Value);
  TAssert.AssertEquals(SomeGuid, GUIDToString(O.Id.Value));

  Nul := TJsonMapper.Shared.FromJson<INullDto>(ValuesJson);
  N := Nul as TNullDto;
  TAssert.AssertFalse(N.Text.IsNull);
  TAssert.AssertEquals('São Paulo', N.Text.Value);
  TAssert.AssertEquals(-7, N.Count.Value);
  TAssert.AssertEquals(Int64(9007199254740993), N.Big.Value);
  TAssert.AssertEquals(0.5, N.Ratio.Value, 0);
  TAssert.AssertEquals(0.1, N.Amount.Value, 0);
  TAssert.AssertTrue(N.Price.Value = 12.3456);
  TAssert.AssertEquals(EncodeDateTime(2026, 10, 2, 13, 45, 10, 500), N.When.Value, 0);
  TAssert.AssertTrue(N.Flag.Value);
  TAssert.AssertEquals(SomeGuid, GUIDToString(N.Id.Value));

  OptNul := TJsonMapper.Shared.FromJson<IOptNullDto>(ValuesJson);
  B := OptNul as TOptNullDto;
  TAssert.AssertTrue(B.Text.HasValue and not B.Text.IsNull);
  TAssert.AssertEquals('São Paulo', B.Text.Value);
  TAssert.AssertEquals(-7, B.Count.Value);
  TAssert.AssertEquals(Int64(9007199254740993), B.Big.Value);
  TAssert.AssertEquals(0.5, B.Ratio.Value, 0);
  TAssert.AssertEquals(0.1, B.Amount.Value, 0);
  TAssert.AssertTrue(B.Price.Value = 12.3456);
  TAssert.AssertEquals(EncodeDateTime(2026, 10, 2, 13, 45, 10, 500), B.When.Value, 0);
  TAssert.AssertTrue(B.Flag.Value);
  TAssert.AssertEquals(SomeGuid, GUIDToString(B.Id.Value));
end;

procedure TJsonMapperOptionalsTests.Read_Null_NullableFlavors;
var
  Nul: INullDto;
  OptNul: IOptNullDto;
  N: TNullDto;
  B: TOptNullDto;
begin
  Nul := TJsonMapper.Shared.FromJson<INullDto>(AllNullJson);
  N := Nul as TNullDto;
  TAssert.AssertTrue(N.Text.IsNull);
  TAssert.AssertTrue(N.Count.IsNull);
  TAssert.AssertTrue(N.Big.IsNull);
  TAssert.AssertTrue(N.Ratio.IsNull);
  TAssert.AssertTrue(N.Amount.IsNull);
  TAssert.AssertTrue(N.Price.IsNull);
  TAssert.AssertTrue(N.When.IsNull);
  TAssert.AssertTrue(N.Flag.IsNull);
  TAssert.AssertTrue(N.Id.IsNull);

  // Null is a value that was provided: HasValue and IsNull.
  OptNul := TJsonMapper.Shared.FromJson<IOptNullDto>(AllNullJson);
  B := OptNul as TOptNullDto;
  TAssert.AssertTrue(B.Text.HasValue and B.Text.IsNull);
  TAssert.AssertTrue(B.Count.HasValue and B.Count.IsNull);
  TAssert.AssertTrue(B.Big.HasValue and B.Big.IsNull);
  TAssert.AssertTrue(B.Ratio.HasValue and B.Ratio.IsNull);
  TAssert.AssertTrue(B.Amount.HasValue and B.Amount.IsNull);
  TAssert.AssertTrue(B.Price.HasValue and B.Price.IsNull);
  TAssert.AssertTrue(B.When.HasValue and B.When.IsNull);
  TAssert.AssertTrue(B.Flag.HasValue and B.Flag.IsNull);
  TAssert.AssertTrue(B.Id.HasValue and B.Id.IsNull);
end;

procedure TJsonMapperOptionalsTests.Read_NullIntoOptional_RaisesWithPath;
begin
  // Decision: an IOptXxx ("may be absent, never null") rejects null.
  // Common.JsonMapper stored a Null instead.
  AssertOptReadFails('{"text":null}', '$.text');
  AssertOptReadFails('{"count":null}', '$.count');
  AssertOptReadFails('{"big":null}', '$.big');
  AssertOptReadFails('{"ratio":null}', '$.ratio');
  AssertOptReadFails('{"amount":null}', '$.amount');
  AssertOptReadFails('{"price":null}', '$.price');
  AssertOptReadFails('{"when":null}', '$.when');
  AssertOptReadFails('{"flag":null}', '$.flag');
  AssertOptReadFails('{"id":null}', '$.id');
end;

procedure TJsonMapperOptionalsTests.Read_Absent_LeavesNil;
var
  Opt: IOptDto;
  Nul: INullDto;
  O: TOptDto;
  N: TNullDto;
begin
  // Absent members never reach the converter: the DTO's nil stands, and
  // TOptionals.Safe reads it as Undefined (IOptXxx) or Null (INullXxx).
  Opt := TJsonMapper.Shared.FromJson<IOptDto>('{}');
  O := Opt as TOptDto;
  TAssert.AssertTrue(O.Text = nil);
  TAssert.AssertTrue(O.Id = nil);
  TAssert.AssertFalse(TOptionals.Safe(O.Count).HasValue);

  Nul := TJsonMapper.Shared.FromJson<INullDto>('{}');
  N := Nul as TNullDto;
  TAssert.AssertTrue(N.Text = nil);
  TAssert.AssertTrue(TOptionals.Safe(N.Count).IsNull);
end;

procedure TJsonMapperOptionalsTests.Read_WrongValue_RaisesWithPath;
begin
  // The mapper's own rules, reached through the converter.
  AssertOptNullReadFails('{"text":5}', '$.text');
  AssertOptNullReadFails('{"count":"x"}', '$.count');
  AssertOptNullReadFails('{"count":2147483648}', '$.count');
  AssertOptNullReadFails('{"big":1.5}', '$.big');
  AssertOptNullReadFails('{"amount":"x"}', '$.amount');
  AssertOptNullReadFails('{"when":"yesterday"}', '$.when');
  AssertOptNullReadFails('{"flag":1}', '$.flag');
  AssertOptNullReadFails('{"id":7}', '$.id');
end;

procedure TJsonMapperOptionalsTests.Read_Guid_WithOrWithoutBraces;
var
  Dto: IOptNullDto;
begin
  Dto := TJsonMapper.Shared.FromJson<IOptNullDto>('{"id":"' + SomeGuid + '"}');
  TAssert.AssertEquals(SomeGuid, GUIDToString((Dto as TOptNullDto).Id.Value));
  Dto := TJsonMapper.Shared.FromJson<IOptNullDto>(
    '{"id":"0f8fad5b-d9cb-469f-a165-70867728950e"}');
  TAssert.AssertEquals(SomeGuid, GUIDToString((Dto as TOptNullDto).Id.Value));
end;

procedure TJsonMapperOptionalsTests.Read_Guid_Invalid_RaisesWithPath;
begin
  AssertOptNullReadFails('{"id":"not-a-guid"}', '$.id');
  AssertOptNullReadFails('{"id":"0f8fad5b-d9cb-469f-a165-70867728950z"}', '$.id');
  AssertOptNullReadFails('{"id":""}', '$.id');
end;

procedure TJsonMapperOptionalsTests.Write_NeverSet_NullableIsNull;
var
  Opt: IOptDto;
  Nul: INullDto;
  OptNul: IOptNullDto;
begin
  // Decision: a nil INullXxx is written as null, the reading
  // TOptionals.Safe gives it. Common.JsonMapper omitted it.
  Nul := TNullDto.Create;
  TAssert.AssertEquals(AllNullJson, TJsonMapper.Shared.ToJson<INullDto>(Nul));
  // The flavors that can be absent are omitted.
  Opt := TOptDto.Create;
  TAssert.AssertEquals('{}', TJsonMapper.Shared.ToJson<IOptDto>(Opt));
  OptNul := TOptNullDto.Create;
  TAssert.AssertEquals('{"scores":[]}', TJsonMapper.Shared.ToJson<IOptNullDto>(OptNul));
end;

procedure TJsonMapperOptionalsTests.Write_UndefinedOmitted_NullWritten;
var
  D: TOptNullDto;
  Dto: IOptNullDto;
  O: TOptDto;
  Opt: IOptDto;
begin
  D := TOptNullDto.Create;
  Dto := D;
  D.Text := TOptNullString.Undefined;
  D.Count := TOptNullInteger.Null;
  D.Big := TOptNullInt64.Undefined;
  D.Ratio := TOptNullSingle.Null;
  D.Amount := TOptNullDouble.Undefined;
  D.Price := TOptNullCurrency.Null;
  D.When := TOptNullDateTime.Undefined;
  D.Flag := TOptNullBoolean.Null;
  D.Id := TOptNullGuid.Undefined;
  TAssert.AssertEquals('{"count":null,"ratio":null,"price":null,"flag":null,"scores":[]}',
    TJsonMapper.Shared.ToJson<IOptNullDto>(Dto));

  O := TOptDto.Create;
  Opt := O;
  O.Text := TOptNullString.Undefined;
  O.Id := TOptNullGuid.Undefined;
  TAssert.AssertEquals('{}', TJsonMapper.Shared.ToJson<IOptDto>(Opt));
end;

procedure TJsonMapperOptionalsTests.Write_NullHeldByOptional_IsNull;
var
  O: TOptDto;
  Opt: IOptDto;
begin
  // TOptNullXxx.Null assigned to an IOptXxx compiles; its Value ('' / 0)
  // would be made up, so null goes out.
  O := TOptDto.Create;
  Opt := O;
  O.Text := TOptNullString.Null;
  O.Count := TOptNullInteger.Null;
  TAssert.AssertEquals('{"text":null,"count":null}',
    TJsonMapper.Shared.ToJson<IOptDto>(Opt));
end;

procedure TJsonMapperOptionalsTests.Write_Values_EachFlavor;
var
  O: TOptDto;
  N: TNullDto;
  B: TOptNullDto;
  Opt: IOptDto;
  Nul: INullDto;
  OptNul: IOptNullDto;
  Expected: string;
begin
  O := TOptDto.Create;
  Opt := O;
  O.Text := TOptNullString.From('São Paulo');
  O.Count := TOptNullInteger.From(-7);
  O.Big := TOptNullInt64.From(9007199254740993);
  O.Ratio := TOptNullSingle.From(0.5);
  O.Amount := TOptNullDouble.From(0.1);
  O.Price := TOptNullCurrency.From(12.3456);
  O.When := TOptNullDateTime.From(EncodeDateTime(2026, 10, 2, 13, 45, 10, 500));
  O.Flag := TOptNullBoolean.TrueValue;
  O.Id := TOptNullGuid.From(StringToGUID(SomeGuid));
  TAssert.AssertEquals(ValuesJson, TJsonMapper.Shared.ToJson<IOptDto>(Opt));

  N := TNullDto.Create;
  Nul := N;
  N.Text := TOptNullString.From('São Paulo');
  N.Count := TOptNullInteger.From(-7);
  N.Big := TOptNullInt64.From(9007199254740993);
  N.Ratio := TOptNullSingle.From(0.5);
  N.Amount := TOptNullDouble.From(0.1);
  N.Price := TOptNullCurrency.From(12.3456);
  N.When := TOptNullDateTime.From(EncodeDateTime(2026, 10, 2, 13, 45, 10, 500));
  N.Flag := TOptNullBoolean.TrueValue;
  N.Id := TOptNullGuid.From(StringToGUID(SomeGuid));
  TAssert.AssertEquals(ValuesJson, TJsonMapper.Shared.ToJson<INullDto>(Nul));

  B := TOptNullDto.Create;
  OptNul := B;
  B.Text := TOptNullString.From('');
  B.Count := TOptNullInteger.From(0);
  B.Big := TOptNullInt64.From(-1);
  B.Ratio := TOptNullSingle.From(-0.25);
  B.Amount := TOptNullDouble.From(1e300);
  B.Price := TOptNullCurrency.From(-0.0001);
  B.When := TOptNullDateTime.From(EncodeDateTime(2000, 1, 1, 0, 0, 0, 0));
  B.Flag := TOptNullBoolean.From(False);
  B.Id := TOptNullGuid.From(StringToGUID('{00000000-0000-0000-0000-000000000000}'));
  Expected := '{"text":"","count":0,"big":-1,"ratio":-0.25,"amount":1E300,' +
    '"price":-0.0001,"when":"2000-01-01T00:00:00","flag":false,' +
    '"id":"{00000000-0000-0000-0000-000000000000}","scores":[]}';
  TAssert.AssertEquals(Expected, TJsonMapper.Shared.ToJson<IOptNullDto>(OptNul));
end;

procedure TJsonMapperOptionalsTests.Write_DecimalPlaces_NotInJson;
var
  B: TOptNullDto;
  Dto: IOptNullDto;
begin
  // DecimalPlaces is a database hint: the JSON carries the exact value.
  B := TOptNullDto.Create;
  Dto := B;
  B.Amount := TOptNullDouble.From(1.23456, 2);
  B.Ratio := TOptNullSingle.From(0.75, 1);
  TAssert.AssertEquals('{"ratio":0.75,"amount":1.23456,"scores":[]}',
    TJsonMapper.Shared.ToJson<IOptNullDto>(Dto));
  Dto := TJsonMapper.Shared.FromJson<IOptNullDto>('{"amount":1.23456}');
  TAssert.AssertEquals(-1, (Dto as TOptNullDto).Amount.DecimalPlaces);
end;

procedure TJsonMapperOptionalsTests.Array_ReadAndWrite;
var
  B: TOptNullDto;
  Dto: IOptNullDto;
  Scores: TOptNullIntegerArray;
begin
  Dto := TJsonMapper.Shared.FromJson<IOptNullDto>('{"scores":[1,null,3]}');
  B := Dto as TOptNullDto;
  TAssert.AssertEquals(3, Integer(Length(B.Scores)));
  TAssert.AssertEquals(1, B.Scores[0].Value);
  TAssert.AssertTrue(B.Scores[1].HasValue and B.Scores[1].IsNull);
  TAssert.AssertEquals(3, B.Scores[2].Value);

  // An element the converter omits (Undefined, nil) becomes null.
  B := TOptNullDto.Create;
  Dto := B;
  SetLength(Scores, 4);
  Scores[0] := TOptNullInteger.From(1);
  Scores[1] := TOptNullInteger.Null;
  Scores[2] := TOptNullInteger.Undefined;
  Scores[3] := nil;
  B.Scores := Scores;
  TAssert.AssertEquals('{"scores":[1,null,null,null]}',
    TJsonMapper.Shared.ToJson<IOptNullDto>(Dto));
end;

procedure TJsonMapperOptionalsTests.RoundTrip;
const
  Json = '{"text":"A\"b\\c","count":2147483647,"big":-9223372036854775808,' +
    '"ratio":3.4028235E38,"amount":0.30000000000000004,' +
    '"price":922337203685477.5807,"when":"1999-12-31T23:59:59.999",' +
    '"flag":false,"scores":[null,0]}';
var
  Dto: IOptNullDto;
begin
  Dto := TJsonMapper.Shared.FromJson<IOptNullDto>(Json);
  TAssert.AssertEquals(Json, TJsonMapper.Shared.ToJson<IOptNullDto>(Dto));
  Dto := TJsonMapper.Shared.FromJson<IOptNullDto>(AllNullJson);
  TAssert.AssertEquals(Copy(AllNullJson, 1, Length(AllNullJson) - 1) + ',"scores":[]}',
    TJsonMapper.Shared.ToJson<IOptNullDto>(Dto));
end;

procedure TJsonMapperOptionalsTests.MapperCreatedByHand_NeedsRegister;
var
  M: TJsonMapper;
  Dto: IOptDto;
begin
  M := TJsonMapper.Create;
  try
    M.RegisterMapping<IOptDto, TOptDto>;
    try
      Dto := M.FromJson<IOptDto>('{"count":1}');
      TAssert.Fail('Without the converter an optional is an unmapped interface');
    except
      on E: EJsonMapperError do
        TAssert.AssertTrue(E.Message, Pos('IOptInteger', E.Message) > 0);
    end;
    RegisterOptionalsConverter(M);
    Dto := M.FromJson<IOptDto>('{"count":1}');
    TAssert.AssertEquals(1, (Dto as TOptDto).Count.Value);
  finally
    Dto := nil;
    M.Free;
  end;
end;

initialization
  // The DTO-unit convention: register on the shared mapper at startup.
  TJsonMapper.Shared.RegisterMapping<IOptDto, TOptDto>;
  TJsonMapper.Shared.RegisterMapping<INullDto, TNullDto>;
  TJsonMapper.Shared.RegisterMapping<IOptNullDto, TOptNullDto>;
  RegisterTest(TJsonMapperOptionalsTests);

end.
