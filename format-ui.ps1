<#
    Windows UI formatter entry point.

    The desktop app first runs the same format-sql.ps1 engine used by DBeaver,
    then applies UI-only semantic presentation passes for complex expressions,
    and finally applies the user's advanced beautifier preferences.

    MERGE statements are containers: their USING query is refined independently,
    then the completed MERGE is protected from a second generic presentation pass.
#>

$ErrorActionPreference = 'Stop'
$Formatter = Join-Path $PSScriptRoot 'format-sql.ps1'
$SemanticPolish = Join-Path $PSScriptRoot 'format-semantic-polish.ps1'
$UiFinalize = Join-Path $PSScriptRoot 'format-ui-finalize.ps1'
$Beautifier = Join-Path $PSScriptRoot 'format-beautifier.ps1'

$script:UiMergeMap = @{}
$script:UiMergeIndex = 0

function Find-UiStatementEnd {
    param([string]$Text, [int]$StartIndex)

    $single = $false
    $double = $false
    $lineComment = $false
    $blockComment = $false
    $depth = 0

    for ($i = $StartIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($lineComment) {
            if ($ch -eq "`n") { $lineComment = $false }
            continue
        }
        if ($blockComment) {
            if ($ch -eq '*' -and $next -eq '/') { $blockComment = $false; $i++ }
            continue
        }
        if ($single) {
            if ($ch -eq "'") {
                if ($next -eq "'") { $i++ } else { $single = $false }
            }
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($next -eq '"') { $i++ } else { $double = $false }
            }
            continue
        }

        if ($ch -eq '-' -and $next -eq '-') { $lineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $blockComment = $true; $i++; continue }
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') { if ($depth -gt 0) { $depth-- }; continue }

        if ($ch -eq ';' -and $depth -eq 0) { return $i + 1 }
    }

    return -1
}

function Find-UiMatchingParen {
    param([string]$Text, [int]$OpenIndex)

    $single = $false
    $double = $false
    $lineComment = $false
    $blockComment = $false
    $depth = 0

    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($lineComment) {
            if ($ch -eq "`n") { $lineComment = $false }
            continue
        }
        if ($blockComment) {
            if ($ch -eq '*' -and $next -eq '/') { $blockComment = $false; $i++ }
            continue
        }
        if ($single) {
            if ($ch -eq "'") {
                if ($next -eq "'") { $i++ } else { $single = $false }
            }
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($next -eq '"') { $i++ } else { $double = $false }
            }
            continue
        }

        if ($ch -eq '-' -and $next -eq '-') { $lineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $blockComment = $true; $i++; continue }
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }

    return -1
}

function Remove-UiCommonIndent {
    param([string]$Text)

    $lines = @($Text -split "`r?`n")
    $indents = @(
        $lines |
            Where-Object { $_.Trim().Length -gt 0 } |
            ForEach-Object { $_.Length - $_.TrimStart().Length }
    )

    if ($indents.Count -eq 0) { return $Text.Trim() }
    $minimum = ($indents | Measure-Object -Minimum).Minimum
    if ($minimum -le 0) { return $Text.Trim() }

    return (($lines | ForEach-Object {
        if ($_.Length -ge $minimum) { $_.Substring($minimum) } else { $_ }
    }) -join [Environment]::NewLine).Trim()
}

function Get-UiCteLayoutMode {
    $settingsPath = Join-Path $PSScriptRoot 'settings\settings.json'
    if (-not (Test-Path $settingsPath)) { return 'Preserve' }

    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        if ($null -eq $settings.advanced -or -not [bool]$settings.advanced.enabled) { return 'Preserve' }
        $mode = [string]$settings.advanced.clauses.cteLayout
        if ($mode -in @('CompactHeader', 'ExpandedHeader')) { return $mode }
    }
    catch {
        # Formatting still works with the normal formatter when settings are invalid.
    }

    return 'Preserve'
}

