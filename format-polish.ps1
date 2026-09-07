<#
    Final structural polish for formatted DB2 SQL.

    The core formatter deliberately stays heuristic. This pass fixes two cases
    where generic word wrapping is syntactically safe but visually poor:
      - long CASE WHEN conditions: keep the condition intact and move THEN down
        before breaking inside a function call;
      - long parenthesized AND/OR groups: split on their logical operators and
        align each expression, rather than wrapping arbitrary words.
#>

$ErrorActionPreference = "Stop"
$script:MaxLineLength = 120

$settingsPath = Join-Path $PSScriptRoot "settings\settings.json"
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties.Name -contains "maxLineLength") {
            $value = 0
            if ([int]::TryParse([string]$settings.maxLineLength, [ref]$value) -and $value -ge 60 -and $value -le 400) {
                $script:MaxLineLength = $value
            }
        }
    }
    catch {
        # Invalid local settings must never break DBeaver formatting.
    }
}

function Normalize-Inline {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim())
}

function Get-LeadingWhitespace {
    param([string]$Text)
    $m = [regex]::Match($Text, '^\s*')
    return $m.Value
}

function Get-ParenDelta {
    param([string]$Text)

    $depth = 0
    $single = $false
    $double = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]

        if ($single) {
            if ($ch -eq "'") {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") {
                    $i++
                }
                else {
                    $single = $false
                }
            }
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') {
                    $i++
                }
                else {
                    $double = $false
                }
            }
            continue
        }

        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') { $depth-- }
    }
    return $depth
}

function Split-TopLevelLogical {
    param([string]$Text)

    $text = Normalize-Inline $Text
    $parts = New-Object System.Collections.Generic.List[object]
    $depth = 0
    $start = 0
    $currentOp = ''
    $betweenNeedsAnd = $false
    $single = $false
    $double = $false
    $i = 0

    while ($i -lt $text.Length) {
        $ch = $text[$i]

        if ($single) {
            if ($ch -eq "'") {
                if ($i + 1 -lt $text.Length -and $text[$i + 1] -eq "'") { $i += 2; continue }
                $single = $false
            }
            $i++
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $text.Length -and $text[$i + 1] -eq '"') { $i += 2; continue }
                $double = $false
            }
            $i++
            continue
        }

        if ($ch -eq "'") { $single = $true; $i++; continue }
        if ($ch -eq '"') { $double = $true; $i++; continue }
        if ($ch -eq '(') { $depth++; $i++; continue }
        if ($ch -eq ')') { if ($depth -gt 0) { $depth-- }; $i++; continue }

        if ($depth -eq 0) {
            $rest = $text.Substring($i)
            $between = [regex]::Match($rest, '^BETWEEN\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($between.Success) {
                $betweenNeedsAnd = $true
                $i += $between.Length
                continue
            }

            $logical = [regex]::Match($rest, '^(AND|OR)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($logical.Success) {
                $op = $logical.Groups[1].Value.ToUpperInvariant()
                if ($op -eq 'AND' -and $betweenNeedsAnd) {
                    $betweenNeedsAnd = $false
                    $i += $logical.Length
                    continue
                }

                $piece = Normalize-Inline ($text.Substring($start, $i - $start))
                if ($piece) {
                    $parts.Add([pscustomobject]@{ Op = $currentOp; Text = $piece })
                }
                $currentOp = $op
                $start = $i + $logical.Length
                $i = $start
                continue
            }
        }

        $i++
    }

    $tail = Normalize-Inline ($text.Substring($start))
    if ($tail) {
        $parts.Add([pscustomobject]@{ Op = $currentOp; Text = $tail })
    }
    return $parts
}

function Get-SafeBreakIndex {
    param([string]$Text, [int]$Maximum)

    if ($Maximum -le 0) { return -1 }
    $depth = 0
    $single = $false
    $double = $false
    $last = -1
    $limit = [Math]::Min($Maximum, $Text.Length - 1)

    for ($i = 0; $i -le $limit; $i++) {
        $ch = $Text[$i]
        if ($single) {
            if ($ch -eq "'") {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
                $single = $false
            }
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i++; continue }
                $double = $false
            }
            continue
        }

        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') { if ($depth -gt 0) { $depth-- }; continue }
        if ($ch -eq ' ' -and $depth -eq 0) { $last = $i }
    }
    return $last
}

function Wrap-ExpressionSafely {
    param(
        [string]$Text,
        [string]$FirstPrefix,
        [string]$ContinuationPrefix
    )

    $remaining = Normalize-Inline $Text
    $out = New-Object System.Collections.Generic.List[string]
    $prefix = $FirstPrefix

    while (($prefix + $remaining).Length -gt $script:MaxLineLength) {
        $available = $script:MaxLineLength - $prefix.Length
        $break = Get-SafeBreakIndex -Text $remaining -Maximum $available
        if ($break -le 0) {
            # There is no syntactically sensible break outside parentheses.
            # Keep the expression whole; upstream validation will expose a truly
            # unbreakable token rather than splitting a function call in half.
            break
        }
        $out.Add($prefix + $remaining.Substring(0, $break).TrimEnd())
        $remaining = $remaining.Substring($break + 1).TrimStart()
        $prefix = $ContinuationPrefix
    }

    $out.Add($prefix + $remaining)
    return $out
}

