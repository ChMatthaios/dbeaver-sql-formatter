<#
    DBeaver External SQL Beautifier
    Unified SELECT Architecture
    ------------------------------------------------------------

    Core idea:
      A SELECT is always formatted by the same formatter.

      Normal SELECT:
        Format-SelectStatement -Sql $sql -OpeningPrefix ""

      CTE SELECT:
        Format-SelectStatement -Sql $innerSql -OpeningPrefix "WITH NAME AS ( "

      MERGE source SELECT:
        Format-SelectStatement -Sql $sourceSql -OpeningPrefix " USING ( "

    This avoids the previous problem where normal SELECTs, CTE SELECTs,
    and MERGE source SELECTs were formatted by different logic.

    Rules:
      - No downloads
      - PowerShell 5.1 compatible
      - 120-character target line length where safe
      - Spaces only
      - CRLF output
      - SQL keywords/functions uppercase
      - SELECT / FROM / WHERE / GROUP BY / ORDER BY / LIMIT / WITH UR
        keep the same alignment style everywhere
#>

$ErrorActionPreference = "Stop"

$script:MaxLineLength = 80
$script:NewLine = "`r`n"

# ======================================================================
# Protection layer
# ======================================================================
# We protect strings and comments before normalizing whitespace or
# uppercasing keywords. This prevents the formatter from changing text
# inside string literals or comments.
# ======================================================================

$script:ProtectedMap = @{}
$script:ProtectedIndex = 0

function New-ProtectedToken {
    param(
        [string]$Prefix,
        [string]$Value
    )

    $token = "__SQLFMT_${Prefix}_$script:ProtectedIndex`__"
    $script:ProtectedMap[$token] = $Value
    $script:ProtectedIndex++

    return $token
}

function Protect-SqlText {
    param([string]$Text)

    # ------------------------------------------------------------------
    # Comment/string protection strategy
    # ------------------------------------------------------------------
    # The formatter normalizes whitespace before rebuilding SQL. If raw
    # comments are left in the SQL during that step, line comments can swallow
    # the next tokens and block comments can be split incorrectly.
    #
    # So comments and strings are replaced with neutral tokens first, then the
    # real text is restored at the end.
    #
    # Important style rule:
    #   Comments are not "formatted" separately. They behave like text items
    #   that stay where they were:
    #
    #     SELECT A,
    #            -- comment
    #            B,
    #            C -- inline comment
    #
    # Standalone comments receive an internal EOL marker only so the formatter
    # remembers that the next SQL token originally started on the next line.
    # ------------------------------------------------------------------

    # Standalone block comments:
    #
    #   /*
    #    ...
    #   */
    #
    # If the block comment occupies its own physical line/block, keep it as a
    # standalone item by appending __SQLFMT_EOL__. This allows later formatting
    # to place it on its own line without inventing blank lines.
    $Text = [regex]::Replace(
        $Text,
        '(?ms)(^|\n)[ \t]*(/\*.*?\*/)[ \t]*(?=\n|$)',
        {
            param($m)
            $m.Groups[1].Value +
            (New-ProtectedToken -Prefix "BCOM" -Value $m.Groups[2].Value) +
            ' __SQLFMT_EOL__ '
        }
    )

    # Remaining block comments are inline block comments. They stay exactly
    # where they are in the expression/statement that contains them.
    $Text = [regex]::Replace(
        $Text,
        '/\*[\s\S]*?\*/',
        { param($m) New-ProtectedToken -Prefix "BCOM" -Value $m.Value }
    )

    # Protect SQL string literals, including escaped single quotes.
    $Text = [regex]::Replace(
        $Text,
        "'(?:''|[^'])*'",
        { param($m) New-ProtectedToken -Prefix "STR" -Value $m.Value }
    )

    # Standalone line comments:
    #
    #   -- comment
    #
    # behave like standalone SELECT-list/procedure items. The EOL marker only
    # preserves the original "next token starts on next line" boundary.
    $Text = [regex]::Replace(
        $Text,
        '(?m)^[ \t]*(--.*)$',
        {
            param($m)
            (New-ProtectedToken -Prefix "SLCOM" -Value $m.Groups[1].Value) +
            ' __SQLFMT_EOL__ '
        }
    )

    # Inline line comments:
    #
    #   COL, -- comment
    #
    # remain attached to the previous item. The EOL marker lets the next SQL
    # token continue as the next item/line instead of being consumed by the
    # comment.
    $Text = [regex]::Replace(
        $Text,
        '(?m)--.*$',
        {
            param($m)
            (New-ProtectedToken -Prefix "LCOM" -Value $m.Value) +
            ' __SQLFMT_EOL__ '
        }
    )

    return $Text
}

function Restore-SqlText {
    param([string]$Text)

    foreach ($key in ($script:ProtectedMap.Keys | Sort-Object Length -Descending)) {
        $Text = $Text.Replace($key, $script:ProtectedMap[$key])
    }

    return $Text
}

# ======================================================================
# Normalization and keyword casing
# ======================================================================

function Normalize-SqlWhitespace {
    param([string]$Text)

    $Text = $Text -replace "`r`n", "`n"
    $Text = $Text -replace "`r", "`n"

    # Create a predictable single-line representation.
    $Text = [regex]::Replace($Text, '[ \t\r\n]+', ' ')
    $Text = [regex]::Replace($Text, '\s*,\s*', ', ')
    $Text = [regex]::Replace($Text, '\s*\(\s*', ' (')
    $Text = [regex]::Replace($Text, '\s*\)\s*', ') ')
    $Text = [regex]::Replace($Text, '\s+', ' ')

    # Preferred function style from the guide.
    $Text = [regex]::Replace($Text, '\b(SUM|COUNT|MIN|MAX|AVG|COALESCE|ROW_NUMBER)\s*\(', '$1 (', 'IgnoreCase')
    $Text = [regex]::Replace($Text, '\bOVER\s*\(', 'OVER (', 'IgnoreCase')
    $Text = [regex]::Replace($Text, '\bTOP\s+\(\s*(\d+)\s*\)', 'TOP ($1)', 'IgnoreCase')

    return $Text.Trim()
}

function Convert-SqlKeywordsToUpper {
    param([string]$Text)

    $keywords = @(
        'select', 'distinct', 'top', 'from', 'where', 'and', 'or', 'not', 'in', 'exists',
        'inner', 'left', 'right', 'full', 'outer', 'join', 'on',
        'group', 'by', 'having', 'order', 'asc', 'desc',
        'limit', 'fetch', 'first', 'rows', 'only',
        'with', 'ur', 'nc',
        'insert', 'into', 'values',
        'update', 'set',
        'delete',
        'merge', 'using', 'matched', 'when', 'then',
        'case', 'else', 'end', 'as',
        'is', 'null',
        'current', 'timestamp', 'user',
        'row_number', 'over', 'partition',
        'sum', 'count', 'min', 'max', 'avg', 'coalesce',
        'union','all','except','intersect'
    )

    foreach ($kw in $keywords) {
        $Text = [regex]::Replace(
            $Text,
            '\b' + [regex]::Escape($kw) + '\b',
            { param($m) $m.Value.ToUpperInvariant() },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    return $Text
}

# ======================================================================
# Scanner helpers
# ======================================================================
# These helpers split SQL only at top-level separators. They avoid commas,
# AND, OR, and keywords inside parentheses and CASE blocks.
# ======================================================================

function Split-TopLevelComma {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]

    $start = 0
    $depth = 0
    $caseDepth = 0
    $i = 0

    while ($i -lt $Text.Length) {
        $remaining = $Text.Substring($i)

        if ([regex]::IsMatch($remaining, '^\bCASE\b', 'IgnoreCase')) {
            $caseDepth++
            $i += 4
            continue
        }

        if ([regex]::IsMatch($remaining, '^\bEND\b', 'IgnoreCase')) {
            if ($caseDepth -gt 0) { $caseDepth-- }
            $i += 3
            continue
        }

        $ch = $Text[$i]

        if ($ch -eq '(') {
            $depth++
        }
        elseif ($ch -eq ')') {
            if ($depth -gt 0) { $depth-- }
        }
        elseif ($ch -eq ',' -and $depth -eq 0 -and $caseDepth -eq 0) {
            $part = $Text.Substring($start, $i - $start).Trim()
            if ($part.Length -gt 0) { $items.Add($part) }
            $start = $i + 1
        }

        $i++
    }

    $tail = $Text.Substring($start).Trim()
    if ($tail.Length -gt 0) { $items.Add($tail) }

    return $items
}

function Find-TopLevelKeyword {
    param(
        [string]$Text,
        [string]$Pattern,
        [int]$StartAt = 0
    )

    $depth = 0
    $caseDepth = 0

    for ($i = $StartAt; $i -lt $Text.Length; $i++) {
        $remaining = $Text.Substring($i)

        if ([regex]::IsMatch($remaining, '^\bCASE\b', 'IgnoreCase')) {
            $caseDepth++
            $i += 3
            continue
        }

        if ([regex]::IsMatch($remaining, '^\bEND\b', 'IgnoreCase')) {
            if ($caseDepth -gt 0) { $caseDepth-- }
            $i += 2
            continue
        }

        $ch = $Text[$i]

        if ($ch -eq '(') {
            $depth++
        }
        elseif ($ch -eq ')') {
            if ($depth -gt 0) { $depth-- }
        }

        if ($depth -eq 0 -and $caseDepth -eq 0) {
            $m = [regex]::Match(
                $Text.Substring($i),
                '^' + $Pattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($m.Success) {
                return $i
            }
        }
    }

    return -1
}

function Split-SqlStatements {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]

    $start = 0
    $depth = 0

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]

        if ($ch -eq '(') {
            $depth++
        }
        elseif ($ch -eq ')') {
            if ($depth -gt 0) { $depth-- }
        }
        elseif ($ch -eq ';' -and $depth -eq 0) {
            $part = $Text.Substring($start, $i - $start).Trim()
            if ($part.Length -gt 0) { $items.Add($part) }
            $start = $i + 1
        }
    }

    $tail = $Text.Substring($start).Trim()
    if ($tail.Length -gt 0) { $items.Add($tail) }

    return $items
}

