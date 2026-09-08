<#
    Windows application script-level formatter.

    The desktop editor can contain several independent SQL statements at once.
    Each top-level statement is formatted independently with format-ui.ps1 so
    UPDATE/DELETE/MERGE/SELECT all reach their dedicated formatter as the root
    statement instead of later statements being treated as trailing text.

    Stored-program and dollar-quoted scripts are deliberately kept as one unit,
    because semicolons inside those bodies are not top-level statement endings.
#>

$ErrorActionPreference = 'Stop'
$UnitFormatter = Join-Path $PSScriptRoot 'format-ui.ps1'
$DgttFormatter = Join-Path $PSScriptRoot 'format-dgtt-ui.ps1'
$CaseArithmetic = Join-Path $PSScriptRoot 'format-case-arithmetic.ps1'
$CaseBranchRepair = Join-Path $PSScriptRoot 'format-case-branches.ps1'
$CaseConditionDetail = Join-Path $PSScriptRoot 'format-case-condition-detail.ps1'

function Test-UnsafeToSplit {
    param([string]$Text)

    if ($Text -match '(?im)^\s*(CREATE|ALTER)\s+(?:(?:OR\s+(?:REPLACE|ALTER))\s+)?(?:EDITIONABLE\s+|NONEDITIONABLE\s+)?(PROCEDURE|PROC|FUNCTION|TRIGGER|PACKAGE(?:\s+BODY)?|TYPE\s+BODY)\b') {
        return $true
    }
    if ($Text -match '(?im)^\s*BEGIN\s+ATOMIC\b') { return $true }
    if ($Text -match '(?s)\$\$|\$[A-Za-z_][A-Za-z0-9_]*\$') { return $true }

    return $false
}

function Find-TopLevelStatementEnd {
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

function Split-TopLevelStatements {
    param([string]$Text)

    if (Test-UnsafeToSplit $Text) { return @($Text.Trim()) }

    $segments = New-Object System.Collections.Generic.List[string]
    $start = 0

    while ($start -lt $Text.Length) {
        $end = Find-TopLevelStatementEnd -Text $Text -StartIndex $start
        if ($end -le $start) {
            $tail = $Text.Substring($start).Trim()
            if (-not [string]::IsNullOrWhiteSpace($tail)) { $segments.Add($tail) }
            break
        }

        $segment = $Text.Substring($start, $end - $start).Trim()
        if (-not [string]::IsNullOrWhiteSpace($segment)) { $segments.Add($segment) }
        $start = $end
    }

    if ($segments.Count -eq 0) { $segments.Add($Text.Trim()) }
    return $segments.ToArray()
}

function Repair-DetachedJoinModifiers {
    param([string]$Text)

    # The advanced EachNewLine JOIN presentation can see `INNER JOIN ...` as two
    # candidate boundaries and leave `INNER` / `JOIN ...` on separate lines.
    # Rejoin only an isolated SQL join modifier immediately followed by JOIN.
    return [regex]::Replace(
        $Text,
        '(?im)^(?<indent>[ \t]*)(?<kind>INNER|LEFT|RIGHT|FULL|CROSS)(?<outer>[ \t]+OUTER)?[ \t]*\r?\n[ \t]*JOIN(?<rest>[^\r\n]*)\r?$',
        {
            param($m)
            return $m.Groups['indent'].Value +
                   $m.Groups['kind'].Value +
                   $m.Groups['outer'].Value +
                   ' JOIN' +
                   $m.Groups['rest'].Value
        }
    )
}

function Format-OneUnit {
    param([string]$Sql)

    $cleanUnit = $Sql.Trim()
    $formatter = $UnitFormatter

    # DB2 DGTT AS (...) contains a complete child query. Format that child with
    # its own width budget and then place it back under the parent declaration.
    if (Test-Path $DgttFormatter -and
        $cleanUnit -match '(?is)\bDECLARE\s+GLOBAL\s+TEMPORARY\s+TABLE\b.*?\bAS\s*\(') {
        $formatter = $DgttFormatter
    }

    $formatted = $cleanUnit |
        powershell -NoProfile -ExecutionPolicy Bypass -File $formatter |
        Out-String
    $formatted = $formatted.TrimEnd("`r", "`n")

    # Sibling CASE expressions joined by arithmetic operators must stay siblings.
    # Normalize those chains before the generic CASE branch presentation runs.
    if (Test-Path $CaseArithmetic) {
        $formatted = $formatted |
            powershell -NoProfile -ExecutionPolicy Bypass -File $CaseArithmetic |
            Out-String
        $formatted = $formatted.TrimEnd("`r", "`n")
    }

    # Long searched CASE expressions can leave later WHEN branches attached to
    # the preceding THEN result. Repair those branch boundaries only when the
    # selected advanced profile explicitly requests multiline CASE formatting.
    if (Test-Path $CaseBranchRepair) {
        $formatted = $formatted |
            powershell -NoProfile -ExecutionPolicy Bypass -File $CaseBranchRepair |
            Out-String
        $formatted = $formatted.TrimEnd("`r", "`n")
    }

    # A WHEN condition is itself a structured expression. Refine inline EXISTS
    # queries as independent SQL units and split top-level boolean predicates
    # according to the user's selected boolean-operator style.
    if (Test-Path $CaseConditionDetail) {
        $formatted = $formatted |
            powershell -NoProfile -ExecutionPolicy Bypass -File $CaseConditionDetail |
            Out-String
        $formatted = $formatted.TrimEnd("`r", "`n")
    }

    return (Repair-DetachedJoinModifiers $formatted)
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$units = @(Split-TopLevelStatements $inputSql)
$out = New-Object System.Collections.Generic.List[string]

foreach ($unit in $units) {
    $formatted = Format-OneUnit $unit
    if (-not [string]::IsNullOrWhiteSpace($formatted)) {
        $out.Add($formatted.Trim())
    }
}

[Console]::Out.Write(($out -join ([Environment]::NewLine + [Environment]::NewLine)).TrimEnd())
