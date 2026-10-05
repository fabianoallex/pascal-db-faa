# 2. SQL by key

Samples: [`02-quickstart`](../samples/02-quickstart/Quickstart.dpr) (SQL registered in code),
[`03-migrations`](../samples/03-migrations/Migrations.dpr) (`.sql` files embedded as
resources), [`04-optionals`](../samples/04-optionals/Optionals.dpr) (templates).

## Keys, not SQL in code

Code asks for SQL by name, and the factory's loader finds the text:

```pascal
LQuery.Sql := FFactory.SqlLoader['CITY.INSERT'].SQL;
```

The loader looks for `<SQLDirectory>/<KEY>` in the configuration's `SqlSource`.
`SQLDirectory` is set per database (`'PG'`, `'FB'`, `'SQLITE'` in the samples), so **one key
can hold a different statement for each database** while the code stays the same. Usually
most scripts are identical and only a few differ (a `CREATE TABLE`, a `RETURNING`). A
pagination clause doesn't need a copy per database: the dialect writes it ([Paging](#paging)).

A missing key raises `ESQLLoaderException` ("SQL not found: PG/CITY.INSERT. Looked in: ...").
Each loader caches the texts it has read, and is safe to use from several threads.

### Why plain SQL and no query builder

This is a decision, not a gap. The library doesn't generate SQL: the statement you write is
the statement the database receives (the dialect only writes the few clauses that can't be
copied between databases, such as paging, a ping or a savepoint). Reasons:

- **Dialects differ where a builder would have to hide it:** `ROWS m TO n` or `OFFSET/FETCH`,
  `RETURNING` or `OUTPUT INSERTED` or nothing (MySQL), identifier quoting and case, column
  types. A builder covering only simple `SELECT`s still hits these, and JOINs, subqueries and
  CTEs make it a project of its own, tested on every database and adapter.
- **Plain SQL is reviewable.** The text lives in `.sql` files, one folder per database, with a
  readable diff. With a builder the real statement only exists at run time.
- **Writing SQL for another dialect is cheap, and checked.** The contract suite and the samples
  validate a statement on every database, and the SQL is what people and AI assistants already
  write best; a builder would add an API to learn and to get wrong.
- **The API would be hard to take back.** Every builder exposes a large, opinionated surface
  that users then ask to extend.

What exists instead: optional filters and partial updates through template tags and
[`IOptXxx`](optionals.md), and `${PAGE}` for paging. If a real consumer shows that repetitive
write statements hurt, a small, optional unit for `INSERT`/`UPDATE` built from `IOptXxx` is
the candidate to look at, not a general builder. Decided 2026-10-01.

## Where the text comes from

`IDatabaseConfig.SqlSource` takes any `ISqlSource` (unit `PascalDb.SqlSources`):

| Source | Reads | Use it for |
|---|---|---|
| `TResourceSqlSource` (default, when `SqlSource` is nil) | resources linked into the executable, named `SQL_<DIR>_<KEY>` | production: the SQL ships inside the program |
| `TDirectorySqlSource.Create(Root)` | `<Root>/<DIR>/<KEY>.sql` at runtime | development, or SQL deployed next to the program |
| `TMemorySqlSource` | `.Add(Dir, Key, Sql)` calls | tests, and small programs such as the samples |
| `TCompositeSqlSource.Create([A, B])` | asks each source in order; the first hit wins | a folder that overrides the embedded copies while developing |

### Embedded `.sql` files

Keep one folder per database with one file per key:

```
sql/
  PG/      CITY.INSERT.sql  CITY.BY_STATE.sql  ...
  FB/      CITY.INSERT.sql  ...
  SQLITE/  CITY.INSERT.sql  ...
```

Build the resource file (Python 3, any OS; compiling a `.rc` on Linux would need a MinGW
toolchain):

```
python tools/build_sql_res.py sql sql/MySql.res
```

and link it into the program on both compilers:

```pascal
{$R 'sql/MySql.res'}
```

