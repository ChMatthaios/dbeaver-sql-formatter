# DBeaver SQL Formatter

A PowerShell-based SQL formatter designed to work well with DBeaver's external formatter flow, while also being usable directly from the command line.

The formatter reads SQL from standard input and writes formatted SQL to standard output. This makes it easy to integrate with tools that support external commands.

## Current status

This project is working, but still evolving.

The current goals are:

1. Keep the existing DBeaver workflow stable.
2. Improve formatter behavior safely and gradually.
3. Add real regression checks before making larger changes.
4. Later, add a standalone UI/UX app that uses the same formatter core.

## Project structure

```text
dbeaver-sql-formatter/
├─ .gitignore
├─ README.md
├─ format-sql.ps1
├─ format.ps1
├─ scripts/
│  └─ install-sqlfmt-command.ps1
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
```

The installer adds a small `sqlfmt` wrapper function to the current user's PowerShell profile.

It avoids personal or machine-specific paths by using:

```text
DBEAVER_SQL_FORMATTER_HOME
```

Do not use a generic command name like `format` for public documentation. `format` may conflict with existing Windows commands or local user functions. `sqlfmt` is safer and clearer.

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

Every meaningful project change should be reflected in this README when it affects usage, setup, workflow, or project direction.

## DBeaver usage

This formatter is designed to work with DBeaver as an external SQL formatter.

The important behavior is:

- SQL input comes from stdin.
- Formatted SQL output goes to stdout.
- No UI interaction is required for the DBeaver workflow.

Detailed DBeaver setup instructions will be added as the project evolves.

## Public repository hygiene

Before pushing public changes, avoid committing:

- personal Windows paths,
- usernames,
- passwords,
- API keys,
- tokens,
- real database connection strings,
- private company SQL,
- local scratch files.

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

1. Keep improving formatter correctness and consistency.
2. Add stronger regression checks.
3. Improve documentation for DBeaver integration.
4. Add configurable formatting options.
5. Build a standalone UI/UX app that uses the same formatter core.

## License

No license has been selected yet.