function Split-TopLevelLogical {
    param([string]$Text)

    $parts = New-Object System.Collections.Generic.List[object]

    $start = 0
    $depth = 0
    $i = 0
    $currentConnector = ""

    while ($i -lt $Text.Length) {
        $ch = $Text[$i]

        if ($ch -eq '(') {
            $depth++
            $i++
            continue
        }

        if ($ch -eq ')') {
            if ($depth -gt 0) { $depth-- }
            $i++
            continue
        }

        if ($depth -eq 0) {
            $remaining = $Text.Substring($i)
            $m = [regex]::Match($remaining, '^\s+(AND|OR)\s+', 'IgnoreCase')

            if ($m.Success) {
                $condition = $Text.Substring($start, $i - $start).Trim()

                if ($condition.Length -gt 0) {
                    $parts.Add([pscustomobject]@{
                            Connector = $currentConnector
                            Text      = $condition
                        })
                }

                $currentConnector = $m.Groups[1].Value.ToUpperInvariant()
                $i += $m.Length
                $start = $i
                continue
            }
        }

        $i++
    }

    $tail = $Text.Substring($start).Trim()
    if ($tail.Length -gt 0) {
        $parts.Add([pscustomobject]@{
                Connector = $currentConnector
                Text      = $tail
            })
    }

    return $parts
}

# ======================================================================
# SELECT expression formatters
# ======================================================================

function Format-CaseExpression {
    param(
        [string]$Expression,
        [string]$Indent
    )

    # ------------------------------------------------------------------
    # Formats CASE expressions inside a SELECT list.
    #
    # Important:
    #   $Indent may contain "SELECT " when the CASE is the first selected
    #   expression:
    #
    #       SELECT CASE
    #                WHEN ...
    #
    #   Only the first CASE line should use the full prefix.
    #   The following WHEN / ELSE / END lines must align using spaces of
    #   the same length, not repeat "SELECT".
    # ------------------------------------------------------------------

    $lines = New-Object System.Collections.Generic.List[string]

    $expr = $Expression.Trim()
    $expr = [regex]::Replace($expr, '\bCASE\b', "`nCASE", 'IgnoreCase')
    $expr = [regex]::Replace($expr, '\bWHEN\b', "`nWHEN", 'IgnoreCase')
    $expr = [regex]::Replace($expr, '\bELSE\b', "`nELSE", 'IgnoreCase')
    $expr = [regex]::Replace($expr, '\bEND\b', "`nEND", 'IgnoreCase')

    $rawLines = $expr -split "`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" }

    $continuationIndent = ' ' * $Indent.Length

    foreach ($line in $rawLines) {
        if ($line -match '^CASE\b') {
            $lines.Add($Indent + $line)
        }
        elseif ($line -match '^WHEN\b') {
            $lines.Add($continuationIndent + '  ' + $line)
        }
        elseif ($line -match '^ELSE\b') {
            $lines.Add($continuationIndent + '  ' + $line)
        }
        elseif ($line -match '^END\b') {
            $lines.Add($continuationIndent + $line)
        }
        else {
            $lines.Add($continuationIndent + $line)
        }
    }

    return $lines
}

