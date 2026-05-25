<#
    DB2 SQL Formatter - recursive rewrite v2
    ------------------------------------------------------------
    Reads SQL from stdin and writes formatted SQL to stdout.

    This formatter is heuristic, not a full DB2 parser.
    It is designed around one central idea:
      - Format SELECT consistently.
      - Reuse SELECT formatting inside CTEs, subqueries, MERGE, CREATE VIEW, cursors, procedures, and functions.
#>

$ErrorActionPreference = "Stop"

$script:ProtectedMap = @{}
$script:ProtectedIndex = 0

function New-ProtectedToken {
    param([string]$Prefix, [string]$Value)

    $script:ProtectedIndex++
    $token = "__SQLFMT_${Prefix}_$script:ProtectedIndex`__"
    $script:ProtectedMap[$token] = $Value
    return $token
}

function Protect-SqlLiteralsAndComments {
    param([string]$Sql)

    $script:ProtectedMap = @{}
    $script:ProtectedIndex = 0

    $Sql = [regex]::Replace($Sql, '/\*[\s\S]*?\*/', { param($m) New-ProtectedToken -Prefix "BCOM" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, "'(?:''|[^'])*'", { param($m) New-ProtectedToken -Prefix "STR" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '"(?:""|[^"])*"', { param($m) New-ProtectedToken -Prefix "DQS" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '--[^\r\n]*', { param($m) New-ProtectedToken -Prefix "LCOM" -Value $m.Value })

    return $Sql
}

function Restore-ProtectedTokens {
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
    $Text = $Text -replace '\s+\)', ')'
    $Text = $Text -replace '\(\s+', '('
    $Text = $Text -replace '\s+;', ';'
    return $Text.Trim()
}

function Convert-SqlKeywordsToUpper {
    param([string]$Sql)

    $keywords = @(
        'select', 'from', 'where', 'and', 'or', 'not', 'null', 'is', 'in', 'exists', 'between', 'like',
        'inner', 'left', 'right', 'full', 'cross', 'outer', 'join', 'on', 'group', 'by', 'having', 'order',
        'asc', 'desc', 'fetch', 'first', 'rows', 'only', 'limit', 'offset', 'with', 'ur', 'rs', 'cs', 'rr', 'nc',
        'union', 'all', 'except', 'intersect', 'case', 'when', 'then', 'else', 'end', 'as', 'over', 'partition',
        'insert', 'into', 'values', 'update', 'set', 'delete', 'merge', 'using', 'matched', 'then',
        'create', 'replace', 'procedure', 'function', 'returns', 'language', 'sql', 'begin', 'atomic',
        'declare', 'cursor', 'for', 'continue', 'handler', 'open', 'fetch', 'close', 'loop', 'leave', 'if',
        'signal', 'sqlstate', 'message_text', 'prepare', 'execute', 'table', 'view', 'index', 'schema',
        'constraint', 'primary', 'key', 'foreign', 'references', 'check', 'default', 'temporary', 'global',
        'session', 'commit', 'preserve', 'logged', 'alter', 'add', 'column', 'data', 'type', 'optimize',
        'deterministic', 'external', 'action'
    )

    foreach ($kw in $keywords) {
        $escaped = [regex]::Escape($kw)
        $Sql = [regex]::Replace(
            $Sql,
            "(?i)(?<![A-Z0-9_])$escaped(?![A-Z0-9_])",
            { param($m) $m.Value.ToUpperInvariant() }
        )
    }

    return $Sql
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

function Get-TopLevelMatches {
    param([string]$Text, [string]$Pattern)

    $matches = New-Object System.Collections.Generic.List[object]
    $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($m in $rx.Matches($Text)) {
        if ((Get-ParenDepthAt -Text $Text -Index $m.Index) -eq 0) {
            $matches.Add($m)
        }
    }

    return $matches
}

function Get-FirstTopLevelMatch {
    param([string]$Text, [string]$Pattern)

    $matches = Get-TopLevelMatches -Text $Text -Pattern $Pattern
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Split-TopLevelByComma {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]

        if ($ch -eq '(') {
            $depth++
        }
        elseif ($ch -eq ')') {
            if ($depth -gt 0) { $depth-- }
        }
        elseif ($ch -eq ',' -and $depth -eq 0) {
            $items.Add((Normalize-Space $Text.Substring($start, $i - $start)))
            $start = $i + 1
        }
    }

    $last = Normalize-Space $Text.Substring($start)
    if ($last.Length -gt 0) { $items.Add($last) }

    return $items
}

function Split-TopLevelLogical {
    param([string]$Text)

    $parts = New-Object System.Collections.Generic.List[string]
    $matches = Get-TopLevelMatches -Text $Text -Pattern '\b(AND|OR)\b'

    if ($matches.Count -eq 0) {
        $parts.Add((Normalize-Space $Text))
        return $parts
    }

    $start = 0

    foreach ($m in $matches) {
        if ($m.Index -gt $start) {
            $segment = Normalize-Space $Text.Substring($start, $m.Index - $start)
            if ($segment.Length -gt 0) { $parts.Add($segment) }
        }

        $start = $m.Index
    }

    $tail = Normalize-Space $Text.Substring($start)
    if ($tail.Length -gt 0) { $parts.Add($tail) }

    return $parts
}

function Add-IndentedLines {
    param(
        [System.Collections.Generic.List[string]]$Out,
        [string[]]$Lines,
        [int]$Indent
    )

    $prefix = ' ' * $Indent

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $Out.Add("")
        }
        else {
            $Out.Add($prefix + $line.TrimEnd())
        }
    }
}

function Strip-TrailingSemicolon {
    param([string]$Text)

    return ($Text.Trim() -replace ';\s*$', '')
}

function Remove-LeadingProtectedCommentsForDetection {
    param([string]$Text)

    $work = $Text.Trim()

    # The statement may begin with several protected comments separated by newlines.
    # Use Singleline behavior so the remaining SQL after the comment block is preserved.
    while ([regex]::IsMatch($work, '^\s*__SQLFMT_(LCOM|BCOM)_\d+__\s*', [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $work = [regex]::Replace(
            $work,
            '^\s*__SQLFMT_(LCOM|BCOM)_\d+__\s*',
            '',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        ).Trim()
    }

    return $work
}


function Test-RoutineStatementComplete {
    param([string]$Text)

    $work = (Remove-LeadingProtectedCommentsForDetection $Text).ToUpperInvariant()

    if ($work -notmatch '^\s*CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b') {
        return $false
    }

    $tokens = [regex]::Matches(
        $work,
        '\bBEGIN\s+ATOMIC\b|\bBEGIN\b|\bCASE\b|\bLOOP\b|\bIF\b|\bEND\s+IF\b|\bEND\s+LOOP\b|\bEND\b',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $depth = 0

    foreach ($tokenMatch in $tokens) {
        $token = $tokenMatch.Value.ToUpperInvariant() -replace '\s+', ' '

        switch -Regex ($token) {
            '^BEGIN' {
                $depth++
                break
            }
            '^CASE$' {
                $depth++
                break
            }
            '^LOOP$' {
                $depth++
                break
            }
            '^IF$' {
                $depth++
                break
            }
            '^END IF$' {
                if ($depth -gt 0) { $depth-- }
                break
            }
            '^END LOOP$' {
                if ($depth -gt 0) { $depth-- }
                break
            }
            '^END$' {
                if ($depth -gt 0) { $depth-- }
                break
            }
        }
    }

    return ($depth -eq 0 -and $work -match '\bEND\s*$')
}

function Split-SqlStatements {
    param([string]$Sql)

    $statements = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0
    $insideRoutine = $false

    for ($i = 0; $i -lt $Sql.Length; $i++) {
        $ch = $Sql[$i]

        if ($ch -eq '(') {
            $depth++
        }
        elseif ($ch -eq ')') {
            if ($depth -gt 0) { $depth-- }
        }
        elseif ($ch -eq ';' -and $depth -eq 0) {
            $candidate = $Sql.Substring($start, $i - $start).Trim()

            if ($candidate.Length -gt 0) {
                $detect = Remove-LeadingProtectedCommentsForDetection $candidate

                if (-not $insideRoutine -and $detect -match '^\s*CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b') {
                    $insideRoutine = $true
                }

                if ($insideRoutine) {
                    # DB2 SQL PL routines contain many semicolons inside BEGIN/END.
                    # Keep collecting until the real routine-level END; is reached.
                    # A CASE expression also ends with END, so a simple "\bEND$" check
                    # incorrectly stops at RETURN CASE ... END; inside functions.
                    if (-not (Test-RoutineStatementComplete $candidate)) {
                        continue
                    }

                    $statements.Add($candidate + ';')
                    $insideRoutine = $false
                }
                else {
                    $statements.Add($candidate + ';')
                }
            }

            $start = $i + 1
        }
    }

    $tail = $Sql.Substring($start).Trim()
    if ($tail.Length -gt 0) {
        $statements.Add($tail)
    }

    return $statements
}

function Format-CommaList {
    param([string]$Text, [string]$FirstPrefix, [string]$NextPrefix)

    $out = New-Object System.Collections.Generic.List[string]
    $items = @(Split-TopLevelByComma $Text)

    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { "," } else { "" }

        if ($i -eq 0) {
            $out.Add($FirstPrefix + $items[$i] + $suffix)
        }
        else {
            $out.Add($NextPrefix + $items[$i] + $suffix)
        }
    }

    return $out
}

function Format-CaseExpression {
    param([string]$Item, [string]$FirstPrefix, [string]$NextPrefix)

    $out = New-Object System.Collections.Generic.List[string]
    $item = Normalize-Space $Item

    if ($item -notmatch '^\s*CASE\b') {
        $out.Add($FirstPrefix + $item)
        return $out
    }

    $alias = ""
    $caseBody = $item

    $aliasMatch = [regex]::Match($item, '\bEND\s+AS\s+([A-Z0-9_]+)\s*$', 'IgnoreCase')
    if ($aliasMatch.Success) {
        $alias = " AS " + $aliasMatch.Groups[1].Value
        $caseBody = $item.Substring(0, $aliasMatch.Index + 3).Trim()
    }

    $out.Add($FirstPrefix + "CASE")

    $work = $caseBody -replace '^\s*CASE\s+', ''
    $work = $work -replace '\s*END\s*$', ''

    $tokens = [regex]::Matches($work, '\bWHEN\b|\bELSE\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($tokens.Count -eq 0) {
        $out[$out.Count - 1] = $FirstPrefix + $item
        return $out
    }

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        $next = if ($i -lt $tokens.Count - 1) { $tokens[$i + 1].Index } else { $work.Length }
        $segment = Normalize-Space $work.Substring($t.Index, $next - $t.Index)
        $out.Add($NextPrefix + "  " + $segment)
    }

    $out.Add($NextPrefix + "END" + $alias)
    return $out
}

function Format-WindowExpression {
    param([string]$Item, [string]$FirstPrefix, [string]$NextPrefix)

    $out = New-Object System.Collections.Generic.List[string]
    $item = Normalize-Space $Item

    if ($item.Length -le 120 -or $item -notmatch '\bOVER\s*\(') {
        $out.Add($FirstPrefix + $item)
        return $out
    }

    $m = [regex]::Match($item, '^(.*?)\s+OVER\s*\((.*)\)(\s+AS\s+[A-Z0-9_]+)?$', 'IgnoreCase')
    if (-not $m.Success) {
        $out.Add($FirstPrefix + $item)
        return $out
    }

    $func = Normalize-Space $m.Groups[1].Value
    $inside = Normalize-Space $m.Groups[2].Value
    $alias = $m.Groups[3].Value

    $partitionMatch = [regex]::Match($inside, '^(PARTITION\s+BY\s+.*?)(\s+ORDER\s+BY\s+.*)?$', 'IgnoreCase')

    $out.Add($FirstPrefix + $func)
    if ($partitionMatch.Success) {
        $out.Add($NextPrefix + "      OVER (" + (Normalize-Space $partitionMatch.Groups[1].Value))
        if (-not [string]::IsNullOrWhiteSpace($partitionMatch.Groups[2].Value)) {
            $orderText = Normalize-Space $partitionMatch.Groups[2].Value
            $out.Add($NextPrefix + "              " + $orderText + ")" + $alias)
        }
        else {
            $out.Add($NextPrefix + "      )" + $alias)
        }
    }
    else {
        $out.Add($NextPrefix + "      OVER (" + $inside + ")" + $alias)
    }

    return $out
}

function Format-SelectList {
    param([string]$Text, [int]$Indent)

    $out = New-Object System.Collections.Generic.List[string]
    $items = @(Split-TopLevelByComma $Text)
    $firstPrefix = (' ' * $Indent) + "SELECT "
    $nextPrefix = (' ' * $Indent) + "       "

    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { "," } else { "" }
        $prefix = if ($i -eq 0) { $firstPrefix } else { $nextPrefix }
        $item = $items[$i]

        if ($item -match '^\s*CASE\b') {
            $caseLines = @(Format-CaseExpression -Item $item -FirstPrefix $prefix -NextPrefix $nextPrefix)
            for ($j = 0; $j -lt $caseLines.Count; $j++) {
                if ($j -eq $caseLines.Count - 1) {
                    $out.Add($caseLines[$j] + $suffix)
                }
                else {
                    $out.Add($caseLines[$j])
                }
            }
        }
        elseif ($item -match '\bOVER\s*\(' -and $item.Length -gt 120) {
            $winLines = @(Format-WindowExpression -Item $item -FirstPrefix $prefix -NextPrefix $nextPrefix)
            for ($j = 0; $j -lt $winLines.Count; $j++) {
                if ($j -eq $winLines.Count - 1) {
                    $out.Add($winLines[$j] + $suffix)
                }
                else {
                    $out.Add($winLines[$j])
                }
            }
        }
        else {
            $out.Add($prefix + $item + $suffix)
        }
    }

    return $out
}

function Has-TopLevelSetOperator {
    param([string]$Sql)

    return (Get-TopLevelMatches -Text $Sql -Pattern '\b(UNION\s+ALL|UNION|EXCEPT|INTERSECT)\b').Count -gt 0
}

function Format-SetQuery {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon)

    $out = New-Object System.Collections.Generic.List[string]
    $matches = @(Get-TopLevelMatches -Text $Sql -Pattern '\b(UNION\s+ALL|UNION|EXCEPT|INTERSECT)\b')
    $start = 0

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $m = $matches[$i]
        $part = $Sql.Substring($start, $m.Index - $start).Trim()

        if ($part.Length -gt 0) {
            Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $part -Indent $Indent -NoSemicolon) -Indent 0
        }

        $out.Add((' ' * $Indent) + $m.Value.ToUpperInvariant())
        $start = $m.Index + $m.Length
    }

    $tail = $Sql.Substring($start).Trim()
    if ($tail.Length -gt 0) {
        Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $tail -Indent $Indent -NoSemicolon:$NoSemicolon) -Indent 0
    }

    return $out
}

