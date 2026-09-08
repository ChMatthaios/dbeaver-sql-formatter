<#
    Final presentation cleanup for the Windows app.

    The semantic formatter works from syntactically safe formatter output. This
    pass fixes presentation artifacts that can remain when a logical expression
    was already split across physical lines before the semantic pass saw it:
      - a window-function alias left on its own line after `) AS`;
      - a BETWEEN upper bound rejoined with alignment spaces instead of a newline;
      - a logical CASE condition whose THEN branch was rejoined with indentation.
#>

$ErrorActionPreference = 'Stop'
$script:MaxLineLength = 120

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
    catch {
        # Invalid local settings must never break formatting.
    }
}

function Get-LeadingWhitespace {
    param([string]$Text)
    return [regex]::Match($Text, '^\s*').Value
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$lines = @(($inputSql -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")
$out = New-Object System.Collections.Generic.List[string]
$i = 0

while ($i -lt $lines.Count) {
    $line = $lines[$i]

    # A window expression may arrive as:
    #   ... AND CURRENT ROW) AS
    #   RUNNING_TOTAL,
    # Keep the alias with the closing window expression when the line still fits.
    if ($i + 1 -lt $lines.Count -and
        $line -match '(?i)\)\s+AS\s*$' -and
        $lines[$i + 1].Trim() -match '^[A-Z_][A-Z0-9_$#]*,?$') {
        $candidate = $line.TrimEnd() + ' ' + $lines[$i + 1].Trim()
        if ($candidate.Length -le $script:MaxLineLength) {
            $out.Add($candidate)
            $i += 2
            continue
        }
    }

    # If the semantic pass reconstructed a BETWEEN split as alignment spaces,
    # restore the intended semantic line break before AND.
    $between = [regex]::Match(
        $line,
        '^(?<indent>\s*)(?<left>.*\bBETWEEN\s+.+?)\s{2,}AND\s+(?<right>.+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($between.Success) {
        $firstLine = $between.Groups['indent'].Value + $between.Groups['left'].Value.TrimEnd()
        $betweenColumn = $firstLine.IndexOf('BETWEEN', [System.StringComparison]::OrdinalIgnoreCase)
        if ($betweenColumn -ge 0) {
            $secondLine = (' ' * ($betweenColumn + 4)) + 'AND ' + $between.Groups['right'].Value.Trim()
            if ($firstLine.Length -le $script:MaxLineLength -and $secondLine.Length -le $script:MaxLineLength) {
                $out.Add($firstLine)
                $out.Add($secondLine)
                $i++
                continue
            }
        }
    }

    # A logical CASE condition should break at the SQL boundary, not be glued
    # back together by the repeated indentation that preceded THEN.
    $caseThen = [regex]::Match(
        $line,
        '^(?<indent>\s*)WHEN\s+(?<condition>.+?)\s{2,}THEN\s+(?<result>.+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($caseThen.Success -and $caseThen.Groups['condition'].Value -match '(?i)\b(?:AND|OR)\b') {
        $indent = $caseThen.Groups['indent'].Value
        $whenLine = $indent + 'WHEN ' + $caseThen.Groups['condition'].Value.Trim()
        $thenLine = $indent + 'THEN ' + $caseThen.Groups['result'].Value.Trim()
        if ($whenLine.Length -le $script:MaxLineLength -and $thenLine.Length -le $script:MaxLineLength) {
            $out.Add($whenLine)
            $out.Add($thenLine)
            $i++
            continue
        }
    }

    $out.Add($line)
    $i++
}

[Console]::Out.Write(($out -join [Environment]::NewLine).TrimEnd())