function Format-RowNumberExpression {
    param(
        [string]$Expression,
        [string]$Indent
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $m = [regex]::Match(
        $Expression.Trim(),
        '^ROW_NUMBER\s*\(\s*\)\s+OVER\s*\(\s*PARTITION\s+BY\s+(.+?)\s+ORDER\s+BY\s+(.+?)\s*\)\s+AS\s+(.+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($m.Success) {
        $partitionBy = $m.Groups[1].Value.Trim()
        $orderBy = $m.Groups[2].Value.Trim()
        $alias = $m.Groups[3].Value.Trim()

        $lines.Add($Indent + 'ROW_NUMBER ()')
        $lines.Add($Indent + '      OVER (PARTITION BY ' + $partitionBy)
        $lines.Add($Indent + '                ORDER BY ' + $orderBy + ') AS ' + $alias)

        return $lines
    }

    $lines.Add($Indent + $Expression.Trim())
    return $lines
}

function Format-SelectList {
    param(
        [string]$SelectKeywordWithPrefix,
        [string]$ColumnText
    )

    $lines = New-Object System.Collections.Generic.List[string]

    # ------------------------------------------------------------------
    # Comment handling inside SELECT lists
    # ------------------------------------------------------------------
    # __SQLFMT_EOL__ is inserted after line comments and standalone block
    # comments before whitespace normalization.
    #
    # In a SELECT list, that marker means:
    #   "the next thing is a new SELECT-list item"
    #
    # We convert it to a comma separator before splitting the SELECT list.
    # This makes comments behave like simple SELECT-list items:
    #
    #   A,
    #   -- comment
    #   B,
    #   C, -- inline comment
    #   D
    #
    # becomes items:
    #   A | SLCOM | B | C | LCOM | D
    #
    # Then:
    #   - SLCOM/BCOM items are printed as their own aligned line.
    #   - LCOM items are appended to the previous line.
    # ------------------------------------------------------------------
    $ColumnText = [regex]::Replace($ColumnText, '\s*__SQLFMT_EOL__\s*', ', ')

    $columns = @(Split-TopLevelComma $ColumnText)
    $firstPrefix = $SelectKeywordWithPrefix + ' '
    $contPrefix  = ' ' * $firstPrefix.Length

    # Do not immediately return for a single SELECT expression.
    # A single expression can still be complex, for example:
    #
    #   SELECT CASE WHEN ... THEN ... ELSE ... END AS SEGMENT_CODE
    #
    # Simple single-column SELECTs are handled correctly by the loop below.

    for ($i = 0; $i -lt $columns.Count; $i++) {
        $col = $columns[$i].Trim()

        # A normal item receives a comma when another item follows.
        # Comment items themselves do not use this suffix because they are
        # handled in their own branches below.
        $suffix = if ($i -lt $columns.Count - 1) { ',' } else { '' }

        # Inline line comments belong to the previous SELECT-list item.
        #
        # Input:
        #   G, -- inline comment
        #   H
        #
        # Output:
        #   G, -- inline comment
        #   H
        if ($col -match '^__SQLFMT_LCOM_\d+__$') {
            if ($lines.Count -gt 0) {
                $lines[$lines.Count - 1] = $lines[$lines.Count - 1] + ' ' + $col
            }
            continue
        }

        # Standalone line comments behave like a SELECT-list item with no comma.
        if ($col -match '^__SQLFMT_SLCOM_\d+__$') {
            if ($i -eq 0) {
                $lines.Add($firstPrefix + $col)
            }
            else {
                $lines.Add($contPrefix + $col)
            }
            continue
        }

        # Standalone block comments also behave like SELECT-list items.
        #
        # Inline block comments, e.g. "B /**/", are part of $col and therefore
        # pass through the normal expression branch unchanged.
        if ($col -match '^__SQLFMT_BCOM_\d+__$') {
            if ($i -eq 0) {
                $lines.Add($firstPrefix + $col)
            }
            else {
                $lines.Add($contPrefix + $col)
            }
            continue
        }

        if ($i -eq 0) {
            $linePrefix = $firstPrefix
        }
        else {
            $linePrefix = $contPrefix
        }

        if ($col -match '^\s*ROW_NUMBER\b') {
            $rnLines = Format-RowNumberExpression -Expression $col -Indent $linePrefix

            for ($j = 0; $j -lt $rnLines.Count; $j++) {
                if ($j -eq $rnLines.Count - 1) {
                    $lines.Add($rnLines[$j] + $suffix)
                }
                else {
                    $lines.Add($rnLines[$j])
                }
            }
        }
        elseif ($col -match '\bCASE\b') {
            $caseLines = Format-CaseExpression -Expression $col -Indent $linePrefix

            for ($j = 0; $j -lt $caseLines.Count; $j++) {
                if ($j -eq $caseLines.Count - 1) {
                    $lines.Add($caseLines[$j] + $suffix)
                }
                else {
                    $lines.Add($caseLines[$j])
                }
            }
        }
        else {
            $lines.Add($linePrefix + $col + $suffix)
        }
    }

    return $lines
}

# ======================================================================
# Inline subquery formatter
# ======================================================================
# Purpose:
#   Formats SELECT statements that appear inside predicates, for example:
#
#       EXISTS (SELECT 1 FROM CUSTOMER C WHERE C.ID = X.ID)
#
#   into:
#
#       EXISTS (SELECT 1
#                 FROM CUSTOMER C
#                WHERE C.ID = X.ID)
#
# Design note:
#   This function does not create a separate "subquery formatter".
#   It delegates the inner SELECT to the same Format-SelectStatement function
#   used by normal SELECTs, CTEs, and MERGE source SELECTs.
#
#   The only special thing here is the OpeningPrefix:
#
#       "EXISTS ("
#       "COL IN ("
#
#   That prefix length shifts the inner SELECT block to the correct column.
# ======================================================================

function Format-InlineSubqueries {
    param([string]$Text)

    # ------------------------------------------------------------------
    # Formats inline SELECTs that appear inside predicates.
    #
    # Examples:
    #
    #   EXISTS (SELECT 1 FROM T WHERE ...)
    #
    # becomes:
    #
    #   EXISTS (SELECT 1
    #             FROM T
    #            WHERE ...)
    #
    #   COL IN (SELECT X FROM T WHERE ...)
    #
    # becomes:
    #
    #   COL IN (SELECT X
    #             FROM T
    #            WHERE ...)
    #
    # Important:
    #   This function does not create a separate subquery formatter.
    #   It delegates to Format-SelectStatement with an OpeningPrefix.
    # ------------------------------------------------------------------

    $result = $Text
    $searchStart = 0

    while ($searchStart -lt $result.Length) {
        $match = [regex]::Match(
            $result.Substring($searchStart),
            '(EXISTS\s*\(\s*SELECT\b|[A-Z0-9_\.]+\s+IN\s*\(\s*SELECT\b)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $match.Success) {
            break
        }

        $absoluteMatchIndex = $searchStart + $match.Index
        $openParenIndex = $result.IndexOf('(', $absoluteMatchIndex)

        if ($openParenIndex -lt 0) {
            break
        }

        # Find the matching closing parenthesis for this subquery.
        # This is safer than regex-only matching because the subquery may
        # contain nested parentheses in functions or predicates.
        $depth = 0
        $closeParenIndex = -1

        for ($i = $openParenIndex; $i -lt $result.Length; $i++) {
            if ($result[$i] -eq '(') {
                $depth++
            }
            elseif ($result[$i] -eq ')') {
                $depth--

                if ($depth -eq 0) {
                    $closeParenIndex = $i
                    break
                }
            }
        }

        if ($closeParenIndex -lt 0) {
            break
        }

        $prefix = $result.Substring($absoluteMatchIndex, $openParenIndex - $absoluteMatchIndex + 1)
        $innerSql = $result.Substring($openParenIndex + 1, $closeParenIndex - $openParenIndex - 1).Trim()

        if ($innerSql -match '^SELECT\b') {
            # The inline SELECT formatter receives only the local prefix:
            #
            #   EXISTS (
            #   C.COL IN (
            #
            # That is correct for the first line because the text before the match
            # remains in the predicate. However, continuation lines also need to know
            # where the inline subquery started on the current physical line.
            #
            # Example:
            #
            #   AND EXISTS (SELECT 1
            #                 FROM CUSTOMER C
            #                WHERE ...)
            #
            # The "FROM" line must be shifted by the column where EXISTS started.
            $lineStartIndex = $result.LastIndexOf("`n", [Math]::Max(0, $absoluteMatchIndex - 1))

            if ($lineStartIndex -lt 0) {
                $subqueryStartColumn = $absoluteMatchIndex
            }
            else {
                $subqueryStartColumn = $absoluteMatchIndex - $lineStartIndex - 1
            }

            $formattedLines = @(Format-SelectStatement -Sql $innerSql -OpeningPrefix $prefix)

            # Do not add any extra indentation here.
            #
            # Format-SelectStatement already uses OpeningPrefix to align the inner
            # SELECT block correctly:
            #
            #   EXISTS (SELECT 1
            #             FROM T
            #            WHERE ...)
            #
            # Adding the outer column again causes double-indentation, so we leave the
            # formatted lines exactly as returned.

            $formattedText = ($formattedLines -join $script:NewLine) + ')'
        
            $result =
            $result.Substring(0, $absoluteMatchIndex) +
            $formattedText +
            $result.Substring($closeParenIndex + 1)
        
            $searchStart = $absoluteMatchIndex + $formattedText.Length
        }
        else {
            $searchStart = $closeParenIndex + 1
        }
    }

    return $result
}

function Format-InlineSubqueriesInLine {
    param([string]$Line)

    # ------------------------------------------------------------------
    # Formats inline subqueries inside a final rendered predicate line.
    #
    # Important design rule:
    #   Do NOT add the absolute column again.
    #
    # Why:
    #   Format-SelectStatement already aligns continuation lines using the
    #   OpeningPrefix we give it.
    #
    # Example:
    #   OR C.CUSTOMER_ID IN (SELECT P.CUSTOMER_ID FROM CUSTOMER_PREFERENCE P WHERE ...)
    #
    # We pass this as OpeningPrefix:
    #   "OR C.CUSTOMER_ID IN ("
    #
    # So Format-SelectStatement already knows to produce:
    #   OR C.CUSTOMER_ID IN (SELECT P.CUSTOMER_ID
    #                          FROM CUSTOMER_PREFERENCE P
    #                         WHERE ...)
    #
    # Adding absoluteMatchIndex again would double-indent the FROM/WHERE lines.
    # ------------------------------------------------------------------

    $result = $Line
    $searchStart = 0

    while ($searchStart -lt $result.Length) {
        $match = [regex]::Match(
            $result.Substring($searchStart),
            '(EXISTS\s*\(\s*SELECT\b|[A-Z0-9_\.]+\s+IN\s*\(\s*SELECT\b)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $match.Success) {
            break
        }

        $absoluteMatchIndex = $searchStart + $match.Index
        $openParenIndex = $result.IndexOf('(', $absoluteMatchIndex)

        if ($openParenIndex -lt 0) {
            break
        }

        # Find the matching closing parenthesis for the inline SELECT.
        # This safely handles nested function calls or predicates inside it.
        $depth = 0
        $closeParenIndex = -1

        for ($i = $openParenIndex; $i -lt $result.Length; $i++) {
            if ($result[$i] -eq '(') {
                $depth++
            }
            elseif ($result[$i] -eq ')') {
                $depth--

                if ($depth -eq 0) {
                    $closeParenIndex = $i
                    break
                }
            }
        }

        if ($closeParenIndex -lt 0) {
            break
        }

        # Prefix from the current line, for example:
        #   EXISTS (
        #   C.CUSTOMER_ID IN (
        #
        # This is the local prefix that controls the subquery alignment.
        $prefix = $result.Substring($absoluteMatchIndex, $openParenIndex - $absoluteMatchIndex + 1)

        $innerSql = $result.Substring(
            $openParenIndex + 1,
            $closeParenIndex - $openParenIndex - 1
        ).Trim()

        if ($innerSql -match '^SELECT\b') {
            $formattedLines = @(Format-SelectStatement -Sql $innerSql -OpeningPrefix $prefix)

            # No extra indentation here.
            # Format-SelectStatement already uses OpeningPrefix to align:
            #
            #   EXISTS (SELECT ...
            #             FROM ...
            #            WHERE ...)
            $formattedText = ($formattedLines -join $script:NewLine) + ')'

            $result =
            $result.Substring(0, $absoluteMatchIndex) +
            $formattedText +
            $result.Substring($closeParenIndex + 1)

            $searchStart = $absoluteMatchIndex + $formattedText.Length
        }
        else {
            $searchStart = $closeParenIndex + 1
        }
    }

    return $result
}

# ======================================================================
# SELECT clause formatting
# ======================================================================

function Split-SelectClauses {
    param([string]$Sql)

    $patterns = [ordered]@{
        From    = '\bFROM\b'
        Where   = '\bWHERE\b'
        GroupBy = '\bGROUP\s+BY\b'
        Having  = '\bHAVING\b'
        OrderBy = '\bORDER\s+BY\b'
        Fetch   = '\bFETCH\s+FIRST\b'
        Limit   = '\bLIMIT\b'
        WithIso = '\bWITH\s+(UR|NC)\b'
    }

    $positions = @{}

    foreach ($name in $patterns.Keys) {
        $idx = Find-TopLevelKeyword -Text $Sql -Pattern $patterns[$name]
        if ($idx -ge 0) {
            $positions[$name] = $idx
        }
    }

    $ordered = $positions.GetEnumerator() | Sort-Object Value
    $result = [ordered]@{}

    if ($ordered.Count -eq 0) {
        $result.Select = $Sql
        return $result
    }

    $result.Select = $Sql.Substring(0, $ordered[0].Value).Trim()

    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $name = $ordered[$i].Key
        $start = $ordered[$i].Value

        if ($i + 1 -lt $ordered.Count) {
            $end = $ordered[$i + 1].Value
        }
        else {
            $end = $Sql.Length
        }

        $result[$name] = $Sql.Substring($start, $end - $start).Trim()
    }

    return $result
}

