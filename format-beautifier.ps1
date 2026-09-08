<#
    Advanced SQL Beautifier

    This is a presentation-only pass for the Windows application. The normal
    dialect-aware formatter runs first and remains responsible for syntax safety.
    All advanced settings default to Preserve, so existing output is unchanged
    until a user explicitly chooses a style.
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

if (-not ($settings.PSObject.Properties.Name -contains 'advanced')) {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

$advanced = $settings.advanced
if ($null -eq $advanced -or -not [bool]$advanced.enabled) {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

# Stored-program bodies and SPARQL need grammar-specific presentation logic.
# Keep the advanced query beautifier away from those bodies for safety.
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
    $parsed = 0
    if ([int]::TryParse([string]$settings.maxLineLength, [ref]$parsed) -and $parsed -ge 60 -and $parsed -le 400) {
        $script:MaxLineLength = $parsed
    }
}
if ($settings.PSObject.Properties.Name -contains 'indentSize') {
    $parsed = 0
    if ([int]::TryParse([string]$settings.indentSize, [ref]$parsed) -and $parsed -in @(2, 4)) {
        $script:IndentSize = $parsed
    }
}

$paren = $advanced.parentheses
$lists = $advanced.lists
$clauses = $advanced.clauses
$caseSettings = $advanced.case
$spacing = $advanced.spacing

function Get-Option {
    param($Object, [string]$Name, [string]$Default = 'Preserve')

    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $value = [string]$Object.$Name
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $Default
}

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

function Get-ContinuationColumn {
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

    $continuation = Get-ContinuationColumn -OriginalLines $OriginalLines -Prefix $Prefix -BaseIndent $BaseIndent
    $continuationPrefix = ' ' * $continuation
    $compact = $Prefix + ($Items -join ', ') + $Tail

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
            $isLast = ($i -eq $Items.Count - 1)
            if ($i -eq 0) {
                $line = $Prefix + $Items[$i]
                if (-not $isLast -and $commaStyle -eq 'Trailing') { $line += ',' }
            }
            elseif ($commaStyle -eq 'Leading') {
                $line = $continuationPrefix + ', ' + $Items[$i]
            }
            else {
                $line = $continuationPrefix + $Items[$i]
                if (-not $isLast) { $line += ',' }
            }

            if ($isLast) { $line += $Tail }
            $out.Add($line)
        }
        return $out.ToArray()
    }

    # Wrap: greedily pack complete list items without splitting expressions.
    $current = $Prefix
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $isLast = ($i -eq $Items.Count - 1)
        $piece = $Items[$i]
        if (-not $isLast) { $piece += ',' }

        $separator = ''
        if ($current -ne $Prefix) { $separator = ' ' }

        $candidate = $current + $separator + $piece
        if ($isLast) { $candidate += $Tail }

        if ($candidate.Length -le $script:MaxLineLength -or $current -eq $Prefix) {
            $current = $candidate
        }
        else {
            $out.Add($current)
            $current = $continuationPrefix + $piece
            if ($isLast) { $current += $Tail }
        }
    }
    if ($current) { $out.Add($current) }
    return $out.ToArray()
}

function Get-ClauseDefinition {
    param([string]$Kind)

    switch ($Kind) {
        'Select' {
            return [pscustomobject]@{
                Pattern = '^(?<indent>\s*)(?<pre>(?:AS\s*\(\s*)?)(?<kw>SELECT)\s+(?<rest>.+)$'
                Stop = '^(?i)FROM\b'
            }
        }
        'GroupBy' {
            return [pscustomobject]@{
                Pattern = '^(?<indent>\s*)(?<pre>)(?<kw>GROUP\s+BY)\s+(?<rest>.+)$'
                Stop = '^(?i)(HAVING|ORDER\s+BY|FETCH|LIMIT|OFFSET|UNION|EXCEPT|INTERSECT|WITH\s+(UR|RS|CS|RR|NC))\b'
            }
        }
        'OrderBy' {
            return [pscustomobject]@{
                Pattern = '^(?<indent>\s*)(?<pre>)(?<kw>ORDER\s+BY)\s+(?<rest>.+)$'
                Stop = '^(?i)(FETCH|LIMIT|OFFSET|FOR\s+(UPDATE|SHARE|JSON|XML)|OPTION|UNION|EXCEPT|INTERSECT|WITH\s+(UR|RS|CS|RR|NC))\b'
            }
        }
        'UpdateSet' {
            return [pscustomobject]@{
                Pattern = '^(?<indent>\s*)(?<pre>)(?<kw>SET)\s+(?<rest>.+)$'
                Stop = '^(?i)(FROM|WHERE|OUTPUT|RETURNING|WHEN)\b'
            }
        }
    }
    return $null
}

