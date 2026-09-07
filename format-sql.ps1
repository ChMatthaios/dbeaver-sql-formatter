<#
    DBeaver SQL Formatter - DB2 heuristic formatter

    Design goals:
      - Safe formatting over aggressive rewriting.
      - Stable DBeaver stdin -> stdout behavior.
      - IBM-style clause grid (SELECT / FROM / WHERE / AND / OR).
      - Recursive formatting for CTEs and subqueries where it is safe.
      - Compact short constructs; wrap only when readability or maxLineLength requires it.
      - Preserve strings, quoted identifiers and comments.

    This is intentionally not a full DB2 parser.
#>

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

$script:MaxLineLength = 120
$script:IndentSize = 2
$script:KeywordCasing = "Uppercase"
$script:PreserveCommentLineBoundaries = $true
$script:ProtectedMap = @{}
$script:ProtectedIndex = 0

function Load-SqlfmtSettings {
    $settingsPath = Join-Path $PSScriptRoot "settings\settings.json"

    if (-not (Test-Path $settingsPath)) {
        return
    }

    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

        if ($settings.PSObject.Properties.Name -contains "maxLineLength") {
            $value = 0
            if ([int]::TryParse([string]$settings.maxLineLength, [ref]$value) -and $value -ge 60 -and $value -le 400) {
                $script:MaxLineLength = $value
            }
        }

        if ($settings.PSObject.Properties.Name -contains "indentSize") {
            $value = 0
            if ([int]::TryParse([string]$settings.indentSize, [ref]$value) -and $value -in @(2, 4)) {
                $script:IndentSize = $value
            }
        }

        if ($settings.PSObject.Properties.Name -contains "keywordCasing") {
            $value = [string]$settings.keywordCasing
            if ($value -in @("Uppercase", "Lowercase", "Preserve")) {
                $script:KeywordCasing = $value
            }
        }

        if ($settings.PSObject.Properties.Name -contains "preserveCommentLineBoundaries") {
            $script:PreserveCommentLineBoundaries = [bool]$settings.preserveCommentLineBoundaries
        }
    }
    catch {
        # Invalid local settings must never break DBeaver formatting.
    }
}

Load-SqlfmtSettings

# ---------------------------------------------------------------------------
# Protection
# ---------------------------------------------------------------------------

function New-ProtectedToken {
    param(
        [string]$Prefix,
        [string]$Value
    )

    $script:ProtectedIndex++
    $token = "__SQLFMT_${Prefix}_$script:ProtectedIndex`__"
    $script:ProtectedMap[$token] = $Value
    return $token
}

