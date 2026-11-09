# Full-text search

Searching text by words with the database's own full-text index: PostgreSQL (`tsvector` /
`to_tsquery`), MySQL and MariaDB (`FULLTEXT` / `MATCH ... AGAINST`) and SQLite (FTS5). Firebird
has no full-text search, and SQL Server's is not covered: there the same search runs with
`LIKE`.

The library writes no full-text SQL. The index, the column and the query are yours, written once
per database like any other SQL (see [SQL by key](sql.md)), because their shape differs: on
PostgreSQL and MySQL the search is a condition on the table, on SQLite it is a join with the FTS5
table. What the library writes is the **value of the search parameter**, from what the user
typed, in `PascalDb.FullText`.

## Why the value needs the library

Each syntax gives meaning to characters a user types without thinking about it. Measured with
the three databases, passing the text as typed:

| Typed | PostgreSQL `to_tsquery` | MySQL boolean mode | SQLite FTS5 |
|---|---|---|---|
| `café preto` | syntax error | `café` OR `preto` | both words |
| `"café` | ok | ok | `unterminated string` |
| `café)` | syntax error | syntax error | syntax error |
| `-café` | ok | excludes `café`: no rows | `no such column` |
| `50%`, `d'água` | ok | ok | syntax error |
| `*`, `+` | ok | syntax error | syntax error |
| `café OR leite` | syntax error | `OR` is a stopword: `café` OR `leite` | `café` OR `leite` |

It is a parameter, so nothing reaches the SQL text, but the query fails (an HTTP 500 for a
search box) or means something else. `PdbFullTextQuery` cuts the text into words and writes each
one in a form the syntax reads literally:

```pascal
uses PascalDb.FullText, PascalDb.SqlLoader;

function TArticleRepository.Search(const AText: string): TArray<TArticle>;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LValue: string;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    if PdbSupportsFullText(LScope) then
      LValue := PdbFullTextQuery(LScope, AText)   // '' = no word to search for
    else
      LValue := PdbLikeContains(AText);           // Firebird, SQL Server
    if LValue <> '' then
    begin
      LQuery.Sql := FFactory.SqlLoader['FULLTEXT.SEARCH'].SQL;
      LQuery.Params.Strings['Q'] := LValue;
      Result := ReadArticles(LQuery.Open);
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;
```

`PdbFullTextQuery` returns `''` when the text has no word the database can search for (empty,
only punctuation or emoji, or on MySQL only short words and stopwords): there is nothing to
find, so don't run the query. The mock's dialect writes PostgreSQL's form, so code like the
above runs against `TMockDBFactory` too.

## Words

`PdbFullTextWords` keeps runs of letters and digits. ASCII punctuation and spaces, the
underscore, Latin-1 punctuation (`«`, `»`, `¿`), Unicode spaces and general punctuation
(dashes, curly quotes, `…`), symbols, arrows and emoji separate words; an invalid character
(a stray UTF-8 byte, a lone surrogate) does too. `Café-com-leite` is three words, `d'água` is
`d` and `água`. On FPC the text must be UTF-8, as everywhere in the library
([runtime requirements](adapters.md)).

## Options

```pascal
var
  LOptions: TFullTextOptions;
begin
  LOptions := TFullTextOptions.Default;   // all words, no prefix
  LOptions.Match := ftmAnyWord;           // at least one word
  LOptions.PrefixLastWord := True;        // "polvi" finds "polvilho": search as you type
  LValue := PdbFullTextQuery(LScope, AText, LOptions);
```

Start from `TFullTextOptions.Default`: a record declared without it has no MySQL stopwords and
no minimum word length. What each dialect writes for `café pre`:

| | All words | Any word | All words, prefix |
|---|---|---|---|
| PostgreSQL | `'café' & 'pre'` | `'café' \| 'pre'` | `'café' & 'pre':*` |
| MySQL / MariaDB | `+café +pre` | `café pre` | `+café +pre*` |
| SQLite | `"café" "pre"` | `"café" OR "pre"` | `"café" "pre"*` |

- **Any word** only makes sense with the rows ordered by the score; the reference queries do.
- **A prefix** of one or two letters matches a large part of the table on every database. That
  is correct, and the cost is your choice: start searching after a few characters.