function Add-SelectClauseLine {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$OpeningPrefix,
        [string]$Keyword,
        [string]$Text
    )

    # Clause alignment is local to the SELECT block.
    # OpeningPrefix shifts the whole SELECT block to the right.
    #
    # Normal:
    # SELECT ...
    #   FROM ...
    #  WHERE ...
    #
    # CTE:
    # WITH X AS ( SELECT ...
    #               FROM ...
    #              WHERE ...

    $base = ' ' * $OpeningPrefix.Length

    switch ($Keyword) {
        'FROM' {
            $Lines.Add($base + '  FROM ' + $Text)
        }
        'WHERE' {
            $Lines.Add($base + ' WHERE ' + $Text)
        }
        'GROUP BY' {
            $Lines.Add($base + ' GROUP BY ' + $Text)
        }
        'HAVING' {
            $Lines.Add($base + ' HAVING ' + $Text)
        }
        'ORDER BY' {
            $Lines.Add($base + ' ORDER BY ' + $Text)
        }
        'FETCH FIRST' {
            $Lines.Add($base + ' FETCH FIRST ' + $Text)
        }
        'LIMIT' {
            $Lines.Add($base + ' LIMIT ' + $Text)
        }
        'WITH' {
            $Lines.Add($base + '  WITH ' + $Text)
        }
    }
}

function Format-PredicatePart {
    param(
        [string]$LinePrefix,
        [string]$ConditionText
    )

    # ------------------------------------------------------------------
    # Formats one predicate part.
    #
    # Simple rule:
    #   If the predicate contains:
    #
    #       EXISTS (SELECT ...)
    #       X IN (SELECT ...)
    #
    #   then format the inner SELECT exactly like every other SELECT.
    #
    # Important:
    #   The indentation prefix must be calculated from the CURRENT LINE only.
    #
    # Why:
    #   In a condition like this:
    #
    #       AND (   A = 1
    #            OR B IN (SELECT ...))
    #
    #   the text before "B IN (" contains a previous line.
    #   We must NOT count the previous line's characters.
    #   We only count:
    #
    #            OR B IN (
    #
    # ------------------------------------------------------------------

    $lines = New-Object System.Collections.Generic.List[string]
    $condition = $ConditionText.Trim()

    $match = [regex]::Match(
        $condition,
        '(EXISTS\s*\(\s*SELECT\b|[A-Z0-9_\.]+\s+IN\s*\(\s*SELECT\b)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {
        $lines.Add($LinePrefix + $condition)
        return $lines
    }

    $matchIndex = $match.Index
    $openParenIndex = $condition.IndexOf('(', $matchIndex)

    if ($openParenIndex -lt 0) {
        $lines.Add($LinePrefix + $condition)
        return $lines
    }

    # Find the closing parenthesis of the inline SELECT.
    $depth = 0
    $closeParenIndex = -1

    for ($i = $openParenIndex; $i -lt $condition.Length; $i++) {
        if ($condition[$i] -eq '(') {
            $depth++
        }
        elseif ($condition[$i] -eq ')') {
            $depth--

            if ($depth -eq 0) {
                $closeParenIndex = $i
                break
            }
        }
    }

    if ($closeParenIndex -lt 0) {
        $lines.Add($LinePrefix + $condition)
        return $lines
    }

    $beforeInline = $condition.Substring(0, $matchIndex)
    $inlinePrefix = $condition.Substring($matchIndex, $openParenIndex - $matchIndex + 1)
    $innerSql = $condition.Substring($openParenIndex + 1, $closeParenIndex - $openParenIndex - 1).Trim()
    $afterInline = $condition.Substring($closeParenIndex + 1)

    if ($innerSql -notmatch '^SELECT\b') {
        $lines.Add($LinePrefix + $condition)
        return $lines
    }

    # Build the visible text that appears before the inline SELECT.
    $visibleBeforeInline = $LinePrefix + $beforeInline

    # The bug was here:
    #   We were using the whole $visibleBeforeInline as part of the SELECT prefix.
    #
    # Instead, split it at the LAST newline.
    # Everything before the last newline is already-rendered text.
    # Only the current line prefix should control the inner SELECT alignment.
    $lastNewLine = $visibleBeforeInline.LastIndexOf("`n")

    if ($lastNewLine -ge 0) {
        $alreadyRenderedText = $visibleBeforeInline.Substring(0, $lastNewLine + 1)
        $currentLinePrefix = $visibleBeforeInline.Substring($lastNewLine + 1)
    }
    else {
        $alreadyRenderedText = ""
        $currentLinePrefix = $visibleBeforeInline
    }

    # This is the actual prefix for the inner SELECT.
    # Example:
    #        OR C.CUSTOMER_ID IN (
    #
    # The SELECT formatter will then align FROM / WHERE based only on this.
    $openingPrefix = $currentLinePrefix + $inlinePrefix

    $formatted = @(Format-SelectStatement -Sql $innerSql -OpeningPrefix $openingPrefix)

    if ($formatted.Count -gt 0) {
        $formatted[$formatted.Count - 1] = $formatted[$formatted.Count - 1] + ')' + $afterInline
    }

    # Put back the already-rendered previous part only once.
    if ($formatted.Count -gt 0) {
        $formatted[0] = $alreadyRenderedText + $formatted[0]
    }

    foreach ($line in $formatted) {
        $lines.Add($line)
    }

    return $lines
}

function Format-PredicateLines {
    param(
        [string]$OpeningPrefix,
        [string]$Keyword,
        [string]$Predicate
    )

    $lines = New-Object System.Collections.Generic.List[string]

    $base = ' ' * $OpeningPrefix.Length

    # Before deciding whether the predicate fits on one line, format any
    # nested SELECTs inside EXISTS (...) or IN (...). This keeps the same
    # unified SELECT formatting everywhere.
    # Do not format inline subqueries here.
    # At this point we do not yet know their final rendered column.
    # Inline subqueries are formatted later per final predicate line by
    # Format-InlineSubqueriesInLine.
    # $Predicate = Format-InlineSubqueries $Predicate

    # Format long parenthesized OR groups inside predicates.
    #
    # Example:
    #   AND (A = 1 OR B IN (SELECT ...))
    #
    # becomes:
    #   AND (   A = 1
    #        OR B IN (SELECT ...))
    #
    # This is intentionally conservative: it only changes groups that contain
    # a top-level OR inside the parentheses.
    $Predicate = [regex]::Replace(
        $Predicate,
        '\(\s*(.+?)\s+OR\s+(.+?)\s*\)',
        {
            param($m)

            $leftSide = $m.Groups[1].Value.Trim()
            $rightSide = $m.Groups[2].Value.Trim()

            if (($leftSide.Length + $rightSide.Length + 6) -lt 80) {
                return $m.Value
            }

            return "(   $leftSide" + $script:NewLine + "        OR $rightSide)"
        },
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($Keyword -eq 'WHERE') {
        $firstPrefix = $base + ' WHERE '
        $contAnd = $base + '   AND '
        $contOr = $base + '    OR '
    }
    elseif ($Keyword -eq 'HAVING') {
        # HAVING is six characters, same width as SELECT / WHERE.
        # It should align like:
        #
        #  WHERE ...
        # HAVING ...
        #
        # inside the same local SELECT block.
        $firstPrefix = $base + 'HAVING '
        $contAnd = $base + '   AND '
        $contOr = $base + '    OR '
    }
    else {
        $firstPrefix = $base + ' ' + $Keyword + ' '
        $contAnd = $base + ' AND '
        $contOr = $base + '  OR '
    }

    if (($firstPrefix.Length + $Predicate.Length) -le $script:MaxLineLength) {
        foreach ($line in (Format-PredicatePart -LinePrefix $firstPrefix -ConditionText $Predicate)) {
            $lines.Add($line)
        }

        return $lines
    }

    $parts = @(Split-TopLevelLogical $Predicate)

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $connector = $parts[$i].Connector
        $text = $parts[$i].Text

        if ($i -eq 0) {
            foreach ($line in (Format-PredicatePart -LinePrefix $firstPrefix -ConditionText $text)) {
                $lines.Add($line)
            }
        }
        elseif ($connector -eq 'AND') {
            foreach ($line in (Format-PredicatePart -LinePrefix $contAnd -ConditionText $text)) {
                $lines.Add($line)
            }
        }
        elseif ($connector -eq 'OR') {
            foreach ($line in (Format-PredicatePart -LinePrefix $contOr -ConditionText $text)) {
                $lines.Add($line)
            }
        }
        else {
            foreach ($line in (Format-PredicatePart -LinePrefix $firstPrefix -ConditionText $text)) {
                $lines.Add($line)
            }
        }
    }

    # Predicate lines are already fully formatted before being added.
    # Do not re-process subqueries here, because that causes double indentation.
    return $lines
}

