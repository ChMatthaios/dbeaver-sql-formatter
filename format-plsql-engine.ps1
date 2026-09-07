<#
    Oracle SQL / PL-SQL formatter.

    Shared SQL grammar is delegated to the common formatter where possible.
    Oracle-specific clauses are reconstructed here, and PL/SQL program units are
    formatted conservatively so procedure/package bodies are not flattened.
#>

$ErrorActionPreference = 'Stop'
$script:MaxLineLength = 120
$script:QQuoteMap = @{}
$script:QQuoteIndex = 0

$CoreFormatter = Join-Path $PSScriptRoot 'format-sql-core.ps1'
$MergeFormatter = Join-Path $PSScriptRoot 'format-merge.ps1'

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
    }
    catch {
        # Local settings must never make DBeaver formatting fail.
    }
}

function Protect-OracleQQuotes {
    param([string]$Text)

    if ($null -eq $Text) { return '' }
    $out = New-Object System.Text.StringBuilder
    $i = 0

    while ($i -lt $Text.Length) {
        $isQ = ($Text[$i] -eq 'q' -or $Text[$i] -eq 'Q')
        if ($isQ -and $i + 2 -lt $Text.Length -and $Text[$i + 1] -eq "'") {
            $open = $Text[$i + 2]
            $close = switch ($open) {
                '[' { ']' }
                '{' { '}' }
                '(' { ')' }
                '<' { '>' }
                default { [string]$open }
            }
            $j = $i + 3
            $end = -1
            while ($j + 1 -lt $Text.Length) {
                if ([string]$Text[$j] -eq $close -and $Text[$j + 1] -eq "'") {
                    $end = $j + 1
                    break
                }
                $j++
            }
            if ($end -gt $i) {
                $token = ('__PLSQL_Q_{0:D6}__' -f $script:QQuoteIndex)
                $script:QQuoteIndex++
                $script:QQuoteMap[$token] = $Text.Substring($i, $end - $i + 1)
                [void]$out.Append($token)
                $i = $end + 1
                continue
            }
        }
        [void]$out.Append($Text[$i])
        $i++
    }
    return $out.ToString()
}

function Restore-OracleQQuotes {
    param([string]$Text)
    $out = $Text
    foreach ($key in $script:QQuoteMap.Keys) {
        $out = $out.Replace($key, [string]$script:QQuoteMap[$key])
    }
    return $out
}

function Normalize-OracleSpace {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim())
}

function Remove-OracleTrailingSemicolon {
    param([string]$Text)
    return ([regex]::Replace($Text.Trim(), ';\s*$', '')).Trim()
}

function Invoke-OracleCore {
    param([string]$Sql)
    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $CoreFormatter |
        Out-String
    return $formatted.TrimEnd("`r", "`n")
}

function Invoke-OracleMerge {
    param([string]$Sql)
    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $MergeFormatter |
        Out-String
    return $formatted.TrimEnd("`r", "`n")
}

function Get-OracleTopLevelMatches {
    param([string]$Text, [string]$Pattern)

    $all = [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $result = New-Object System.Collections.Generic.List[object]
    $depth = 0
    $single = $false
    $double = $false
    $matchIndex = 0

    for ($i = 0; $i -lt $Text.Length; $i++) {
        while ($matchIndex -lt $all.Count -and $all[$matchIndex].Index -lt $i) { $matchIndex++ }

        $ch = $Text[$i]
        if ($single) {
            if ($ch -eq "'") {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
                $single = $false
            }
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i++; continue }
                $double = $false
            }
            continue
        }

        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') { if ($depth -gt 0) { $depth-- }; continue }

        if ($matchIndex -lt $all.Count -and $all[$matchIndex].Index -eq $i) {
            if ($depth -eq 0) { [void]$result.Add($all[$matchIndex]) }
            $i += $all[$matchIndex].Length - 1
            $matchIndex++
        }
    }
    return $result
}

