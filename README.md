# DBeaver SQL Formatter

A PowerShell-based SQL formatter designed for **DBeaver external formatter usage** and the optional Windows formatter UI.

Core rule:

```text
The Windows UI and DBeaver use the same script-level formatting pipeline.
Every SQL unit is formatted independently, then placed into its parent context.
The configured maxLineLength (120 by default) is treated as the margin for each formatted unit.
```

The formatter reads SQL from **stdin** and writes formatted SQL to **stdout**, which makes it usable from DBeaver, PowerShell, file runners, and the optional `sqlfmt` command.

The current dialect router supports common/DB2 SQL, PostgreSQL, SQL Server/T-SQL, Oracle SQL/PLSQL, and SPARQL. Dialect-specific syntax is detected automatically.

---

## What this project does

This project formats practical SQL with a consistent style. It is heuristic rather than a full parser for every supported language, so the formatter should prefer safe formatting over aggressive rewriting. If it cannot understand something safely, it should avoid destroying the query.

Main goals:

- format selected SQL directly inside DBeaver,
- make DBeaver output exactly match the Windows UI output,
- share the same saved formatting profile between the UI and DBeaver,
- format `.sql` files from PowerShell,
- support tests and regression checks,
- support optional user preferences,
- keep comments and strings safe,
- recursively format CTEs, subqueries, joins, DGTTs, MERGE `USING` queries, and other SQL containers where possible,
- keep output inside the configured line margin by breaking at SQL structure before arbitrary words,
- prefer logical boundaries (`AND`, `OR`, `THEN`, comma-separated items) over splitting function calls or nested expressions.

---

## Project structure

```text
dbeaver-sql-formatter/
├─ .gitignore
├─ README.md
├─ format-dbeaver.ps1
├─ format-ui-script.ps1
├─ format-ui.ps1
├─ format-beautifier.ps1
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
| `format-dbeaver.ps1` | DBeaver entry point. Delegates to the exact same full pipeline used by the Windows UI. |
| `format-ui-script.ps1` | Shared script-level formatter used by the Windows UI and DBeaver wrapper. Handles multi-statement input and UI presentation repairs. |
| `format-ui.ps1` | Shared per-statement UI presentation pipeline. |
| `format-beautifier.ps1` | Applies the advanced formatting profile selected in the Windows UI. |
| `format-sql.ps1` | Dialect-aware SQL engine used underneath the presentation pipeline. |
| `format-sql-core.ps1` | Main heuristic common/DB2 SQL formatter. |
| `format-merge.ps1` | Structural formatter for standalone DB2 `MERGE` statements. |
| `format-polish.ps1` | Structural pass for long CASE conditions and logical groups. |
| `format.ps1` | Test/development runner. |
| `format-file.ps1` | Formats real `.sql` files. |
| `scripts/install-sqlfmt-command.ps1` | Optional installer for the `sqlfmt` command. |
| `tests/` | Input regression tests. |
| `tests_out/` | Expected formatted outputs. |
| `settings/settings.json` | Local user preferences shared by the Windows UI and DBeaver. Usually ignored by Git. |
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
apply semantic presentation passes
        ↓
apply the saved advanced beautifier profile
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

### Shared Windows UI / DBeaver flow

```text
selected SQL / editor SQL
        ↓ stdin
format-dbeaver.ps1                Windows UI
        ↓                            ↓
        └──────→ format-ui-script.ps1
                     ↓
               format-ui.ps1
                     ↓
               format-sql.ps1
                     ↓
             dialect-specific engine
                     ↓
        semantic / CASE / DGTT presentation
                     ↓
             format-beautifier.ps1
                     ↓
          settings/settings.json
                     ↓ stdout
          identical formatted result
```

This is intentional: DBeaver is not given a reduced formatter anymore. It receives the same script-level formatting and the same advanced preferences as the Windows application.

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

Use PowerShell and point to `format-dbeaver.ps1`.

Command shape:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "FULL_PATH_TO_REPOSITORY\format-dbeaver.ps1"
```

Example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\dbeaver-sql-formatter\format-dbeaver.ps1"
```

Replace `C:\Path\To\dbeaver-sql-formatter` with your actual local path.

Do not commit personal Windows paths to the repository.

### 3. Use the same formatting profile as the Windows UI

The Windows application writes its selected formatting preferences to:

```text
settings\settings.json
```

`format-dbeaver.ps1` runs the same presentation pipeline and reads that same file. Change a formatting preference in the Windows UI, save/apply it, and the next DBeaver format operation uses the same profile.

### 4. Format SQL in DBeaver

Use:

```text
Ctrl + Shift + F
```

DBeaver formats either the selected text or the query where the cursor currently is. The shared script-level formatter supports multi-statement selections and automatically routes supported dialect-specific syntax.

---

## Direct formatter usage

For the exact Windows UI/DBeaver presentation result, use `format-dbeaver.ps1`:

```powershell
Get-Content .\input.sql -Raw | powershell -NoProfile -ExecutionPolicy Bypass -File .\format-dbeaver.ps1
```

The lower-level dialect-aware engine remains available as `format-sql.ps1`:

```powershell
Get-Content .\input.sql -Raw | powershell -NoProfile -ExecutionPolicy Bypass -File .\format-sql.ps1
```

For normal file usage, prefer `format-file.ps1`.

---

## File formatting usage

Show help:

```powershell
.\format-file.ps1 -help
```

The formatter is intentionally conservative: correctness and stable SQL come before aggressive reformatting.
