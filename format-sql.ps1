<#
    DB2 SQL Formatter - format-everything grid formatter

    Main rule:
      FORMAT EVERYTHING.
      Do not keep SELECT columns, WHERE predicates, JOIN predicates, CTEs, CASE blocks,
      INSERT lists, VALUES lists, GROUP BY lists, or ORDER BY lists inline just because
      they fit inside 120 columns.

    Design:
      - One SELECT grid everywhere.
      - Nested SELECT/WITH uses the same formatter, only shifted right.
      - Comments are protected/restored as plain text.
      - Strings are protected so SQL-looking text inside strings is not formatted.
      - This is heuristic, not a DB2 parser.
#>

$ErrorActionPreference = "Stop"

$script:KeywordCasing = "Uppercase"
$script:ProtectedMap = @{}
$script:ProtectedIndex = 0

function Load-SqlfmtSettings {
    $settingsPath = Join-Path $PSScriptRoot "settings\settings.json"

    if (-not (Test-Path $settingsPath)) {
        return
    }

    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

        if ($settings.PSObject.Properties.Name -contains "keywordCasing") {
            $value = [string]$settings.keywordCasing
            if ($value -in @("Uppercase", "Lowercase", "Preserve")) {
                $script:KeywordCasing = $value
            }
        }
    }
    catch {
        # Settings must never break DBeaver formatting.
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

    # Protect comments and strings.
    $Sql = [regex]::Replace($Sql, '/\*[\s\S]*?\*/', { param($m) New-ProtectedToken -Prefix "BCOM" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, "'(?:''|[^'])*'", { param($m) New-ProtectedToken -Prefix "STR" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '"(?:""|[^"])*"', { param($m) New-ProtectedToken -Prefix "DQS" -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '--[^\r\n]*', { param($m) New-ProtectedToken -Prefix "LCOM" -Value $m.Value })

    # Preserve physical line boundary after comments.
    $Sql = [regex]::Replace(
        $Sql,
        '(__SQLFMT_(?:LCOM|BCOM)_\d+__)(\r?\n)([ \t]*)',
        {
            param($m)
            return $m.Groups[1].Value + " __SQLFMT_EOL_" + $m.Groups[3].Value.Length + "__ "
        }
    )

    return $Sql
}

function Restore-SqlText {
    param([string]$Sql)

    $Sql = [regex]::Replace($Sql, '[ \t]*__SQLFMT_EOL_\d+__[ \t]*(\r?\n)', '$1')

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
    $Text = $Text -replace '\s+\)', ')'
    $Text = $Text -replace '\(\s+', '('
    $Text = $Text -replace '\s+;', ';'
    $Text = $Text.Trim()

    # Function style: NAME (...)
    foreach ($fn in @(
        'COUNT','SUM','AVG','MIN','MAX','COALESCE','NULLIF','TRIM','UPPER','LOWER',
        'CAST','VARCHAR','VARCHAR_FORMAT','DECIMAL','SUBSTR','SUBSTRING','DATE',
        'TIMESTAMP','LOCATE','ROW_NUMBER','RANK','DENSE_RANK','LAST_DAY'
    )) {
        $Text = [regex]::Replace(
            $Text,
            "(?i)\b$fn\s*\(",
            {
                param($m)
                return ($m.Value -replace '\s*\($', ' (')
            }
        )
    }

    return $Text
}

function Convert-SqlKeywords {
    param([string]$Sql)

    if ($script:KeywordCasing -eq "Preserve") {
        return $Sql
    }

    $keywords = @(
        'select','from','where','and','or','not','null','is','in','exists','between','like',
        'inner','left','right','full','cross','outer','join','on','group','by','having','order',
        'asc','desc','fetch','first','rows','only','limit','offset','with','ur','rs','cs','rr','nc',
        'union','all','except','intersect','case','when','then','else','end','as','over','partition',
        'insert','into','values','update','set','delete','merge','using','matched','then',
        'create','replace','procedure','function','returns','language','sql','begin','atomic',
        'declare','cursor','for','continue','handler','open','fetch','close','loop','leave','if',
        'signal','sqlstate','message_text','prepare','execute','table','view','index','schema',
        'constraint','primary','key','foreign','references','check','default','temporary','global',
        'session','commit','preserve','logged','alter','add','column','data','type','optimize',
        'deterministic','external','action','no','of'
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
            if ($depth -gt 0) {
                $depth--
            }
        }
        elseif ($Text[$i] -eq ',' -and $depth -eq 0) {
            $item = Normalize-Space $Text.Substring($start, $i - $start)

            if ($item.Length -gt 0) {
                $items.Add($item)
            }

            $start = $i + 1
        }
    }

    $last = Normalize-Space $Text.Substring($start)

    if ($last.Length -gt 0) {
        $items.Add($last)
    }

    return $items
}

function Split-TopLevelLogical {
    param([string]$Text)

    $parts = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0
    $skipNextAndForBetween = $false
    $i = 0

    while ($i -lt $Text.Length) {
        if ($Text[$i] -eq '(') {
            $depth++
            $i++
            continue
        }

        if ($Text[$i] -eq ')') {
            if ($depth -gt 0) {
                $depth--
            }

            $i++
            continue
        }

        if ($depth -eq 0) {
            $rest = $Text.Substring($i)

            if ($rest -match '^(?i)\bBETWEEN\b') {
                $skipNextAndForBetween = $true
                $i += $matches[0].Length
                continue
            }

            $m = [regex]::Match($rest, '^(AND|OR)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

            if ($m.Success) {
                $op = $m.Groups[1].Value.ToUpperInvariant()

                if ($op -eq "AND" -and $skipNextAndForBetween) {
                    $skipNextAndForBetween = $false
                    $i += $m.Length
                    continue
                }

                if ($i -gt $start) {
                    $segment = Normalize-Space $Text.Substring($start, $i - $start)

                    if ($segment.Length -gt 0) {
                        $parts.Add($segment)
                    }
                }

                $start = $i
            }
        }

        $i++
    }

    $tail = Normalize-Space $Text.Substring($start)

    if ($tail.Length -gt 0) {
        $parts.Add($tail)
    }

    if ($parts.Count -eq 0) {
        $parts.Add((Normalize-Space $Text))
    }

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

# ---------------------------------------------------------------------------
# Nested SELECT placement
# ---------------------------------------------------------------------------

function Format-NestedSelectExpression {
    param(
        [string]$Head,
        [string]$InnerSql,
        [string]$Tail,
        [int]$Indent,
        [int]$SubqueryDepth
    )

    $inner = $InnerSql.Trim()

    if ($inner -notmatch '^\s*(SELECT|WITH)\b' -or $SubqueryDepth -ge 5) {
        return $Head + "(" + (Normalize-Space $InnerSql) + ")" + $Tail
    }

    # SELECT starts after the prefix text and the opening parenthesis.
    # Example:
    #   AND EXISTS (SELECT ...
    #               FROM ...
    $nestedIndent = $Indent + $Head.Length + 1
    $innerLines = @(Format-SqlStatement -Statement $inner -Indent $nestedIndent -NoSemicolon -SubqueryDepth ($SubqueryDepth + 1))

    if ($innerLines.Count -eq 0) {
        return $Head + "()"
    }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($Head + "(" + $innerLines[0].Trim())

    for ($i = 1; $i -lt $innerLines.Count; $i++) {
        $out.Add($innerLines[$i])
    }

    $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ")" + $Tail
    return ($out -join [Environment]::NewLine)
}

function Format-AllParenthesizedSelectsInText {
    param(
        [string]$Text,
        [int]$Indent,
        [int]$SubqueryDepth = 0
    )

    $work = Normalize-Space $Text

    if ($work -notmatch '\(\s*(SELECT|WITH)\b') {
        return $work
    }

    # Format the first parenthesized SELECT/WITH found in this expression.
    # This is enough because Format-SqlStatement will recursively format the inner query.
    for ($i = 0; $i -lt $work.Length; $i++) {
        if ($work[$i] -ne '(') {
            continue
        }

        $close = Find-MatchingParen -Text $work -OpenIndex $i

        if ($close -lt 0) {
            continue
        }

        $inner = $work.Substring($i + 1, $close - $i - 1).Trim()

        if ($inner -notmatch '^\s*(SELECT|WITH)\b') {
            continue
        }

        $head = $work.Substring(0, $i)
        $tail = $work.Substring($close + 1)

        return Format-NestedSelectExpression `
            -Head $head `
            -InnerSql $inner `
            -Tail $tail `
            -Indent $Indent `
            -SubqueryDepth $SubqueryDepth
    }

    return $work
}

# ---------------------------------------------------------------------------
# Formatting primitives
# ---------------------------------------------------------------------------

function Add-MultilineItem {
    param(
        [System.Collections.Generic.List[string]]$Out,
        [string]$Item,
        [string]$FirstPrefix,
        [string]$NextPrefix,
        [string]$Suffix
    )

    $lines = $Item -split [regex]::Escape([Environment]::NewLine)

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq 0) {
            $Out.Add($FirstPrefix + $lines[$i])
        }
        elseif ($i -eq $lines.Count - 1) {
            $Out.Add($lines[$i] + $Suffix)
        }
        else {
            $Out.Add($lines[$i])
        }
    }
}

function Format-CaseExpression {
    param(
        [string]$Item,
        [string]$FirstPrefix,
        [string]$NextPrefix
    )

    $out = New-Object System.Collections.Generic.List[string]
    $item = Normalize-Space $Item

    if ($item -notmatch '^\s*CASE\b') {
        $out.Add($FirstPrefix + $item)
        return $out
    }

    $alias = ""
    $caseBody = $item
    $aliasMatch = [regex]::Match($item, '\bEND\s+AS\s+([A-Z0-9_"]+)\s*$', 'IgnoreCase')

    if ($aliasMatch.Success) {
        $alias = " AS " + $aliasMatch.Groups[1].Value
        $caseBody = $item.Substring(0, $aliasMatch.Index + 3).Trim()
    }

    $out.Add($FirstPrefix + "CASE")

    $work = $caseBody -replace '^\s*CASE\s+', ''
    $work = $work -replace '\s*END\s*$', ''
    $tokens = [regex]::Matches($work, '\bWHEN\b|\bELSE\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    if ($tokens.Count -eq 0) {
        $out[0] = $FirstPrefix + $item
        return $out
    }

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $next = if ($i -lt $tokens.Count - 1) { $tokens[$i + 1].Index } else { $work.Length }
        $segment = Normalize-Space $work.Substring($tokens[$i].Index, $next - $tokens[$i].Index)
        $segment = Format-AllParenthesizedSelectsInText -Text $segment -Indent ($NextPrefix.Length + 2)

        if ($segment -match [regex]::Escape([Environment]::NewLine) -and $segment -match '^(WHEN\s+[\s\S]+?)\s+THEN\s+([\s\S]+)$') {
            $out.Add($NextPrefix + "  " + $matches[1])
            $out.Add($NextPrefix + "  THEN " + $matches[2])
        }
        elseif ($segment -match '^(WHEN\s+.+?)\s+THEN\s+(.+)$' -and ($NextPrefix + "  " + $segment).Length -gt 120) {
            $out.Add($NextPrefix + "  " + $matches[1])
            $out.Add($NextPrefix + "  THEN " + $matches[2])
        }
        else {
            $out.Add($NextPrefix + "  " + $segment)
        }
    }

    $out.Add($NextPrefix + "END" + $alias)
    return $out
}

function Format-WindowExpression {
    param(
        [string]$Item,
        [string]$FirstPrefix,
        [string]$NextPrefix
    )

    $out = New-Object System.Collections.Generic.List[string]
    $item = Normalize-Space $Item

    $m = [regex]::Match(
        $item,
        '^(.*?)\s+OVER\s*\((.*)\)(\s+AS\s+[A-Z0-9_"]+)?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $m.Success) {
        $out.Add($FirstPrefix + $item)
        return $out
    }

    $func = Normalize-Space $m.Groups[1].Value
    $inside = Normalize-Space $m.Groups[2].Value
    $alias = $m.Groups[3].Value

    $out.Add($FirstPrefix + $func)

    $partitionMatch = [regex]::Match(
        $inside,
        '^(PARTITION\s+BY\s+.*?)(\s+ORDER\s+BY\s+.*)?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($partitionMatch.Success) {
        $partitionText = Normalize-Space $partitionMatch.Groups[1].Value
        $orderText = Normalize-Space $partitionMatch.Groups[2].Value

        if ($orderText.Length -gt 0) {
            $out.Add($NextPrefix + "  OVER (" + $partitionText)
            $out.Add($NextPrefix + "      " + $orderText + ")" + $alias)
        }
        else {
            $out.Add($NextPrefix + "  OVER (" + $partitionText + ")" + $alias)
        }
    }
    else {
        $out.Add($NextPrefix + "  OVER (" + $inside + ")" + $alias)
    }

    return $out
}

function Format-CommaListAlways {
    param(
        [string]$Text,
        [string]$FirstPrefix,
        [string]$NextPrefix
    )

    $out = New-Object System.Collections.Generic.List[string]
    $items = @(Split-TopLevelByComma $Text)

    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { "," } else { "" }
        $prefix = if ($i -eq 0) { $FirstPrefix } else { $NextPrefix }
        $out.Add($prefix + $items[$i] + $suffix)
    }

    return $out
}

function Format-InlineParenListAlways {
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

    if ($items.Count -eq 1) {
        $out.Add($Prefix + $Keyword + "(" + $items[0] + ")")
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

# ---------------------------------------------------------------------------
# SELECT
# ---------------------------------------------------------------------------

function Normalize-SelectItemCommentEol {
    param(
        [string]$Item,
        [int]$Indent
    )

    return [regex]::Replace(
        $Item,
        '__SQLFMT_EOL_\d+__',
        "__SQLFMT_EOL_$Indent`__"
    )
}

function Format-SelectList {
    param(
        [string]$Text,
        [int]$Indent,
        [int]$SubqueryDepth = 0
    )

    $out = New-Object System.Collections.Generic.List[string]
    $items = @(Split-TopLevelByComma (Normalize-Space $Text))

    $firstPrefix = (' ' * $Indent) + "SELECT "
    $nextPrefix = (' ' * $Indent) + "       "

    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { "," } else { "" }
        $prefix = if ($i -eq 0) { $firstPrefix } else { $nextPrefix }
        $itemIndent = if ($i -eq 0) { $Indent + 7 } else { $Indent + 7 }

        $item = Normalize-SelectItemCommentEol `
            -Item $items[$i] `
            -Indent $itemIndent
            
        $item = Format-AllParenthesizedSelectsInText `
            -Text $item `
            -Indent $itemIndent `
            -SubqueryDepth $SubqueryDepth

        if ($item -match '^\s*CASE\b') {
            $lines = @(Format-CaseExpression -Item $item -FirstPrefix $prefix -NextPrefix $nextPrefix)

            for ($j = 0; $j -lt $lines.Count; $j++) {
                if ($j -eq $lines.Count - 1) { $out.Add($lines[$j] + $suffix) }
                else { $out.Add($lines[$j]) }
            }
        }
        elseif ($item -match '\bOVER\s*\(') {
            $lines = @(Format-WindowExpression -Item $item -FirstPrefix $prefix -NextPrefix $nextPrefix)

            for ($j = 0; $j -lt $lines.Count; $j++) {
                if ($j -eq $lines.Count - 1) { $out.Add($lines[$j] + $suffix) }
                else { $out.Add($lines[$j]) }
            }
        }
        elseif ($item -match [regex]::Escape([Environment]::NewLine)) {
            Add-MultilineItem -Out $out -Item $item -FirstPrefix $prefix -NextPrefix $nextPrefix -Suffix $suffix
        }
        else {
            $out.Add($prefix + $item + $suffix)
        }
    }

    return $out
}

function Format-LogicalConditionGroup {
    param(
        [string]$Condition,
        [string]$LinePrefix
    )

    $condition = Normalize-Space $Condition

    if ($condition -notmatch '^\((.+)\)$') {
        return $condition
    }

    $inner = $condition.Substring(1, $condition.Length - 2).Trim()
    $parts = @(Split-TopLevelLogical $inner)

    if ($parts.Count -le 1) {
        return $condition
    }

    $out = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $raw = Normalize-Space $parts[$i]
        $op = ""
        $text = $raw

        if ($raw -match '^(AND|OR)\s+(.+)$') {
            $op = $matches[1].ToUpperInvariant()
            $text = $matches[2]
        }

        if ($i -eq 0) {
            $out.Add("(   " + $text)
        }
        else {
            if ($op -eq "OR") { $out.Add("        OR " + $text) }
            else { $out.Add("       AND " + $text) }
        }
    }

    $out[$out.Count - 1] = $out[$out.Count - 1] + ")"
    return ($out -join [Environment]::NewLine)
}

function Reindent-CommentEolTokens {
    param(
        [string]$Text,
        [int]$Indent
    )

    # A comment token followed by __SQLFMT_EOL_0__ means:
    #   restore a newline after the comment.
    #
    # If that comment appears inside a formatted WHERE/SELECT/JOIN item, the
    # original physical indent is not useful anymore. The continuation line must
    # follow the current SQL grid.
    return [regex]::Replace(
        $Text,
        '__SQLFMT_EOL_\d+__',
        "__SQLFMT_EOL_$Indent`__"
    )
}

function Format-WhereClause {
    param(
        [string]$Text,
        [string]$Keyword,
        [int]$Indent,
        [int]$SubqueryDepth = 0
    )

    $out = New-Object System.Collections.Generic.List[string]
    $prefix = ' ' * $Indent
    $parts = @(Split-TopLevelLogical $Text)

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $raw = Normalize-Space $parts[$i]

        $op = ""
        $condition = $raw

        if ($raw -match '^(AND|OR)\s+(.+)$') {
            $op = $matches[1].ToUpperInvariant()
            $condition = $matches[2]
        }

        $linePrefix = if ($i -eq 0) {
            $prefix + $Keyword + " "
        }
        elseif ($op -eq "OR") {
            $prefix + "    OR "
        }
        else {
            $prefix + "   AND "
        }

        # If a comment line boundary exists inside this WHERE item, do not let
        # the protected comment token become part of the nested SELECT head.
        #
        # Example protected shape:
        #   __SQLFMT_LCOM_7__ __SQLFMT_EOL_0__ EXISTS (SELECT ...)
        #
        # We format only the SQL after the EOL token, then attach it back.
        if ($condition -match '^(.*?__SQLFMT_EOL_\d+__)\s*(.+)$') {
            $beforeCommentBreak = $matches[1]
            $afterCommentBreak = $matches[2]

            $beforeCommentBreak = [regex]::Replace(
                $beforeCommentBreak,
                '__SQLFMT_EOL_\d+__',
                "__SQLFMT_EOL_$($linePrefix.Length)__"
            )

            $afterCommentBreak = Format-AllParenthesizedSelectsInText `
                -Text (Normalize-Space $afterCommentBreak) `
                -Indent $linePrefix.Length `
                -SubqueryDepth $SubqueryDepth

            $condition = $beforeCommentBreak + " " + $afterCommentBreak
        }
        else {
            # Normal path: format nested SELECT/WITH predicates.
            $condition = Format-AllParenthesizedSelectsInText `
                -Text (Normalize-Space $condition) `
                -Indent $linePrefix.Length `
                -SubqueryDepth $SubqueryDepth

            # Only format parenthesized logical groups when the condition is still
            # single-line. If nested SELECT formatting already created line breaks,
            # do not normalize it again or the subquery becomes inline again.
            if ($condition -notmatch [regex]::Escape([Environment]::NewLine)) {
                $condition = Format-LogicalConditionGroup `
                    -Condition $condition `
                    -LinePrefix $linePrefix
            }

            $condition = [regex]::Replace(
                $condition,
                '__SQLFMT_EOL_\d+__',
                "__SQLFMT_EOL_$($linePrefix.Length)__"
            )
        }

        if ($i -eq 0) {
            $out.Add($prefix + $Keyword + " " + $condition)
        }
        else {
            if ($op -eq "OR") {
                $out.Add($prefix + "    OR " + $condition)
            }
            else {
                $out.Add($prefix + "   AND " + $condition)
            }
        }
    }

    return $out
}

function Format-JoinClause {
    param(
        [string]$JoinText,
        [string]$Prefix,
        [int]$JoinPad
    )

    $out = New-Object System.Collections.Generic.List[string]
    $joinText = Normalize-Space $JoinText
    $on = Get-FirstTopLevelMatch -Text $joinText -Pattern '\bON\b'

    if ($null -eq $on) {
        $out.Add($Prefix + (' ' * $JoinPad) + $joinText)
        return $out
    }

    $head = Normalize-Space $joinText.Substring(0, $on.Index)
    $conditionText = Normalize-Space $joinText.Substring($on.Index + $on.Length)

    $out.Add($Prefix + (' ' * $JoinPad) + $head)

    $parts = @(Split-TopLevelLogical $conditionText)

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $raw = Normalize-Space $parts[$i]
        $op = ""
        $condition = $raw

        if ($raw -match '^(AND|OR)\s+(.+)$') {
            $op = $matches[1].ToUpperInvariant()
            $condition = $matches[2]
        }

        if ($i -eq 0) {
            $out.Add($Prefix + "    ON " + $condition)
        }
        else {
            if ($op -eq "OR") { $out.Add($Prefix + "    OR " + $condition) }
            else { $out.Add($Prefix + "   AND " + $condition) }
        }
    }

    return $out
}

function Format-FromClause {
    param(
        [string]$Text,
        [int]$Indent,
        [int]$SubqueryDepth = 0
    )

    $out = New-Object System.Collections.Generic.List[string]
    $prefix = ' ' * $Indent
    $text = $Text.Trim()

    if ($text.StartsWith("(")) {
        $close = Find-MatchingParen -Text $text -OpenIndex 0

        if ($close -gt 0) {
            $inner = $text.Substring(1, $close - 1).Trim()
            $alias = Normalize-Space $text.Substring($close + 1)

            if ($inner -match '^\s*(SELECT|WITH)\b') {
                $lines = @(Format-SqlStatement -Statement $inner -Indent ($Indent + 9) -NoSemicolon -SubqueryDepth ($SubqueryDepth + 1))
                $out.Add($prefix + "  FROM ( " + $lines[0].Trim())

                for ($i = 1; $i -lt $lines.Count; $i++) {
                    $out.Add($lines[$i])
                }

                $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + " )" + $(if ($alias) { " " + $alias } else { "" })
                return $out
            }
        }
    }

    $joinPattern = '\b(LEFT\s+OUTER\s+JOIN|RIGHT\s+OUTER\s+JOIN|FULL\s+OUTER\s+JOIN|INNER\s+JOIN|LEFT\s+JOIN|RIGHT\s+JOIN|FULL\s+JOIN|CROSS\s+JOIN|JOIN)\b'
    $matches = @(Get-TopLevelMatches -Text $text -Pattern $joinPattern)

    if ($matches.Count -eq 0) {
        $out.Add($prefix + "  FROM " + (Normalize-Space $text))
        return $out
    }

    $source = Normalize-Space $text.Substring(0, $matches[0].Index)

    if ($source) {
        $out.Add($prefix + "  FROM " + $source)
    }

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $next = if ($i -lt $matches.Count - 1) { $matches[$i + 1].Index } else { $text.Length }
        $joinText = Normalize-Space $text.Substring($matches[$i].Index, $next - $matches[$i].Index)
        $firstWord = ($joinText -split '\s+', 2)[0].ToUpperInvariant()
        $pad = [Math]::Max(1, 6 - $firstWord.Length)

        Add-IndentedLines -Out $out -Lines @(Format-JoinClause -JoinText $joinText -Prefix $prefix -JoinPad $pad) -Indent 0
    }

    return $out
}

