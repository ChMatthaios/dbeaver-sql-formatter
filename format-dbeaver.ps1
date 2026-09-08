<#
    DBeaver formatter entry point.

    DBeaver must produce the exact same output as the Windows application's SQL
    editor. Therefore this wrapper delegates directly to format-ui-script.ps1,
    which is the shared script-level presentation pipeline used by the UI.

    Dialect detection still happens underneath in format-sql.ps1, so the same
    DBeaver command works for DB2/common SQL, PostgreSQL, SQL Server/T-SQL,
    Oracle/PLSQL and SPARQL. The advanced formatting profile in
    settings/settings.json is shared with the Windows UI.
#>

$ErrorActionPreference = 'Stop'

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$formatter = Join-Path $PSScriptRoot 'format-ui-script.ps1'
if (-not (Test-Path $formatter)) {
    throw "Shared UI formatter was not found: $formatter"
}

$formatted = $inputSql |
    powershell -NoProfile -ExecutionPolicy Bypass -File $formatter |
    Out-String

[Console]::Out.Write($formatted.TrimEnd("`r", "`n"))
