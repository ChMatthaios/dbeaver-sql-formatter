# DBeaver SQL Formatter

A PowerShell-based SQL formatter focused on DB2 SQL and DBeaver integration.

The project has one core rule:

```text
format-sql.ps1 is the formatter engine.
Everything else is a wrapper, runner, helper, or UI around it.
```

The formatter reads SQL from **stdin** and writes formatted SQL to **stdout**. That makes it usable from DBeaver, PowerShell, and file runners.

---

## Current status

This project is working and actively improving.

The formatter is heuristic. It is **not** a full DB2 parser. The goal is to format practical DB2 SQL consistently while avoiding destructive changes to the developer's query.

Current formatting principles:

1. Format `SELECT` statements consistently.
2. Format nested `SELECT` statements like top-level `SELECT` statements, only with extra left indentation.
3. Reuse the same SELECT formatting inside CTEs, subqueries, `MERGE USING (SELECT ...)`, `CREATE VIEW AS SELECT`, cursors, procedures, and functions where possible.
4. Treat comments as normal visible text.
5. Preserve comment line boundaries. SQL that was on the line after a comment must stay on the line after the comment.
6. Format `CASE / WHEN / ELSE / END` blocks consistently.
7. Align `AND` / `OR` conditions predictably.
8. Align CTE inner SELECT columns with the first SELECT column.
9. Align JOIN clauses with the SELECT body clause column.
10. If the formatter does not understand something safely, it should avoid destroying the query.

---

## Project structure

```text
dbeaver-sql-formatter/
├─ .gitignore
├─ README.md
├─ format-sql.ps1
├─ format.ps1
├─ format-file.ps1
├─ scripts/
│  └─ install-sqlfmt-command.ps1
├─ examples/
│  └─ sample-db2.sql
├─ tests/
└─ tests_out/
```

### Important files

| File | Purpose |
|---|---|
| `format-sql.ps1` | The actual formatter engine. DBeaver, CLI, and file runner, should all call this. |
| `format.ps1` | Development/test runner. Used for `-list`, `-runall`, `-check`, and test file formatting. |
| `format-file.ps1` | File-based runner for formatting a `.sql` file directly. |
| `scripts/install-sqlfmt-command.ps1` | Optional installer for a PowerShell command named `sqlfmt`. |
| `tests/` | Regression test input SQL files. |
| `tests_out/` | Expected formatted outputs for regression checks. |

---

## Architecture / flow

### DBeaver flow

```text
DBeaver selected SQL
        ↓ stdin
format-sql.ps1
        ↓ stdout
DBeaver replaces selected SQL
```

### File formatting flow

```text
input.sql
   ↓
format-file.ps1
   ↓ calls
format-sql.ps1
   ↓
output.sql
```

### Test flow

```text
tests/*.sql
   ↓
format.ps1 -check / -runall
   ↓ calls
format-sql.ps1
   ↓
tests_out/*.out.sql
```

---

## Requirements

- Windows
- Windows PowerShell
- DBeaver, if using the DBeaver integration
- Git, if contributing/pushing changes

---

## Basic command-line usage

From the repository root:

```powershell
.\format.ps1 -help
```

List available test files:

```powershell
.\format.ps1 -list
```

Format all test inputs and regenerate outputs:

```powershell
.\format.ps1 -runall
```

Check formatter output against expected output:

```powershell
.\format.ps1 -check
```

Format one matching test file:

```powershell
.\format.ps1 -file 01
```

or:

```powershell
.\format.ps1 -file 04_complicated_multiline_statements.sql
```

---

## Formatting a SQL file

Use `format-file.ps1` for normal file-based formatting.

Print formatted SQL to the terminal:

```powershell
.\format-file.ps1 .\input.sql
```

Write formatted SQL to another file:

```powershell
.\format-file.ps1 .\input.sql -OutFile .\output.sql
```

Replace the input file with formatted SQL:

```powershell
.\format-file.ps1 .\input.sql -InPlace
```

Show help:

```powershell
.\format-file.ps1 -help
```

---

## Optional `sqlfmt` command

You can install a convenient PowerShell command named `sqlfmt`.

From the repository root:

```powershell
.\scripts\install-sqlfmt-command.ps1
```

If PowerShell blocks script execution:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-sqlfmt-command.ps1
```

Close and reopen PowerShell after installation.

Then use:

```powershell
sqlfmt --list
sqlfmt --check
sqlfmt --runall
sqlfmt --file 01
sqlfmt --help
```

Avoid using a generic command named `format` in public documentation. It may conflict with existing commands, aliases, or user-defined functions. Use `sqlfmt`.

---

## DBeaver setup

The formatter is designed to work as an external formatter in DBeaver.

### 1. Open DBeaver preferences

In DBeaver, go to:

```text
Window → Preferences
```

Then open:

```text
Editors → SQL Editor → SQL Formatting
```

Depending on your DBeaver version, the wording may differ slightly, but SQL formatter settings are under SQL Editor preferences.

### 2. Choose external formatter

Configure DBeaver to use an external formatter command.

Use PowerShell and point directly to `format-sql.ps1`.

Command shape:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "FULL_PATH_TO_REPOSITORY\format-sql.ps1"
```