function Has-TopLevelSetOperator {
    param([string]$Sql)

    return (@(Get-TopLevelMatches -Text $Sql -Pattern '\b(UNION\s+ALL|UNION|EXCEPT|INTERSECT)\b').Count -gt 0)
}

function Format-SetQuery {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$SubqueryDepth = 0
    )

    $out = New-Object System.Collections.Generic.List[string]
    $matches = @(Get-TopLevelMatches -Text $Sql -Pattern '\b(UNION\s+ALL|UNION|EXCEPT|INTERSECT)\b')
    $start = 0

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $part = $Sql.Substring($start, $matches[$i].Index - $start).Trim()

        if ($part) {
            Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $part -Indent $Indent -NoSemicolon -SubqueryDepth $SubqueryDepth) -Indent 0
        }

        $out.Add((' ' * $Indent) + $matches[$i].Value.ToUpperInvariant())
        $start = $matches[$i].Index + $matches[$i].Length
    }

    $tail = $Sql.Substring($start).Trim()

    if ($tail) {
        Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $tail -Indent $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth) -Indent 0
    }

    return $out
}

function Get-SelectClauses {
    param([string]$Sql)

    $pattern = '\bFROM\b|\bWHERE\b|\bGROUP\s+BY\b|\bHAVING\b|\bORDER\s+BY\b|\bFETCH\s+FIRST\b|\bLIMIT\b|\bOPTIMIZE\s+FOR\b|\bFOR\s+UPDATE\b|\bWITH\s+(UR|RS|CS|RR|NC)\b'
    $matches = @(Get-TopLevelMatches -Text $Sql -Pattern $pattern)
    $result = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $next = if ($i -lt $matches.Count - 1) { $matches[$i + 1].Index } else { $Sql.Length }

        $result.Add([pscustomobject]@{
            Name = $matches[$i].Value.ToUpperInvariant()
            Index = $matches[$i].Index
            Length = $matches[$i].Length
            Text = $Sql.Substring($matches[$i].Index + $matches[$i].Length, $next - ($matches[$i].Index + $matches[$i].Length)).Trim()
        })
    }

    return $result
}

