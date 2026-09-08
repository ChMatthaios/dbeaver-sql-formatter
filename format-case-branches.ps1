<#
    Multiline CASE branch repair for the Windows application.

    The main beautifier intentionally stays conservative around complex expressions.
    A long searched CASE can therefore arrive here with later WHEN branches still
    attached to the previous THEN result. This pass only runs when the advanced
    CASE style is Multiline and separates CASE branch boundaries without changing
    expressions, literals, comments, or SQL semantics.
#>

$ErrorActionPreference = 'Stop'

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$settingsPath = Join-Path $PSScriptRoot 'settings\settings.json'
if (-not (Test-Path $settingsPath)) {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

try {
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
}
catch {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

if (-not ($settings.PSObject.Properties.Name -contains 'advanced') -or
    $null -eq $settings.advanced -or
    -not [bool]$settings.advanced.enabled -or
    $null -eq $settings.advanced.case -or
    [string]$settings.advanced.case.style -ne 'Multiline') {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

# Do not reinterpret stored-program or dollar-quoted bodies.
$normalizedInput = ($inputSql -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
if ($normalizedInput -match '^(?i)(CREATE|ALTER)\s+(?:(?:OR\s+(?:REPLACE|ALTER))\s+)?(?:EDITIONABLE\s+|NONEDITIONABLE\s+)?(PROCEDURE|PROC|FUNCTION|TRIGGER|PACKAGE(?:\s+BODY)?|TYPE\s+BODY)\b' -or
    $inputSql -match '(?s)\$\$|\$[A-Za-z_][A-Za-z0-9_]*\$') {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

$indentSize = 2
$maxLineLength = 120
if ($settings.PSObject.Properties.Name -contains 'indentSize') {
    $parsed = 0
    if ([int]::TryParse([string]$settings.indentSize, [ref]$parsed) -and $parsed -in @(2, 4)) {
        $indentSize = $parsed
    }
}
if ($settings.PSObject.Properties.Name -contains 'maxLineLength') {
    $parsed = 0
    if ([int]::TryParse([string]$settings.maxLineLength, [ref]$parsed) -and $parsed -ge 60 -and $parsed -le 400) {
        $maxLineLength = $parsed
    }
}

$thenMode = if ($settings.advanced.case.PSObject.Properties.Name -contains 'thenResult') {
    [string]$settings.advanced.case.thenResult
} else { 'Preserve' }
$elseMode = if ($settings.advanced.case.PSObject.Properties.Name -contains 'elseResult') {
    [string]$settings.advanced.case.elseResult
} else { 'Preserve' }

function Mask-CaseLine {
    param([string]$Line, [ref]$InBlockComment)

    $chars = $Line.ToCharArray()
    $single = $false
    $double = $false
    $bracket = $false

    for ($i = 0; $i -lt $chars.Length; $i++) {
        $ch = $chars[$i]
        $next = if ($i + 1 -lt $chars.Length) { $chars[$i + 1] } else { [char]0 }

        if ($InBlockComment.Value) {
            $chars[$i] = ' '
            if ($ch -eq '*' -and $next -eq '/') {
                $chars[$i + 1] = ' '
                $InBlockComment.Value = $false
                $i++
            }
            continue
        }

        if ($single) {
            $chars[$i] = ' '
            if ($ch -eq "'") {
                if ($next -eq "'") {
                    $chars[$i + 1] = ' '
                    $i++
                }
                else { $single = $false }
            }
            continue
        }
        if ($double) {
            $chars[$i] = ' '
            if ($ch -eq '"') {
                if ($next -eq '"') {
                    $chars[$i + 1] = ' '
                    $i++
                }
                else { $double = $false }
            }
            continue
        }
        if ($bracket) {
            $chars[$i] = ' '
            if ($ch -eq ']') {
                if ($next -eq ']') {
                    $chars[$i + 1] = ' '
                    $i++
                }
                else { $bracket = $false }
            }
            continue
        }

        if ($ch -eq '-' -and $next -eq '-') {
            for ($j = $i; $j -lt $chars.Length; $j++) { $chars[$j] = ' ' }
            break
        }
        if ($ch -eq '/' -and $next -eq '*') {
            $chars[$i] = ' '
            $chars[$i + 1] = ' '
            $InBlockComment.Value = $true
            $i++
            continue
        }
        if ($ch -eq "'") { $chars[$i] = ' '; $single = $true; continue }
        if ($ch -eq '"') { $chars[$i] = ' '; $double = $true; continue }
        if ($ch -eq '[') { $chars[$i] = ' '; $bracket = $true; continue }
    }

    return (-join $chars)
}

function Has-VisibleText {
    param([string]$Text, [int]$Start, [int]$End)

    if ($End -le $Start) { return $false }
    return -not [string]::IsNullOrWhiteSpace($Text.Substring($Start, $End - $Start))
}

function Expand-CaseBoundaries {
    param([string[]]$Lines)

    $out = New-Object System.Collections.Generic.List[string]
    $caseIndents = New-Object System.Collections.Generic.List[int]
    $inBlockComment = $false

    foreach ($line in $Lines) {
        $masked = Mask-CaseLine -Line $line -InBlockComment ([ref]$inBlockComment)
        $tokens = [regex]::Matches($masked, '(?i)\b(CASE|WHEN|THEN|ELSE|END)\b')
        $breaks = New-Object System.Collections.Generic.List[object]
        $segmentStart = 0

        foreach ($token in $tokens) {
            $kind = $token.Groups[1].Value.ToUpperInvariant()

            if ($kind -eq 'CASE') {
                $caseIndents.Add($token.Index)
                continue
            }

            if ($kind -eq 'WHEN' -or $kind -eq 'ELSE') {
                if ($caseIndents.Count -gt 0 -and (Has-VisibleText -Text $line -Start $segmentStart -End $token.Index)) {
                    $branchIndent = $caseIndents[$caseIndents.Count - 1] + $indentSize
                    $breaks.Add([pscustomobject]@{ Index = $token.Index; Indent = $branchIndent })
                    $segmentStart = $token.Index
                }
                continue
            }

            if ($kind -eq 'END' -and $caseIndents.Count -gt 0) {
                $caseIndent = $caseIndents[$caseIndents.Count - 1]
                if (Has-VisibleText -Text $line -Start $segmentStart -End $token.Index) {
                    $breaks.Add([pscustomobject]@{ Index = $token.Index; Indent = $caseIndent })
                    $segmentStart = $token.Index
                }
                $caseIndents.RemoveAt($caseIndents.Count - 1)
            }
        }

        if ($breaks.Count -eq 0) {
            $out.Add($line)
            continue
        }

        $start = 0
        $currentIndent = 0
        foreach ($break in $breaks) {
            $piece = $line.Substring($start, $break.Index - $start)
            if ($start -eq 0) {
                $piece = $piece.TrimEnd()
                if (-not [string]::IsNullOrWhiteSpace($piece)) { $out.Add($piece) }
            }
            else {
                $piece = $piece.Trim()
                if ($piece) { $out.Add((' ' * $currentIndent) + $piece) }
            }

            $start = $break.Index
            $currentIndent = [int]$break.Indent
        }

        $tail = $line.Substring($start).Trim()
        if ($tail) { $out.Add((' ' * $currentIndent) + $tail) }
    }

    return $out.ToArray()
}

function Apply-ThenPlacement {
    param([string[]]$Lines, [string]$Mode)

    if ($Mode -eq 'NewLine') {
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($line in $Lines) {
            $m = [regex]::Match($line, '^(?<indent>\s*)WHEN\s+(?<condition>.+?)\s+THEN\s+(?<result>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $out.Add($m.Groups['indent'].Value + 'WHEN ' + $m.Groups['condition'].Value)
                $out.Add($m.Groups['indent'].Value + 'THEN ' + $m.Groups['result'].Value)
            }
            else { $out.Add($line) }
        }
        return $out.ToArray()
    }

    if ($Mode -eq 'SameLine') {
        $out = New-Object System.Collections.Generic.List[string]
        $i = 0
        while ($i -lt $Lines.Count) {
            if ($i + 1 -lt $Lines.Count -and
                $Lines[$i].TrimStart() -match '^(?i)WHEN\b' -and
                $Lines[$i + 1].TrimStart() -match '^(?i)THEN\b') {
                $candidate = $Lines[$i].TrimEnd() + ' ' + $Lines[$i + 1].TrimStart()
                if ($candidate.Length -le $maxLineLength) {
                    $out.Add($candidate)
                    $i += 2
                    continue
                }
            }
            $out.Add($Lines[$i])
            $i++
        }
        return $out.ToArray()
    }

    return $Lines
}

function Apply-ElsePlacement {
    param([string[]]$Lines, [string]$Mode)

    if ($Mode -eq 'NewLine') {
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($line in $Lines) {
            $m = [regex]::Match($line, '^(?<indent>\s*)ELSE\s+(?<result>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $out.Add($m.Groups['indent'].Value + 'ELSE')
                $out.Add($m.Groups['indent'].Value + (' ' * $indentSize) + $m.Groups['result'].Value)
            }
            else { $out.Add($line) }
        }
        return $out.ToArray()
    }

    if ($Mode -eq 'SameLine') {
        $out = New-Object System.Collections.Generic.List[string]
        $i = 0
        while ($i -lt $Lines.Count) {
            if ($i + 1 -lt $Lines.Count -and
                $Lines[$i].Trim() -match '^(?i)ELSE$' -and
                $Lines[$i + 1].TrimStart() -notmatch '^(?i)(WHEN|END|THEN|ELSE)\b') {
                $candidate = $Lines[$i].TrimEnd() + ' ' + $Lines[$i + 1].TrimStart()
                if ($candidate.Length -le $maxLineLength) {
                    $out.Add($candidate)
                    $i += 2
                    continue
                }
            }
            $out.Add($Lines[$i])
            $i++
        }
        return $out.ToArray()
    }

    return $Lines
}

$lines = @(($inputSql -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")
$lines = Expand-CaseBoundaries $lines
$lines = Apply-ThenPlacement -Lines $lines -Mode $thenMode
$lines = Apply-ElsePlacement -Lines $lines -Mode $elseMode

[Console]::Out.Write(($lines -join [Environment]::NewLine).TrimEnd())
