# DBeaver SQL Formatter

A PowerShell-based DB2-oriented SQL formatter designed to work well with DBeaver's external formatter flow, while also being usable directly from the command line.

The formatter reads SQL from standard input and writes formatted SQL to standard output. This makes it easy to integrate with tools that support external commands.

## Current status

This project is working, but still evolving.

The formatter was rewritten around a recursive formatting approach:

- SELECT formatting is reused across plain queries, CTEs, subqueries, MERGE source queries, CREATE VIEW statements, cursors, procedures, and functions.
- DB2 SQL and SQL PL patterns are handled more deliberately.
- The formatter is still heuristic. It is not a full DB2 parser.

The current goals are:

1. Keep the existing DBeaver workflow stable.
2. Improve formatter behavior safely and gradually.
3. Keep regression checks available before making larger changes.
4. Add broader DB2 examples and stress tests.
5. Later, add a standalone UI/UX app that uses the same formatter core.

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

## Main files

### `format-sql.ps1`

The actual SQL formatter.

It reads SQL from stdin:

```powershell
$inputSql = [Console]::In.ReadToEnd()
```

and writes formatted SQL to stdout:

```powershell
[Console]::Out.Write($result)
```

This stdin/stdout behavior is important because it allows the formatter to work with DBeaver and other external tools.

### `format.ps1`

The local test/helper runner.

Use it to list test files, regenerate outputs, check outputs, or format a single test case.

### `format-file.ps1`

A file-based runner for normal command-line usage.

Use it when you want to format a SQL file directly instead of piping SQL through stdin.

### `scripts/install-sqlfmt-command.ps1`

Optional installer that adds a convenient PowerShell command named `sqlfmt`.

It does not hardcode personal paths. It detects the project root automatically and stores it in the user environment variable:

```text
DBEAVER_SQL_FORMATTER_HOME
```

## Requirements

- Windows PowerShell
- Git, if you want to clone or contribute
- DBeaver, if you want to use it as a DBeaver external formatter

## Basic usage

From the project root:

```powershell
.\format.ps1 -list
```

Formats all SQL test inputs and writes outputs to `tests_out`:

```powershell
.\format.ps1 -runall
```

Checks formatter output against the committed expected outputs in `tests_out`:

```powershell
.\format.ps1 -check
```

Formats one matching test file:

```powershell
.\format.ps1 -file 01
```

or:

```powershell
.\format.ps1 -file 04_complicated_multiline_statements.sql
```

Shows the available commands:

```powershell
.\format.ps1 -help
```

## Formatting a SQL file

Use `format-file.ps1` when you want to format a file directly.

Write formatted SQL to the terminal:

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

`format-file.ps1` is for normal file-based usage. DBeaver should still call `format-sql.ps1` directly because DBeaver works through stdin and stdout.

## Optional PowerShell command: `sqlfmt`

For convenience, you can install a local PowerShell command named `sqlfmt`.

From the project root, run:

```powershell
.\scripts\install-sqlfmt-command.ps1
```