function Protect-SqlText {
    param([string]$Sql)

    $script:ProtectedMap = @{}
    $script:ProtectedIndex = 0

    # Protect block comments first, then strings/quoted identifiers, then line comments.
    $Sql = [regex]::Replace($Sql, '/\*[\s\S]*?\*/', { param($m) New-ProtectedToken -Prefix "BCOM" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, "'(?:''|[^'])*'", { param($m) New-ProtectedToken -Prefix "STR" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '"(?:""|[^"])*"', { param($m) New-ProtectedToken -Prefix "DQS" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '--[^\r\n]*', { param($m) New-ProtectedToken -Prefix "LCOM" -Value $m.Value })

    if ($script:PreserveCommentLineBoundaries) {
        $Sql = [regex]::Replace(
            $Sql,
            '(__SQLFMT_(?:LCOM|BCOM)_\d+__)(\r?\n)([ \t]*)',
            {
                param($m)
                return $m.Groups[1].Value + " __SQLFMT_EOL_" + $m.Groups[3].Value.Length + "__ "
            }
        )
    }

    return $Sql
}

function Restore-SqlText {
    param([string]$Sql)

    $Sql = [regex]::Replace(
        $Sql,
        '[ \t]*__SQLFMT_EOL_(\d+)__[ \t]*',
        {
            param($m)
            return [Environment]::NewLine + (' ' * [int]$m.Groups[1].Value)
        }
    )

    foreach ($key in ($script:ProtectedMap.Keys | Sort-Object Length -Descending)) {
        $Sql = $Sql.Replace($key, $script:ProtectedMap[$key])
    }

    return $Sql
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

function Normalize-Space {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $Text = $Text -replace '[\r\n\t]+', ' '
    $Text = $Text -replace '\s+', ' '
    $Text = $Text -replace '\s+,', ','
    $Text = $Text -replace ',\s*', ', '
    $Text = $Text -replace '\(\s+', '('
    $Text = $Text -replace '\s+\)', ')'
    $Text = $Text -replace '\s+;', ';'
    return $Text.Trim()
}

function Convert-SqlKeywords {
    param([string]$Sql)

    if ($script:KeywordCasing -eq "Preserve") {
        return $Sql
    }

    $keywords = @(
        'select','distinct','from','where','and','or','not','null','is','in','exists','between','like',
        'inner','left','right','full','cross','outer','join','on','group','by','having','order',
        'asc','desc','fetch','first','row','rows','only','limit','offset','with','ur','rs','cs','rr','nc',
        'union','all','except','intersect','case','when','then','else','end','as','over','partition',
        'insert','into','values','update','set','delete','merge','using','matched',
        'create','replace','procedure','function','returns','language','sql','begin','atomic',
        'declare','cursor','for','continue','handler','open','close','loop','leave','if','elseif',
        'signal','sqlstate','message_text','prepare','execute','table','view','index','schema',
        'constraint','primary','key','foreign','references','check','default','temporary','global',
        'session','commit','preserve','logged','alter','add','column','data','type','optimize',
        'deterministic','external','action','no','of','current','timestamp','user'
    )

    foreach ($kw in $keywords) {
        $escaped = [regex]::Escape($kw)
        $Sql = [regex]::Replace(
            $Sql,
            "(?i)(?<![A-Z0-9_])$escaped(?![A-Z0-9_])",
            {
                param($m)
                if ($script:KeywordCasing -eq "Lowercase") {
                    return $m.Value.ToLowerInvariant()
                }
                return $m.Value.ToUpperInvariant()
            }
        )
    }

    return $Sql
}

function Strip-TrailingSemicolon {
    param([string]$Text)
    return ($Text.Trim() -replace ';+\s*$', '')
}

function Find-MatchingParen {
    param(
        [string]$Text,
        [int]$OpenIndex
    )

    $depth = 0
    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '(') {
            $depth++
        }
        elseif ($Text[$i] -eq ')') {
            $depth--
            if ($depth -eq 0) {
                return $i
            }
        }
    }
    return -1
}

function Get-ParenDepthAt {
    param(
        [string]$Text,
        [int]$Index
    )

    $depth = 0
    for ($i = 0; $i -lt $Index; $i++) {
        if ($Text[$i] -eq '(') {
            $depth++
        }
        elseif ($Text[$i] -eq ')' -and $depth -gt 0) {
            $depth--
        }
    }
    return $depth
}

function Get-TopLevelMatches {
    param(
        [string]$Text,
        [string]$Pattern
    )

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
    param(
        [string]$Text,
        [string]$Pattern
    )

    $matches = @(Get-TopLevelMatches -Text $Text -Pattern $Pattern)
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Split-TopLevelByComma {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0

    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '(') {
            $depth++
        }
        elseif ($Text[$i] -eq ')') {
            if ($depth -gt 0) { $depth-- }
        }
        elseif ($Text[$i] -eq ',' -and $depth -eq 0) {
            $item = Normalize-Space $Text.Substring($start, $i - $start)
            if ($item) { $items.Add($item) }
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

function Split-TrailingIsolationClause {
    param([string]$Text)

    $normalized = Normalize-Space $Text
    $m = [regex]::Match($normalized, '(?i)\s+WITH\s+(UR|RS|CS|RR|NC)\s*$')
    if (-not $m.Success -or (Get-ParenDepthAt -Text $normalized -Index $m.Index) -ne 0) {
        return [pscustomobject]@{ Sql = $normalized; Isolation = '' }
    }

    return [pscustomobject]@{
        Sql = $normalized.Substring(0, $m.Index).TrimEnd()
        Isolation = ('WITH ' + $m.Groups[1].Value.ToUpperInvariant())
    }
}

function Get-LinePrefixForClause {
    param(
        [string]$Clause,
        [int]$Indent
    )

    $base = ' ' * $Indent
    switch ($Clause.ToUpperInvariant()) {
        'SELECT'   { return $base + 'SELECT ' }
        'FROM'     { return $base + '  FROM ' }
        'WHERE'    { return $base + ' WHERE ' }
        'AND'      { return $base + '   AND ' }
        'OR'       { return $base + '    OR ' }
        'GROUP BY' { return $base + ' GROUP BY ' }
        'HAVING'   { return $base + ' HAVING ' }
        'ORDER BY' { return $base + ' ORDER BY ' }
        'FETCH'    { return $base + ' FETCH ' }
        'LIMIT'    { return $base + ' LIMIT ' }
        'WITH'     { return $base + '  WITH ' }
        default    { return $base + $Clause + ' ' }
    }
}

function Format-ParenthesizedSubqueries {
    param(
        [string]$Text,
        [int]$AbsolutePrefixLength,
        [int]$Depth = 0
    )

    if ($Depth -ge 8) {
        return Normalize-Space $Text
    }

    $work = Normalize-Space $Text
    for ($i = 0; $i -lt $work.Length; $i++) {
        if ($work[$i] -ne '(') { continue }
        $close = Find-MatchingParen -Text $work -OpenIndex $i
        if ($close -lt 0) { continue }

        $inner = $work.Substring($i + 1, $close - $i - 1).Trim()
        if ($inner -notmatch '^(?i)(SELECT|WITH)\b') { continue }

        $head = $work.Substring(0, $i)
        $tail = $work.Substring($close + 1)
        $innerIndent = $AbsolutePrefixLength + $head.Length + 1
        $formattedInner = @(Format-SqlStatement -Statement $inner -Indent $innerIndent -NoSemicolon -Depth ($Depth + 1))
        if ($formattedInner.Count -eq 0) { return $work }

        $out = New-Object System.Collections.Generic.List[string]
        $out.Add($head + '(' + $formattedInner[0].TrimStart())
        for ($j = 1; $j -lt $formattedInner.Count; $j++) {
            $out.Add($formattedInner[$j])
        }
        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ')' + $tail
        return ($out -join [Environment]::NewLine)
    }

    return $work
}

# ---------------------------------------------------------------------------
# SELECT / FROM / WHERE
# ---------------------------------------------------------------------------

function Format-CaseSelectItem {
    param(
        [string]$Item,
        [string]$FirstPrefix,
        [string]$NextPrefix
    )

    $item = Normalize-Space $Item
    if ($item -notmatch '^(?i)CASE\b') {
        return @($FirstPrefix + $item)
    }

    $alias = ''
    $mAlias = [regex]::Match($item, '(?i)\bEND\s+(AS\s+)?([A-Z0-9_]+)\s*$')
    if ($mAlias.Success) {
        $alias = ' ' + $(if ($mAlias.Groups[1].Success) { 'AS ' } else { '' }) + $mAlias.Groups[2].Value
        $body = $item.Substring(0, $mAlias.Index + 3).Trim()
    }
    else {
        $body = $item
    }

    $body = $body -replace '^(?i)CASE\s*', ''
    $body = $body -replace '(?i)\s*END\s*$', ''
    $tokens = [regex]::Matches($body, '(?i)\bWHEN\b|\bELSE\b')
    if ($tokens.Count -eq 0) {
        return @($FirstPrefix + $item)
    }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($FirstPrefix + 'CASE')
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $next = if ($i -lt $tokens.Count - 1) { $tokens[$i + 1].Index } else { $body.Length }
        $segment = Normalize-Space $body.Substring($tokens[$i].Index, $next - $tokens[$i].Index)
        $out.Add($NextPrefix + (' ' * $script:IndentSize) + $segment)
    }
    $out.Add($NextPrefix + 'END' + $alias)
    return $out
}

function Format-SelectList {
    param(
        [string]$Text,
        [int]$Indent,
        [int]$Depth = 0
    )

    $items = @(Split-TopLevelByComma (Normalize-Space $Text))
    $out = New-Object System.Collections.Generic.List[string]
    $firstPrefix = Get-LinePrefixForClause -Clause 'SELECT' -Indent $Indent
    $nextPrefix = (' ' * $Indent) + (' ' * 7)

    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $prefix = if ($i -eq 0) { $firstPrefix } else { $nextPrefix }
        $item = Format-ParenthesizedSubqueries -Text $items[$i] -AbsolutePrefixLength ($Indent + 7) -Depth $Depth

        if ($item -match '^(?i)CASE\b') {
            $lines = @(Format-CaseSelectItem -Item $item -FirstPrefix $prefix -NextPrefix $nextPrefix)
            for ($j = 0; $j -lt $lines.Count; $j++) {
                if ($j -eq $lines.Count - 1) { $out.Add($lines[$j] + $suffix) }
                else { $out.Add($lines[$j]) }
            }
        }
        elseif ($item.Contains([Environment]::NewLine)) {
            $lines = $item -split [regex]::Escape([Environment]::NewLine)
            $out.Add($prefix + $lines[0])
            for ($j = 1; $j -lt $lines.Count; $j++) {
                $line = $lines[$j]
                if ($j -eq $lines.Count - 1) { $line += $suffix }
                $out.Add($line)
            }
        }
        else {
            $out.Add($prefix + $item + $suffix)
        }
    }

    if ($items.Count -eq 0) {
        $out.Add($firstPrefix.TrimEnd())
    }
    return $out
}

function Format-JoinClause {
    param(
        [string]$JoinText,
        [int]$Indent
    )

    $joinText = Normalize-Space $JoinText
    $prefix = ' ' * $Indent
    $on = Get-FirstTopLevelMatch -Text $joinText -Pattern '\bON\b'

    if ($null -eq $on) {
        return @($prefix + '  ' + $joinText)
    }

    # README rule: short joins may remain on one line.
    $compact = $prefix + '  ' + $joinText
    if ($compact.Length -le $script:MaxLineLength -and $joinText -notmatch '__SQLFMT_EOL_') {
        return @($compact)
    }

    $head = Normalize-Space $joinText.Substring(0, $on.Index)
    $conditions = Normalize-Space $joinText.Substring($on.Index + $on.Length)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($prefix + '  ' + $head)

    $parts = @(Split-TopLevelLogical $conditions)
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $op = if ($i -eq 0) { 'ON' } elseif ($parts[$i].Op -eq 'OR') { 'OR' } else { 'AND' }
        $linePrefix = switch ($op) {
            'ON'  { $prefix + '    ON ' }
            'OR'  { $prefix + '    OR ' }
            default { $prefix + '   AND ' }
        }
        $condition = Format-ParenthesizedSubqueries -Text $parts[$i].Text -AbsolutePrefixLength $linePrefix.Length
        if ($condition.Contains([Environment]::NewLine)) {
            $lines = $condition -split [regex]::Escape([Environment]::NewLine)
            $out.Add($linePrefix + $lines[0])
            for ($j = 1; $j -lt $lines.Count; $j++) { $out.Add($lines[$j]) }
        }
        else {
            $out.Add($linePrefix + $condition)
        }
    }
    return $out
}

function Format-FromClause {
    param(
        [string]$Text,
        [int]$Indent,
        [int]$Depth = 0
    )

    $text = Normalize-Space $Text
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]

    # Derived table / FROM subquery.
    if ($text.StartsWith('(')) {
        $close = Find-MatchingParen -Text $text -OpenIndex 0
        if ($close -gt 0) {
            $inner = $text.Substring(1, $close - 1).Trim()
            $alias = Normalize-Space $text.Substring($close + 1)
            if ($inner -match '^(?i)(SELECT|WITH)\b') {
                $innerLines = @(Format-SqlStatement -Statement $inner -Indent ($Indent + 9) -NoSemicolon -Depth ($Depth + 1))
                $out.Add($prefix + '  FROM ( ' + $innerLines[0].TrimStart())
                for ($i = 1; $i -lt $innerLines.Count; $i++) { $out.Add($innerLines[$i]) }
                $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ' )' + $(if ($alias) { ' ' + $alias } else { '' })
                return $out
            }
        }
    }

    $joinPattern = '\b(LEFT\s+OUTER\s+JOIN|RIGHT\s+OUTER\s+JOIN|FULL\s+OUTER\s+JOIN|INNER\s+JOIN|LEFT\s+JOIN|RIGHT\s+JOIN|FULL\s+JOIN|CROSS\s+JOIN|JOIN)\b'
    $joins = @(Get-TopLevelMatches -Text $text -Pattern $joinPattern)
    if ($joins.Count -eq 0) {
        $out.Add($prefix + '  FROM ' + $text)
        return $out
    }

    $source = Normalize-Space $text.Substring(0, $joins[0].Index)
    $out.Add($prefix + '  FROM ' + $source)
    for ($i = 0; $i -lt $joins.Count; $i++) {
        $next = if ($i -lt $joins.Count - 1) { $joins[$i + 1].Index } else { $text.Length }
        $joinText = $text.Substring($joins[$i].Index, $next - $joins[$i].Index)
        foreach ($line in @(Format-JoinClause -JoinText $joinText -Indent $Indent)) {
            $out.Add($line)
        }
    }
    return $out
}

