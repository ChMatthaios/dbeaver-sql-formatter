<#
    Windows UI formatter entry point.

    The desktop app first runs the same format-sql.ps1 engine used by DBeaver,
    then applies UI-only semantic presentation passes for complex expressions,
    and finally applies the user's advanced beautifier preferences.
#>

$ErrorActionPreference = 'Stop'
$Formatter = Join-Path $PSScriptRoot 'format-sql.ps1'
$SemanticPolish = Join-Path $PSScriptRoot 'format-semantic-polish.ps1'
$UiFinalize = Join-Path $PSScriptRoot 'format-ui-finalize.ps1'
$Beautifier = Join-Path $PSScriptRoot 'format-beautifier.ps1'

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$trailingIsolation = [regex]::Match(
    $inputSql,
    '(?is)\bWITH\s+(UR|RS|CS|RR|NC)\s*;\s*$'
)

$formatted = $inputSql |
    powershell -NoProfile -ExecutionPolicy Bypass -File $Formatter |
    Out-String
$formatted = $formatted.TrimEnd("`r", "`n")

if (-not [string]::IsNullOrWhiteSpace($formatted)) {
    # The semantic pass recognizes function-call shaped lines. A CTE's `AS (`
    # has the same superficial shape, so protect that structural token while the
    # pass works on expressions inside the CTE and restore it afterwards.
    $cteAsToken = '__SQLFMT_CTE_AS_OPEN__'
    $polishInput = [regex]::Replace(
        $formatted,
        '(?im)^(\s*)AS\s+\(',
        ('$1' + $cteAsToken)
    )

    $formatted = $polishInput |
        powershell -NoProfile -ExecutionPolicy Bypass -File $SemanticPolish |
        Out-String
    $formatted = $formatted.TrimEnd("`r", "`n")
    $formatted = $formatted.Replace($cteAsToken, 'AS (')

    $formatted = $formatted |
        powershell -NoProfile -ExecutionPolicy Bypass -File $UiFinalize |
        Out-String
    $formatted = $formatted.TrimEnd("`r", "`n")

    if (Test-Path $Beautifier) {
        $formatted = $formatted |
            powershell -NoProfile -ExecutionPolicy Bypass -File $Beautifier |
            Out-String
        $formatted = $formatted.TrimEnd("`r", "`n")
    }
}

# Formatting must never silently change DB2 isolation semantics.
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