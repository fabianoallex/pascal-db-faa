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
most scripts are identical and only a few differ (a `CREATE TABLE`, a `RETURNING`, a
pagination clause).

A missing key raises `ESQLLoaderException` ("SQL not found: PG/CITY.INSERT. Looked in: ...").
Each loader caches the texts it has read, and is safe to use from several threads.

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
program folder instead of the one in the `$R` path (gotcha 19 in [`CLAUDE.md`](../CLAUDE.md)).

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
binding fails with `Parameter "..." not found` (gotcha 26 in [`CLAUDE.md`](../CLAUDE.md)).

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

## Next

[Guide 3](optionals.md): the optional and nullable types that decide which blocks to keep and
which parameters get bound.
