# DBeaver SQL Formatter

A PowerShell-based DB2 SQL formatter designed mainly for **DBeaver external formatter usage**.

Core rule:

```text
format-sql.ps1 is the formatter engine.
Everything else is a wrapper, runner, installer, or test helper around it.
```

The formatter reads SQL from **stdin** and writes formatted SQL to **stdout**, which makes it usable from DBeaver, PowerShell, file runners, and the optional `sqlfmt` command.

---

## What this project does

This project formats practical DB2 SQL with a consistent style. It is heuristic, not a full DB2 parser, so the formatter should prefer safe formatting over aggressive rewriting. If it cannot understand something safely, it should avoid destroying the query.

Main goals:

- format selected SQL directly inside DBeaver,
- format `.sql` files from PowerShell,
- support tests and regression checks,
- support optional user preferences,
- keep comments and strings safe,
- recursively format CTEs, subqueries, joins, and DB2 SQL patterns where possible.

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
├─ settings/
│  └─ settings.example.json
├─ tests/
└─ tests_out/
```

Important files:

| File | Purpose |
|---|---|
| `format-sql.ps1` | Actual formatter engine. DBeaver should call this directly. |
| `format.ps1` | Test/development runner. |
| `format-file.ps1` | Formats real `.sql` files. |
| `scripts/install-sqlfmt-command.ps1` | Optional installer for the `sqlfmt` command. |
| `tests/` | Input regression tests. |
| `tests_out/` | Expected formatted outputs. |
| `settings/settings.json` | Local user preferences. Usually ignored by Git. |
| `settings/settings.example.json` | Example/default preferences. Safe to commit. |

---

## Architecture

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
formatted output / output file
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

### Optional `sqlfmt` flow

```text
sqlfmt --check / --runall / --file ...
   ↓
format.ps1 / format-file.ps1
   ↓
format-sql.ps1
```

---

## Requirements

- Windows
- Windows PowerShell
- DBeaver, for editor integration
- Git, for development workflow

---

## Quick start

Clone the repository:

```powershell
git clone https://github.com/ChMatthaios/dbeaver-sql-formatter.git
cd dbeaver-sql-formatter
```

Run the test check:

```powershell
.\format.ps1 -check
```

List test files:

```powershell
.\format.ps1 -list
```

Regenerate all expected outputs:

```powershell
.\format.ps1 -runall
```

---

## DBeaver setup

### 1. Open SQL formatter settings

In DBeaver:

```text
Window → Preferences → Editors → SQL Editor → SQL Formatting
```

The exact wording may differ slightly depending on the DBeaver version.

### 2. Configure external formatter

Use PowerShell and point directly to `format-sql.ps1`.

Command shape:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "FULL_PATH_TO_REPOSITORY\format-sql.ps1"
```

Example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\dbeaver-sql-formatter\format-sql.ps1"
```

Replace `C:\Path\To\dbeaver-sql-formatter` with your actual local path.

Do not commit personal Windows paths to the repository.

### 3. Format SQL in DBeaver

Use:

```text
Ctrl + Shift + F
```

DBeaver formats either the selected text or the query where the cursor currently is. For large CTEs, subqueries, procedures, or multi-statement scripts, select the full query before formatting.

---

## Direct formatter usage

`format-sql.ps1` reads from stdin and writes to stdout.

```powershell
Get-Content .\input.sql -Raw | powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1
```

Save output:

```powershell
Get-Content .\input.sql -Raw |
  powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1 |
  Set-Content .\output.sql
```

For normal file usage, prefer `format-file.ps1`.

---

## File formatting usage

Show help:

```powershell
.\format-file.ps1 -help
```

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

---

## Test runner usage

Show help:

```powershell
.\format.ps1 -help
```

List test files:

```powershell
.\format.ps1 -list
```

Regenerate all outputs:

```powershell
.\format.ps1 -runall
```

Check outputs:

```powershell
.\format.ps1 -check
```

Format one matching test:

```powershell
.\format.ps1 -file 01
```

or:

```powershell
.\format.ps1 -file 04_complicated_multiline_statements.sql
```

---

## Optional `sqlfmt` command

The project includes an optional helper script that installs a command named:

```text
sqlfmt
```

This lets users run formatter/test commands without typing the full script path.

### Install `sqlfmt`

From the repository root:

```powershell
.\scripts\install-sqlfmt-command.ps1
```

If PowerShell blocks it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-sqlfmt-command.ps1
```

