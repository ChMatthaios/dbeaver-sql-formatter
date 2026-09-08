<#
    Semantic presentation pass shared by the DBeaver formatter and Windows app.

    The main formatter already guarantees syntactically safe output and the hard
    maxLineLength margin. This pass handles a few expressions whose readable SQL
    structure is more important than generic word wrapping:
      - analytic/window functions;
      - aggregate CASE expressions;
      - multiline function arguments;
      - BETWEEN operands;
      - compact three-value IN lists when the surrounding indentation allows it;
      - CASE WHEN ... THEN placement for logical conditions.
#>

$ErrorActionPreference = 'Stop'
$script:MaxLineLength = 120
$script:PreferredExpressionLength = 75

$settingsPath = Join-Path $PSScriptRoot 'settings\settings.json'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties.Name -contains 'maxLineLength') {
            $value = 0
            if ([int]::TryParse([string]$settings.maxLineLength, [ref]$value) -and $value -ge 60 -and $value -le 400) {
                $script:MaxLineLength = $value
            }
        }
    }
    catch {
        # Invalid local settings must never break formatting.
    }
}
$script:PreferredExpressionLength = [Math]::Min($script:PreferredExpressionLength, $script:MaxLineLength)

function Normalize-Inline {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim())
}

function Get-LeadingWhitespace {
    param([string]$Text)
    return [regex]::Match($Text, '^\s*').Value
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

        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') { $depth-- }
    }
    return $depth
}

