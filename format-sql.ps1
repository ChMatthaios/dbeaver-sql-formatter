<#
    DBeaver SQL Formatter entry point.

    The core heuristic formatter handles SELECT/CTE/subquery/DML/DDL formatting.
    MERGE is post-processed as a container because the legacy dispatcher used to
    flatten unsupported standalone MERGE statements into a single line.
    A final structural polish pass fixes long CASE conditions and parenthesized
    logical groups before the formatted SQL is returned to DBeaver.
#>

$ErrorActionPreference = "Stop"

$CoreFormatter = Join-Path $PSScriptRoot "format-sql-core.ps1"
$MergeFormatter = Join-Path $PSScriptRoot "format-merge.ps1"
$PolishFormatter = Join-Path $PSScriptRoot "format-polish.ps1"

function Invoke-CoreFormatter {
    param([string]$Sql)

    $formatted = $Sql |
        powershell -NoProfile -ExecutionPolicy Bypass -File $CoreFormatter |
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

# A leading documentation/comment block belongs to the selected SQL, but it must
# not hide the real statement type from the core dispatcher. Keep it outside the
# parse/format pass, then place it back above the formatted query.
$split = Split-LeadingCommentBlock -Sql $inputSql
$leadingComments = @($split.Leading)
$bodySql = [string]$split.Body

if ([string]::IsNullOrWhiteSpace($bodySql)) {
    [Console]::Out.Write(($leadingComments -join [Environment]::NewLine).TrimEnd())
    exit 0
}

$coreOutput = Invoke-CoreFormatter -Sql $bodySql

# SQL PL routines already contain their own statement boundaries. Do not feed
# individual MERGE lines from a procedure/function into the standalone MERGE
# formatter, otherwise a partial line can be mistaken for a complete statement.
$normalizedBody = ($bodySql -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
$isRoutine = $normalizedBody -match '^(?i)CREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION)\b'

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

            # The inner USING query is a SQL unit embedded inside MERGE, so it must
            # not carry its own statement terminator before the closing parenthesis.
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