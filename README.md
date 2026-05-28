# SQLFMT — DB2 SQL Formatter for DBeaver

> A lightweight DB2 SQL formatter built around one simple idea:  
> **format everything using the same readable SQL grid.**

SQLFMT is a small PowerShell-based formatter designed mainly for **DBeaver External Formatter** integration. It reads SQL from `stdin`, writes formatted SQL to `stdout`, and keeps DBeaver usage simple, fast, and predictable.

---

## Table of Contents

- [What SQLFMT Does](#what-sqlfmt-does)
- [Formatting Philosophy](#formatting-philosophy)
- [Project Structure](#project-structure)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Install the sqlfmt Command](#install-the-sqlfmt-command)
- [Use SQLFMT from PowerShell](#use-sqlfmt-from-powershell)
- [Add SQLFMT to DBeaver](#add-sqlfmt-to-dbeaver)
- [Recommended DBeaver Workflow](#recommended-dbeaver-workflow)
- [Formatter Rules](#formatter-rules)
- [Supported SQL Patterns](#supported-sql-patterns)
- [Settings](#settings)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Performance Notes](#performance-notes)
- [Development Notes](#development-notes)
- [Commit Checklist](#commit-checklist)

---

## What SQLFMT Does

SQLFMT formats DB2 SQL into a consistent, readable layout.

It is especially useful for:

| Use case | Supported |
|---|---:|
| Formatting DB2 SQL in DBeaver | ✅ |
| Formatting complete SQL files from PowerShell | ✅ |
| Formatting complete selected SQL statements | ✅ |
| Formatting nested `SELECT` / `WITH` queries | ✅ |
| Formatting procedures and functions | ✅ |
| Preserving comments as normal text | ✅ |
| Acting as a full SQL parser | ❌ |

SQLFMT is intentionally heuristic. It is not a complete DB2 parser. The goal is practical, predictable formatting for real working SQL.

---

## Formatting Philosophy

The formatter follows one main rule:

> **FORMAT EVERYTHING.**

That means SQLFMT does not try to keep clauses inline just because they fit on one line.

Instead, it applies the same visual grid everywhere:

```sql
SELECT C.CUSTOMER_ID,
       C.CUSTOMER_NAME,
       C.COUNTRY_CODE
  FROM CUSTOMER C
 WHERE C.IS_ACTIVE = 1
   AND EXISTS (SELECT 1
                 FROM ORDER_HEADER O
                WHERE O.CUSTOMER_ID = C.CUSTOMER_ID);
```

Nested queries are formatted using the same rules, only shifted right to their local starting point.

---

## Project Structure

Typical repository layout:

```text
dbeaver-sql-formatter/
├─ examples/
│  ├─ sample-db2.sql
│  └─ sample-db2-output.sql
├─ scripts/
│  └─ install-sqlfmt-command.ps1
├─ settings/
│  └─ settings.json
├─ tests/
│  ├─ 01_simple_one_line_statements.sql
│  ├─ 02_simple_multiline_statements.sql
│  ├─ ...
│  └─ 12_union_except_intersect.sql
├─ tests_out/
├─ format-sql.ps1
├─ format.ps1
├─ format-file.ps1
├─ sqlfmt.cmd
├─ README.md
└─ .gitignore
```

The most important file is:

```text
format-sql.ps1
```

DBeaver should call this formatter directly.

---

## Requirements

| Requirement | Notes |
|---|---|
| Windows | Primary target environment |
| PowerShell 5+ | Windows PowerShell works |
| DBeaver | For editor integration |
| DB2 SQL | Formatter is designed around DB2 style |

Check PowerShell:

```powershell
$PSVersionTable.PSVersion
```

---

## Quick Start

From the repository root:

```powershell
Get-Content .\examples\sample-db2.sql -Raw |
powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1 |
Set-Content .\examples\sample-db2-output.sql -Encoding UTF8
```

Open:

```text
examples/sample-db2-output.sql
```

You should see formatted SQL.

---

## Install the sqlfmt Command

SQLFMT includes a command wrapper so you can run the formatter more easily.

From the repo root:

```powershell
.\scripts\install-sqlfmt-command.ps1
```

After installation, restart your terminal and test:

```powershell
sqlfmt
```

Typical usage:

```powershell
Get-Content .\examples\sample-db2.sql -Raw | sqlfmt
```

Write output to a file:

```powershell
Get-Content .\examples\sample-db2.sql -Raw |
sqlfmt |
Set-Content .\examples\sample-db2-output.sql -Encoding UTF8
```

### If `sqlfmt` is not recognized

Restart VS Code / terminal first.

Then check your PATH:

```powershell
$env:Path -split ';'
```

If needed, rerun:

```powershell
.\scripts\install-sqlfmt-command.ps1
```

---

## Use SQLFMT from PowerShell

### Format a file manually

```powershell
Get-Content .\examples\sample-db2.sql -Raw |
powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1 |
Set-Content .\examples\sample-db2-output.sql -Encoding UTF8
```

### Format using the local test runner

```powershell
.\format.ps1 -runall
```

### List available test files

```powershell
.\format.ps1 -list
```

### Format one test file

```powershell
.\format.ps1 -file .\tests\01_simple_one_line_statements.sql
```

### Important note about `format-file.ps1`

If `format-file.ps1` contains an embedded old formatter, update it so it calls:

```text
format-sql.ps1
```

The project should have **one formatter source of truth**:

```text
format-sql.ps1
```

---

## Add SQLFMT to DBeaver

DBeaver can call external formatters. SQLFMT is designed for that workflow.

### Step 1 — Open DBeaver Preferences

In DBeaver:

```text
Window → Preferences
```

Then go to:

```text
Editors → SQL Editor → Code Editor → Formatter
```

Depending on your DBeaver version, the exact menu labels may vary slightly.

### Step 2 — Choose External Formatter

Select an external/custom formatter option.

Use PowerShell as the command.

### Step 3 — Configure the command

Use this command:

```text
powershell
```

Arguments:

```text
-NoProfile -ExecutionPolicy Bypass -File "C:\path\to\dbeaver-sql-formatter\format-sql.ps1"
```

Example:

```text
-NoProfile -ExecutionPolicy Bypass -File "C:\Users\v-mchouliaras\Desktop\dbeaver-sql-formatter\format-sql.ps1"
```

### Step 4 — Save and test

In SQL Editor:

1. Select a full SQL statement.
2. Run DBeaver formatting.
3. Check the formatted result.

---

## Recommended DBeaver Workflow

Use SQLFMT on complete SQL statements.

| Action | Recommended? | Why |
|---|---:|---|
| Select a full SQL statement and format | ✅ | Best result |
| Format the whole script | ✅ | Works when statements are separated by semicolons |
| Triple-click a physical line and format | ❌ | Can send broken fragments |
| Format half a query | ❌ | Formatter cannot safely infer missing SQL context |

Good:

```sql
SELECT C.CUSTOMER_ID,
       C.CUSTOMER_NAME
  FROM CUSTOMER C
 WHERE C.IS_ACTIVE = 1;
```

Risky:

```sql
WHERE C.IS_ACTIVE = 1
```

The formatter expects valid SQL statements, not random fragments.

---

## Formatter Rules

### SELECT lists

Always one column/expression per line:

```sql
SELECT C.CUSTOMER_ID,
       C.CUSTOMER_NAME,
       C.COUNTRY_CODE
```

### FROM and JOIN

Joins get their own lines:

```sql
  FROM CUSTOMER C
 INNER JOIN ORDER_HEADER O
    ON O.CUSTOMER_ID = C.CUSTOMER_ID
   AND O.STATUS_CODE = 'PAID'
```

### WHERE

Predicates are split by top-level `AND` / `OR`:

```sql
 WHERE C.IS_ACTIVE = 1
   AND C.COUNTRY_CODE = 'GR'
   AND EXISTS (SELECT 1
                 FROM ORDER_HEADER O
                WHERE O.CUSTOMER_ID = C.CUSTOMER_ID)
```

### Parenthesized OR groups

Boolean groups are expanded:

```sql
   AND (   C.COUNTRY_CODE = 'GR'
        OR C.COUNTRY_CODE = 'US'
        OR C.COUNTRY_CODE = 'GB')
```

### CASE

CASE blocks are expanded:

```sql
CASE
  WHEN C.IS_ACTIVE = 1 THEN 'ACTIVE'
  ELSE 'INACTIVE'
END AS CUSTOMER_STATUS
```

### Nested SELECT

Nested SELECTs use the same grid:

```sql
SELECT C.CUSTOMER_ID,
       (SELECT COUNT (*)
          FROM CUSTOMER_NOTE CN
         WHERE CN.CUSTOMER_ID = C.CUSTOMER_ID) AS NOTE_COUNT
  FROM CUSTOMER C
```

### CTEs

CTEs are formatted recursively:

```sql
WITH CUSTOMER_BASE
     AS ( SELECT C.CUSTOMER_ID,
                 C.CUSTOMER_NAME
            FROM CUSTOMER C
           WHERE C.IS_ACTIVE = 1 )
SELECT CUSTOMER_ID,
       CUSTOMER_NAME
  FROM CUSTOMER_BASE;
```

### GROUP BY / ORDER BY

Always one item per line:

```sql
 GROUP BY C.CUSTOMER_ID,
          C.CUSTOMER_NAME
 ORDER BY C.CUSTOMER_NAME ASC,
          C.CUSTOMER_ID ASC
```

### Comments

Comments are preserved as normal text.

```sql
SELECT C.CUSTOMER_ID,
       -- Customer display name
       C.CUSTOMER_NAME
  FROM CUSTOMER C
 WHERE C.IS_ACTIVE = 1
   AND -- only paid customers
       EXISTS (SELECT 1
                 FROM ORDER_HEADER O
                WHERE O.CUSTOMER_ID = C.CUSTOMER_ID)
```

---

## Supported SQL Patterns

| SQL pattern | Status | Notes |
|---|---:|---|
| Simple `SELECT` | ✅ | One column per line |
| Nested `SELECT` | ✅ | Recursive formatting |
| CTE / `WITH` | ✅ | Recursive formatting |
| Multiple CTEs | ✅ | Each CTE formatted |
| `JOIN ... ON ... AND ...` | ✅ | ON predicates split |
| `WHERE EXISTS (SELECT...)` | ✅ | Nested query formatted |
| `WHERE IN (SELECT...)` | ✅ | Nested query formatted |
| Scalar subquery in SELECT list | ✅ | Nested query formatted |
| `CASE WHEN` | ✅ | Multiline CASE |
| `INSERT INTO ... SELECT` | ✅ | Insert columns + SELECT |
| `INSERT INTO ... VALUES` | ✅ | Values split |
| `UPDATE ... SET` | ✅ | Assignments split |
| `UPDATE ... WHERE IN (SELECT...)` | ✅ | Nested query formatted |
| `DELETE ... WHERE EXISTS` | ✅ | Nested query formatted |
| `MERGE INTO ... USING (WITH...)` | ✅ | Recursive USING block |
| `CREATE TABLE` | ✅ | Columns split |
| `DECLARE GLOBAL TEMPORARY TABLE` | ✅ | Columns split, tail preserved |
| `CREATE TABLE AS (...) WITH NO DATA` | ✅ | Inner SELECT formatted |
| `CREATE VIEW AS SELECT` | ✅ | SELECT formatted |
| `CREATE PROCEDURE` | ✅ | SQL PL body handled conservatively |
| `CREATE FUNCTION` | ✅ | `RETURN CASE` handled |

---

## Settings

Settings are read from:

```text
settings/settings.json
```

Example:

```json
{
  "keywordCasing": "Uppercase"
}
```

Supported values:

| Setting | Values | Description |
|---|---|---|
| `keywordCasing` | `Uppercase`, `Lowercase`, `Preserve` | Controls SQL keyword casing |

Current formatter behavior is focused on **format everything**, so line-length settings are intentionally not the main driver.

---

## Testing

### Smoke test

```powershell
"select a, b, c from t where x = 1 and y = 2;" |
powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1
```

Expected shape:

```sql
SELECT A,
       B,
       C
  FROM T
 WHERE X = 1
   AND Y = 2;
```

### Nested SELECT test

```powershell
"select c.customer_id from customer c where exists (select 1 from order_header o where o.customer_id = c.customer_id);" |
powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1
```

Expected shape:

```sql
SELECT C.CUSTOMER_ID
  FROM CUSTOMER C
 WHERE EXISTS (SELECT 1
                 FROM ORDER_HEADER O
                WHERE O.CUSTOMER_ID = C.CUSTOMER_ID);
```

### Full example test

```powershell
Get-Content .\examples\sample-db2.sql -Raw |
powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1 |
Set-Content .\examples\sample-db2-output.sql -Encoding UTF8
```

---

## Troubleshooting

### DBeaver formats nothing

Check that DBeaver points to the real formatter:

```text
format-sql.ps1
```

Not an old wrapper or copied script.

From repo root:

```powershell
Select-String -Path .\format-sql.ps1 -Pattern "FORMAT EVERYTHING"
```

You should see:

```text
FORMAT EVERYTHING
```

### `format-file.ps1` gives old output

Your `format-file.ps1` may still contain an embedded old formatter.

Use this direct command instead:

```powershell
Get-Content .\examples\sample-db2.sql -Raw |
powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1 |
Set-Content .\examples\sample-db2-output.sql -Encoding UTF8
```

Then update `format-file.ps1` later so it calls `format-sql.ps1`.

### Comments break formatting

SQLFMT protects comments internally and restores them later.

Test with:

```powershell
"select c.customer_id, -- comment
c.customer_name from customer c where c.is_active = 1 and -- comment
exists (select 1 from order_header o where o.customer_id = c.customer_id);" |
powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1
```

### Timer appears in the terminal

That is expected.

SQL is written to `stdout`.

Runtime info is written to `stderr`:

```text
SQLFMT completed in 1.234 seconds
```

This keeps redirected SQL output clean.

### DBeaver command does not run

Use command:

```text
powershell
```

Arguments:

```text
-NoProfile -ExecutionPolicy Bypass -File "C:\path\to\dbeaver-sql-formatter\format-sql.ps1"
```

Check the path carefully.

### PowerShell blocks execution

Run from the repo root:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Or keep using:

```powershell
-ExecutionPolicy Bypass
```

in the DBeaver command.

---

## Performance Notes

The formatter currently favors correctness and recursive formatting over speed.

Typical observed timings during development:

| Query type | Expected behavior |
|---|---|
| Simple SELECT | Fast |
| Nested CTE / MERGE | Slower |
| Large procedure/function | Slower |
| Full stress-test script | Can take several seconds |

Performance optimization is a future step. The most important rule for now is:

> Correct formatting first. Speed later.

---

## Development Notes

The formatter is intentionally built around a few simple ideas:

| Area | Rule |
|---|---|
| Strings | Protect before formatting |
| Comments | Protect and restore as text |
| Statement splitting | Split on top-level semicolons |
| Nested SQL | Call the same formatter recursively |
| SELECT layout | Same grid everywhere |
| Unsafe input | Do not guess too much |

Avoid broad “repair missing spaces before keywords” logic. It can corrupt identifiers such as:

```text
VALID_FROM
```

into invalid tokens.

---

## Commit Checklist

Before committing:

- [ ] Run the smoke test.
- [ ] Run the nested SELECT test.
- [ ] Format `examples/sample-db2.sql`.
- [ ] Check `examples/sample-db2-output.sql`.
- [ ] Test DBeaver external formatter.
- [ ] Confirm comments do not swallow SQL.
- [ ] Confirm procedures/functions stay intact.
- [ ] Confirm `format-file.ps1` and `format.ps1` call the correct formatter.
- [ ] Commit everything together.

Suggested commit message:

```text
Finalize format-everything DB2 SQL formatter
```

---

## Recommended Final Flow

```text
DBeaver / PowerShell / sqlfmt
        ↓
format-sql.ps1
        ↓
formatted SQL to stdout
        ↓
DBeaver editor or output file
```

One formatter. One source of truth. One predictable grid.
