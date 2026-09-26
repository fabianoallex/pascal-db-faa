# 5. Testing with the mock

Sample: [`01-mock-repository`](../samples/01-mock-repository/MockRepository.dpr), which tests
[`common/Samples.CityRepository.pas`](../samples/common/Samples.CityRepository.pas), the same
repository that [sample 02](../samples/02-quickstart/Quickstart.dpr) runs on a real database.

## What it is

`TMockDBFactory` (unit `PascalDb.Mock`) is an in-memory `IDBFactory`. Code that only depends
on `IDBFactory`, as a repository written with the pattern from [guide 1](getting-started.md)
does, runs against it unchanged:

- it **returns canned results** by SQL key (`AddResult`);
- it **records every execution** with a snapshot of its parameters (`LastExecution`,
  `ExecutionCount`).

That is enough to test the repository's own logic: validation before any SQL runs, the
parameters it binds, how it maps rows to records. It needs no database, no adapter and no
test framework.

With the mock, the "SQL" a query receives is the key itself: `SqlLoader['CITY.INSERT'].SQL`
returns `'CITY.INSERT'`, which is what results and executions are matched against.

## Lifetime: hold it in an interface variable

`TMockDBFactory` is reference-counted, and a repository keeps the factory it receives as an
`IDBFactory`. **Keep your own `IDBFactory` reference to the mock, and never call `Free`:**

```pascal
var
  LMock: TMockDBFactory;     // to call the mock's own methods
  LFactory: IDBFactory;      // keeps it alive
  LRepo: TCityRepository;
begin
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  LRepo := TCityRepository.Create(LFactory);
  try
    // ...
  finally
    LRepo.Free;
  end;
end;  // LFactory goes out of scope: the mock is freed here
```

With only the class variable, releasing the repository drops the last reference and frees the
mock: the next `LastExecution` reads freed memory, and a final `Free` frees it a second time.

## Checking what was executed

```pascal
LRepo.Insert(City(' 3550308 ', 'São Paulo', 'sp'));

LExec := LMock.LastExecution('CITY.INSERT');   // nil if the key never ran
Check(not LExec.WasOpen, 'ran through ExecSql');
Check(LExec.AsString('CODE') = '3550308', 'CODE is trimmed');
Check(LExec.AsString('STATE') = 'SP', 'STATE is upper-cased');
```

`TMockExecution` has `AsString`, `AsInteger`, `AsInt64`, `AsBoolean`, `AsCurrency`,
`AsDateTime`, `HasParam` (was the parameter bound at all?) and `IsNull`. `HasParam` is how a
test checks that an optional parameter was left out ([guide 3](optionals.md)).

`ExecutionCount(Key)` counts executions, so a test can also check that something did **not**
run:

```pascal
// An invalid city in the batch: the repository must reject it before any INSERT.
try
  LRepo.InsertAll([City('3304557', 'Rio de Janeiro', 'RJ'), City('0000000', 'Nowhere', 'XYZ')]);
except
  on ECityValidation do LRaised := True;
end;
Check(LMock.ExecutionCount('CITY.INSERT') = 0, 'not even the valid one was inserted');
```

## Canned results

Every key the code `Open`s needs a registered result (`Open` raises otherwise); `ExecSql`
needs none.

```pascal
LMock.AddResult('CITY.BY_STATE', TMockQueryResult.MultiRows(
  ['CODE', 'NAME', 'STATE'],
  [TArray<Variant>.Create('3509502', 'Campinas', 'SP'),
   TArray<Variant>.Create('3550308', 'São Paulo', 'SP')]));

LMock.AddResult('CITY.COUNT', TMockQueryResult.SingleRow(['TOTAL'], [2]));
LMock.AddResult('CITY.NONE', TMockQueryResult.Empty);
```

The result supports the same getters as a real one, `Nullable...` included (a `Null` variant
reads as NULL).

## What the mock doesn't do

- It runs no SQL: template tags, parameter names that don't exist in the statement and SQL
  errors all go unnoticed. The integration tests on a real database cover those.
- Transactions only pretend: nothing is rolled back.
- `CreateSqlScript` isn't supported (it raises), so code that runs migrations isn't testable
  with it.

## FPC note

On Unix, a non-ASCII literal inside `TArray<Variant>.Create(...)` needs `cwstring` in the
program's `uses`, or it comes back as invalid UTF-8 ([guide 8](adapters.md#what-a-free-pascal-program-must-do)).