function Format-WhereLikeClause {
    param(
        [string]$Text,
        [string]$Keyword,
        [int]$Indent,
        [int]$Depth = 0
    )

    $parts = @(Split-TopLevelLogical (Normalize-Space $Text))
    $out = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $clause = if ($i -eq 0) { $Keyword } elseif ($parts[$i].Op -eq 'OR') { 'OR' } else { 'AND' }
        $linePrefix = Get-LinePrefixForClause -Clause $clause -Indent $Indent
        $condition = Format-ParenthesizedSubqueries -Text $parts[$i].Text -AbsolutePrefixLength $linePrefix.Length -Depth $Depth
        if ($condition.Contains([Environment]::NewLine)) {
            $lines = $condition -split [regex]::Escape([Environment]::NewLine)
            $out.Add($linePrefix + $lines[0])
            for ($j = 1; $j -lt $lines.Count; $j++) { $out.Add($lines[$j]) }
        }
        else {
            $out.Add($linePrefix + $condition)
        }
    }
    return $out
}

function Format-CommaClause {
    param(
        [string]$Text,
        [string]$Keyword,
        [int]$Indent
    )

    $normalized = Normalize-Space $Text
    $prefix = Get-LinePrefixForClause -Clause $Keyword -Indent $Indent
    if (($prefix + $normalized).Length -le $script:MaxLineLength) {
        return @($prefix + $normalized)
    }

    $items = @(Split-TopLevelByComma $normalized)
    $out = New-Object System.Collections.Generic.List[string]
    $continuation = ' ' * $prefix.Length
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $out.Add($(if ($i -eq 0) { $prefix } else { $continuation }) + $items[$i] + $suffix)
    }
    return $out
}