function Get-SelectClauses {
    param([string]$Sql)

    $clausePattern = '\bFROM\b|\bWHERE\b|\bGROUP\s+BY\b|\bHAVING\b|\bORDER\s+BY\b|\bFETCH\s+FIRST\b|\bLIMIT\b|\bOPTIMIZE\s+FOR\b|\bFOR\s+UPDATE\b|\bWITH\s+(UR|RS|CS|RR|NC)\b'
    $matches = @(Get-TopLevelMatches -Text $Sql -Pattern $clausePattern)
    $clauses = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $m = $matches[$i]
        $nextIndex = if ($i -lt $matches.Count - 1) { $matches[$i + 1].Index } else { $Sql.Length }

        $clauses.Add([pscustomobject]@{
                Name   = $m.Value.ToUpperInvariant()
                Index  = $m.Index
                Length = $m.Length
                Text   = $Sql.Substring($m.Index + $m.Length, $nextIndex - ($m.Index + $m.Length)).Trim()
            })
    }

    return $clauses
}

function Format-FromClause {
    param([string]$Text, [int]$Indent)

    $out = New-Object System.Collections.Generic.List[string]
    $prefix = ' ' * $Indent
    $joinPattern = '\b(INNER\s+JOIN|LEFT\s+JOIN|LEFT\s+OUTER\s+JOIN|RIGHT\s+JOIN|RIGHT\s+OUTER\s+JOIN|FULL\s+JOIN|FULL\s+OUTER\s+JOIN|CROSS\s+JOIN|JOIN)\b'
    $matches = @(Get-TopLevelMatches -Text $Text -Pattern $joinPattern)

    if ($matches.Count -eq 0) {
        $out.Add($prefix + "  FROM " + (Normalize-Space $Text))
        return $out
    }

    $first = $Text.Substring(0, $matches[0].Index).Trim()
    $out.Add($prefix + "  FROM " + (Normalize-Space $first))

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $m = $matches[$i]
        $next = if ($i -lt $matches.Count - 1) { $matches[$i + 1].Index } else { $Text.Length }
        $joinText = Normalize-Space $Text.Substring($m.Index, $next - $m.Index)
        $out.Add($prefix + " " + $joinText)
    }

    return $out
}

