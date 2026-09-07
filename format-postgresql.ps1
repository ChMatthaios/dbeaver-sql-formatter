<#
    PostgreSQL support for the DBeaver SQL formatter.
    Shared SQL is delegated to format-sql-core.ps1. PostgreSQL-specific clauses
    are handled here, while dollar-quoted bodies are protected from rewriting.
#>

$ErrorActionPreference = 'Stop'
$script:MaxLineLength = 120
$script:PgMap = @{}
$script:PgIndex = 0
$CoreFormatter = Join-Path $PSScriptRoot 'format-sql-core.ps1'

$settingsPath = Join-Path $PSScriptRoot 'settings\settings.json'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties.Name -contains 'maxLineLength') {
            $n = 0
            if ([int]::TryParse([string]$settings.maxLineLength, [ref]$n) -and $n -ge 60 -and $n -le 400) {
                $script:MaxLineLength = $n
            }
        }
    }
    catch { }
}

function New-PgToken {
    param([string]$Kind, [string]$Value)
    $script:PgIndex++
    $token = "__SQLFMT_PG_${Kind}_$script:PgIndex`__"
    $script:PgMap[$token] = $Value
    return $token
}

function Protect-PgSql {
    param([string]$Sql)
    $script:PgMap = @{}
    $script:PgIndex = 0

    # Dollar quotes first: their contents may contain strings, comments and ;.
    $Sql = [regex]::Replace($Sql, '(?s)(\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$).*?\1', {
        param($m) New-PgToken -Kind 'DOLLAR' -Value $m.Value
    })
    $Sql = [regex]::Replace($Sql, '/\*[\s\S]*?\*/', { param($m) New-PgToken -Kind 'BCOM' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, "'(?:''|[^'])*'", { param($m) New-PgToken -Kind 'STR' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '"(?:""|[^"])*"', { param($m) New-PgToken -Kind 'DQS' -Value $m.Value })
    $Sql = [regex]::Replace($Sql, '--[^\r\n]*', { param($m) New-PgToken -Kind 'LCOM' -Value $m.Value })
    return $Sql
}

function Restore-PgSql {
    param([string]$Sql)
    foreach ($key in ($script:PgMap.Keys | Sort-Object Length -Descending)) {
        $Sql = $Sql.Replace($key, $script:PgMap[$key])
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
        'create','replace','procedure','function','returns','language','begin','table','view','index','schema','alter',
        'with','recursive','materialized','lateral','returning','conflict','do','nothing','excluded','true','false',
        'temp','temporary','array','generated','identity','serial','bigserial','json','jsonb','variadic','overriding',
        'system','value','concurrently','deferrable','initially','for','share','key','no','nowait','skip','locked'
    )
    foreach ($kw in $keywords) {
        $e = [regex]::Escape($kw)
        $Sql = [regex]::Replace($Sql, "(?i)(?<![A-Z0-9_])$e(?![A-Z0-9_])", { param($m) $m.Value.ToUpperInvariant() })
    }
    return $Sql
}

function Normalize-Pg {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text = $Text -replace '[\r\n\t]+', ' '
    $Text = $Text -replace '\s+', ' '
    $Text = $Text -replace '\s+,', ','
    $Text = $Text -replace ',\s*', ', '
    $Text = $Text -replace '\s+;', ';'
    return $Text.Trim()
}

function Remove-Semicolon {
    param([string]$Text)
    return ($Text.TrimEnd() -replace ';\s*$', '')
}

function Get-Depth {
    param([string]$Text, [int]$Index)
    $d = 0
    for ($i = 0; $i -lt $Index; $i++) {
        if ($Text[$i] -eq '(') { $d++ }
        elseif ($Text[$i] -eq ')' -and $d -gt 0) { $d-- }
    }
    return $d
}

function Find-Top {
    param([string]$Text, [string]$Pattern)
    $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $rx.Matches($Text)) {
        if ((Get-Depth -Text $Text -Index $m.Index) -eq 0) { return $m }
    }
    return $null
}

function Split-Comma {
    param([string]$Text)
    $out = New-Object System.Collections.Generic.List[string]
    $d = 0
    $start = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '(') { $d++ }
        elseif ($Text[$i] -eq ')' -and $d -gt 0) { $d-- }
        elseif ($Text[$i] -eq ',' -and $d -eq 0) {
            $p = Normalize-Pg $Text.Substring($start, $i - $start)
            if ($p) { $out.Add($p) }
            $start = $i + 1
        }
    }
    $tail = Normalize-Pg $Text.Substring($start)
    if ($tail) { $out.Add($tail) }
    return $out
}

function Core {
    param([string]$Sql)
    $x = $Sql | powershell -NoProfile -ExecutionPolicy Bypass -File $CoreFormatter | Out-String
    return $x.TrimEnd("`r", "`n")
}

