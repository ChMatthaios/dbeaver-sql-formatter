<#
    DB2 SQL Formatter - Safe Line-Aware Version

    Core formatting logic
    ---------------------
    This formatter is intentionally conservative.

    1. Treat "--" comments as normal visible SQL text.
       They stay in the output.

    2. Preserve "--" line-comment boundaries.
       A line comment ends the physical line. The formatter must not move SQL
       from the next line onto the comment line.

    3. Preserve developer line layout when the input is already multiline.
       This is the most important safety rule. If a developer already shaped a
       complex SELECT / CASE / CTE by hand, the formatter must not flatten it.

    4. Format simple one-line SELECT statements into the house style.

    5. Nested SELECTs follow the same style by adding leading indentation.

    6. If unsupported/complex syntax is detected, preserve layout instead of
       destroying it.

    This is a practical DB2 formatter, not a full SQL parser.
#>

$ErrorActionPreference = "Stop"

# ============================================================
# Keyword casing helpers
# ============================================================

function Convert-SqlKeywordsToUpperSafe {
    param([string]$Text)

    # Split a line into code/comment parts.
    # Comments are normal visible text, but we should not keyword-case comment text.
    $commentIndex = $Text.IndexOf("--")

    if ($commentIndex -ge 0) {
        $codePart = $Text.Substring(0, $commentIndex)
        $commentPart = $Text.Substring($commentIndex)
        return (Convert-CodeKeywordsToUpperSafe $codePart) + $commentPart
    }

    return Convert-CodeKeywordsToUpperSafe $Text
}

function Convert-CodeKeywordsToUpperSafe {
    param([string]$Text)

    # Protect strings before uppercasing keywords.
    $map = @{}
    $index = 0

    $protected = [regex]::Replace(
        $Text,
        "'(?:''|[^'])*'",
        {
            param($m)
            $scriptToken = "__SQLFMT_STR_$index`__"
            $map[$scriptToken] = $m.Value
            $index++
            $scriptToken
        }
    )

    $keywords = @(
        'select','from','where','and','or','not','null','is','in','exists','between','like',
        'inner','left','right','full','cross','outer','join','on','group','by','having','order',
        'asc','desc','fetch','first','rows','only','limit','offset','with','ur','rs','cs','rr','nc',
        'union','all','except','intersect','case','when','then','else','end','as','over','partition',
        'insert','into','values','update','set','delete','merge','using','matched',
        'create','replace','procedure','function','returns','language','sql','begin','atomic',
        'declare','cursor','for','continue','handler','open','fetch','close','loop','leave','if',
        'signal','sqlstate','message_text','prepare','execute','table','view','index','schema',
        'constraint','primary','key','foreign','references','check','default','temporary','global',
        'session','commit','preserve','logged','alter','add','column','data','type','optimize',
        'deterministic','external','action'
    )

    foreach ($kw in $keywords) {
        $escaped = [regex]::Escape($kw)
        $protected = [regex]::Replace(
            $protected,
            "(?i)(?<![A-Z0-9_])$escaped(?![A-Z0-9_])",
            { param($m) $m.Value.ToUpperInvariant() }
        )
    }

    foreach ($key in ($map.Keys | Sort-Object Length -Descending)) {
        $protected = $protected.Replace($key, $map[$key])
    }

    return $protected
}

# ============================================================
# Basic text helpers
# ============================================================

function Normalize-OneLineWhitespace {
    param([string]$Text)

    $Text = $Text -replace '[\r\n\t]+', ' '
    $Text = $Text -replace '\s+', ' '
    $Text = $Text -replace '\s+,', ','
    $Text = $Text -replace ',\s*', ', '
    $Text = $Text -replace '\(\s+', '('
    $Text = $Text -replace '\s+\)', ')'
    $Text = $Text -replace '\s+;', ';'
    return $Text.Trim()
}

function Get-ParenDepthAt {
    param([string]$Text, [int]$Index)

    $depth = 0
    $inString = $false

    for ($i = 0; $i -lt $Index; $i++) {
        $ch = $Text[$i]

        if ($ch -eq "'") {
            if ($inString -and $i + 1 -lt $Index -and $Text[$i + 1] -eq "'") {
                $i++
                continue
            }

            $inString = -not $inString
            continue
        }

        if ($inString) {
            continue
        }

        if ($ch -eq '(') {
            $depth++
        }
        elseif ($ch -eq ')' -and $depth -gt 0) {
            $depth--
        }
    }

    return $depth
}