function Format-FromAndJoins {
    param(
        [string]$OpeningPrefix,
        [string]$FromClause
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $base = ' ' * $OpeningPrefix.Length

    $text = $FromClause.Trim()
    $text = [regex]::Replace(
        $text,
        '\s+(INNER\s+JOIN|LEFT\s+JOIN|RIGHT\s+JOIN|FULL\s+JOIN)\s+',
        "`n`$1 ",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $parts = $text -split "`n"

    foreach ($part in $parts) {
        $t = $part.Trim()

        if ($t -match '^FROM\b') {
            $lines.Add($base + '  ' + $t)
        }
        elseif ($t -match '^INNER JOIN\b') {
            $lines.Add($base + ' ' + $t)
        }
        elseif ($t -match '^LEFT JOIN\b') {
            $lines.Add($base + '  ' + $t)
        }
        elseif ($t -match '^RIGHT JOIN\b') {
            $lines.Add($base + ' ' + $t)
        }
        elseif ($t -match '^FULL JOIN\b') {
            $lines.Add($base + '  ' + $t)
        }
        else {
            $lines.Add($base + '  ' + $t)
        }
    }

    return $lines
}

function Format-SelectStatement {
    param(
        [string]$Sql,
        [string]$OpeningPrefix = ""
    )

    $out = New-Object System.Collections.Generic.List[string]

    $Sql = Normalize-SqlWhitespace $Sql
    $Sql = Convert-SqlKeywordsToUpper $Sql

    $clauses = Split-SelectClauses $Sql
    $selectPart = $clauses.Select.Trim()

    if ($selectPart -match '^SELECT\s+DISTINCT\s+') {
        $selectKeyword = $OpeningPrefix + 'SELECT DISTINCT'
        $columnText = $selectPart -replace '^SELECT\s+DISTINCT\s+', ''
    }
    else {
        $selectKeyword = $OpeningPrefix + 'SELECT'
        $columnText = $selectPart -replace '^SELECT\s+', ''
    }

    foreach ($line in (Format-SelectList -SelectKeywordWithPrefix $selectKeyword -ColumnText $columnText)) {
        $out.Add($line)
    }

    if ($clauses.Contains('From')) {
        foreach ($line in (Format-FromAndJoins -OpeningPrefix $OpeningPrefix -FromClause $clauses.From)) {
            $out.Add($line)
        }
    }

    if ($clauses.Contains('Where')) {
        $predicate = ($clauses.Where -replace '^WHERE\s+', '').Trim()

        foreach ($line in (Format-PredicateLines -OpeningPrefix $OpeningPrefix -Keyword 'WHERE' -Predicate $predicate)) {
            $out.Add($line)
        }
    }

	if ($clauses.Contains('GroupBy')) {
		$groupText = ($clauses.GroupBy -replace '^GROUP\s+BY\s+', '').Trim()
		$base = ' ' * $OpeningPrefix.Length
		$oneLine = $base + ' GROUP BY ' + $groupText
	
		# Keep GROUP BY on one line when it fits inside the configured threshold.
		# Only split by commas when the full line would pass MaxLineLength.
		if ($oneLine.Length -le $script:MaxLineLength) {
			$out.Add($oneLine)
		}
		else {
			$items = @(Split-TopLevelComma $groupText)
	
			for ($i = 0; $i -lt $items.Count; $i++) {
				$suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
	
				if ($i -eq 0) {
					$out.Add($base + ' GROUP BY ' + $items[$i] + $suffix)
				}
				else {
					$out.Add($base + '          ' + $items[$i] + $suffix)
				}
			}
		}
	}

    if ($clauses.Contains('Having')) {
        $havingText = ($clauses.Having -replace '^HAVING\s+', '').Trim()

        foreach ($line in (Format-PredicateLines -OpeningPrefix $OpeningPrefix -Keyword 'HAVING' -Predicate $havingText)) {
            $out.Add($line)
        }
    }

	if ($clauses.Contains('OrderBy')) {
		$orderText = ($clauses.OrderBy -replace '^ORDER\s+BY\s+', '').Trim()
		$base = ' ' * $OpeningPrefix.Length
		$oneLine = $base + ' ORDER BY ' + $orderText
	
		# Keep ORDER BY on one line when it fits inside the configured threshold.
		# Only split by commas when the full line would pass MaxLineLength.
		if ($oneLine.Length -le $script:MaxLineLength) {
			$out.Add($oneLine)
		}
		else {
			$items = @(Split-TopLevelComma $orderText)
	
			for ($i = 0; $i -lt $items.Count; $i++) {
				$suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
	
				if ($i -eq 0) {
					$out.Add($base + ' ORDER BY ' + $items[$i] + $suffix)
				}
				else {
					$out.Add($base + '          ' + $items[$i] + $suffix)
				}
			}
		}
	}

    if ($clauses.Contains('Fetch')) {
        $fetchText = ($clauses.Fetch -replace '^FETCH\s+FIRST\s+', '').Trim()
        Add-SelectClauseLine -Lines $out -OpeningPrefix $OpeningPrefix -Keyword 'FETCH FIRST' -Text $fetchText
    }

    if ($clauses.Contains('Limit')) {
        $limitText = ($clauses.Limit -replace '^LIMIT\s+', '').Trim()
        Add-SelectClauseLine -Lines $out -OpeningPrefix $OpeningPrefix -Keyword 'LIMIT' -Text $limitText
    }

    if ($clauses.Contains('WithIso')) {
        $isoText = ($clauses.WithIso -replace '^WITH\s+', '').Trim()
        Add-SelectClauseLine -Lines $out -OpeningPrefix $OpeningPrefix -Keyword 'WITH' -Text $isoText
    }

    return $out
}

# ======================================================================
# Compound SELECT formatter
# ======================================================================
# Handles:
#
#   SELECT ...
#   UNION
#   SELECT ...
#
#   SELECT ...
#   UNION ALL
#   SELECT ...
#   EXCEPT
#   SELECT ...
#
#   SELECT ...
#   INTERSECT
#   SELECT ...
#
# Design rule:
#   Each SELECT part is formatted by the same unified SELECT formatter.
#   UNION / EXCEPT / INTERSECT are just separator lines at column 1.
# ======================================================================

function Split-CompoundSelect {
    param([string]$Sql)

    $parts = New-Object System.Collections.Generic.List[string]
    $ops   = New-Object System.Collections.Generic.List[string]

    $start = 0
    $depth = 0
    $caseDepth = 0
    $i = 0

    while ($i -lt $Sql.Length) {
        $remaining = $Sql.Substring($i)

        if ([regex]::IsMatch($remaining, '^\bCASE\b', 'IgnoreCase')) {
            $caseDepth++
            $i += 4
            continue
        }

        if ([regex]::IsMatch($remaining, '^\bEND\b', 'IgnoreCase')) {
            if ($caseDepth -gt 0) { $caseDepth-- }
            $i += 3
            continue
        }

        $ch = $Sql[$i]

        if ($ch -eq '(') {
            $depth++
            $i++
            continue
        }

        if ($ch -eq ')') {
            if ($depth -gt 0) { $depth-- }
            $i++
            continue
        }

        if ($depth -eq 0 -and $caseDepth -eq 0) {
            $m = [regex]::Match(
                $remaining,
                '^\s*\b(UNION\s+ALL|UNION|EXCEPT|INTERSECT)\b\s*',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($m.Success) {
                $part = $Sql.Substring($start, $i - $start).Trim()

                if ($part.Length -gt 0) {
                    $parts.Add($part)
                    $ops.Add(($m.Groups[1].Value -replace '\s+', ' ').ToUpperInvariant())
                }

                $i += $m.Length
                $start = $i
                continue
            }
        }

        $i++
    }

    $tail = $Sql.Substring($start).Trim()

    if ($tail.Length -gt 0) {
        $parts.Add($tail)
    }

    return [pscustomobject]@{
        Parts = $parts
        Operators = $ops
    }
}

function Format-CompoundSelectStatement {
    param(
        [string]$Sql,
        [string]$OpeningPrefix = ""
    )

    $Sql = Normalize-SqlWhitespace $Sql
    $Sql = Convert-SqlKeywordsToUpper $Sql

    $split = Split-CompoundSelect $Sql

    # No UNION / EXCEPT / INTERSECT found.
    if ($split.Operators.Count -eq 0) {
        return Format-SelectStatement -Sql $Sql -OpeningPrefix $OpeningPrefix
    }

    $out = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $split.Parts.Count; $i++) {
        $part = [string]$split.Parts[$i]

        # Only the first SELECT receives the external wrapper prefix.
        # Example:
        #   WITH X AS ( SELECT ...
        #
        # Later compound SELECT parts start normally at column 1:
        #   UNION ALL
        #   SELECT ...
        if ($i -eq 0) {
            $formattedPart = @(Format-SelectStatement -Sql $part -OpeningPrefix $OpeningPrefix)
        }
        else {
            $formattedPart = @(Format-SelectStatement -Sql $part -OpeningPrefix "")
        }

        foreach ($line in $formattedPart) {
            $out.Add($line)
        }

        if ($i -lt $split.Operators.Count) {
            $out.Add($split.Operators[$i])
        }
    }

    return $out
}

# ======================================================================
# WITH formatter
# ======================================================================
# This is intentionally small now.
# It does not format CTE SELECTs itself.
# It only calculates the CTE prefix and delegates to Format-SelectStatement.
# ======================================================================

function Format-WithStatement {
    param([string]$Sql)

    $Sql = Normalize-SqlWhitespace $Sql
    $Sql = Convert-SqlKeywordsToUpper $Sql

    $out = New-Object System.Collections.Generic.List[string]

    $body = $Sql -replace '^WITH\s+', ''
    $pos = 0
    $cteIndex = 0

    while ($pos -lt $body.Length) {
        $m = [regex]::Match($body.Substring($pos), '^\s*([A-Z0-9_]+)\s+AS\s*\(', 'IgnoreCase')

        if (-not $m.Success) {
            break
        }

        $cteName = $m.Groups[1].Value
        $openPos = $pos + $m.Index + $m.Length - 1

        $depth = 0
        $closePos = -1

        for ($i = $openPos; $i -lt $body.Length; $i++) {
            if ($body[$i] -eq '(') {
                $depth++
            }
            elseif ($body[$i] -eq ')') {
                $depth--
                if ($depth -eq 0) {
                    $closePos = $i
                    break
                }
            }
        }

        if ($closePos -lt 0) {
            break
        }

        $innerSql = $body.Substring($openPos + 1, $closePos - $openPos - 1).Trim()

        if ($cteIndex -eq 0) {
            $prefix = "WITH $cteName AS ( "
        }
        else {
            $prefix = "     $cteName AS ( "
        }

        $innerLines = Format-SelectStatement -Sql $innerSql -OpeningPrefix $prefix

        foreach ($line in $innerLines) {
            $out.Add($line)
        }

        $next = $closePos + 1
        while ($next -lt $body.Length -and [char]::IsWhiteSpace($body[$next])) {
            $next++
        }

        if ($next -lt $body.Length -and $body[$next] -eq ',') {
            $out[$out.Count - 1] = $out[$out.Count - 1] + ' ),'
            $pos = $next + 1
            $cteIndex++
        }
        else {
            $out[$out.Count - 1] = $out[$out.Count - 1] + ' )'
            $pos = $next
            break
        }
    }

    $rest = $body.Substring($pos).Trim()

    if ($rest.Length -gt 0) {
        foreach ($line in (Format-CompoundSelectStatement -Sql $rest -OpeningPrefix "")) {
            $out.Add($line)
        }
    }

    return $out
}

# ======================================================================
# INSERT formatter
# ======================================================================

function Format-InsertStatement {
    param([string]$Sql)

    $Sql = Normalize-SqlWhitespace $Sql
    $Sql = Convert-SqlKeywordsToUpper $Sql

    $out = New-Object System.Collections.Generic.List[string]

    if ($Sql.Length -le $script:MaxLineLength) {
        $out.Add($Sql)
        return $out
    }

    # --------------------------------------------------------------
    # INSERT INTO ... (columns) SELECT ...
    # --------------------------------------------------------------
    # This handles procedure/reporting patterns like:
    #
    #   INSERT INTO TARGET (COL1, COL2)
    #   SELECT ...
    #     FROM ...
    #
    # The INSERT column list is formatted here, then the SELECT portion
    # is delegated to the unified SELECT formatter.
    # --------------------------------------------------------------

    $insertSelectMatch = [regex]::Match(
        $Sql,
        '^INSERT\s+INTO\s+(.+?)\s*\((.+?)\)\s+(SELECT\b.+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($insertSelectMatch.Success) {
        $target     = $insertSelectMatch.Groups[1].Value.Trim()
        $columnText = $insertSelectMatch.Groups[2].Value.Trim()
        $selectSql  = $insertSelectMatch.Groups[3].Value.Trim()

        $columns = @(Split-TopLevelComma $columnText)
        $insertPrefix = 'INSERT INTO ' + $target + ' ( '

        for ($i = 0; $i -lt $columns.Count; $i++) {
            $suffix = if ($i -lt $columns.Count - 1) { ',' } else { ' )' }

            if ($i -eq 0) {
                $out.Add($insertPrefix + $columns[$i] + $suffix)
            }
            else {
                $out.Add((' ' * $insertPrefix.Length) + $columns[$i] + $suffix)
            }
        }

        foreach ($line in (Format-SelectStatement -Sql $selectSql -OpeningPrefix "")) {
            $out.Add($line)
        }

        return $out
    }

    $m = [regex]::Match(
        $Sql,
        '^INSERT\s+INTO\s+(.+?)\s*\((.+?)\)\s+VALUES\s*\((.+?)\)\s*(WITH\s+(UR|NC))?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $m.Success) {
        $out.Add($Sql)
        return $out
    }

    $target = $m.Groups[1].Value.Trim()
    $cols = @(Split-TopLevelComma $m.Groups[2].Value.Trim())
    $vals = @(Split-TopLevelComma $m.Groups[3].Value.Trim())
    $iso = $m.Groups[4].Value.Trim()

    $insertPrefix = 'INSERT INTO ' + $target + ' ( '

    for ($i = 0; $i -lt $cols.Count; $i++) {
        $suffix = if ($i -lt $cols.Count - 1) { ',' } else { ' )' }

        if ($i -eq 0) {
            $out.Add($insertPrefix + $cols[$i] + $suffix)
        }
        else {
            $out.Add((' ' * $insertPrefix.Length) + $cols[$i] + $suffix)
        }
    }

    for ($i = 0; $i -lt $vals.Count; $i++) {
        $suffix = if ($i -lt $vals.Count - 1) { ',' } else { ' )' }

        if ($i -eq 0) {
            $out.Add('VALUES ( ' + $vals[$i] + $suffix)
        }
        else {
            $out.Add('         ' + $vals[$i] + $suffix)
        }
    }

    if ($iso.Length -gt 0) {
        $out.Add('  ' + $iso)
    }

    return $out
}

# ======================================================================
# UPDATE formatter
# ======================================================================

function Format-UpdateStatement {
    param([string]$Sql)

    $Sql = Normalize-SqlWhitespace $Sql
    $Sql = Convert-SqlKeywordsToUpper $Sql

    $out = New-Object System.Collections.Generic.List[string]

    $m = [regex]::Match(
        $Sql,
        '^UPDATE\s+(.+?)\s+SET\s+(.+?)\s+WHERE\s+(.+?)(\s+WITH\s+(UR|NC))?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $m.Success) {
        $out.Add($Sql)
        return $out
    }

    $target = $m.Groups[1].Value.Trim()
    $setText = $m.Groups[2].Value.Trim()
    $whereText = $m.Groups[3].Value.Trim()
    $iso = $m.Groups[4].Value.Trim()

    $out.Add('UPDATE ' + $target)

    $assignments = @(Split-TopLevelComma $setText)

    for ($i = 0; $i -lt $assignments.Count; $i++) {
        $suffix = if ($i -lt $assignments.Count - 1) { ',' } else { '' }

        if ($i -eq 0) {
            $out.Add('   SET ' + $assignments[$i].Trim() + $suffix)
        }
        else {
            $out.Add('       ' + $assignments[$i].Trim() + $suffix)
        }
    }

    foreach ($line in (Format-PredicateLines -OpeningPrefix "" -Keyword 'WHERE' -Predicate $whereText)) {
        $out.Add($line)
    }

    if ($iso.Length -gt 0) {
        $out.Add('  ' + $iso.Trim())
    }

    return $out
}

# ======================================================================
# MERGE formatter
# ======================================================================
# MERGE still has special statement-level structure, but its source SELECT
# is now formatted by the same Format-SelectStatement function.
# ======================================================================

function Format-MergeStatement {
    param([string]$Sql)

    $Sql = Normalize-SqlWhitespace $Sql
    $Sql = Convert-SqlKeywordsToUpper $Sql

    $out = New-Object System.Collections.Generic.List[string]

    $m = [regex]::Match(
        $Sql,
        '^MERGE\s+INTO\s+(.+?)\s+USING\s*\((.+)\)\s+([A-Z0-9_]+)\s+ON\s*\((.+?)\)\s+WHEN\s+MATCHED\s+AND\s*\((.+?)\)\s+THEN\s+UPDATE\s+SET\s+(.+?)\s+WHEN\s+NOT\s+MATCHED\s+THEN\s+INSERT\s*\((.+?)\)\s+VALUES\s*\((.+?)\)\s*(WITH\s+(UR|NC))?$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $m.Success) {
        $out.Add($Sql)
        return $out
    }

    $target = $m.Groups[1].Value.Trim()
    $sourceSql = $m.Groups[2].Value.Trim()
    $sourceAlias = $m.Groups[3].Value.Trim()
    $onCond = $m.Groups[4].Value.Trim()
    $matchCond = $m.Groups[5].Value.Trim()
    $setText = $m.Groups[6].Value.Trim()
    $insertText = $m.Groups[7].Value.Trim()
    $valuesText = $m.Groups[8].Value.Trim()
    $iso = $m.Groups[9].Value.Trim()

    $out.Add(' MERGE INTO ' + $target)

    $sourceLines = Format-SelectStatement -Sql $sourceSql -OpeningPrefix ' USING ( '

    foreach ($line in $sourceLines) {
        $out.Add($line)
    }

    $onInline = ' ) ' + $sourceAlias + ' ON (' + $onCond + ')'

    if (($out[$out.Count - 1].Length + $onInline.Length) -le $script:MaxLineLength) {
        $out[$out.Count - 1] = $out[$out.Count - 1] + $onInline
    }
    else {
        $out[$out.Count - 1] = $out[$out.Count - 1] + ' ) ' + $sourceAlias

        $onLine = '        ON (' + $onCond + ')'
        if ($onLine.Length -le $script:MaxLineLength) {
            $out.Add($onLine)
        }
        else {
            $parts = @(Split-TopLevelLogical $onCond)
            for ($i = 0; $i -lt $parts.Count; $i++) {
                if ($i -eq 0) {
                    $out.Add('        ON (' + $parts[$i].Text)
                }
                elseif ($parts[$i].Connector -eq 'AND') {
                    $out.Add('       AND ' + $parts[$i].Text)
                }
                elseif ($parts[$i].Connector -eq 'OR') {
                    $out.Add('        OR ' + $parts[$i].Text)
                }
            }
            $out[$out.Count - 1] = $out[$out.Count - 1] + ')'
        }
    }

    $matchPrefix = '  WHEN MATCHED AND ( '

    if (($matchPrefix.Length + $matchCond.Length + ' ) THEN'.Length) -le $script:MaxLineLength) {
        $out.Add($matchPrefix + $matchCond + ' ) THEN')
    }
    else {
        $parts = @(Split-TopLevelLogical $matchCond)

        for ($i = 0; $i -lt $parts.Count; $i++) {
            if ($i -eq 0) {
                $out.Add('  WHEN MATCHED AND (    ' + $parts[$i].Text)
            }
            elseif ($parts[$i].Connector -eq 'OR') {
                $out.Add('                     OR ' + $parts[$i].Text)
            }
            elseif ($parts[$i].Connector -eq 'AND') {
                $out.Add('                    AND ' + $parts[$i].Text)
            }
        }

        $out[$out.Count - 1] = $out[$out.Count - 1] + ' ) THEN'
    }

    $out.Add('UPDATE ')

    $assignments = @(Split-TopLevelComma $setText)
    for ($i = 0; $i -lt $assignments.Count; $i++) {
        $suffix = if ($i -lt $assignments.Count - 1) { ',' } else { '' }

        if ($i -eq 0) {
            $out.Add('   SET ' + $assignments[$i] + $suffix)
        }
        else {
            $out.Add('       ' + $assignments[$i] + $suffix)
        }
    }

    $out.Add('  WHEN NOT MATCHED THEN')

    $insertCols = @(Split-TopLevelComma $insertText)
    for ($i = 0; $i -lt $insertCols.Count; $i++) {
        $suffix = if ($i -lt $insertCols.Count - 1) { ',' } else { ' )' }

        if ($i -eq 0) {
            $out.Add('INSERT ( ' + $insertCols[$i] + $suffix)
        }
        else {
            $out.Add('         ' + $insertCols[$i] + $suffix)
        }
    }

    $values = @(Split-TopLevelComma $valuesText)
    for ($i = 0; $i -lt $values.Count; $i++) {
        $suffix = if ($i -lt $values.Count - 1) { ',' } else { ' )' }

        if ($i -eq 0) {
            $out.Add('VALUES ( ' + $values[$i] + $suffix)
        }
        else {
            $out.Add('         ' + $values[$i] + $suffix)
        }
    }

    if ($iso.Length -gt 0) {
        $out.Add('  ' + $iso)
    }

    return $out
}

# ======================================================================
# Safe wrapping
# ======================================================================
# This layer only handles patterns we understand safely. It avoids breaking
# arbitrary SQL expressions incorrectly.
# ======================================================================

function Apply-SafeLineWrapping {
    param([System.Collections.Generic.List[string]]$Lines)

    $out = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ($line.Length -le $script:MaxLineLength) {
            $out.Add($line)
            continue
        }

        $m = [regex]::Match(
            $line,
            '^(\s*)ROW_NUMBER\s*\(\s*\)\s+OVER\s*\(PARTITION\s+BY\s+(.+?)\s+ORDER\s+BY\s+(.+?)\)\s+AS\s+(.+)$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($m.Success) {
            $indent = $m.Groups[1].Value
            $out.Add($indent + 'ROW_NUMBER ()')
            $out.Add($indent + '      OVER (PARTITION BY ' + $m.Groups[2].Value.Trim())
            $out.Add($indent + '                ORDER BY ' + $m.Groups[3].Value.Trim() + ') AS ' + $m.Groups[4].Value.Trim())
            continue
        }

        $out.Add($line)
    }

    return $out
}


# ======================================================================
# PROCEDURE formatter
# ======================================================================
# Simple procedure rule:
#   - Header / BEGIN / END stay at column 1.
#   - Everything inside BEGIN / END is just the normal SQL formatter output
#     shifted two spaces to the right.
#   - We do not invent different SQL formatting for procedures.
#   - We only add two leading spaces to the already formatted body lines.
# ======================================================================

function Format-ProcedureStatement {
    param([string]$Sql)

    $Sql = Normalize-SqlWhitespace $Sql
    $Sql = Convert-SqlKeywordsToUpper $Sql

    $out = New-Object System.Collections.Generic.List[string]

    $m = [regex]::Match(
        $Sql,
        '^(CREATE\s+OR\s+REPLACE\s+PROCEDURE\s+.+?)\s+LANGUAGE\s+SQL\s+BEGIN\s+(.+?)\s+END$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $m.Success) {
        $out.Add($Sql)
        return $out
    }

    $header = $m.Groups[1].Value.Trim()
    $body   = $m.Groups[2].Value.Trim()

    # Header formatting is just space-character movement:
    #   CREATE ... PROCEDURE NAME
    #   (
    #     IN PARAM TYPE
    #   )
    #   LANGUAGE SQL
    if ($header -match '^(CREATE\s+OR\s+REPLACE\s+PROCEDURE\s+[^\(]+)\s*\((.+)\)$') {
        $out.Add($matches[1].Trim())
        $out.Add('(')

        $params = @(Split-TopLevelComma $matches[2].Trim())
        for ($i = 0; $i -lt $params.Count; $i++) {
            $suffix = if ($i -lt $params.Count - 1) { ',' } else { '' }
            $out.Add('  ' + $params[$i].Trim() + $suffix)
        }

        $out.Add(')')
    }
    else {
        $out.Add($header)
    }

    $out.Add('LANGUAGE SQL')
    $out.Add('BEGIN')

    # Body formatting: format each body statement normally, then add exactly
    # two spaces in front. This is the simple rule we want for procedures.
    $bodyStatements = @(Split-SqlStatements $body)

    for ($statementIndex = 0; $statementIndex -lt $bodyStatements.Count; $statementIndex++) {
        $bodyStatement = $bodyStatements[$statementIndex]
        $formattedBody = @(Format-SqlStatement $bodyStatement)

        # Procedure body lines get two spaces.
        # The SQL statement itself keeps its normal internal alignment, just shifted
        # two columns to the right because it lives inside BEGIN / END.
        for ($i = 0; $i -lt $formattedBody.Count; $i++) {
            $line = [string]$formattedBody[$i]

            if (-not [string]::IsNullOrWhiteSpace($line)) {
                if ($i -eq $formattedBody.Count - 1 -and $line.TrimEnd() -notmatch ';$') {
                    $line = $line.TrimEnd() + ';'
                }

                $out.Add('  ' + $line)
            }
        }

        # One blank line between separate statements inside BEGIN / END.
        # Do not add a blank line after the final statement before END.
        if ($statementIndex -lt $bodyStatements.Count - 1) {
            $out.Add('')
        }
    }

    $out.Add('END')

    return $out
}

# ======================================================================
# FUNCTION formatter
# ======================================================================
# Function formatting follows the same simple rule as procedures:
#
#   - CREATE / RETURNS / LANGUAGE / BEGIN / END stay at column 1
#   - Function body lines get two spaces
#   - SQL inside the body is formatted by the existing statement formatter
#
# We intentionally do not build a separate SQL parser for functions.
# We only split the wrapper from the body and reuse the existing formatters.
# ======================================================================

function Format-FunctionStatement {
    param([string]$Sql)

    $Sql = Normalize-SqlWhitespace $Sql
    $Sql = Convert-SqlKeywordsToUpper $Sql

    $out = New-Object System.Collections.Generic.List[string]

    $m = [regex]::Match(
        $Sql,
        '^(CREATE\s+OR\s+REPLACE\s+FUNCTION\s+.+?)\s+RETURNS\s+(.+?)\s+LANGUAGE\s+SQL\s+BEGIN\s+(.+?)\s+END$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $m.Success) {
        $out.Add($Sql)
        return $out
    }

    $header  = $m.Groups[1].Value.Trim()
    $returns = $m.Groups[2].Value.Trim()
    $body    = $m.Groups[3].Value.Trim()

    # Make the function signature readable:
    #
    # CREATE OR REPLACE FUNCTION FN_NAME
    # (
    #   P_PARAM INTEGER
    # )
    $header = [regex]::Replace($header, '\s*\(\s*', "`n(")
    $header = [regex]::Replace($header, '\s*\)\s*$', "`n)")
    $header = [regex]::Replace($header, ',\s*', ",`n  ")

    foreach ($line in ($header -split "`n")) {
        $trim = $line.Trim()

        if ($trim -eq '(' -or $trim -eq ')') {
            $out.Add($trim)
        }
        elseif ($trim.Length -gt 0 -and $trim -notmatch '^CREATE\s+') {
            $out.Add('  ' + $trim)
        }
        else {
            $out.Add($trim)
        }
    }

    $out.Add('RETURNS ' + $returns)
    $out.Add('LANGUAGE SQL')
    $out.Add('BEGIN')

    # Split function body statements.
    # Functions commonly contain RETURN (...); and possibly DECLARE / SET later.
    # We reuse the existing formatter for whatever SQL statement appears inside.
    $bodyStatements = @(Split-SqlStatements $body)

    for ($statementIndex = 0; $statementIndex -lt $bodyStatements.Count; $statementIndex++) {
        $bodyStatement = $bodyStatements[$statementIndex].Trim()

        if ($bodyStatement -match '^RETURN\s*\((.+)\)$') {
            $returnInner = $matches[1].Trim()

            $out.Add('  RETURN (')

            if ($returnInner -match '^SELECT\b' -or $returnInner -match '^WITH\b') {
                $formattedReturn = @(Format-SqlStatement $returnInner)

                foreach ($line in $formattedReturn) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $out.Add('    ' + [string]$line)
                    }
                }
            }
            else {
                $out.Add('    ' + $returnInner)
            }

            $out.Add('  );')
        }
        else {
            $formattedBody = @(Format-SqlStatement $bodyStatement)

            for ($i = 0; $i -lt $formattedBody.Count; $i++) {
                $line = [string]$formattedBody[$i]

                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    if ($i -eq $formattedBody.Count - 1 -and $line.TrimEnd() -notmatch ';$') {
                        $line = $line.TrimEnd() + ';'
                    }

                    $out.Add('  ' + $line)
                }
            }
        }

        if ($statementIndex -lt $bodyStatements.Count - 1) {
            $out.Add('')
        }
    }

    $out.Add('END')

    return $out
}