function Format-SelectStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$SubqueryDepth = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)

    if (Has-TopLevelSetOperator -Sql $Sql) {
        return Format-SetQuery -Sql $Sql -Indent $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth
    }

    $out = New-Object System.Collections.Generic.List[string]
    $prefix = ' ' * $Indent

    if ($Sql -notmatch '^\s*SELECT\b') {
        $out.Add($prefix + $Sql)
        return $out
    }

    $clauses = @(Get-SelectClauses -Sql $Sql)

    if ($clauses.Count -eq 0) {
        Add-IndentedLines -Out $out -Lines @(Format-SelectList -Text ($Sql -replace '^\s*SELECT\s+', '') -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
        return $out
    }

    $selectList = $Sql.Substring(6, $clauses[0].Index - 6).Trim()
    Add-IndentedLines -Out $out -Lines @(Format-SelectList -Text $selectList -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0

    foreach ($clause in $clauses) {
        $name = $clause.Name
        $text = $clause.Text

        if ($name -eq 'FROM') {
            Add-IndentedLines -Out $out -Lines @(Format-FromClause -Text $text -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
        }
        elseif ($name -eq 'WHERE') {
            Add-IndentedLines -Out $out -Lines @(Format-WhereClause -Text $text -Keyword " WHERE" -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
        }
        elseif ($name -eq 'GROUP BY') {
            Add-IndentedLines -Out $out -Lines @(Format-CommaListAlways -Text $text -FirstPrefix ($prefix + " GROUP BY ") -NextPrefix ($prefix + "          ")) -Indent 0
        }
        elseif ($name -eq 'HAVING') {
            Add-IndentedLines -Out $out -Lines @(Format-WhereClause -Text $text -Keyword "HAVING" -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
        }
        elseif ($name -eq 'ORDER BY') {
            Add-IndentedLines -Out $out -Lines @(Format-CommaListAlways -Text $text -FirstPrefix ($prefix + " ORDER BY ") -NextPrefix ($prefix + "          ")) -Indent 0
        }
        elseif ($name -eq 'FETCH FIRST') {
            $out.Add($prefix + " FETCH FIRST " + (Normalize-Space $text))
        }
        elseif ($name -eq 'LIMIT') {
            $out.Add($prefix + " LIMIT " + (Normalize-Space $text))
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
    }

    return $out
}

# ---------------------------------------------------------------------------
# WITH
# ---------------------------------------------------------------------------

function Format-WithStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$SubqueryDepth = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $body = $Sql -replace '^\s*WITH\s+', ''
    $pos = 0
    $index = 0

    while ($pos -lt $body.Length) {
        $remaining = $body.Substring($pos)
        $m = [regex]::Match($remaining, '^\s*([A-Z0-9_]+(?:\s*\([^)]*\))?)\s+AS\s*\(', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        if (-not $m.Success) {
            break
        }

        $name = Normalize-Space $m.Groups[1].Value
        $open = $pos + $m.Index + $m.Length - 1
        $close = Find-MatchingParen -Text $body -OpenIndex $open

        if ($close -lt 0) {
            break
        }

        $inner = $body.Substring($open + 1, $close - $open - 1).Trim()

        # The first SELECT is printed after "     AS ( ".
        # This is 10 characters from the CTE indent.
        $lines = @(Format-SqlStatement -Statement $inner -Indent ($Indent + 10) -NoSemicolon -SubqueryDepth ($SubqueryDepth + 1))

        if ($index -eq 0) {
            $out.Add($prefix + "WITH " + $name)
        }
        else {
            $out.Add($prefix + "     " + $name)
        }

        $out.Add($prefix + "     AS ( " + $lines[0].Trim())

        for ($i = 1; $i -lt $lines.Count; $i++) {
            $out.Add($lines[$i])
        }

        $pos = $close + 1

        while ($pos -lt $body.Length -and [char]::IsWhiteSpace($body[$pos])) {
            $pos++
        }

        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + " )"

        if ($pos -lt $body.Length -and $body[$pos] -eq ',') {
            $out[$out.Count - 1] += ","
            $pos++
            $index++
        }
        else {
            break
        }
    }

    $rest = $body.Substring($pos).Trim()

    if ($out.Count -eq 0) {
        $out.Add($prefix + $Sql)
        return $out
    }

    if ($rest) {
        Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $rest -Indent $Indent -NoSemicolon -SubqueryDepth $SubqueryDepth) -Indent 0
    }

    return $out
}

# ---------------------------------------------------------------------------
# DML / DDL
# ---------------------------------------------------------------------------

function Format-InsertStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$SubqueryDepth = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $select = Get-FirstTopLevelMatch -Text $Sql -Pattern '\b(WITH|SELECT)\b'
    $values = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bVALUES\b'

    if ($null -ne $select -and ($null -eq $values -or $select.Index -lt $values.Index)) {
        $head = $Sql.Substring(0, $select.Index).Trim()
        $query = $Sql.Substring($select.Index).Trim()
        $open = $head.IndexOf('(')
        $close = if ($open -ge 0) { Find-MatchingParen -Text $head -OpenIndex $open } else { -1 }

        if ($open -ge 0 -and $close -gt $open) {
            $before = Normalize-Space $head.Substring(0, $open)
            $cols = $head.Substring($open + 1, $close - $open - 1)
            Add-IndentedLines -Out $out -Lines @(Format-InlineParenListAlways -Keyword ($before + " ") -Text $cols -Prefix $prefix) -Indent 0
        }
        else {
            $out.Add($prefix + $head)
        }

        Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $query -Indent $Indent -NoSemicolon -SubqueryDepth $SubqueryDepth) -Indent 0
        return $out
    }

    if ($null -ne $values) {
        $head = $Sql.Substring(0, $values.Index).Trim()
        $valuesText = $Sql.Substring($values.Index + $values.Length).Trim()
        $open = $head.IndexOf('(')
        $close = if ($open -ge 0) { Find-MatchingParen -Text $head -OpenIndex $open } else { -1 }

        if ($open -ge 0 -and $close -gt $open) {
            $before = Normalize-Space $head.Substring(0, $open)
            $cols = $head.Substring($open + 1, $close - $open - 1)
            Add-IndentedLines -Out $out -Lines @(Format-InlineParenListAlways -Keyword ($before + " ") -Text $cols -Prefix $prefix) -Indent 0
        }
        else {
            $out.Add($prefix + $head)
        }

        if ($valuesText.StartsWith("(")) {
            $end = Find-MatchingParen -Text $valuesText -OpenIndex 0

            if ($end -gt 0) {
                $valuesBody = $valuesText.Substring(1, $end - 1)
                Add-IndentedLines -Out $out -Lines @(Format-InlineParenListAlways -Keyword "VALUES " -Text $valuesBody -Prefix $prefix) -Indent 0
                return $out
            }
        }
    }

    $out.Add($prefix + $Sql)
    return $out
}

function Format-UpdateStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [int]$SubqueryDepth = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $set = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bSET\b'

    if ($null -eq $set) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $where = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bWHERE\b'
    $head = Normalize-Space $Sql.Substring(0, $set.Index)
    $setEnd = if ($null -ne $where) { $where.Index } else { $Sql.Length }
    $setText = $Sql.Substring($set.Index + $set.Length, $setEnd - ($set.Index + $set.Length)).Trim()

    $out.Add($prefix + $head)

    $items = @(Split-TopLevelByComma $setText)

    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { "," } else { "" }
        $itemPrefix = if ($i -eq 0) { $prefix + "   SET " } else { $prefix + "       " }
        $assignment = Format-AllParenthesizedSelectsInText -Text (Normalize-Space $items[$i]) -Indent ($Indent + 7) -SubqueryDepth $SubqueryDepth
        $caseMatch = [regex]::Match($assignment, '^(.*?)=\s*(CASE\b[\s\S]+\bEND)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        if ($caseMatch.Success) {
            $left = Normalize-Space $caseMatch.Groups[1].Value
            $caseText = $caseMatch.Groups[2].Value
            $casePrefix = $itemPrefix + $left + " = "
            $caseNextPrefix = ' ' * $casePrefix.Length
            $caseLines = @(Format-CaseExpression -Item $caseText -FirstPrefix $casePrefix -NextPrefix $caseNextPrefix)
            $caseLines[$caseLines.Count - 1] += $suffix
            Add-IndentedLines -Out $out -Lines $caseLines -Indent 0
        }
        elseif ($assignment -match [regex]::Escape([Environment]::NewLine)) {
            Add-MultilineItem -Out $out -Item $assignment -FirstPrefix $itemPrefix -NextPrefix ($prefix + "       ") -Suffix $suffix
        }
        else {
            $out.Add($itemPrefix + $assignment + $suffix)
        }
    }

    if ($null -ne $where) {
        $whereText = $Sql.Substring($where.Index + $where.Length).Trim()
        Add-IndentedLines -Out $out -Lines @(Format-WhereClause -Text $whereText -Keyword " WHERE" -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
    }

    return $out
}

function Format-DeleteStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [int]$SubqueryDepth = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $where = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bWHERE\b'

    if ($Sql -match '^\s*DELETE\s+FROM\b' -and $null -ne $where) {
        $fromText = Normalize-Space ($Sql.Substring(0, $where.Index) -replace '^\s*DELETE\s+FROM\s+', '')
        $whereText = $Sql.Substring($where.Index + $where.Length).Trim()

        $out.Add($prefix + "DELETE")
        $out.Add($prefix + "  FROM " + $fromText)
        Add-IndentedLines -Out $out -Lines @(Format-WhereClause -Text $whereText -Keyword " WHERE" -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
        return $out
    }

    if ($null -eq $where) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $head = Normalize-Space $Sql.Substring(0, $where.Index)
    $whereText = $Sql.Substring($where.Index + $where.Length).Trim()

    $out.Add($prefix + $head)
    Add-IndentedLines -Out $out -Lines @(Format-WhereClause -Text $whereText -Keyword " WHERE" -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
    return $out
}

function Format-MergeStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [int]$SubqueryDepth = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]

    $using = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bUSING\b'
    $on = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bON\b'
    $whens = @(Get-TopLevelMatches -Text $Sql -Pattern '\bWHEN\s+(MATCHED|NOT\s+MATCHED)\s+THEN\b')

    if ($null -eq $using -or $null -eq $on) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $out.Add($prefix + " MERGE " + (Normalize-Space (($Sql.Substring(0, $using.Index)) -replace '^\s*MERGE\s+', '')))

    $usingText = $Sql.Substring($using.Index + $using.Length, $on.Index - ($using.Index + $using.Length)).Trim()

    if ($usingText.StartsWith("(")) {
        $close = Find-MatchingParen -Text $usingText -OpenIndex 0
        $inner = $usingText.Substring(1, $close - 1).Trim()
        $alias = Normalize-Space $usingText.Substring($close + 1)
        $lines = @(Format-SqlStatement -Statement $inner -Indent ($Indent + 9) -NoSemicolon -SubqueryDepth ($SubqueryDepth + 1))

        $out.Add($prefix + " USING ( " + $lines[0].Trim())

        for ($i = 1; $i -lt $lines.Count; $i++) {
            $out.Add($lines[$i])
        }

        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + " )" + $(if ($alias) { " " + $alias } else { "" })
    }
    else {
        $out.Add($prefix + " USING " + $usingText)
    }

    $onEnd = if ($whens.Count -gt 0) { $whens[0].Index } else { $Sql.Length }
    $onText = $Sql.Substring($on.Index + $on.Length, $onEnd - ($on.Index + $on.Length))
    $parts = @(Split-TopLevelLogical $onText)

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $raw = Normalize-Space $parts[$i]
        $op = ""
        $condition = $raw

        if ($raw -match '^(AND|OR)\s+(.+)$') {
            $op = $matches[1].ToUpperInvariant()
            $condition = $matches[2]
        }

        if ($i -eq 0) {
            $out.Add($prefix + "    ON " + $condition)
        }
        else {
            if ($op -eq "OR") { $out.Add($prefix + "    OR " + $condition) }
            else { $out.Add($prefix + "   AND " + $condition) }
        }
    }

    for ($i = 0; $i -lt $whens.Count; $i++) {
        $next = if ($i -lt $whens.Count - 1) { $whens[$i + 1].Index } else { $Sql.Length }
        $whenText = Normalize-Space $Sql.Substring($whens[$i].Index, $next - $whens[$i].Index)
        $updateSet = [regex]::Match($whenText, '^(WHEN\s+MATCHED\s+THEN)\s+UPDATE\s+SET\s+(.+)$', 'IgnoreCase')
        $insertValues = [regex]::Match($whenText, '^(WHEN\s+NOT\s+MATCHED\s+THEN)\s+INSERT\s*\((.+?)\)\s+VALUES\s*\((.+)\)$', 'IgnoreCase')

        if ($updateSet.Success) {
            $out.Add($prefix + "  WHEN MATCHED THEN")
            Add-IndentedLines -Out $out -Lines @(Format-CommaListAlways -Text $updateSet.Groups[2].Value -FirstPrefix ($prefix + "UPDATE SET ") -NextPrefix ($prefix + "           ")) -Indent 0
        }
        elseif ($insertValues.Success) {
            $out.Add($prefix + "  WHEN NOT MATCHED THEN")
            Add-IndentedLines -Out $out -Lines @(Format-InlineParenListAlways -Keyword "INSERT " -Text $insertValues.Groups[2].Value -Prefix $prefix) -Indent 0
            Add-IndentedLines -Out $out -Lines @(Format-InlineParenListAlways -Keyword "VALUES " -Text $insertValues.Groups[3].Value -Prefix $prefix) -Indent 0
        }
        else {
            $out.Add($prefix + "  " + $whenText)
        }
    }

    return $out
}

