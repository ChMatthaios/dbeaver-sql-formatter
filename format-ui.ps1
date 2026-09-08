<#
    Windows UI formatter entry point.

    The desktop app first runs the same format-sql.ps1 engine used by DBeaver,
    then applies UI-only semantic presentation passes for complex expressions,
    and finally applies the user's advanced beautifier preferences.

    MERGE statements are already formatted by the dedicated MERGE container
    formatter. They are protected while the generic UI presentation passes run,
    so nested CTEs/SELECTs inside USING are not re-indented a second time.
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
            if ($ch -eq '*' -and $next -eq '/') {
                $blockComment = $false
                $i++
            }
            continue
        }

        if ($single) {
            if ($ch -eq "'") {
                if ($next -eq "'") { $i++ }
                else { $single = $false }
            }
            continue
        }

        if ($double) {
            if ($ch -eq '"') {
                if ($next -eq '"') { $i++ }
                else { $double = $false }
            }
            continue
        }

        if ($ch -eq '-' -and $next -eq '-') {
            $lineComment = $true
            $i++
            continue
        }
        if ($ch -eq '/' -and $next -eq '*') {
            $blockComment = $true
            $i++
            continue
        }
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') { if ($depth -gt 0) { $depth-- }; continue }

        if ($ch -eq ';' -and $depth -eq 0) {
            return $i + 1
        }
    }

    return -1
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
    # MERGE has its own recursive formatter. Protect complete MERGE statements
    # from the generic semantic/beautifier passes to prevent runaway indentation
    # in USING (WITH ... SELECT ...) containers.
    $formatted = Protect-UiMergeStatements $formatted

    # The semantic pass recognizes function-call shaped lines. A CTE's `AS (`
    # has the same superficial shape, so protect that structural token while the
    # pass works on expressions inside ordinary queries and restore it afterwards.
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