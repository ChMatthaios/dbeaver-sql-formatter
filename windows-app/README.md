# Windows app

`SqlFormatterApp` is a small WPF desktop front end for the repository formatter.

It supports the same automatic dialect routing as `format-sql.ps1`:

- DB2 / ANSI SQL
- PostgreSQL
- T-SQL / SQL Server / Azure SQL
- Oracle SQL / PL-SQL
- SPARQL 1.1

## UI

The app has two large editors:

- **Input** on the left
- **Formatted Output** on the right

Toolbar actions:

- **Open**: load `.sql`, `.sparql`, `.rq`, `.ru`, or any text file
- **Format**: run the same formatter used by DBeaver
- **Copy Output**: copy the formatted text
- **Replace Input**: move the formatted result back to the input editor
- **Save Output**: save the formatted result
- **Clear**: reset both editors

`Ctrl+Enter` formats the current input. `Ctrl+Shift+S` saves the formatted output.

The header also shows a lightweight dialect guess and lets you change the formatter's maximum line width. The default remains 120 columns.

## Run from source

Requirements:

- Windows 10/11
- .NET 8 SDK
- Windows PowerShell 5.1 (already included with normal Windows installations)

From the repository root:

```powershell
dotnet run --project .\windows-app\SqlFormatterApp\SqlFormatterApp.csproj
```

## Build

```powershell
dotnet build .\windows-app\SqlFormatterApp\SqlFormatterApp.csproj -c Release
```

## Publish a portable folder

```powershell
dotnet publish .\windows-app\SqlFormatterApp\SqlFormatterApp.csproj `
  -c Release `
  -r win-x64 `
  --self-contained true `
  -p:PublishSingleFile=false `
  -o .\artifacts\SqlFormatterApp
```

Run:

```text
artifacts\SqlFormatterApp\SqlFormatterApp.exe
```

The publish folder contains the PowerShell formatter scripts under `Formatter\`, so the GUI uses exactly the same formatting engine as DBeaver.

## GitHub Actions artifact

The `Windows app` workflow builds and publishes the application on relevant pull requests and pushes to `main`. Its downloadable artifact is named:

```text
SqlFormatterApp-win-x64
```

The artifact is self-contained for .NET, so the target Windows computer does not need the .NET runtime installed. Windows PowerShell is still used internally to run the existing formatter engine.
