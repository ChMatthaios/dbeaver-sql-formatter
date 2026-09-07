<#
    DBeaver SQL Formatter entry point.

    The core heuristic formatter handles SELECT/CTE/subquery/DML/DDL formatting.
    MERGE is post-processed as a container because the legacy dispatcher used to
    flatten unsupported MERGE statements into a single line.
#>

$ErrorActionPreference = "Stop"

$CoreFormatter = Join-Path $PSScriptRoot "format-sql-core.ps1"
$MergeFormatter = Join-Path $PSScriptRoot "format-merge.ps1"

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) {
    exit 0
}

$coreOutput = $inputSql |
    powershell -NoProfile -ExecutionPolicy Bypass -File $CoreFormatter |
    Out-String
$coreOutput = $coreOutput.TrimEnd("`r", "`n")

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
        $mergeLines = @($formattedMerge -split "`r?`n")
        foreach ($mergeLine in $mergeLines) {
            $out.Add((' ' * $leading) + $mergeLine)
        }
    }
    else {
        $out.Add($line)
    }
}

[Console]::Out.Write(($out -join [Environment]::NewLine).TrimEnd())