function Find-MatchingParenInText {
    param([string]$Text, [int]$OpenIndex)

    $depth = 0
    $single = $false
    $double = $false
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
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

function Split-TopLevelByComma {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $single = $false
    $double = $false
    $start = 0

    for ($i = 0; $i -lt $Text.Length; $i++) {
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
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') { if ($depth -gt 0) { $depth-- }; continue }
        if ($ch -eq ',' -and $depth -eq 0) {
            $piece = Normalize-Inline $Text.Substring($start, $i - $start)
            if ($piece) { $items.Add($piece) }
            $start = $i + 1
        }
    }

    $tail = Normalize-Inline $Text.Substring($start)
    if ($tail) { $items.Add($tail) }
    return $items.ToArray()
}

function Find-TopLevelPhraseIndex {
    param([string]$Text, [string]$Phrase, [int]$Start = 0)

    $pattern = '^' + (($Phrase -split '\s+' | ForEach-Object { [regex]::Escape($_) }) -join '\s+') + '\b'
    $depth = 0
    $single = $false
    $double = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
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
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') { if ($depth -gt 0) { $depth-- }; continue }
        if ($depth -ne 0 -or $i -lt $Start) { continue }

        $m = [regex]::Match($Text.Substring($i), $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { return $i }
    }
    return -1
}

function Test-TopLevelLogicalCondition {
    param([string]$Text)
    return (Find-TopLevelPhraseIndex -Text $Text -Phrase 'AND') -ge 0 -or
           (Find-TopLevelPhraseIndex -Text $Text -Phrase 'OR') -ge 0
}

function Collect-BalancedItem {
    param([string[]]$Lines, [int]$Start)

    $parts = New-Object System.Collections.Generic.List[string]
    $balance = 0
    $seenParen = $false
    $end = $Start

    for ($i = $Start; $i -lt $Lines.Count; $i++) {
        $piece = $Lines[$i].Trim()
        $parts.Add($piece)
        if ($piece.Contains('(')) { $seenParen = $true }
        $balance += Get-ParenDelta $piece
        $end = $i

        if ($seenParen -and $balance -le 0) { break }
        if (-not $seenParen) { break }
    }

    return [pscustomobject]@{
        End = $end
        Text = Normalize-Inline ($parts -join ' ')
    }
}

function Get-MinPositiveIndex {
    param([int[]]$Values, [int]$Fallback)
    $valid = @($Values | Where-Object { $_ -ge 0 })
    if ($valid.Count -eq 0) { return $Fallback }
    return ($valid | Measure-Object -Minimum).Minimum
}

function Try-FormatWindowItem {
    param([string[]]$Lines, [int]$Start)

    $first = $Lines[$Start]
    $trimmed = $first.TrimStart()
    if ($trimmed -notmatch '^(?i)(ROW_NUMBER|RANK|DENSE_RANK|NTILE|PERCENT_RANK|CUME_DIST|SUM|AVG|MIN|MAX|COUNT)\s*\(') {
        return $null
    }

    # Preserve already-structured window output.
    if ($Start + 1 -lt $Lines.Count -and $trimmed -notmatch '(?i)\bOVER\s*\(' -and $Lines[$Start + 1].TrimStart() -match '^(?i)OVER\s*\(') {
        return $null
    }

    $collected = Collect-BalancedItem -Lines $Lines -Start $Start
    $text = $collected.Text
    $overMatch = [regex]::Match($text, '(?i)\s+OVER\s*\(')
    if (-not $overMatch.Success) { return $null }

    $functionText = Normalize-Inline $text.Substring(0, $overMatch.Index)
    $open = $text.IndexOf('(', $overMatch.Index)
    if ($open -lt 0) { return $null }
    $close = Find-MatchingParenInText -Text $text -OpenIndex $open
    if ($close -lt 0) { return $null }

    $window = Normalize-Inline $text.Substring($open + 1, $close - $open - 1)
    $tail = Normalize-Inline $text.Substring($close + 1)
    if (-not $window) { return $null }

    $indent = Get-LeadingWhitespace $first
    $isRanking = $functionText -match '^(?i)(ROW_NUMBER|RANK|DENSE_RANK|NTILE|PERCENT_RANK|CUME_DIST)\s*\('
    if (-not $isRanking) {
        $functionText = [regex]::Replace($functionText, '^(?i)(SUM|AVG|MIN|MAX|COUNT)\s*\(', '$1 (')
    }

    $orderIndex = Find-TopLevelPhraseIndex -Text $window -Phrase 'ORDER BY'
    $rowsIndex = Find-TopLevelPhraseIndex -Text $window -Phrase 'ROWS'
    $rangeIndex = Find-TopLevelPhraseIndex -Text $window -Phrase 'RANGE'
    $frameIndex = Get-MinPositiveIndex -Values @($rowsIndex, $rangeIndex) -Fallback $window.Length
    $partitionIndex = Find-TopLevelPhraseIndex -Text $window -Phrase 'PARTITION BY'

    $partition = ''
    if ($partitionIndex -eq 0) {
        $partitionEnd = Get-MinPositiveIndex -Values @($orderIndex, $rowsIndex, $rangeIndex) -Fallback $window.Length
        $partition = Normalize-Inline $window.Substring(12, $partitionEnd - 12)
    }

    $order = ''
    if ($orderIndex -ge 0) {
        $orderEnd = if ($frameIndex -gt $orderIndex) { $frameIndex } else { $window.Length }
        $order = Normalize-Inline $window.Substring($orderIndex + 8, $orderEnd - ($orderIndex + 8))
    }

    $frame = ''
    if ($frameIndex -lt $window.Length) {
        $frame = Normalize-Inline $window.Substring($frameIndex)
    }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($indent + $functionText)

    $overIndent = $indent.Length + $(if ($isRanking) { 5 } else { 2 })
    $contentIndent = $overIndent + 6
    if ($partition) {
        $out.Add((' ' * $overIndent) + 'OVER (PARTITION BY ' + $partition)
    }
    elseif ($order) {
        # Keep OVER itself structural even without PARTITION BY.
        $out.Add((' ' * $overIndent) + 'OVER (')
    }
    else {
        $out.Add((' ' * $overIndent) + 'OVER (' + $window)
        $out[$out.Count - 1] = $out[$out.Count - 1] + ')' + $(if ($tail) { ' ' + $tail } else { '' })
        return [pscustomobject]@{ End = $collected.End; Lines = $out.ToArray() }
    }

    if ($order) {
        $orderItems = @(Split-TopLevelByComma $order)
        $orderIndent = $contentIndent + 4
        for ($i = 0; $i -lt $orderItems.Count; $i++) {
            $prefix = if ($i -eq 0) { (' ' * $orderIndent) + 'ORDER BY ' } else { ' ' * ($orderIndent + 9) }
            $suffix = if ($i -lt $orderItems.Count - 1) { ',' } else { '' }
            $out.Add($prefix + $orderItems[$i] + $suffix)
        }
    }

    if ($frame) {
        $frameMatch = [regex]::Match($frame, '^(?i)(ROWS|RANGE)\s+BETWEEN\s+(.+)$')
        if ($frameMatch.Success) {
            $kind = $frameMatch.Groups[1].Value.ToUpperInvariant()
            $body = Normalize-Inline $frameMatch.Groups[2].Value
            $andIndex = Find-TopLevelPhraseIndex -Text $body -Phrase 'AND'
            $frameIndent = $contentIndent + 5
            if ($andIndex -ge 0) {
                $left = Normalize-Inline $body.Substring(0, $andIndex)
                $right = Normalize-Inline $body.Substring($andIndex + 3)
                $out.Add((' ' * $frameIndent) + $kind + ' BETWEEN ' + $left)
                $out.Add((' ' * ($frameIndent + 9)) + 'AND ' + $right)
            }
            else {
                $out.Add((' ' * $frameIndent) + $frame)
            }
        }
        else {
            $out.Add((' ' * ($contentIndent + 5)) + $frame)
        }
    }

    $closing = ')' + $(if ($tail) { ' ' + $tail } else { '' })
    $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + $closing
    return [pscustomobject]@{ End = $collected.End; Lines = $out.ToArray() }
}

function Try-FormatAggregateCaseItem {
    param([string[]]$Lines, [int]$Start)

    $first = $Lines[$Start]
    $trimmed = $first.TrimStart()
    $head = [regex]::Match($trimmed, '^(?i)(SUM|COUNT|AVG|MIN|MAX)(\s*)\(\s*CASE\b')
    if (-not $head.Success) { return $null }

    $collected = Collect-BalancedItem -Lines $Lines -Start $Start
    $text = $collected.Text
    $nameMatch = [regex]::Match($text, '^(?i)(SUM|COUNT|AVG|MIN|MAX)(\s*)\(')
    if (-not $nameMatch.Success) { return $null }

    $open = $text.IndexOf('(', $nameMatch.Index)
    $close = Find-MatchingParenInText -Text $text -OpenIndex $open
    if ($close -lt 0) { return $null }

    $inside = Normalize-Inline $text.Substring($open + 1, $close - $open - 1)
    if ($inside -notmatch '^(?i)CASE\b' -or $inside -notmatch '(?i)\bEND\s*$') { return $null }

    $body = Normalize-Inline ($inside -replace '^(?i)CASE\s*', '' -replace '(?i)\s*END\s*$', '')
    # Nested CASE needs a parser, so leave it to the normal formatter.
    if ($body -match '(?i)\bCASE\b') { return $null }

    $tokens = [regex]::Matches($body, '(?i)\bWHEN\b|\bELSE\b')
    if ($tokens.Count -eq 0) { return $null }

    $indent = Get-LeadingWhitespace $first
    $funcPrefix = $nameMatch.Groups[1].Value.ToUpperInvariant() + $nameMatch.Groups[2].Value + '('
    $innerIndent = $indent.Length + $funcPrefix.Length + 2
    $endIndent = $indent.Length + $funcPrefix.Length
    $tail = Normalize-Inline $text.Substring($close + 1)

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($indent + $funcPrefix + 'CASE')

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $next = if ($i -lt $tokens.Count - 1) { $tokens[$i + 1].Index } else { $body.Length }
        $segment = Normalize-Inline $body.Substring($tokens[$i].Index, $next - $tokens[$i].Index)

        if ($segment -match '^(?i)WHEN\s+(.+?)\s+THEN\s+(.+)$') {
            $condition = Normalize-Inline $Matches[1]
            $result = Normalize-Inline $Matches[2]
            $out.Add((' ' * $innerIndent) + 'WHEN ' + $condition)
            $out.Add((' ' * $innerIndent) + 'THEN ' + $result)
        }
        elseif ($segment -match '^(?i)ELSE\s+(.+)$') {
            $out.Add((' ' * $innerIndent) + 'ELSE ' + (Normalize-Inline $Matches[1]))
        }
        else {
            return $null
        }
    }

    $out.Add((' ' * $endIndent) + 'END)' + $(if ($tail) { ' ' + $tail } else { '' }))
    return [pscustomobject]@{ End = $collected.End; Lines = $out.ToArray() }
}