function Invoke-ClauseListPass {
    param([string[]]$Lines, [string]$Kind, [string]$Style)

    if ($Style -eq 'Preserve') { return $Lines }
    $definition = Get-ClauseDefinition $Kind
    if ($null -eq $definition) { return $Lines }

    $out = New-Object System.Collections.Generic.List[string]
    $i = 0

    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        $m = [regex]::Match($line, $definition.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) {
            $out.Add($line)
            $i++
            continue
        }

        $block = New-Object System.Collections.Generic.List[string]
        $parts = New-Object System.Collections.Generic.List[string]
        $block.Add($line)
        $parts.Add($m.Groups['rest'].Value.Trim())
        $depth = Get-ParenDelta $m.Groups['rest'].Value
        $j = $i + 1

        while ($j -lt $Lines.Count) {
            $nextTrim = $Lines[$j].TrimStart()
            if ($depth -le 0 -and $nextTrim -match $definition.Stop) { break }
            if ([string]::IsNullOrWhiteSpace($Lines[$j])) { break }

            $block.Add($Lines[$j])
            $parts.Add($Lines[$j].Trim())
            $depth += Get-ParenDelta $Lines[$j]
            $j++
        }

        $blockText = $block -join "`n"
        if ($blockText -match '(?m)--|/\*|\*/') {
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

        # Do not flatten already-structured complex expressions when the user asks
        # for vertical wrapping; the normal formatter has already parsed them well.
        $complex = $joined -match '(?i)\b(OVER|CASE|SELECT|WITH)\b'
        if ($complex -and $Style -ne 'Compact') {
            foreach ($b in $block) { $out.Add($b) }
            $i = $j
            continue
        }

        $prefix = $m.Groups['indent'].Value + $m.Groups['pre'].Value + $m.Groups['kw'].Value + ' '
        $formatted = Format-ItemList -Prefix $prefix -Items $items -Style $Style -OriginalLines $block.ToArray() -BaseIndent $m.Groups['indent'].Value.Length
        foreach ($f in $formatted) { $out.Add([string]$f) }
        $i = $j
    }

    return $out.ToArray()
}