function Format-SelectStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$Depth = 0
    )

    $sql = Strip-TrailingSemicolon (Normalize-Space $Sql)
    $select = Get-FirstTopLevelMatch -Text $sql -Pattern '^SELECT\b'
    if ($null -eq $select) {
        return @((' ' * $Indent) + $sql + $(if ($NoSemicolon) { '' } else { ';' }))
    }

    $clausePattern = '\b(FROM|WHERE|GROUP\s+BY|HAVING|ORDER\s+BY|FETCH\s+FIRST|LIMIT|WITH\s+(UR|RS|CS|RR|NC))\b'
    $matches = @(Get-TopLevelMatches -Text $sql -Pattern $clausePattern)
    $selectStart = $select.Index + $select.Length
    $selectEnd = if ($matches.Count -gt 0) { $matches[0].Index } else { $sql.Length }
    $selectText = $sql.Substring($selectStart, $selectEnd - $selectStart)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Format-SelectList -Text $selectText -Indent $Indent -Depth $Depth)) { $out.Add($line) }

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $m = $matches[$i]
        $next = if ($i -lt $matches.Count - 1) { $matches[$i + 1].Index } else { $sql.Length }
        $body = Normalize-Space $sql.Substring($m.Index + $m.Length, $next - ($m.Index + $m.Length))
        $name = ($m.Value -replace '\s+', ' ').ToUpperInvariant()

        if ($name -eq 'FROM') {
            foreach ($line in @(Format-FromClause -Text $body -Indent $Indent -Depth $Depth)) { $out.Add($line) }
        }
        elseif ($name -eq 'WHERE' -or $name -eq 'HAVING') {
            foreach ($line in @(Format-WhereLikeClause -Text $body -Keyword $name -Indent $Indent -Depth $Depth)) { $out.Add($line) }
        }
        elseif ($name -eq 'GROUP BY' -or $name -eq 'ORDER BY') {
            foreach ($line in @(Format-CommaClause -Text $body -Keyword $name -Indent $Indent)) { $out.Add($line) }
        }
        elseif ($name -match '^WITH\s+(UR|RS|CS|RR|NC)$') {
            $out.Add((' ' * $Indent) + '  ' + $name)
        }
        elseif ($name -match '^FETCH\s+FIRST$') {
            $out.Add((Get-LinePrefixForClause -Clause 'FETCH' -Indent $Indent) + 'FIRST ' + $body)
        }
        elseif ($name -eq 'LIMIT') {
            $out.Add((Get-LinePrefixForClause -Clause 'LIMIT' -Indent $Indent) + $body)
        }
    }

    if (-not $NoSemicolon -and $out.Count -gt 0) {
        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';'
    }
    return $out
}