function Try-AlignMultilineFunctionArguments {
    param([string[]]$Lines, [int]$Start)

    $first = $Lines[$Start]
    if ((Get-ParenDelta $first.Trim()) -le 0) { return $null }
    $trimmed = $first.TrimStart()
    $nameMatch = [regex]::Match($trimmed, '^(?i)([A-Z_][A-Z0-9_$#]*)(\s*)\(')
    if (-not $nameMatch.Success) { return $null }
    if ($nameMatch.Groups[1].Value -match '^(?i)(SUM|COUNT|AVG|MIN|MAX|ROW_NUMBER|RANK|DENSE_RANK|NTILE)$') { return $null }

    $collected = Collect-BalancedItem -Lines $Lines -Start $Start
    if ($collected.End -eq $Start) { return $null }
    $text = $collected.Text
    $open = $text.IndexOf('(', $nameMatch.Index)
    $close = Find-MatchingParenInText -Text $text -OpenIndex $open
    if ($close -lt 0) { return $null }

    $args = @(Split-TopLevelByComma $text.Substring($open + 1, $close - $open - 1))
    if ($args.Count -lt 2) { return $null }

    $indent = Get-LeadingWhitespace $first
    $head = $text.Substring(0, $open + 1)
    $tail = Normalize-Inline $text.Substring($close + 1)
    $argIndent = $indent.Length + $head.Length
    $out = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $args.Count; $i++) {
        $prefix = if ($i -eq 0) { $indent + $head } else { ' ' * $argIndent }
        if ($i -lt $args.Count - 1) {
            $out.Add($prefix + $args[$i] + ',')
        }
        else {
            $out.Add($prefix + $args[$i] + ')' + $(if ($tail) { ' ' + $tail } else { '' }))
        }
    }

    return [pscustomobject]@{ End = $collected.End; Lines = $out.ToArray() }
}

