<#
    DB2 MERGE formatter.

    Input: one normalized MERGE statement on stdin.
    Output: formatted MERGE on stdout.

    The USING query is formatted independently by format-sql-core.ps1 and
    then placed into the MERGE statement with parent indentation applied.
#>

$ErrorActionPreference = "Stop"

$script:MaxLineLength = 120
$script:ProtectedMap = @{}
$script:ProtectedIndex = 0
$CoreFormatter = Join-Path $PSScriptRoot "format-sql-core.ps1"

function Load-SqlfmtSettings {
    $settingsPath = Join-Path $PSScriptRoot "settings\settings.json"
    if (-not (Test-Path $settingsPath)) { return }

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
        # Invalid settings must not make formatting fail.
    }
}

function New-ProtectedToken {
    param([string]$Prefix, [string]$Value)

    $script:ProtectedIndex++
    $token = "__SQLFMT_MERGE_${Prefix}_$script:ProtectedIndex`__"
    $script:ProtectedMap[$token] = $Value
    return $token
}

function Protect-SqlText {
    param([string]$Sql)

    $script:ProtectedMap = @{}
    $script:ProtectedIndex = 0
    $Sql = [regex]::Replace($Sql, '/\*[\s\S]*?\*/', { param($m) New-ProtectedToken -Prefix "BCOM" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, "'(?:''|[^'])*'", { param($m) New-ProtectedToken -Prefix "STR" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '"(?:""|[^"])*"', { param($m) New-ProtectedToken -Prefix "DQS" -Value $m.Value })
    return $Sql
}

function Restore-SqlText {
    param([string]$Sql)

    foreach ($key in ($script:ProtectedMap.Keys | Sort-Object Length -Descending)) {
        $Sql = $Sql.Replace($key, $script:ProtectedMap[$key])
    }
    return $Sql
}

function Normalize-Space {
    param([string]$Text)

    if ($null -eq $Text) { return "" }
    $Text = $Text -replace '[\r\n\t]+', ' '
    $Text = $Text -replace '\s+', ' '
    $Text = $Text -replace '\s+,', ','
    $Text = $Text -replace ',\s*', ', '
    $Text = $Text -replace '\(\s+', '('
    $Text = $Text -replace '\s+\)', ')'
    $Text = $Text -replace '\s+;', ';'
    return $Text.Trim()
}

function Find-MatchingParen {
    param([string]$Text, [int]$OpenIndex)

    $depth = 0
    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '(') {
            $depth++
        }
        elseif ($Text[$i] -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

function Get-ParenDepthAt {
    param([string]$Text, [int]$Index)

    $depth = 0
    for ($i = 0; $i -lt $Index; $i++) {
        if ($Text[$i] -eq '(') { $depth++ }
        elseif ($Text[$i] -eq ')' -and $depth -gt 0) { $depth-- }
    }
    return $depth
}

function Get-TopLevelMatches {
    param([string]$Text, [string]$Pattern)

    $result = New-Object System.Collections.Generic.List[object]
    $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $rx.Matches($Text)) {
        if ((Get-ParenDepthAt -Text $Text -Index $m.Index) -eq 0) {
            $result.Add($m)
        }
    }
    return $result
}

function Get-FirstTopLevelMatch {
    param([string]$Text, [string]$Pattern)

    $matches = @(Get-TopLevelMatches -Text $Text -Pattern $Pattern)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Split-TopLevelByComma {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0

    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '(') { $depth++ }
        elseif ($Text[$i] -eq ')' -and $depth -gt 0) { $depth-- }
        elseif ($Text[$i] -eq ',' -and $depth -eq 0) {
            $piece = Normalize-Space $Text.Substring($start, $i - $start)
            if ($piece) { $items.Add($piece) }
            $start = $i + 1
        }
    }

    $tail = Normalize-Space $Text.Substring($start)
    if ($tail) { $items.Add($tail) }
    return $items
}

function Split-TopLevelLogical {
    param([string]$Text)

    $parts = New-Object System.Collections.Generic.List[object]
    $depth = 0
    $start = 0
    $currentOp = ''
    $betweenNeedsAnd = $false
    $i = 0

    while ($i -lt $Text.Length) {
        if ($Text[$i] -eq '(') {
            $depth++
            $i++
            continue
        }
        if ($Text[$i] -eq ')') {
            if ($depth -gt 0) { $depth-- }
            $i++
            continue
        }

        if ($depth -eq 0) {
            $rest = $Text.Substring($i)
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

                $piece = Normalize-Space $Text.Substring($start, $i - $start)
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

    $tail = Normalize-Space $Text.Substring($start)
    if ($tail) {
        $parts.Add([pscustomobject]@{ Op = $currentOp; Text = $tail })
    }
    if ($parts.Count -eq 0) {
        $parts.Add([pscustomobject]@{ Op = ''; Text = (Normalize-Space $Text) })
    }
    return $parts
}

function Wrap-Words {
    param([string]$Text, [string]$FirstPrefix, [string]$ContinuationPrefix)

    $text = Normalize-Space $Text
    if (-not $text) { return @($FirstPrefix.TrimEnd()) }

    $words = @($text -split '\s+' | Where-Object { $_ })
    $out = New-Object System.Collections.Generic.List[string]
    $current = $FirstPrefix

    foreach ($word in $words) {
        $separator = ' '
        if (-not $current -or $current.EndsWith(' ')) { $separator = '' }
        $candidate = $current + $separator + $word

        if ($candidate.Length -gt $script:MaxLineLength -and $current.Trim().Length -gt 0) {
            $out.Add($current.TrimEnd())
            $current = $ContinuationPrefix + $word
        }
        else {
            $current = $candidate
        }
    }

    if ($current.Trim().Length -gt 0) { $out.Add($current.TrimEnd()) }
    return $out
}

function Format-CoreSql {
    param([string]$Sql)

    $restored = Restore-SqlText $Sql
    $formatted = $restored |
        powershell -NoProfile -ExecutionPolicy Bypass -File $CoreFormatter |
        Out-String
    return $formatted.TrimEnd("`r", "`n")
}

function Add-IndentedCoreSql {
    param(
        [System.Collections.Generic.List[string]]$Output,
        [string]$Sql,
        [int]$Indent
    )

    $formatted = Format-CoreSql $Sql
    $lines = @($formatted -split "`r?`n")

    foreach ($line in $lines) {
        $candidate = (' ' * $Indent) + $line
        if ($candidate.Length -le $script:MaxLineLength) {
            $Output.Add($candidate)
            continue
        }

        $leading = $candidate.Length - $candidate.TrimStart().Length
        $prefix = ' ' * $leading
        foreach ($wrapped in @(Wrap-Words -Text $candidate.TrimStart() -FirstPrefix $prefix -ContinuationPrefix $prefix)) {
            $Output.Add($wrapped)
        }
    }
}

function Format-LogicalCondition {
    param([string]$Text, [string]$Clause)

    $text = Normalize-Space $Text
    $hasOuterParens = $false

    if ($text.StartsWith('(')) {
        $close = Find-MatchingParen -Text $text -OpenIndex 0
        if ($close -eq $text.Length - 1) {
            $hasOuterParens = $true
            $text = $text.Substring(1, $text.Length - 2).Trim()
        }
    }

    $parts = @(Split-TopLevelLogical $text)
    $out = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -eq 0) {
            switch ($Clause.ToUpperInvariant()) {
                'ON'  { $prefix = '    ON ' }
                'AND' { $prefix = '   AND ' }
                'OR'  { $prefix = '    OR ' }
                default { $prefix = $Clause + ' ' }
            }
            if ($hasOuterParens) { $prefix += '(' }
        }
        else {
            if ($parts[$i].Op -eq 'OR') { $prefix = '    OR ' }
            else { $prefix = '   AND ' }
        }

        $continuation = ' ' * $prefix.Length
        foreach ($line in @(Wrap-Words -Text $parts[$i].Text -FirstPrefix $prefix -ContinuationPrefix $continuation)) {
            $out.Add($line)
        }
    }

    if ($hasOuterParens -and $out.Count -gt 0) {
        if (($out[$out.Count - 1] + ')').Length -le $script:MaxLineLength) {
            $out[$out.Count - 1] = $out[$out.Count - 1] + ')'
        }
        else {
            $out.Add('    )')
        }
    }
    return $out
}

function Format-ParenList {
    param([string]$Keyword, [string]$Body)

    $items = @(Split-TopLevelByComma $Body)
    $compact = $Keyword + ' ( ' + ($items -join ', ') + ' )'
    if ($compact.Length -le $script:MaxLineLength) { return @($compact) }

    $out = New-Object System.Collections.Generic.List[string]
    $firstPrefix = $Keyword + ' ( '
    $nextPrefix = ' ' * $firstPrefix.Length

    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { ' )' }
        $prefix = if ($i -eq 0) { $firstPrefix } else { $nextPrefix }
        $candidate = $prefix + $items[$i] + $suffix

        if ($candidate.Length -le $script:MaxLineLength) {
            $out.Add($candidate)
        }
        else {
            foreach ($line in @(Wrap-Words -Text ($items[$i] + $suffix) -FirstPrefix $prefix -ContinuationPrefix $nextPrefix)) {
                $out.Add($line)
            }
        }
    }
    return $out
}