function Format-WhereClause {
    param([string]$Text, [string]$Keyword, [int]$Indent)

    $out = New-Object System.Collections.Generic.List[string]
    $prefix = ' ' * $Indent
    $parts = @(Split-TopLevelLogical $Text)

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $part = Normalize-Space $parts[$i]

        if ($i -eq 0) {
            $out.Add($prefix + $Keyword + " " + $part)
        }
        elseif ($part -match '^(AND|OR)\b') {
            $out.Add($prefix + "   " + $part)
        }
        else {
            $out.Add($prefix + "   AND " + $part)
        }
    }

    return $out
}

function Format-SelectStatement {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)

    if (Has-TopLevelSetOperator $Sql) {
        return Format-SetQuery -Sql $Sql -Indent $Indent -NoSemicolon:$NoSemicolon
    }

    $out = New-Object System.Collections.Generic.List[string]
    $prefix = ' ' * $Indent

    if ($Sql -notmatch '^\s*SELECT\b') {
        $out.Add($prefix + $Sql)
        return $out
    }

    $clauses = @(Get-SelectClauses $Sql)

    if ($clauses.Count -eq 0) {
        $selectList = $Sql -replace '^\s*SELECT\s+', ''
        Add-IndentedLines -Out $out -Lines @(Format-SelectList -Text $selectList -Indent $Indent) -Indent 0
        return $out
    }

    $firstClause = $clauses[0]
    $selectList = $Sql.Substring(6, $firstClause.Index - 6).Trim()

    Add-IndentedLines -Out $out -Lines @(Format-SelectList -Text $selectList -Indent $Indent) -Indent 0

    foreach ($clause in $clauses) {
        $name = $clause.Name
        $text = $clause.Text

        if ($name -eq 'FROM') {
            Add-IndentedLines -Out $out -Lines @(Format-FromClause -Text $text -Indent $Indent) -Indent 0
        }
        elseif ($name -eq 'WHERE') {
            Add-IndentedLines -Out $out -Lines @(Format-WhereClause -Text $text -Keyword " WHERE" -Indent $Indent) -Indent 0
        }
        elseif ($name -eq 'GROUP BY') {
            $out.Add($prefix + " GROUP BY " + (Normalize-Space $text))
        }
        elseif ($name -eq 'HAVING') {
            $out.Add($prefix + "HAVING " + (Normalize-Space $text))
        }
        elseif ($name -eq 'ORDER BY') {
            $out.Add($prefix + " ORDER BY " + (Normalize-Space $text))
        }
        elseif ($name -eq 'FETCH FIRST') {
            $out.Add($prefix + " FETCH FIRST " + (Normalize-Space $text))
        }
        elseif ($name -eq 'OPTIMIZE FOR') {
            $out.Add($prefix + " OPTIMIZE FOR " + (Normalize-Space $text))
        }
        elseif ($name -eq 'FOR UPDATE') {
            $out.Add($prefix + " FOR UPDATE " + (Normalize-Space $text))
        }
        elseif ($name -match '^WITH\s+') {
            $out.Add($prefix + "  " + $name)
        }
        else {
            $out.Add($prefix + $name + " " + (Normalize-Space $text))
        }
    }

    return $out
}