function Try-FormatBetweenExpression {
    param([string[]]$Lines, [int]$Start)

    $first = $Lines[$Start]
    $trimmed = $first.TrimStart()
    if ($trimmed -notmatch '(?i)\bBETWEEN\b') { return $null }

    $end = $Start
    $joined = $trimmed
    if ($trimmed -match '(?i)\bAND\s*$' -and $Start + 1 -lt $Lines.Count) {
        $end = $Start + 1
        $joined = Normalize-Inline ($trimmed + ' ' + $Lines[$end].Trim())
    }

    $betweenIndex = Find-TopLevelPhraseIndex -Text $joined -Phrase 'BETWEEN'
    if ($betweenIndex -lt 0) { return $null }
    $andIndex = Find-TopLevelPhraseIndex -Text $joined -Phrase 'AND' -Start ($betweenIndex + 7)
    if ($andIndex -lt 0) { return $null }

    $indent = Get-LeadingWhitespace $first
    $candidate = $indent + $joined
    if ($end -eq $Start -and $candidate.Length -le $script:PreferredExpressionLength) { return $null }

    $left = Normalize-Inline $joined.Substring(0, $andIndex)
    $right = Normalize-Inline $joined.Substring($andIndex + 3)
    $betweenColumn = $first.IndexOf('BETWEEN', [System.StringComparison]::OrdinalIgnoreCase)
    if ($betweenColumn -lt 0) { return $null }

    $out = @(
        $indent + $left,
        (' ' * ($betweenColumn + 4)) + 'AND ' + $right
    )
    return [pscustomobject]@{ End = $end; Lines = $out }
}

