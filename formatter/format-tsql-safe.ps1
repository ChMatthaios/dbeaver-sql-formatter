<#
    Semantic safety wrapper for T-SQL formatting.

    The structural T-SQL engine does the formatting. This wrapper protects a
    trailing SELECT OPTION(...) query hint from accidental loss during clause
    reconstruction. It only restores the clause when the original selected SQL
    ends with OPTION(...) and the formatted output does not already contain it.
#>

$ErrorActionPreference = 'Stop'
$Engine = Join-Path $PSScriptRoot 'format-tsql.ps1'

function Normalize-TsqlOptionClause {
    param([string]$Clause)

    $text = ($Clause -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
    $keywords = @(
        'option','recompile','maxdop','optimize','for','unknown','force','order',
        'hash','loop','merge','join','use','hint','parameterization','simple','forced',
        'keep','plan','keepfixed','robust','fast','maxrecursion','querytraceon'
    )
    foreach ($kw in $keywords) {
        $escaped = [regex]::Escape($kw)
        $text = [regex]::Replace(
            $text,
            "(?i)(?<![A-Z0-9_])$escaped(?![A-Z0-9_])",
            { param($m) $m.Value.ToUpperInvariant() }
        )
    }
    return $text
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$formatted = $inputSql |
    powershell -NoProfile -ExecutionPolicy Bypass -File $Engine |
    Out-String
$formatted = $formatted.TrimEnd("`r", "`n")

# OPTION(...) is a trailing query-hint clause in T-SQL. The engine normally
# preserves it. Keep this postcondition as a semantic guard for SELECT forms
# whose OFFSET/FETCH reconstruction could otherwise terminate before OPTION.
$option = [regex]::Match(
    $inputSql,
    '(?is)\bOPTION\s*\((?<body>[^;]*)\)\s*;?\s*$'
)

if ($option.Success -and $formatted -notmatch '(?is)\bOPTION\s*\([^;]*\)\s*;?\s*$') {
    $clause = Normalize-TsqlOptionClause -Clause $option.Value
    $clause = $clause -replace ';\s*$', ''
    $formatted = $formatted.TrimEnd()
    $formatted = $formatted -replace ';\s*$', ''
    $formatted += [Environment]::NewLine + ' OPTION ' + (($clause -replace '^(?i)OPTION\s*', '').Trim()) + ';'
}

[Console]::Out.Write($formatted)