function Normalize-UiCteHeaders {
    param([string]$Sql, [string]$Mode)

    if ($Mode -ne 'CompactHeader') { return $Sql }

    $lines = @($Sql -split "`r?`n")
    $combined = New-Object System.Collections.Generic.List[string]
    $i = 0

    # First combine any two-line "CTE_NAME" / "AS (" headers.
    while ($i -lt $lines.Count) {
        if ($i + 1 -lt $lines.Count) {
            $first = [regex]::Match(
                $lines[$i],
                '^(?<indent>\s*)(?<with>WITH\s+)?(?<name>[A-Za-z_][A-Za-z0-9_$#]*)\s*$',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            $second = [regex]::Match(
                $lines[$i + 1],
                '^\s*AS\s*\(',
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($first.Success -and $second.Success) {
                $prefix = $first.Groups['indent'].Value
                if ($first.Groups['with'].Success) { $prefix += 'WITH ' }
                $tail = $lines[$i + 1].TrimStart() -replace '^(?i)AS\s*\(', 'AS ('
                $combined.Add($prefix + $first.Groups['name'].Value + ' ' + $tail)
                $i += 2
                continue
            }
        }

        $combined.Add($lines[$i])
        $i++
    }

    # Then align all CTE headers to the indentation of the initial WITH CTE.
    # This prevents later CTEs such as CUSTOMER_AGG from drifting right even
    # when the core formatter had to wrap an earlier nested expression.
    $out = New-Object System.Collections.Generic.List[string]
    $cteIndent = $null

    foreach ($line in $combined) {
        $header = [regex]::Match(
            $line,
            '^(?<indent>\s*)(?<with>WITH\s+)?(?<name>[A-Za-z_][A-Za-z0-9_$#]*)\s+AS\s*\((?<tail>.*)$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($header.Success) {
            if ($header.Groups['with'].Success) {
                $cteIndent = $header.Groups['indent'].Value
                $prefix = $cteIndent + 'WITH '
            }
            elseif ($null -ne $cteIndent) {
                $prefix = $cteIndent
            }
            else {
                $prefix = $header.Groups['indent'].Value
            }

            $normalized = $prefix + $header.Groups['name'].Value + ' AS ('
            if ($header.Groups['tail'].Value) { $normalized += $header.Groups['tail'].Value }
            $out.Add($normalized)
            continue
        }

        $out.Add($line)
    }

    return ($out -join [Environment]::NewLine)
}

function Invoke-UiPresentationPasses {
    param([string]$Sql)

    $formatted = $Sql.Trim()
    if ([string]::IsNullOrWhiteSpace($formatted)) { return $formatted }

    # Semantic polish can mistake a CTE's AS ( for a function-shaped expression.
    $cteAsToken = '__SQLFMT_CTE_AS_OPEN__'
    $polishInput = [regex]::Replace(
        $formatted,
        '(?im)^(\s*)AS\s+\(',
        ('$1' + $cteAsToken)
    )

    $formatted = $polishInput |
        powershell -NoProfile -ExecutionPolicy Bypass -File $SemanticPolish |
        Out-String
    $formatted = $formatted.TrimEnd("`r", "`n")
    $formatted = $formatted.Replace($cteAsToken, 'AS (')

    $formatted = $formatted |
        powershell -NoProfile -ExecutionPolicy Bypass -File $UiFinalize |
        Out-String
    $formatted = $formatted.TrimEnd("`r", "`n")

    if (Test-Path $Beautifier) {
        $formatted = $formatted |
            powershell -NoProfile -ExecutionPolicy Bypass -File $Beautifier |
            Out-String
        $formatted = $formatted.TrimEnd("`r", "`n")
    }

    return $formatted
}

function Refine-UiMergeUsingQueries {
    param([string]$Text)

    $cteLayout = Get-UiCteLayoutMode
    $matches = @([regex]::Matches($Text, '(?im)^[ \t]*MERGE\b'))
    for ($m = $matches.Count - 1; $m -ge 0; $m--) {
        $statementStart = $matches[$m].Index
        $statementEnd = Find-UiStatementEnd -Text $Text -StartIndex $statementStart
        if ($statementEnd -le $statementStart) { continue }

        $statement = $Text.Substring($statementStart, $statementEnd - $statementStart)
        $using = [regex]::Match($statement, '(?im)^[ \t]*USING\s*\(')
        if (-not $using.Success) { continue }

        $open = $statement.IndexOf('(', $using.Index)
        if ($open -lt 0) { continue }
        $close = Find-UiMatchingParen -Text $statement -OpenIndex $open
        if ($close -le $open) { continue }

        $inner = $statement.Substring($open + 1, $close - $open - 1)
        $inner = Remove-UiCommonIndent $inner
        if ($inner -notmatch '^(?is)(WITH|SELECT)\b') { continue }

        $refined = Invoke-UiPresentationPasses $inner
        $refined = Normalize-UiCteHeaders -Sql $refined -Mode $cteLayout
        $refinedLines = @($refined -split "`r?`n")
        $placed = [Environment]::NewLine + (($refinedLines | ForEach-Object { '  ' + $_ }) -join [Environment]::NewLine) + [Environment]::NewLine + ' '

        $statement = $statement.Substring(0, $open + 1) + $placed + $statement.Substring($close)
        $Text = $Text.Substring(0, $statementStart) + $statement + $Text.Substring($statementEnd)
    }

    return $Text
}

function Protect-UiMergeStatements {
    param([string]$Text)

    $script:UiMergeMap = @{}
    $script:UiMergeIndex = 0

    $matches = @([regex]::Matches($Text, '(?im)^[ \t]*MERGE\b'))
    for ($m = $matches.Count - 1; $m -ge 0; $m--) {
        $start = $matches[$m].Index
        $end = Find-UiStatementEnd -Text $Text -StartIndex $start
        if ($end -le $start) { continue }

        $script:UiMergeIndex++
        $token = "__SQLFMT_UI_MERGE_$script:UiMergeIndex`__"
        $value = $Text.Substring($start, $end - $start)
        $script:UiMergeMap[$token] = $value
        $Text = $Text.Substring(0, $start) + $token + $Text.Substring($end)
    }

    return $Text
}

function Restore-UiMergeStatements {
    param([string]$Text)

    foreach ($token in ($script:UiMergeMap.Keys | Sort-Object Length -Descending)) {
        $Text = $Text.Replace($token, $script:UiMergeMap[$token])
    }
    return $Text
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$trailingIsolation = [regex]::Match(
    $inputSql,
    '(?is)\bWITH\s+(UR|RS|CS|RR|NC)\s*;\s*$'
)

$formatted = $inputSql |
    powershell -NoProfile -ExecutionPolicy Bypass -File $Formatter |
    Out-String
$formatted = $formatted.TrimEnd("`r", "`n")

if (-not [string]::IsNullOrWhiteSpace($formatted)) {
    # A MERGE owns its outer layout, but its USING query is still an independent
    # query unit and therefore receives the same presentation settings as any
    # other SELECT/WITH query before the completed MERGE is protected.
    $formatted = Refine-UiMergeUsingQueries $formatted
    $formatted = Protect-UiMergeStatements $formatted

    $formatted = Invoke-UiPresentationPasses $formatted
    $formatted = Restore-UiMergeStatements $formatted
}

# Formatting must never silently change DB2 isolation semantics.
if ($trailingIsolation.Success) {
    $isolation = 'WITH ' + $trailingIsolation.Groups[1].Value.ToUpperInvariant()
    if ($formatted -notmatch ('(?is)\b' + [regex]::Escape($isolation) + '\s*;\s*$')) {
        $formatted = $formatted.TrimEnd()
        if ($formatted.EndsWith(';')) {
            $formatted = $formatted.Substring(0, $formatted.Length - 1).TrimEnd()
        }
        $formatted += [Environment]::NewLine + '  ' + $isolation + ';'
    }
}

[Console]::Out.Write($formatted)