function Split-TopLevelByComma {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0
    $inString = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]

        if ($ch -eq "'") {
            if ($inString -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") {
                $i++
                continue
            }

            $inString = -not $inString
            continue
        }

        if ($inString) {
            continue
        }

        if ($ch -eq '(') {
            $depth++
        }
        elseif ($ch -eq ')') {
            if ($depth -gt 0) {
                $depth--
            }
        }
        elseif ($ch -eq ',' -and $depth -eq 0) {
            $items.Add((Normalize-OneLineWhitespace $Text.Substring($start, $i - $start)))
            $start = $i + 1
        }
    }

    $tail = Normalize-OneLineWhitespace $Text.Substring($start)
    if ($tail.Length -gt 0) {
        $items.Add($tail)
    }

    return $items
}

function Find-TopLevelKeyword {
    param(
        [string]$Text,
        [string]$Pattern
    )

    $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($m in $rx.Matches($Text)) {
        if ((Get-ParenDepthAt -Text $Text -Index $m.Index) -eq 0) {
            return $m
        }
    }

    return $null
}

function Get-TopLevelKeywordMatches {
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

# ============================================================
# Safe multiline formatting
# ============================================================

function Format-MultilineSafely {
    param([string]$Sql)

    # This is the safety-first path.
    #
    # It preserves developer line breaks and indentation. It only:
    # - trims trailing whitespace,
    # - uppercases SQL keywords outside strings/comments,
    # - normalizes leading AND/OR alignment in WHERE-like blocks when obvious.
    #
    # It does NOT flatten the query.
    $lines = $Sql -replace "`r`n", "`n"
    $lines = $lines -replace "`r", "`n"
    $arr = $lines -split "`n", -1

    $out = New-Object System.Collections.Generic.List[string]
    $lastWhereIndent = $null

    foreach ($rawLine in $arr) {
        $line = $rawLine.TrimEnd()

        if ([string]::IsNullOrWhiteSpace($line)) {
            $out.Add("")
            continue
        }

        $converted = Convert-SqlKeywordsToUpperSafe $line

        # Track WHERE indentation.
        if ($converted -match '^(\s*)WHERE\b') {
            $lastWhereIndent = $matches[1]
        }

        # Align obvious AND / OR lines under WHERE.
        # This is intentionally conservative and only affects lines whose first
        # SQL token is AND or OR.
        if ($null -ne $lastWhereIndent -and $converted -match '^\s*(AND|OR)\s+(.+)$') {
            $op = $matches[1].ToUpperInvariant()
            $body = $matches[2]

            if ($op -eq "AND") {
                $converted = $lastWhereIndent + "   AND " + $body
            }
            else {
                $converted = $lastWhereIndent + "    OR " + $body
            }
        }

        $out.Add($converted)
    }

    return (($out -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine)
}

# ============================================================
# One-line SELECT formatter
# ============================================================
# This path is used when the input is not already developer-formatted.
# It formats SELECT columns one per line and predictable clauses.
# ============================================================

function Format-OneLineSelect {
    param(
        [string]$Sql,
        [int]$Indent = 0
    )

    $prefix = ' ' * $Indent
    $sql = Convert-CodeKeywordsToUpperSafe (Normalize-OneLineWhitespace $Sql.Trim().TrimEnd(';'))

    if ($sql -notmatch '^\s*SELECT\b') {
        return $prefix + $sql + ";"
    }

    $clausePattern = '\bFROM\b|\bWHERE\b|\bGROUP\s+BY\b|\bHAVING\b|\bORDER\s+BY\b|\bFETCH\s+FIRST\b|\bWITH\s+(UR|RS|CS|RR|NC)\b'
    $matches = @(Get-TopLevelKeywordMatches -Text $sql -Pattern $clausePattern)

    if ($matches.Count -eq 0) {
        $selectList = $sql -replace '^\s*SELECT\s+', ''
        return Format-CommaListLines -Text $selectList -FirstPrefix ($prefix + "SELECT ") -NextPrefix ($prefix + "       ") -AddSemicolon
    }

    $out = New-Object System.Collections.Generic.List[string]
    $firstClause = $matches[0]
    $selectList = $sql.Substring(6, $firstClause.Index - 6).Trim()

    foreach ($line in (Format-CommaListLines -Text $selectList -FirstPrefix ($prefix + "SELECT ") -NextPrefix ($prefix + "       "))) {
        $out.Add($line)
    }

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $m = $matches[$i]
        $next = if ($i -lt $matches.Count - 1) { $matches[$i + 1].Index } else { $sql.Length }
        $name = $m.Value.ToUpperInvariant()
        $body = Normalize-OneLineWhitespace $sql.Substring($m.Index + $m.Length, $next - ($m.Index + $m.Length))

        switch -Regex ($name) {
            '^FROM$' {
                $out.Add($prefix + "  FROM " + $body)
                break
            }
            '^WHERE$' {
                Add-WhereLines -Out $out -Body $body -Prefix $prefix
                break
            }
            '^GROUP BY$' {
                foreach ($line in (Format-CommaListLines -Text $body -FirstPrefix ($prefix + " GROUP BY ") -NextPrefix ($prefix + "          "))) {
                    $out.Add($line)
                }
                break
            }
            '^ORDER BY$' {
                foreach ($line in (Format-CommaListLines -Text $body -FirstPrefix ($prefix + " ORDER BY ") -NextPrefix ($prefix + "          "))) {
                    $out.Add($line)
                }
                break
            }
            '^FETCH FIRST$' {
                $out.Add($prefix + " FETCH FIRST " + $body)
                break
            }
            '^WITH ' {
                $out.Add($prefix + "  " + $name)
                break
            }
            default {
                $out.Add($prefix + " " + $name + " " + $body)
            }
        }
    }

    if ($out.Count -gt 0) {
        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ";"
    }

    return ($out -join [Environment]::NewLine)
}

function Format-CommaListLines {
    param(
        [string]$Text,
        [string]$FirstPrefix,
        [string]$NextPrefix,
        [switch]$AddSemicolon
    )

    $items = @(Split-TopLevelByComma $Text)
    $out = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { "," } else { "" }
        if ($AddSemicolon -and $i -eq $items.Count - 1) {
            $suffix += ";"
        }

        $prefix = if ($i -eq 0) { $FirstPrefix } else { $NextPrefix }
        $out.Add($prefix + $items[$i] + $suffix)
    }

    return $out
}