function Add-Returning {
    param([System.Collections.Generic.List[string]]$Out, [string]$Text)
    if (-not $Text) { return }
    $items = @(Split-Comma $Text)
    $prefix = 'RETURNING '
    $compact = $prefix + ($items -join ', ')
    if ($compact.Length -le $script:MaxLineLength) {
        $Out.Add($compact)
        return
    }
    $next = ' ' * $prefix.Length
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $Out.Add($(if ($i -eq 0) { $prefix } else { $next }) + $items[$i] + $suffix)
    }
}

function Add-Set {
    param([System.Collections.Generic.List[string]]$Out, [string]$Text)
    $items = @(Split-Comma $Text)
    for ($i = 0; $i -lt $items.Count; $i++) {
        $suffix = if ($i -lt $items.Count - 1) { ',' } else { '' }
        $Out.Add($(if ($i -eq 0) { '   SET ' } else { '       ' }) + $items[$i] + $suffix)
    }
}

function Add-Where {
    param([System.Collections.Generic.List[string]]$Out, [string]$Text)
    $fake = Core ('SELECT 1 WHERE ' + (Normalize-Pg $Text))
    $lines = @($fake -split "`r?`n")
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $Out.Add((Remove-Semicolon $lines[$i]))
    }
}

function Format-PgSelect {
    param([string]$Sql)
    $sql = Remove-Semicolon (Normalize-Pg $Sql)

    $lock = ''
    $m = Find-Top -Text $sql -Pattern '\bFOR\s+(?:NO\s+KEY\s+UPDATE|KEY\s+SHARE|UPDATE|SHARE)\b'
    if ($null -ne $m) {
        $lock = Normalize-Pg $sql.Substring($m.Index)
        $sql = $sql.Substring(0, $m.Index).TrimEnd()
    }

    $offset = ''
    $m = Find-Top -Text $sql -Pattern '\bOFFSET\b'
    if ($null -ne $m) {
        $offset = Normalize-Pg $sql.Substring($m.Index + $m.Length)
        $sql = $sql.Substring(0, $m.Index).TrimEnd()
    }

    $base = Remove-Semicolon (Core $sql)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($base -split "`r?`n")) { $out.Add($line) }
    if ($offset) { $out.Add(' OFFSET ' + $offset) }
    if ($lock) { $out.Add(' ' + $lock) }
    $out[$out.Count - 1] += ';'
    return ($out -join [Environment]::NewLine)
}

function Format-PgInsert {
    param([string]$Sql)
    $sql = Remove-Semicolon (Normalize-Pg $Sql)

    $returning = ''
    $m = Find-Top -Text $sql -Pattern '\bRETURNING\b'
    if ($null -ne $m) {
        $returning = $sql.Substring($m.Index + $m.Length).Trim()
        $sql = $sql.Substring(0, $m.Index).TrimEnd()
    }

    $conflict = ''
    $m = Find-Top -Text $sql -Pattern '\bON\s+CONFLICT\b'
    if ($null -ne $m) {
        $conflict = $sql.Substring($m.Index).Trim()
        $sql = $sql.Substring(0, $m.Index).TrimEnd()
    }

    $base = Remove-Semicolon (Core $sql)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($base -split "`r?`n")) { $out.Add($line) }

    if ($conflict) {
        $do = Find-Top -Text $conflict -Pattern '\bDO\b'
        if ($null -eq $do) {
            $out.Add($conflict)
        }
        else {
            $out.Add((Normalize-Pg $conflict.Substring(0, $do.Index)))
            $action = Normalize-Pg $conflict.Substring($do.Index)
            if ($action -match '^(?i)DO\s+NOTHING\b') {
                $out.Add('DO NOTHING')
            }
            else {
                $set = Find-Top -Text $action -Pattern '\bSET\b'
                if ($null -eq $set) {
                    $out.Add($action)
                }
                else {
                    $out.Add((Normalize-Pg $action.Substring(0, $set.Index)))
                    $w = Find-Top -Text $action -Pattern '\bWHERE\b'
                    $setEnd = if ($null -ne $w) { $w.Index } else { $action.Length }
                    Add-Set -Out $out -Text $action.Substring($set.Index + $set.Length, $setEnd - ($set.Index + $set.Length))
                    if ($null -ne $w) { Add-Where -Out $out -Text $action.Substring($w.Index + $w.Length) }
                }
            }
        }
    }

    Add-Returning -Out $out -Text $returning
    $out[$out.Count - 1] += ';'
    return ($out -join [Environment]::NewLine)
}