function Format-WithStatement {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]

    $body = $Sql -replace '^\s*WITH\s+', ''
    $pos = 0
    $cteIndex = 0

    while ($pos -lt $body.Length) {
        $remaining = $body.Substring($pos)

        $m = [regex]::Match(
            $remaining,
            '^\s*([A-Z0-9_]+(?:\s*\([^)]*\))?)\s+AS\s*\(',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $m.Success) { break }

        $cteName = Normalize-Space $m.Groups[1].Value
        $openIndex = $pos + $m.Index + $m.Length - 1
        $closeIndex = Find-MatchingParen -Text $body -OpenIndex $openIndex
        if ($closeIndex -lt 0) { break }

        $inner = $body.Substring($openIndex + 1, $closeIndex - $openIndex - 1).Trim()
        $innerLines = @(Format-SqlStatement -Statement $inner -Indent ($Indent + 5) -NoSemicolon)

        if ($cteIndex -eq 0) {
            $out.Add($prefix + "WITH " + $cteName)
        }
        else {
            $out.Add($prefix + "   , " + $cteName)
        }

        if ($innerLines.Count -gt 0) {
            $out.Add($prefix + "  AS ( " + $innerLines[0].Trim())
            for ($i = 1; $i -lt $innerLines.Count; $i++) {
                $out.Add($innerLines[$i])
            }
        }
        else {
            $out.Add($prefix + "  AS (")
        }

        $pos = $closeIndex + 1
        while ($pos -lt $body.Length -and [char]::IsWhiteSpace($body[$pos])) { $pos++ }

        if ($pos -lt $body.Length -and $body[$pos] -eq ',') {
            $out.Add($prefix + "     ),")
            $pos++
        }
        else {
            $out.Add($prefix + "     )")
            break
        }

        $cteIndex++
    }

    $rest = $body.Substring($pos).Trim()

    if ($out.Count -eq 0) {
        $out.Add($prefix + $Sql)
        return $out
    }

    if ($rest.Length -gt 0) {
        Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $rest -Indent $Indent -NoSemicolon) -Indent 0
    }

    return $out
}

