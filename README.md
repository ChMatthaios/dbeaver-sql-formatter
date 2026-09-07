# DBeaver SQL Formatter

A PowerShell-based DB2 SQL formatter designed mainly for **DBeaver external formatter usage**.

Core rule:

```text
format-sql.ps1 is the formatter entry point.
Every SQL unit is formatted independently, then placed into its parent context.
The configured maxLineLength (120 by default) is treated as the margin for each formatted unit.
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
- recursively format CTEs, subqueries, joins, DGTTs, MERGE `USING` queries, and other DB2 SQL containers where possible,
- keep output inside the configured line margin by breaking at SQL structure before arbitrary words,
- prefer logical boundaries (`AND`, `OR`, `THEN`, comma-separated items) over splitting function calls or nested expressions.

---

## Project structure

```text
dbeaver-sql-formatter/
├─ .gitignore
├─ README.md
├─ format-sql.ps1
├─ format-sql-core.ps1
├─ format-merge.ps1
├─ format-polish.ps1
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
| `format-sql.ps1` | DBeaver/CLI entry point. |
| `format-sql-core.ps1` | Main heuristic SQL formatter. |
| `format-merge.ps1` | Structural formatter for standalone DB2 `MERGE` statements. |
| `format-polish.ps1` | Final structural pass for long CASE conditions and logical groups. |
| `format.ps1` | Test/development runner. |
| `format-file.ps1` | Formats real `.sql` files. |
| `scripts/install-sqlfmt-command.ps1` | Optional installer for the `sqlfmt` command. |
| `tests/` | Input regression tests. |
| `tests_out/` | Expected formatted outputs. |
| `settings/settings.json` | Local user preferences. Usually ignored by Git. |
| `settings/settings.example.json` | Example/default preferences. Safe to commit. |

---

## Architecture

### Formatting model

```text
outer SQL statement
        ↓
identify nested SQL units / structural expressions
        ↓
format each unit independently
        ↓
place it back into its parent with parent indentation
        ↓
apply structural 120-column polish
```

The formatter should break on SQL structure before breaking arbitrary text. For example, a long CASE condition should prefer:

```sql
         WHEN SOME_LONG_CONDITION AND ANOTHER_LONG_CONDITION
         THEN 1
```

over splitting a function call in the middle. Likewise, a long parenthesized OR group should prefer:

```sql
   AND (  CONDITION_1
       OR CONDITION_2
       OR CONDITION_3)
```

### DBeaver flow

```text
DBeaver selected SQL
        ↓ stdin
format-sql.ps1
        ↓
format-sql-core.ps1
        ↓
format-merge.ps1 (when needed)
        ↓
format-polish.ps1
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

The formatter is intentionally conservative: correctness and stable SQL come before aggressive reformatting.