function Get-OracleFirstTopLevelMatch {
    param([string]$Text, [string]$Pattern)
    $matches = @(Get-OracleTopLevelMatches -Text $Text -Pattern $Pattern)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Split-OracleTopLevelComma {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $single = $false
    $double = $false
    $start = 0

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($single) {
            if ($ch -eq "'") {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
                $single = $false
            }
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i++; continue }
                $double = $false
            }
            continue
        }
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') { if ($depth -gt 0) { $depth-- }; continue }
        if ($ch -eq ',' -and $depth -eq 0) {
            $piece = Normalize-OracleSpace $Text.Substring($start, $i - $start)
            if ($piece) { [void]$items.Add($piece) }
            $start = $i + 1
        }
    }
    $tail = Normalize-OracleSpace $Text.Substring($start)
    if ($tail) { [void]$items.Add($tail) }
    return $items
}

function Split-OracleTopLevelLogical {
    param([string]$Text)

    $text = Normalize-OracleSpace $Text
    $matches = @(Get-OracleTopLevelMatches -Text $text -Pattern '\b(AND|OR)\b')
    if ($matches.Count -eq 0) {
        return @([pscustomobject]@{ Op = ''; Text = $text })
    }

    $items = New-Object System.Collections.Generic.List[object]
    $start = 0
    $op = ''
    $betweenPending = $false

    foreach ($m in $matches) {
        $before = $text.Substring($start, $m.Index - $start)
        if ($m.Value.ToUpperInvariant() -eq 'AND' -and $before -match '(?i)\bBETWEEN\b[^\r\n]*$') {
            continue
        }
        $piece = Normalize-OracleSpace $before
        if ($piece) { [void]$items.Add([pscustomobject]@{ Op = $op; Text = $piece }) }
        $op = $m.Value.ToUpperInvariant()
        $start = $m.Index + $m.Length
    }
    $tail = Normalize-OracleSpace $text.Substring($start)
    if ($tail) { [void]$items.Add([pscustomobject]@{ Op = $op; Text = $tail }) }
    return $items
}

function Format-OracleCommaClause {
    param([string]$Text, [string]$Keyword, [int]$Indent = 0)

    $items = @(Split-OracleTopLevelComma (Normalize-OracleSpace $Text))
    $out = New-Object System.Collections.Generic.List[string]
    $firstPrefix = (' ' * $Indent) + $Keyword + ' '
    $continuePrefix = ' ' * $firstPrefix.Length

    for ($i = 0; $i -lt $items.Count; $i++) {
        $prefix = if ($i -eq 0) { $firstPrefix } else { $continuePrefix }
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        [void]$out.Add($prefix + $items[$i] + $suffix)
    }
    return $out
}

function Format-OracleConditionClause {
    param([string]$Text, [string]$Keyword, [int]$Indent = 0)

    $logical = @(Split-OracleTopLevelLogical (Normalize-OracleSpace $Text))
    $out = New-Object System.Collections.Generic.List[string]
    $firstPrefix = (' ' * $Indent) + $Keyword + ' '
    $column = $firstPrefix.Length

    for ($i = 0; $i -lt $logical.Count; $i++) {
        if ($i -eq 0) {
            $prefix = $firstPrefix
        }
        else {
            $op = $logical[$i].Op
            $prefix = (' ' * [Math]::Max($Indent, $column - $op.Length - 1)) + $op + ' '
        }
        [void]$out.Add($prefix + $logical[$i].Text)
    }
    return $out
}

function Add-OracleSemicolon {
    param([System.Collections.Generic.List[string]]$Lines, [switch]$NoSemicolon)
    if (-not $NoSemicolon -and $Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -notmatch ';\s*$') {
        $Lines[$Lines.Count - 1] = $Lines[$Lines.Count - 1].TrimEnd() + ';'
    }
}

