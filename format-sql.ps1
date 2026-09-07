<#
    DBeaver SQL Formatter entry point.

    Shared SQL is handled by the core formatter. PostgreSQL-, T-SQL- and Oracle
    PL/SQL-specific syntax is detected automatically and routed through the
    appropriate dialect formatter, so one DBeaver external formatter command
    works across DB2, PostgreSQL, SQL Server/Azure SQL and Oracle.
#>

$ErrorActionPreference = "Stop"

$CoreFormatter = Join-Path $PSScriptRoot "format-sql-core.ps1"
$MergeFormatter = Join-Path $PSScriptRoot "format-merge.ps1"
$PolishFormatter = Join-Path $PSScriptRoot "format-polish.ps1"
$CompactSubqueryFormatter = Join-Path $PSScriptRoot "format-compact-subqueries.ps1"
$PostgresFormatter = Join-Path $PSScriptRoot "format-postgresql.ps1"
$TsqlFormatter = Join-Path $PSScriptRoot "format-tsql-safe.ps1"
$PlsqlFormatter = Join-Path $PSScriptRoot "format-plsql.ps1"

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

function Invoke-TsqlFormatter {
    param([string]$Sql)

    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $TsqlFormatter |
        Out-String

    return $formatted.TrimEnd("`r", "`n")
}

