<#
    Installs the `sqlfmt` PowerShell command for this SQL formatter project.

    After running this installer, restart PowerShell and use:

      sqlfmt --list
      sqlfmt --check
      sqlfmt --runall
      sqlfmt --file 01

    The installer:
      - Detects the project root automatically.
      - Stores it in the user environment variable DBEAVER_SQL_FORMATTER_HOME.
      - Adds a small `sqlfmt` wrapper function to the user's PowerShell profile.
      - Does not hardcode any personal folders, usernames, or machine-specific paths.
#>

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$RunnerPath = Join-Path $ProjectRoot "format.ps1"

if (-not (Test-Path $RunnerPath)) {
    throw "Could not find format.ps1 at expected path: $RunnerPath"
}

[Environment]::SetEnvironmentVariable(
    "DBEAVER_SQL_FORMATTER_HOME",
    $ProjectRoot,
    "User"
)

$ProfileDir = Split-Path -Parent $PROFILE

if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null
}

$FunctionBlock = @'

# DBeaver SQL Formatter command wrapper
function sqlfmt {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$FormatArgs
    )

    $formatterHome = [Environment]::GetEnvironmentVariable("DBEAVER_SQL_FORMATTER_HOME", "User")

    if ([string]::IsNullOrWhiteSpace($formatterHome)) {
        throw "DBEAVER_SQL_FORMATTER_HOME is not set. Run scripts/install-sqlfmt-command.ps1 from the formatter repository."
    }

    $runner = Join-Path $formatterHome "format.ps1"

    if (-not (Test-Path $runner)) {
        throw "Formatter runner not found: $runner"
    }

    powershell -NoProfile -ExecutionPolicy Bypass -File $runner @FormatArgs
}

'@

$ProfileContent = ""

if (Test-Path $PROFILE) {
    $ProfileContent = Get-Content $PROFILE -Raw
}

if ($ProfileContent -like "*function sqlfmt*") {
    Write-Host "PowerShell profile already contains a sqlfmt function."
    Write-Host "Profile:" $PROFILE
}
else {
    Add-Content -Path $PROFILE -Value $FunctionBlock
    Write-Host "Added sqlfmt function to PowerShell profile:"
    Write-Host $PROFILE
}

Write-Host ""
Write-Host "Set DBEAVER_SQL_FORMATTER_HOME to:"
Write-Host $ProjectRoot
Write-Host ""
Write-Host "Restart PowerShell, then test with:"
Write-Host "  sqlfmt --list"
Write-Host "  sqlfmt --check"