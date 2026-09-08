<#
    Final CASE-condition presentation pass for the Windows UI.

    Multiline CASE expressions can still contain complete nested queries or
    compound predicates on a WHEN line after the generic beautifier.
    This pass keeps the normal dialect formatter as the source of truth:
      - EXISTS (SELECT ...) is formatted as its own query and then placed back
        under the WHEN prefix, whether it arrived inline or already multiline;
      - top-level AND / OR predicates in a WHEN condition honor the configured
        boolean-operator position without splitting BETWEEN ... AND ... .
#>

$ErrorActionPreference = 'Stop'

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$settingsPath = Join-Path $PSScriptRoot 'settings\settings.json'
$formatter = Join-Path $PSScriptRoot 'format-sql.ps1'

try {
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
}
catch {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

if ($null -eq $settings.advanced -or
    -not [bool]$settings.advanced.enabled -or
    [string]$settings.advanced.case.style -ne 'Multiline') {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

$booleanMode = [string]$settings.advanced.clauses.booleanOperatorPosition

function Find-MatchingParen {
    param([string]$Text, [int]$OpenIndex)

    $depth = 0
    $single = $false
    $double = $false
    $bracket = $false

    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]

        if ($single) {
            if ($ch -eq "'") {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++ }
                else { $single = $false }
            }
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i++ }
                else { $double = $false }
            }
            continue
        }
        if ($bracket) {
            if ($ch -eq ']') {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq ']') { $i++ }
                else { $bracket = $false }
            }
            continue
        }

        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '[') { $bracket = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }

    return -1
}

function Expand-InlineExists {
    param([string[]]$Lines)

    $out = New-Object System.Collections.Generic.List[string]
    $i = 0

    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        $m = [regex]::Match(
            $line,
            '^(?<indent>\s*)WHEN\s+EXISTS\s*\(',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $m.Success) {
            $out.Add($line)
            $i++
            continue
        }

        $openInFirstLine = $line.IndexOf('(', $m.Index)
        if ($openInFirstLine -lt 0) {
            $out.Add($line)
            $i++
            continue
        }

        # The prior CASE pass may already have placed the SELECT and closing ) on
        # following lines. Gather the complete EXISTS parenthesized expression.
        $block = $line
        $close = Find-MatchingParen -Text $block -OpenIndex $openInFirstLine
        $j = $i + 1
        while ($close -lt 0 -and $j -lt $Lines.Count) {
            $block += [Environment]::NewLine + $Lines[$j]
            $close = Find-MatchingParen -Text $block -OpenIndex $openInFirstLine
            $j++
        }

        if ($close -lt 0) {
            $out.Add($line)
            $i++
            continue
        }

        $inner = $block.Substring($openInFirstLine + 1, $close - $openInFirstLine - 1).Trim()
        $tail = $block.Substring($close + 1).Trim()
        if ($inner -notmatch '^(?i)(SELECT|WITH)\b') {
            for ($k = $i; $k -lt $j; $k++) { $out.Add($Lines[$k]) }
            $i = $j
            continue
        }

        $nested = $inner |
            powershell -NoProfile -ExecutionPolicy Bypass -File $formatter |
            Out-String
        $nested = $nested.TrimEnd("`r", "`n")
        $nestedLines = @($nested -split "`r?`n")

        # A nested SELECT is a query unit, not just text belonging to WHEN.
        # If the shared formatter kept this very small query on one line, make
        # the major SELECT clauses explicit before placement so the parent CASE
        # cannot collapse it back into the condition line.
        if ($nestedLines.Count -eq 1) {
            $fallback = $nestedLines[0].Trim()
            $fallback = [regex]::Replace($fallback, '\s+(FROM)\s+', [Environment]::NewLine + '  FROM ', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $fallback = [regex]::Replace($fallback, '\s+(WHERE)\s+', [Environment]::NewLine + ' WHERE ', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $fallback = [regex]::Replace($fallback, '\s+(AND)\s+', [Environment]::NewLine + '   AND ', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $nestedLines = @($fallback -split "`r?`n")
        }

        $prefix = $m.Groups['indent'].Value + 'WHEN EXISTS ('
        $out.Add($prefix + $nestedLines[0].TrimStart())

        $placement = ' ' * $prefix.Length
        for ($n = 1; $n -lt $nestedLines.Count; $n++) {
            $placed = $placement + $nestedLines[$n]
            if ($n -eq $nestedLines.Count - 1) {
                $placed += ')'
                if ($tail) { $placed += ' ' + $tail }
            }
            $out.Add($placed)
        }

        if ($nestedLines.Count -eq 1) {
            $out[$out.Count - 1] += ')'
            if ($tail) { $out[$out.Count - 1] += ' ' + $tail }
        }

        $i = $j
    }

    return $out.ToArray()
}

function Split-TopLevelBoolean {
    param([string]$Condition)

    $parts = New-Object System.Collections.Generic.List[object]
    $depth = 0
    $single = $false
    $double = $false
    $bracket = $false
    $betweenPending = $false
    $start = 0
    $pendingOp = ''
    $i = 0

    while ($i -lt $Condition.Length) {
        $ch = $Condition[$i]

        if ($single) {
            if ($ch -eq "'") {
                if ($i + 1 -lt $Condition.Length -and $Condition[$i + 1] -eq "'") { $i += 2; continue }
                $single = $false
            }
            $i++; continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $Condition.Length -and $Condition[$i + 1] -eq '"') { $i += 2; continue }
                $double = $false
            }
            $i++; continue
        }
        if ($bracket) {
            if ($ch -eq ']') {
                if ($i + 1 -lt $Condition.Length -and $Condition[$i + 1] -eq ']') { $i += 2; continue }
                $bracket = $false
            }
            $i++; continue
        }

        if ($ch -eq "'") { $single = $true; $i++; continue }
        if ($ch -eq '"') { $double = $true; $i++; continue }
        if ($ch -eq '[') { $bracket = $true; $i++; continue }
        if ($ch -eq '(') { $depth++; $i++; continue }
        if ($ch -eq ')') { if ($depth -gt 0) { $depth-- }; $i++; continue }

        if ($depth -eq 0 -and [char]::IsLetter($ch)) {
            $wordStart = $i
            while ($i -lt $Condition.Length -and ([char]::IsLetterOrDigit($Condition[$i]) -or $Condition[$i] -eq '_')) { $i++ }
            $word = $Condition.Substring($wordStart, $i - $wordStart).ToUpperInvariant()

            if ($word -eq 'BETWEEN') {
                $betweenPending = $true
                continue
            }

            if ($word -eq 'AND' -and $betweenPending) {
                $betweenPending = $false
                continue
            }

            if ($word -in @('AND', 'OR')) {
                $piece = $Condition.Substring($start, $wordStart - $start).Trim()
                if ($piece) {
                    $parts.Add([pscustomobject]@{ Operator = $pendingOp; Text = $piece })
                }
                $pendingOp = $word
                $start = $i
                continue
            }

            continue
        }

        $i++
    }

    $tail = $Condition.Substring($start).Trim()
    if ($tail) {
        $parts.Add([pscustomobject]@{ Operator = $pendingOp; Text = $tail })
    }

    return $parts.ToArray()
}