function Format-OracleSelect {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon)

    $sql = Remove-OracleTrailingSemicolon (Normalize-OracleSpace $Sql)
    $tailPattern = '\b(START\s+WITH|CONNECT\s+BY(?:\s+NOCYCLE)?|ORDER\s+BY|OFFSET|FETCH\s+(?:FIRST|NEXT)|FOR\s+UPDATE|MODEL)\b'
    $tailMatches = @(Get-OracleTopLevelMatches -Text $sql -Pattern $tailPattern)
    $special = @($tailMatches | Where-Object { $_.Value -match '^(?i)(START\s+WITH|CONNECT\s+BY|FOR\s+UPDATE|MODEL|OFFSET)' })

    $baseSql = $sql
    $appendMatches = @()
    if ($special.Count -gt 0) {
        $firstSpecial = $special[0].Index
        $eligible = @($tailMatches | Where-Object { $_.Index -le $firstSpecial })
        $tailStart = if ($eligible.Count -gt 0) { $eligible[0].Index } else { $firstSpecial }
        $baseSql = $sql.Substring(0, $tailStart).TrimEnd()
        $appendMatches = @($tailMatches | Where-Object { $_.Index -ge $tailStart })
    }

    # PL/SQL SELECT ... INTO ... FROM ... is not the same construct as T-SQL SELECT INTO.
    $into = Get-OracleFirstTopLevelMatch -Text $baseSql -Pattern '\bINTO\b'
    $from = Get-OracleFirstTopLevelMatch -Text $baseSql -Pattern '\bFROM\b'
    $intoText = ''
    if ($null -ne $into -and $null -ne $from -and $into.Index -lt $from.Index) {
        $intoText = Normalize-OracleSpace $baseSql.Substring($into.Index + $into.Length, $from.Index - ($into.Index + $into.Length))
        $baseSql = ($baseSql.Substring(0, $into.Index).TrimEnd() + ' ' + $baseSql.Substring($from.Index)).Trim()
    }

    $core = Invoke-OracleCore ($baseSql + ';')
    $core = Remove-OracleTrailingSemicolon $core
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($core -split "`r?`n")) {
        [void]$lines.Add((' ' * $Indent) + $line)
    }

    if ($intoText) {
        $insertAt = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].TrimStart() -match '^(?i)FROM\b') { $insertAt = $i; break }
        }
        $intoLine = (' ' * $Indent) + '  INTO ' + $intoText
        if ($insertAt -ge 0) { $lines.Insert($insertAt, $intoLine) } else { [void]$lines.Add($intoLine) }
    }

    if ($appendMatches.Count -gt 0) {
        for ($i = 0; $i -lt $appendMatches.Count; $i++) {
            $m = $appendMatches[$i]
            $next = if ($i -lt $appendMatches.Count - 1) { $appendMatches[$i + 1].Index } else { $sql.Length }
            $body = Normalize-OracleSpace $sql.Substring($m.Index + $m.Length, $next - ($m.Index + $m.Length))
            $name = ($m.Value -replace '\s+', ' ').ToUpperInvariant()

            if ($name -eq 'START WITH') {
                foreach ($line in @(Format-OracleConditionClause -Text $body -Keyword ' START WITH' -Indent $Indent)) { [void]$lines.Add($line) }
            }
            elseif ($name -match '^CONNECT BY') {
                $prefix = if ($name -match 'NOCYCLE') { ' CONNECT BY NOCYCLE' } else { ' CONNECT BY' }
                foreach ($line in @(Format-OracleConditionClause -Text $body -Keyword $prefix -Indent $Indent)) { [void]$lines.Add($line) }
            }
            elseif ($name -eq 'ORDER BY') {
                foreach ($line in @(Format-OracleCommaClause -Text $body -Keyword ' ORDER BY' -Indent $Indent)) { [void]$lines.Add($line) }
            }
            elseif ($name -eq 'OFFSET') {
                [void]$lines.Add((' ' * $Indent) + ' OFFSET ' + $body)
            }
            elseif ($name -match '^FETCH\s+(FIRST|NEXT)$') {
                [void]$lines.Add((' ' * $Indent) + ' FETCH ' + ($name -replace '^FETCH\s+', '') + ' ' + $body)
            }
            elseif ($name -eq 'FOR UPDATE') {
                [void]$lines.Add((' ' * $Indent) + '   FOR UPDATE' + $(if ($body) { ' ' + $body } else { '' }))
            }
            elseif ($name -eq 'MODEL') {
                [void]$lines.Add((' ' * $Indent) + ' MODEL' + $(if ($body) { ' ' + $body } else { '' }))
            }
        }
    }

    Add-OracleSemicolon -Lines $lines -NoSemicolon:$NoSemicolon
    return $lines
}