function Format-CreateTableStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0
    )

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
    Add-IndentedLines -Out $out -Lines @(Format-CommaListAlways -Text $body -FirstPrefix ($prefix + "  ") -NextPrefix ($prefix + "  ")) -Indent 0
    $out.Add($prefix + ")" + $(if ($tail) { " " + $tail } else { "" }))

    return $out
}

function Format-CreateTableAsStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [int]$SubqueryDepth = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $as = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bAS\s*\('

    if ($null -eq $as) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $open = $Sql.IndexOf('(', $as.Index)
    $close = Find-MatchingParen -Text $Sql -OpenIndex $open
    $head = Normalize-Space $Sql.Substring(0, $open)
    $inner = $Sql.Substring($open + 1, $close - $open - 1)
    $tail = Normalize-Space $Sql.Substring($close + 1)

    $out.Add($prefix + $head + " (")
    Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $inner -Indent ($Indent + 2) -NoSemicolon -SubqueryDepth ($SubqueryDepth + 1)) -Indent 0
    $out.Add($prefix + ")")

    if ($tail) {
        $out.Add($prefix + $tail)
    }

    return $out
}

function Format-CreateViewStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [int]$SubqueryDepth = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $as = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bAS\b'
    $out = New-Object System.Collections.Generic.List[string]

    if ($null -eq $as) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $out.Add($prefix + (Normalize-Space $Sql.Substring(0, $as.Index)))
    $out.Add($prefix + "AS")
    Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement ($Sql.Substring($as.Index + $as.Length).Trim()) -Indent ($Indent + 2) -NoSemicolon -SubqueryDepth ($SubqueryDepth + 1)) -Indent 0

    return $out
}

