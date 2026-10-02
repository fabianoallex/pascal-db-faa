# 3. Optional and nullable values

Sample: [`04-optionals`](../samples/04-optionals/Optionals.dpr).

## Three questions, three interfaces

A plain `string` or `Integer` can't say "NULL" or "not given". Unit `PascalDb.Optionals`
adds three interface families for that:

| Interface | Answers | Typical use |
|---|---|---|
| `INullXxx` | "is it NULL?" (`IsNull`) | a nullable column or parameter |
| `IOptXxx` | "was it given?" (`HasValue`) | an optional search filter |
| `IOptNullXxx` | both | a field in a partial update: **Undefined** = leave the column alone, **Null** = set it to NULL, **From(X)** = set it to X |

`Xxx` is `String`, `Integer`, `Int64`, `Double`, `Currency`, `DateTime`, `Boolean` (also
`Single` and `Guid`, which parameters and results don't expose). One class per type,
`TOptNullXxx`, implements all three, and builds the values:

```pascal
LEmail := TOptNullString.From('ana@example.com');   // a value
LEmail := TOptNullString.Null;                      // NULL
LEmail := TOptNullString.Undefined;                 // not given
```

Values are immutable and shared (`Null` and `Undefined` are singletons, `From` reuses cached
instances), so they are safe to pass between threads.

### nil

An interface field in a record or class starts as `nil`, which is none of the three states.
`TOptionals.Safe(X)` turns `nil` into Undefined (`IOptXxx`, `IOptNullXxx`) or Null
(`INullXxx`) and returns anything else unchanged. The parameter setters read `nil` the same
way (a `nil` `IOptXxx`/`IOptNullXxx` leaves the parameter untouched, a `nil` `INullXxx` writes
NULL), on every adapter and on the mock, so a field can go to a parameter as it is; use `Safe`
where your own code calls `HasValue`, `IsNull` or `Value` on it.

```pascal
type
  TCustomerFilter = record
    Name: IOptString;
    City: IOptString;
  end;

var
  LFilter: TCustomerFilter;
begin
  LFilter := Default(TCustomerFilter);          // both fields nil
  LFilter.City := TOptNullString.From('Campinas');
  LName := TOptionals.Safe(LFilter.Name);       // Undefined
  LCity := TOptionals.Safe(LFilter.City);       // 'Campinas'
```

## As parameters

```pascal
LQuery.Params.NullStrings['EMAIL'] := LEmail;       // always bound: NULL or the value
LQuery.Params.OptStrings['CITY'] := LCity;          // bound only when HasValue
LQuery.Params.OptNullStrings['PHONE'] := LPhone;    // Undefined: not bound; Null: NULL; else the value
```

So a parameter that may not be bound must not be in the SQL when it isn't: the template
tags take it out.

## Optional filters

The SQL has one block per optional condition ([guide 2](sql.md#templates)):

```sql
SELECT ID, NAME, CITY, EMAIL FROM SAMPLE_CUSTOMERS WHERE 1 = 1
  [NAME {] AND NAME ${NAME_OP} :NAME [} NAME]
  [CITY {] AND CITY = :CITY [} CITY]
ORDER BY ID
```

The code keeps a block exactly when its value was given, then binds the same values:

```pascal
if LName.HasValue and (Pos('%', LName.Value) > 0) then
  LOperator := 'LIKE'
else
  LOperator := '=';
LSql := FFactory.SqlLoader['CUSTOMER.FIND']
  .ApplyFilter('NAME', LOperator, LName.HasValue)
  .ProcessTag('CITY', LCity.HasValue);

LQuery.Sql := LSql.SQL;
LQuery.Params.OptStrings['NAME'] := LName;   // bound only when its block was kept
LQuery.Params.OptStrings['CITY'] := LCity;
```

With no filter the SQL is `... WHERE 1 = 1 ORDER BY ID`; with a city only, `... WHERE 1 = 1
AND CITY = :CITY ORDER BY ID`.

## Partial updates

The same idea with `IOptNullXxx`: only the fields the caller defined go into the `UPDATE`,
and Null is a value like any other.

```sql
UPDATE SAMPLE_CUSTOMERS SET ID = ID
  [NAME {], NAME = :NAME [} NAME]
  [EMAIL {], EMAIL = :EMAIL [} EMAIL]
  [PHONE {], PHONE = :PHONE [} PHONE]
WHERE ID = :ID
```

```pascal
LSql := FFactory.SqlLoader['CUSTOMER.UPDATE']
  .ProcessTag('NAME', LName.HasValue)
  .ProcessTag('EMAIL', LEmail.HasValue)
  .ProcessTag('PHONE', LPhone.HasValue);
LQuery.Sql := LSql.SQL;
LQuery.Params.Integers['ID'] := AId;
LQuery.Params.OptStrings['NAME'] := LName;
LQuery.Params.OptNullStrings['EMAIL'] := LEmail;   // Null here writes NULL
LQuery.Params.OptNullStrings['PHONE'] := LPhone;
```

A patch with Email = `From('ana@example.com')` and Name and Phone Undefined keeps only the
`EMAIL = :EMAIL` block: the name and the phone aren't touched. When no
field is defined, skip the `UPDATE` altogether (the sample does).

## Reading nullable columns

```pascal
LEmail := LResult.NullableStrings['EMAIL'];   // INullString
if LEmail.IsNull then ...
```

`NullableStrings`, `NullableIntegers`, `NullableInt64`, `NullableCurrencies`,
`NullableDateTimes` and `NullableBooleans` exist on `IQueryResult`. The plain getters
(`Strings[...]`, ...) read a NULL as `''` / `0` / `False`.

## Optionals in JSON DTOs

With [pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa), a DTO can
declare optional properties and read and write them as JSON. The converter lives in a unit of
its own, `PascalDb.JsonMapper.Optionals` (`bridges/jsonmapper`, Lazarus package
`pascal_db_faa_jsonmapper.lpk`), so the core doesn't depend on the mapper. The mapper is a
git submodule in `external/pascal-jsonmapper-faa` (`git submodule update --init`); on Delphi,
add `external/pascal-jsonmapper-faa/src` and `bridges/jsonmapper` to the search path.

Using the unit is all it takes: its initialization registers the converter on
`TJsonMapper.Shared`. A mapper created by hand gets it from `RegisterOptionalsConverter(M)`.

```pascal
uses PascalJsonMapper.Mapper, PascalDb.Optionals, PascalDb.JsonMapper.Optionals;

{$M+}
TCustomerPatch = class(TInterfacedObject, ICustomerPatch)
published
  property Name: IOptString read FName write FName;          // may be absent, never null
  property Email: IOptNullString read FEmail write FEmail;   // absent, null or a value
  property Phone: INullString read FPhone write FPhone;      // always there, maybe null
end;
{$M-}

LPatch := TJsonMapper.Shared.FromJson<ICustomerPatch>('{"email":null}');
// Name = nil (TOptionals.Safe: Undefined), Email = Null, Phone = nil (Safe: Null)
```

| | reading `null` | writing `nil` / Undefined | writing Null |
|---|---|---|---|
| `IOptXxx` | **error** (`EJsonMapperError`, `$.name: ...`) | member omitted | `null` |
| `INullXxx` | Null | **`null`** | `null` |
| `IOptNullXxx` | Null | member omitted | `null` |

An absent member leaves the property untouched (`nil` in a fresh DTO), so `TOptionals.Safe`
gives Undefined or Null. All 9 value types work; the value follows the mapper's own rules
(range checks, exact float text, ISO 8601 dates, the JSON path in errors). A GUID is written
with braces (`GUIDToString`) and read with or without them. `DecimalPlaces` of a Single/Double
stays out of the JSON.

Two of these rules differ from `delphi-api-infra-faa`'s `Common.JsonMapper`, on purpose:
it stored `null` into an `IOptXxx` as Null (a state the type can't express), and it omitted a
`nil` `INullXxx` (which `TOptionals.Safe` reads as Null, so `null` is what goes out now). An
`IOptXxx` holding Null (`TOptNullXxx.Null` assigned to it compiles) is written as `null`,
not as its `''`/`0`.

## Next

[Guide 4](migrations.md): creating and evolving the tables these queries run against.
