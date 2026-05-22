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

function Invoke-SqlFormatter {
    param(
        [string]$Sql
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Formatter`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()

    $process.StandardInput.Write($Sql)
    $process.StandardInput.Close()

    $output = $process.StandardOutput.ReadToEnd()
    $errorOutput = $process.StandardError.ReadToEnd()

    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        throw "Formatter failed with exit code $($process.ExitCode): $errorOutput"
    }

    return $output
}

$inputSql = Get-Content $ResolvedInputFile -Raw
$formattedSql = Invoke-SqlFormatter -Sql $inputSql

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