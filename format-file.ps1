<#
    SQL Formatter File Runner
    ------------------------------------------------------------
    Usage:
      .\format-file.ps1 .\input.sql
      .\format-file.ps1 .\input.sql -OutFile .\output.sql
      .\format-file.ps1 .\input.sql -InPlace
      .\format-file.ps1 -help

    This script formats SQL from a file using format-sql.ps1.

    It does not replace format-sql.ps1.
    DBeaver should still call format-sql.ps1 directly.
#>

param(
    [Parameter(Position = 0)]
    [string]$InputFile,

    [string]$OutFile,

    [switch]$InPlace,

    [switch]$help
)

$ErrorActionPreference = "Stop"

$RootDir = $PSScriptRoot
$Formatter = Join-Path $RootDir "format-sql.ps1"

function Show-Help {
    Write-Host ""
    Write-Host "DBeaver SQL Formatter - File Runner"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  .\format-file.ps1 .\input.sql"
    Write-Host "  .\format-file.ps1 .\input.sql -OutFile .\output.sql"
    Write-Host "  .\format-file.ps1 .\input.sql -InPlace"
    Write-Host "  .\format-file.ps1 -help"
    Write-Host ""
    Write-Host "Modes:"
    Write-Host "  default   Writes formatted SQL to stdout."
    Write-Host "  -OutFile  Writes formatted SQL to a specific output file."
    Write-Host "  -InPlace  Replaces the input file with formatted SQL."
    Write-Host "  -help     Shows this help message."
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\format-file.ps1 .\tests\01_simple_one_line_statements.sql"
    Write-Host "  .\format-file.ps1 .\input.sql -OutFile .\formatted.sql"
    Write-Host "  .\format-file.ps1 .\input.sql -InPlace"
    Write-Host ""
}

if ($help) {
    Show-Help
    exit 0
}

if ([string]::IsNullOrWhiteSpace($InputFile)) {
    Show-Help
    exit 1
}

if (-not (Test-Path $Formatter)) {
    throw "Formatter script not found: $Formatter"
}

if (-not (Test-Path $InputFile)) {
    throw "Input file not found: $InputFile"
}

if ($InPlace -and -not [string]::IsNullOrWhiteSpace($OutFile)) {
    throw "Use either -InPlace or -OutFile, not both."
}

$ResolvedInputFile = (Resolve-Path $InputFile).Path

if ((Get-Item $ResolvedInputFile).PSIsContainer) {
    throw "Input path is a directory, not a file: $ResolvedInputFile"
}

$formattedSql = Get-Content $ResolvedInputFile -Raw |
    powershell -NoProfile -ExecutionPolicy Bypass -File $Formatter

if ($InPlace) {
    Set-Content -Path $ResolvedInputFile -Value $formattedSql -Encoding UTF8 -NoNewline
    Write-Host "Formatted in place:" $ResolvedInputFile
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $OutDir = Split-Path -Parent $OutFile

    if (-not [string]::IsNullOrWhiteSpace($OutDir) -and -not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    }

    Set-Content -Path $OutFile -Value $formattedSql -Encoding UTF8 -NoNewline
    Write-Host "Formatted:" $ResolvedInputFile "->" $OutFile
    exit 0
}

[Console]::Out.Write($formattedSql)
exit 0