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
(`INullXxx`) and returns anything else unchanged. **Pass values through `Safe` before handing
them to parameters**: the parameter setters don't check for `nil`.

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

## Next

[Guide 4](migrations.md): creating and evolving the tables these queries run against.
