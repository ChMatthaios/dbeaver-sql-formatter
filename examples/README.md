# Formatter examples

These files are manual stress-test inputs for the Windows app and DBeaver formatter.
They are intentionally compact or awkwardly laid out so formatting differences are easy to see.

## Files

- `sample-db2.sql` — large DB2 query/DML/DGTT stress test.
- `sample-db2-objects.sql` — DB2 view, SQL PL procedure, function and trigger.
- `sample-ansi.sql` — common/ANSI-style SELECT, INSERT, UPDATE, DELETE and VIEW.
- `sample-postgresql.sql` — PostgreSQL SELECT/DML/CTE/JSON/ARRAY/LATERAL/locking features.
- `sample-postgresql-objects.sql` — PostgreSQL view, functions, procedure and trigger.
- `sample-tsql.sql` — SQL Server/T-SQL TOP, APPLY, temp tables, OUTPUT, UPDATE FROM, DELETE FROM, OFFSET/FETCH and FOR JSON.
- `sample-tsql-objects.sql` — SQL Server view, procedure, function and trigger.
- `sample-oracle.sql` — Oracle hierarchy, analytics, INSERT ALL, MERGE, RETURNING INTO, VIEW and q-quoted strings.
- `sample-plsql.sql` — Oracle PL/SQL anonymous block, procedure, function, trigger and package.
- `sample-sparql.rq` — SPARQL 1.1 query forms, graph patterns, aggregates and update operations.

## Recommended testing

For ordinary SQL files, you can paste or open the whole file in the Windows app and press **Format**.
In DBeaver, select a statement and use `Ctrl + Shift + F`.

For stored procedures, functions, triggers, packages, PostgreSQL dollar-quoted bodies and other program units, select **one complete object/program unit at a time** in DBeaver. This makes the test match the formatter's conservative stored-program behavior and avoids treating internal semicolons as independent top-level statements.

The examples are test fixtures only. They are not intended to be executed against a real database without adapting schemas, tables, delimiters and sample data to your environment.