function Format-UpdateAction {
    param([string]$Action)

    $action = Normalize-Space $Action
    $set = Get-FirstTopLevelMatch -Text $action -Pattern '\bSET\b'
    if ($null -eq $set) {
        return @(Wrap-Words -Text $action -FirstPrefix '' -ContinuationPrefix '  ')
    }

    $head = Normalize-Space $action.Substring(0, $set.Index)
    if (-not $head) { $head = 'UPDATE' }
    $body = Normalize-Space $action.Substring($set.Index + $set.Length)
    $items = @(Split-TopLevelByComma $body)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($head)

    for ($i = 0; $i -lt $items.Count; $i++) {
        $prefix = if ($i -eq 0) { '   SET ' } else { '       ' }
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $candidate = $prefix + $items[$i] + $suffix

        if ($candidate.Length -le $script:MaxLineLength) {
            $out.Add($candidate)
        }
        else {
            foreach ($line in @(Wrap-Words -Text ($items[$i] + $suffix) -FirstPrefix $prefix -ContinuationPrefix (' ' * $prefix.Length))) {
                $out.Add($line)
            }
        }
    }
    return $out
}

function Format-InsertAction {
    param([string]$Action)

    $action = Normalize-Space $Action
    $m = [regex]::Match($action, '^(?i)INSERT\s*\(')
    if (-not $m.Success) {
        return @(Wrap-Words -Text $action -FirstPrefix '' -ContinuationPrefix '  ')
    }

    $open = $action.IndexOf('(', $m.Index + $m.Length - 1)
    $close = Find-MatchingParen -Text $action -OpenIndex $open
    if ($close -lt 0) {
        return @(Wrap-Words -Text $action -FirstPrefix '' -ContinuationPrefix '  ')
    }

    $columns = $action.Substring($open + 1, $close - $open - 1)
    $tail = Normalize-Space $action.Substring($close + 1)
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($line in @(Format-ParenList -Keyword 'INSERT' -Body $columns)) {
        $out.Add($line)
    }

    $valuesMatch = [regex]::Match($tail, '^(?i)VALUES\s*\(')
    if ($valuesMatch.Success) {
        $vopen = $tail.IndexOf('(', $valuesMatch.Index + $valuesMatch.Length - 1)
        $vclose = Find-MatchingParen -Text $tail -OpenIndex $vopen
        if ($vclose -gt $vopen) {
            $values = $tail.Substring($vopen + 1, $vclose - $vopen - 1)
            foreach ($line in @(Format-ParenList -Keyword 'VALUES' -Body $values)) {
                $out.Add($line)
            }
            $after = Normalize-Space $tail.Substring($vclose + 1)
            if ($after) {
                foreach ($line in @(Wrap-Words -Text $after -FirstPrefix '' -ContinuationPrefix '  ')) {
                    $out.Add($line)
                }
            }
            return $out
        }
    }

    if ($tail) {
        foreach ($line in @(Wrap-Words -Text $tail -FirstPrefix '' -ContinuationPrefix '  ')) {
            $out.Add($line)
        }
    }
    return $out
}

