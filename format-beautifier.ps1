<#
    Advanced presentation pass used by the Windows SQL Formatter.

    The normal dialect-aware formatter remains the source of truth for syntax and
    safe token handling. This pass only changes presentation according to the
    optional `advanced` section in settings/settings.json. Every option defaults
    to Preserve, so enabling the advanced settings model does not change existing
    output until the user chooses a style.

    The pass is deliberately conservative around stored-program bodies and SPARQL.
    It targets query/DML presentation: lists, parentheses, clause alignment,
    boolean operators, JOIN/ON layout, CASE layout and whitespace.
#>

$ErrorActionPreference = 'Stop'

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$settingsPath = Join-Path $PSScriptRoot 'settings\settings.json'
if (-not (Test-Path $settingsPath)) {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

try { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json }
catch {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

$advanced = $settings.advanced
if ($null -eq $advanced -or -not [bool]$advanced.enabled) {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

# Stored-program bodies and SPARQL graph blocks need grammar-specific formatting;
# do not run a query-layout pass over them.
$normalizedInput = ($inputSql -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
if ($normalizedInput -match '^(?i)(CREATE|ALTER)\s+(?:(?:OR\s+(?:REPLACE|ALTER))\s+)?(?:EDITIONABLE\s+|NONEDITIONABLE\s+)?(PROCEDURE|PROC|FUNCTION|TRIGGER|PACKAGE|TYPE\s+BODY)\b' -or
    $inputSql -match '(?im)^\s*(PREFIX|BASE)\s+' -or
    ($inputSql -match '\{' -and $inputSql -match '(?i)[\?\$][A-Za-z_][A-Za-z0-9_]*')) {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

$script:MaxLineLength = 120
$script:IndentSize = 2
if ($settings.PSObject.Properties.Name -contains 'maxLineLength') {
    $v = 0
    if ([int]::TryParse([string]$settings.maxLineLength, [ref]$v) -and $v -ge 60 -and $v -le 400) {
        $script:MaxLineLength = $v
    }
}
if ($settings.PSObject.Properties.Name -contains 'indentSize') {
    $v = 0
    if ([int]::TryParse([string]$settings.indentSize, [ref]$v) -and $v -in @(2,4)) {
        $script:IndentSize = $v
    }
}

function Get-Option {
    param($Object, [string]$Name, [string]$Default = 'Preserve')
    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $value = [string]$Object.$Name
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $Default
}

$paren = $advanced.parentheses
$lists = $advanced.lists
$clauses = $advanced.clauses
$caseSettings = $advanced.case
$spacing = $advanced.spacing

function Get-LeadingWhitespace {
    param([string]$Text)
    return [regex]::Match($Text, '^\s*').Value
}

function Normalize-Inline {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim())
}

function Get-ParenDelta {
    param([string]$Text)

    $depth = 0
    $single = $false
    $double = $false
    $bracket = $false
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
        if ($ch -eq '-' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '-') { break }
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') { $depth-- }
    }
    return $depth
}

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

function Split-TopLevelComma {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $single = $false
    $double = $false
    $bracket = $false
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

function Get-ContinuationIndent {
    param([string[]]$OriginalLines, [string]$Prefix, [int]$BaseIndent)

    $mode = Get-Option $lists 'continuationIndent'
    if ($mode -eq 'Align') { return $Prefix.Length }
    if ($mode -eq 'Indent') { return $BaseIndent + $script:IndentSize }
    if ($OriginalLines.Count -gt 1) {
        return (Get-LeadingWhitespace $OriginalLines[1]).Length
    }
    return $Prefix.Length
}

function Format-ItemList {
    param(
        [string]$Prefix,
        [string[]]$Items,
        [string]$Style,
        [string[]]$OriginalLines,
        [int]$BaseIndent,
        [string]$Tail = ''
    )

    if ($Style -eq 'Preserve' -or $Items.Count -eq 0) { return $OriginalLines }

    $commaStyle = Get-Option $lists 'commaStyle'
    if ($commaStyle -eq 'Preserve') { $commaStyle = 'Trailing' }
    $continuation = Get-ContinuationIndent -OriginalLines $OriginalLines -Prefix $Prefix -BaseIndent $BaseIndent
    $continuationPrefix = ' ' * $continuation

    $compactBody = $Items -join ', '
    $compact = $Prefix + $compactBody + $Tail
    if ($Style -eq 'Compact') {
        if ($compact.Length -le $script:MaxLineLength) { return @($compact) }
        return $OriginalLines
    }
    if ($Style -eq 'Wrap' -and $compact.Length -le $script:MaxLineLength) {
        return @($compact)
    }

    $out = New-Object System.Collections.Generic.List[string]
    if ($Style -eq 'OnePerLine' -or $commaStyle -eq 'Leading') {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $isLast = $i -eq $Items.Count - 1
            if ($i -eq 0) {
                $line = $Prefix + $Items[$i]
                if (-not $isLast -and $commaStyle -eq 'Trailing') { $line += ',' }
            }
            else {
                if ($commaStyle -eq 'Leading') {
                    $line = $continuationPrefix + ', ' + $Items[$i]
                }
                else {
                    $line = $continuationPrefix + $Items[$i]
                    if (-not $isLast) { $line += ',' }
                }
            }
            if ($isLast) { $line += $Tail }
            $out.Add($line)
        }
        return $out.ToArray()
    }

    # Greedy wrapping for trailing-comma lists. Expressions remain atomic; the
    # canonical formatter is still responsible for breaking a single long item.
    $current = $Prefix
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $isLast = $i -eq $Items.Count - 1
        $piece = $Items[$i] + $(if (-not $isLast) { ',' } else { '' })
        $separator = if ($current.TrimEnd().EndsWith($Prefix.TrimEnd())) { '' } else { ' ' }
        $candidate = $current + $separator + $piece + $(if ($isLast) { $Tail } else { '' })
        if ($candidate.Length -le $script:MaxLineLength -or $current -eq $Prefix) {
            $current = $candidate
        }
        else {
            $out.Add($current)
            $current = $continuationPrefix + $piece + $(if ($isLast) { $Tail } else { '' })
        }
    }
    if ($current) { $out.Add($current) }
    return $out.ToArray()
}

function Invoke-ClauseListPass {
    param([string[]]$Lines, [string]$Kind, [string]$Style)

    if ($Style -eq 'Preserve') { return $Lines }
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0

    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        $pattern = switch ($Kind) {
            'Select' { '^(?<indent>\s*)(?<pre>(?:AS\s*\(\s*)?)(?<kw>SELECT)\s+(?<rest>.+)$' }
            'GroupBy' { '^(?<indent>\s*)(?<pre>)(?<kw>GROUP\s+BY)\s+(?<rest>.+)$' }
            'OrderBy' { '^(?<indent>\s*)(?<pre>)(?<kw>ORDER\s+BY)\s+(?<rest>.+)$' }
            'UpdateSet' { '^(?<indent>\s*)(?<pre>)(?<kw>SET)\s+(?<rest>.+)$' }
            default { '' }
        }
        $m = [regex]::Match($line, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) { $out.Add($line); $i++; continue }

        $stopPattern = switch ($Kind) {
            'Select' { '^(?i)FROM\b' }
            'GroupBy' { '^(?i)(HAVING|ORDER\s+BY|FETCH|LIMIT|OFFSET|UNION|EXCEPT|INTERSECT|WITH\s+(UR|RS|CS|RR|NC))\b' }
            'OrderBy' { '^(?i)(FETCH|LIMIT|OFFSET|FOR\s+(UPDATE|SHARE|JSON|XML)|OPTION|UNION|EXCEPT|INTERSECT|WITH\s+(UR|RS|CS|RR|NC))\b' }
            'UpdateSet' { '^(?i)(FROM|WHERE|OUTPUT|RETURNING|WHEN)\b' }
        }

        $block = New-Object System.Collections.Generic.List[string]
        $block.Add($line)
        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add($m.Groups['rest'].Value.Trim())
        $relativeDepth = Get-ParenDelta $m.Groups['rest'].Value
        $j = $i + 1
        while ($j -lt $Lines.Count) {
            $nextTrim = $Lines[$j].TrimStart()
            if ($relativeDepth -le 0 -and $nextTrim -match $stopPattern) { break }
            if ([string]::IsNullOrWhiteSpace($Lines[$j])) { break }
            $block.Add($Lines[$j])
            $parts.Add($Lines[$j].Trim())
            $relativeDepth += Get-ParenDelta $Lines[$j]
            $j++
        }

        if ($block -join "`n" -match '(?m)--|/\*|\*/') {
            foreach ($b in $block) { $out.Add($b) }
            $i = $j
            continue
        }

        $joined = Normalize-Inline ($parts -join ' ')
        $items = @(Split-TopLevelComma $joined)
        if ($items.Count -lt 2) {
            foreach ($b in $block) { $out.Add($b) }
            $i = $j
            continue
        }

        $prefix = $m.Groups['indent'].Value + $m.Groups['pre'].Value + $m.Groups['kw'].Value + ' '
        $complex = $joined -match '(?i)\b(OVER|CASE|SELECT|WITH)\b'
        if ($complex -and $Style -ne 'Compact') {
            foreach ($b in $block) { $out.Add($b) }
            $i = $j
            continue
        }

        $formatted = Format-ItemList -Prefix $prefix -Items $items -Style $Style -OriginalLines $block.ToArray() -BaseIndent $m.Groups['indent'].Value.Length
        foreach ($f in $formatted) { $out.Add($f) }
        $i = $j
    }
    return $out.ToArray()
}

function Get-ParenListOpenIndex {
    param([string]$Trimmed, [string]$Kind)

    if ($Kind -eq 'InList') {
        $m = [regex]::Match($Trimmed, '(?i)\b(?:NOT\s+)?IN\s*\(')
        if ($m.Success) { return $Trimmed.IndexOf('(', $m.Index) }
        return -1
    }
    if ($Kind -eq 'Values') {
        $m = [regex]::Match($Trimmed, '(?i)\bVALUES\s*\(')
        if ($m.Success) { return $Trimmed.IndexOf('(', $m.Index) }
        return -1
    }
    if ($Kind -eq 'InsertColumns') {
        if ($Trimmed -notmatch '^(?i)INSERT\s+INTO\b') { return -1 }
        $valueIndex = [regex]::Match($Trimmed, '(?i)\b(VALUES|SELECT)\b').Index
        $open = $Trimmed.IndexOf('(')
        if ($open -ge 0 -and ($valueIndex -eq 0 -or $open -lt $valueIndex)) { return $open }
        return -1
    }
    if ($Kind -eq 'FunctionArguments') {
        $reserved = @('IN','VALUES','OVER','PARTITION','ORDER','GROUP','SELECT','FROM','WHERE','CASE','WHEN','THEN','ELSE','EXISTS','AS','ON','AND','OR','JOIN','TABLE','CREATE','UPDATE','INSERT','DELETE')
        $matches = [regex]::Matches($Trimmed, '(?i)\b([A-Z_][A-Z0-9_$#]*)\s*\(')
        foreach ($m in $matches) {
            if ($reserved -contains $m.Groups[1].Value.ToUpperInvariant()) { continue }
            return $Trimmed.IndexOf('(', $m.Index)
        }
    }
    return -1
}

function Invoke-ParenListPass {
    param([string[]]$Lines, [string]$Kind, [string]$Style)

    if ($Style -eq 'Preserve') { return $Lines }
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0

    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        $indent = Get-LeadingWhitespace $line
        $trimmed = $line.TrimStart()
        $open = Get-ParenListOpenIndex -Trimmed $trimmed -Kind $Kind
        if ($open -lt 0) { $out.Add($line); $i++; continue }

        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add($trimmed)
        $balance = Get-ParenDelta $trimmed.Substring($open)
        $j = $i + 1
        while ($balance -gt 0 -and $j -lt $Lines.Count) {
            $parts.Add($Lines[$j].Trim())
            $balance += Get-ParenDelta $Lines[$j]
            $j++
        }
        if ($balance -gt 0) { $out.Add($line); $i++; continue }

        $combined = Normalize-Inline ($parts -join ' ')
        $open = Get-ParenListOpenIndex -Trimmed $combined -Kind $Kind
        if ($open -lt 0) { $out.Add($line); $i++; continue }
        $close = Find-MatchingParen -Text $combined -OpenIndex $open
        if ($close -lt 0) { $out.Add($line); $i++; continue }

        $inner = $combined.Substring($open + 1, $close - $open - 1)
        if ($Kind -eq 'InList' -and $inner -match '^(?i)\s*(SELECT|WITH)\b') {
            for ($k = $i; $k -lt $j; $k++) { $out.Add($Lines[$k]) }
            $i = $j
            continue
        }
        if ($inner -match '(?m)--|/\*|\*/') {
            for ($k = $i; $k -lt $j; $k++) { $out.Add($Lines[$k]) }
            $i = $j
            continue
        }

        $items = @(Split-TopLevelComma $inner)
        if ($items.Count -lt 2) {
            for ($k = $i; $k -lt $j; $k++) { $out.Add($Lines[$k]) }
            $i = $j
            continue
        }
        $head = $indent + $combined.Substring(0, $open + 1)
        $tail = ')' + (Normalize-Inline $combined.Substring($close + 1) | ForEach-Object { if ($_){' ' + $_}else{''} })
        $original = @($Lines[$i..($j - 1)])
        $formatted = Format-ItemList -Prefix $head -Items $items -Style $Style -OriginalLines $original -BaseIndent $indent.Length -Tail $tail
        foreach ($f in $formatted) { $out.Add($f) }
        $i = $j
    }
    return $out.ToArray()
}

