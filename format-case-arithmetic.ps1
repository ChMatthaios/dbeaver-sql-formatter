<#
    Normalize parenthesized arithmetic chains made from searched CASE expressions.

    Example:
      (CASE ... END + CASE ... END + CASE ... END) AS X

    Each CASE is a sibling expression, not a nested CASE. This pass prevents a later
    CASE from inheriting the visual column of the previous END + CASE text and keeps
    every sibling aligned under the same parent expression.
#>

$ErrorActionPreference = 'Stop'

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$settingsPath = Join-Path $PSScriptRoot 'settings\settings.json'
$indentSize = 2
$thenMode = 'Preserve'
$elseMode = 'Preserve'
$insideParen = 'Preserve'

try {
    if (Test-Path $settingsPath) {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        $parsed = 0
        if ($settings.PSObject.Properties.Name -contains 'indentSize' -and
            [int]::TryParse([string]$settings.indentSize, [ref]$parsed) -and
            $parsed -in @(2, 4)) {
            $indentSize = $parsed
        }
        if ($null -ne $settings.advanced) {
            if ($null -ne $settings.advanced.case) {
                $thenMode = [string]$settings.advanced.case.thenResult
                $elseMode = [string]$settings.advanced.case.elseResult
            }
            if ($null -ne $settings.advanced.parentheses) {
                $insideParen = [string]$settings.advanced.parentheses.insideParentheses
            }
        }
    }
}
catch { }

function Find-MatchingSqlParen {
    param([string]$Text, [int]$OpenIndex)

    $depth = 0
    $single = $false
    $double = $false
    $bracket = $false
    $lineComment = $false
    $blockComment = $false

    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($lineComment) { if ($ch -eq "`n") { $lineComment = $false }; continue }
        if ($blockComment) { if ($ch -eq '*' -and $next -eq '/') { $blockComment = $false; $i++ }; continue }
        if ($single) { if ($ch -eq "'") { if ($next -eq "'") { $i++ } else { $single = $false } }; continue }
        if ($double) { if ($ch -eq '"') { if ($next -eq '"') { $i++ } else { $double = $false } }; continue }
        if ($bracket) { if ($ch -eq ']') { if ($next -eq ']') { $i++ } else { $bracket = $false } }; continue }

        if ($ch -eq '-' -and $next -eq '-') { $lineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $blockComment = $true; $i++; continue }
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '[') { $bracket = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') { $depth--; if ($depth -eq 0) { return $i } }
    }
    return -1
}

function Normalize-WhitespaceSafe {
    param([string]$Text)

    $sb = New-Object System.Text.StringBuilder
    $single = $false
    $double = $false
    $bracket = $false
    $pendingSpace = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($single) {
            [void]$sb.Append($ch)
            if ($ch -eq "'") {
                if ($next -eq "'") { [void]$sb.Append($next); $i++ }
                else { $single = $false }
            }
            continue
        }
        if ($double) {
            [void]$sb.Append($ch)
            if ($ch -eq '"') {
                if ($next -eq '"') { [void]$sb.Append($next); $i++ }
                else { $double = $false }
            }
            continue
        }
        if ($bracket) {
            [void]$sb.Append($ch)
            if ($ch -eq ']') {
                if ($next -eq ']') { [void]$sb.Append($next); $i++ }
                else { $bracket = $false }
            }
            continue
        }

        if ($ch -eq "'") { if ($pendingSpace -and $sb.Length -gt 0) { [void]$sb.Append(' ') }; $pendingSpace = $false; [void]$sb.Append($ch); $single = $true; continue }
        if ($ch -eq '"') { if ($pendingSpace -and $sb.Length -gt 0) { [void]$sb.Append(' ') }; $pendingSpace = $false; [void]$sb.Append($ch); $double = $true; continue }
        if ($ch -eq '[') { if ($pendingSpace -and $sb.Length -gt 0) { [void]$sb.Append(' ') }; $pendingSpace = $false; [void]$sb.Append($ch); $bracket = $true; continue }

        if ([char]::IsWhiteSpace($ch)) { $pendingSpace = $true; continue }
        if ($pendingSpace -and $sb.Length -gt 0) { [void]$sb.Append(' ') }
        $pendingSpace = $false
        [void]$sb.Append($ch)
    }

    return $sb.ToString().Trim()
}

function Split-TopLevelCaseChain {
    param([string]$Inner)

    $parts = New-Object System.Collections.Generic.List[string]
    $start = 0
    $parenDepth = 0
    $caseDepth = 0
    $single = $false
    $double = $false
    $bracket = $false
    $i = 0

    while ($i -lt $Inner.Length) {
        $ch = $Inner[$i]
        $next = if ($i + 1 -lt $Inner.Length) { $Inner[$i + 1] } else { [char]0 }

        if ($single) { if ($ch -eq "'") { if ($next -eq "'") { $i += 2; continue } else { $single = $false } }; $i++; continue }
        if ($double) { if ($ch -eq '"') { if ($next -eq '"') { $i += 2; continue } else { $double = $false } }; $i++; continue }
        if ($bracket) { if ($ch -eq ']') { if ($next -eq ']') { $i += 2; continue } else { $bracket = $false } }; $i++; continue }

        if ($ch -eq "'") { $single = $true; $i++; continue }
        if ($ch -eq '"') { $double = $true; $i++; continue }
        if ($ch -eq '[') { $bracket = $true; $i++; continue }
        if ($ch -eq '(') { $parenDepth++; $i++; continue }
        if ($ch -eq ')') { if ($parenDepth -gt 0) { $parenDepth-- }; $i++; continue }

        if ([char]::IsLetter($ch)) {
            $wordStart = $i
            while ($i -lt $Inner.Length -and ([char]::IsLetterOrDigit($Inner[$i]) -or $Inner[$i] -eq '_')) { $i++ }
            $word = $Inner.Substring($wordStart, $i - $wordStart).ToUpperInvariant()
            if ($word -eq 'CASE') { $caseDepth++; continue }
            if ($word -eq 'END' -and $caseDepth -gt 0) { $caseDepth--; continue }
            continue
        }

        if ($parenDepth -eq 0 -and $caseDepth -eq 0 -and $ch -eq '+') {
            $piece = $Inner.Substring($start, $i - $start).Trim()
            if ($piece) { $parts.Add($piece) }
            $start = $i + 1
            $i++
            continue
        }

        $i++
    }

    $tail = $Inner.Substring($start).Trim()
    if ($tail) { $parts.Add($tail) }
    return $parts.ToArray()
}

