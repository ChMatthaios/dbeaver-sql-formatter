<#
    Formats one .sql file by calling format-sql.ps1.

    Usage from the repository root:
      .\formatter\format-file.ps1 .\input.sql
      .\formatter\format-file.ps1 .\input.sql -OutFile .\output.sql
      .\formatter\format-file.ps1 .\input.sql -InPlace
      .\formatter\format-file.ps1 -help
#>

param(
    [Parameter(Position = 0)]
    [string]$Path,
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
    Write-Host "Usage from repository root:"
    Write-Host "  .\formatter\format-file.ps1 .\input.sql"
    Write-Host "  .\formatter\format-file.ps1 .\input.sql -OutFile .\output.sql"
    Write-Host "  .\formatter\format-file.ps1 .\input.sql -InPlace"
    Write-Host "  .\formatter\format-file.ps1 -help"
    Write-Host ""
    Write-Host "Preferences:"
    Write-Host "  Formatter preferences are read from:"
    Write-Host ""
    Write-Host "      formatter/settings/settings.json"
    Write-Host ""
    Write-Host "  If the file does not exist, default preferences are used."
    Write-Host ""
    Write-Host "  Example:"
    Write-Host ""
    Write-Host '      {'
    Write-Host '        "maxLineLength": 120,'
    Write-Host '        "indentSize": 2,'
    Write-Host '        "keywordCasing": "Uppercase",'
    Write-Host '        "preserveCommentLineBoundaries": true'
    Write-Host '      }'
    Write-Host ""
    Write-Host "  Copy formatter/settings/settings.example.json to formatter/settings/settings.json and edit it."
    Write-Host "  formatter/settings/settings.json is local/user-specific and should not normally be committed."
    Write-Host ""
}

if ($help) {
    Show-Help
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    Show-Help
    exit 1
}

if ($InPlace -and -not [string]::IsNullOrWhiteSpace($OutFile)) {
    throw "Use either -OutFile or -InPlace, not both."
}

if (-not (Test-Path -LiteralPath $Formatter -PathType Leaf)) {
    throw "Formatter engine not found: $Formatter"
}

$InputPath = (Resolve-Path -LiteralPath $Path).Path
if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Input SQL file not found: $Path"
}

$sql = Get-Content -LiteralPath $InputPath -Raw
$formatted = $sql | powershell -NoProfile -ExecutionPolicy Bypass -File $Formatter | Out-String
$formatted = $formatted.TrimEnd("`r", "`n")

if ($InPlace) {
    Set-Content -LiteralPath $InputPath -Value $formatted -Encoding UTF8
    Write-Host "Formatted in place:" $InputPath
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    $OutputDirectory = Split-Path -Parent $OutputPath
    if ($OutputDirectory -and -not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $formatted -Encoding UTF8
    Write-Host "Formatted:" $InputPath "->" $OutputPath
    exit 0
}

[Console]::Out.Write($formatted)