function Invoke-BooleanPosition {
    param([string[]]$Lines, [string]$Mode)
    if ($Mode -eq 'Preserve') { return $Lines }

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) { $result.Add($line) }

    if ($Mode -eq 'Trailing') {
        for ($i = 1; $i -lt $result.Count; $i++) {
            $m = [regex]::Match($result[$i], '^(?<indent>\s*)(?<op>AND|OR)\s+(?<rest>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $m.Success) { continue }
            $p = $i - 1
            while ($p -ge 0 -and [string]::IsNullOrWhiteSpace($result[$p])) { $p-- }
            if ($p -lt 0 -or $result[$p] -match '--') { continue }
            $candidate = $result[$p].TrimEnd() + ' ' + $m.Groups['op'].Value
            if ($candidate.Length -gt $script:MaxLineLength) { continue }
            $result[$p] = $candidate
            $result[$i] = $m.Groups['indent'].Value + $m.Groups['rest'].Value
        }
    }
    elseif ($Mode -eq 'Leading') {
        for ($i = 0; $i -lt $result.Count - 1; $i++) {
            $m = [regex]::Match($result[$i], '^(?<body>.*?)(?:\s+)(?<op>AND|OR)\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $m.Success) { continue }
            $next = $i + 1
            while ($next -lt $result.Count -and [string]::IsNullOrWhiteSpace($result[$next])) { $next++ }
            if ($next -ge $result.Count) { continue }
            $indent = Get-LeadingWhitespace $result[$next]
            $result[$i] = $m.Groups['body'].Value.TrimEnd()
            $result[$next] = $indent + $m.Groups['op'].Value + ' ' + $result[$next].TrimStart()
        }
    }
    return $result.ToArray()
}

function Invoke-OnClauseLayout {
    param([string[]]$Lines, [string]$Mode)
    if ($Mode -eq 'Preserve') { return $Lines }
    $out = New-Object System.Collections.Generic.List[string]

    if ($Mode -eq 'SameLine') {
        $i = 0
        while ($i -lt $Lines.Count) {
            if ($i + 1 -lt $Lines.Count -and $Lines[$i] -match '(?i)\bJOIN\b' -and $Lines[$i + 1].TrimStart() -match '^(?i)ON\b') {
                $candidate = $Lines[$i].TrimEnd() + ' ' + $Lines[$i + 1].TrimStart()
                if ($candidate.Length -le $script:MaxLineLength) {
                    $out.Add($candidate); $i += 2; continue
                }
            }
            $out.Add($Lines[$i]); $i++
        }
        return $out.ToArray()
    }

    foreach ($line in $Lines) {
        if ($line -match '(?i)\bJOIN\b.+\s+ON\s+') {
            $m = [regex]::Match($line, '^(?<before>.*?\bJOIN\b.+?)\s+ON\s+(?<after>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $indent = (Get-LeadingWhitespace $line).Length + $script:IndentSize
                $out.Add($m.Groups['before'].Value.TrimEnd())
                $out.Add((' ' * $indent) + 'ON ' + $m.Groups['after'].Value)
                continue
            }
        }
        $out.Add($line)
    }
    return $out.ToArray()
}

function Invoke-JoinLayout {
    param([string[]]$Lines, [string]$Mode)
    if ($Mode -ne 'CompactWhenPossible') { return $Lines }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ($line.TrimStart() -match '^(?i)(INNER|LEFT|RIGHT|FULL|CROSS)?\s*(OUTER\s+)?JOIN\b' -and $out.Count -gt 0) {
            $prev = $out[$out.Count - 1]
            if ($prev.TrimStart() -match '^(?i)(FROM|INNER|LEFT|RIGHT|FULL|CROSS|JOIN)\b') {
                $candidate = $prev.TrimEnd() + ' ' + $line.TrimStart()
                if ($candidate.Length -le $script:MaxLineLength) {
                    $out[$out.Count - 1] = $candidate
                    continue
                }
            }
        }
        $out.Add($line)
    }
    return $out.ToArray()
}

