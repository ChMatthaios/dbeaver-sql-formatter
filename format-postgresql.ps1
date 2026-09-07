<#
    PostgreSQL structural formatter.

    This script reuses the common DB2-compatible core for shared SQL grammar and
    adds PostgreSQL-specific statement handling around it. It is intentionally
    conservative: PostgreSQL dollar-quoted bodies, strings, comments and quoted
    identifiers are protected before any structural processing.
#>

$ErrorActionPreference = 'Stop'
$script:MaxLineLength = 120
$script:ProtectedMap = @{}
$script:ProtectedIndex = 0

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
    catch { }
}

$CoreFormatter = Join-Path $PSScriptRoot 'format-sql-core.ps1'

function New-PgProtectedToken {
    param([string]$Kind, [string]$Value)
    $script:ProtectedIndex++
    $token = "__SQLFMT_PG_${Kind}_$script:ProtectedIndex`__"
    $script:ProtectedMap[$token] = $Value
    return $token
}

function Protect-PgText {
    param([string]$Sql)

    $script:ProtectedMap = @{}
    $script:ProtectedIndex = 0

    # PostgreSQL dollar-quoted text must be protected before comments/strings,
    # because it may itself contain quotes, comments and semicolons.
    $Sql = [regex]::Replace(
        $Sql,
        '(?s)(\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$).*?\1',
        { param($m) New-PgProtectedToken -Kind 'DOLLAR' -Value $m.Value }
    )
    $Sql = [regex]::Replace($Sql, '/\*[\s\S]*?\*/', { param($m) New-PgProtectedToken -Kind 'BCOM' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, "'(?:''|[^'])*'", { param($m) New-PgProtectedToken -Kind 'STR' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '"(?:""|[^"])*"', { param($m) New-PgProtectedToken -Kind 'DQS' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '--[^\r\n]*', { param($m) New-PgProtectedToken -Kind 'LCOM' -Value $m.Value })
    return $Sql
}

function Restore-PgText {
    param([string]$Sql)
    foreach ($key in ($script:ProtectedMap.Keys | Sort-Object Length -Descending)) {
        $Sql = $Sql.Replace($key, $script:ProtectedMap[$key])
    }
    return $Sql
}

function Convert-PgKeywords {
    param([string]$Sql)

    $keywords = @(
        'select','distinct','from','where','and','or','not','null','is','in','exists','between','like','ilike',
        'inner','left','right','full','cross','outer','join','on','group','by','having','order','asc','desc',
        'fetch','first','row','rows','only','limit','offset','union','all','except','intersect','case','when','then',
        'else','end','as','over','partition','filter','insert','into','values','update','set','delete','merge','using',
        'matched','create','replace','procedure','function','returns','language','begin','declare','if','elseif','loop',
        'table','view','index','schema','constraint','primary','key','foreign','references','check','default','alter',
        'add','column','current','timestamp','user','with','recursive','materialized','lateral','returning','conflict',
        'do','nothing','excluded','true','false','temp','temporary','unnest','array','generated','identity','serial',
        'bigserial','json','jsonb','variadic','overriding','system','value','concurrently','deferrable','initially',
        'for','share','no','nowait','skip','locked'
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

function Normalize-PgSpace {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text = $Text -replace '[\r\n\t]+', ' '
    $Text = $Text -replace '\s+', ' '
    $Text = $Text -replace '\s+,', ','
    $Text = $Text -replace ',\s*', ', '
    $Text = $Text -replace '\s+;', ';'
    return $Text.Trim()
}

function Get-PgParenDepthAt {
    param([string]$Text, [int]$Index)
    $depth = 0
    for ($i = 0; $i -lt $Index; $i++) {
        if ($Text[$i] -eq '(') { $depth++ }
        elseif ($Text[$i] -eq ')' -and $depth -gt 0) { $depth-- }
    }
    return $depth
}

function Get-PgTopLevelMatch {
    param([string]$Text, [string]$Pattern)
    $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $rx.Matches($Text)) {
        if ((Get-PgParenDepthAt -Text $Text -Index $m.Index) -eq 0) { return $m }
    }
    return $null
}

function Split-PgTopLevelComma {
    param([string]$Text)
    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0
    $start = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '(') { $depth++ }
        elseif ($Text[$i] -eq ')' -and $depth -gt 0) { $depth-- }
        elseif ($Text[$i] -eq ',' -and $depth -eq 0) {
            $piece = Normalize-PgSpace $Text.Substring($start, $i - $start)
            if ($piece) { $items.Add($piece) }
            $start = $i + 1
        }
    }
    $tail = Normalize-PgSpace $Text.Substring($start)
    if ($tail) { $items.Add($tail) }
    return $items
}

function Invoke-PgCoreFormatter {
    param([string]$Sql)
    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $CoreFormatter |
        Out-String
    return $formatted.TrimEnd("`r", "`n")
}

function Remove-PgTrailingSemicolon {
    param([string]$Text)
    return ($Text.TrimEnd() -replace ';\s*$', '')
}

function Format-PgSetItems {
    param([string]$Text, [int]$Indent = 0)
    $items = @(Split-PgTopLevelComma $Text)
    $prefix = ' ' * $Indent
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $out.Add($prefix + $(if ($i -eq 0) { '   SET ' } else { '       ' }) + $items[$i] + $suffix)
    }
    return $out
}

function Format-PgReturning {
    param([string]$Text, [int]$Indent = 0)
    $text = Normalize-PgSpace $Text
    if (-not $text) { return @() }
    $prefix = (' ' * $Indent) + 'RETURNING '
    if (($prefix + $text).Length -le $script:MaxLineLength) { return @($prefix + $text) }

    $items = @(Split-PgTopLevelComma $text)
    $out = New-Object System.Collections.Generic.List[string]
    $next = ' ' * $prefix.Length
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $out.Add($(if ($i -eq 0) { $prefix } else { $next }) + $items[$i] + $suffix)
    }
    return $out
}

