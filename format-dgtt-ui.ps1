<#
    Placement-aware formatter for DB2 DECLARE GLOBAL TEMPORARY TABLE ... AS (...).

    The query inside AS (...) is a complete SQL unit. Format that unit independently,
    then place it inside the DGTT container with the configured indentation. This keeps
    the parent declaration from stealing the child's width/indent budget.
#>

$ErrorActionPreference = 'Stop'

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$unitFormatter = Join-Path $PSScriptRoot 'format-ui.ps1'
$settingsPath = Join-Path $PSScriptRoot 'settings\settings.json'
$indentSize = 2

try {
    if (Test-Path $settingsPath) {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        $parsed = 0
        if ($settings.PSObject.Properties.Name -contains 'indentSize' -and
            [int]::TryParse([string]$settings.indentSize, [ref]$parsed) -and
            $parsed -in @(2, 4)) {
            $indentSize = $parsed
        }
    }
}
catch {
    $indentSize = 2
}

function Find-MatchingSqlParen {
    param([string]$Text, [int]$OpenIndex)

    $depth = 0
    $single = $false
    $double = $false
    $bracket = $false
    $lineComment = $false
    $blockComment = $false

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
        if ($bracket) {
            if ($ch -eq ']') {
                if ($next -eq ']') { $i++ } else { $bracket = $false }
            }
            continue
        }

        if ($ch -eq '-' -and $next -eq '-') { $lineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $blockComment = $true; $i++; continue }
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '[') { $bracket = $true; continue }
        if ($ch -eq '(') { $depth++; continue }
        if ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }

    return -1
}

$statementMatch = [regex]::Match(
    $inputSql,
    '(?is)\bDECLARE\s+GLOBAL\s+TEMPORARY\s+TABLE\s+[^\r\n;]+?\s+AS\s*\('
)

if (-not $statementMatch.Success) {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

$open = $inputSql.IndexOf('(', $statementMatch.Index)
if ($open -lt 0) {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

$close = Find-MatchingSqlParen -Text $inputSql -OpenIndex $open
if ($close -lt 0) {
    [Console]::Out.Write($inputSql.TrimEnd("`r", "`n"))
    exit 0
}

$prefix = $inputSql.Substring(0, $statementMatch.Index).TrimEnd()
$header = $inputSql.Substring($statementMatch.Index, $open - $statementMatch.Index)
$header = ($header -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
$inner = $inputSql.Substring($open + 1, $close - $open - 1).Trim()
$tail = $inputSql.Substring($close + 1).Trim()
$tail = ($tail -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()

$formattedInner = $inner |
    powershell -NoProfile -ExecutionPolicy Bypass -File $unitFormatter |
    Out-String
$formattedInner = $formattedInner.TrimEnd("`r", "`n")
$formattedInner = $formattedInner -replace ';\s*$', ''

$indent = ' ' * $indentSize
$innerLines = @($formattedInner -split "`r?`n")
$out = New-Object System.Collections.Generic.List[string]

if ($prefix) { $out.Add($prefix) }
$out.Add($header + ' (')
foreach ($line in $innerLines) {
    if ([string]::IsNullOrWhiteSpace($line)) { $out.Add('') }
    else { $out.Add($indent + $line) }
}
$out.Add(')')
if ($tail) { $out.Add($tail) }

[Console]::Out.Write(($out -join [Environment]::NewLine).TrimEnd())
