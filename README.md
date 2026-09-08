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

The repository root is intentionally kept small. Formatter implementation files live together under `formatter/`, dialect documentation under `docs/`, and expected regression output under `tests/expected/`.

```text
dbeaver-sql-formatter/
├─ .github/
│  └─ workflows/
├─ .gitignore
├─ README.md
├─ docs/
│  ├─ ORACLE_PLSQL.md
│  ├─ POSTGRESQL.md
│  └─ SPARQL.md
├─ examples/
│  ├─ README.md
│  └─ sample-*.sql / sample-*.rq
├─ formatter/
│  ├─ format-dbeaver.ps1
│  ├─ format-ui-script.ps1
│  ├─ format-ui.ps1
│  ├─ format-beautifier.ps1
│  ├─ format-sql.ps1
│  ├─ format-sql-core.ps1
│  ├─ format-merge.ps1
│  ├─ format-polish.ps1
│  ├─ format-file.ps1
│  ├─ format.ps1
│  ├─ other formatter passes and dialect engines
│  └─ settings/
│     └─ settings.example.json
├─ scripts/
│  └─ install-sqlfmt-command.ps1
├─ tests/
│  ├─ *.sql
│  └─ expected/
│     └─ *.out.sql
└─ windows-app/
   ├─ SqlFormatterApp/
   ├─ test-data/
   └─ publish.ps1
```

Important files:

| File | Purpose |
|---|---|
| `formatter/format-dbeaver.ps1` | DBeaver entry point. Delegates to the exact same full pipeline used by the Windows UI. |
| `formatter/format-ui-script.ps1` | Shared script-level formatter used by the Windows UI and DBeaver wrapper. Handles multi-statement input and presentation repairs. |
| `formatter/format-ui.ps1` | Shared per-statement presentation pipeline. |
| `formatter/format-beautifier.ps1` | Applies the advanced formatting profile selected in the Windows UI. |
| `formatter/format-sql.ps1` | Dialect-aware SQL engine used underneath the presentation pipeline. |
| `formatter/format-sql-core.ps1` | Main heuristic common/DB2 SQL formatter. |
| `formatter/format-merge.ps1` | Structural formatter for standalone `MERGE` statements. |
| `formatter/format-polish.ps1` | Structural pass for long CASE conditions and logical groups. |
| `formatter/format.ps1` | Test/development runner. |
| `formatter/format-file.ps1` | Formats real `.sql` files. |
| `scripts/install-sqlfmt-command.ps1` | Optional installer for the `sqlfmt` command. |
| `tests/` | Input regression tests. |
| `tests/expected/` | Expected formatted outputs. |
| `formatter/settings/settings.json` | Local user preferences shared by the Windows UI and DBeaver. Usually ignored by Git. |
| `formatter/settings/settings.example.json` | Example/default preferences. Safe to commit. |

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

over splitting a function call in the middle.

### Shared Windows UI / DBeaver flow

```text
selected SQL / editor SQL
        ↓ stdin
formatter/format-dbeaver.ps1          Windows UI
        ↓                                ↓
        └──────→ formatter/format-ui-script.ps1
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
          formatter/settings/settings.json
                         ↓ stdout
              identical formatted result
```

This is intentional: DBeaver is not given a reduced formatter. It receives the same script-level formatting and the same advanced preferences as the Windows application.

### Test flow

```text
tests/*.sql
   ↓
formatter/format.ps1 -check / -runall
   ↓ calls
formatter/format-sql.ps1
   ↓
tests/expected/*.out.sql
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
.\formatter\format.ps1 -check
```

List test files:

```powershell
.\formatter\format.ps1 -list
```

Regenerate all expected outputs:

```powershell
.\formatter\format.ps1 -runall
```

Run the Windows app from source:

```powershell
dotnet run --project .\windows-app\SqlFormatterApp\SqlFormatterApp.csproj
```

---

## DBeaver setup

In DBeaver, open:

```text
Window → Preferences → Editors → SQL Editor → SQL Formatting
```

Configure the external formatter to point to:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "FULL_PATH_TO_REPOSITORY\formatter\format-dbeaver.ps1"
```

The shared formatting profile is stored at:

```text
formatter\settings\settings.json
```

Use `Ctrl + Shift + F` in DBeaver to format the selected SQL or current statement.

---

## Direct formatter usage

For the exact Windows UI/DBeaver presentation result:

```powershell
Get-Content .\input.sql -Raw | powershell -NoProfile -ExecutionPolicy Bypass -File .\formatter\format-dbeaver.ps1
```

For the lower-level dialect-aware engine:

```powershell
Get-Content .\input.sql -Raw | powershell -NoProfile -ExecutionPolicy Bypass -File .\formatter\format-sql.ps1
```

For normal file usage:

```powershell
.\formatter\format-file.ps1 .\input.sql
```

The formatter is intentionally conservative: correctness and stable SQL come before aggressive reformatting.