function Format-GenericStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $Sql = [regex]::Replace($Sql, '\s+\b(FROM|WHERE|GROUP\s+BY|HAVING|ORDER\s+BY|FETCH\s+FIRST|WITH\s+(UR|RS|CS|RR|NC)|VALUES|SET|ON\s+COMMIT|NOT\s+LOGGED)\b', "`n`$1", 'IgnoreCase')

    return @($Sql -split "`n" | ForEach-Object { $prefix + (Normalize-Space $_) })
}

# ---------------------------------------------------------------------------
# SQL PL routines
# ---------------------------------------------------------------------------

function Format-RoutineStatement {
    param(
        [string]$Sql,
        [int]$Indent = 0,
        [int]$SubqueryDepth = 0
    )

    $Sql = Normalize-Space (Strip-TrailingSemicolon $Sql)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    $begin = Get-FirstTopLevelMatch -Text $Sql -Pattern '\bBEGIN(\s+ATOMIC)?\b'

    if ($null -eq $begin) {
        $out.Add($prefix + $Sql)
        return $out
    }

    $head = Normalize-Space $Sql.Substring(0, $begin.Index)
    $beginToken = Normalize-Space $begin.Value
    $body = Normalize-Space $Sql.Substring($begin.Index + $begin.Length)
    $body = $body -replace '\bEND\s*$', ''
    $open = $head.IndexOf('(')
    $close = if ($open -ge 0) { Find-MatchingParen -Text $head -OpenIndex $open } else { -1 }

    if ($open -ge 0 -and $close -gt $open) {
        $out.Add($prefix + (Normalize-Space $head.Substring(0, $open)) + " (")
        Add-IndentedLines -Out $out -Lines @(Format-CommaListAlways -Text $head.Substring($open + 1, $close - $open - 1) -FirstPrefix ($prefix + "  ") -NextPrefix ($prefix + "  ")) -Indent 0
        $out.Add($prefix + ")")

        $after = Normalize-Space $head.Substring($close + 1)

        if ($after) {
            foreach ($part in ([regex]::Split($after, '\s+(?=LANGUAGE|RETURNS|DETERMINISTIC|NO\s+EXTERNAL\s+ACTION)') | Where-Object { $_.Trim() })) {
                $out.Add($prefix + (Normalize-Space $part))
            }
        }
    }
    else {
        $out.Add($prefix + $head)
    }

    $out.Add($prefix + $beginToken)
    Add-IndentedLines -Out $out -Lines @(Format-RoutineBody -Body $body -Indent ($Indent + 2) -SubqueryDepth $SubqueryDepth) -Indent 0
    $out.Add($prefix + "END")

    return $out
}