function Format-PgWhere {
    param([string]$Text, [int]$Indent = 0)
    $fake = 'SELECT 1 WHERE ' + (Normalize-PgSpace $Text)
    $formatted = Invoke-PgCoreFormatter -Sql $fake
    $lines = @($formatted -split "`r?`n")
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = Remove-PgTrailingSemicolon $lines[$i]
        if ($Indent -gt 0) { $line = (' ' * $Indent) + $line }
        $out.Add($line)
    }
    return $out
}

function Format-PgFromLike {
    param([string]$Keyword, [string]$Text, [int]$Indent = 0)
    $prefix = (' ' * $Indent) + $(switch ($Keyword) {
        'FROM'  { '  FROM ' }
        'USING' { ' USING ' }
        default { $Keyword + ' ' }
    })
    $text = Normalize-PgSpace $Text
    if (($prefix + $text).Length -le $script:MaxLineLength) { return @($prefix + $text) }

    $items = @(Split-PgTopLevelComma $text)
    if ($items.Count -le 1) { return @($prefix + $text) }
    $out = New-Object System.Collections.Generic.List[string]
    $next = ' ' * $prefix.Length
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $out.Add($(if ($i -eq 0) { $prefix } else { $next }) + $items[$i] + $suffix)
    }
    return $out
}

function Format-PgSelect {
    param([string]$Sql)
    $sql = Remove-PgTrailingSemicolon (Normalize-PgSpace $Sql)
    $lockMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bFOR\s+(?:NO\s+KEY\s+UPDATE|KEY\s+SHARE|UPDATE|SHARE)\b'
    $lockText = ''
    if ($null -ne $lockMatch) {
        $lockText = Normalize-PgSpace $sql.Substring($lockMatch.Index)
        $sql = $sql.Substring(0, $lockMatch.Index).TrimEnd()
    }

    $offsetMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bOFFSET\b'
    $offsetText = ''
    if ($null -ne $offsetMatch) {
        $offsetText = Normalize-PgSpace $sql.Substring($offsetMatch.Index + $offsetMatch.Length))
        $sql = $sql.Substring(0, $offsetMatch.Index).TrimEnd()
    }

    $formatted = Remove-PgTrailingSemicolon (Invoke-PgCoreFormatter -Sql $sql)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($formatted -split "`r?`n")) { $out.Add($line) }
    if ($offsetText) { $out.Add(' OFFSET ' + $offsetText) }
    if ($lockText) { $out.Add(' ' + $lockText) }
    $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';'
    return ($out -join [Environment]::NewLine)
}