function Format-OracleReturning {
    param([string]$Tail, [int]$Indent = 0)

    $tail = Normalize-OracleSpace $Tail
    $into = Get-OracleFirstTopLevelMatch -Text $tail -Pattern '\bINTO\b'
    $returnText = if ($null -ne $into) { $tail.Substring(0, $into.Index).Trim() } else { $tail }
    $intoText = if ($null -ne $into) { $tail.Substring($into.Index + $into.Length).Trim() } else { '' }
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($line in @(Format-OracleCommaClause -Text $returnText -Keyword 'RETURNING' -Indent $Indent)) { [void]$out.Add($line) }
    if ($intoText) {
        foreach ($line in @(Format-OracleCommaClause -Text $intoText -Keyword '     INTO' -Indent $Indent)) { [void]$out.Add($line) }
    }
    return $out
}

function Format-OracleInsertAll {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon)

    $sql = Remove-OracleTrailingSemicolon (Normalize-OracleSpace $Sql)
    $head = [regex]::Match($sql, '^(?i)INSERT\s+(ALL|FIRST)\b')
    if (-not $head.Success) { return $null }
    $select = Get-OracleFirstTopLevelMatch -Text $sql -Pattern '\bSELECT\b'
    if ($null -eq $select) {
        return @((' ' * $Indent) + $sql + $(if ($NoSemicolon) { '' } else { ';' }))
    }

    $out = New-Object System.Collections.Generic.List[string]
    [void]$out.Add((' ' * $Indent) + 'INSERT ' + $head.Groups[1].Value.ToUpperInvariant())
    $between = $sql.Substring($head.Length, $select.Index - $head.Length).Trim()
    $intoMatches = @(Get-OracleTopLevelMatches -Text $between -Pattern '\bINTO\b')

    if ($intoMatches.Count -gt 0) {
        for ($i = 0; $i -lt $intoMatches.Count; $i++) {
            $m = $intoMatches[$i]
            $next = if ($i -lt $intoMatches.Count - 1) { $intoMatches[$i + 1].Index } else { $between.Length }
            $body = Normalize-OracleSpace $between.Substring($m.Index + $m.Length, $next - ($m.Index + $m.Length))
            [void]$out.Add((' ' * $Indent) + '  INTO ' + $body)
        }
    }
    elseif ($between) {
        [void]$out.Add((' ' * ($Indent + 2)) + $between)
    }

    $selectSql = $sql.Substring($select.Index)
    foreach ($line in @(Format-OracleSelect -Sql $selectSql -Indent $Indent -NoSemicolon)) { [void]$out.Add($line) }
    Add-OracleSemicolon -Lines $out -NoSemicolon:$NoSemicolon
    return $out
}

function Format-OracleDml {
    param([string]$Sql, [int]$Indent = 0, [switch]$NoSemicolon)

    $sql = Remove-OracleTrailingSemicolon (Normalize-OracleSpace $Sql)
    if ($sql -match '^(?i)INSERT\s+(ALL|FIRST)\b') {
        return @(Format-OracleInsertAll -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon)
    }

    $returning = Get-OracleFirstTopLevelMatch -Text $sql -Pattern '\bRETURNING\b'
    $base = $sql
    $tail = ''
    if ($null -ne $returning) {
        $tail = $sql.Substring($returning.Index + $returning.Length).Trim()
        $base = $sql.Substring(0, $returning.Index).TrimEnd()
    }

    $core = Invoke-OracleCore ($base + ';')
    $core = Remove-OracleTrailingSemicolon $core
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($core -split "`r?`n")) { [void]$out.Add((' ' * $Indent) + $line) }
    if ($tail) {
        foreach ($line in @(Format-OracleReturning -Tail $tail -Indent $Indent)) { [void]$out.Add($line) }
    }
    Add-OracleSemicolon -Lines $out -NoSemicolon:$NoSemicolon
    return $out
}

