# DB2 SQL Formatter (`format-sql.ps1`)

`format-sql.ps1` is a standalone PowerShell script for formatting DB2 SQL scripts into a consistent, readable style.

It was written from the DB2 SQL formatter specification supplied with this project. The formatter is intentionally conservative: it focuses on improving whitespace, indentation, clause layout, keyword casing, semicolon handling, and common DB2 statement structure while preserving SQL meaning.

---

## Table of contents

- [What this script does](#what-this-script-does)
- [Design goals](#design-goals)
- [Requirements](#requirements)
- [Files](#files)
- [Quick start](#quick-start)
- [Command-line usage](#command-line-usage)
- [Parameters](#parameters)
- [Examples](#examples)
- [Using it from DBeaver](#using-it-from-dbeaver)
- [Formatting behavior](#formatting-behavior)
- [How the formatter works internally](#how-the-formatter-works-internally)
- [Supported SQL areas](#supported-sql-areas)
- [Known limitations](#known-limitations)
- [Safety and preservation rules](#safety-and-preservation-rules)
- [Troubleshooting](#troubleshooting)
- [Recommended test workflow](#recommended-test-workflow)
- [Future improvement ideas](#future-improvement-ideas)

---

## What this script does

The formatter reads DB2 SQL from one of three sources:

1. A SQL file passed with `-Path`.
2. Raw SQL text passed with `-LiteralSql`.
3. Pipeline input.

It then produces formatted SQL by applying DB2-oriented layout rules, including:

- replacing tabs with spaces;
- using two-space indentation;
- adding missing statement semicolons where appropriate;
- preserving DB2 custom statement terminators such as `--#SET TERMINATOR @`;
- preserving comments;
- preserving string literals;
- preserving quoted identifiers;
- preserving host variables such as `:host_id`;
- preserving parameter markers such as `?`;
- formatting common DB2 SQL statements into readable multi-line layouts;
- keeping short statements compact when possible;
- applying DB2 function-call spacing such as `COUNT (*)`, `DECIMAL (amount, 15, 2)`, and `ROW_NUMBER ()`.

The script can write formatted SQL to stdout, to a separate output file, or back into the input file in place.

---

## Design goals

The implementation follows these priorities:

### 1. Preserve SQL meaning

The formatter should never intentionally change what the SQL does. It should only change layout-related details such as spaces, line breaks, indentation, and keyword casing outside protected regions.

### 2. Be conservative around protected text

The formatter does not rewrite the inside of:

- single-quoted string literals;
- double-quoted identifiers;
- line comments;
- block comments;
- host variables;
- DB2 parameter markers.

This is important because SQL-looking text can legally appear inside strings or comments and should not be treated as executable SQL.

### 3. Work without external dependencies

The script is pure PowerShell. It does not require Node.js, Python, Java, npm packages, NuGet packages, or third-party SQL formatter binaries.

### 4. Be useful from editors and automation

The script supports in-place formatting and file-based input/output, which makes it suitable for editor integrations such as DBeaver external formatter configuration.

### 5. Prefer readability over aggressive rewriting

The script does not attempt to fully parse every DB2 grammar edge case. Instead, it tokenizes SQL and applies practical statement-aware formatting rules.

---

## Requirements

### Runtime

- Windows PowerShell 5.1 or PowerShell 7+

PowerShell 7+ is recommended for modern cross-platform use, but the script is written to avoid unnecessary dependencies.

### Operating systems

The script can be used on:

- Windows
- macOS
- Linux

On Windows, invoke it with either `powershell.exe` or `pwsh.exe`.

On macOS/Linux, invoke it with `pwsh`.

---

## Files

Expected project files:

```text
format-sql.ps1    # The formatter script
README.md         # This documentation file
```

Optional files you may create while testing:

```text
input.sql         # Unformatted SQL
output.sql        # Formatted SQL
```

---

## Quick start

Format a SQL file and print the result to the terminal:

```powershell
.\format-sql.ps1 -Path .\input.sql
```

Format a SQL file and write the result to another file:

```powershell
.\format-sql.ps1 -Path .\input.sql -OutputPath .\output.sql
```

Format a SQL file in place:

```powershell
.\format-sql.ps1 -Path .\input.sql -InPlace
```

Format raw SQL text:

```powershell
.\format-sql.ps1 -LiteralSql "select col1,col2 from schema.table where status='A'"
```

Format SQL from the pipeline:

```powershell
Get-Content .\input.sql -Raw | .\format-sql.ps1
```

---

## Command-line usage

General form:

```powershell
.\format-sql.ps1 [-Path <file>] [-OutputPath <file>] [-InPlace] [-MaxLineLength <number>] [-Encoding <encoding>]
```

Alternative literal input form:

```powershell
.\format-sql.ps1 -LiteralSql <sql-text> [-OutputPath <file>] [-MaxLineLength <number>] [-Encoding <encoding>]
```

Pipeline form:

```powershell
<sql text> | .\format-sql.ps1 [-OutputPath <file>] [-MaxLineLength <number>] [-Encoding <encoding>]
```

---

## Parameters

### `-Path`

Input SQL file path.

Use this when you want the script to read SQL from a file.

Example:

```powershell
.\format-sql.ps1 -Path .\input.sql
```

---

### `-LiteralSql`

Raw SQL text to format.

Use this when SQL is generated by another command or supplied directly as a string.

Example:

```powershell
.\format-sql.ps1 -LiteralSql "SELECT col1 FROM schema.table"
```

---

### `-OutputPath`

File path where formatted SQL should be written.

If omitted, the formatted SQL is written to stdout unless `-InPlace` is used.

Example:

```powershell
.\format-sql.ps1 -Path .\input.sql -OutputPath .\formatted.sql
```

---

### `-InPlace`

Overwrites the input file with the formatted SQL.

`-InPlace` requires `-Path`.

Example:

```powershell
.\format-sql.ps1 -Path .\input.sql -InPlace
```

Use this carefully. For important scripts, keep the file under source control or create a backup before running in-place formatting.

---

### `-MaxLineLength`

Preferred maximum line length.

Default:

```text
120
```

Valid range:

```text
40 to 400
```

Example:

```powershell
.\format-sql.ps1 -Path .\input.sql -MaxLineLength 100
```

The formatter uses this as a layout target for wrapping common expressions and lists. It is not a full formal proof that every possible line in every possible DB2 statement will be below the limit, especially when a single unbreakable token is longer than the margin.

---

### `-Encoding`

Controls file read/write encoding.

Supported values:

```text
UTF8
UTF8BOM
Unicode
BigEndianUnicode
ASCII
OEM
```

Default:

```text
UTF8
```

Example:

```powershell
.\format-sql.ps1 -Path .\input.sql -OutputPath .\output.sql -Encoding UTF8BOM
```

---

## Examples

### Example 1: Basic SELECT formatting

Input:

```sql
select col1,col2 from schema.table where status='A'
```

Command:

```powershell
.\format-sql.ps1 -Path .\input.sql
```

Typical output:

```sql
SELECT col1, col2
  FROM schema.table
 WHERE status = 'A';
```

---

### Example 2: In-place formatting

```powershell
.\format-sql.ps1 -Path .\script.sql -InPlace
```

This reads `script.sql`, formats it, and writes the formatted result back to `script.sql`.

---

### Example 3: Write to a new file

```powershell
.\format-sql.ps1 -Path .\script.sql -OutputPath .\script.formatted.sql
```

This leaves the original file untouched.

---

### Example 4: Pipeline use

```powershell
Get-Content .\script.sql -Raw | .\format-sql.ps1 | Set-Content .\script.formatted.sql
```

This is useful when integrating with other shell commands.

---

### Example 5: Custom line length

```powershell
.\format-sql.ps1 -Path .\script.sql -OutputPath .\formatted.sql -MaxLineLength 100
```

This asks the formatter to prefer a 100-character margin instead of the default 120-character margin.

---

## Using it from DBeaver

DBeaver can call external formatters by passing the currently selected SQL or editor contents through a temporary file.

The important part is that the formatter must read DBeaver's temporary file and write the formatted SQL back to that same file. That is what `-Path "${file}" -InPlace` does.

### Recommended Windows command using Windows PowerShell

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\format-sql.ps1" -Path "${file}" -InPlace
```

### Recommended Windows command using PowerShell 7

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\format-sql.ps1" -Path "${file}" -InPlace
```

### Recommended macOS/Linux command

```bash
pwsh -NoProfile -File "/path/to/format-sql.ps1" -Path "${file}" -InPlace
```

### DBeaver setup checklist

1. Save `format-sql.ps1` in a stable location, for example:

   ```text
   C:\Tools\format-sql.ps1
   ```

2. Open DBeaver preferences.

3. Go to the SQL editor formatting settings.

4. Choose the external formatter option.

5. Enable the option that uses a temporary file.

6. Paste the command above, adjusted to your real script path.

7. Open a SQL editor, select SQL, and run DBeaver's format action.

### Important DBeaver note

This does not install the script as a native DBeaver plugin. It configures DBeaver to call the PowerShell script as an external formatter.

That is usually the simplest and most maintainable integration method for a `.ps1` formatter.

---

## Formatting behavior

### Tabs and indentation

The formatter never intentionally emits tab characters.

Tabs in the input are normalized to spaces.

Indentation uses two spaces per level.

---

### Semicolons

Complete statements should end with a semicolon.

If a normal statement is missing a semicolon, the formatter attempts to add one.

Example:

```sql
SELECT col1
  FROM schema.table;
```

---

### Custom DB2 terminators

DB2 scripts often use custom terminators for routines and triggers, for example:

```sql
--#SET TERMINATOR @

CREATE PROCEDURE schema.p1 ()
LANGUAGE SQL
BEGIN
  SET v_value = 1;
END@

--#SET TERMINATOR ;
```

The formatter recognizes terminator directives and uses the active terminator while splitting statements.

Inner compound-SQL statements can still use semicolons inside a larger routine body.

---

### Function-call spacing

The formatter follows the project's DB2 style of placing one space before function-call parentheses.

Examples:

```sql
COUNT (*)
MAX (amount)
DECIMAL (amount, 15, 2)
ROW_NUMBER ()
COALESCE (NULLIF (TRIM (name), ''), 'UNKNOWN')
```

---

### SELECT statements

The formatter handles common `SELECT` structures, including:

- `SELECT` lists;
- `FROM`;
- `WHERE`;
- `GROUP BY`;
- `HAVING`;
- `ORDER BY`;
- `OFFSET`;
- `FETCH FIRST`;
- `LIMIT`;
- `WITH UR`;
- joins;
- subqueries;
- CTEs;
- set operators such as `UNION`, `INTERSECT`, and `EXCEPT`.

Typical output:

```sql
SELECT col1, col2
  FROM schema.table
 WHERE status = 'A';
```

---

### INSERT, UPDATE, DELETE, and MERGE

The formatter includes statement-aware handlers for common DML forms:

```sql
INSERT INTO schema.table
       (col1, col2, col3)
VALUES (1, 'A', CURRENT DATE);
```

```sql
UPDATE schema.table
   SET col1 = 'A',
       col2 = CURRENT DATE
 WHERE id = 1;
```

```sql
DELETE FROM schema.table
 WHERE id = 1;
```

```sql
MERGE INTO schema.target_table t
USING schema.source_table s
   ON t.id = s.id
 WHEN MATCHED THEN
      UPDATE
         SET t.col1 = s.col1
 WHEN NOT MATCHED THEN
      INSERT (id, col1)
      VALUES (s.id, s.col1);
```

---

### CREATE statements

CREATE statements are treated more simply than SELECT-style statements.

This follows the project rule that DDL bodies should use simple two-space indentation rather than heavy right alignment.

Examples of CREATE families handled include:

- `CREATE TABLE`
- `CREATE VIEW`
- `CREATE ALIAS`
- `CREATE INDEX`
- `CREATE SEQUENCE`
- `CREATE PROCEDURE`
- `CREATE FUNCTION`
- `CREATE TRIGGER`
- `CREATE ROLE`
- `CREATE VARIABLE`
- `CREATE TYPE`
- `CREATE MODULE`
- `CREATE MASK`
- `CREATE PERMISSION`

---

### Comments

The formatter preserves comments and tries to keep them near their original logical syntax.

Supported comment forms:

```sql
-- line comment
```

```sql
/* block comment */
```

The formatter does not intentionally move comments across unrelated clauses.

---

### Strings and quoted identifiers

The formatter does not format SQL-looking content inside string literals.

Example:

```sql
WHERE text_col = 'SELECT * FROM TABLE WHERE X = 1'
```

The formatter also does not uppercase or split quoted identifiers.

Example:

```sql
SELECT "Customer ID"
  FROM "My Schema"."Customer Table";
```

---

### Host variables and parameter markers

Host variables are preserved:

```sql
WHERE id = :host_id
```

Parameter markers are preserved:

```sql
WHERE id = ?
```

The formatter does not treat `:host_id` as a label and does not treat `?` as invalid syntax.

---

## How the formatter works internally

The script is organized around a small formatting pipeline.

### 1. Normalize input

The script normalizes line endings and replaces tab characters with spaces.

This ensures later formatting logic works from a predictable text representation.

### 2. Tokenize SQL

The script scans the SQL into tokens.

Tokenization is important because pure regular-expression formatting is too risky for SQL. For example, the word `SELECT` can appear in an actual query, in a string literal, in a comment, or inside a quoted identifier. Those cases must be treated differently.

The tokenizer recognizes major token kinds such as:

- words and keywords;
- numbers;
- string literals;
- quoted identifiers;
- line comments;
- block comments;
- symbols;
- operators;
- host variables;
- parameter markers.

### 3. Split the script into statements

After tokenization, the formatter splits the script into statements.

This split is terminator-aware, meaning it can handle DB2 custom terminators such as `@` when a script contains directives like:

```sql
--#SET TERMINATOR @
```

### 4. Detect statement type

The formatter inspects the leading tokens of each statement and chooses a formatter for the statement family.

Examples:

- `SELECT` uses the SELECT formatter.
- `WITH` uses CTE-aware formatting when appropriate.
- `INSERT` uses INSERT formatting.
- `UPDATE` uses UPDATE formatting.
- `DELETE` uses DELETE formatting.
- `MERGE` uses MERGE formatting.
- `CREATE` uses CREATE formatting.
- Unknown or less common statements fall back to generic formatting.

### 5. Format expressions and lists

The script contains helpers for expression joining and comma-list splitting.

The list splitter is depth-aware, so it avoids splitting commas inside nested parentheses such as function calls, `IN` lists, row values, and subqueries.

### 6. Emit lines

Formatted lines are emitted through a central helper that enforces the no-tabs rule and applies two-space indentation.

This central output path helps keep the formatting rules consistent.

---

## Supported SQL areas

The script is designed to handle the major SQL areas from the project specification, including:

- `SELECT`
- `WITH` CTE queries
- `VALUES`
- `INSERT`
- `UPDATE`
- `DELETE`
- `MERGE`
- `CALL`
- `SET`
- `DECLARE`
- `OPEN`
- `FETCH`
- `CLOSE`
- `PREPARE`
- `EXECUTE`
- `EXECUTE IMMEDIATE`
- `COMMIT`
- `ROLLBACK`
- `SAVEPOINT`
- `SIGNAL`
- `RESIGNAL`
- `GET DIAGNOSTICS`
- `CREATE` statement families
- `ALTER` statement families
- `DROP` statement families
- `RENAME`
- `COMMENT ON`
- `LABEL ON`
- `GRANT`
- `REVOKE`
- `TRUNCATE TABLE`
- `LOCK TABLE`
- compound SQL control statements such as `BEGIN`, `IF`, `LOOP`, `WHILE`, `FOR`, and `CASE`

For less common or highly unusual DB2 syntax, the script falls back to generic formatting rather than failing outright.

---

## Known limitations

This formatter is a practical, statement-aware formatter. It is not a complete DB2 compiler or full formal DB2 grammar parser.

Known limitations include:

1. Extremely complex or unusual DB2 syntax may fall back to generic formatting.
2. Some long lines may remain long when they contain unbreakable tokens or deeply nested expressions.
3. The script aims to preserve comments near their syntax, but comment placement in highly unusual input may not be perfect.
4. The formatter does not format SQL inside string literals by default.
5. Dynamic SQL string formatting is intentionally not implemented by default because it can change application behavior if done incorrectly.
6. Semantic validation is out of scope. The script formats SQL text; it does not verify that DB2 will execute the SQL successfully.
7. The formatter does not connect to a DB2 database and does not inspect database metadata.
8. Vendor-specific or site-specific SQL macros may be formatted generically.

These limitations are intentional tradeoffs to preserve SQL meaning and keep the tool safe for day-to-day formatting.

---

## Safety and preservation rules

Before using in-place formatting on important scripts, use source control or create a backup.

Recommended safe workflow:

```powershell
Copy-Item .\script.sql .\script.sql.bak
.\format-sql.ps1 -Path .\script.sql -InPlace
```

Or write to a separate file first:

```powershell
.\format-sql.ps1 -Path .\script.sql -OutputPath .\script.formatted.sql
```

Then compare:

```powershell
Compare-Object `
  (Get-Content .\script.sql) `
  (Get-Content .\script.formatted.sql)
```

For repository usage, review the diff before committing.

---

## Troubleshooting

### PowerShell says script execution is disabled

On Windows, PowerShell execution policy may block local scripts.

For one-time execution, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\format-sql.ps1" -Path "C:\path\input.sql"
```

This bypasses the policy for that process only.

---

### DBeaver does not change the SQL after formatting

Check the following:

1. The DBeaver command points to the real script path.
2. The command includes `-Path "${file}" -InPlace`.
3. DBeaver's external formatter is configured to use a temporary file.
4. PowerShell is available on the system path.
5. The script can be run manually from a terminal.

Manual test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\format-sql.ps1" -Path "C:\Temp\test.sql" -InPlace
```

---

### The command works in terminal but not in DBeaver

This is usually a quoting or path issue.

Prefer quoting both the script path and `${file}`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\format-sql.ps1" -Path "${file}" -InPlace
```

If your script path contains spaces, quotes are required.

---

### Characters look wrong after formatting

Specify an encoding explicitly.

Example:

```powershell
.\format-sql.ps1 -Path .\input.sql -OutputPath .\output.sql -Encoding UTF8BOM
```

If your existing tooling expects UTF-8 with BOM, use `UTF8BOM`.

---

### A statement is not formatted exactly as expected

The formatter may have fallen back to generic formatting for that statement.

Recommended debugging steps:

1. Isolate the smallest SQL sample that reproduces the issue.
2. Format that sample by itself.
3. Compare the output against the desired style.
4. Add or adjust a statement-specific formatting rule in the script.

---

## Recommended test workflow

Use a small test folder:

```text
tests/
  input/
    simple-select.sql
    create-procedure.sql
    merge.sql
  expected/
    simple-select.sql
    create-procedure.sql
    merge.sql
  actual/
```

Run formatting:

```powershell
.\format-sql.ps1 -Path .\tests\input\simple-select.sql -OutputPath .\tests\actual\simple-select.sql
```

Compare actual output to expected output:

```powershell
Compare-Object `
  (Get-Content .\tests\expected\simple-select.sql) `
  (Get-Content .\tests\actual\simple-select.sql)
```

For larger usage, add test cases for:

- simple `SELECT`;
- long `SELECT` lists;
- joins;
- nested subqueries;
- CTEs;
- `INSERT SELECT`;
- `UPDATE` with subquery;
- `MERGE`;
- `CREATE PROCEDURE`;
- custom terminator scripts;
- comments;
- string literals containing SQL-looking text;
- quoted identifiers;
- host variables;
- parameter markers.

---

## Future improvement ideas

Possible future enhancements:

1. Add a formal test suite with golden input/output files.
2. Add a `-Check` mode that exits non-zero when a file is not already formatted.
3. Add a `-Diff` mode for CI pipelines.
4. Add optional dynamic-SQL-string formatting.
5. Add more DB2-specific grammar recognition for advanced DDL.
6. Add formatter configuration through a `.db2formatter.json` file.
7. Add a native DBeaver plugin wrapper around the script.
8. Add richer logging with a `-Verbose` mode for formatting decisions.
9. Add a `-KeywordCase` parameter, for example `Upper`, `Lower`, or `Preserve`.
10. Add a `-Backup` switch for automatic `.bak` files during in-place formatting.

---

## Summary

`format-sql.ps1` is a dependency-free, PowerShell-based DB2 SQL formatter designed for practical daily use.

It provides:

- safe token-aware formatting;
- two-space indentation;
- no tabs;
- DB2 function-call spacing;
- statement terminator handling;
- DBeaver external formatter compatibility;
- file, literal, and pipeline input modes;
- stdout, output-file, and in-place output modes.

It is intentionally conservative so that formatting improves readability without changing SQL meaning.