function Format-InsertStatement {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $selectMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bSELECT\b'
    $valuesMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bVALUES\b'

    if ($null -ne $selectMatch) {
        $head = $Sql.Substring(0, $selectMatch.Index).Trim()
        $select = $Sql.Substring($selectMatch.Index).Trim()
        $open = $head.IndexOf('(')
        $close = if ($open -ge 0) { Find-MatchingParen -Text $head -OpenIndex $open } else { -1 }

        if ($open -ge 0 -and $close -gt $open) {
            $before = Normalize-Space $head.Substring(0, $open)
            $cols = $head.Substring($open + 1, $close - $open - 1)
            $out.Add($prefix + $before + " (")
            Add-IndentedLines -Out $out -Lines @(Format-CommaList -Text $cols -FirstPrefix ($prefix + "    ") -NextPrefix ($prefix + "    ")) -Indent 0
            $out.Add($prefix + ")")
        }
        else {
            $out.Add($prefix + $head)
        }

        Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $select -Indent $Indent -NoSemicolon) -Indent 0
        return $out
    }

    if ($null -ne $valuesMatch) {
        $head = $Sql.Substring(0, $valuesMatch.Index).Trim()
        $values = $Sql.Substring($valuesMatch.Index + $valuesMatch.Length).Trim()
        $open = $head.IndexOf('(')
        $close = if ($open -ge 0) { Find-MatchingParen -Text $head -OpenIndex $open } else { -1 }

        if ($open -ge 0 -and $close -gt $open) {
            $before = Normalize-Space $head.Substring(0, $open)
            $cols = $head.Substring($open + 1, $close - $open - 1)
            $out.Add($prefix + $before + " (")
            Add-IndentedLines -Out $out -Lines @(Format-CommaList -Text $cols -FirstPrefix ($prefix + "    ") -NextPrefix ($prefix + "    ")) -Indent 0
            $out.Add($prefix + ")")
        }
        else {
            $out.Add($prefix + $head)
        }

        if ($values.StartsWith("(")) {
            $end = Find-MatchingParen -Text $values -OpenIndex 0
            if ($end -gt 0) {
                $valText = $values.Substring(1, $end - 1)
                $out.Add($prefix + "VALUES (")
                Add-IndentedLines -Out $out -Lines @(Format-CommaList -Text $valText -FirstPrefix ($prefix + "    ") -NextPrefix ($prefix + "    ")) -Indent 0
                $out.Add($prefix + ")")
                return $out
            }
        }

        $out.Add($prefix + "VALUES " + $values)
        return $out
    }

    $out.Add($prefix + $Sql)
    return $out
}

function Format-UpdateStatement {
    param([string]$Sql, [int]$Indent = 0)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $setMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bSET\b'

    if ($null -eq $setMatch) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $whereMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bWHERE\b'
    $head = Normalize-Space $Sql.Substring(0, $setMatch.Index)
    $setEnd = if ($null -ne $whereMatch) { $whereMatch.Index } else { $Sql.Length }
    $setText = $Sql.Substring($setMatch.Index + $setMatch.Length, $setEnd - ($setMatch.Index + $setMatch.Length)).Trim()
    $whereText = if ($null -ne $whereMatch) { $Sql.Substring($whereMatch.Index + $whereMatch.Length).Trim() } else { "" }

    $out.Add($prefix + $head)
    Add-IndentedLines -Out $out -Lines @(Format-CommaList -Text $setText -FirstPrefix ($prefix + "   SET ") -NextPrefix ($prefix + "       ")) -Indent 0

    if ($whereText.Length -gt 0) {
        Add-IndentedLines -Out $out -Lines @(Format-WhereClause -Text $whereText -Keyword " WHERE" -Indent $Indent) -Indent 0
    }

    return $out
}

function Format-DeleteStatement {
    param([string]$Sql, [int]$Indent = 0)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $whereMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bWHERE\b'

    if ($null -eq $whereMatch) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $head = Normalize-Space $Sql.Substring(0, $whereMatch.Index)
    $where = $Sql.Substring($whereMatch.Index + $whereMatch.Length).Trim()

    $out.Add($prefix + $head)
    Add-IndentedLines -Out $out -Lines @(Format-WhereClause -Text $where -Keyword " WHERE" -Indent $Indent) -Indent 0
    return $out
}


function Format-InlineParenCommaList {
    param(
        [string]$Keyword,
        [string]$Text,
        [string]$Prefix
    )

    $out = New-Object System.Collections.Generic.List[string]
    $items = @(Split-TopLevelByComma $Text)

    if ($items.Count -eq 0) {
        $out.Add($Prefix + $Keyword + "()")
        return $out
    }

    $continuation = ' ' * ($Keyword.Length + 1)

    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { "," } else { ")" }

        if ($i -eq 0) {
            $out.Add($Prefix + $Keyword + "(" + $items[$i] + $suffix)
        }
        else {
            $out.Add($Prefix + $continuation + $items[$i] + $suffix)
        }
    }

    return $out
}

