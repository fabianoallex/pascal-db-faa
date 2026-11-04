# 12. Caching query results

pascal-db-faa doesn't cache by itself: the cache is pascal-common-faa's `PascalCommon.Cache`
(1.29.0 or later), and it sits in the application's **service**, in front of the repository. A hit
takes nothing from the pool and runs nothing on the database; a miss runs the repository as
usual. What this library adds is the one thing a cache needs from the database layer:
**invalidating after the commit**, with `PdbInvalidateAfterCommit` (`PascalDb.Cache`).

The cache's own design (tags by generations, single-flight, a store that is down being a miss,
the Redis store in pascal-redis-faa) is pascal-common-faa's `docs/cache-design.md`; why the cache
isn't on `IQuery` is its table "Where this came from" and decision C11.

## The cache

```pascal
uses PascalCommon.Cache;

// Composition root: one cache for the process (memory) or shared by every instance (Redis).
if Config.UseRedis then
  LStore := TRedisCacheStore.Create(RedisPool)      // pascal-redis-faa
else
  LStore := TPcMemoryCacheStore.Create(10000);       // at most 10000 entries
FCache := TPcCache.Create(LStore, 'app');             // 'app' prefixes the keys and labels the metrics
```

What goes in is a string, in practice the service's DTO as JSON (pascal-jsonmapper-faa): the
mapping is saved on a hit too, and a typed value (`Currency`, dates, NULLs) survives, which a raw
`Variant` row wouldn't.

## Reading through the cache

```pascal
function TCityService.ByState(const AState: string): TCityList;
var
  LKey, LJson: string;
begin
  LKey := FCache.Key('city.by_state:' + AState, ['cities', 'cities.state:' + AState]);
  if FCache.TryGet(LKey, LJson) then
    Exit(CitiesFromJson(LJson));                 // hit: no pool, no database
  Result := FRepository.ByState(AState);         // miss: the usual query, in a scope of its own
  FCache.Put(LKey, CitiesToJson(Result), 300);   // 5 minutes
end;
```

- **Read for the cache in a scope of its own** (`AcquireQuery` with no transaction), never inside
  a transaction that also wrote: that transaction may still roll back, and its uncommitted rows
  would be cached (the cache's C7, rule 2).
- **The key is yours**, built from what the query depends on. No secrets in it (keys show in
  Redis' `MONITOR` and `SCAN`); hash anything sensitive first.
- **Tags** say what a change must drop: one for everything (`cities`), one per item, one per
  aggregate that a change to any item drops (pascal-common-faa's "Usage").
- **`GetOrLoad`** does the same in one call, and when many requests miss the same key at once only
  one runs the query: the others wait for its result. That protects the pool too: N concurrent
  misses take one connection, not N.

```pascal
function TCityService.LoadByState(const AState: string): string;   // a method: works on FPC too
begin
  Result := CitiesToJson(FRepository.ByState(AState));
end;

LJson := FCache.GetOrLoad(LKey, 300, LoadByState, AState);
```

## Invalidating after the commit

A change invalidates the tags of what it changed, **after the commit** (the cache's C7, rule 1).
Before it, a concurrent reader can load the old row and put it back. And a repository that commits
its own scope can't tell whether that commit is the real one: inside the caller's transaction it
only releases a savepoint. `PdbInvalidateAfterCommit` waits for the real commit:

```pascal
uses PascalDb.Cache;

procedure TCityRepository.Rename(AId: Integer; const AState, AName: string;
  ATransaction: ITransaction);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery, ATransaction);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.RENAME'].SQL;
    LQuery.Params.Integers['ID'] := AId;
    LQuery.Params.Strings['NAME'] := AName;
    LQuery.ExecSql;
    PdbInvalidateAfterCommit(LScope, FCache, ['city:' + IntToStr(AId), 'cities.state:' + AState]);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;
```

- It runs after the real commit, whichever scope is the main one; a rollback (or the rollback of
  the scope it was added in) drops it. It is `PdbAfterCommit` ([guide 1](getting-started.md#after-the-commit))
  with the invalidation already written.
- A `nil` cache does nothing: a repository that runs with the cache turned off needs no `if`.
- `IPcCache.Invalidate` never raises for a store that is down: the failure goes to the cache's
  `OnError` and metrics, and **the TTL bounds how long the old value is read**. Data that can't be
  stale for a TTL shouldn't be cached.
- Between the commit and the invalidation, readers may still get the old value for an instant;
  also bounded by the TTL.

## Testing

With the mock (`TMockDBFactory`, [guide 5](testing-with-the-mock.md)) and a
`TPcMemoryCacheStore`, a service's test can check the whole cycle: the second read doesn't run the
query (`ExecutionCount`), a change followed by `Commit` makes the next read run it again, and a
change rolled back doesn't. The mock's scopes run the after-commit actions on `Commit` and drop
them on `Rollback`.

## Sample

`samples/08-cache`: a cached read, a hit, a change in a nested scope invalidating after the real
commit, on every database the samples run on.