function Format-PgUpdate {
    param([string]$Sql)
    $sql = Remove-Semicolon (Normalize-Pg $Sql)

    $returning = ''
    $r = Find-Top -Text $sql -Pattern '\bRETURNING\b'
    if ($null -ne $r) {
        $returning = $sql.Substring($r.Index + $r.Length).Trim()
        $sql = $sql.Substring(0, $r.Index).TrimEnd()
    }

    $set = Find-Top -Text $sql -Pattern '\bSET\b'
    if ($null -eq $set) { return Core ($sql + ';') }
    $from = Find-Top -Text $sql -Pattern '\bFROM\b'
    $where = Find-Top -Text $sql -Pattern '\bWHERE\b'

    $endSet = $sql.Length
    if ($null -ne $from -and $from.Index -lt $endSet) { $endSet = $from.Index }
    if ($null -ne $where -and $where.Index -lt $endSet) { $endSet = $where.Index }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add((Normalize-Pg $sql.Substring(0, $set.Index)))
    Add-Set -Out $out -Text $sql.Substring($set.Index + $set.Length, $endSet - ($set.Index + $set.Length))

    if ($null -ne $from) {
        $endFrom = if ($null -ne $where -and $where.Index -gt $from.Index) { $where.Index } else { $sql.Length }
        $out.Add('  FROM ' + (Normalize-Pg $sql.Substring($from.Index + $from.Length, $endFrom - ($from.Index + $from.Length))))
    }
    if ($null -ne $where) { Add-Where -Out $out -Text $sql.Substring($where.Index + $where.Length) }
    Add-Returning -Out $out -Text $returning
    $out[$out.Count - 1] += ';'
    return ($out -join [Environment]::NewLine)
}

function Format-PgDelete {
    param([string]$Sql)
    $sql = Remove-Semicolon (Normalize-Pg $Sql)

    $returning = ''
    $r = Find-Top -Text $sql -Pattern '\bRETURNING\b'
    if ($null -ne $r) {
        $returning = $sql.Substring($r.Index + $r.Length).Trim()
        $sql = $sql.Substring(0, $r.Index).TrimEnd()
    }

    $using = Find-Top -Text $sql -Pattern '\bUSING\b'
    $where = Find-Top -Text $sql -Pattern '\bWHERE\b'
    $headEnd = $sql.Length
    if ($null -ne $using -and $using.Index -lt $headEnd) { $headEnd = $using.Index }
    if ($null -ne $where -and $where.Index -lt $headEnd) { $headEnd = $where.Index }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add((Normalize-Pg $sql.Substring(0, $headEnd)))
    if ($null -ne $using) {
        $endUsing = if ($null -ne $where -and $where.Index -gt $using.Index) { $where.Index } else { $sql.Length }
        $out.Add(' USING ' + (Normalize-Pg $sql.Substring($using.Index + $using.Length, $endUsing - ($using.Index + $using.Length))))
    }
    if ($null -ne $where) { Add-Where -Out $out -Text $sql.Substring($where.Index + $where.Length) }
    Add-Returning -Out $out -Text $returning
    $out[$out.Count - 1] += ';'
    return ($out -join [Environment]::NewLine)
}

function Format-PgCreateTableAs {
    param([string]$Sql)
    $sql = Remove-Semicolon (Normalize-Pg $Sql)
    $as = Find-Top -Text $sql -Pattern '\bAS\s+(?=SELECT\b|WITH\b)'
    if ($null -eq $as) { return Core ($sql + ';') }
    $head = Normalize-Pg $sql.Substring(0, $as.Index + 2)
    $query = $sql.Substring($as.Index + $as.Length).Trim()
    return $head + [Environment]::NewLine + (Remove-Semicolon (Core $query)) + ';'
}

function Format-Pg {
    param([string]$Sql)
    $n = Normalize-Pg $Sql
    if ($n -match '^(?i)SELECT\b') { return Format-PgSelect $n }
    if ($n -match '^(?i)INSERT\b') { return Format-PgInsert $n }
    if ($n -match '^(?i)UPDATE\b') { return Format-PgUpdate $n }
    if ($n -match '^(?i)DELETE\b') { return Format-PgDelete $n }
    if ($n -match '^(?i)CREATE\s+(?:(?:GLOBAL|LOCAL)\s+)?(?:TEMP|TEMPORARY)\s+TABLE\b' -or
        $n -match '^(?i)CREATE\s+TABLE\b.*\bAS\s+(SELECT|WITH)\b') {
        return Format-PgCreateTableAs $n
    }
    return Core $n
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$protected = Protect-PgSql $inputSql
$protected = Convert-PgKeywords $protected
$normalized = Normalize-Pg $protected

# First PostgreSQL release: protect PL/pgSQL bodies completely. The surrounding
# SQL keywords may be cased, but the dollar-quoted body is restored unchanged.
if ($normalized -match '^(?i)CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE)\b' -and
    $protected -match '__SQLFMT_PG_DOLLAR_\d+__') {
    $formatted = $protected.Trim()
}
else {
    $formatted = Format-Pg $protected
}

$formatted = Restore-PgSql $formatted
[Console]::Out.Write($formatted.TrimEnd())