# ---------------------------------------------------------------------------
# Set operations and CTEs
# ---------------------------------------------------------------------------

function Format-SetQuery {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$Depth = 0
    )

    $sql = Strip-TrailingSemicolon (Normalize-Space $Sql)
    $ops = @(Get-TopLevelMatches -Text $sql -Pattern '\b(UNION\s+ALL|UNION|EXCEPT|INTERSECT)\b')
    if ($ops.Count -eq 0) {
        return @(Format-SelectStatement -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth)
    }

    $out = New-Object System.Collections.Generic.List[string]
    $start = 0
    for ($i = 0; $i -lt $ops.Count; $i++) {
        $part = $sql.Substring($start, $ops[$i].Index - $start).Trim()
        foreach ($line in @(Format-SqlStatement -Statement $part -Indent $Indent -NoSemicolon -Depth $Depth)) { $out.Add($line) }
        $out.Add((' ' * $Indent) + (($ops[$i].Value -replace '\s+', ' ').ToUpperInvariant()))
        $start = $ops[$i].Index + $ops[$i].Length
    }
    $tail = $sql.Substring($start).Trim()
    foreach ($line in @(Format-SqlStatement -Statement $tail -Indent $Indent -NoSemicolon -Depth $Depth)) { $out.Add($line) }

    if (-not $NoSemicolon -and $out.Count -gt 0) {
        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';'
    }
    return $out
}

