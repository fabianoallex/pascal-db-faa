# 4. Migrations

Sample: [`03-migrations`](../samples/03-migrations/Migrations.dpr), with its scripts under
[`samples/03-migrations/sql`](../samples/03-migrations/sql).

## How it works

`TDBMigrationEngine` (unit `PascalDb.Migrations`) takes a list of migrations, each a numbered
SQL script, and applies in order those whose version is above the last one recorded in the
`SCHEMA_MIGRATIONS` table. Running it again applies nothing.

```pascal
const
  ALL_MIGRATIONS: array[0..4] of TMigrationItem = (
    (Version: 1; ScriptName: 'MIG.0001'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: True),   // SCHEMA_MIGRATIONS
    (Version: 2; ScriptName: 'MIG.0002'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: True),   // PRODUCTS table
    (Version: 3; ScriptName: 'MIG.0003'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: False),  // seed rows
    (Version: 4; ScriptName: 'MIG.0004'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: True),   // ACTIVE column
    (Version: 5; ScriptName: 'MIG.0005'; ParamReplaceProc: nil; Terminator: ';'; IsDDL: False)); // fill ACTIVE

LEngine := TDBMigrationEngine.Create(LFactory, LLog.OnEvent);
try
  Writeln('Schema version: ', LEngine.CurrentVersion);
  LEngine.Execute(ALL_MIGRATIONS);
finally
  LEngine.Free;
end;
```

- `ScriptName` is a SQL key ([guide 2](sql.md)): the script is read from the factory's SQL
  source, so each database can have its own version of it.
- **The engine doesn't create `SCHEMA_MIGRATIONS`**: your first migration does. The sample's
  `MIG.0001` (PostgreSQL and SQLite; Firebird has no `IF NOT EXISTS` and uses a plain
  `CREATE TABLE`):

  ```sql
  CREATE TABLE IF NOT EXISTS SCHEMA_MIGRATIONS (
    VERSION    INTEGER   NOT NULL,
    APPLIED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT PK_SCHEMA_MIGRATIONS PRIMARY KEY (VERSION)
  );
  ```

- **Append only.** A published migration is never edited, and a new one always gets a version
  above every existing one: the engine compares with the highest version applied, so a
  migration inserted below it would never run.
- `ParamReplaceProc` (optional) receives the script's lines before they run, to adjust them
  from code.
- `CurrentVersion` reads the highest applied version without running anything, e.g. to log
  the database's state at startup.
- A failing migration stops `Execute` and its exception propagates; the migrations before it
  stay applied.

## `IsDDL`: DDL and DML go in separate migrations

`IsDDL` decides the transactions:

- `IsDDL = False` (DML: `INSERT`, `UPDATE`, `DELETE`): the script and the insert of its version
  run in **one transaction**, all or nothing.
- `IsDDL = True` (`CREATE`, `ALTER`, `DROP`, `CREATE INDEX`, ...): the script runs and commits
  in one transaction, then its version is recorded in a second one. Firebird can't use a table
  or column in the transaction that created it, so recording the version of the migration that
  creates `SCHEMA_MIGRATIONS` in the same transaction fails with "Table unknown". Two
  transactions work on every database.

So adding a column and filling it are two migrations: `MIG.0004` (`ALTER TABLE ... ADD ACTIVE`,
DDL) and `MIG.0005` (`UPDATE ... SET ACTIVE = 1`, DML), since on Firebird the `UPDATE` can't
use the column in the transaction that added it.

A consequence of the two transactions: if a DDL script commits and recording its version then
fails, the next run applies that script again. Where the database allows it,
`IF NOT EXISTS` makes a DDL script safe to repeat.

## How scripts are split

A migration script can hold several statements. The engine cuts the text at **every**
`Terminator` (`;` above) and runs each piece separately, **without looking at string literals
or comments**. Therefore:

- no `;` inside a string literal or a comment;
- no comment after the last statement: it would become a statement of its own. Comments
  before a statement are fine.

The same applies to any `ISqlScript` (`IDBFactory.CreateSqlScript`).

## Progress events

Each step raises a `TMigrationEvent`: `mekCheck` (with the version before anything runs),
`mekApplying`, `mekApplied`, `mekFailed` (with `ErrorMessage`) and `mekCompleted` (with
`AppliedCount` and the final `SchemaVersion`). The engine doesn't choose where they go: you
pass a handler. Without one, each event becomes a line on the console.

Pass a **method** as the handler: it compiles on both compilers. Delphi also accepts an
anonymous method, but FPC 3.2.2 has none.

```pascal
type
  TMigrationLog = class
  public
    procedure OnEvent(const AEvent: TMigrationEvent);
  end;

procedure TMigrationLog.OnEvent(const AEvent: TMigrationEvent);
begin
  case AEvent.Kind of
    mekApplying: Writeln(Format('Applying %d (%s)', [AEvent.Version, AEvent.ScriptName]));
    mekFailed:   Writeln(Format('Failed %d: %s', [AEvent.Version, AEvent.ErrorMessage]));
  end;
end;
```

## Next

[Guide 5](testing-with-the-mock.md): testing the code that uses all of this, without a
database.