function Get-ParenListOpenIndex {
    param([string]$Text, [string]$Kind)

    if ($Kind -eq 'InList') {
        $m = [regex]::Match($Text, '(?i)\b(?:NOT\s+)?IN\s*\(')
        if ($m.Success) { return $Text.IndexOf('(', $m.Index) }
        return -1
    }

    if ($Kind -eq 'Values') {
        $m = [regex]::Match($Text, '(?i)\bVALUES\s*\(')
        if ($m.Success) { return $Text.IndexOf('(', $m.Index) }
        return -1
    }

    if ($Kind -eq 'InsertColumns') {
        if ($Text -notmatch '^(?i)INSERT\s+INTO\b') { return -1 }
        $open = $Text.IndexOf('(')
        if ($open -lt 0) { return -1 }
        $valueMatch = [regex]::Match($Text, '(?i)\b(VALUES|SELECT)\b')
        if (-not $valueMatch.Success -or $open -lt $valueMatch.Index) { return $open }
        return -1
    }

    if ($Kind -eq 'FunctionArguments') {
        $reserved = @(
            'IN','VALUES','OVER','PARTITION','ORDER','GROUP','SELECT','FROM','WHERE',
            'CASE','WHEN','THEN','ELSE','EXISTS','AS','ON','AND','OR','JOIN','TABLE',
            'CREATE','UPDATE','INSERT','DELETE'
        )
        $matches = [regex]::Matches($Text, '(?i)\b([A-Z_][A-Z0-9_$#]*)\s*\(')
        foreach ($m in $matches) {
            if ($reserved -contains $m.Groups[1].Value.ToUpperInvariant()) { continue }
            return $Text.IndexOf('(', $m.Index)
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
        $open = Get-ParenListOpenIndex -Text $trimmed -Kind $Kind

        if ($open -lt 0) {
            $out.Add($line)
            $i++
            continue
        }

        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add($trimmed)
        $balance = Get-ParenDelta $trimmed.Substring($open)
        $j = $i + 1

        while ($balance -gt 0 -and $j -lt $Lines.Count) {
            $parts.Add($Lines[$j].Trim())
            $balance += Get-ParenDelta $Lines[$j]
            $j++
        }

        if ($balance -gt 0) {
            $out.Add($line)
            $i++
            continue
        }

        $combined = Normalize-Inline ($parts -join ' ')
        $open = Get-ParenListOpenIndex -Text $combined -Kind $Kind
        if ($open -lt 0) {
            $out.Add($line)
            $i++
            continue
        }

        $close = Find-MatchingParen -Text $combined -OpenIndex $open
        if ($close -lt 0) {
            $out.Add($line)
            $i++
            continue
        }

        $inner = $combined.Substring($open + 1, $close - $open - 1)
        if ($Kind -eq 'InList' -and $inner -match '^(?i)\s*(SELECT|WITH)\b') {
            for ($k = $i; $k -lt $j; $k++) { $out.Add($Lines[$k]) }
            $i = $j
            continue
        }

        $original = @($Lines[$i..($j - 1)])
        $originalText = $original -join "`n"
        if ($originalText -match '(?m)--|/\*|\*/') {
            foreach ($b in $original) { $out.Add($b) }
            $i = $j
            continue
        }

        $items = @(Split-TopLevelComma $inner)
        if ($items.Count -lt 2) {
            foreach ($b in $original) { $out.Add($b) }
            $i = $j
            continue
        }

        $tailText = Normalize-Inline $combined.Substring($close + 1)
        $tail = ')'
        if ($tailText) { $tail += ' ' + $tailText }

        $prefix = $indent + $combined.Substring(0, $open + 1)
        $formatted = Format-ItemList -Prefix $prefix -Items $items -Style $Style -OriginalLines $original -BaseIndent $indent.Length -Tail $tail
        foreach ($f in $formatted) { $out.Add([string]$f) }
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

            $previous = $i - 1
            while ($previous -ge 0 -and [string]::IsNullOrWhiteSpace($result[$previous])) { $previous-- }
            if ($previous -lt 0 -or $result[$previous] -match '--') { continue }

            $candidate = $result[$previous].TrimEnd() + ' ' + $m.Groups['op'].Value.ToUpperInvariant()
            if ($candidate.Length -gt $script:MaxLineLength) { continue }

            $result[$previous] = $candidate
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
            $result[$next] = $indent + $m.Groups['op'].Value.ToUpperInvariant() + ' ' + $result[$next].TrimStart()
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
            if ($i + 1 -lt $Lines.Count -and
                $Lines[$i] -match '(?i)\bJOIN\b' -and
                $Lines[$i + 1].TrimStart() -match '^(?i)ON\b') {
                $candidate = $Lines[$i].TrimEnd() + ' ' + $Lines[$i + 1].TrimStart()
                if ($candidate.Length -le $script:MaxLineLength) {
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

    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^(?<before>.*?\bJOIN\b.+?)\s+ON\s+(?<after>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) {
            $indent = (Get-LeadingWhitespace $line).Length + $script:IndentSize
            $out.Add($m.Groups['before'].Value.TrimEnd())
            $out.Add((' ' * $indent) + 'ON ' + $m.Groups['after'].Value)
        }
        else {
            $out.Add($line)
        }
    }

    return $out.ToArray()
}

function Invoke-JoinLayout {
    param([string[]]$Lines, [string]$Mode)

    if ($Mode -eq 'Preserve') { return $Lines }

    if ($Mode -eq 'CompactWhenPossible') {
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($line in $Lines) {
            if ($line.TrimStart() -match '^(?i)(INNER|LEFT|RIGHT|FULL|CROSS)?\s*(OUTER\s+)?JOIN\b' -and $out.Count -gt 0) {
                $previous = $out[$out.Count - 1]
                if ($previous.TrimStart() -match '^(?i)(FROM|INNER|LEFT|RIGHT|FULL|CROSS|JOIN)\b') {
                    $candidate = $previous.TrimEnd() + ' ' + $line.TrimStart()
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

    # EachNewLine: split additional JOINs that happen to share a line.
    $expanded = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $working = $line
        $indent = Get-LeadingWhitespace $line
        $matches = [regex]::Matches($working, '(?i)\s+(?=(?:INNER|LEFT|RIGHT|FULL|CROSS)?\s*(?:OUTER\s+)?JOIN\b)')
        if ($matches.Count -eq 0) {
            $expanded.Add($line)
            continue
        }

        $start = 0
        foreach ($match in $matches) {
            $piece = $working.Substring($start, $match.Index - $start).TrimEnd()
            if ($piece) {
                if ($start -eq 0) { $expanded.Add($piece) }
                else { $expanded.Add($indent + $piece.TrimStart()) }
            }
            $start = $match.Index + $match.Length
        }
        $last = $working.Substring($start).Trim()
        if ($last) { $expanded.Add($indent + $last) }
    }

    return $expanded.ToArray()
}

function Invoke-ClauseAlignment {
    param([string[]]$Lines, [string]$Mode)

    if ($Mode -in @('Preserve', 'IBM')) { return $Lines }

    $ibmOffsets = @{
        'SELECT' = 0
        'FROM' = 2
        'WHERE' = 1
        'GROUP BY' = 1
        'HAVING' = 1
        'ORDER BY' = 1
        'FETCH' = 1
        'LIMIT' = 1
        'OFFSET' = 0
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^(?<indent>\s*)(?<kw>SELECT|FROM|WHERE|GROUP\s+BY|HAVING|ORDER\s+BY|FETCH|LIMIT|OFFSET)\b(?<rest>.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) {
            $out.Add($line)
            continue
        }

        $kw = ($m.Groups['kw'].Value -replace '\s+', ' ').ToUpperInvariant()
        $offset = 0
        if ($ibmOffsets.ContainsKey($kw)) { $offset = [int]$ibmOffsets[$kw] }
        $base = [Math]::Max(0, $m.Groups['indent'].Value.Length - $offset)
        $newIndent = $base
        if ($Mode -eq 'Indented') { $newIndent += $script:IndentSize }

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
    for ($i = 0; $i -lt $out.Count; $i++) {
        $final.Add($out[$i])
        if ($out[$i].TrimEnd().EndsWith('),') -and $i + 1 -lt $out.Count) {
            $next = $out[$i + 1].Trim()
            if ($next -match '^[A-Za-z_][A-Za-z0-9_$#]*$' -or $next -match '^[A-Za-z_][A-Za-z0-9_$#]*\s+AS\b') {
                $final.Add('')
            }
        }
    }

    return $final.ToArray()
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
        elseif ($Mode -eq 'SameLine' -and $i + 2 -lt $Lines.Count -and
            $Lines[$i].Trim() -match '^(?i)AS$' -and
            $Lines[$i + 1].Trim() -eq '(' -and
            $Lines[$i + 2].TrimStart() -match '^(?i)SELECT\b') {
            $candidate = $Lines[$i].TrimEnd() + ' (' + $Lines[$i + 2].TrimStart()
            if ($candidate.Length -le $script:MaxLineLength) {
                $out.Add((Get-LeadingWhitespace $Lines[$i]) + $candidate.TrimStart())
                $i += 3
                continue
            }
        }

        $out.Add($Lines[$i])
        $i++
    }

    return $out.ToArray()
}

function Invoke-CaseLayout {
    param([string[]]$Lines, [string]$Style, [string]$ThenMode, [string]$ElseMode)

    $work = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) { $work.Add($line) }

    if ($Style -eq 'Multiline') {
        $expanded = New-Object System.Collections.Generic.List[string]
        foreach ($line in $work) {
            $m = [regex]::Match(
                $line,
                '^(?<indent>\s*)(?<prefix>.*?)(?<case>CASE\s+WHEN\s+.+?\s+THEN\s+.+?\s+ELSE\s+.+?\s+END)(?<tail>.*)$',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($m.Success) {
                $caseText = $m.Groups['case'].Value
                $cm = [regex]::Match($caseText, '^(?i)CASE\s+WHEN\s+(.+?)\s+THEN\s+(.+?)\s+ELSE\s+(.+?)\s+END$')
                if ($cm.Success) {
                    $base = $m.Groups['indent'].Value + $m.Groups['prefix'].Value
                    $caseIndent = ' ' * $base.Length
                    $innerIndent = $caseIndent + (' ' * $script:IndentSize)
                    $expanded.Add($base + 'CASE')
                    $expanded.Add($innerIndent + 'WHEN ' + $cm.Groups[1].Value + ' THEN ' + $cm.Groups[2].Value)
                    $expanded.Add($innerIndent + 'ELSE ' + $cm.Groups[3].Value)
                    $expanded.Add($caseIndent + 'END' + $m.Groups['tail'].Value)
                    continue
                }
            }

            $expanded.Add($line)
        }
        $work = $expanded
    }
    elseif ($Style -eq 'CompactShort') {
        $compacted = New-Object System.Collections.Generic.List[string]
        $i = 0
        while ($i -lt $work.Count) {
            if ($work[$i].Trim() -eq 'CASE') {
                $end = $i + 1
                while ($end -lt $work.Count -and $end -le $i + 6 -and $work[$end].TrimStart() -notmatch '^(?i)END\b') { $end++ }
                if ($end -lt $work.Count -and $work[$end].TrimStart() -match '^(?i)END\b') {
                    $segment = @($work[$i..$end])
                    $whenCount = @($segment | Where-Object { $_.TrimStart() -match '^(?i)WHEN\b' }).Count
                    if ($whenCount -eq 1) {
                        $candidate = (Get-LeadingWhitespace $work[$i]) + (Normalize-Inline ($segment -join ' '))
                        if ($candidate.Length -le $script:MaxLineLength) {
                            $compacted.Add($candidate)
                            $i = $end + 1
                            continue
                        }
                    }
                }
            }
            $compacted.Add($work[$i])
            $i++
        }
        $work = $compacted
    }

    if ($ThenMode -eq 'NewLine') {
        $tmp = New-Object System.Collections.Generic.List[string]
        foreach ($line in $work) {
            $m = [regex]::Match($line, '^(?<indent>\s*)WHEN\s+(?<condition>.+?)\s+THEN\s+(?<result>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($m.Success) {
                $tmp.Add($m.Groups['indent'].Value + 'WHEN ' + $m.Groups['condition'].Value)
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
            if ($i + 1 -lt $work.Count -and
                $work[$i].TrimStart() -match '^(?i)WHEN\b' -and
                $work[$i + 1].TrimStart() -match '^(?i)THEN\b') {
                $candidate = $work[$i].TrimEnd() + ' ' + $work[$i + 1].TrimStart()
                if ($candidate.Length -le $script:MaxLineLength) {
                    $tmp.Add($candidate)
                    $i += 2
                    continue
                }
            }
            $tmp.Add($work[$i])
            $i++
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
            if ($i + 1 -lt $work.Count -and
                $work[$i].Trim() -match '^(?i)ELSE$' -and
                $work[$i + 1].TrimStart() -notmatch '^(?i)(WHEN|END|THEN|ELSE)\b') {
                $candidate = $work[$i].TrimEnd() + ' ' + $work[$i + 1].TrimStart()
                if ($candidate.Length -le $script:MaxLineLength) {
                    $tmp.Add($candidate)
                    $i += 2
                    continue
                }
            }
            $tmp.Add($work[$i])
            $i++
        }
        $work = $tmp
    }

    return $work.ToArray()
}

function Find-SubquerySpans {
    param([string]$Text)

    $spans = New-Object System.Collections.Generic.List[object]
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
        if ($ch -ne '(') { continue }

        $keywordIndex = $i + 1
        while ($keywordIndex -lt $Text.Length -and [char]::IsWhiteSpace($Text[$keywordIndex])) { $keywordIndex++ }
        if ($keywordIndex -ge $Text.Length) { continue }
        if ($Text.Substring($keywordIndex) -notmatch '^(?i)(SELECT|WITH)\b') { continue }

        $close = Find-MatchingParen -Text $Text -OpenIndex $i
        if ($close -lt 0) { continue }

        $spans.Add([pscustomobject]@{
            Open = $i
            Keyword = $keywordIndex
            Close = $close
        })
    }

    return $spans.ToArray()
}

function Get-LineIndentAtIndex {
    param([string]$Text, [int]$Index)

    $searchIndex = [Math]::Max(0, $Index - 1)
    $lineStart = $Text.LastIndexOf("`n", $searchIndex)
    if ($lineStart -lt 0) { $lineStart = 0 }
    else { $lineStart++ }

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
            $length = $span.Keyword - ($span.Open + 1)
            $between = ''
            if ($length -gt 0) { $between = $Text.Substring($span.Open + 1, $length) }
            if ($between -match '^\s*$') {
                $replacement = ''
                if ($OpenMode -eq 'NewLine') {
                    $replacement = [Environment]::NewLine + (' ' * ($indent + $script:IndentSize))
                }
                $replacements.Add([pscustomobject]@{ Start = $span.Open + 1; Length = $length; Text = $replacement })
            }
        }

        if ($CloseMode -ne 'Preserve') {
            $start = $span.Close
            while ($start -gt $span.Open + 1 -and [char]::IsWhiteSpace($Text[$start - 1])) { $start-- }
            $length = $span.Close - $start
            $replacement = ''
            if ($CloseMode -eq 'NewLine') {
                $replacement = [Environment]::NewLine + (' ' * $indent)
            }
            $replacements.Add([pscustomobject]@{ Start = $start; Length = $length; Text = $replacement })
        }
    }

    foreach ($replacement in @($replacements | Sort-Object Start -Descending)) {
        $Text = $Text.Substring(0, $replacement.Start) + $replacement.Text + $Text.Substring($replacement.Start + $replacement.Length)
    }

    return $Text
}

function Protect-LineLiterals {
    param([string]$Line, [hashtable]$Map, [ref]$Counter)

    $pattern = @'
'(?:''|[^'])*'|"(?:""|[^"])*"|\[(?:\]\]|[^\]])*\]|--.*$
'@

    return [regex]::Replace($Line, $pattern.Trim(), {
        param($m)
        $Counter.Value++
        $token = '__BFMT_' + $Counter.Value + '__'
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

    if ($functionParen -eq 'Preserve' -and $inside -eq 'Preserve' -and $operator -eq 'Preserve' -and $afterComma -eq 'Preserve') {
        return $Lines
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        $map = @{}
        $counter = 0
        $masked = Protect-LineLiterals -Line $line -Map $map -Counter ([ref]$counter)

        if ($functionParen -eq 'NoSpace') {
            $masked = [regex]::Replace($masked, '(?i)\b([A-Z_][A-Z0-9_$#]*)[ \t]*\(', '$1(')
        }
        elseif ($functionParen -eq 'Space') {
            $masked = [regex]::Replace($masked, '(?i)\b([A-Z_][A-Z0-9_$#]*)[ \t]*\(', '$1 (')
        }

        if ($inside -eq 'NoSpace') {
            $masked = $masked -replace '\([ \t]+', '('
            $masked = $masked -replace '[ \t]+\)', ')'
        }
        elseif ($inside -eq 'Space') {
            $masked = [regex]::Replace($masked, '\((?![\s\)])', '( ')
            $masked = [regex]::Replace($masked, '(?<![\s\(])\)', ' )')
        }

        if ($operator -eq 'Spaced') {
            $masked = [regex]::Replace($masked, '(?<![:<>=!~#@\-])[ \t]*(<>|!=|<=|>=|=|<|>)[ \t]*(?![<>=])', ' $1 ')
        }
        elseif ($operator -eq 'Tight') {
            $masked = [regex]::Replace($masked, '(?<![:<>=!~#@\-])[ \t]*(<>|!=|<=|>=|=|<|>)[ \t]*(?![<>=])', '$1')
        }

        if ($afterComma -eq 'Space') {
            $masked = [regex]::Replace($masked, ',[ \t]*', ', ')
        }
        elseif ($afterComma -eq 'NoSpace') {
            $masked = [regex]::Replace($masked, ',[ \t]*', ',')
        }

        foreach ($key in ($map.Keys | Sort-Object Length -Descending)) {
            $masked = $masked.Replace($key, $map[$key])
        }

        # Never turn a previously legal-width line into an over-width line merely
        # because of a cosmetic spacing preference.
        if ($masked.Length -gt $script:MaxLineLength -and $line.Length -le $script:MaxLineLength) {
            $out.Add($line)
        }
        else {
            $out.Add($masked)
        }
    }

    return $out.ToArray()
}

# ---------------------------------------------------------------------------
# Execute presentation passes.
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
$blankLineBetweenCtes = $false
if ($null -ne $clauses -and $clauses.PSObject.Properties.Name -contains 'blankLineBetweenCtes') {
    $blankLineBetweenCtes = [bool]$clauses.blankLineBetweenCtes
}
$lines = Invoke-CteLayout -Lines $lines -Mode (Get-Option $clauses 'cteLayout') -BlankLine $blankLineBetweenCtes
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
