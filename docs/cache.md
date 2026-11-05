# 12. Caching query results

pascal-db-faa doesn't cache by itself: the cache is pascal-common-faa's `PascalCommon.Cache`
(1.29.0 or later), placed wherever the application's architecture puts it. The examples below put
it in the **service**, in front of the repository; [Caching in the repository](#caching-in-the-repository)
covers keeping it behind the repository's interface instead. Either way, a hit takes nothing from
the pool and runs nothing on the database; a miss runs the query as usual. What this library adds is the one thing a cache needs from the database layer:
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

## Caching in the repository

The library doesn't care which layer holds the cache. An application that wants the service free of
storage details can keep the cache inside the repository, or in a decorator around it. The rules
are the same as in the service, but two of them are easier to break there:

- **Check the cache before `AcquireQuery`**, or a hit still takes a connection from the pool.
- **Skip the cache when the caller passes a transaction.** In the service, a cached read runs in a
  scope of its own by construction; a repository method usually receives the caller's
  `ATransaction`. When it isn't `nil`, neither read from the cache nor put into it: a `Put` could
  cache rows that transaction hasn't committed (and may roll back), and a hit would return the
  committed state without the changes that same transaction just made.

```pascal
function TCityRepository.ByState(const AState: string;
  ATransaction: ITransaction): TCityList;
var
  LKey: string;
begin
  if (FCache = nil) or (ATransaction <> nil) then
    Exit(QueryByState(AState, ATransaction));    // no cache: the usual query

  LKey := FCache.Key('city.by_state:' + AState, ['cities', 'cities.state:' + AState]);
  Result := CitiesFromJson(FCache.GetOrLoad(LKey, 300, LoadByStateJson, AState));
end;
```

The repository then also maps its results to and from the cached string (JSON). To keep the SQL
repository free of that, a **decorator** does the same job: a `TCachedCityRepository` implementing
the same `ICityRepository` and wrapping the concrete one. Its reads go through the cache (passing
straight through when `ATransaction <> nil`), its writes are passed on, and the invalidation stays
in the concrete repository's scope, as in the next section. Turning the cache on or off is then a
choice of the composition root: inject the decorator or the concrete repository.

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

## Before caching a query

A cache trades freshness for speed, and most of its failures are silent: nothing raises, the
application just serves an old value. The ones above, in one place, plus those the code can't see:

| Side effect | Why | Work-around |
|---|---|---|
| An old value for an instant after a change | the invalidation runs after the commit, not with it | bounded by the TTL; don't cache what can't be stale for that long |
| An old value for a whole TTL | the store was down when the invalidation ran (`Invalidate` doesn't raise) | watch `OnError` and the cache metrics; keep the TTL as short as the data allows |
| Rows that never existed | a read cached inside a transaction that later rolled back | read for the cache in a scope of its own; in a repository, skip the cache when `ATransaction <> nil` |
| An old value put back right after a change | invalidating before the commit: a concurrent reader reloads the old row | `PdbInvalidateAfterCommit`, never `Invalidate` inside the transaction |
| Changes made outside the application never show up | SQL run by hand, another system, a trigger or a database job: nothing invalidates | only the TTL helps; don't cache tables others write to, or give them a short TTL |
| Each instance sees its own data | `TPcMemoryCacheStore` is per process: a write invalidates only the instance that made it | one shared store (Redis) when more than one instance runs |
| A change doesn't drop an entry, with no error | the write forgot a tag that the read used | build the tags in one place (a function per entity), used by both the read and the write |
| A user gets another user's data | the result depends on the user or their permissions, and that isn't in the key | put what the query depends on in the key (user, tenant, role), hashed if sensitive; or don't cache it |
| A new version reads a value it can't parse | the DTO changed, and a shared store still holds JSON written by the previous version | a format version in the key (`'v2:city.by_state:'`), changed with the DTO; the old entries expire by TTL |
| The pool still sees every request | the cache is checked after `AcquireQuery` | check it first: a hit must take no connection |

When in doubt, measure first: cache the queries that are both frequent and slow, read far more than
they're written and written only by this application.

## Testing

With the mock (`TMockDBFactory`, [guide 5](testing-with-the-mock.md)) and a
`TPcMemoryCacheStore`, a service's test can check the whole cycle: the second read doesn't run the
query (`ExecutionCount`), a change followed by `Commit` makes the next read run it again, and a
change rolled back doesn't. The mock's scopes run the after-commit actions on `Commit` and drop
them on `Rollback`.

## Sample

`samples/08-cache`: a cached read, a hit, a change in a nested scope invalidating after the real
commit, on every database the samples run on.