function Invoke-ClauseAlignment {
    param([string[]]$Lines, [string]$Mode)
    if ($Mode -in @('Preserve','IBM')) { return $Lines }

    $offsets = @{
        'SELECT' = 0; 'FROM' = 2; 'WHERE' = 1; 'GROUP BY' = 1; 'HAVING' = 1;
        'ORDER BY' = 1; 'FETCH' = 1; 'LIMIT' = 1; 'OFFSET' = 0;
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^(?<indent>\s*)(?<kw>SELECT|FROM|WHERE|GROUP\s+BY|HAVING|ORDER\s+BY|FETCH|LIMIT|OFFSET)\b(?<rest>.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) { $out.Add($line); continue }
        $kw = ($m.Groups['kw'].Value -replace '\s+', ' ').ToUpperInvariant()
        $offset = if ($offsets.ContainsKey($kw)) { [int]$offsets[$kw] } else { 0 }
        $base = [Math]::Max(0, $m.Groups['indent'].Value.Length - $offset)
        $newIndent = if ($Mode -eq 'Indented') { $base + $script:IndentSize } else { $base }
        $out.Add((' ' * $newIndent) + $m.Groups['kw'].Value + $m.Groups['rest'].Value)
    }
    return $out.ToArray()
}

function Invoke-CteLayout {
    param([string[]]$Lines, [string]$Mode, [bool]$BlankLine)
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Lines.Count) {
        if ($Mode -eq 'CompactHeader' -and $i + 1 -lt $Lines.Count -and
            $Lines[$i].Trim() -match '^[A-Za-z_][A-Za-z0-9_$#]*$' -and
            $Lines[$i + 1].TrimStart() -match '^(?i)AS\s*\(') {
            $candidate = $Lines[$i].TrimEnd() + ' ' + $Lines[$i + 1].TrimStart()
            if ($candidate.Length -le $script:MaxLineLength) {
                $out.Add((Get-LeadingWhitespace $Lines[$i]) + $candidate.TrimStart())
                $i += 2
                continue
            }
        }
        if ($Mode -eq 'ExpandedHeader') {
            $m = [regex]::Match($Lines[$i], '^(?<indent>\s*)(?<name>[A-Za-z_][A-Za-z0-9_$#]*)\s+AS\s*(?<rest>\(.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $out.Add($m.Groups['indent'].Value + $m.Groups['name'].Value)
                $out.Add($m.Groups['indent'].Value + 'AS ' + $m.Groups['rest'].Value)
                $i++
                continue
            }
        }
        $out.Add($Lines[$i])
        $i++
    }

    if (-not $BlankLine) { return $out.ToArray() }
    $final = New-Object System.Collections.Generic.List[string]
    for ($j = 0; $j -lt $out.Count; $j++) {
        $final.Add($out[$j])
        if ($out[$j].TrimEnd().EndsWith('),') -and $j + 2 -lt $out.Count -and
            $out[$j + 1].Trim() -match '^[A-Za-z_][A-Za-z0-9_$#]*$' -and
            $out[$j + 2].TrimStart() -match '^(?i)AS\s*\(') {
            $final.Add('')
        }
    }
    return $final.ToArray()
}