function Format-MergeStatement {
    param([string]$Sql, [int]$Indent = 0)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]

    $usingMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bUSING\b'
    $onMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bON\b'
    $whenMatches = @(Get-TopLevelMatches -Text $Sql -Pattern '\bWHEN\s+(MATCHED|NOT\s+MATCHED)\s+THEN\b')

    if ($null -eq $usingMatch -or $null -eq $onMatch) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $out.Add($prefix + " MERGE " + (Normalize-Space (($Sql.Substring(0, $usingMatch.Index)) -replace '^\s*MERGE\s+', '')))

    $usingBody = $Sql.Substring($usingMatch.Index + $usingMatch.Length, $onMatch.Index - ($usingMatch.Index + $usingMatch.Length)).Trim()

    if ($usingBody.StartsWith("(")) {
        $close = Find-MatchingParen -Text $usingBody -OpenIndex 0
        if ($close -gt 0) {
            $inner = $usingBody.Substring(1, $close - 1).Trim()
            $alias = Normalize-Space $usingBody.Substring($close + 1)
            $innerLines = @(Format-SqlStatement -Statement $inner -Indent ($Indent + 7) -NoSemicolon)

            $out.Add($prefix + " USING ( " + $innerLines[0].Trim())
            for ($i = 1; $i -lt $innerLines.Count; $i++) {
                $out.Add($innerLines[$i])
            }
            $out.Add($prefix + "       ) " + $alias)
        }
        else {
            $out.Add($prefix + " USING " + $usingBody)
        }
    }
    else {
        $out.Add($prefix + " USING " + $usingBody)
    }

    $onEnd = if ($whenMatches.Count -gt 0) { $whenMatches[0].Index } else { $Sql.Length }
    $onText = Normalize-Space $Sql.Substring($onMatch.Index + $onMatch.Length, $onEnd - ($onMatch.Index + $onMatch.Length))
    $out.Add($prefix + "    ON " + $onText)

    for ($i = 0; $i -lt $whenMatches.Count; $i++) {
        $m = $whenMatches[$i]
        $next = if ($i -lt $whenMatches.Count - 1) { $whenMatches[$i + 1].Index } else { $Sql.Length }
        $whenText = Normalize-Space $Sql.Substring($m.Index, $next - $m.Index)

        $updateSet = [regex]::Match($whenText, '^(WHEN\s+MATCHED\s+THEN)\s+UPDATE\s+SET\s+(.+)$', 'IgnoreCase')
        $insertVals = [regex]::Match($whenText, '^(WHEN\s+NOT\s+MATCHED\s+THEN)\s+INSERT\s*\((.+?)\)\s+VALUES\s*\((.+)\)$', 'IgnoreCase')

        if ($updateSet.Success) {
            $out.Add($prefix + "  WHEN MATCHED THEN")
            Add-IndentedLines -Out $out -Lines @(Format-CommaList -Text $updateSet.Groups[2].Value -FirstPrefix ($prefix + "UPDATE SET ") -NextPrefix ($prefix + "       SET ")) -Indent 0
        }
        elseif ($insertVals.Success) {
            $out.Add($prefix + "  WHEN NOT MATCHED THEN")

            Add-IndentedLines -Out $out -Lines @(
                Format-InlineParenCommaList -Keyword "INSERT " -Text $insertVals.Groups[2].Value -Prefix $prefix
            ) -Indent 0

            Add-IndentedLines -Out $out -Lines @(
                Format-InlineParenCommaList -Keyword "VALUES " -Text $insertVals.Groups[3].Value -Prefix $prefix
            ) -Indent 0
        }
        else {
            $out.Add($prefix + "  " + $whenText)
        }
    }

    return $out
}

function Format-CreateTableStatement {
    param([string]$Sql, [int]$Indent = 0)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $open = $Sql.IndexOf('(')

    if ($open -lt 0) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $close = Find-MatchingParen -Text $Sql -OpenIndex $open
    if ($close -lt 0) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $head = Normalize-Space $Sql.Substring(0, $open)
    $body = $Sql.Substring($open + 1, $close - $open - 1)
    $tail = Normalize-Space $Sql.Substring($close + 1)

    $out.Add($prefix + $head + " (")
    Add-IndentedLines -Out $out -Lines @(Format-CommaList -Text $body -FirstPrefix ($prefix + "    ") -NextPrefix ($prefix + "    ")) -Indent 0
    $out.Add($prefix + ")" + $(if ($tail.Length -gt 0) { " " + $tail } else { "" }))
    return $out
}

function Format-CreateIndexStatement {
    param([string]$Sql, [int]$Indent = 0)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $onMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bON\b'

    if ($null -eq $onMatch) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $head = Normalize-Space $Sql.Substring(0, $onMatch.Index)
    $tail = Normalize-Space $Sql.Substring($onMatch.Index)

    $out.Add($prefix + $head)

    if (($prefix + "    " + $tail).Length -le 120) {
        $out.Add($prefix + "    " + $tail)
        return $out
    }

    $open = $tail.IndexOf('(')
    $close = if ($open -ge 0) { Find-MatchingParen -Text $tail -OpenIndex $open } else { -1 }

    if ($open -ge 0 -and $close -gt $open) {
        $before = Normalize-Space $tail.Substring(0, $open)
        $cols = $tail.Substring($open + 1, $close - $open - 1)
        $out.Add($prefix + "    " + $before + " (")
        Add-IndentedLines -Out $out -Lines @(Format-CommaList -Text $cols -FirstPrefix ($prefix + "        ") -NextPrefix ($prefix + "        ")) -Indent 0
        $out.Add($prefix + "    )")
    }
    else {
        $out.Add($prefix + "    " + $tail)
    }

    return $out
}

function Format-CreateViewStatement {
    param([string]$Sql, [int]$Indent = 0)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $asMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bAS\s+SELECT\b'

    if ($null -eq $asMatch) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $head = Normalize-Space $Sql.Substring(0, $asMatch.Index)
    $select = $Sql.Substring($asMatch.Index + 3).Trim()

    $out.Add($prefix + $head + " AS")
    Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $select -Indent ($Indent + 2) -NoSemicolon) -Indent 0
    return $out
}