function Expand-CaseBooleanConditions {
    param([string[]]$Lines)

    if ($booleanMode -notin @('Leading', 'Trailing')) { return $Lines }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $m = [regex]::Match(
            $line,
            '^(?<indent>\s*)WHEN\s+(?<condition>.+)$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $m.Success -or $m.Groups['condition'].Value -match '^(?i)EXISTS\s*\(') {
            $out.Add($line)
            continue
        }

        $parts = @(Split-TopLevelBoolean $m.Groups['condition'].Value)
        if ($parts.Count -lt 2) {
            $out.Add($line)
            continue
        }

        $indent = $m.Groups['indent'].Value
        if ($booleanMode -eq 'Leading') {
            $out.Add($indent + 'WHEN ' + $parts[0].Text)
            for ($n = 1; $n -lt $parts.Count; $n++) {
                $out.Add($indent + ' ' + $parts[$n].Operator + ' ' + $parts[$n].Text)
            }
        }
        else {
            for ($n = 0; $n -lt $parts.Count; $n++) {
                if ($n -eq 0) { $text = $indent + 'WHEN ' + $parts[$n].Text }
                else { $text = $indent + (' ' * 5) + $parts[$n].Text }

                if ($n + 1 -lt $parts.Count) { $text += ' ' + $parts[$n + 1].Operator }
                $out.Add($text)
            }
        }
    }

    return $out.ToArray()
}

$lines = @(($inputSql -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")
$lines = Expand-InlineExists $lines
$lines = Expand-CaseBooleanConditions $lines

[Console]::Out.Write(($lines -join [Environment]::NewLine).TrimEnd())