function Invoke-CaseLayout {
    param([string[]]$Lines, [string]$Style, [string]$ThenMode, [string]$ElseMode)
    $work = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) { $work.Add($line) }

    if ($Style -eq 'Multiline') {
        $expanded = New-Object System.Collections.Generic.List[string]
        foreach ($line in $work) {
            $m = [regex]::Match($line, '^(?<indent>\s*)(?<prefix>.*?)(?<case>CASE\s+WHEN\s+.+?\s+THEN\s+.+?\s+ELSE\s+.+?\s+END)(?<tail>.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success -and $m.Groups['case'].Value -notmatch '(?i)\bCASE\b.*\bCASE\b') {
                $c = $m.Groups['case'].Value
                $cm = [regex]::Match($c, '^(?i)CASE\s+WHEN\s+(.+?)\s+THEN\s+(.+?)\s+ELSE\s+(.+?)\s+END$')
                if ($cm.Success) {
                    $base = $m.Groups['indent'].Value + $m.Groups['prefix'].Value
                    $caseIndent = ' ' * $base.Length
                    $inner = $caseIndent + (' ' * $script:IndentSize)
                    $expanded.Add($base + 'CASE')
                    $expanded.Add($inner + 'WHEN ' + $cm.Groups[1].Value + ' THEN ' + $cm.Groups[2].Value)
                    $expanded.Add($inner + 'ELSE ' + $cm.Groups[3].Value)
                    $expanded.Add($caseIndent + 'END' + $m.Groups['tail'].Value)
                    continue
                }
            }
            $expanded.Add($line)
        }
        $work = $expanded
    }
    elseif ($Style -eq 'CompactShort') {
        $compact = New-Object System.Collections.Generic.List[string]
        $i = 0
        while ($i -lt $work.Count) {
            if ($work[$i].Trim() -eq 'CASE') {
                $end = $i + 1
                while ($end -lt $work.Count -and $end -le $i + 6 -and $work[$end].TrimStart() -notmatch '^(?i)END\b') { $end++ }
                if ($end -lt $work.Count -and $work[$end].TrimStart() -match '^(?i)END\b') {
                    $segment = @($work[$i..$end])
                    $whenCount = @($segment | Where-Object { $_.TrimStart() -match '^(?i)WHEN\b' }).Count
                    if ($whenCount -eq 1) {
                        $candidate = Normalize-Inline ($segment -join ' ')
                        $candidate = (Get-LeadingWhitespace $work[$i]) + $candidate
                        if ($candidate.Length -le $script:MaxLineLength) {
                            $compact.Add($candidate); $i = $end + 1; continue
                        }
                    }
                }
            }
            $compact.Add($work[$i]); $i++
        }
        $work = $compact
    }

    if ($ThenMode -eq 'NewLine') {
        $tmp = New-Object System.Collections.Generic.List[string]
        foreach ($line in $work) {
            $m = [regex]::Match($line, '^(?<indent>\s*)WHEN\s+(?<cond>.+?)\s+THEN\s+(?<result>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $tmp.Add($m.Groups['indent'].Value + 'WHEN ' + $m.Groups['cond'].Value)
                $tmp.Add($m.Groups['indent'].Value + 'THEN ' + $m.Groups['result'].Value)
            }
            else { $tmp.Add($line) }
        }
        $work = $tmp
    }
    elseif ($ThenMode -eq 'SameLine') {
        $tmp = New-Object System.Collections.Generic.List[string]
        $i = 0
        while ($i -lt $work.Count) {
            if ($i + 1 -lt $work.Count -and $work[$i].TrimStart() -match '^(?i)WHEN\b' -and $work[$i + 1].TrimStart() -match '^(?i)THEN\b') {
                $candidate = $work[$i].TrimEnd() + ' ' + $work[$i + 1].TrimStart()
                if ($candidate.Length -le $script:MaxLineLength) { $tmp.Add($candidate); $i += 2; continue }
            }
            $tmp.Add($work[$i]); $i++
        }
        $work = $tmp
    }

    if ($ElseMode -eq 'NewLine') {
        $tmp = New-Object System.Collections.Generic.List[string]
        foreach ($line in $work) {
            $m = [regex]::Match($line, '^(?<indent>\s*)ELSE\s+(?<result>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $tmp.Add($m.Groups['indent'].Value + 'ELSE')
                $tmp.Add($m.Groups['indent'].Value + (' ' * $script:IndentSize) + $m.Groups['result'].Value)
            }
            else { $tmp.Add($line) }
        }
        $work = $tmp
    }
    elseif ($ElseMode -eq 'SameLine') {
        $tmp = New-Object System.Collections.Generic.List[string]
        $i = 0
        while ($i -lt $work.Count) {
            if ($i + 1 -lt $work.Count -and $work[$i].Trim() -match '^(?i)ELSE$' -and
                $work[$i + 1].TrimStart() -notmatch '^(?i)(WHEN|END|THEN|ELSE)\b') {
                $candidate = $work[$i].TrimEnd() + ' ' + $work[$i + 1].TrimStart()
                if ($candidate.Length -le $script:MaxLineLength) { $tmp.Add($candidate); $i += 2; continue }
            }
            $tmp.Add($work[$i]); $i++
        }
        $work = $tmp
    }
    return $work.ToArray()
}