function Format-MergeAction {
    param([string]$Action)

    $action = Normalize-Space $Action
    if ($action -match '^(?i)UPDATE\b') { return @(Format-UpdateAction -Action $action) }
    if ($action -match '^(?i)INSERT\b') { return @(Format-InsertAction -Action $action) }
    return @(Wrap-Words -Text $action -FirstPrefix '' -ContinuationPrefix '  ')
}

Load-SqlfmtSettings

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$sql = Protect-SqlText $inputSql
$sql = Normalize-Space $sql
$sql = $sql -replace ';+\s*$', ''

$isolation = ''
$isolationMatch = [regex]::Match($sql, '(?i)\s+WITH\s+(UR|RS|CS|RR|NC)\s*$')
if ($isolationMatch.Success -and (Get-ParenDepthAt -Text $sql -Index $isolationMatch.Index) -eq 0) {
    $isolation = 'WITH ' + $isolationMatch.Groups[1].Value.ToUpperInvariant()
    $sql = $sql.Substring(0, $isolationMatch.Index).TrimEnd()
}

$using = Get-FirstTopLevelMatch -Text $sql -Pattern '\bUSING\b'
$on = Get-FirstTopLevelMatch -Text $sql -Pattern '\bON\b'
$whens = @(Get-TopLevelMatches -Text $sql -Pattern '\bWHEN\s+(?:NOT\s+)?MATCHED\b')