Close and reopen PowerShell after installation.

### Verify installation

```powershell
Get-Command sqlfmt
```

Expected:

```text
CommandType     Name
-----------     ----
Function        sqlfmt
```

### `sqlfmt` usage

Show help:

```powershell
sqlfmt --help
```

List test files:

```powershell
sqlfmt --list
```

Run all tests and regenerate outputs:

```powershell
sqlfmt --runall
```

Check outputs:

```powershell
sqlfmt --check
```

Format one test file:

```powershell
sqlfmt --file 01
```

Format a SQL file to stdout, if supported by the installed wrapper:

```powershell
sqlfmt .\input.sql
```

Format a SQL file to another file, if supported by the installed wrapper:

```powershell
sqlfmt .\input.sql --out .\output.sql
```

Format a SQL file in place, if supported by the installed wrapper:

```powershell
sqlfmt .\input.sql --inplace
```

The exact supported arguments are controlled by `scripts/install-sqlfmt-command.ps1`, but `sqlfmt` should ultimately call the same project scripts:

```text
format.ps1
format-file.ps1
format-sql.ps1
```

### Why `sqlfmt` and not `format`

Do not use a generic command named `format`. It can conflict with existing PowerShell functions, aliases, Windows commands, or user-defined commands.

Use:

```text
sqlfmt
```

---

## User preferences

Users can customize formatter behavior through a local settings file.

Recommended local settings path:

```text
settings/settings.json
```

This file is user-specific and should normally be ignored by Git.

Recommended committed example file:

```text
settings/settings.example.json
```

### Create local settings

Create the folder:

```powershell
New-Item -ItemType Directory -Force .\settings
```

Copy the example file if it exists:

```powershell
Copy-Item .\settings\settings.example.json .\settings\settings.json
```

Or create `settings/settings.json` manually.

### Example settings

```json
{
  "maxLineLength": 120,
  "indentSize": 2,
  "keywordCasing": "Uppercase",
  "preserveCommentLineBoundaries": true
}
```

### Supported preference keys

| Setting | Values | Meaning |
|---|---|---|
| `maxLineLength` | usually `80`, `100`, `120`, `160` | Preferred maximum line length before wrapping. |
| `indentSize` | `2` or `4` | Level-based indentation size. Alignment columns may still use fixed layout spacing. |
| `keywordCasing` | `Uppercase`, `Lowercase`, `Preserve` | Controls SQL keyword casing where supported. |
| `preserveCommentLineBoundaries` | `true` / `false` | Keeps SQL after `--` comments on the next physical line. Should usually stay `true`. |

If a setting is missing or invalid, the formatter should use safe defaults.

### Default preferences

```json
{
  "maxLineLength": 120,
  "indentSize": 2,
  "keywordCasing": "Uppercase",
  "preserveCommentLineBoundaries": true
}
```

### Git ignore recommendation

Add this to `.gitignore`:

```gitignore
# Local formatter preferences
settings/settings.json
```

Commit this instead:

```text
settings/settings.example.json
```

### Preferences in usage help

The usage help for `format.ps1`, `format-file.ps1`, and `sqlfmt --help` should include this section:

```text
Preferences:
  Formatter preferences are read from:

      settings/settings.json

  If the file does not exist, default preferences are used.

  Example:

      {
        "maxLineLength": 120,
        "indentSize": 2,
        "keywordCasing": "Uppercase",
        "preserveCommentLineBoundaries": true
      }

  To change preferences:
    1. Create the settings folder if needed.
    2. Copy settings/settings.example.json to settings/settings.json.
    3. Edit settings/settings.json.
    4. Run the formatter again.

  settings/settings.json is local/user-specific and should not normally be committed.
```

---

## Formatting rules

### SELECT

