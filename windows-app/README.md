# Windows app

`SqlFormatterApp` is a WPF desktop front end for the repository formatter.

It supports the same automatic dialect routing as `format-sql.ps1`:

- DB2 / ANSI SQL
- PostgreSQL
- T-SQL / SQL Server / Azure SQL
- Oracle SQL / PL-SQL
- SPARQL 1.1

## UI

The app is split into three working areas:

- **Input** on the left
- **SQL Beautifier** settings in the middle
- **Formatted Output** on the right

Toolbar actions:

- **Open**: load `.sql`, `.sparql`, `.rq`, `.ru`, or any text file
- **Format**: run the same formatter used by DBeaver
- **Copy Output**: copy the formatted text
- **Replace Input**: move the formatted result back to the input editor
- **Save Output**: save the formatted result
- **Clear**: reset both editors
- **Theme**: switch between the soft Light and Dark palettes

`Ctrl+Enter` formats the current input. `Ctrl+Shift+S` saves the formatted output.

The selected UI theme is stored per Windows user under `%LOCALAPPDATA%\SqlFormatterApp` and is restored on the next launch. The light palette uses muted greys rather than a bright white canvas; the dark palette uses charcoal/slate surfaces rather than near-black backgrounds. Text, controls, selected ComboBox values and popup items use theme-aware foreground/background resources so labels remain readable in either mode. Windows system control colors are overridden inside the app as well, preventing native ComboBox templates from falling back to white-on-white or dark-on-dark text. The Windows title bar follows the selected mode on supported Windows builds.

The SQL Beautifier panel includes presets plus granular controls for width, indentation, keyword casing, parentheses, SELECT/GROUP BY/ORDER BY and other lists, comma placement, joins, boolean operators, CTEs, CASE expressions and spacing. Formatter settings remain separate from the visual theme.

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