function Format-PgInsert {
    param([string]$Sql)
    $sql = Remove-PgTrailingSemicolon (Normalize-PgSpace $Sql)

    $returningMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bRETURNING\b'
    $returning = ''
    if ($null -ne $returningMatch) {
        $returning = $sql.Substring($returningMatch.Index + $returningMatch.Length).Trim()
        $sql = $sql.Substring(0, $returningMatch.Index).TrimEnd()
    }

    $conflictMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bON\s+CONFLICT\b'
    $conflict = ''
    if ($null -ne $conflictMatch) {
        $conflict = $sql.Substring($conflictMatch.Index).Trim()
        $sql = $sql.Substring(0, $conflictMatch.Index).TrimEnd()
    }

    $base = Remove-PgTrailingSemicolon (Invoke-PgCoreFormatter -Sql $sql)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($base -split "`r?`n")) { $out.Add($line) }

    if ($conflict) {
        $doMatch = Get-PgTopLevelMatch -Text $conflict -Pattern '\bDO\b'
        if ($null -eq $doMatch) {
            $out.Add($conflict)
        }
        else {
            $head = Normalize-PgSpace $conflict.Substring(0, $doMatch.Index)
            $action = Normalize-PgSpace $conflict.Substring($doMatch.Index))
            $out.Add($head)
            if ($action -match '^(?i)DO\s+NOTHING\b') {
                $out.Add('DO NOTHING')
            }
            else {
                $setMatch = Get-PgTopLevelMatch -Text $action -Pattern '\bSET\b'
                if ($null -eq $setMatch) {
                    $out.Add($action)
                }
                else {
                    $out.Add((Normalize-PgSpace $action.Substring(0, $setMatch.Index)))
                    $whereMatch = Get-PgTopLevelMatch -Text $action -Pattern '\bWHERE\b'
                    $setEnd = if ($null -ne $whereMatch) { $whereMatch.Index } else { $action.Length }
                    $setText = $action.Substring($setMatch.Index + $setMatch.Length, $setEnd - ($setMatch.Index + $setMatch.Length))
                    foreach ($line in @(Format-PgSetItems -Text $setText)) { $out.Add($line) }
                    if ($null -ne $whereMatch) {
                        foreach ($line in @(Format-PgWhere -Text $action.Substring($whereMatch.Index + $whereMatch.Length))) { $out.Add($line) }
                    }
                }
            }
        }
    }

    if ($returning) {
        foreach ($line in @(Format-PgReturning -Text $returning)) { $out.Add($line) }
    }
    $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';'
    return ($out -join [Environment]::NewLine)
}

function Format-PgUpdate {
    param([string]$Sql)
    $sql = Remove-PgTrailingSemicolon (Normalize-PgSpace $Sql)

    $returningMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bRETURNING\b'
    $returning = ''
    if ($null -ne $returningMatch) {
        $returning = $sql.Substring($returningMatch.Index + $returningMatch.Length).Trim()
        $sql = $sql.Substring(0, $returningMatch.Index).TrimEnd()
    }

    $setMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bSET\b'
    if ($null -eq $setMatch) { return Invoke-PgCoreFormatter -Sql ($sql + ';') }
    $fromMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bFROM\b'
    $whereMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bWHERE\b'

    $setEnd = $sql.Length
    if ($null -ne $fromMatch -and $fromMatch.Index -lt $setEnd) { $setEnd = $fromMatch.Index }
    if ($null -ne $whereMatch -and $whereMatch.Index -lt $setEnd) { $setEnd = $whereMatch.Index }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add((Normalize-PgSpace $sql.Substring(0, $setMatch.Index)))
    $setText = $sql.Substring($setMatch.Index + $setMatch.Length, $setEnd - ($setMatch.Index + $setMatch.Length))
    foreach ($line in @(Format-PgSetItems -Text $setText)) { $out.Add($line) }

    if ($null -ne $fromMatch) {
        $fromEnd = if ($null -ne $whereMatch -and $whereMatch.Index -gt $fromMatch.Index) { $whereMatch.Index } else { $sql.Length }
        $fromText = $sql.Substring($fromMatch.Index + $fromMatch.Length, $fromEnd - ($fromMatch.Index + $fromMatch.Length))
        foreach ($line in @(Format-PgFromLike -Keyword 'FROM' -Text $fromText)) { $out.Add($line) }
    }
    if ($null -ne $whereMatch) {
        foreach ($line in @(Format-PgWhere -Text $sql.Substring($whereMatch.Index + $whereMatch.Length))) { $out.Add($line) }
    }
    if ($returning) {
        foreach ($line in @(Format-PgReturning -Text $returning)) { $out.Add($line) }
    }
    $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';'
    return ($out -join [Environment]::NewLine)
}