```sql
SELECT C.CUSTOMER_ID,
       C.CUSTOMER_NAME,
       C.EMAIL_ADDRESS
  FROM CUSTOMER C
 WHERE C.IS_ACTIVE = 1
  WITH UR;
```

### JOIN and ON

Short joins may stay on one line if they fit. Long `JOIN ... ON ... AND ...` clauses should wrap:

```sql
SELECT ABA.F_CMSN_INCM,
       MON1.*
  FROM DW_MRT_CBS.CB_CST_PDTP_AC_MON1 MON1
  JOIN DW_TEMP.ABACADABA_2026027 ABA
    ON MON1.MSR_PRD_ID = ABA.MSR_PRD_ID
   AND MON1.CST_ID = ABA.CST_ID
   AND MON1.PD_TP_ID = ABA.PD_TP_ID
   AND MON1.CCY_ID = ABA.CCY_ID;
```

### WHERE / AND / OR

```sql
 WHERE A.STATUS = 'OPEN'
   AND A.TYPE <> 'TEST'
    OR A.TYPE IS NULL
```

### CASE

```sql
CASE
  WHEN CONDITION_1 THEN VALUE_1
  WHEN CONDITION_2 THEN VALUE_2
  ELSE VALUE_3
END AS SOME_ALIAS
```

Inside aggregate functions:

```sql
SUM(CASE
      WHEN CONDITION_1 THEN AMOUNT
      ELSE 0
    END) AS TOTAL_AMOUNT
```

### CTEs

```sql
WITH BASE_ORDERS
  AS ( SELECT O.CUSTOMER_ID,
              O.ORDER_ID,
              O.ORDER_DATE
         FROM ORDER_HEADER O
        WHERE O.STATUS_CODE = 'PAID' ),
     CUSTOMER_TOTALS
  AS ( SELECT B.CUSTOMER_ID,
              COUNT(*) AS ORDER_COUNT
         FROM BASE_ORDERS B
        GROUP BY B.CUSTOMER_ID )
SELECT *
  FROM CUSTOMER_TOTALS
 WITH UR;
```

### Subqueries in FROM

```sql
SELECT COUNT(*)
  FROM ( SELECT ROW_NUMBER() OVER (PARTITION BY A.ID ORDER BY A.ID) AS RN,
                A.*
           FROM SOME_TABLE A
          WHERE A.STATUS = 'OPEN' ) X
 WHERE X.RN = 1;
```

### Set operations

```sql
SELECT CUSTOMER_ID,
       EMAIL_ADDRESS
  FROM CUSTOMER
 WHERE IS_ACTIVE = 1
UNION
SELECT CUSTOMER_ID,
       EMAIL_ADDRESS
  FROM CUSTOMER_ARCHIVE
 WHERE IS_ACTIVE = 1
EXCEPT
SELECT CUSTOMER_ID,
       EMAIL_ADDRESS
  FROM CUSTOMER_SUPPRESSION
 WHERE IS_ACTIVE = 1
 ORDER BY CUSTOMER_ID
  WITH UR;
```

Only one final semicolon should be emitted.

### INSERT

Short insert lists may stay on one line:

```sql
INSERT INTO CUSTOMER_AUDIT ( CUSTOMER_ID, AUDIT_ACTION, AUDIT_TS, AUDIT_USER )
VALUES ( 1001, 'CREATED', CURRENT TIMESTAMP, CURRENT USER );
```

Long lists should wrap and align under the first item.

### CREATE TABLE

```sql
CREATE TABLE REPORTING.CUSTOMER_SUMMARY (
  CUSTOMER_ID INTEGER NOT NULL,
  CUSTOMER_NAME VARCHAR(200) NOT NULL,
  ORDER_COUNT INTEGER NOT NULL DEFAULT 0
);
```

### CREATE TABLE AS SELECT

DB2 CTAS statements should format the inner query recursively:

```sql
CREATE TABLE ABCD.EFGH AS (
  SELECT C.CUSTOMER_ID,
         C.CUSTOMER_NAME,
         COUNT(*) AS ORDER_COUNT
    FROM CUSTOMER C
   WHERE C.IS_ACTIVE = 1
   GROUP BY C.CUSTOMER_ID,
            C.CUSTOMER_NAME
)
WITH DATA;
```

