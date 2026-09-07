<#
    T-SQL structural formatter for SQL Server / Azure SQL.

    Shared ANSI-style SQL is formatted in the same house style as DB2/PostgreSQL,
    while SQL Server-specific syntax is protected and handled here. The formatter
    is conservative around stored-program bodies and batch separators.
#>

$ErrorActionPreference = 'Stop'
$script:MaxLineLength = 120
$script:IndentSize = 2
$script:ProtectedMap = @{}
$script:ProtectedIndex = 0
$CoreFormatter = Join-Path $PSScriptRoot 'format-sql-core.ps1'

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
        if ($settings.PSObject.Properties.Name -contains 'indentSize') {
            $value = 0
            if ([int]::TryParse([string]$settings.indentSize, [ref]$value) -and $value -in @(2, 4)) {
                $script:IndentSize = $value
            }
        }
    }
    catch {
        # Local settings must never break formatting.
    }
}

function New-TsqlProtectedToken {
    param([string]$Prefix, [string]$Value)
    $script:ProtectedIndex++
    $token = "__TSQL_${Prefix}_$script:ProtectedIndex`__"
    $script:ProtectedMap[$token] = $Value
    return $token
}

function Protect-TsqlText {
    param([string]$Sql)

    $script:ProtectedMap = @{}
    $script:ProtectedIndex = 0

    $Sql = [regex]::Replace($Sql, '/\*[\s\S]*?\*/', { param($m) New-TsqlProtectedToken -Prefix 'BCOM' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, "(?i)N'(?:''|[^'])*'", { param($m) New-TsqlProtectedToken -Prefix 'NSTR' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, "'(?:''|[^'])*'", { param($m) New-TsqlProtectedToken -Prefix 'STR' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '\[(?:\]\]|[^\]])*\]', { param($m) New-TsqlProtectedToken -Prefix 'BRK' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '"(?:""|[^"])*"', { param($m) New-TsqlProtectedToken -Prefix 'DQS' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '--[^\r\n]*', { param($m) New-TsqlProtectedToken -Prefix 'LCOM' -Value $m.Value })

    # Keep the physical boundary after line comments. Without this, restored text
    # could accidentally comment out SQL that originally lived on the next line.
    $Sql = [regex]::Replace(
        $Sql,
        '(__TSQL_LCOM_\d+__)(\r?\n)([ \t]*)',
        { param($m) $m.Groups[1].Value + " __TSQL_EOL_$($m.Groups[3].Value.Length)__ " }
    )
    return $Sql
}

function Restore-TsqlText {
    param([string]$Sql)

    $Sql = [regex]::Replace(
        $Sql,
        '[ \t]*__TSQL_EOL_(\d+)__[ \t]*',
        { param($m) [Environment]::NewLine + (' ' * [int]$m.Groups[1].Value) }
    )
    foreach ($key in ($script:ProtectedMap.Keys | Sort-Object Length -Descending)) {
        $Sql = $Sql.Replace($key, $script:ProtectedMap[$key])
    }
    return $Sql
}

function Normalize-TsqlSpace {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text = $Text -replace '[\r\n\t]+', ' '
    $Text = $Text -replace '\s+', ' '
    $Text = $Text -replace '\s+,', ','
    $Text = $Text -replace ',\s*', ', '
    $Text = $Text -replace '\(\s+', '('
    $Text = $Text -replace '\s+\)', ')'
    $Text = $Text -replace '\s+;', ';'
    return $Text.Trim()
}

function Convert-TsqlKeywords {
    param([string]$Sql)

    $keywords = @(
        'top','percent','ties','output','inserted','deleted','apply','pivot','unpivot',
        'option','recompile','optimize','unknown','maxdop','force','order','loop','hash','merge',
        'nolock','updlock','holdlock','rowlock','readpast','readuncommitted','readcommitted',
        'tablock','tablockx','xlock','nowait','index','for','json','xml','path','auto','root',
        'include_null_values','without_array_wrapper','offset','next','rows','fetch','only',
        'create','alter','or','procedure','proc','function','trigger','view','returns','return',
        'begin','end','try','catch','throw','raiserror','exec','execute','declare','set',
        'transaction','tran','commit','rollback','save','identity','nvarchar','varchar','nchar',
        'uniqueidentifier','datetime2','datetimeoffset','bit','money','smallmoney','varbinary',
        'isnull','iif','try_cast','try_convert','convert','cast','getdate','sysdatetime','newid',
        'cross','outer','join','inner','left','right','full','on','select','distinct','from','where',
        'and','not','null','is','in','exists','between','like','group','by','having','asc','desc',
        'insert','into','values','update','delete','case','when','then','else','as','with','union',
        'all','except','intersect','over','partition'
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

function Remove-TsqlTrailingSemicolon {
    param([string]$Text)
    return ($Text.Trim() -replace ';+\s*$', '')
}

function Find-TsqlMatchingParen {
    param([string]$Text, [int]$OpenIndex)
    $depth = 0
    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '(') { $depth++ }
        elseif ($Text[$i] -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

function Get-TsqlParenDepthAt {
    param([string]$Text, [int]$Index)
    $depth = 0
    for ($i = 0; $i -lt $Index; $i++) {
        if ($Text[$i] -eq '(') { $depth++ }
        elseif ($Text[$i] -eq ')' -and $depth -gt 0) { $depth-- }
    }
    return $depth
}

function Get-TsqlTopLevelMatches {
    param([string]$Text, [string]$Pattern)
    $result = New-Object System.Collections.Generic.List[object]
    $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $rx.Matches($Text)) {
        if ((Get-TsqlParenDepthAt -Text $Text -Index $m.Index) -eq 0) { [void]$result.Add($m) }
    }
    return $result
}

function Get-TsqlFirstTopLevelMatch {
    param([string]$Text, [string]$Pattern)
    $matches = @(Get-TsqlTopLevelMatches -Text $Text -Pattern $Pattern)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Split-TsqlTopLevelComma {
    param([string]$Text)
    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '(') { $depth++ }
        elseif ($Text[$i] -eq ')' -and $depth -gt 0) { $depth-- }
        elseif ($Text[$i] -eq ',' -and $depth -eq 0) {
            $piece = Normalize-TsqlSpace $Text.Substring($start, $i - $start)
            if ($piece) { [void]$items.Add($piece) }
            $start = $i + 1
        }
    }
    $tail = Normalize-TsqlSpace $Text.Substring($start)
    if ($tail) { [void]$items.Add($tail) }
    return $items
}

function Split-TsqlLogical {
    param([string]$Text)

    $parts = New-Object System.Collections.Generic.List[object]
    $depth = 0
    $start = 0
    $currentOp = ''
    $betweenNeedsAnd = $false
    $i = 0

    while ($i -lt $Text.Length) {
        if ($Text[$i] -eq '(') { $depth++; $i++; continue }
        if ($Text[$i] -eq ')') { if ($depth -gt 0) { $depth-- }; $i++; continue }

        if ($depth -eq 0) {
            $rest = $Text.Substring($i)
            $between = [regex]::Match($rest, '^BETWEEN\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($between.Success) { $betweenNeedsAnd = $true; $i += $between.Length; continue }

            $logical = [regex]::Match($rest, '^(AND|OR)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($logical.Success) {
                $op = $logical.Groups[1].Value.ToUpperInvariant()
                if ($op -eq 'AND' -and $betweenNeedsAnd) {
                    $betweenNeedsAnd = $false
                    $i += $logical.Length
                    continue
                }
                $piece = Normalize-TsqlSpace $Text.Substring($start, $i - $start)
                if ($piece) { [void]$parts.Add([pscustomobject]@{ Op = $currentOp; Text = $piece }) }
                $currentOp = $op
                $start = $i + $logical.Length
                $i = $start
                continue
            }
        }
        $i++
    }

    $tail = Normalize-TsqlSpace $Text.Substring($start)
    if ($tail) { [void]$parts.Add([pscustomobject]@{ Op = $currentOp; Text = $tail }) }
    if ($parts.Count -eq 0) { [void]$parts.Add([pscustomobject]@{ Op = ''; Text = (Normalize-TsqlSpace $Text) }) }
    return $parts
}

function Invoke-TsqlCore {
    param([string]$Sql)
    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $CoreFormatter |
        Out-String
    return $formatted.TrimEnd("`r", "`n")
}

function Wrap-TsqlWords {
    param([string]$Text, [string]$FirstPrefix, [string]$ContinuationPrefix)
    $normalized = Normalize-TsqlSpace $Text
    if (-not $normalized) { return @($FirstPrefix.TrimEnd()) }
    $words = @($normalized -split '\s+' | Where-Object { $_ })
    $out = New-Object System.Collections.Generic.List[string]
    $current = $FirstPrefix
    foreach ($word in $words) {
        $separator = if ($current.TrimEnd().Length -gt $FirstPrefix.TrimEnd().Length) { ' ' } else { '' }
        if (($current + $separator + $word).Length -gt $script:MaxLineLength -and $current.Trim().Length -gt 0) {
            [void]$out.Add($current.TrimEnd())
            $current = $ContinuationPrefix + $word
        }
        else { $current += $separator + $word }
    }
    if ($current.Trim().Length -gt 0) { [void]$out.Add($current.TrimEnd()) }
    return $out
}

function Format-TsqlNestedSubqueries {
    param([string]$Text, [int]$AbsolutePrefixLength, [int]$Depth = 0)
    if ($Depth -ge 8) { return Normalize-TsqlSpace $Text }

    $work = Normalize-TsqlSpace $Text
    for ($i = 0; $i -lt $work.Length; $i++) {
        if ($work[$i] -ne '(') { continue }
        $close = Find-TsqlMatchingParen -Text $work -OpenIndex $i
        if ($close -lt 0) { continue }
        $inner = $work.Substring($i + 1, $close - $i - 1).Trim()
        if ($inner -notmatch '^(?i);?(SELECT|WITH)\b') { continue }

        $head = $work.Substring(0, $i)
        $tail = $work.Substring($close + 1)
        $innerIndent = $AbsolutePrefixLength + $head.Length + 1
        $innerLines = @(Format-TsqlStatement -Statement $inner -Indent $innerIndent -NoSemicolon -Depth ($Depth + 1))
        if ($innerLines.Count -eq 0) { return $work }

        $out = New-Object System.Collections.Generic.List[string]
        [void]$out.Add($head + '(' + $innerLines[0].TrimStart())
        for ($j = 1; $j -lt $innerLines.Count; $j++) { [void]$out.Add($innerLines[$j]) }
        $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ')' + $tail
        return ($out -join [Environment]::NewLine)
    }
    return $work
}

function Format-TsqlExpressionWithPrefix {
    param([string]$Text, [string]$FirstPrefix, [string]$ContinuationPrefix, [int]$Depth = 0)
    $expression = Format-TsqlNestedSubqueries -Text $Text -AbsolutePrefixLength $FirstPrefix.Length -Depth $Depth
    if ($expression.Contains([Environment]::NewLine)) {
        $lines = @($expression -split [regex]::Escape([Environment]::NewLine))
        $out = New-Object System.Collections.Generic.List[string]
        [void]$out.Add($FirstPrefix + $lines[0])
        for ($i = 1; $i -lt $lines.Count; $i++) { [void]$out.Add($lines[$i]) }
        return $out
    }
    if (($FirstPrefix + $expression).Length -le $script:MaxLineLength) { return @($FirstPrefix + $expression) }
    return @(Wrap-TsqlWords -Text $expression -FirstPrefix $FirstPrefix -ContinuationPrefix $ContinuationPrefix)
}

function Format-TsqlSelectList {
    param([string]$Text, [int]$Indent = 0, [int]$Depth = 0)
    $items = @(Split-TsqlTopLevelComma (Normalize-TsqlSpace $Text))
    $out = New-Object System.Collections.Generic.List[string]
    $firstPrefix = (' ' * $Indent) + 'SELECT '
    $nextPrefix = (' ' * $Indent) + (' ' * 7)

    for ($i = 0; $i -lt $items.Count; $i++) {
        $prefix = if ($i -eq 0) { $firstPrefix } else { $nextPrefix }
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $lines = @(Format-TsqlExpressionWithPrefix -Text $items[$i] -FirstPrefix $prefix -ContinuationPrefix $nextPrefix -Depth $Depth)
        for ($j = 0; $j -lt $lines.Count; $j++) {
            if ($j -eq $lines.Count - 1) { [void]$out.Add($lines[$j] + $suffix) }
            else { [void]$out.Add($lines[$j]) }
        }
    }
    return $out
}

function Format-TsqlConditionClause {
    param([string]$Text, [string]$Keyword, [int]$Indent = 0, [int]$Depth = 0)
    $parts = @(Split-TsqlLogical (Normalize-TsqlSpace $Text))
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $clause = if ($i -eq 0) { $Keyword.ToUpperInvariant() } elseif ($parts[$i].Op -eq 'OR') { 'OR' } else { 'AND' }
        $prefix = switch ($clause) {
            'WHERE'  { (' ' * $Indent) + ' WHERE ' }
            'HAVING' { (' ' * $Indent) + ' HAVING ' }
            'ON'     { (' ' * $Indent) + '    ON ' }
            'OR'     { (' ' * $Indent) + '    OR ' }
            default  { (' ' * $Indent) + '   AND ' }
        }
        $continuation = ' ' * $prefix.Length
        foreach ($line in @(Format-TsqlExpressionWithPrefix -Text $parts[$i].Text -FirstPrefix $prefix -ContinuationPrefix $continuation -Depth $Depth)) {
            [void]$out.Add($line)
        }
    }
    return $out
}

function Format-TsqlCommaClause {
    param([string]$Text, [string]$Keyword, [int]$Indent = 0, [int]$Depth = 0)
    $prefix = switch ($Keyword.ToUpperInvariant()) {
        'GROUP BY' { (' ' * $Indent) + ' GROUP BY ' }
        'ORDER BY' { (' ' * $Indent) + ' ORDER BY ' }
        'OUTPUT'   { (' ' * $Indent) + 'OUTPUT ' }
        'RETURNING'{ (' ' * $Indent) + 'RETURNING ' }
        default    { (' ' * $Indent) + $Keyword.ToUpperInvariant() + ' ' }
    }
    $normalized = Normalize-TsqlSpace $Text
    if (($prefix + $normalized).Length -le $script:MaxLineLength) { return @($prefix + $normalized) }

    $items = @(Split-TsqlTopLevelComma $normalized)
    $continuation = ' ' * $prefix.Length
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $items.Count; $i++) {
        $itemPrefix = if ($i -eq 0) { $prefix } else { $continuation }
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        foreach ($line in @(Format-TsqlExpressionWithPrefix -Text $items[$i] -FirstPrefix $itemPrefix -ContinuationPrefix $continuation -Depth $Depth)) {
            if ($line -eq $null) { continue }
            if ($line -eq (@(Format-TsqlExpressionWithPrefix -Text $items[$i] -FirstPrefix $itemPrefix -ContinuationPrefix $continuation -Depth $Depth))[-1]) { }
        }
        $lines = @(Format-TsqlExpressionWithPrefix -Text $items[$i] -FirstPrefix $itemPrefix -ContinuationPrefix $continuation -Depth $Depth)
        for ($j = 0; $j -lt $lines.Count; $j++) {
            if ($j -eq $lines.Count - 1) { [void]$out.Add($lines[$j] + $suffix) }
            else { [void]$out.Add($lines[$j]) }
        }
    }
    return $out
}

function Format-TsqlJoinSegment {
    param([string]$Segment, [int]$Indent = 0, [int]$Depth = 0)
    $text = Normalize-TsqlSpace $Segment
    $m = [regex]::Match($text, '^(?i)(LEFT\s+OUTER\s+JOIN|RIGHT\s+OUTER\s+JOIN|FULL\s+OUTER\s+JOIN|INNER\s+JOIN|LEFT\s+JOIN|RIGHT\s+JOIN|FULL\s+JOIN|CROSS\s+JOIN|CROSS\s+APPLY|OUTER\s+APPLY|JOIN)\b')
    if (-not $m.Success) { return @((' ' * $Indent) + $text) }

    $keyword = ($m.Groups[1].Value -replace '\s+', ' ').ToUpperInvariant()
    $rest = $text.Substring($m.Length).Trim()
    $prefix = (' ' * $Indent) + '  ' + $keyword + ' '

    if ($keyword -match 'APPLY$') {
        return @(Format-TsqlExpressionWithPrefix -Text $rest -FirstPrefix $prefix -ContinuationPrefix (' ' * $prefix.Length) -Depth $Depth)
    }

    $on = Get-TsqlFirstTopLevelMatch -Text $rest -Pattern '\bON\b'
    if ($null -eq $on) { return @(Format-TsqlExpressionWithPrefix -Text $rest -FirstPrefix $prefix -ContinuationPrefix (' ' * $prefix.Length) -Depth $Depth) }

    $source = Normalize-TsqlSpace $rest.Substring(0, $on.Index)
    $condition = $rest.Substring($on.Index + $on.Length)
    $inline = $prefix + $source + ' ON ' + (Normalize-TsqlSpace $condition)
    if ($inline.Length -le $script:MaxLineLength -and $condition -notmatch '(?i)\b(AND|OR)\b') { return @($inline) }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Format-TsqlExpressionWithPrefix -Text $source -FirstPrefix $prefix -ContinuationPrefix (' ' * $prefix.Length) -Depth $Depth)) { [void]$out.Add($line) }
    foreach ($line in @(Format-TsqlConditionClause -Text $condition -Keyword 'ON' -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
    return $out
}

function Format-TsqlFromClause {
    param([string]$Text, [int]$Indent = 0, [int]$Depth = 0)
    $text = Normalize-TsqlSpace $Text
    $joinPattern = '\b(LEFT\s+OUTER\s+JOIN|RIGHT\s+OUTER\s+JOIN|FULL\s+OUTER\s+JOIN|INNER\s+JOIN|LEFT\s+JOIN|RIGHT\s+JOIN|FULL\s+JOIN|CROSS\s+JOIN|CROSS\s+APPLY|OUTER\s+APPLY|JOIN)\b'
    $joins = @(Get-TsqlTopLevelMatches -Text $text -Pattern $joinPattern)
    $out = New-Object System.Collections.Generic.List[string]

    if ($joins.Count -eq 0) {
        $prefix = (' ' * $Indent) + '  FROM '
        foreach ($line in @(Format-TsqlExpressionWithPrefix -Text $text -FirstPrefix $prefix -ContinuationPrefix (' ' * $prefix.Length) -Depth $Depth)) { [void]$out.Add($line) }
        return $out
    }

    $source = Normalize-TsqlSpace $text.Substring(0, $joins[0].Index)
    foreach ($line in @(Format-TsqlExpressionWithPrefix -Text $source -FirstPrefix ((' ' * $Indent) + '  FROM ') -ContinuationPrefix ((' ' * $Indent) + (' ' * 7)) -Depth $Depth)) { [void]$out.Add($line) }

    for ($i = 0; $i -lt $joins.Count; $i++) {
        $next = if ($i -lt $joins.Count - 1) { $joins[$i + 1].Index } else { $text.Length }
        $segment = $text.Substring($joins[$i].Index, $next - $joins[$i].Index)
        foreach ($line in @(Format-TsqlJoinSegment -Segment $segment -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
    }
    return $out
}

function Format-TsqlSelect {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon, [int]$Depth = 0)
    $sql = Remove-TsqlTrailingSemicolon (Normalize-TsqlSpace $Sql)
    if ($sql.StartsWith(';')) { $sql = $sql.Substring(1).TrimStart() }

    $select = [regex]::Match($sql, '^(?i)SELECT\b')
    if (-not $select.Success) { return @((' ' * $Indent) + $sql + $(if ($NoSemicolon) { '' } else { ';' })) }

    $clausePattern = '\b(FROM|WHERE|GROUP\s+BY|HAVING|ORDER\s+BY|OFFSET|FETCH\s+(?:NEXT|FIRST)|FOR\s+(?:JSON|XML)|OPTION)\b'
    $matches = @(Get-TsqlTopLevelMatches -Text $sql -Pattern $clausePattern)
    $firstClauseIndex = if ($matches.Count -gt 0) { $matches[0].Index } else { $sql.Length }
    $into = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bINTO\b'
    if ($null -ne $into -and $into.Index -gt $firstClauseIndex) { $into = $null }

    $selectStart = $select.Index + $select.Length
    $selectEnd = $firstClauseIndex
    if ($null -ne $into -and $into.Index -lt $selectEnd) { $selectEnd = $into.Index }
    $selectText = $sql.Substring($selectStart, $selectEnd - $selectStart)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Format-TsqlSelectList -Text $selectText -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }

    if ($null -ne $into) {
        $intoEnd = $firstClauseIndex
        $intoText = Normalize-TsqlSpace $sql.Substring($into.Index + $into.Length, $intoEnd - ($into.Index + $into.Length))
        [void]$out.Add((' ' * $Indent) + '  INTO ' + $intoText)
    }

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $m = $matches[$i]
        $next = if ($i -lt $matches.Count - 1) { $matches[$i + 1].Index } else { $sql.Length }
        $body = Normalize-TsqlSpace $sql.Substring($m.Index + $m.Length, $next - ($m.Index + $m.Length))
        $name = ($m.Value -replace '\s+', ' ').ToUpperInvariant()
        switch -Regex ($name) {
            '^FROM$'     { foreach ($line in @(Format-TsqlFromClause -Text $body -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }; break }
            '^(WHERE|HAVING)$' { foreach ($line in @(Format-TsqlConditionClause -Text $body -Keyword $name -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }; break }
            '^(GROUP BY|ORDER BY)$' { foreach ($line in @(Format-TsqlCommaClause -Text $body -Keyword $name -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }; break }
            '^OFFSET$' { [void]$out.Add((' ' * $Indent) + ' OFFSET ' + $body); break }
            '^FETCH (NEXT|FIRST)$' { [void]$out.Add((' ' * $Indent) + ' FETCH ' + ($name -replace '^FETCH\s+', '') + ' ' + $body); break }
            '^FOR (JSON|XML)$' { [void]$out.Add((' ' * $Indent) + '   ' + $name + $(if ($body) { ' ' + $body } else { '' })); break }
            '^OPTION$' { [void]$out.Add((' ' * $Indent) + ' OPTION ' + $body); break }
        }
    }

    if (-not $NoSemicolon -and $out.Count -gt 0) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
    return $out
}

function Format-TsqlWith {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon, [int]$Depth = 0)
    $sql = Remove-TsqlTrailingSemicolon (Normalize-TsqlSpace $Sql)
    if ($sql.StartsWith(';')) { $sql = $sql.Substring(1).TrimStart() }
    $work = $sql.Substring(4).TrimStart()
    $out = New-Object System.Collections.Generic.List[string]
    $cteIndex = 0

    while ($work) {
        $asMatch = Get-TsqlFirstTopLevelMatch -Text $work -Pattern '\bAS\s*\('
        if ($null -eq $asMatch) { break }
        $name = Normalize-TsqlSpace $work.Substring(0, $asMatch.Index)
        if ($name.StartsWith(',')) { $name = $name.Substring(1).Trim() }
        $open = $work.IndexOf('(', $asMatch.Index)
        if ($open -lt 0) { break }
        $close = Find-TsqlMatchingParen -Text $work -OpenIndex $open
        if ($close -lt 0) { break }

        $inner = $work.Substring($open + 1, $close - $open - 1).Trim()
        $namePrefix = if ($cteIndex -eq 0) { (' ' * $Indent) + 'WITH ' } else { (' ' * $Indent) + '     ' }
        [void]$out.Add($namePrefix + $name)
        $asPrefix = (' ' * $Indent) + '  AS ( '
        $innerLines = @(Format-TsqlStatement -Statement $inner -Indent $asPrefix.Length -NoSemicolon -Depth ($Depth + 1))
        if ($innerLines.Count -gt 0) {
            [void]$out.Add($asPrefix + $innerLines[0].TrimStart())
            for ($i = 1; $i -lt $innerLines.Count; $i++) { [void]$out.Add($innerLines[$i]) }
        }
        else { [void]$out.Add($asPrefix.TrimEnd()) }

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
        foreach ($line in @(Format-TsqlStatement -Statement $work -Indent $Indent -NoSemicolon -Depth $Depth)) { [void]$out.Add($line) }
    }
    if (-not $NoSemicolon -and $out.Count -gt 0) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
    return $out
}

function Format-TsqlParenList {
    param([string]$Head, [string]$Text, [int]$Indent = 0)
    $items = @(Split-TsqlTopLevelComma $Text)
    $prefix = ' ' * $Indent
    $compact = $prefix + $Head + ' ( ' + ($items -join ', ') + ' )'
    if ($compact.Length -le $script:MaxLineLength) { return @($compact) }
    $out = New-Object System.Collections.Generic.List[string]
    $first = $prefix + $Head + ' ( '
    $next = ' ' * $first.Length
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { ' )' }
        [void]$out.Add($(if ($i -eq 0) { $first } else { $next }) + $items[$i] + $suffix)
    }
    return $out
}

function Format-TsqlInsert {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon, [int]$Depth = 0)
    $sql = Remove-TsqlTrailingSemicolon (Normalize-TsqlSpace $Sql)
    $prefix = ' ' * $Indent
    $outputMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bOUTPUT\b'
    $valuesMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bVALUES\b'
    $selectMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bSELECT\b'

    $payloadIndex = $sql.Length
    if ($null -ne $valuesMatch) { $payloadIndex = [Math]::Min($payloadIndex, $valuesMatch.Index) }
    if ($null -ne $selectMatch -and $selectMatch.Index -gt 0) { $payloadIndex = [Math]::Min($payloadIndex, $selectMatch.Index) }
    $headEnd = $payloadIndex
    if ($null -ne $outputMatch -and $outputMatch.Index -lt $headEnd) { $headEnd = $outputMatch.Index }
    $head = Normalize-TsqlSpace $sql.Substring(0, $headEnd)

    $out = New-Object System.Collections.Generic.List[string]
    $m = [regex]::Match($head, '^(?i)(INSERT\s+(?:TOP\s*\([^)]*\)\s+)?INTO\s+[^\s(]+)\s*(.*)$')
    if ($m.Success -and $m.Groups[2].Value.Trim().StartsWith('(')) {
        $rest = $m.Groups[2].Value.Trim()
        $close = Find-TsqlMatchingParen -Text $rest -OpenIndex 0
        if ($close -gt 0) {
            foreach ($line in @(Format-TsqlParenList -Head (Normalize-TsqlSpace $m.Groups[1].Value) -Text $rest.Substring(1, $close - 1) -Indent $Indent)) { [void]$out.Add($line) }
        }
        else { [void]$out.Add($prefix + $head) }
    }
    else { [void]$out.Add($prefix + $head) }

    if ($null -ne $outputMatch) {
        $outputEnd = $payloadIndex
        $outputText = Normalize-TsqlSpace $sql.Substring($outputMatch.Index + $outputMatch.Length, $outputEnd - ($outputMatch.Index + $outputMatch.Length))
        foreach ($line in @(Format-TsqlCommaClause -Text $outputText -Keyword 'OUTPUT' -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
    }

    if ($null -ne $valuesMatch -and $valuesMatch.Index -eq $payloadIndex) {
        $valuesText = Normalize-TsqlSpace $sql.Substring($valuesMatch.Index + $valuesMatch.Length))
        if ($valuesText.StartsWith('(')) {
            $groups = @(Split-TsqlTopLevelComma $valuesText)
            $valuesPrefix = $prefix + 'VALUES '
            for ($i = 0; $i -lt $groups.Count; $i++) {
                $linePrefix = if ($i -eq 0) { $valuesPrefix } else { ' ' * $valuesPrefix.Length }
                [void]$out.Add($linePrefix + $groups[$i] + $(if ($i -lt $groups.Count - 1) { ',' } else { '' }))
            }
        }
        else { [void]$out.Add($prefix + 'VALUES ' + $valuesText) }
    }
    elseif ($null -ne $selectMatch -and $selectMatch.Index -eq $payloadIndex) {
        $selectText = $sql.Substring($selectMatch.Index)
        foreach ($line in @(Format-TsqlStatement -Statement $selectText -Indent $Indent -NoSemicolon -Depth ($Depth + 1))) { [void]$out.Add($line) }
    }

    if (-not $NoSemicolon -and $out.Count -gt 0) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
    return $out
}

function Format-TsqlSetItems {
    param([string]$Text, [int]$Indent = 0, [int]$Depth = 0)
    $items = @(Split-TsqlTopLevelComma (Normalize-TsqlSpace $Text))
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $items.Count; $i++) {
        $prefix = (' ' * $Indent) + $(if ($i -eq 0) { '   SET ' } else { '       ' })
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $lines = @(Format-TsqlExpressionWithPrefix -Text $items[$i] -FirstPrefix $prefix -ContinuationPrefix ((' ' * $Indent) + '       ') -Depth $Depth)
        for ($j = 0; $j -lt $lines.Count; $j++) {
            if ($j -eq $lines.Count - 1) { [void]$out.Add($lines[$j] + $suffix) } else { [void]$out.Add($lines[$j]) }
        }
    }
    return $out
}

function Format-TsqlUpdate {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon, [int]$Depth = 0)
    $sql = Remove-TsqlTrailingSemicolon (Normalize-TsqlSpace $Sql)
    $prefix = ' ' * $Indent
    $setMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bSET\b'
    if ($null -eq $setMatch) { return @($prefix + $sql + $(if ($NoSemicolon) { '' } else { ';' })) }

    $outputMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bOUTPUT\b'
    $fromMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bFROM\b'
    $whereMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bWHERE\b'
    $optionMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bOPTION\b'

    $setEnd = $sql.Length
    foreach ($m in @($outputMatch, $fromMatch, $whereMatch, $optionMatch)) {
        if ($null -ne $m -and $m.Index -gt $setMatch.Index -and $m.Index -lt $setEnd) { $setEnd = $m.Index }
    }

    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add($prefix + (Normalize-TsqlSpace $sql.Substring(0, $setMatch.Index)))
    foreach ($line in @(Format-TsqlSetItems -Text $sql.Substring($setMatch.Index + $setMatch.Length, $setEnd - ($setMatch.Index + $setMatch.Length)) -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }

    if ($null -ne $outputMatch) {
        $outputEnd = $sql.Length
        foreach ($m in @($fromMatch, $whereMatch, $optionMatch)) { if ($null -ne $m -and $m.Index -gt $outputMatch.Index -and $m.Index -lt $outputEnd) { $outputEnd = $m.Index } }
        foreach ($line in @(Format-TsqlCommaClause -Text $sql.Substring($outputMatch.Index + $outputMatch.Length, $outputEnd - ($outputMatch.Index + $outputMatch.Length)) -Keyword 'OUTPUT' -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
    }
    if ($null -ne $fromMatch) {
        $fromEnd = $sql.Length
        foreach ($m in @($whereMatch, $optionMatch)) { if ($null -ne $m -and $m.Index -gt $fromMatch.Index -and $m.Index -lt $fromEnd) { $fromEnd = $m.Index } }
        foreach ($line in @(Format-TsqlFromClause -Text $sql.Substring($fromMatch.Index + $fromMatch.Length, $fromEnd - ($fromMatch.Index + $fromMatch.Length)) -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
    }
    if ($null -ne $whereMatch) {
        $whereEnd = if ($null -ne $optionMatch -and $optionMatch.Index -gt $whereMatch.Index) { $optionMatch.Index } else { $sql.Length }
        foreach ($line in @(Format-TsqlConditionClause -Text $sql.Substring($whereMatch.Index + $whereMatch.Length, $whereEnd - ($whereMatch.Index + $whereMatch.Length)) -Keyword 'WHERE' -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
    }
    if ($null -ne $optionMatch) { [void]$out.Add($prefix + ' OPTION ' + (Normalize-TsqlSpace $sql.Substring($optionMatch.Index + $optionMatch.Length))) }

    if (-not $NoSemicolon) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
    return $out
}

function Format-TsqlDelete {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon, [int]$Depth = 0)
    $sql = Remove-TsqlTrailingSemicolon (Normalize-TsqlSpace $Sql)
    $prefix = ' ' * $Indent
    $outputMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bOUTPUT\b'
    $whereMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bWHERE\b'
    $optionMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bOPTION\b'

    # DELETE alias FROM ... is a T-SQL-specific form. DELETE FROM target ... can
    # safely use the shared core unless OUTPUT/OPTION requires T-SQL handling.
    $aliasDelete = [regex]::Match($sql, '^(?i)DELETE\s+(?!FROM\b)(.+?)\s+FROM\s+')
    if ($aliasDelete.Success) {
        $fromMatch = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bFROM\b'
        $head = Normalize-TsqlSpace $sql.Substring(0, $fromMatch.Index)
        [System.Collections.Generic.List[string]]$out = @()
        [void]$out.Add($prefix + $head)
        $fromEnd = $sql.Length
        foreach ($m in @($whereMatch, $optionMatch)) { if ($null -ne $m -and $m.Index -gt $fromMatch.Index -and $m.Index -lt $fromEnd) { $fromEnd = $m.Index } }
        foreach ($line in @(Format-TsqlFromClause -Text $sql.Substring($fromMatch.Index + $fromMatch.Length, $fromEnd - ($fromMatch.Index + $fromMatch.Length)) -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
        if ($null -ne $whereMatch) {
            $whereEnd = if ($null -ne $optionMatch -and $optionMatch.Index -gt $whereMatch.Index) { $optionMatch.Index } else { $sql.Length }
            foreach ($line in @(Format-TsqlConditionClause -Text $sql.Substring($whereMatch.Index + $whereMatch.Length, $whereEnd - ($whereMatch.Index + $whereMatch.Length)) -Keyword 'WHERE' -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
        }
        if ($null -ne $optionMatch) { [void]$out.Add($prefix + ' OPTION ' + (Normalize-TsqlSpace $sql.Substring($optionMatch.Index + $optionMatch.Length))) }
        if (-not $NoSemicolon) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
        return $out
    }

    if ($null -eq $outputMatch -and $null -eq $optionMatch) {
        return @((Invoke-TsqlCore -Sql ($sql + $(if ($NoSemicolon) { '' } else { ';' }))) -split "`r?`n")
    }

    $headEnd = $sql.Length
    foreach ($m in @($outputMatch, $whereMatch, $optionMatch)) { if ($null -ne $m -and $m.Index -lt $headEnd) { $headEnd = $m.Index } }
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add($prefix + (Normalize-TsqlSpace $sql.Substring(0, $headEnd)))
    if ($null -ne $outputMatch) {
        $outputEnd = $sql.Length
        foreach ($m in @($whereMatch, $optionMatch)) { if ($null -ne $m -and $m.Index -gt $outputMatch.Index -and $m.Index -lt $outputEnd) { $outputEnd = $m.Index } }
        foreach ($line in @(Format-TsqlCommaClause -Text $sql.Substring($outputMatch.Index + $outputMatch.Length, $outputEnd - ($outputMatch.Index + $outputMatch.Length)) -Keyword 'OUTPUT' -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
    }
    if ($null -ne $whereMatch) {
        $whereEnd = if ($null -ne $optionMatch -and $optionMatch.Index -gt $whereMatch.Index) { $optionMatch.Index } else { $sql.Length }
        foreach ($line in @(Format-TsqlConditionClause -Text $sql.Substring($whereMatch.Index + $whereMatch.Length, $whereEnd - ($whereMatch.Index + $whereMatch.Length)) -Keyword 'WHERE' -Indent $Indent -Depth $Depth)) { [void]$out.Add($line) }
    }
    if ($null -ne $optionMatch) { [void]$out.Add($prefix + ' OPTION ' + (Normalize-TsqlSpace $sql.Substring($optionMatch.Index + $optionMatch.Length))) }
    if (-not $NoSemicolon) { $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';' }
    return $out
}

function Format-TsqlView {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon, [int]$Depth = 0)
    $sql = Remove-TsqlTrailingSemicolon (Normalize-TsqlSpace $Sql)
    $as = Get-TsqlFirstTopLevelMatch -Text $sql -Pattern '\bAS\b'
    if ($null -eq $as) { return @((' ' * $Indent) + $sql + $(if ($NoSemicolon) { '' } else { ';' })) }
    $head = Normalize-TsqlSpace $sql.Substring(0, $as.Index)
    $body = $sql.Substring($as.Index + $as.Length).Trim()
    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add((' ' * $Indent) + $head)
    [void]$out.Add((' ' * $Indent) + 'AS')
    foreach ($line in @(Format-TsqlStatement -Statement $body -Indent $Indent -NoSemicolon:$NoSemicolon -Depth ($Depth + 1))) { [void]$out.Add($line) }
    return $out
}

function Format-TsqlRoutine {
    param([string]$Sql, [int]$Indent = 0)

    # Stored-program bodies can contain arbitrary control flow and dynamic SQL.
    # Preserve statement boundaries and only normalize indentation/casing safely.
    $normalized = $Sql -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = @($normalized -split "`n")
    if ($lines.Count -eq 1) {
        return @((Wrap-TsqlWords -Text (Normalize-TsqlSpace $Sql) -FirstPrefix (' ' * $Indent) -ContinuationPrefix ((' ' * $Indent) + (' ' * $script:IndentSize))))
    }

    $out = New-Object System.Collections.Generic.List[string]
    $level = $Indent
    foreach ($raw in $lines) {
        $line = Normalize-TsqlSpace $raw
        if (-not $line) { continue }
        if ($line -match '^(?i)(END\b|END\s+TRY\b|END\s+CATCH\b|ELSE\b)') { $level = [Math]::Max($Indent, $level - $script:IndentSize) }
        [void]$out.Add((' ' * $level) + (Convert-TsqlKeywords $line))
        if ($line -match '^(?i)(BEGIN\b|BEGIN\s+TRY\b|BEGIN\s+CATCH\b|ELSE\b)' -and $line -notmatch '^(?i)BEGIN\s+(TRAN|TRANSACTION)\b') { $level += $script:IndentSize }
    }
    return $out
}

function Format-TsqlStatement {
    param([string]$Statement, [int]$Indent = 0, [switch]$NoSemicolon, [int]$Depth = 0)
    $sql = Normalize-TsqlSpace $Statement
    if (-not $sql) { return @() }
    if ($sql.StartsWith(';') -and $sql -match '^(?i);\s*WITH\b') { $sql = $sql.Substring(1).TrimStart() }

    if ($sql -match '^(?i)WITH\b') { return @(Format-TsqlWith -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth) }
    if ($sql -match '^(?i)SELECT\b') { return @(Format-TsqlSelect -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth) }
    if ($sql -match '^(?i)INSERT\b') { return @(Format-TsqlInsert -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth) }
    if ($sql -match '^(?i)UPDATE\b') { return @(Format-TsqlUpdate -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth) }
    if ($sql -match '^(?i)DELETE\b') { return @(Format-TsqlDelete -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth) }
    if ($sql -match '^(?i)CREATE\s+(OR\s+ALTER\s+)?VIEW\b|^ALTER\s+VIEW\b') { return @(Format-TsqlView -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon -Depth $Depth) }
    if ($sql -match '^(?i)(CREATE|ALTER)\s+(OR\s+ALTER\s+)?(PROC|PROCEDURE|FUNCTION|TRIGGER)\b|^CREATE\s+OR\s+ALTER\s+(PROC|PROCEDURE|FUNCTION|TRIGGER)\b') { return @(Format-TsqlRoutine -Sql $Statement -Indent $Indent) }
    if ($sql -match '^(?i)CREATE\s+TABLE\b') { return @((Invoke-TsqlCore -Sql ($sql + $(if ($NoSemicolon) { '' } else { ';' }))) -split "`r?`n") }

    $line = (' ' * $Indent) + (Convert-TsqlKeywords (Remove-TsqlTrailingSemicolon $sql))
    if (-not $NoSemicolon) { $line += ';' }
    if ($line.Length -le $script:MaxLineLength) { return @($line) }
    return @(Wrap-TsqlWords -Text (Convert-TsqlKeywords (Remove-TsqlTrailingSemicolon $sql)) -FirstPrefix (' ' * $Indent) -ContinuationPrefix ((' ' * $Indent) + (' ' * $script:IndentSize)))
}

function Split-TsqlTopLevelStatements {
    param([string]$Sql)
    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0
    for ($i = 0; $i -lt $Sql.Length; $i++) {
        if ($Sql[$i] -eq '(') { $depth++ }
        elseif ($Sql[$i] -eq ')' -and $depth -gt 0) { $depth-- }
        elseif ($Sql[$i] -eq ';' -and $depth -eq 0) {
            $piece = $Sql.Substring($start, $i - $start).Trim()
            if ($piece) { [void]$items.Add($piece) }
            $start = $i + 1
        }
    }
    $tail = $Sql.Substring($start).Trim()
    if ($tail) { [void]$items.Add($tail) }
    return $items
}

function Format-TsqlBatch {
    param([string]$Batch)
    if ([string]::IsNullOrWhiteSpace($Batch)) { return '' }
    $trimmed = $Batch.Trim()

    if ((Normalize-TsqlSpace $trimmed) -match '^(?i)(CREATE|ALTER)\s+(OR\s+ALTER\s+)?(PROC|PROCEDURE|FUNCTION|TRIGGER)\b|^CREATE\s+OR\s+ALTER\s+(PROC|PROCEDURE|FUNCTION|TRIGGER)\b') {
        return ((Format-TsqlRoutine -Sql $trimmed) -join [Environment]::NewLine)
    }

    $statements = @(Split-TsqlTopLevelStatements $trimmed)
    if ($statements.Count -eq 0) { return '' }
    $blocks = New-Object System.Collections.Generic.List[string]
    foreach ($statement in $statements) {
        $lines = @(Format-TsqlStatement -Statement $statement)
        if ($lines.Count -gt 0) { [void]$blocks.Add(($lines -join [Environment]::NewLine)) }
    }
    return ($blocks -join ([Environment]::NewLine + [Environment]::NewLine))
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$protected = Protect-TsqlText $inputSql
$protected = Convert-TsqlKeywords $protected
$normalizedLines = @((($protected -replace "`r`n", "`n") -replace "`r", "`n") -split "`n")

$final = New-Object System.Collections.Generic.List[string]
$batchLines = New-Object System.Collections.Generic.List[string]

function Flush-TsqlBatch {
    if ($batchLines.Count -eq 0) { return }
    $batch = $batchLines -join [Environment]::NewLine
    $formatted = Format-TsqlBatch -Batch $batch
    if ($formatted) {
        foreach ($line in @($formatted -split "`r?`n")) { [void]$final.Add($line) }
    }
    $batchLines.Clear()
}

foreach ($line in $normalizedLines) {
    if ($line -match '^\s*(?i:GO)(?:\s+\d+)?\s*$') {
        Flush-TsqlBatch
        if ($final.Count -gt 0 -and $final[$final.Count - 1] -eq '') { $final.RemoveAt($final.Count - 1) }
        [void]$final.Add(($line.Trim() -replace '^(?i)go', 'GO'))
    }
    else { [void]$batchLines.Add($line) }
}
Flush-TsqlBatch

$formattedSql = ($final -join [Environment]::NewLine).TrimEnd()
$formattedSql = Restore-TsqlText $formattedSql
[Console]::Out.Write($formattedSql)