function Format-AlterTableStatement {
    param([string]$Sql, [int]$Indent = 0)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent

    if (($prefix + $Sql).Length -le 120) {
        return @($prefix + $Sql)
    }

    return @(Format-GenericStatement -Sql $Sql -Indent $Indent)
}

function Format-RoutineStatement {
    param([string]$Sql, [int]$Indent = 0)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]

    $beginMatch = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bBEGIN(\s+ATOMIC)?\b'
    if ($null -eq $beginMatch) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $header = Normalize-Space $Sql.Substring(0, $beginMatch.Index)
    $beginToken = Normalize-Space $beginMatch.Value
    $body = Normalize-Space $Sql.Substring($beginMatch.Index + $beginMatch.Length)
    $body = $body -replace '\bEND\s*$', ''

    $open = $header.IndexOf('(')
    $close = if ($open -ge 0) { Find-MatchingParen -Text $header -OpenIndex $open } else { -1 }

    if ($open -ge 0 -and $close -gt $open) {
        $before = Normalize-Space $header.Substring(0, $open)
        $params = $header.Substring($open + 1, $close - $open - 1)
        $after = Normalize-Space $header.Substring($close + 1)

        $out.Add($prefix + $before + " (")
        Add-IndentedLines -Out $out -Lines @(Format-CommaList -Text $params -FirstPrefix ($prefix + "    ") -NextPrefix ($prefix + "    ")) -Indent 0
        $out.Add($prefix + ")")

        if ($after.Length -gt 0) {
            foreach ($part in ([regex]::Split($after, '\s+(?=LANGUAGE|RETURNS|DETERMINISTIC|NO\s+EXTERNAL\s+ACTION)') | Where-Object { $_.Trim().Length -gt 0 })) {
                $out.Add($prefix + (Normalize-Space $part))
            }
        }
    }
    else {
        $out.Add($prefix + $header)
    }

    $out.Add($prefix + $beginToken)

    $bodyLines = Format-RoutineBody -Body $body -Indent ($Indent + 2)
    Add-IndentedLines -Out $out -Lines $bodyLines -Indent 0

    $out.Add($prefix + "END")
    return $out
}

function Format-RoutineBody {
    param([string]$Body, [int]$Indent)

    $Body = Normalize-Space $Body

    # SQL PL body formatting is deliberately conservative:
    # split obvious statement starts and semicolon boundaries, but keep routine body
    # under the owning BEGIN/END instead of letting top-level splitting break it apart.
    $Body = [regex]::Replace($Body, '\s+\b(DECLARE|OPEN|FETCH|CLOSE|PREPARE|EXECUTE|IF|END IF|LOOP|END LOOP|LEAVE|SIGNAL|RETURN|MERGE INTO|SELECT|WITH)\b', "`n`$1", 'IgnoreCase')
    $Body = [regex]::Replace($Body, '\bTHEN\s+(SIGNAL|LEAVE|RETURN|MERGE INTO|SELECT|WITH)\b', "THEN`n`$1", 'IgnoreCase')
    $Body = [regex]::Replace($Body, ';\s*', ";`n")

    $rawLines = $Body -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
    $out = New-Object System.Collections.Generic.List[string]
    $level = 0

    foreach ($raw in $rawLines) {
        $line = Normalize-Space $raw
        if ($line -eq ";") { continue }

        $hadSemi = $line.EndsWith(";")
        $line = $line -replace ';\s*$', ''

        if ($line -match '^(END IF|END LOOP|END)\b') {
            if ($level -gt 0) { $level-- }
        }

        $lineIndent = $Indent + ($level * 2)

        if ($line -match '^(SELECT|WITH|MERGE INTO)\b') {
            Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $line -Indent $lineIndent -NoSemicolon) -Indent 0

            if ($hadSemi -and $out.Count -gt 0) {
                $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ";"
            }
        }
        elseif ($line -match '^DECLARE\s+.+\s+CURSOR\s+FOR\s+SELECT\b') {
            $m = [regex]::Match($line, '^(DECLARE\s+.+?\s+CURSOR\s+FOR)\s+(SELECT\b.+)$', 'IgnoreCase')
            if ($m.Success) {
                $out.Add((' ' * $lineIndent) + (Normalize-Space $m.Groups[1].Value))
                Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $m.Groups[2].Value -Indent ($lineIndent + 2) -NoSemicolon) -Indent 0

                if ($hadSemi -and $out.Count -gt 0) {
                    $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ";"
                }
            }
            else {
                $out.Add((' ' * $lineIndent) + $line + $(if ($hadSemi) { ";" } else { "" }))
            }
        }
        elseif ($line -match '^RETURN\s+CASE\b') {
            $caseText = $line -replace '^RETURN\s+', ''
            $caseLines = @(Format-CaseExpression -Item $caseText -FirstPrefix ((' ' * $lineIndent) + "RETURN ") -NextPrefix ((' ' * $lineIndent) + "       "))
            foreach ($caseLine in $caseLines) {
                $out.Add($caseLine)
            }

            if ($hadSemi -and $out.Count -gt 0) {
                $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ";"
            }
        }
        else {
            $out.Add((' ' * $lineIndent) + $line + $(if ($hadSemi) { ";" } else { "" }))
        }

        if ($line -match '\b(THEN|LOOP)\b' -and $line -notmatch '^END') {
            $level++
        }
    }

    return $out
}