or:

```sql
CREATE TABLE ABCD.EFGH AS (
  SELECT C.CUSTOMER_ID,
         C.CUSTOMER_NAME
    FROM CUSTOMER C
   WHERE C.IS_ACTIVE = 1
)
WITH NO DATA;
```

### SQL PL routines

```sql
BEGIN
  DECLARE V_SQL VARCHAR(4000);

  SET V_SQL = 'SELECT COUNT(*) FROM CUSTOMER';

  PREPARE S1 FROM V_SQL;

  EXECUTE S1 INTO P_CUSTOMER_COUNT;
END;
```

### Comments

Comments are normal visible text and must preserve line boundaries:

```sql
SELECT A.ID,
       -- Explanation for the next column.
       CAST('-200' AS CHAR(20)) AS MSG_TP_CD
  FROM ACCOUNT A;
```

The formatter must not produce this:

```sql
-- Explanation for the next column. CAST('-200' AS CHAR(20)) AS MSG_TP_CD
```

Strings that look like SQL/comments must remain strings:

```sql
SELECT '-- this is not a real comment inside a string' AS COMMENT_TEXT
  FROM SYSIBM.SYSDUMMY1;
```

---

## Troubleshooting

### DBeaver output differs from command-line output

Check that DBeaver points to the same `format-sql.ps1` you are editing.

DBeaver should call:

```text
format-sql.ps1
```

not:

```text
format.ps1
format-file.ps1
```

### DBeaver does not format the whole query

Select the full query before pressing `Ctrl + Shift + F`.

### PowerShell blocks the script

```powershell
Unblock-File .\format-sql.ps1
```

or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1
```

### `sqlfmt` is not recognized

```powershell
Get-Command sqlfmt
```

If missing:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-sqlfmt-command.ps1
```

Close and reopen PowerShell.

### `sqlfmt` points to the wrong folder

Re-run the installer from the correct repository root:

```powershell
cd C:\Path\To\dbeaver-sql-formatter
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-sqlfmt-command.ps1
```

Then reopen PowerShell and check:

```powershell
Get-Command sqlfmt
```

### Settings do not apply

Check that the settings file exists:

```powershell
Test-Path .\settings\settings.json
```

Validate JSON:

```powershell
Get-Content .\settings\settings.json -Raw | ConvertFrom-Json
```

If invalid:

```powershell
Remove-Item .\settings\settings.json
Copy-Item .\settings\settings.example.json .\settings\settings.json
```

---

## Development workflow

Before changing formatter logic:

```powershell
git status
.\format.ps1 -check
```

After an intentional formatter change:

```powershell
.\format.ps1 -runall
.\format.ps1 -check
git diff
```

Commit:

```powershell
git add -A
git commit -m "Describe the formatter change"
git push
```

---

## Recommended development process

Keep changes small.

Each formatter change should target one bug or one formatting rule:

1. Identify the smallest failing SQL example.
2. Add or update a test input.
3. Patch only the relevant function.
4. Run `.ormat.ps1 -check`.
5. Review formatted output manually.
6. Commit only when the output is better.

Avoid full rewrites unless done on a separate branch and tested carefully.

---

## Public repository hygiene

Do not commit:

- personal Windows paths,
- usernames,
- passwords,
- API keys,
- tokens,
- real connection strings,
- private company SQL,
- local scratch files,
- generated temporary outputs,
- user-specific `settings/settings.json`.

Useful scans:

```powershell
Get-ChildItem -Recurse -File | Select-String -Pattern "C:\\Users\\"
```

```powershell
Get-ChildItem -Recurse -File | Select-String -Pattern "password|passwd|pwd|secret|apikey|api_key|connectionstring|connection string|server=|user id=|uid=|trusted_connection"
```

---

## Suggested `.gitignore`

```gitignore
# Generated formatter outputs
*.formatted.sql

# Temporary files
*.tmp
*.bak

# Local editor files
.vscode/
.idea/

# Local formatter preferences
settings/settings.json
```

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