function Try-CompactThreeValueInList {
    param([string[]]$Lines, [int]$Start)

    $first = $Lines[$Start]
    $trimmed = $first.TrimStart()
    $inMatch = [regex]::Match($trimmed, '(?i)\b(?:NOT\s+)?IN\s*\(')
    if (-not $inMatch.Success -or (Get-ParenDelta $trimmed) -le 0) { return $null }

    $collected = Collect-BalancedItem -Lines $Lines -Start $Start
    if ($collected.End -eq $Start) { return $null }
    $text = $collected.Text
    $open = $text.IndexOf('(', $inMatch.Index)
    $close = Find-MatchingParenInText -Text $text -OpenIndex $open
    if ($close -lt 0) { return $null }

    $inner = $text.Substring($open + 1, $close - $open - 1)
    if ($inner -match '^(?i)\s*(SELECT|WITH)\b') { return $null }
    $items = @(Split-TopLevelByComma $inner)
    if ($items.Count -ne 3) { return $null }

    $indent = Get-LeadingWhitespace $first
    # A deeply nested predicate is easier to scan vertically. Compact only the
    # shallow three-value form, such as a normal CTE WHERE/AND predicate.
    if ($indent.Length -gt 12) { return $null }

    $head = Normalize-Inline $text.Substring(0, $open)
    $tail = Normalize-Inline $text.Substring($close + 1)
    $candidate = $indent + $head + ' (' + ($items -join ', ') + ')' + $(if ($tail) { ' ' + $tail } else { '' })
    if ($candidate.Length -gt $script:PreferredExpressionLength) { return $null }

    return [pscustomobject]@{ End = $collected.End; Lines = @($candidate) }
}

function Try-FixCaseThenPlacement {
    param([string[]]$Lines, [int]$Start)

    $first = $Lines[$Start]
    $trimmed = $first.TrimStart()
    if ($trimmed -notmatch '^(?i)WHEN\b') { return $null }
    $indent = Get-LeadingWhitespace $first

    $m = [regex]::Match($trimmed, '^(?i)WHEN\s+(.+?)\s+THEN\s*$')
    if ($m.Success -and $Start + 1 -lt $Lines.Count) {
        $condition = Normalize-Inline $m.Groups[1].Value
        $next = $Lines[$Start + 1].Trim()
        if ($next -and $next -notmatch '^(?i)(WHEN|ELSE|END|THEN)\b') {
            return [pscustomobject]@{
                End = $Start + 1
                Lines = @($indent + 'WHEN ' + $condition, $indent + 'THEN ' + $next)
            }
        }
    }

    $m = [regex]::Match($trimmed, '^(?i)WHEN\s+(.+?)\s+THEN\s+(.+)$')
    if ($m.Success) {
        $condition = Normalize-Inline $m.Groups[1].Value
        $result = Normalize-Inline $m.Groups[2].Value
        if (Test-TopLevelLogicalCondition $condition) {
            return [pscustomobject]@{
                End = $Start
                Lines = @($indent + 'WHEN ' + $condition, $indent + 'THEN ' + $result)
            }
        }
    }

    return $null
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$lines = @(($inputSql -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")
$out = New-Object System.Collections.Generic.List[string]
$i = 0

while ($i -lt $lines.Count) {
    $result = Try-FormatWindowItem -Lines $lines -Start $i
    if ($null -eq $result) { $result = Try-FormatAggregateCaseItem -Lines $lines -Start $i }
    if ($null -eq $result) { $result = Try-AlignMultilineFunctionArguments -Lines $lines -Start $i }
    if ($null -eq $result) { $result = Try-FormatBetweenExpression -Lines $lines -Start $i }
    if ($null -eq $result) { $result = Try-CompactThreeValueInList -Lines $lines -Start $i }
    if ($null -eq $result) { $result = Try-FixCaseThenPlacement -Lines $lines -Start $i }

    if ($null -ne $result) {
        foreach ($line in $result.Lines) { $out.Add([string]$line) }
        $i = $result.End + 1
        continue
    }

    $out.Add($lines[$i])
    $i++
}

[Console]::Out.Write(($out -join [Environment]::NewLine).TrimEnd())