# ======================================================================
# Dispatcher
# ======================================================================

function Format-SqlStatement {
    param([string]$Statement)

    $Statement = Normalize-SqlWhitespace $Statement
    $Statement = Convert-SqlKeywordsToUpper $Statement

    if ($Statement -match '^CREATE\s+OR\s+REPLACE\s+PROCEDURE\b') {
        return Apply-SafeLineWrapping -Lines (Format-ProcedureStatement $Statement)
    }

    if ($Statement -match '^CREATE\s+OR\s+REPLACE\s+FUNCTION\b') {
        return Apply-SafeLineWrapping -Lines (Format-FunctionStatement $Statement)
    }

    if ($Statement -match '^WITH\b') {
        return Apply-SafeLineWrapping -Lines (Format-WithStatement $Statement)
    }

    if ($Statement -match '^SELECT\b') {
        return Apply-SafeLineWrapping -Lines (Format-CompoundSelectStatement -Sql $Statement -OpeningPrefix "")
    }

    if ($Statement -match '^INSERT\b') {
        return Apply-SafeLineWrapping -Lines (Format-InsertStatement $Statement)
    }

    if ($Statement -match '^UPDATE\b') {
        return Apply-SafeLineWrapping -Lines (Format-UpdateStatement $Statement)
    }

    if ($Statement -match '^MERGE\b') {
        return Apply-SafeLineWrapping -Lines (Format-MergeStatement $Statement)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Statement)
    return $lines
}