function Find-SubquerySpans {
    param([string]$Text)

    $spans = New-Object System.Collections.Generic.List[object]
    $single = $false; $double = $false; $bracket = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($single) {
            if ($ch -eq "'") { if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++ } else { $single = $false } }
            continue
        }
        if ($double) {
            if ($ch -eq '"') { if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i++ } else { $double = $false } }
            continue
        }
        if ($bracket) {
            if ($ch -eq ']') { if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq ']') { $i++ } else { $bracket = $false } }
            continue
        }
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '[') { $bracket = $true; continue }
        if ($ch -ne '(') { continue }

        $k = $i + 1
        while ($k -lt $Text.Length -and [char]::IsWhiteSpace($Text[$k])) { $k++ }
        if ($k -ge $Text.Length) { continue }
        $tail = $Text.Substring($k)
        if ($tail -notmatch '^(?i)(SELECT|WITH)\b') { continue }
        $close = Find-MatchingParen -Text $Text -OpenIndex $i
        if ($close -lt 0) { continue }
        $spans.Add([pscustomobject]@{ Open=$i; Keyword=$k; Close=$close })
    }
    return $spans.ToArray()
}

function Get-LineIndentAtIndex {
    param([string]$Text, [int]$Index)
    $lineStart = $Text.LastIndexOf("`n", [Math]::Max(0,$Index - 1))
    if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
    $count = 0
    while ($lineStart + $count -lt $Text.Length -and $Text[$lineStart + $count] -eq ' ') { $count++ }
    return $count
}

