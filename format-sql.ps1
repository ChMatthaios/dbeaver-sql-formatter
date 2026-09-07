<#
    Public formatter entry point.

    format-sql-base.ps1 contains the dialect-routing formatter. This thin wrapper
    applies the shared semantic presentation pass afterwards so DBeaver, CLI and
    the Windows app always produce the same final layout.
#>

$ErrorActionPreference = 'Stop'

$BaseFormatter = Join-Path $PSScriptRoot 'format-sql-base.ps1'
$SemanticPolish = Join-Path $PSScriptRoot 'format-semantic-polish.ps1'

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

# The formatter must never change transaction/isolation semantics. Remember a
# trailing DB2 isolation clause so it can be restored if an inner formatting path
# accidentally drops it while handling a complex WITH/FETCH statement.
$trailingIsolation = [regex]::Match(
    $inputSql,
    '(?is)\bWITH\s+(UR|RS|CS|RR|NC)\s*;\s*$'
)

$formatted = $inputSql |
    powershell -NoProfile -ExecutionPolicy Bypass -File $BaseFormatter |
    Out-String
$formatted = $formatted.TrimEnd("`r", "`n")

if (-not [string]::IsNullOrWhiteSpace($formatted)) {
    $formatted = $formatted |
        powershell -NoProfile -ExecutionPolicy Bypass -File $SemanticPolish |
        Out-String
    $formatted = $formatted.TrimEnd("`r", "`n")
}

if ($trailingIsolation.Success) {
    $isolation = 'WITH ' + $trailingIsolation.Groups[1].Value.ToUpperInvariant()
    if ($formatted -notmatch ('(?is)\b' + [regex]::Escape($isolation) + '\s*;\s*$')) {
        $formatted = $formatted.TrimEnd()
        if ($formatted.EndsWith(';')) {
            $formatted = $formatted.Substring(0, $formatted.Length - 1).TrimEnd()
        }
        $formatted += [Environment]::NewLine + '  ' + $isolation + ';'
    }
}

[Console]::Out.Write($formatted)