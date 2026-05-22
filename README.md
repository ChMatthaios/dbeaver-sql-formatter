# DBeaver SQL Formatter

A lightweight PowerShell-based SQL formatter designed to work as an external formatter for DBeaver.

The project currently focuses on formatting SQL scripts from standard input and writing the formatted result to standard output, which makes it suitable for editor integrations and command-line usage.

## Current status

This project is working, but still evolving.

It is currently a script-based formatter, not yet a standalone desktop application. Future improvements may include a dedicated UI so the formatter can also be used as a separate app outside DBeaver.

## Features

- Reads SQL from standard input.
- Writes formatted SQL to standard output.
- Supports multiple SQL statement types, including:
  - `SELECT`
  - `WITH`
  - `INSERT`
  - `UPDATE`
  - `MERGE`
  - `CREATE PROCEDURE`
  - `CREATE FUNCTION`
- Preserves protected SQL content such as strings and comments during formatting.
- Includes test SQL files and generated output examples.

## Requirements

- Windows, Linux, or macOS with PowerShell installed.
- PowerShell 5.1+ or PowerShell 7+.

On Windows, PowerShell is usually already available.

## Project structure

```text
dbeaver-sql-formatter/
├─ format-sql.ps1   # Main SQL formatter script
├─ format.ps1       # Test/helper runner
├─ tests/           # SQL input examples
├─ tests_out/       # Generated formatter output files
└─ .gitignore
```

## Usage from the command line

Format a SQL file and write the result to another file:

```powershell
Get-Content .\tests\01_simple_one_line_statements.sql -Raw | .\format-sql.ps1 > .\formatted.sql
```

Or manually pipe SQL text into the formatter:

```powershell
"select * from customer where customer_id = 1;" | .\format-sql.ps1
```

## Test/helper runner

List available test files:

```powershell
.\format.ps1 -list
```

Run the formatter against all test files:

```powershell
.\format.ps1 -runall
```

This writes formatted output files into:

```text
tests_out/
```

Important: the current runner formats all test inputs, but it does not yet compare actual output against expected/golden output. So `-runall` means the formatter completed successfully, not necessarily that every formatting result is semantically or stylistically correct.

## DBeaver usage

This formatter is intended to be usable from DBeaver as an external SQL formatter.

The formatter script reads SQL from standard input and writes the formatted SQL to standard output:

```powershell
.\format-sql.ps1
```

Exact DBeaver configuration steps may vary depending on your DBeaver version and environment.

## Roadmap

Planned improvements:

- Improve formatting consistency and edge-case handling.
- Add true regression tests by comparing generated output against expected output.
- Improve command-line documentation.
- Prepare better DBeaver setup instructions.
- Add a standalone UI/UX layer so the formatter can be used as a separate app.
- Consider packaging options for easier installation.

## Development notes

Before making changes, run:

```powershell
.\format.ps1 -runall
```

After making changes, run it again and inspect the generated files in `tests_out/`.

Future versions should introduce golden-output comparison so formatting changes can be reviewed more safely.

## Security / privacy note

This repository should not contain personal local paths, credentials, database connection strings, tokens, or private SQL data.

Before publishing, scan the project for sensitive values such as:

- local machine paths
- usernames
- passwords
- API keys
- access tokens
- database server names
- connection strings
- private customer or company data

## License

No license has been selected yet.

Until a license is added, all rights are reserved by the repository owner.
