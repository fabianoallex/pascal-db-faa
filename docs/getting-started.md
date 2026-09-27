# 1. Getting started

Sample: [`02-quickstart`](../samples/02-quickstart/Quickstart.dpr), with the factory built in
[`common/Samples.Env.pas`](../samples/common/Samples.Env.pas).

## The factory

Everything starts from an `IDBFactory`: **one per database**, created once and shared by the
whole program. It owns the connection pool and the SQL loader. You build it from a
configuration and an adapter (the driver):

```pascal
uses
  PascalDb.Interfaces, PascalDb.Adapter.Base,
  PascalDb.Adapter.SQLdb;   // or PascalDb.Adapter.FireDAC / PascalDb.Adapter.Zeos

function NewFactory: IDBFactory;
var
  LConfig: IDatabaseConfig;   // an interface variable, never TDatabaseConfig
begin
  LConfig := TDatabaseConfig.Create;
  LConfig.ConnectionParams.Values['ConnectorType'] := 'PostgreSQL';  // adapter-specific names
  LConfig.ConnectionParams.Values['HostName'] := 'localhost';
  LConfig.ConnectionParams.Values['DatabaseName'] := 'postgres';
  LConfig.ConnectionParams.Values['UserName'] := 'postgres';
  LConfig.ConnectionParams.Values['Password'] := 'postgres';
  LConfig.ConnectionParams.Values['CharSet'] := 'UTF8';

  LConfig.SQLDialect := 'PostgreSQL';   // 'Firebird', 'PostgreSQL' or 'SQLite'
  LConfig.SQLDirectory := 'PG';         // which SQL folder this database reads (guide 2)

  LConfig.PoolIniConnections := 1;      // opened when the factory is created
  LConfig.PoolMaxConnections := 5;
  LConfig.PoolWaitMaxAttemps := 50;     // a caller waits up to 50 x 100 ms
  LConfig.PoolWaitMilliseconds := 100;

  Result := TSQLdbFactory.Create(LConfig);  // TFDFactory / TZeosFactory
end;
```

- **Hold the configuration in an `IDatabaseConfig` variable.** `TDatabaseConfig` is
  reference-counted; with a class variable, handing it to the factory frees it too early.
- **Size the pool for your program.** Without these lines the pool opens 1 connection at
  start, grows to 10, and a caller waits up to 50 × 100 ms for a free one; `PoolMaxConnections`
  below 1 makes the factory raise `EArgumentException`. [Guide 7](pool.md) explains each
  setting.
- **`ConnectionParams` is the only adapter-specific part.** Each adapter has its own names
  (`ConnectorType` / `DriverID` / `Protocol`, ...); [guide 8](adapters.md) lists them. From
  the factory on, the code is the same for every driver and database.
- **Creating the factory never fails because the server is down.** The initial connections
  that can't be opened are retried on the next acquire ([guide 6](errors.md)).
- `SqlSource` is left nil here, which means SQL embedded as resources ([guide 2](sql.md)).

## The usage pattern

Every database operation has the same shape:

```pascal
procedure TCityRepository.InsertAll(const ACities: array of TCity);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  I: Integer;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);   // a pooled connection + a query on it
  LScope.StartTransaction;
  try
    for I := 0 to High(ACities) do
    begin
      LQuery.Sql := FFactory.SqlLoader['CITY.INSERT'].SQL;
      LQuery.Params.Strings['CODE'] := ACities[I].Code;
      LQuery.Params.Strings['NAME'] := ACities[I].Name;
      LQuery.Params.Strings['STATE'] := ACities[I].State;
      LQuery.ExecSql;
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;  // LQuery and LScope are released: the connection goes back to the pool
```

- `AcquireQuery` takes a connection from the pool (opening one or waiting for one if needed)
  and returns the query in its `out` parameter and the **scope transaction** as the result.
- Start, then commit on success or roll back on any exception. Everything between
  `StartTransaction` and `Commit` is one transaction: here, the whole batch or none of it.
- There is no `Release` call. The connection returns to the pool when the interfaces that
  use it (the query and the scope) are released, normally when the method returns.
- A repository only needs the `IDBFactory`: no adapter unit, no driver type. That is what
  lets the same class run against the mock in tests ([guide 5](testing-with-the-mock.md)).

## Reading results

```pascal
LQuery.Sql := FFactory.SqlLoader['CITY.BY_STATE'].SQL;
LQuery.Params.Strings['STATE'] := 'SP';
LResult := LQuery.Open;                  // IQueryResult
SetLength(Cities, LResult.RecordCount);  // exact: every adapter fetches the whole result on Open
while not LResult.Eof do
begin
  Writeln(LResult.Strings['NAME']);      // also Integers, Int64s, Currencies, DateTimes, Booleans
  LResult.Next;
end;
LScope.Commit;                           // read the result BEFORE committing
```

- **Read the result before `Commit`.** On SQLdb, committing closes the datasets attached to the
  transaction, so the pattern is always "read, then commit".
- The plain getters return `''` / `0` / `False` for a NULL. To tell NULL apart, read
  `NullableStrings['EMAIL']` and friends, which return an `INullXxx` ([guide 3](optionals.md)).
- `Open.Integers['TOTAL']` reads a single value directly.

## Nested scopes (savepoints)

A method that already runs inside a transaction can call another that opens its own scope,
by passing the outer transaction to `AcquireQuery`:

```pascal
LOuter := FFactory.GetPool.AcquireQuery(LOuterQuery);
LOuter.StartTransaction;
try
  // ... work in the outer scope ...

  LInner := FFactory.GetPool.AcquireQuery(LInnerQuery, LOuter.OriginalTransaction);
  LInner.StartTransaction;        // same connection and transaction: sets a savepoint
  try
    // ... work in the inner scope ...
    LInner.Commit;                // releases the savepoint (nothing is committed yet)
  except
    LInner.Rollback;              // rolls back to the savepoint; the outer work stays
    raise;
  end;

  LOuter.Commit;                  // the only real commit
except
  LOuter.Rollback;
  raise;
end;
```

Only the outermost scope (`IsMain = True`) commits or rolls back the real transaction; a nested
scope uses the dialect's savepoint statements. This is covered by the contract suite on every
adapter and database (`NestedScope_RollbackToSavepoint_KeepsOuterWork`).

## Next

The SQL above came from `SqlLoader['CITY.INSERT']`: [guide 2](sql.md) explains where that
text lives and how one key can hold a different statement for each database.