function Format-GenericStatement {
    param([string]$Sql, [int]$Indent = 0)

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent

    if (($prefix + $Sql).Length -le 120) {
        return @($prefix + $Sql)
    }

    $Sql = [regex]::Replace($Sql, '\s+\b(FROM|WHERE|GROUP\s+BY|HAVING|ORDER\s+BY|FETCH\s+FIRST|WITH\s+(UR|RS|CS|RR|NC)|VALUES|SET|ON\s+COMMIT|NOT\s+LOGGED)\b', "`n`$1", 'IgnoreCase')
    return @($Sql -split "`n" | ForEach-Object { $prefix + (Normalize-Space $_) })
}

function Extract-LeadingComments {
    param([string]$Statement)

    $comments = New-Object System.Collections.Generic.List[string]
    $remaining = $Statement.Trim()

    while ($remaining -match '^\s*(__SQLFMT_(LCOM|BCOM)_\d+__)\s*(.*)$') {
        $comments.Add($matches[1])
        $remaining = $matches[3].Trim()
    }

    return [pscustomobject]@{ Comments = $comments; Body = $remaining }
}

function Format-SqlStatement {
    param(
        [string]$Statement,
        [int]$Indent = 0,
        [switch]$NoSemicolon
    )

    $Statement = Normalize-Space $Statement
    $Statement = Convert-SqlKeywordsToUpper $Statement

    $leading = Extract-LeadingComments -Statement $Statement
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($c in $leading.Comments) {
        $out.Add((' ' * $Indent) + $c)
    }

    $Statement = $leading.Body
    if ([string]::IsNullOrWhiteSpace($Statement)) { return $out }

    $bodyNoSemi = Strip-TrailingSemicolon $Statement
    $upper = $bodyNoSemi.Trim().ToUpperInvariant()

    if ($upper -match '^WITH\b') {
        Add-IndentedLines -Out $out -Lines @(Format-WithStatement -Sql $bodyNoSemi -Indent $Indent -NoSemicolon:$NoSemicolon) -Indent 0
    }
    elseif ($upper -match '^SELECT\b') {
        Add-IndentedLines -Out $out -Lines @(Format-SelectStatement -Sql $bodyNoSemi -Indent $Indent -NoSemicolon:$NoSemicolon) -Indent 0
    }
    elseif ($upper -match '^INSERT\b') {
        Add-IndentedLines -Out $out -Lines @(Format-InsertStatement -Sql $bodyNoSemi -Indent $Indent -NoSemicolon:$NoSemicolon) -Indent 0
    }
    elseif ($upper -match '^UPDATE\b') {
        Add-IndentedLines -Out $out -Lines @(Format-UpdateStatement -Sql $bodyNoSemi -Indent $Indent) -Indent 0
    }
    elseif ($upper -match '^DELETE\b') {
        Add-IndentedLines -Out $out -Lines @(Format-DeleteStatement -Sql $bodyNoSemi -Indent $Indent) -Indent 0
    }
    elseif ($upper -match '^MERGE\b') {
        Add-IndentedLines -Out $out -Lines @(Format-MergeStatement -Sql $bodyNoSemi -Indent $Indent) -Indent 0
    }
    elseif ($upper -match '^CREATE\s+(OR\s+REPLACE\s+)?VIEW\b') {
        Add-IndentedLines -Out $out -Lines @(Format-CreateViewStatement -Sql $bodyNoSemi -Indent $Indent) -Indent 0
    }
    elseif ($upper -match '^CREATE\s+INDEX\b') {
        Add-IndentedLines -Out $out -Lines @(Format-CreateIndexStatement -Sql $bodyNoSemi -Indent $Indent) -Indent 0
    }
    elseif ($upper -match '^(CREATE\s+TABLE|DECLARE\s+GLOBAL\s+TEMPORARY\s+TABLE)\b') {
        Add-IndentedLines -Out $out -Lines @(Format-CreateTableStatement -Sql $bodyNoSemi -Indent $Indent) -Indent 0
    }
    elseif ($upper -match '^ALTER\s+TABLE\b') {
        Add-IndentedLines -Out $out -Lines @(Format-AlterTableStatement -Sql $bodyNoSemi -Indent $Indent) -Indent 0
    }
    elseif ($upper -match '^CREATE\s+SCHEMA\b') {
        $out.Add((' ' * $Indent) + $bodyNoSemi)
    }
    elseif ($upper -match '^CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b') {
        Add-IndentedLines -Out $out -Lines @(Format-RoutineStatement -Sql $bodyNoSemi -Indent $Indent) -Indent 0
    }
    else {
        Add-IndentedLines -Out $out -Lines @(Format-GenericStatement -Sql $bodyNoSemi -Indent $Indent) -Indent 0
    }

    if (-not $NoSemicolon -and $out.Count -gt 0) {
        $lastIndex = $out.Count - 1
        $out[$lastIndex] = $out[$lastIndex].TrimEnd() + ";"
    }

    return $out
}

function Format-SqlText {
    param([string]$Sql)

    $protected = Protect-SqlLiteralsAndComments $Sql
    $protected = Convert-SqlKeywordsToUpper $protected

    $statements = @(Split-SqlStatements $protected)
    $allLines = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $statements.Count; $i++) {
        $lines = @(Format-SqlStatement -Statement $statements[$i] -Indent 0)

        foreach ($line in $lines) {
            $allLines.Add($line)
        }

        if ($i -lt $statements.Count - 1) {
            $allLines.Add("")
        }
    }

    $result = ($allLines -join [Environment]::NewLine)
    $result = Restore-ProtectedTokens $result
    return $result.TrimEnd() + [Environment]::NewLine
}

$inputSql = [Console]::In.ReadToEnd()
$result = Format-SqlText $inputSql
[Console]::Out.Write($result)