# ======================================================================
# Standalone comment formatter
# ======================================================================
# Standalone line comments are protected as SLCOM tokens before whitespace
# normalization. Because normalization collapses whitespace, those tokens may
# temporarily sit at the end of a SQL line.
#
# This function moves each standalone-comment token onto its own line.
#
# Inline comments use LCOM tokens and are intentionally not touched here.
# ======================================================================

function Format-StandaloneCommentTokens {
    param([string]$Text)

    # ------------------------------------------------------------------
    # Final safety pass for standalone comments outside SELECT lists.
    # ------------------------------------------------------------------
    # SELECT lists handle comment tokens directly. This function catches
    # standalone comment tokens that remain in other places, for example:
    #
    #   FROM TAB __SQLFMT_BCOM_1__ __SQLFMT_EOL__
    #   WHERE ...
    #
    # It moves the standalone comment token to its own line using the current
    # line indentation and removes the internal EOL marker without creating a
    # blank line.
    #
    # Inline line comments (LCOM) are intentionally ignored here because they
    # should stay at the end of the line where they were written.
    # ------------------------------------------------------------------

    $out = New-Object System.Collections.Generic.List[string]
    $lines = $Text -split "`r?`n"

    foreach ($line in $lines) {
        $current = $line

        while ($current -match '(__SQLFMT_(SLCOM|BCOM)_\d+__)') {
            $token = $matches[1]
            $tokenIndex = $current.IndexOf($token)

            $before = $current.Substring(0, $tokenIndex).TrimEnd()
            $after  = $current.Substring($tokenIndex + $token.Length).TrimStart()

            # Remove one following internal EOL marker if it exists. The token
            # is already being placed on its own line, so keeping the marker
            # would create an artificial blank line later.
            $after = [regex]::Replace($after, '^\s*__SQLFMT_EOL__\s*', '')

            $indent = ([regex]::Match($current, '^\s*')).Value

            if (-not [string]::IsNullOrWhiteSpace($before)) {
                $out.Add($before)
            }

            $out.Add($indent + $token)

            $current = $after
        }

        # Any leftover EOL marker on this line is only an internal boundary.
        # Remove it rather than converting it into an extra empty line.
        $current = [regex]::Replace($current, '\s*__SQLFMT_EOL__\s*', ' ')

        if (-not [string]::IsNullOrWhiteSpace($current)) {
            $out.Add($current.TrimEnd())
        }
        elseif ($line -eq '') {
            $out.Add('')
        }
    }

    return ($out -join $script:NewLine)
}