Rebuild the `.res` after editing a `.sql` file. Give it a name different from the program's
and keep it out of the program's folder: FPC with `-FU` links a same-named `.res` from the
program folder instead of the one in the `$R` path (gotcha 19 in [`gotchas.md`](gotchas.md)).

### Overriding with a folder while developing

```pascal
LConfig.SqlSource := TCompositeSqlSource.Create([
  TDirectorySqlSource.Create(LSqlDir),   // edited files answer first
  TResourceSqlSource.Create]);           // the embedded copy is the fallback
```

A relative `Root` is resolved against the **executable's folder**, not the working directory
(a Windows service runs with `System32` as its working directory). On Linux, a directory
named `FB` also matches a lower-case `fb` folder.

### Text encoding

Files and resources are read as UTF-8 (a leading BOM is dropped) and returned exactly as
stored. On FPC, a SQL with non-ASCII characters needs the process's code page to be UTF-8,
otherwise the source raises `ESqlSourceException` instead of silently turning characters into
`?` ([guide 8](adapters.md#what-a-free-pascal-program-must-do)).

## Templates

`SqlLoader['KEY']` returns a `TSQLResult`: the text plus a few operations that shape it
before `.SQL` is read. They exist for SQL whose parts depend on the input, typically
optional filters and partial updates ([guide 3](optionals.md) shows both end to end).

```sql
[COMMENTS {] Removed when .SQL is read: documents the template. [} COMMENTS]
SELECT ID, NAME, CITY FROM CUSTOMERS WHERE 1 = 1
  [NAME {] AND NAME ${NAME_OP} :NAME [} NAME]
  [CITY {] AND CITY = :CITY [} CITY]
ORDER BY ID
```

```pascal
LSql := FFactory.SqlLoader['CUSTOMER.FIND']
  .ApplyFilter('NAME', 'LIKE', LName.HasValue)   // keeps [NAME] and sets ${NAME_OP}, or drops [NAME]
  .ProcessTag('CITY', LCity.HasValue);           // keeps or drops [CITY]
LQuery.Sql := LSql.SQL;
```

| Operation | Effect |
|---|---|
| `ProcessTag('TAG', Keep)` | keeps (without the markers) or removes every `[TAG {] ... [} TAG]` block in the text |
| `ReplaceLiteral('NAME', Text)` | replaces `${NAME}` with `Text` |
| `ApplyOperator('TAG', Op)` | `ReplaceLiteral('TAG_OP', Op)` |
| `ApplyFilter('TAG', Op, HasValue)` | `ProcessTag('TAG', HasValue)`, and `ApplyOperator` when `HasValue` |

Spaces around the tag name are optional in both markers: `[NAME{]`, `[ NAME {]`, `[}NAME]` and
`[} NAME ]` are the same markers. `ProcessTag` pairs each opening marker with the next closing
one and raises `ESQLLoaderException` for a closing marker with no opening before it, an opening
with no closing after it, or a block nested in another block of the same tag. Markers of a tag
nobody processed are dropped when `.SQL` is read, and their content stays.

The `WHERE 1 = 1` (or `SET ID = ID` in an `UPDATE`) lets every optional part start with
`AND` (or a comma) whichever of them are kept.

Three rules that aren't obvious from the syntax:

- **Process every tag the SQL has.** A tag nobody processed loses only its markers when `.SQL`
  is read; its content stays in the SQL. A forgotten `ProcessTag` leaves, for example, an
  `AND NAME = :NAME` whose parameter nobody binds.
- **`${...}` is pasted in as text.** Fill it from code (an operator, a column name chosen from
  a fixed list), never from user input. Values always go through parameters.
- `TSQLResult` is a record whose operations change it and return it, so they chain. Applied
  to a variable (`LSql.ProcessTag(...)`), they change that variable.

## Prefix searches and `LIKE ... ESCAPE`

A prefix typed by a user can contain `%` or `_`, which `LIKE` treats as wildcards. Escape them
in code and name the escape character in the SQL, **choosing one that isn't a backslash**:

```sql
[PREFIX {] AND DESCRIPTION LIKE :PREFIX ESCAPE '!' [} PREFIX]
```

```pascal
// '100%' -> '100!%%': the typed % is literal, the final one is the wildcard
LPattern := StringReplace(StringReplace(StringReplace(AText,
  '!', '!!', [rfReplaceAll]), '%', '!%', [rfReplaceAll]), '_', '!_', [rfReplaceAll]) + '%';
```

With `ESCAPE '\'`, SQLdb's SQLite and PostgreSQL connectors read `\'` as an escaped quote while
looking for parameters, and every parameter after it disappears without an error, until
binding fails with `Parameter "..." not found` (gotcha 26 in [`gotchas.md`](gotchas.md)).

## Paging

`PascalDb.Paging` pages a query by offset (running in
[sample 02](../samples/02-quickstart/Quickstart.dpr), `PrintStatePages`, on every database; the
repository method is `FindByStatePaged` in
[`Samples.CityRepository`](../samples/common/Samples.CityRepository.pas), checked against the
mock in sample 01). The SQL marks where the clause goes with a `${PAGE}` literal, after the
`ORDER BY`:

```sql
SELECT CODE, NAME, STATE FROM CITIES
WHERE STATE = :STATE
ORDER BY NAME, CODE
${PAGE}
```

`PdbPagingClause` writes the clause for the database of the scope's connection:

```pascal
function TCityRepository.FindByStatePaged(const AState: string;
  const APage: TPageRequest): TPage<TCity>;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.COUNT_BY_STATE'].SQL;
    LQuery.Params.Strings['STATE'] := AState;
    Result.Meta := TPageMeta.Create(APage, LQuery.Open.Int64s['TOTAL']);

    LQuery.Sql := FFactory.SqlLoader['CITY.BY_STATE_PAGED']
      .ReplaceLiteral('PAGE', PdbPagingClause(LScope, APage)).SQL;
    LQuery.Params.Strings['STATE'] := AState;
    LResult := LQuery.Open;
    SetLength(Result.Items, LResult.RecordCount);
    // ... read the rows into Result.Items
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

// the caller: page and limit as they came in, normalized
LPage := LRepo.FindByStatePaged('SC', TPageRequest.Create(LPageNumber, LLimit));
```

| Database | Clause for page 3 of 20 |
|---|---|
| PostgreSQL, SQLite, MySQL, MariaDB | `LIMIT 20 OFFSET 40` |
| Firebird (2.5 and later) | `ROWS 41 TO 60` |
| SQL Server | `OFFSET 40 ROWS FETCH NEXT 20 ROWS ONLY` |

- **`TPageRequest.Create(Page, Limit, DefaultLimit = 20, MaxLimit = 100)`** normalizes what a
  client sent: a page below 1 becomes 1, a missing limit (0 or less) becomes the default, and
  one above the maximum becomes the maximum. Build every page with it: `PdbPagingClause`
  refuses a page with no limit.
- **`TPageMeta`** holds the page, the limit and the total, and derives `TotalPages` (never below
  1: an empty result is one empty page), `HasNext` and `HasPrev`. **`TPage<T>`** is `Items` plus
  `Meta`, to return both from a repository. Turning them into JSON is the API's job.
- **The total is a query you write**, with the same filter, usually `COUNT(*)`: the library
  doesn't derive it from the page query, which would mean parsing SQL. In the same scope, both
  run in one transaction.
- **The `ORDER BY` must name a unique set of columns** (end with the key): with ties, the
  database may put a row on two pages or on none. SQL Server refuses the clause without an
  `ORDER BY`; the others accept it and return rows in no defined order.
- **The numbers go into the text**, not through parameters: they are `Integer`/`Int64`, so
  nothing a client types reaches the SQL. It also means each page is a different statement;
  a request runs its page query once, so that costs nothing it wouldn't cost anyway.
- **Large offsets are slow**: the database still reads and skips every row before the page.
  For deep pages, page by key instead — `WHERE ID > :LAST_ID ORDER BY ID` with the same clause
  on page 1 (`TPageRequest.Create(1, Limit)`), passing the last key of the previous page.
- `PdbDialectOf(LScope)` gives the dialect itself. A dialect of your own pages only if it
  implements `IPagingDialect` ([guide 10](other-databases.md#1-an-sql-dialect)); with the
  mock, the clause is a `LIMIT`/`OFFSET` that never reaches the recorded key
  ([guide 5](testing-with-the-mock.md)).

## Running the same statement many times

There is no `Prepare` to call: each driver prepares a statement the first time it runs, and the
adapters keep it prepared while the same query runs it again. What decides the speed is
**reusing one `IQuery`** for the whole loop instead of acquiring one per row:

```pascal
LScope := LFactory.GetPool.AcquireQuery(LQuery);
LScope.StartTransaction;
try
  LQuery.Sql := LFactory.SqlLoader['PRODUCT.INSERT'].SQL;  // setting it inside the loop is fine too
  for LProduct in AProducts do
  begin
    LQuery.Params.Strings['CODE'] := LProduct.Code;
    LQuery.Params.Currencies['PRICE'] := LProduct.Price;
    LQuery.ExecSql;
  end;
  LScope.Commit;
except
  LScope.Rollback;
  raise;
end;
```

Setting `Sql` to the text it already has keeps the statement prepared and clears only the
parameters' values, so a parameter you don't set on a row is not sent with the previous row's
value. The statement stays prepared within one transaction; SQLdb prepares it again in the next.

Measured with 2000 `SELECT ... WHERE ID = :ID` (FPC 3.2.2 and Delphi 12 on Windows, PostgreSQL 17
in Docker; the absolute numbers depend on the network, the ratios much less):

| | one query for the loop | a new query per row |
|---|---|---|
| Zeos | 1.1 s | 5.0 s |
| FireDAC | 1.1 s | 6.6 s |
| SQLdb | 3.5 s | 5.8 s |

A new query per request is what a server does anyway, and it costs a few milliseconds per request
there; a loop is where one query pays off.

### Loading many rows

What makes a load slow, in this order:

1. **A commit per row.** Every commit waits for the database to make it durable. Put the whole
   load (or large chunks of it) in one transaction.
2. **A round trip per row.** With the statement prepared, each `ExecSql` still waits for the
   server's answer; the cost is the latency, not the library.
3. Only then, the statement itself.

Measured with 20 000 rows of three columns (SQLdb, FPC 3.2.2 on Windows; Firebird 2.5 on the same
machine, PostgreSQL 17 in Docker reached through its forwarded port; the commit-per-row column
with 2 000 rows):

| | a commit per row | one transaction, one row per `ExecSql` | one transaction, many rows per statement |
|---|---|---|---|
| SQLite | 234 rows/s | 425 000 rows/s | 128 000 rows/s (100 per statement) |
| PostgreSQL | 255 rows/s | 1 500 rows/s | 42 600 rows/s (100 per statement) |
| Firebird | 1 100 rows/s | 5 800 rows/s | 32 800 rows/s (50 per statement) |

At those rates, 100 000 rows with a commit each take several minutes on every database, and
seconds (SQLite: a quarter of a second) in one transaction. Sending many rows per statement
cuts the round trips: 28 times faster on PostgreSQL, 5.7 on Firebird, and nothing on SQLite,
which has no server to talk to. The farther the server, the more it pays.

#### Batches: `IBatch`

`TBatch.New` (unit `PascalDb.Batch`) takes a query and one statement, and you add rows of
parameters to it:

```pascal
LScope := LFactory.GetPool.AcquireQuery(LQuery);
LScope.StartTransaction;
try
  LBatch := TBatch.New(LQuery, LFactory.SqlLoader['PRODUCT.INSERT'].SQL);
  for LProduct in AProducts do
  begin
    LBatch.Params.Strings['CODE'] := LProduct.Code;
    LBatch.Params.Currencies['PRICE'] := LProduct.Price;
    LBatch.Params.OptNullStrings['NOTE'] := LProduct.Note;
    LBatch.AddRow;
  end;
  LBatch.Execute;   // the rows not sent yet
  LScope.Commit;
except
  LScope.Rollback;
  raise;
end;
```

The rows are sent `MaxRows` at a time (1000 by default, the third argument of `New`): `AddRow`
sends them when they reach it, `Execute` sends the rest. With FireDAC they go as one Array DML
operation per send; with SQLdb and Zeos, one `ExecSql` per row on the prepared statement, the
same as the loop above (`IsNative` tells which). Zeos has an array operation of its own, but it
failed on most databases and wrote wrong values on PostgreSQL
([gotcha 44](gotchas.md)). Measured with FireDAC, 10 000 `INSERT`s of four columns in one
transaction (Delphi 12, Win64; servers in Docker on the same machine, except Firebird):

| | one row per `ExecSql` | `IBatch` (1000 per send) |
|---|---|---|
| Firebird 2.5 (local) | 0.63 s | 0.15 s |
| PostgreSQL 17 | 6.1 s | 0.56 s |
| SQLite | 80 ms | 23 ms |
| MySQL 8.4 | 26 s | 0.17 s |
| MariaDB 11.4 | 20 s | 0.10 s |

What to know:

- **Each row starts empty.** A parameter set in some rows and not in another is NULL in that
  one (an Undefined optional too), so no value carries over from the previous row.
- **One type per parameter.** `Integers['QTY']` in one row and `Int64s['QTY']` in another raises
  `EArgumentException`: an array operation has one type per column. A NULL counts with the type of
  its setter (`NullIntegers`, ...).
- **Call `AddRow` for the last row too.** `Execute` with values set and no `AddRow` raises
  `EInvalidOpException` instead of dropping them. Rows added and never sent are dropped with the
  batch.
- **A failure rejects the send**, with the same exceptions as `ExecSql` (`ELockConflictException`,
  `EDatabaseUnavailableException`, the driver's). Earlier sends are already in the transaction:
  roll it back. Which row failed isn't reported.
- **The query is the batch's until you're done** with it; afterwards it runs single statements
  again. In tests, the mock records one execution per row.
- The pool's statement events report a native send as one `skExecBatch` with the row count, and
  a row-by-row batch as one `skExecSql` per row ([guide 7](pool.md#statement-events)).

#### Many rows per statement, by hand

Where `IBatch` runs row by row (SQLdb, Zeos), a statement with many rows still cuts the round
trips. It is plain SQL with numbered parameters, sent through the same loop.
PostgreSQL and SQLite take a list of rows:

```sql
INSERT INTO PRODUCTS (CODE, NAME) VALUES (:C1, :N1), (:C2, :N2), (:C3, :N3)
```

Firebird has no multi-row `VALUES` (neither 2.5 nor 5); select the rows from `RDB$DATABASE`, with
a `CAST` on each parameter so the server knows its type (measured on 2.5):

```sql
INSERT INTO PRODUCTS (CODE, NAME)
  SELECT CAST(:C1 AS VARCHAR(20)), CAST(:N1 AS VARCHAR(60)) FROM RDB$DATABASE
  UNION ALL SELECT CAST(:C2 AS VARCHAR(20)), CAST(:N2 AS VARCHAR(60)) FROM RDB$DATABASE
```

Build the text once for a batch size, set it once, and bind row by row (`'C' + IntToStr(J)`);
send the last, shorter batch with a statement of its own size. What it costs:

- **A failure rejects the whole batch**, and the database doesn't say which row caused it. One
  row per `ExecSql` tells you exactly which one failed; for a load that must report or skip bad
  rows, keep it, or rerun a failed batch row by row.
- **Limits per statement:** PostgreSQL 65 535 parameters, SQLite 32 766 (999 before 3.32),
  Firebird 2.5 64 KB of SQL text. The table used 50 and 100 rows per statement; larger batches
  weren't measured.
- On SQLite it is slower, not faster (the table above): stay with one row per `ExecSql` in one
  transaction.

When the rows are already in the database, none of this applies: `INSERT INTO ... SELECT ...`
runs as one `ExecSql`. PostgreSQL's `COPY` goes further still, but no adapter exposes it.

## Next

[Guide 3](optionals.md): the optional and nullable types that decide which blocks to keep and
which parameters get bound.