function Format-OracleStatement {
    param([string]$Statement, [int]$Indent = 0, [switch]$NoSemicolon)

    $sql = Normalize-OracleSpace $Statement
    if (-not $sql) { return @() }
    if ($sql -match '^(?i)SELECT\b') { return @(Format-OracleSelect -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon) }
    if ($sql -match '^(?i)(INSERT|UPDATE|DELETE)\b') { return @(Format-OracleDml -Sql $sql -Indent $Indent -NoSemicolon:$NoSemicolon) }
    if ($sql -match '^(?i)MERGE\b') {
        $merge = Invoke-OracleMerge $sql
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($line in @($merge -split "`r?`n")) { [void]$out.Add((' ' * $Indent) + $line) }
        if ($NoSemicolon -and $out.Count -gt 0) { $out[$out.Count - 1] = $out[$out.Count - 1] -replace ';\s*$', '' }
        return $out
    }
    if ($sql -match '^(?i)WITH\b') {
        $core = Invoke-OracleCore ($sql + $(if ($sql -match ';\s*$') { '' } else { ';' }))
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($line in @($core -split "`r?`n")) { [void]$out.Add((' ' * $Indent) + $line) }
        if ($NoSemicolon -and $out.Count -gt 0) { $out[$out.Count - 1] = $out[$out.Count - 1] -replace ';\s*$', '' }
        return $out
    }

    return @((' ' * $Indent) + (Remove-OracleTrailingSemicolon $sql) + $(if ($NoSemicolon) { '' } else { ';' }))
}

function Convert-OracleProgramKeywords {
    param([string]$Line)

    $trimmed = $Line.Trim()
    if (-not $trimmed) { return '' }
    if ($trimmed.StartsWith('--') -or $trimmed.StartsWith('/*') -or $trimmed -eq '/') { return $trimmed }

    $keywords = @(
        'create','or','replace','editionable','noneditionable','procedure','function','package','body','trigger','type',
        'is','as','authid','definer','current_user','declare','begin','end','exception','when','then','else','elsif','if',
        'loop','for','while','in','reverse','exit','continue','return','raise','pragma','cursor','open','fetch','close','into',
        'bulk','collect','forall','save','exceptions','select','insert','update','delete','merge','from','where','and','or',
        'not','null','values','set','returning','commit','rollback','savepoint','execute','immediate','using','out','nocopy',
        'constant','default','record','table','index','by','binary_integer','pls_integer','varchar2','number','date','timestamp',
        'clob','blob','boolean','true','false','rowtype','type','case','end','others'
    )

    $out = New-Object System.Text.StringBuilder
    $segment = New-Object System.Text.StringBuilder
    $single = $false
    $double = $false

    function Flush-OracleKeywordSegment {
        param([System.Text.StringBuilder]$Builder, [System.Text.StringBuilder]$Target, [string[]]$Words)
        if ($Builder.Length -eq 0) { return }
        $text = $Builder.ToString()
        foreach ($kw in $Words) {
            $text = [regex]::Replace($text, '(?i)(?<![A-Z0-9_$#])' + [regex]::Escape($kw) + '(?![A-Z0-9_$#])', { param($m) $m.Value.ToUpperInvariant() })
        }
        [void]$Target.Append($text)
        [void]$Builder.Clear()
    }

    for ($i = 0; $i -lt $trimmed.Length; $i++) {
        $ch = $trimmed[$i]
        if ($single) {
            [void]$out.Append($ch)
            if ($ch -eq "'") {
                if ($i + 1 -lt $trimmed.Length -and $trimmed[$i + 1] -eq "'") { $i++; [void]$out.Append("'") }
                else { $single = $false }
            }
            continue
        }
        if ($double) {
            [void]$out.Append($ch)
            if ($ch -eq '"') {
                if ($i + 1 -lt $trimmed.Length -and $trimmed[$i + 1] -eq '"') { $i++; [void]$out.Append('"') }
                else { $double = $false }
            }
            continue
        }
        if ($ch -eq "'") {
            Flush-OracleKeywordSegment -Builder $segment -Target $out -Words $keywords
            [void]$out.Append($ch); $single = $true; continue
        }
        if ($ch -eq '"') {
            Flush-OracleKeywordSegment -Builder $segment -Target $out -Words $keywords
            [void]$out.Append($ch); $double = $true; continue
        }
        if ($ch -eq '-' -and $i + 1 -lt $trimmed.Length -and $trimmed[$i + 1] -eq '-') {
            Flush-OracleKeywordSegment -Builder $segment -Target $out -Words $keywords
            [void]$out.Append($trimmed.Substring($i)); break
        }
        [void]$segment.Append($ch)
    }
    Flush-OracleKeywordSegment -Builder $segment -Target $out -Words $keywords
    return $out.ToString()
}