function Add-WhereLines {
    param(
        [System.Collections.Generic.List[string]]$Out,
        [string]$Body,
        [string]$Prefix
    )

    $parts = Split-WhereLogicalParts $Body

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $part = $parts[$i]

        if ($i -eq 0) {
            $Out.Add($Prefix + " WHERE " + $part)
        }
        elseif ($part -match '^(AND|OR)\s+(.+)$') {
            $op = $matches[1].ToUpperInvariant()
            $rest = $matches[2]

            if ($op -eq "AND") {
                $Out.Add($Prefix + "   AND " + $rest)
            }
            else {
                $Out.Add($Prefix + "    OR " + $rest)
            }
        }
        else {
            $Out.Add($Prefix + "   AND " + $part)
        }
    }
}

function Split-WhereLogicalParts {
    param([string]$Text)

    $matches = @(Get-TopLevelKeywordMatches -Text $Text -Pattern '\b(AND|OR)\b')
    $parts = New-Object System.Collections.Generic.List[string]

    if ($matches.Count -eq 0) {
        $parts.Add((Normalize-OneLineWhitespace $Text))
        return $parts
    }

    $start = 0

    foreach ($m in $matches) {
        if ($m.Index -gt $start) {
            $segment = Normalize-OneLineWhitespace $Text.Substring($start, $m.Index - $start)
            if ($segment.Length -gt 0) {
                $parts.Add($segment)
            }
        }

        $start = $m.Index
    }

    $tail = Normalize-OneLineWhitespace $Text.Substring($start)
    if ($tail.Length -gt 0) {
        $parts.Add($tail)
    }

    return $parts
}

# ============================================================
# Main
# ============================================================

function Format-SqlText {
    param([string]$Sql)

    $normalizedNewlines = $Sql -replace "`r`n", "`n"
    $normalizedNewlines = $normalizedNewlines -replace "`r", "`n"

    $nonEmptyLines = @(
        $normalizedNewlines -split "`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    # Safety decision:
    # If SQL is already multiline, preserve layout. This prevents the formatter
    # from destroying complex hand-shaped DB2 SQL with comments and CASE blocks.
    if ($nonEmptyLines.Count -gt 1) {
        return Format-MultilineSafely $Sql
    }

    $oneLine = $normalizedNewlines.Trim()

    if ($oneLine -match '^\s*SELECT\b') {
        return (Format-OneLineSelect $oneLine) + [Environment]::NewLine
    }

    return (Convert-SqlKeywordsToUpperSafe (Normalize-OneLineWhitespace $oneLine)) + [Environment]::NewLine
}

$inputSql = [Console]::In.ReadToEnd()
[Console]::Out.Write((Format-SqlText $inputSql))