if ($null -eq $using -or $null -eq $on -or $on.Index -le $using.Index -or $whens.Count -eq 0) {
    $fallback = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Wrap-Words -Text $sql -FirstPrefix '' -ContinuationPrefix '  ')) {
        $fallback.Add($line)
    }
    if ($isolation) { $fallback.Add('  ' + $isolation) }
    if ($fallback.Count -gt 0) { $fallback[$fallback.Count - 1] = $fallback[$fallback.Count - 1] + ';' }
    [Console]::Out.Write((Restore-SqlText ($fallback -join [Environment]::NewLine)))
    exit 0
}

$out = New-Object System.Collections.Generic.List[string]
$head = Normalize-Space $sql.Substring(0, $using.Index)
foreach ($line in @(Wrap-Words -Text $head -FirstPrefix '' -ContinuationPrefix '  ')) {
    $out.Add($line)
}

$usingBody = Normalize-Space $sql.Substring($using.Index + $using.Length, $on.Index - ($using.Index + $using.Length)))
$usingFormatted = $false

if ($usingBody.StartsWith('(')) {
    $close = Find-MatchingParen -Text $usingBody -OpenIndex 0
    if ($close -gt 0) {
        $inner = $usingBody.Substring(1, $close - 1).Trim()
        $alias = Normalize-Space $usingBody.Substring($close + 1)
        if ($inner -match '^(?i)(SELECT|WITH)\b') {
            $out.Add(' USING (')
            Add-IndentedCoreSql -Output $out -Sql $inner -Indent 2
            $closeLine = ' )'
            if ($alias) { $closeLine += ' ' + $alias }
            $out.Add($closeLine)
            $usingFormatted = $true
        }
    }
}

if (-not $usingFormatted) {
    foreach ($line in @(Wrap-Words -Text $usingBody -FirstPrefix ' USING ' -ContinuationPrefix '       ')) {
        $out.Add($line)
    }
}

$firstWhenIndex = $whens[0].Index
$onBody = Normalize-Space $sql.Substring($on.Index + $on.Length, $firstWhenIndex - ($on.Index + $on.Length)))
foreach ($line in @(Format-LogicalCondition -Text $onBody -Clause 'ON')) {
    $out.Add($line)
}

for ($w = 0; $w -lt $whens.Count; $w++) {
    $when = $whens[$w]
    if ($w -lt $whens.Count - 1) { $next = $whens[$w + 1].Index }
    else { $next = $sql.Length }

    $whenName = (Normalize-Space $when.Value).ToUpperInvariant()
    $segment = Normalize-Space $sql.Substring($when.Index + $when.Length, $next - ($when.Index + $when.Length))
    $then = Get-FirstTopLevelMatch -Text $segment -Pattern '\bTHEN\b'

    if ($null -eq $then) {
        foreach ($line in @(Wrap-Words -Text ($whenName + ' ' + $segment) -FirstPrefix '  ' -ContinuationPrefix '    ')) {
            $out.Add($line)
        }
        continue
    }

    $condition = Normalize-Space $segment.Substring(0, $then.Index)
    $action = Normalize-Space $segment.Substring($then.Index + $then.Length)
    $out.Add('  ' + $whenName)

    if ($condition) {
        if ($condition -match '^(?i)AND\b') {
            $condition = $condition -replace '^(?i)AND\s*', ''
            foreach ($line in @(Format-LogicalCondition -Text $condition -Clause 'AND')) {
                $out.Add($line)
            }
        }
        elseif ($condition -match '^(?i)OR\b') {
            $condition = $condition -replace '^(?i)OR\s*', ''
            foreach ($line in @(Format-LogicalCondition -Text $condition -Clause 'OR')) {
                $out.Add($line)
            }
        }
        else {
            foreach ($line in @(Wrap-Words -Text $condition -FirstPrefix '    ' -ContinuationPrefix '    ')) {
                $out.Add($line)
            }
        }
    }

    $out.Add('  THEN')
    foreach ($line in @(Format-MergeAction -Action $action)) {
        $out.Add($line)
    }
}

if ($isolation) { $out.Add('  ' + $isolation) }
if ($out.Count -gt 0) {
    $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';'
}

$formatted = Restore-SqlText ($out -join [Environment]::NewLine)
[Console]::Out.Write($formatted)