function Invoke-SubqueryParentheses {
    param([string]$Text, [string]$OpenMode, [string]$CloseMode)
    if ($OpenMode -eq 'Preserve' -and $CloseMode -eq 'Preserve') { return $Text }

    $replacements = New-Object System.Collections.Generic.List[object]
    foreach ($span in (Find-SubquerySpans $Text)) {
        $indent = Get-LineIndentAtIndex -Text $Text -Index $span.Open
        if ($OpenMode -ne 'Preserve') {
            $len = $span.Keyword - ($span.Open + 1)
            $between = if ($len -gt 0) { $Text.Substring($span.Open + 1, $len) } else { '' }
            if ($between -match '^\s*$') {
                $replacement = if ($OpenMode -eq 'NewLine') { [Environment]::NewLine + (' ' * ($indent + $script:IndentSize)) } else { '' }
                $replacements.Add([pscustomobject]@{ Start=$span.Open+1; Length=$len; Text=$replacement })
            }
        }
        if ($CloseMode -ne 'Preserve') {
            $start = $span.Close
            while ($start -gt $span.Open + 1 -and [char]::IsWhiteSpace($Text[$start - 1])) { $start-- }
            $len = $span.Close - $start
            $replacement = if ($CloseMode -eq 'NewLine') { [Environment]::NewLine + (' ' * $indent) } else { '' }
            $replacements.Add([pscustomobject]@{ Start=$start; Length=$len; Text=$replacement })
        }
    }

    foreach ($r in @($replacements | Sort-Object Start -Descending)) {
        $Text = $Text.Substring(0,$r.Start) + $r.Text + $Text.Substring($r.Start + $r.Length)
    }
    return $Text
}