function Format-SimpleCasePart {
    param([string]$Part, [int]$OpenColumn, [bool]$WithOperator)

    $flat = Normalize-WhitespaceSafe $Part
    if ($flat -notmatch '^(?is)CASE\s+(?<body>.*)\s+END$') { return $null }
    $body = $Matches['body']
    if ([regex]::Matches($body, '(?i)\bCASE\b').Count -gt 0) { return $null }

    $tokens = [regex]::Matches($body, '(?i)\bWHEN\b|\bELSE\b')
    if ($tokens.Count -eq 0) { return $null }

    $caseColumn = if ($WithOperator) { $OpenColumn + 2 } else { $OpenColumn + 2 }
    $branchColumn = $caseColumn + $indentSize
    $resultColumn = $branchColumn + $indentSize
    $lines = New-Object System.Collections.Generic.List[string]

    if ($WithOperator) { $lines.Add((' ' * $OpenColumn) + '+ CASE') }
    else {
        $spaceInside = if ($insideParen -eq 'Space') { ' ' } else { '' }
        $lines.Add('(' + $spaceInside + 'CASE')
    }

    for ($t = 0; $t -lt $tokens.Count; $t++) {
        $token = $tokens[$t]
        $nextIndex = if ($t + 1 -lt $tokens.Count) { $tokens[$t + 1].Index } else { $body.Length }
        $segment = Normalize-WhitespaceSafe $body.Substring($token.Index, $nextIndex - $token.Index)

        if ($segment -match '^(?is)WHEN\s+(?<condition>.*?)\s+THEN\s+(?<result>.*)$') {
            $condition = $Matches['condition'].Trim()
            $result = $Matches['result'].Trim()
            if ($thenMode -eq 'NewLine') {
                $lines.Add((' ' * $branchColumn) + 'WHEN ' + $condition)
                $lines.Add((' ' * $branchColumn) + 'THEN ' + $result)
            }
            else {
                $lines.Add((' ' * $branchColumn) + 'WHEN ' + $condition + ' THEN ' + $result)
            }
            continue
        }

        if ($segment -match '^(?is)ELSE\s+(?<result>.*)$') {
            $result = $Matches['result'].Trim()
            if ($elseMode -eq 'NewLine') {
                $lines.Add((' ' * $branchColumn) + 'ELSE')
                $lines.Add((' ' * $resultColumn) + $result)
            }
            else {
                $lines.Add((' ' * $branchColumn) + 'ELSE ' + $result)
            }
        }
    }

    $lines.Add((' ' * $caseColumn) + 'END')
    return $lines.ToArray()
}

function Format-CaseChainSpan {
    param([string]$Text, [int]$OpenIndex, [int]$CloseIndex)

    $inner = $Text.Substring($OpenIndex + 1, $CloseIndex - $OpenIndex - 1)
    $parts = @(Split-TopLevelCaseChain $inner)
    if ($parts.Count -lt 2) { return $null }
    foreach ($part in $parts) {
        if ((Normalize-WhitespaceSafe $part) -notmatch '^(?i)CASE\b') { return $null }
    }

    $lineStart = $Text.LastIndexOf("`n", [Math]::Max(0, $OpenIndex - 1))
    if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
    $openColumn = $OpenIndex - $lineStart

    $all = New-Object System.Collections.Generic.List[string]
    for ($p = 0; $p -lt $parts.Count; $p++) {
        $formatted = @(Format-SimpleCasePart -Part $parts[$p] -OpenColumn $openColumn -WithOperator ($p -gt 0))
        if ($formatted.Count -eq 0) { return $null }
        foreach ($line in $formatted) { $all.Add($line) }
    }

    $all[$all.Count - 1] = $all[$all.Count - 1] + ')'
    return ($all -join [Environment]::NewLine)
}

$text = $inputSql -replace "`r`n", "`n" -replace "`r", "`n"
$replacements = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $text.Length; $i++) {
    if ($text[$i] -ne '(') { continue }
    $j = $i + 1
    while ($j -lt $text.Length -and [char]::IsWhiteSpace($text[$j])) { $j++ }
    if ($j + 4 -gt $text.Length -or $text.Substring($j, 4) -notmatch '^(?i)CASE$') { continue }

    $close = Find-MatchingSqlParen -Text $text -OpenIndex $i
    if ($close -lt 0) { continue }
    $replacement = Format-CaseChainSpan -Text $text -OpenIndex $i -CloseIndex $close
    if ($null -ne $replacement) {
        $replacements.Add([pscustomobject]@{ Start = $i; Length = $close - $i + 1; Text = $replacement })
        $i = $close
    }
}

for ($r = $replacements.Count - 1; $r -ge 0; $r--) {
    $rep = $replacements[$r]
    $text = $text.Substring(0, $rep.Start) + $rep.Text + $text.Substring($rep.Start + $rep.Length)
}

[Console]::Out.Write($text.TrimEnd("`r", "`n"))