If PowerShell blocks script execution, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-sqlfmt-command.ps1
```

Then close and reopen PowerShell.

You can now use:

```powershell
sqlfmt --list
sqlfmt --check
sqlfmt --runall
sqlfmt --file 01
sqlfmt --help
```

The installer adds a small `sqlfmt` wrapper function to the current user's PowerShell profile.

It avoids personal or machine-specific paths by using:

```text
DBEAVER_SQL_FORMATTER_HOME
```

Do not use a generic command name like `format` for public documentation. `format` may conflict with existing Windows commands or local user functions. `sqlfmt` is safer and clearer.

## Examples

A broad DB2 sample file is available at:

```text
examples/sample-db2.sql
```

Try formatting it with:

```powershell
.\format-file.ps1 .\examples\sample-db2.sql -OutFile .\examples\sample-db2.formatted.sql
```

The generated formatted file is only for local inspection. Do not commit generated `*.formatted.sql` files unless you intentionally want to add them as expected output.

The sample includes beginner-to-advanced SQL patterns such as:

- SELECT statements,
- joins,
- subqueries,
- CTEs,
- recursive CTEs,
- window functions,
- set operations,
- INSERT,
- UPDATE,
- DELETE,
- MERGE,
- CREATE TABLE,
- CREATE INDEX,
- CREATE VIEW,
- ALTER TABLE,
- declared global temporary tables,
- procedures,
- functions,
- cursors,
- handlers,
- dynamic SQL,
- comments,
- DB2-specific clauses such as `WITH UR`, `FETCH FIRST`, and `OPTIMIZE FOR`.

## Formatter behavior

The formatter is DB2-oriented and currently focuses on:

- consistent SELECT formatting,
- aligned SELECT lists,
- CASE expression formatting,
- CTE formatting,
- recursive CTE formatting,
- nested SELECT formatting,
- MERGE formatting,
- CREATE VIEW formatting,
- CREATE TABLE / CREATE INDEX formatting,
- SQL PL procedure/function formatting,
- preserving strings and comments during formatting.

The formatter is heuristic, not a complete DB2 parser. That means there may still be unsupported DB2 syntax, edge cases, or style preferences that need refinement.

## DBeaver usage

This formatter is designed to work with DBeaver as an external SQL formatter.

Current known setup:

```text
Preferences → Editors → SQL Editor → SQL Formatting
```

The formatter is triggered from DBeaver with:

```text
Ctrl + Shift + F
```

DBeaver formats either:

- the selected SQL text, or
- the query where the cursor currently is.

No extra DBeaver-specific settings are currently required.

### Recommended DBeaver command

Use PowerShell directly and point it to `format-sql.ps1`.

Example command shape:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "FULL_PATH_TO_REPOSITORY\format-sql.ps1"
```

Replace `FULL_PATH_TO_REPOSITORY` with the folder where this project is cloned.

Example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\dbeaver-sql-formatter\format-sql.ps1"
```

Do not commit personal local paths to this repository.

### Why DBeaver should call `format-sql.ps1`

For DBeaver integration, the formatter script should behave like a stdin/stdout command:

```text
SQL input  → stdin  → format-sql.ps1 → stdout → formatted SQL output
```

That is why DBeaver should call:

```text
format-sql.ps1
```

not the test runner:

```text
format.ps1
```

`format.ps1` is for local testing and development.

## Test runner behavior

### `-runall`

```powershell
.\format.ps1 -runall
```

Regenerates output files in:

```text
tests_out/
```

This is useful when you intentionally change formatter behavior.

### `-check`

```powershell
.\format.ps1 -check
```

Formats test inputs into a temporary folder and compares them against the committed files in:

```text
tests_out/
```

This does not overwrite expected outputs.

Use this before committing changes.

A successful check looks like:

```text
PASS 01_simple_one_line_statements.sql
PASS 02_simple_multiline_statements.sql
...
Check complete. Passed: X. Failed: 0.
```

## Recommended development workflow

Before editing:

```powershell
git status
```

After editing:

```powershell
.\format.ps1 -check
```

If the formatter behavior intentionally changed, review the new output carefully. Then regenerate expected outputs:

```powershell
.\format.ps1 -runall
```

Run the check again:

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
git commit -m "Describe the change"
git push
```

Every meaningful project change should be reflected in this README when it affects usage, setup, workflow, behavior, or project direction.

## Public repository hygiene

Before pushing public changes, avoid committing:

- personal Windows paths,
- usernames,
- passwords,
- API keys,
- tokens,
- real database connection strings,
- private company SQL,
- local scratch files,
- generated scratch outputs such as `*.formatted.sql`.

Useful scan commands:

```powershell
Get-ChildItem -Recurse -File | Select-String -Pattern "C:\\Users\\"
```

```powershell
Get-ChildItem -Recurse -File | Select-String -Pattern "password|passwd|pwd|secret|apikey|api_key|connectionstring|connection string|server=|user id=|uid=|trusted_connection"
```

Email-like test data such as `'A@B.COM'` is fine when it is fake sample data.

## Roadmap

Planned improvement areas:

1. Stabilize the recursive DB2 formatter rewrite.
2. Add more DB2 regression tests based on real formatting edge cases.
3. Add `sqlfmt --check --file <test>` support if not already present locally.
4. Improve DBeaver setup documentation with screenshots.
5. Add configurable formatting options.
6. Build a standalone UI/UX app that uses the same formatter core.

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