function Invoke-CteParenthesisStyle {
    param([string[]]$Lines, [string]$Mode)
    if ($Mode -eq 'Preserve') { return $Lines }
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Lines.Count) {
        if ($Mode -eq 'NewLine') {
            $m = [regex]::Match($Lines[$i], '^(?<indent>\s*)AS\s*\(\s*(?<rest>SELECT\b.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $out.Add($m.Groups['indent'].Value + 'AS')
                $out.Add($m.Groups['indent'].Value + '(')
                $out.Add($m.Groups['indent'].Value + (' ' * $script:IndentSize) + $m.Groups['rest'].Value)
                $i++
                continue
            }
        }
        else {
            if ($i + 2 -lt $Lines.Count -and $Lines[$i].Trim() -match '^(?i)AS$' -and $Lines[$i + 1].Trim() -eq '(' -and $Lines[$i + 2].TrimStart() -match '^(?i)SELECT\b') {
                $candidate = $Lines[$i].TrimEnd() + ' (' + $Lines[$i + 2].TrimStart()
                if ($candidate.Length -le $script:MaxLineLength) {
                    $out.Add((Get-LeadingWhitespace $Lines[$i]) + $candidate.TrimStart())
                    $i += 3
                    continue
                }
            }
        }
        $out.Add($Lines[$i]); $i++
    }
    return $out.ToArray()
}

function Protect-LineLiterals {
    param([string]$Line, [hashtable]$Map, [ref]$Counter)
    $pattern = "'(?:''|[^'])*'|\"(?:\"\"|[^\"])*\"|\[(?:\]\]|[^\]])*\]|--.*$"
    return [regex]::Replace($Line, $pattern, {
        param($m)
        $Counter.Value++
        $token = "__BFMT_$($Counter.Value)__"
        $Map[$token] = $m.Value
        return $token
    })
}