# ======================================================================
# Main execution
# ======================================================================

$inputSql = [Console]::In.ReadToEnd()

if ([string]::IsNullOrWhiteSpace($inputSql)) {
    exit 0
}

$script:ProtectedMap = @{}
$script:ProtectedIndex = 0

$protectedSql = Protect-SqlText $inputSql
$protectedSql = Normalize-SqlWhitespace $protectedSql

$finalLines = New-Object System.Collections.Generic.List[string]

# Stored procedures contain semicolons inside BEGIN / END.
# So do not split them first. Format the whole procedure as one wrapper,
# then shift only the body SQL two spaces to the right.
if ($protectedSql -match '^\s*CREATE\s+OR\s+REPLACE\s+(PROCEDURE|FUNCTION)\b') {
    $procedureSql = $protectedSql.Trim()

    if ($procedureSql.EndsWith(';')) {
        $procedureSql = $procedureSql.Substring(0, $procedureSql.Length - 1).Trim()
    }

    $formatted = @(Format-SqlStatement $procedureSql)

    foreach ($line in $formatted) {
        $finalLines.Add([string]$line)
    }

    if ($finalLines.Count -gt 0 -and $finalLines[$finalLines.Count - 1].Trim() -eq 'END') {
        $finalLines[$finalLines.Count - 1] = 'END;'
    }
}
else {
    # Force array behavior. Without @(...), one statement may become a scalar
    # string, and PowerShell indexing would return characters.
    $statements = @(Split-SqlStatements $protectedSql)

    for ($i = 0; $i -lt $statements.Count; $i++) {
        $formatted = @(Format-SqlStatement $statements[$i])

        # Restore semicolon on the final non-empty line of each statement.
        for ($j = $formatted.Count - 1; $j -ge 0; $j--) {
            $currentLine = [string]$formatted[$j]

            if (-not [string]::IsNullOrWhiteSpace($currentLine)) {
                $currentLine = $currentLine.TrimEnd()

                if ($currentLine -notmatch ';$') {
                    $currentLine = $currentLine + ';'
                }

                $formatted[$j] = $currentLine
                break
            }
        }

        foreach ($line in $formatted) {
            $finalLines.Add([string]$line)
        }

        if ($i -lt $statements.Count - 1) {
            $finalLines.Add('')
        }
    }
}

$result = $finalLines -join $script:NewLine

# Move standalone comment tokens back onto their own aligned lines before
# restoring the real "-- comment" text.
$result = Format-StandaloneCommentTokens $result

# Safety cleanup:
# __SQLFMT_EOL__ is an internal marker used to preserve comment line breaks.
# At this stage, formatting has already placed comments correctly.
# So any leftover marker should be removed, not converted to a new line,
# otherwise it creates blank lines after comments.
$result = [regex]::Replace($result, '\s*__SQLFMT_EOL__\s*', ' ')

$result = Restore-SqlText $result

[Console]::Out.Write($result)