function Format-LongCaseWhen {
    param([string[]]$Lines, [int]$Start)

    $first = $Lines[$Start]
    $trimmed = $first.TrimStart()
    if ($trimmed -notmatch '^(?i)WHEN\b') { return $null }

    $end = $Start
    $pieces = New-Object System.Collections.Generic.List[string]
    $pieces.Add($trimmed)
    while ($end -lt $Lines.Count - 1 -and (($pieces -join ' ') -notmatch '(?i)\bTHEN\b')) {
        $nextTrim = $Lines[$end + 1].TrimStart()
        if ($nextTrim -match '^(?i)(WHEN|ELSE|END)\b') { break }
        $end++
        $pieces.Add($nextTrim)
    }

    $joined = Normalize-Inline ($pieces -join ' ')
    $m = [regex]::Match($joined, '^(?i)WHEN\s+(.+?)\s+THEN\s+(.+)$')
    if (-not $m.Success) { return $null }

    $indent = Get-LeadingWhitespace $first
    $condition = Normalize-Inline $m.Groups[1].Value
    $result = Normalize-Inline $m.Groups[2].Value
    $compact = $indent + 'WHEN ' + $condition + ' THEN ' + $result

    # Leave genuinely short WHEN lines untouched.
    if ($end -eq $Start -and $compact.Length -le $script:MaxLineLength) { return $null }

    $conditionLine = $indent + 'WHEN ' + $condition
    $formatted = New-Object System.Collections.Generic.List[string]

    if ($conditionLine.Length -le $script:MaxLineLength) {
        $formatted.Add($conditionLine)
    }
    else {
        $logical = @(Split-TopLevelLogical $condition)
        if ($logical.Count -gt 1) {
            $expressionColumn = $indent.Length + 5
            for ($i = 0; $i -lt $logical.Count; $i++) {
                if ($i -eq 0) {
                    $prefix = $indent + 'WHEN '
                }
                else {
                    $op = $logical[$i].Op
                    $prefix = (' ' * [Math]::Max(0, $expressionColumn - ($op.Length + 1))) + $op + ' '
                }
                foreach ($line in @(Wrap-ExpressionSafely -Text $logical[$i].Text -FirstPrefix $prefix -ContinuationPrefix (' ' * $expressionColumn))) {
                    $formatted.Add($line)
                }
            }
        }
        else {
            foreach ($line in @(Wrap-ExpressionSafely -Text $condition -FirstPrefix ($indent + 'WHEN ') -ContinuationPrefix ($indent + '     '))) {
                $formatted.Add($line)
            }
        }
    }

    foreach ($line in @(Wrap-ExpressionSafely -Text $result -FirstPrefix ($indent + 'THEN ') -ContinuationPrefix ($indent + '     '))) {
        $formatted.Add($line)
    }

    return [pscustomobject]@{ End = $end; Lines = @($formatted) }
}

function Format-ParenthesizedLogicalGroup {
    param([string[]]$Lines, [int]$Start)

    $first = $Lines[$Start]
    $trimmed = $first.TrimStart()
    $m = [regex]::Match($trimmed, '^(?i)(WHERE|AND|OR)\s+\(')
    if (-not $m.Success) { return $null }

    $open = $trimmed.IndexOf('(', $m.Index + $m.Length - 1)
    if ($open -lt 0) { return $null }

    $balance = Get-ParenDelta ($trimmed.Substring($open))
    $end = $Start
    $pieces = New-Object System.Collections.Generic.List[string]
    $pieces.Add($trimmed)

    while ($balance -gt 0 -and $end -lt $Lines.Count - 1) {
        $end++
        $piece = $Lines[$end].Trim()
        $pieces.Add($piece)
        $balance += Get-ParenDelta $piece
    }

    if ($balance -ne 0) { return $null }

    $joined = Normalize-Inline ($pieces -join ' ')
    $group = [regex]::Match($joined, '^(?i)(WHERE|AND|OR)\s+\((.*)\)$')
    if (-not $group.Success) { return $null }

    $inner = Normalize-Inline $group.Groups[2].Value
    # Subqueries already have recursive formatting in the core. Do not flatten
    # them back into text in this final presentation pass.
    if ($inner -match '(?i)\(\s*(SELECT|WITH)\b') { return $null }

    $logical = @(Split-TopLevelLogical $inner)
    if ($logical.Count -lt 2) { return $null }

    $indent = Get-LeadingWhitespace $first
    $clause = $group.Groups[1].Value.ToUpperInvariant()
    $firstPrefix = $indent + $clause + ' (  '
    $expressionColumn = $firstPrefix.Length
    $formatted = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $logical.Count; $i++) {
        if ($i -eq 0) {
            $prefix = $firstPrefix
        }
        else {
            $op = $logical[$i].Op
            $prefix = (' ' * [Math]::Max(0, $expressionColumn - ($op.Length + 1))) + $op + ' '
        }
        foreach ($line in @(Wrap-ExpressionSafely -Text $logical[$i].Text -FirstPrefix $prefix -ContinuationPrefix (' ' * $expressionColumn))) {
            $formatted.Add($line)
        }
    }

    if (($formatted[$formatted.Count - 1] + ')').Length -le $script:MaxLineLength) {
        $formatted[$formatted.Count - 1] = $formatted[$formatted.Count - 1] + ')'
    }
    else {
        $formatted.Add((' ' * ($indent.Length + $clause.Length + 1)) + ')')
    }

    return [pscustomobject]@{ End = $end; Lines = @($formatted) }
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$lines = @(($inputSql -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")
$out = New-Object System.Collections.Generic.List[string]
$i = 0

while ($i -lt $lines.Count) {
    $case = Format-LongCaseWhen -Lines $lines -Start $i
    if ($null -ne $case) {
        foreach ($line in $case.Lines) { $out.Add($line) }
        $i = $case.End + 1
        continue
    }

    $group = Format-ParenthesizedLogicalGroup -Lines $lines -Start $i
    if ($null -ne $group) {
        foreach ($line in $group.Lines) { $out.Add($line) }
        $i = $group.End + 1
        continue
    }

    $out.Add($lines[$i])
    $i++
}

[Console]::Out.Write(($out -join [Environment]::NewLine).TrimEnd())