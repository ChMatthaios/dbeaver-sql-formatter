<#
    Final CASE-condition presentation pass for the Windows UI.

    Multiline CASE expressions can still contain complete nested queries or
    compound predicates on a single WHEN line after the generic beautifier.
    This pass keeps the normal dialect formatter as the source of truth:
      - an inline EXISTS (SELECT ...) is formatted as its own query and then
        placed back under the WHEN prefix;
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

    foreach ($line in $Lines) {
        $m = [regex]::Match(
            $line,
            '^(?<indent>\s*)WHEN\s+EXISTS\s*\(',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $m.Success) {
            $out.Add($line)
            continue
        }

        $open = $line.IndexOf('(', $m.Index)
        if ($open -lt 0) {
            $out.Add($line)
            continue
        }

        $close = Find-MatchingParen -Text $line -OpenIndex $open
        if ($close -lt 0 -or $line.Substring($close + 1).Trim().Length -gt 0) {
            $out.Add($line)
            continue
        }

        $inner = $line.Substring($open + 1, $close - $open - 1).Trim()
        if ($inner -notmatch '^(?i)(SELECT|WITH)\b') {
            $out.Add($line)
            continue
        }

        $nested = $inner |
            powershell -NoProfile -ExecutionPolicy Bypass -File $formatter |
            Out-String
        $nested = $nested.TrimEnd("`r", "`n")
        $nestedLines = @($nested -split "`r?`n")

        if ($nestedLines.Count -le 1) {
            $out.Add($line)
            continue
        }

        $prefix = $m.Groups['indent'].Value + 'WHEN EXISTS ('
        $out.Add($prefix + $nestedLines[0].TrimStart())

        $placement = ' ' * $prefix.Length
        for ($i = 1; $i -lt $nestedLines.Count; $i++) {
            $placed = $placement + $nestedLines[$i]
            if ($i -eq $nestedLines.Count - 1) { $placed += ')' }
            $out.Add($placed)
        }
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
            for ($i = 1; $i -lt $parts.Count; $i++) {
                $out.Add($indent + ' ' + $parts[$i].Operator + ' ' + $parts[$i].Text)
            }
        }
        else {
            for ($i = 0; $i -lt $parts.Count; $i++) {
                if ($i -eq 0) { $text = $indent + 'WHEN ' + $parts[$i].Text }
                else { $text = $indent + (' ' * 5) + $parts[$i].Text }

                if ($i + 1 -lt $parts.Count) { $text += ' ' + $parts[$i + 1].Operator }
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