function Test-OracleStatementTerminated {
    param([string]$Text)

    $single = $false
    $double = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($single) {
            if ($ch -eq "'") {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
                $single = $false
            }
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i++; continue }
                $double = $false
            }
            continue
        }
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
    }
    return (-not $single -and -not $double -and $Text.TrimEnd().EndsWith(';'))
}

function Format-OracleProgram {
    param([string]$Sql)

    $normalized = $Sql -replace "`r`n", "`n" -replace "`r", "`n"
    $inputLines = @($normalized -split "`n")
    $out = New-Object System.Collections.Generic.List[string]
    $indent = 0
    $i = 0
    $lastStructural = ''

    while ($i -lt $inputLines.Count) {
        $raw = $inputLines[$i].Trim()
        if (-not $raw) { $i++; continue }
        if ($raw -eq '/') { [void]$out.Add('/'); $i++; continue }
        if ($raw.StartsWith('--') -or $raw.StartsWith('/*')) {
            [void]$out.Add((' ' * $indent) + $raw)
            $i++
            continue
        }

        $upper = $raw.ToUpperInvariant()
        $isSql = $upper -match '^(SELECT|INSERT|UPDATE|DELETE|MERGE|WITH)\b'
        if ($isSql) {
            $parts = New-Object System.Collections.Generic.List[string]
            [void]$parts.Add($raw)
            $j = $i
            while (-not (Test-OracleStatementTerminated ($parts -join ' ')) -and $j + 1 -lt $inputLines.Count) {
                $j++
                [void]$parts.Add($inputLines[$j].Trim())
            }
            $statement = $parts -join ' '
            foreach ($line in @(Format-OracleStatement -Statement $statement -Indent $indent)) { [void]$out.Add($line) }
            $i = $j + 1
            continue
        }

        $dedentBefore = $upper -match '^(END\b|ELSIF\b|ELSE\b|EXCEPTION\b)'
        if ($dedentBefore) { $indent = [Math]::Max(0, $indent - 2) }
        if ($upper -match '^BEGIN\b' -and $lastStructural -match '^(DECLARE|AS|IS)$') {
            $indent = [Math]::Max(0, $indent - 2)
        }

        $formatted = Convert-OracleProgramKeywords $raw
        [void]$out.Add((' ' * $indent) + $formatted)

        if ($upper -match '^DECLARE\b') {
            $indent += 2; $lastStructural = 'DECLARE'
        }
        elseif ($upper -match '^(AS|IS)\b' -and $upper -notmatch ':=') {
            $indent += 2; $lastStructural = ($upper -split '\s+')[0]
        }
        elseif ($upper -match '^BEGIN\b') {
            $indent += 2; $lastStructural = 'BEGIN'
        }
        elseif ($upper -match '^EXCEPTION\b') {
            $indent += 2; $lastStructural = 'EXCEPTION'
        }
        elseif ($upper -match '^(IF\b.*\bTHEN\b|ELSIF\b.*\bTHEN\b|ELSE\b|LOOP\b|FOR\b.*\bLOOP\b|WHILE\b.*\bLOOP\b|CASE\b)') {
            $indent += 2; $lastStructural = 'CONTROL'
        }
        elseif ($upper -match '^END\b') {
            $lastStructural = 'END'
        }
        else {
            $lastStructural = ''
        }
        $i++
    }
    return ($out -join [Environment]::NewLine).TrimEnd()
}

function Test-OracleProgramUnit {
    param([string]$Sql)
    $n = Normalize-OracleSpace $Sql
    return ($n -match '^(?i)(DECLARE\b|BEGIN\b|CREATE\s+(?:OR\s+REPLACE\s+)?(?:EDITIONABLE\s+|NONEDITIONABLE\s+)?(?:PROCEDURE|FUNCTION|PACKAGE(?:\s+BODY)?|TRIGGER|TYPE\s+BODY)\b)')
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$protected = Protect-OracleQQuotes $inputSql
if (Test-OracleProgramUnit $protected) {
    $formatted = Format-OracleProgram $protected
}
else {
    $lines = @(Format-OracleStatement -Statement $protected)
    $formatted = $lines -join [Environment]::NewLine
}

$formatted = Restore-OracleQQuotes $formatted
[Console]::Out.Write($formatted.TrimEnd())