function Format-PgDelete {
    param([string]$Sql)
    $sql = Remove-PgTrailingSemicolon (Normalize-PgSpace $Sql)

    $returningMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bRETURNING\b'
    $returning = ''
    if ($null -ne $returningMatch) {
        $returning = $sql.Substring($returningMatch.Index + $returningMatch.Length).Trim()
        $sql = $sql.Substring(0, $returningMatch.Index).TrimEnd()
    }

    $usingMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bUSING\b'
    $whereMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bWHERE\b'
    $headEnd = $sql.Length
    if ($null -ne $usingMatch -and $usingMatch.Index -lt $headEnd) { $headEnd = $usingMatch.Index }
    if ($null -ne $whereMatch -and $whereMatch.Index -lt $headEnd) { $headEnd = $whereMatch.Index }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add((Normalize-PgSpace $sql.Substring(0, $headEnd)))
    if ($null -ne $usingMatch) {
        $usingEnd = if ($null -ne $whereMatch -and $whereMatch.Index -gt $usingMatch.Index) { $whereMatch.Index } else { $sql.Length }
        $usingText = $sql.Substring($usingMatch.Index + $usingMatch.Length, $usingEnd - ($usingMatch.Index + $usingMatch.Length))
        foreach ($line in @(Format-PgFromLike -Keyword 'USING' -Text $usingText)) { $out.Add($line) }
    }
    if ($null -ne $whereMatch) {
        foreach ($line in @(Format-PgWhere -Text $sql.Substring($whereMatch.Index + $whereMatch.Length))) { $out.Add($line) }
    }
    if ($returning) {
        foreach ($line in @(Format-PgReturning -Text $returning)) { $out.Add($line) }
    }
    $out[$out.Count - 1] = $out[$out.Count - 1].TrimEnd() + ';'
    return ($out -join [Environment]::NewLine)
}

function Format-PgCreateTableAs {
    param([string]$Sql)
    $sql = Remove-PgTrailingSemicolon (Normalize-PgSpace $Sql)
    $asMatch = Get-PgTopLevelMatch -Text $sql -Pattern '\bAS\s+(?=SELECT\b|WITH\b)'
    if ($null -eq $asMatch) { return Invoke-PgCoreFormatter -Sql ($sql + ';') }

    $head = Normalize-PgSpace $sql.Substring(0, $asMatch.Index + 2)
    $query = $sql.Substring($asMatch.Index + $asMatch.Length).Trim()
    $queryFormatted = Remove-PgTrailingSemicolon (Invoke-PgCoreFormatter -Sql $query)
    return $head + [Environment]::NewLine + $queryFormatted + ';'
}

function Format-PgStatement {
    param([string]$Sql)
    $normalized = Normalize-PgSpace $Sql

    if ($normalized -match '^(?i)SELECT\b') { return Format-PgSelect -Sql $normalized }
    if ($normalized -match '^(?i)INSERT\b') { return Format-PgInsert -Sql $normalized }
    if ($normalized -match '^(?i)UPDATE\b') { return Format-PgUpdate -Sql $normalized }
    if ($normalized -match '^(?i)DELETE\b') { return Format-PgDelete -Sql $normalized }
    if ($normalized -match '^(?i)CREATE\s+(?:(?:GLOBAL|LOCAL)\s+)?(?:TEMP|TEMPORARY)\s+TABLE\b' -or
        $normalized -match '^(?i)CREATE\s+TABLE\b.*\bAS\s+(SELECT|WITH)\b') {
        return Format-PgCreateTableAs -Sql $normalized
    }
    return Invoke-PgCoreFormatter -Sql $normalized
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$protected = Protect-PgText $inputSql
$protected = Convert-PgKeywords $protected
$normalizedProtected = Normalize-PgSpace $protected

# PL/pgSQL bodies are intentionally protected and preserved in this first
# PostgreSQL pass. We format ordinary SQL aggressively; routine bodies are kept
# byte-for-byte safe until a dedicated PL/pgSQL formatter is added.
if ($normalizedProtected -match '^(?i)CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE)\b' -and
    $protected -match '__SQLFMT_PG_DOLLAR_\d+__') {
    $formatted = $protected.Trim()
}
else {
    $formatted = Format-PgStatement -Sql $protected
}

$formatted = Restore-PgText $formatted
[Console]::Out.Write($formatted.TrimEnd())