function Format-WithStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$Depth = 0
    )

    $sql = Strip-TrailingSemicolon (Normalize-Space $Sql)
    $work = $sql.Substring(4).TrimStart()
    $out = New-Object System.Collections.Generic.List[string]
    $cteIndex = 0

    while ($work) {
        $asMatch = Get-FirstTopLevelMatch -Text $work -Pattern '\bAS\s*\('
        if ($null -eq $asMatch) { break }

        $name = Normalize-Space $work.Substring(0, $asMatch.Index)
        if ($name.StartsWith(',')) { $name = $name.Substring(1).Trim() }
        $open = $work.IndexOf('(', $asMatch.Index)
        if ($open -lt 0) { break }
        $close = Find-MatchingParen -Text $work -OpenIndex $open
        if ($close -lt 0) { break }

        $inner = $work.Substring($open + 1, $close - $open - 1).Trim()
        $namePrefix = if ($cteIndex -eq 0) { (' ' * $Indent) + 'WITH ' } else { (' ' * $Indent) + '     ' }
        $out.Add($namePrefix + $name)

        $asPrefix = (' ' * $Indent) + '  AS ( '
        $innerIndent = $asPrefix.Length
        $innerLines = @(Format-SqlStatement -Statement $inner -Indent $innerIndent -NoSemicolon -Depth ($Depth + 1))
        if ($innerLines.Count -gt 0) {
            $out.Add($asPrefix + $innerLines[0].TrimStart())
            for ($i = 1; $i -lt $innerLines.Count; $i++) { $out.Add($innerLines[$i]) }
        }
        else {
            $out.Add($asPrefix.TrimEnd())
        }

        $after = $work.Substring($close + 1).TrimStart()
        if ($after.StartsWith(',')) {
            $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ' ),'
            $work = $after.Substring(1).TrimStart()
            $cteIndex++
            continue
        }

        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ' )'
        $work = $after
        break
    }

    if ($work) {
        foreach ($line in @(Format-SqlStatement -Statement $work -Indent $Indent -NoSemicolon -Depth $Depth)) { $out.Add($line) }
    }

    if (-not $NoSemicolon -and $out.Count -gt 0) {
        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';'
    }
    return $out
}

# ---------------------------------------------------------------------------
# INSERT / UPDATE / DELETE / CREATE TABLE
# ---------------------------------------------------------------------------

function Format-ParenList {
    param(
        [string]$Keyword,
        [string]$Text,
        [string]$Prefix
    )

    $items = @(Split-TopLevelByComma $Text)
    $compact = $Prefix + $Keyword + ' ( ' + ($items -join ', ') + ' )'
    if ($compact.Length -le $script:MaxLineLength) {
        return @($compact)
    }

    $out = New-Object System.Collections.Generic.List[string]
    $first = $Prefix + $Keyword + ' ( '
    $next = ' ' * $first.Length
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { ' )' }
        $out.Add($(if ($i -eq 0) { $first } else { $next }) + $items[$i] + $suffix)
    }
    return $out
}

function Format-InsertStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$Depth = 0
    )

    $sql = Strip-TrailingSemicolon (Normalize-Space $Sql)
    $split = Split-TrailingIsolationClause $sql
    $sql = $split.Sql
    $isolation = $split.Isolation
    $prefix = ' ' * $Indent
    $m = [regex]::Match($sql, '^(?i)INSERT\s+INTO\s+([^\s(]+)\s*(.*)$')
    if (-not $m.Success) {
        return @($prefix + $sql + $(if ($NoSemicolon) { '' } else { ';' }))
    }

    $target = $m.Groups[1].Value
    $rest = $m.Groups[2].Value.Trim()
    $out = New-Object System.Collections.Generic.List[string]

    if ($rest.StartsWith('(')) {
        $close = Find-MatchingParen -Text $rest -OpenIndex 0
        if ($close -gt 0) {
            $columns = $rest.Substring(1, $close - 1)
            $afterCols = $rest.Substring($close + 1).TrimStart()
            foreach ($line in @(Format-ParenList -Keyword ('INSERT INTO ' + $target) -Text $columns -Prefix $prefix)) { $out.Add($line) }

            if ($afterCols -match '^(?i)VALUES\s*\(') {
                $open = $afterCols.IndexOf('(')
                $vclose = Find-MatchingParen -Text $afterCols -OpenIndex $open
                if ($vclose -gt $open) {
                    $values = $afterCols.Substring($open + 1, $vclose - $open - 1)
                    foreach ($line in @(Format-ParenList -Keyword 'VALUES' -Text $values -Prefix $prefix)) { $out.Add($line) }
                    $tail = Normalize-Space $afterCols.Substring($vclose + 1)
                    if ($tail) { $out.Add($prefix + $tail) }
                }
            }
            elseif ($afterCols -match '^(?i)(SELECT|WITH)\b') {
                foreach ($line in @(Format-SqlStatement -Statement $afterCols -Indent $Indent -NoSemicolon -Depth ($Depth + 1))) { $out.Add($line) }
            }
            elseif ($afterCols) {
                $out.Add($prefix + $afterCols)
            }
        }
    }
    elseif ($rest -match '^(?i)(SELECT|WITH)\b') {
        $out.Add($prefix + 'INSERT INTO ' + $target)
        foreach ($line in @(Format-SqlStatement -Statement $rest -Indent $Indent -NoSemicolon -Depth ($Depth + 1))) { $out.Add($line) }
    }
    else {
        $out.Add($prefix + 'INSERT INTO ' + $target + ' ' + $rest)
    }

    if ($out.Count -eq 0) { $out.Add($prefix + $sql) }
    if ($isolation) { $out.Add($prefix + '  ' + $isolation) }
    if (-not $NoSemicolon) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
    return $out
}

