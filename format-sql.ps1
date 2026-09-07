<#
    DBeaver SQL Formatter entry point.

    Shared SQL is handled by the core formatter. PostgreSQL-specific syntax is
    detected automatically and routed through format-postgresql.ps1, so the same
    DBeaver external formatter command can be used for DB2 and PostgreSQL.
#>

$ErrorActionPreference = "Stop"

$CoreFormatter = Join-Path $PSScriptRoot "format-sql-core.ps1"
$MergeFormatter = Join-Path $PSScriptRoot "format-merge.ps1"
$PolishFormatter = Join-Path $PSScriptRoot "format-polish.ps1"
$CompactSubqueryFormatter = Join-Path $PSScriptRoot "format-compact-subqueries.ps1"
$PostgresFormatter = Join-Path $PSScriptRoot "format-postgresql.ps1"

function Invoke-CoreFormatter {
    param([string]$Sql)

    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $CoreFormatter |
        Out-String

    return $formatted.TrimEnd("`r", "`n")
}

function Invoke-PostgresFormatter {
    param([string]$Sql)

    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $PostgresFormatter |
        Out-String

    return $formatted.TrimEnd("`r", "`n")
}

function Invoke-PolishFormatter {
    param([string]$Sql)

    if ([string]::IsNullOrWhiteSpace($Sql)) { return $Sql }
    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $PolishFormatter |
        Out-String
    return $formatted.TrimEnd("`r", "`n")
}

function Invoke-CompactSubqueryFormatter {
    param([string]$Sql)

    if ([string]::IsNullOrWhiteSpace($Sql)) { return $Sql }
    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $CompactSubqueryFormatter |
        Out-String
    return $formatted.TrimEnd("`r", "`n")
}

function Test-PostgreSqlSpecificSyntax {
    param([string]$Sql)

    $normalized = ($Sql -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
    if (-not $normalized) { return $false }

    # Strong PostgreSQL signals. Ordinary ANSI SELECT/INSERT/UPDATE/DELETE SQL
    # stays on the common path and therefore works for both dialects.
    $patterns = @(
        '\$\$|\$[A-Za-z_][A-Za-z0-9_]*\$',
        '::',
        '->>|->|#>>|#>',
        '\bON\s+CONFLICT\b',
        '\bRETURNING\b',
        '\bWITH\s+RECURSIVE\b',
        '\bDISTINCT\s+ON\s*\(',
        '\bLATERAL\b',
        '\bFILTER\s*\(',
        '\bILIKE\b',
        '\bARRAY\s*\[',
        '\b(?:TRUE|FALSE)\b',
        '\bCREATE\s+(?:(?:GLOBAL|LOCAL)\s+)?(?:TEMP|TEMPORARY)\s+TABLE\b',
        '\bFOR\s+(?:NO\s+KEY\s+UPDATE|KEY\s+SHARE|UPDATE|SHARE)\b',
        '^UPDATE\b.*\bFROM\b',
        '^DELETE\b.*\bUSING\b'
    )

    foreach ($pattern in $patterns) {
        if ($normalized -match ('(?i)' + $pattern)) { return $true }
    }
    return $false
}

function Split-LeadingCommentBlock {
    param([string]$Sql)

    $normalized = $Sql -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = @($normalized -split "`n", -1)
    $leading = New-Object System.Collections.Generic.List[string]
    $index = 0
    $inBlockComment = $false

    while ($index -lt $lines.Count) {
        $line = $lines[$index]
        $trimmed = $line.TrimStart()

        if ($inBlockComment) {
            $leading.Add($line.TrimEnd())
            if ($trimmed -match '\*/') {
                $inBlockComment = $false
            }
            $index++
            continue
        }

        if ($trimmed.StartsWith('--')) {
            $leading.Add($line.TrimEnd())
            $index++
            continue
        }

        if ($trimmed.StartsWith('/*')) {
            $leading.Add($line.TrimEnd())
            if ($trimmed -notmatch '\*/') {
                $inBlockComment = $true
            }
            $index++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line) -and $leading.Count -gt 0) {
            $leading.Add('')
            $index++
            continue
        }

        break
    }

    if ($index -eq 0) {
        return [pscustomobject]@{ Leading = @(); Body = $Sql }
    }

    $body = if ($index -lt $lines.Count) {
        ($lines[$index..($lines.Count - 1)] -join [Environment]::NewLine)
    }
    else {
        ''
    }

    while ($leading.Count -gt 0 -and $leading[$leading.Count - 1] -eq '') {
        $leading.RemoveAt($leading.Count - 1)
    }

    return [pscustomobject]@{ Leading = @($leading); Body = $body }
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) {
    exit 0
}

$split = Split-LeadingCommentBlock -Sql $inputSql
$leadingComments = @($split.Leading)
$bodySql = [string]$split.Body

if ([string]::IsNullOrWhiteSpace($bodySql)) {
    [Console]::Out.Write(($leadingComments -join [Environment]::NewLine).TrimEnd())
    exit 0
}

$normalizedBody = ($bodySql -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
$isRoutine = $normalizedBody -match '^(?i)CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b'
$isPostgres = Test-PostgreSqlSpecificSyntax -Sql $bodySql

if ($isPostgres) {
    $formattedBody = Invoke-PostgresFormatter -Sql $bodySql
    if (-not $isRoutine) {
        $formattedBody = Invoke-PolishFormatter -Sql $formattedBody
        $formattedBody = Invoke-CompactSubqueryFormatter -Sql $formattedBody
    }
}
else {
    $coreOutput = Invoke-CoreFormatter -Sql $bodySql

    # SQL PL routines already contain their own statement boundaries. Do not feed
    # individual MERGE lines from a procedure/function into the standalone MERGE
    # formatter, otherwise a partial line can be mistaken for a complete statement.
    if ($isRoutine) {
        $formattedBody = $coreOutput
    }
    else {
        $lines = @($coreOutput -split "`r?`n")
        $out = New-Object System.Collections.Generic.List[string]

        foreach ($line in $lines) {
            $trimmed = $line.TrimStart()
            if ($trimmed -match '^(?i)MERGE\b') {
                $leading = $line.Length - $trimmed.Length
                $formattedMerge = $trimmed |
                    powershell -NoProfile -ExecutionPolicy Bypass -File $MergeFormatter |
                    Out-String
                $formattedMerge = $formattedMerge.TrimEnd("`r", "`n")

                # The inner USING query is a SQL unit embedded inside MERGE, so it
                # must not carry its own statement terminator before the close paren.
                $formattedMerge = [regex]::Replace(
                    $formattedMerge,
                    ';(?=\r?\n\s*\)\s+[^\s;]+\s*(?:\r?\n|$))',
                    ''
                )

                $mergeLines = @($formattedMerge -split "`r?`n")
                foreach ($mergeLine in $mergeLines) {
                    $out.Add((' ' * $leading) + $mergeLine)
                }
            }
            else {
                $out.Add($line)
            }
        }

        $formattedBody = ($out -join [Environment]::NewLine).TrimEnd()
        $formattedBody = Invoke-PolishFormatter -Sql $formattedBody
        $formattedBody = Invoke-CompactSubqueryFormatter -Sql $formattedBody
    }
}

$final = New-Object System.Collections.Generic.List[string]
foreach ($commentLine in $leadingComments) {
    $final.Add($commentLine)
}
if ($leadingComments.Count -gt 0 -and $formattedBody) {
    $final.Add('')
}
if ($formattedBody) {
    foreach ($line in @($formattedBody -split "`r?`n")) {
        $final.Add($line)
    }
}

[Console]::Out.Write(($final -join [Environment]::NewLine).TrimEnd())