Example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\dbeaver-sql-formatter\format-sql.ps1"
```

Replace:

```text
C:\Path\To\dbeaver-sql-formatter
```

with the actual repository path on your machine.

Do **not** commit personal Windows paths to the repository.

### 3. Apply and save

Click:

```text
Apply and Close
```

### 4. Format SQL in DBeaver

Use:

```text
Ctrl + Shift + F
```

DBeaver formats either:

- the selected SQL text, or
- the SQL statement/query where the cursor currently is.

For reliable results with large CTEs or multi-statement scripts, select the full query before formatting.

---

## DBeaver troubleshooting

DBeaver should call:

```text
format-sql.ps1
```

not:

```text
format.ps1
format-file.ps1
```

### PowerShell blocks the formatter

Run:

```powershell
Unblock-File .\format-sql.ps1
```

or call it with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1
```

### Extra blank lines appear after repeated formatting

The formatter should not force an extra trailing newline. The final return in `format-sql.ps1` should avoid adding blank lines repeatedly when DBeaver formats only the current statement.

---

## Formatting behavior notes

### CTEs

CTE inner `SELECT` lists should align as if the inner `SELECT` starts normally, with only the parent CTE indentation added.

Target shape:

```sql
WITH PAY_ENRICH
  AS ( SELECT P.MSR_PRD_ID,
              P."YEAR",
              P."MONTH",
              P.OPER_DT
         FROM SOME_TABLE P
         LEFT JOIN OTHER_TABLE X ON X.ID = P.ID
     )
SELECT *
  FROM PAY_ENRICH
 WITH UR;
```

### Comments

Comments are treated as normal visible text.

A comment line must remain a line in the query.

Valid shape:

```sql
SELECT A.ID,
       -- Explanation for the next column.
       CAST('-200' AS CHAR(20)) AS MSG_TP_CD,
       CASE
         WHEN A.FLAG = 'Y' THEN 1 -- inline comment
         ELSE 0
       END AS IS_ACTIVE
  FROM ACCOUNT A
 WITH UR;
```

The formatter must not produce:

```sql
-- Explanation for the next column. CAST('-200' AS CHAR(20)) AS MSG_TP_CD
```

because that makes SQL appear after the comment.

### CASE expressions

CASE blocks should be formatted consistently:

```sql
CASE
  WHEN CONDITION_1 THEN VALUE_1
  WHEN CONDITION_2 THEN VALUE_2
  ELSE VALUE_3
END AS SOME_ALIAS
```

Nested CASE expressions inside aggregate functions should preserve readable indentation:

```sql
SUM(CASE
      WHEN CONDITION_1 THEN AMOUNT
      ELSE 0
    END) AS TOTAL_AMOUNT
```

### WHERE alignment

Logical operators should align predictably:

```sql
 WHERE A.STATUS = 'OPEN'
   AND A.TYPE <> 'TEST'
    OR A.TYPE IS NULL
```

`AND` and `OR` use different leading spaces so the condition text aligns.

### JOIN alignment

JOIN clauses should align with the SELECT body clause column:

```sql
  FROM SOME_TABLE A
  LEFT JOIN OTHER_TABLE B ON B.ID = A.ID
 INNER JOIN THIRD_TABLE C ON C.ID = A.ID
```

For nested queries, the same layout applies with added left indentation.

---

## Test workflow

Before changing formatter logic:

```powershell
git status
```

Run the regression check:

```powershell
.\format.ps1 -check
```

After changing formatter behavior, inspect output carefully.

If the behavior change is intentional, regenerate expected outputs:

```powershell
.\format.ps1 -runall
```

Then run:

```powershell
.\format.ps1 -check
```

Review changes:

```powershell
git diff
```

Commit:

```powershell
git add .
git commit -m "Describe the formatter change"
git push
```

---

## Recommended development process

Keep changes small.

Each formatter change should target one bug:

1. Identify the smallest failing SQL block.
2. Add or update a test.
3. Patch only the relevant function.
4. Run `.\format.ps1 -check`.
5. Review output manually.
6. Commit only when the output is better.

Avoid large rewrites unless they are done on a separate branch.

---

## Public repository hygiene

Before pushing to GitHub, avoid committing:

- personal Windows paths,
- usernames,
- passwords,
- API keys,
- tokens,
- real connection strings,
- private company SQL,
- local scratch files,
- generated temporary outputs.

Useful scan commands:

```powershell
Get-ChildItem -Recurse -File | Select-String -Pattern "C:\\Users\\"
```

```powershell
Get-ChildItem -Recurse -File | Select-String -Pattern "password|passwd|pwd|secret|apikey|api_key|connectionstring|connection string|server=|user id=|uid=|trusted_connection"
```

Generated local outputs such as:

```text
*.formatted.sql
```

should usually stay out of commits unless they are intentionally part of tests.

---

## Suggested `.gitignore` entries

```gitignore
# Generated formatter outputs
*.formatted.sql

# Temporary files
*.tmp
*.bak

# PowerShell temporary/debug files
*.ps1xml.tmp

# Local editor files
.vscode/
.idea/
```

Add exceptions if you intentionally want to commit editor configuration.

---

## Roadmap

Planned next steps:

1. Stabilize formatter behavior around real DB2 CTEs, comments, CASE expressions, and WHERE alignment.
2. Add regression tests for each bug fixed.
3. Improve DBeaver setup documentation with screenshots.
4. Add formatting options only after the default formatter behavior is stable.
5. Consider a packaged desktop app later, after the formatter core is reliable.

---

## License / Usage

This project is publicly visible for personal use and evaluation.

You may:

- clone the repository for personal use,
- run the formatter locally,
- use it with DBeaver or other local tools.

You may not:

- redistribute this project,
- publish modified versions,
- package or sell it,
- claim it as your own,
- use the code in another public or commercial project without permission.

All rights reserved unless explicit written permission is granted by the author.