function Format-UpdateStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$Depth = 0
    )

    $sql = Strip-TrailingSemicolon (Normalize-Space $Sql)
    $split = Split-TrailingIsolationClause $sql
    $sql = $split.Sql
    $isolation = $split.Isolation
    $prefix = ' ' * $Indent
    $setMatch = Get-FirstTopLevelMatch -Text $sql -Pattern '\bSET\b'
    if ($null -eq $setMatch) { return @($prefix + $sql + $(if ($NoSemicolon) { '' } else { ';' })) }
    $whereMatch = Get-FirstTopLevelMatch -Text $sql -Pattern '\bWHERE\b'

    $head = Normalize-Space $sql.Substring(0, $setMatch.Index)
    $setEnd = if ($null -ne $whereMatch) { $whereMatch.Index } else { $sql.Length }
    $setText = Normalize-Space $sql.Substring($setMatch.Index + $setMatch.Length, $setEnd - ($setMatch.Index + $setMatch.Length))
    $items = @(Split-TopLevelByComma $setText)

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($prefix + $head)
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $out.Add($prefix + $(if ($i -eq 0) { '   SET ' } else { '       ' }) + $items[$i] + $suffix)
    }

    if ($null -ne $whereMatch) {
        $whereText = $sql.Substring($whereMatch.Index + $whereMatch.Length)
        foreach ($line in @(Format-WhereLikeClause -Text $whereText -Keyword 'WHERE' -Indent $Indent -Depth $Depth)) { $out.Add($line) }
    }
    if ($isolation) { $out.Add($prefix + '  ' + $isolation) }
    if (-not $NoSemicolon) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
    return $out
}

function Format-DeleteStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$Depth = 0
    )

    $sql = Strip-TrailingSemicolon (Normalize-Space $Sql)
    $split = Split-TrailingIsolationClause $sql
    $sql = $split.Sql
    $isolation = $split.Isolation
    $prefix = ' ' * $Indent
    $whereMatch = Get-FirstTopLevelMatch -Text $sql -Pattern '\bWHERE\b'
    if ($null -eq $whereMatch) { return @($prefix + $sql + $(if ($NoSemicolon) { '' } else { ';' })) }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($prefix + (Normalize-Space $sql.Substring(0, $whereMatch.Index)))
    $whereText = $sql.Substring($whereMatch.Index + $whereMatch.Length)
    foreach ($line in @(Format-WhereLikeClause -Text $whereText -Keyword 'WHERE' -Indent $Indent -Depth $Depth)) { $out.Add($line) }
    if ($isolation) { $out.Add($prefix + '  ' + $isolation) }
    if (-not $NoSemicolon) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
    return $out
}

function Format-CreateTableStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$Depth = 0
    )

    $sql = Strip-TrailingSemicolon (Normalize-Space $Sql)
    $prefix = ' ' * $Indent

    # CREATE TABLE ... AS ( SELECT ... ) WITH [NO] DATA
    $as = [regex]::Match($sql, '^(?i)(CREATE\s+TABLE\s+.+?\s+AS)\s*\(')
    if ($as.Success) {
        $open = $sql.IndexOf('(', $as.Index + $as.Length - 1)
        $close = Find-MatchingParen -Text $sql -OpenIndex $open
        if ($close -gt $open) {
            $head = Normalize-Space $as.Groups[1].Value
            $inner = $sql.Substring($open + 1, $close - $open - 1).Trim()
            $tail = Normalize-Space $sql.Substring($close + 1)
            $out = New-Object System.Collections.Generic.List[string]
            $out.Add($prefix + $head + ' (')
            foreach ($line in @(Format-SqlStatement -Statement $inner -Indent ($Indent + $script:IndentSize) -NoSemicolon -Depth ($Depth + 1))) { $out.Add($line) }
            $out.Add($prefix + ')')
            if ($tail) { $out.Add($prefix + $tail) }
            if (-not $NoSemicolon) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
            return $out
        }
    }

    $open = $sql.IndexOf('(')
    if ($open -lt 0) { return @($prefix + $sql + $(if ($NoSemicolon) { '' } else { ';' })) }
    $close = Find-MatchingParen -Text $sql -OpenIndex $open
    if ($close -lt 0) { return @($prefix + $sql + $(if ($NoSemicolon) { '' } else { ';' })) }

    $head = Normalize-Space $sql.Substring(0, $open)
    $body = $sql.Substring($open + 1, $close - $open - 1)
    $tail = Normalize-Space $sql.Substring($close + 1)
    $items = @(Split-TopLevelByComma $body)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($prefix + $head + ' (')
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $out.Add($prefix + (' ' * $script:IndentSize) + $items[$i] + $suffix)
    }
    $out.Add($prefix + ')' + $(if ($tail) { ' ' + $tail } else { '' }))
    if (-not $NoSemicolon) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
    return $out
}