function Format-RoutineBody {
    param(
        [string]$Body,
        [int]$Indent,
        [int]$SubqueryDepth = 0
    )

    $Body = Normalize-Space $Body
    $Body = [regex]::Replace($Body, '\s+\b(DECLARE|OPEN|FETCH|CLOSE|PREPARE|EXECUTE|IF|END IF|LOOP|END LOOP|LEAVE|SIGNAL|RETURN|MERGE INTO|SELECT|WITH|UPDATE|DELETE|INSERT)\b', "`n`$1", 'IgnoreCase')
    $Body = [regex]::Replace($Body, ';\s*', ";`n")
    $rawLines = $Body -split "`n" | Where-Object { $_.Trim() }
    $out = New-Object System.Collections.Generic.List[string]
    $level = 0

    foreach ($raw in $rawLines) {
        $line = Normalize-Space $raw
        $hasSemi = $line.EndsWith(";")
        $line = $line -replace ';\s*$', ''

        if ($line -match '^(END IF|END LOOP|END)\b' -and $level -gt 0) {
            $level--
        }

        $lineIndent = $Indent + ($level * 2)

        if ($line -match '^(SELECT|WITH|MERGE INTO|UPDATE|DELETE|INSERT)\b') {
            Add-IndentedLines -Out $out -Lines @(Format-SqlStatement -Statement $line -Indent $lineIndent -NoSemicolon -SubqueryDepth $SubqueryDepth) -Indent 0
        
            if ($hasSemi -and $out.Count) {
                $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ";"
            }
        }
        elseif ($line -match '^RETURN\s+CASE\b') {
            $caseText = $line -replace '^RETURN\s+', ''
            $firstPrefix = (' ' * $lineIndent) + "RETURN "
            $nextPrefix = ' ' * $firstPrefix.Length
        
            $caseLines = @(Format-CaseExpression -Item $caseText -FirstPrefix $firstPrefix -NextPrefix $nextPrefix)
            Add-IndentedLines -Out $out -Lines $caseLines -Indent 0
        
            if ($hasSemi -and $out.Count) {
                $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ";"
            }
        }
        else {
            $out.Add((' ' * $lineIndent) + $line + $(if ($hasSemi) { ";" } else { "" }))
        }

        if ($line -match '\b(THEN|LOOP)\b' -and $line -notmatch '^END') {
            $level++
        }

        if ($hasSemi) {
            $out.Add("")
        }
    }

    while ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) {
        $out.RemoveAt($out.Count - 1)
    }

    return $out
}