function Invoke-Spacing {
    param([string[]]$Lines)

    $functionParen = Get-Option $paren 'functionSpaceBeforeParen'
    $inside = Get-Option $paren 'insideParentheses'
    $operator = Get-Option $spacing 'comparisonOperators'
    $afterComma = Get-Option $spacing 'afterComma'
    if ($functionParen -eq 'Preserve' -and $inside -eq 'Preserve' -and $operator -eq 'Preserve' -and $afterComma -eq 'Preserve') { return $Lines }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $map = @{}; $counter = 0
        $masked = Protect-LineLiterals -Line $line -Map $map -Counter ([ref]$counter)
        if ($functionParen -eq 'NoSpace') {
            $masked = [regex]::Replace($masked, '(?i)\b([A-Z_][A-Z0-9_$#]*)[ \t]*\(', '$1(')
        }
        elseif ($functionParen -eq 'Space') {
            $masked = [regex]::Replace($masked, '(?i)\b([A-Z_][A-Z0-9_$#]*)[ \t]*\(', '$1 (')
        }
        if ($inside -eq 'NoSpace') {
            $masked = $masked -replace '\([ \t]+', '(' -replace '[ \t]+\)', ')'
        }
        elseif ($inside -eq 'Space') {
            $masked = [regex]::Replace($masked, '\((?![\s\)])', '( ')
            $masked = [regex]::Replace($masked, '(?<![\s\(])\)', ' )')
        }
        if ($operator -eq 'Spaced') {
            $masked = [regex]::Replace($masked, '(?<![:<>=!~#@\-])\s*(<>|!=|<=|>=|=|<|>)\s*(?![<>=])', ' $1 ')
            $masked = $masked -replace '[ \t]{2,}', ' '
            $leading = Get-LeadingWhitespace $line
            $masked = $leading + $masked.TrimStart()
        }
        elseif ($operator -eq 'Tight') {
            $masked = [regex]::Replace($masked, '(?<![:<>=!~#@\-])[ \t]*(<>|!=|<=|>=|=|<|>)[ \t]*(?![<>=])', '$1')
        }
        if ($afterComma -eq 'Space') { $masked = [regex]::Replace($masked, ',[ \t]*', ', ') }
        elseif ($afterComma -eq 'NoSpace') { $masked = [regex]::Replace($masked, ',[ \t]*', ',') }

        foreach ($key in ($map.Keys | Sort-Object Length -Descending)) { $masked = $masked.Replace($key, $map[$key]) }
        if ($masked.Length -gt $script:MaxLineLength -and $line.Length -le $script:MaxLineLength) { $out.Add($line) }
        else { $out.Add($masked) }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------
# Execute style passes. Each pass is token-order preserving.
# ---------------------------------------------------------------------------

$lines = @(($inputSql -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")

$lines = Invoke-ClauseListPass -Lines $lines -Kind 'Select' -Style (Get-Option $lists 'select')
$lines = Invoke-ClauseListPass -Lines $lines -Kind 'GroupBy' -Style (Get-Option $lists 'groupBy')
$lines = Invoke-ClauseListPass -Lines $lines -Kind 'OrderBy' -Style (Get-Option $lists 'orderBy')
$lines = Invoke-ClauseListPass -Lines $lines -Kind 'UpdateSet' -Style (Get-Option $lists 'updateSet')
$lines = Invoke-ParenListPass -Lines $lines -Kind 'InsertColumns' -Style (Get-Option $lists 'insertColumns')
$lines = Invoke-ParenListPass -Lines $lines -Kind 'Values' -Style (Get-Option $lists 'values')
$lines = Invoke-ParenListPass -Lines $lines -Kind 'InList' -Style (Get-Option $lists 'inList')
$lines = Invoke-ParenListPass -Lines $lines -Kind 'FunctionArguments' -Style (Get-Option $lists 'functionArguments')

$lines = Invoke-CteParenthesisStyle -Lines $lines -Mode (Get-Option $paren 'cteAsParenthesis')
$lines = Invoke-CteLayout -Lines $lines -Mode (Get-Option $clauses 'cteLayout') -BlankLine ([bool]$clauses.blankLineBetweenCtes)
$lines = Invoke-OnClauseLayout -Lines $lines -Mode (Get-Option $clauses 'onClause')
$lines = Invoke-JoinLayout -Lines $lines -Mode (Get-Option $clauses 'joinLayout')
$lines = Invoke-BooleanPosition -Lines $lines -Mode (Get-Option $clauses 'booleanOperatorPosition')
$lines = Invoke-ClauseAlignment -Lines $lines -Mode (Get-Option $clauses 'alignment')
$lines = Invoke-CaseLayout -Lines $lines -Style (Get-Option $caseSettings 'style') -ThenMode (Get-Option $caseSettings 'thenResult') -ElseMode (Get-Option $caseSettings 'elseResult')

$text = $lines -join [Environment]::NewLine
$text = Invoke-SubqueryParentheses -Text $text -OpenMode (Get-Option $paren 'subqueryOpening') -CloseMode (Get-Option $paren 'subqueryClosing')
$lines = @(($text -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")
$lines = Invoke-Spacing -Lines $lines

[Console]::Out.Write(($lines -join [Environment]::NewLine).TrimEnd())