# ---------------------------------------------------------------------------
# SQL PL fallback
# ---------------------------------------------------------------------------

function Format-SqlPlRoutine {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon
    )

    # Preserve statement boundaries inside routines. Only normalize indentation
    # around BEGIN/END and leave individual SQL PL statements semantically intact.
    $rawLines = ($Sql -replace "`r`n", "`n" -replace "`r", "`n") -split "`n"
    $out = New-Object System.Collections.Generic.List[string]
    $level = $Indent

    foreach ($raw in $rawLines) {
        $line = $raw.Trim()
        if (-not $line) { continue }

        if ($line -match '^(?i)(END\b|ELSE\b|ELSEIF\b)') {
            $level = [Math]::Max($Indent, $level - $script:IndentSize)
        }

        $out.Add((' ' * $level) + (Convert-SqlKeywords $line))

        if ($line -match '(?i)\bBEGIN\b\s*;?$' -or $line -match '^(?i)(IF\b.*\bTHEN\b|ELSE\b|ELSEIF\b.*\bTHEN\b|LOOP\b)') {
            $level += $script:IndentSize
        }
    }

    if (-not $NoSemicolon -and $out.Count -gt 0 -and $out[$out.Count - 1] -notmatch ';\s*$') {
        $out[$out.Count - 1] += ';'
    }
    return $out
}

# ---------------------------------------------------------------------------
# Dispatcher / stdin -> stdout
# ---------------------------------------------------------------------------

function Format-SqlStatement {
    param(
        [string]$Statement,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$Depth = 0
    )

    $sql = Normalize-Space $Statement
    if (-not $sql) { return @() }

    if ($sql -match '^(?i)WITH\b') {
        return @(Format-WithStatement -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth)
    }
    if (@(Get-TopLevelMatches -Text $sql -Pattern '\b(UNION\s+ALL|UNION|EXCEPT|INTERSECT)\b').Count -gt 0) {
        return @(Format-SetQuery -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth)
    }
    if ($sql -match '^(?i)SELECT\b') {
        return @(Format-SelectStatement -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth)
    }
    if ($sql -match '^(?i)INSERT\b') {
        return @(Format-InsertStatement -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth)
    }
    if ($sql -match '^(?i)UPDATE\b') {
        return @(Format-UpdateStatement -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth)
    }
    if ($sql -match '^(?i)DELETE\b') {
        return @(Format-DeleteStatement -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth)
    }
    if ($sql -match '^(?i)CREATE\s+TABLE\b') {
        return @(Format-CreateTableStatement -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth)
    }

    return @((' ' * $Indent) + (Strip-TrailingSemicolon $sql) + $(if ($NoSemicolon) { '' } else { ';' }))
}

function Split-TopLevelStatements {
    param([string]$Sql)

    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0
    for ($i = 0; $i -lt $Sql.Length; $i++) {
        if ($Sql[$i] -eq '(') { $depth++ }
        elseif ($Sql[$i] -eq ')' -and $depth -gt 0) { $depth-- }
        elseif ($Sql[$i] -eq ';' -and $depth -eq 0) {
            $piece = $Sql.Substring($start, $i - $start).Trim()
            if ($piece) { $items.Add($piece) }
            $start = $i + 1
        }
    }
    $tail = $Sql.Substring($start).Trim()
    if ($tail) { $items.Add($tail) }
    return $items
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) {
    exit 0
}

$protected = Protect-SqlText $inputSql
$protected = Convert-SqlKeywords $protected

# Routines contain internal semicolons; keep them as one unit.
if ((Normalize-Space $protected) -match '^(?i)CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b') {
    $formattedLines = @(Format-SqlPlRoutine -Sql $protected)
    $formatted = $formattedLines -join [Environment]::NewLine
}
else {
    $statements = @(Split-TopLevelStatements $protected)
    $blocks = New-Object System.Collections.Generic.List[string]
    foreach ($statement in $statements) {
        $lines = @(Format-SqlStatement -Statement $statement)
        if ($lines.Count -gt 0) {
            $blocks.Add(($lines -join [Environment]::NewLine))
        }
    }
    $formatted = $blocks -join ([Environment]::NewLine + [Environment]::NewLine)
}

$formatted = Restore-SqlText $formatted
$formatted = $formatted.TrimEnd()
[Console]::Out.Write($formatted)