function Invoke-PlsqlFormatter {
    param([string]$Sql)

    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $PlsqlFormatter |
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

function Get-DialectDetectionText {
    param([string]$Sql)

    # Remove text whose contents must not influence dialect detection. For example,
    # an email address inside a string must not make '@' look like a T-SQL variable.
    $masked = $Sql
    $masked = [regex]::Replace($masked, '/\*[\s\S]*?\*/', ' ')
    $masked = [regex]::Replace($masked, '--[^\r\n]*', ' ')
    $masked = [regex]::Replace($masked, "(?is)\bq'\[[\s\S]*?\]'", ' ')
    $masked = [regex]::Replace($masked, "(?is)\bq'\{[\s\S]*?\}'", ' ')
    $masked = [regex]::Replace($masked, "(?is)\bq'\([\s\S]*?\)'", ' ')
    $masked = [regex]::Replace($masked, "(?is)\bq'<[\s\S]*?>'", ' ')
    $masked = [regex]::Replace($masked, '\$[A-Za-z_][A-Za-z0-9_]*\$[\s\S]*?\$[A-Za-z_][A-Za-z0-9_]*\$', ' ')
    $masked = [regex]::Replace($masked, '\$\$[\s\S]*?\$\$', ' ')
    $masked = [regex]::Replace($masked, "(?i)N'(?:''|[^'])*'", ' ')
    $masked = [regex]::Replace($masked, "'(?:''|[^'])*'", ' ')
    $masked = [regex]::Replace($masked, '"(?:""|[^"])*"', ' ')
    return ($masked -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
}

function Test-TsqlSpecificSyntax {
    param([string]$Sql)

    $normalized = Get-DialectDetectionText -Sql $Sql
    if (-not $normalized) { return $false }

    $patterns = @(
        '(?<![A-Za-z0-9_])\[(?:\]\]|[^\]])+\]',
        '(?<![A-Za-z0-9_])##?[A-Za-z_][A-Za-z0-9_]*',
        '(?<![A-Za-z0-9_])@@?[A-Za-z_][A-Za-z0-9_]*',
        '\bTOP\s*(?:\(|\d)',
        '\b(?:CROSS|OUTER)\s+APPLY\b',
        '\bOUTPUT\b',
        '\bWITH\s*\(\s*(?:NOLOCK|UPDLOCK|HOLDLOCK|ROWLOCK|READPAST|TABLOCKX?|XLOCK|NOWAIT)\b',
        '\bCREATE\s+OR\s+ALTER\b',
        '\bBEGIN\s+(?:TRY|CATCH)\b|\bEND\s+(?:TRY|CATCH)\b',
        '\b(?:TRY_CONVERT|TRY_CAST|ISNULL|IIF|GETDATE|SYSDATETIME|NEWID)\s*\(',
        '\b(?:NVARCHAR|NCHAR|UNIQUEIDENTIFIER|DATETIME2|DATETIMEOFFSET|VARBINARY)\b',
        '\bIDENTITY\s*\(',
        '\bOPTION\s*\(',
        '\bFOR\s+(?:JSON|XML)\b',
        '\bOFFSET\s+[^\s]+\s+ROWS\s+FETCH\s+(?:NEXT|FIRST)\b',
        '(?m)^\s*GO(?:\s+\d+)?\s*$',
        '\b(?:RAISERROR|THROW)\b'
    )

    foreach ($pattern in $patterns) {
        if ($normalized -match ('(?i)' + $pattern)) { return $true }
    }
    return $false
}

function Test-PostgreSqlSpecificSyntax {
    param([string]$Sql)

    $normalized = ($Sql -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
    if (-not $normalized) { return $false }

    # Strong PostgreSQL signals. Ordinary ANSI SELECT/INSERT/UPDATE/DELETE SQL
    # stays on the common path and therefore works for all supported dialects.
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

function Test-PlsqlSpecificSyntax {
    param([string]$Sql)

    if ($Sql -match "(?is)\bq'([\[\{\(<]|[^A-Za-z0-9\s'])") { return $true }
    $normalized = Get-DialectDetectionText -Sql $Sql
    if (-not $normalized) { return $false }

    $patterns = @(
        ':=',
        '%(?:TYPE|ROWTYPE|ROWCOUNT|FOUND|NOTFOUND|ISOPEN)\b',
        '\bCONNECT\s+BY\b',
        '\bSTART\s+WITH\b',
        '\bRETURNING\b[\s\S]*\bINTO\b',
        '\bBULK\s+COLLECT\b',
        '\bFORALL\b',
        '\bPRAGMA\b',
        '\bSYS_REFCURSOR\b',
        '\bRAISE_APPLICATION_ERROR\b',
        '\bDBMS_[A-Z0-9_]+\s*\.',
        '\bVARCHAR2\b|\bPLS_INTEGER\b|\bBINARY_INTEGER\b',
        '\bFROM\s+DUAL\b',
        '\bROWNUM\b',
        '\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:EDITIONABLE\s+|NONEDITIONABLE\s+)?(?:PACKAGE(?:\s+BODY)?|TYPE\s+BODY)\b',
        '^DECLARE\b[\s\S]*\bBEGIN\b',
        '\bEXCEPTION\b[\s\S]*\bWHEN\b'
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
            if ($trimmed -match '\*/') { $inBlockComment = $false }
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
            if ($trimmed -notmatch '\*/') { $inBlockComment = $true }
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

    if ($index -eq 0) { return [pscustomobject]@{ Leading = @(); Body = $Sql } }

    $body = if ($index -lt $lines.Count) {
        ($lines[$index..($lines.Count - 1)] -join [Environment]::NewLine)
    }
    else { '' }

    while ($leading.Count -gt 0 -and $leading[$leading.Count - 1] -eq '') { $leading.RemoveAt($leading.Count - 1) }
    return [pscustomobject]@{ Leading = @($leading); Body = $body }
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$split = Split-LeadingCommentBlock -Sql $inputSql
$leadingComments = @($split.Leading)
$bodySql = [string]$split.Body

if ([string]::IsNullOrWhiteSpace($bodySql)) {
    [Console]::Out.Write(($leadingComments -join [Environment]::NewLine).TrimEnd())
    exit 0
}

$normalizedBody = ($bodySql -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
$isRoutine = $normalizedBody -match '^(?i)(CREATE|ALTER)\s+(?:(?:OR\s+(?:REPLACE|ALTER))\s+)?(?:EDITIONABLE\s+|NONEDITIONABLE\s+)?(PROCEDURE|PROC|FUNCTION|TRIGGER|PACKAGE(?:\s+BODY)?|TYPE\s+BODY)\b'
$isTsql = Test-TsqlSpecificSyntax -Sql $bodySql
$isPlsql = (-not $isTsql) -and (Test-PlsqlSpecificSyntax -Sql $bodySql)
$isPostgres = (-not $isTsql -and -not $isPlsql) -and (Test-PostgreSqlSpecificSyntax -Sql $bodySql)

if ($isTsql) {
    $formattedBody = Invoke-TsqlFormatter -Sql $bodySql
    if (-not $isRoutine) {
        $formattedBody = Invoke-PolishFormatter -Sql $formattedBody
        $formattedBody = Invoke-CompactSubqueryFormatter -Sql $formattedBody
    }
}
elseif ($isPostgres) {
    $formattedBody = Invoke-PostgresFormatter -Sql $bodySql
    if (-not $isRoutine) {
        $formattedBody = Invoke-PolishFormatter -Sql $formattedBody
        $formattedBody = Invoke-CompactSubqueryFormatter -Sql $formattedBody
    }
}
elseif ($isPlsql) {
    $formattedBody = Invoke-PlsqlFormatter -Sql $bodySql
    if (-not $isRoutine -and $normalizedBody -notmatch '^(?i)(DECLARE|BEGIN)\b') {
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

                $formattedMerge = [regex]::Replace(
                    $formattedMerge,
                    ';(?=\r?\n\s*\)\s+[^\s;]+\s*(?:\r?\n|$))',
                    ''
                )

                $mergeLines = @($formattedMerge -split "`r?`n")
                foreach ($mergeLine in $mergeLines) { $out.Add((' ' * $leading) + $mergeLine) }
            }
            else { $out.Add($line) }
        }

        $formattedBody = ($out -join [Environment]::NewLine).TrimEnd()
        $formattedBody = Invoke-PolishFormatter -Sql $formattedBody
        $formattedBody = Invoke-CompactSubqueryFormatter -Sql $formattedBody
    }
}

$final = New-Object System.Collections.Generic.List[string]
foreach ($commentLine in $leadingComments) { $final.Add($commentLine) }
if ($leadingComments.Count -gt 0 -and $formattedBody) { $final.Add('') }
if ($formattedBody) {
    foreach ($line in @($formattedBody -split "`r?`n")) { $final.Add($line) }
}

[Console]::Out.Write(($final -join [Environment]::NewLine).TrimEnd())