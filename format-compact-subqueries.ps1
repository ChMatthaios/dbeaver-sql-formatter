<#
    Compact already-formatted nested SELECT/WITH queries back into their parent
    expression when the complete parent line fits inside maxLineLength.

    The core formatter still formats every nested SQL unit recursively first.
    This pass is only a placement decision: if the formatted unit can safely live
    inline at its final indentation, keep it inline; otherwise preserve multiline
    formatting. CTE AS (...) bodies remain structural multiline containers.
#>

$ErrorActionPreference = "Stop"
$script:MaxLineLength = 120

$settingsPath = Join-Path $PSScriptRoot "settings\settings.json"
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties.Name -contains "maxLineLength") {
            $value = 0
            if ([int]::TryParse([string]$settings.maxLineLength, [ref]$value) -and $value -ge 60 -and $value -le 400) {
                $script:MaxLineLength = $value
            }
        }
    }
    catch {
        # Invalid local settings must never break DBeaver formatting.
    }
}

function Normalize-SqlFragment {
    param([string]$Text)

    $out = New-Object System.Text.StringBuilder
    $single = $false
    $double = $false
    $pendingSpace = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]

        if ($single) {
            [void]$out.Append($ch)
            if ($ch -eq "'") {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") {
                    $i++
                    [void]$out.Append("'")
                }
                else {
                    $single = $false
                }
            }
            continue
        }

        if ($double) {
            [void]$out.Append($ch)
            if ($ch -eq '"') {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') {
                    $i++
                    [void]$out.Append('"')
                }
                else {
                    $double = $false
                }
            }
            continue
        }

        if ($ch -eq "'") {
            if ($pendingSpace -and $out.Length -gt 0) { [void]$out.Append(' ') }
            $pendingSpace = $false
            [void]$out.Append($ch)
            $single = $true
            continue
        }

        if ($ch -eq '"') {
            if ($pendingSpace -and $out.Length -gt 0) { [void]$out.Append(' ') }
            $pendingSpace = $false
            [void]$out.Append($ch)
            $double = $true
            continue
        }

        if ([char]::IsWhiteSpace($ch)) {
            $pendingSpace = $true
            continue
        }

        if ($pendingSpace -and $out.Length -gt 0) {
            [void]$out.Append(' ')
        }
        $pendingSpace = $false
        [void]$out.Append($ch)
    }

    return $out.ToString().Trim()
}

function Find-SubqueryClose {
    param(
        [string[]]$Lines,
        [int]$StartLine,
        [int]$OpenIndex
    )

    $depth = 0
    $single = $false
    $double = $false

    for ($lineIndex = $StartLine; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = $Lines[$lineIndex]
        $start = if ($lineIndex -eq $StartLine) { $OpenIndex } else { 0 }

        for ($charIndex = $start; $charIndex -lt $line.Length; $charIndex++) {
            $ch = $line[$charIndex]

            if ($single) {
                if ($ch -eq "'") {
                    if ($charIndex + 1 -lt $line.Length -and $line[$charIndex + 1] -eq "'") {
                        $charIndex++
                    }
                    else {
                        $single = $false
                    }
                }
                continue
            }

            if ($double) {
                if ($ch -eq '"') {
                    if ($charIndex + 1 -lt $line.Length -and $line[$charIndex + 1] -eq '"') {
                        $charIndex++
                    }
                    else {
                        $double = $false
                    }
                }
                continue
            }

            if ($ch -eq "'") { $single = $true; continue }
            if ($ch -eq '"') { $double = $true; continue }

            if ($ch -eq '(') {
                $depth++
                continue
            }

            if ($ch -eq ')') {
                $depth--
                if ($depth -eq 0) {
                    return [pscustomobject]@{
                        Line = $lineIndex
                        Index = $charIndex
                    }
                }
            }
        }
    }

    return $null
}

function Try-CompactOneSubquery {
    param([string[]]$Lines)

    for ($start = $Lines.Count - 1; $start -ge 0; $start--) {
        $line = $Lines[$start]
        $matches = [regex]::Matches($line, '\((?=\s*(?:SELECT|WITH)\b)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($matches.Count -eq 0) { continue }

        for ($matchIndex = $matches.Count - 1; $matchIndex -ge 0; $matchIndex--) {
            $openIndex = $matches[$matchIndex].Index
            $prefix = $Lines[$start].Substring(0, $openIndex)

            # CTE bodies are structural SQL containers, not inline expression
            # subqueries. Preserve their established multiline layout.
            if ($prefix -match '(?i)\bAS\s*$') { continue }

            $close = Find-SubqueryClose -Lines $Lines -StartLine $start -OpenIndex $openIndex
            if ($null -eq $close -or $close.Line -eq $start) { continue }

            $blockLines = @($Lines[$start..$close.Line])
            $blockText = $blockLines -join [Environment]::NewLine

            # Never collapse comments; newline placement can be semantically relevant.
            if ($blockText -match '--|/\*|\*/') { continue }

            $firstPart = $Lines[$start].Substring($openIndex)
            $middle = New-Object System.Collections.Generic.List[string]
            $middle.Add($firstPart)
            for ($i = $start + 1; $i -lt $close.Line; $i++) {
                $middle.Add($Lines[$i])
            }
            $middle.Add($Lines[$close.Line].Substring(0, $close.Index + 1))

            $compactBlock = Normalize-SqlFragment ($middle -join [Environment]::NewLine)
            $suffix = $Lines[$close.Line].Substring($close.Index + 1)
            $candidate = $prefix + $compactBlock + $suffix

            if ($candidate.Length -gt $script:MaxLineLength) { continue }

            $newLines = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $start; $i++) { $newLines.Add($Lines[$i]) }
            $newLines.Add($candidate)
            for ($i = $close.Line + 1; $i -lt $Lines.Count; $i++) { $newLines.Add($Lines[$i]) }

            return [pscustomobject]@{
                Changed = $true
                Lines = @($newLines)
            }
        }
    }

    return [pscustomobject]@{
        Changed = $false
        Lines = $Lines
    }
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$lines = @(($inputSql -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")

# Bottom-up, repeated compaction lets an inner subquery become inline first and
# can then make an outer parenthesized SQL unit eligible for the same treatment.
while ($true) {
    $result = Try-CompactOneSubquery -Lines $lines
    $lines = @($result.Lines)
    if (-not $result.Changed) { break }
}

[Console]::Out.Write(($lines -join [Environment]::NewLine).TrimEnd())