# ---------------------------------------------------------------------------
# Statement splitting/routing
# ---------------------------------------------------------------------------

function Remove-LeadingProtectedCommentsForDetection {
    param([string]$Text)

    $work = $Text.Trim()

    while ($work -match '^\s*__SQLFMT_(LCOM|BCOM)_\d+__\s*') {
        $work = [regex]::Replace($work, '^\s*__SQLFMT_(LCOM|BCOM)_\d+__\s*', '').Trim()
    }

    return $work
}

function Test-RoutineStatementComplete {
    param([string]$Text)

    $work = (Remove-LeadingProtectedCommentsForDetection -Text $Text).ToUpperInvariant()

    if ($work -notmatch '^\s*CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b') {
        return $false
    }

    $tokens = [regex]::Matches(
        $work,
        '\bBEGIN\s+ATOMIC\b|\bBEGIN\b|\bCASE\b|\bLOOP\b|\bIF\b|\bEND\s+IF\b|\bEND\s+LOOP\b|\bEND\b',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $depth = 0

    foreach ($token in $tokens) {
        $t = $token.Value.ToUpperInvariant() -replace '\s+', ' '

        if ($t -match '^BEGIN|^CASE$|^LOOP$|^IF$') {
            $depth++
        }
        elseif ($t -match '^END IF$|^END LOOP$|^END$') {
            if ($depth -gt 0) {
                $depth--
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
        if ($Sql[$i] -eq '(') {
            $depth++
        }
        elseif ($Sql[$i] -eq ')') {
            if ($depth -gt 0) {
                $depth--
            }
        }
        elseif ($Sql[$i] -eq ';' -and $depth -eq 0) {
            $candidate = $Sql.Substring($start, $i - $start).Trim()

            if ($candidate) {
                $detect = Remove-LeadingProtectedCommentsForDetection -Text $candidate

                if (-not $insideRoutine -and $detect -match '^\s*CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b') {
                    $insideRoutine = $true
                }

                if ($insideRoutine) {
                    if (-not (Test-RoutineStatementComplete -Text $candidate)) {
                        continue
                    }

                    $insideRoutine = $false
                }

                $statements.Add($candidate + ';')
            }

            $start = $i + 1
        }
    }

    $tail = $Sql.Substring($start).Trim()

    if ($tail) {
        $statements.Add($tail)
    }

    return $statements
}

function Extract-LeadingComments {
    param([string]$Statement)

    $comments = New-Object System.Collections.Generic.List[string]
    $remaining = $Statement.Trim()

    while ($true) {
        # Skip preserved EOL tokens that appear between protected comments.
        $remaining = [regex]::Replace(
            $remaining,
            '^\s*__SQLFMT_EOL_\d+__\s*',
            ''
        ).Trim()

        if ($remaining -notmatch '^\s*(__SQLFMT_(LCOM|BCOM)_\d+__)\s*(.*)$') {
            break
        }

        $comments.Add($matches[1])
        $remaining = $matches[3].Trim()
    }

    # If the last consumed comment was followed by an EOL token, remove it too
    # before statement routing checks whether the body starts with WITH/SELECT/etc.
    $remaining = [regex]::Replace(
        $remaining,
        '^\s*__SQLFMT_EOL_\d+__\s*',
        ''
    ).Trim()

    return [pscustomobject]@{
        Comments = $comments
        Body = $remaining
    }
}

function Format-SqlStatement {
    param(
        [string]$Statement,
        [int]$Indent = 0,
        [switch]$NoSemicolon,
        [int]$SubqueryDepth = 0
    )

    $Statement = Convert-SqlKeywords (Normalize-Space $Statement)
    $leading = Extract-LeadingComments -Statement $Statement
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($comment in $leading.Comments) {
        $out.Add((' ' * $Indent) + $comment)
    }

    $body = Strip-TrailingSemicolon $leading.Body

    if (-not $body) {
        return $out
    }

    $upper = $body.Trim().ToUpperInvariant()

    if ($upper -match '^WITH\b') {
        Add-IndentedLines -Out $out -Lines @(Format-WithStatement -Sql $body -Indent $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth) -Indent 0
    }
    elseif ($upper -match '^SELECT\b') {
        Add-IndentedLines -Out $out -Lines @(Format-SelectStatement -Sql $body -Indent $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth) -Indent 0
    }
    elseif ($upper -match '^INSERT\b') {
        Add-IndentedLines -Out $out -Lines @(Format-InsertStatement -Sql $body -Indent $Indent -NoSemicolon:$NoSemicolon -SubqueryDepth $SubqueryDepth) -Indent 0
    }
    elseif ($upper -match '^UPDATE\b') {
        Add-IndentedLines -Out $out -Lines @(Format-UpdateStatement -Sql $body -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
    }
    elseif ($upper -match '^DELETE\b') {
        Add-IndentedLines -Out $out -Lines @(Format-DeleteStatement -Sql $body -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
    }
    elseif ($upper -match '^MERGE\b') {
        Add-IndentedLines -Out $out -Lines @(Format-MergeStatement -Sql $body -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
    }
    elseif ($upper -match '^CREATE\s+TABLE\b' -and $upper -match '\bAS\s*\(' -and $upper -match '\bWITH\s+(NO\s+)?DATA\b') {
        Add-IndentedLines -Out $out -Lines @(Format-CreateTableAsStatement -Sql $body -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
    }
    elseif ($upper -match '^(CREATE\s+TABLE|DECLARE\s+GLOBAL\s+TEMPORARY\s+TABLE)\b') {
        Add-IndentedLines -Out $out -Lines @(Format-CreateTableStatement -Sql $body -Indent $Indent) -Indent 0
    }
    elseif ($upper -match '^CREATE\s+(OR\s+REPLACE\s+)?VIEW\b') {
        Add-IndentedLines -Out $out -Lines @(Format-CreateViewStatement -Sql $body -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
    }
    elseif ($upper -match '^CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b') {
        Add-IndentedLines -Out $out -Lines @(Format-RoutineStatement -Sql $body -Indent $Indent -SubqueryDepth $SubqueryDepth) -Indent 0
    }
    else {
        Add-IndentedLines -Out $out -Lines @(Format-GenericStatement -Sql $body -Indent $Indent) -Indent 0
    }

    if (-not $NoSemicolon -and $out.Count) {
        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ";"
    }

    return $out
}

function Format-SqlText {
    param([string]$Sql)

    $protected = Convert-SqlKeywords (Protect-SqlText -Sql $Sql)
    $statements = @(Split-SqlStatements -Sql $protected)
    $allLines = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $statements.Count; $i++) {
        foreach ($line in @(Format-SqlStatement -Statement $statements[$i] -Indent 0)) {
            $allLines.Add($line)
        }

        if ($i -lt $statements.Count - 1) {
            $allLines.Add("")
        }
    }

    $result = $allLines -join [Environment]::NewLine
    $result = Restore-SqlText -Sql $result

    return $result.TrimEnd()
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()

$inputSql = [Console]::In.ReadToEnd()
$result = Format-SqlText -Sql $inputSql

$timer.Stop()

[Console]::Out.Write($result)
# [Console]::Error.WriteLine()
# [Console]::Error.WriteLine((" -- SQLFMT completed in {0:N3} seconds" -f $timer.Elapsed.TotalSeconds))