- **MySQL and MariaDB, all words**: the index never holds words shorter than
  `innodb_ft_min_token_size` (3 by default) or in the stopword list (`de`, `com`, `or`, ...), and
  in boolean mode a required word the index doesn't hold matches **no row at all** (`+pão +de
  +queijo` finds nothing, measured). So their dialect leaves those words out: `pão de queijo x`
  becomes `+pão +queijo`. The last word stays when it is a prefix. If the server's settings
  differ from InnoDB's defaults, set `MySQLMinTokenSize` and `MySQLStopwords` to match
  (`MySQLStopwords := nil` for a server without stopwords). In any-word mode nothing is left out.
  PostgreSQL leaves its own stopwords out by itself.

## The reference SQL

[`docs/fulltext/sql`](fulltext/sql) has, for each database, `FULLTEXT.SCHEMA` (an `ARTICLES`
table with its index) and `FULLTEXT.SEARCH` (the search, parameter `:Q`, ordered by the score).
They are the files the integration tests run, so they work as written; copy them into your
SQL folders and rename. Each schema ends its statements with a line holding `^`, so it runs as
a migration with that terminator (SQLite's triggers have `;` inside).

- **PostgreSQL** (`PG`): a generated `TSVECTOR` column with a GIN index, and a text search
  configuration `pt_unaccent` (Portuguese stemming without accents) built on the `unaccent`
  extension. `unaccent()` can't go into the generated column itself: it is not immutable
  (`42P17`); a configuration that uses it can. Change `portuguese` to your language. The query
  is `to_tsquery('pt_unaccent', :Q)`: never with the text as typed, which fails on a space.
- **MySQL / MariaDB** (`MYSQL`): a `FULLTEXT` index on the columns `MATCH` names (exactly those
  columns, in a table with `utf8mb4` and its default accent- and case-insensitive collation).
  `:Q` appears twice in the query; every adapter binds both.
- **SQLite** (`SQLITE`): an FTS5 external content table (it indexes `ARTICLES` without a second
  copy of the text) kept up to date by three triggers, tokenizer `unicode61 remove_diacritics 2`.
  The SQLite library must have FTS5: the sqlite.org builds and Debian's `libsqlite3` do.
- **Firebird** (`FB`) and **SQL Server** (`MSSQL`): the same table, searched with `LIKE` and
  `PdbLikeContains`. That matches the typed text as one piece (`café preto` finds "Café preto",
  not "preto, sem café"), ignores case (Firebird through `LOWER`, SQL Server through its default
  collation) and keeps accents. A long text needs room in the pattern: Firebird casts it to
  `VARCHAR(8000)`, and on SQL Server SQLdb sends no string parameter longer than 2000
  characters, Zeos none longer than 4000 ([gotcha 62](gotchas.md)); limit what the search box
  accepts.

## Differences that remain

The value hides the syntax; these come from the databases themselves (all measured):

| | PostgreSQL | MySQL / MariaDB | SQLite | `LIKE` |
|---|---|---|---|---|
| Accents and case | ignored (`pt_unaccent`) | ignored (collation) | ignored (tokenizer) | case ignored, accents kept |
| Stemming (`cafés` finds `café`) | yes | no | no | no |
| Stopwords | dropped by the database | dropped by the dialect (all words) | none: `de` is a word | — |
| Short words (`pé`, `50`) | found | never found (< 3 characters) | found | found |
| A row written earlier in the same transaction | found | **not found until committed** | found | found |
| Score | `ts_rank`, higher is better | relevance, higher is better | `bm25`, lower is better | none |

- **MySQL and MariaDB only see committed rows** in a full-text search: InnoDB fills the index at
  commit. Code that inserts and then searches in one transaction finds nothing there.
- **SQLdb on PostgreSQL** prints the server's notices to standard error: a search whose words
  are all stopwords (`to_tsquery` with no lexeme left) prints `NOTICE: text-search query
  contains only stop words or doesn't contain lexemes, ignored` on every run. Zeos doesn't.
- The score is a floating-point column; `IQueryResult` has no `Double` getter, read it with
  `FieldValue` if you need the number (ordering in the SQL is usually enough).

## Paging and counting

Add `${PAGE}` after the `ORDER BY` as with any query ([paging](sql.md)); the score and the id
make the order unique. The count is a `SELECT COUNT(*)` with the same `FROM` and `WHERE`,
written by you.
