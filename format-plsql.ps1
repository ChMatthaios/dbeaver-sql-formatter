<#
    Oracle PL/SQL safety wrapper.

    format-plsql-engine.ps1 handles Oracle SQL clauses and embedded SQL. This
    wrapper adds a program-unit indentation pass for anonymous blocks, routines,
    packages and triggers while preserving the engine's relative SQL alignment.
#>

$ErrorActionPreference = 'Stop'
$Engine = Join-Path $PSScriptRoot 'format-plsql-engine.ps1'

function Normalize-PlsqlProgramText {
    param([string]$Text)
    return (($Text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim())
}

function Test-PlsqlProgramUnit {
    param([string]$Sql)
    $n = Normalize-PlsqlProgramText $Sql
    return ($n -match '^(?i)(DECLARE\b|BEGIN\b|CREATE\s+(?:OR\s+REPLACE\s+)?(?:EDITIONABLE\s+|NONEDITIONABLE\s+)?(?:PROCEDURE|FUNCTION|PACKAGE(?:\s+BODY)?|TRIGGER|TYPE\s+BODY)\b)')
}

function Get-LeadingCount {
    param([string]$Line)
    return ($Line.Length - $Line.TrimStart().Length)
}

function Get-ParenDeltaSimple {
    param([string]$Text)
    $delta = 0
    $single = $false
    $double = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($single) {
            if ($ch -eq "'") {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
                $single = $false
            }
            continue
        }
        if ($double) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i++; continue }
                $double = $false
            }
            continue
        }
        if ($ch -eq "'") { $single = $true; continue }
        if ($ch -eq '"') { $double = $true; continue }
        if ($ch -eq '(') { $delta++ }
        elseif ($ch -eq ')') { $delta-- }
    }
    return $delta
}

function Get-StackBase {
    param(
        [System.Collections.Generic.List[object]]$Stack,
        [string[]]$Types
    )
    for ($i = $Stack.Count - 1; $i -ge 0; $i--) {
        if ($Types -contains [string]$Stack[$i].Type) { return [int]$Stack[$i].Base }
    }
    return 0
}

function Pop-StackType {
    param(
        [System.Collections.Generic.List[object]]$Stack,
        [string[]]$Types
    )
    for ($i = $Stack.Count - 1; $i -ge 0; $i--) {
        if ($Types -contains [string]$Stack[$i].Type) {
            $base = [int]$Stack[$i].Base
            while ($Stack.Count -gt $i) { $Stack.RemoveAt($Stack.Count - 1) }
            return $base
        }
    }
    return 0
}

function Add-ProgramLine {
    param(
        [System.Collections.Generic.List[string]]$Out,
        [int]$Indent,
        [string]$Text
    )
    [void]$Out.Add((' ' * [Math]::Max(0, $Indent)) + $Text.Trim())
}

function Format-PlsqlProgramIndentation {
    param([string]$Formatted)

    $lines = @(($Formatted -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")
    $out = New-Object System.Collections.Generic.List[string]
    $stack = New-Object 'System.Collections.Generic.List[object]'
    $indent = 0
    $declarationBase = $null
    $exceptionBase = $null
    $inExceptionHandler = $false
    $headerParenDepth = 0
    $inHeaderParams = $false
    $i = 0

    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        $trim = $line.Trim()
        if (-not $trim) { $i++; continue }
        $upper = $trim.ToUpperInvariant()

        if ($trim -eq '/') {
            [void]$out.Add('/')
            $i++
            continue
        }

        if ($trim.StartsWith('--') -or $trim.StartsWith('/*')) {
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $i++
            continue
        }

        # Preserve relative clause alignment for SQL statements already formatted
        # by the Oracle engine, but place the whole SQL unit at the block indent.
        if ($upper -match '^(SELECT|INSERT|UPDATE|DELETE|MERGE|WITH)\b') {
            $block = New-Object System.Collections.Generic.List[string]
            [void]$block.Add($line)
            $j = $i
            while (-not $lines[$j].TrimEnd().EndsWith(';') -and $j + 1 -lt $lines.Count) {
                $j++
                [void]$block.Add($lines[$j])
            }
            $baseLeading = Get-LeadingCount $block[0]
            foreach ($sqlLine in $block) {
                $relative = [Math]::Max(0, (Get-LeadingCount $sqlLine) - $baseLeading)
                Add-ProgramLine -Out $out -Indent ($indent + $relative) -Text $sqlLine.TrimStart()
            }
            $i = $j + 1
            continue
        }

        if ($upper -match '^CREATE\s+') {
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $headerParenDepth = Get-ParenDeltaSimple $trim
            $inHeaderParams = $headerParenDepth -gt 0
            if ($upper -match '\b(AS|IS)\s*$' -and -not $inHeaderParams) {
                $declarationBase = $indent
                $indent += 2
            }
            $i++
            continue
        }

        if ($inHeaderParams) {
            $headerParenDepth += Get-ParenDeltaSimple $trim
            if ($headerParenDepth -gt 0) {
                Add-ProgramLine -Out $out -Indent ($indent + 2) -Text $trim
            }
            else {
                Add-ProgramLine -Out $out -Indent $indent -Text $trim
                $inHeaderParams = $false
                if ($upper -match '\b(AS|IS)\s*$') {
                    $declarationBase = $indent
                    $indent += 2
                }
            }
            $i++
            continue
        }

        if ($upper -match '^DECLARE\b') {
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $declarationBase = $indent
            $indent += 2
            $i++
            continue
        }

        if ($upper -match '^(AS|IS)\b' -and $upper -notmatch ':=') {
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $declarationBase = $indent
            $indent += 2
            $i++
            continue
        }

        if ($upper -match '^BEGIN\b') {
            if ($null -ne $declarationBase) { $indent = [int]$declarationBase }
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            [void]$stack.Add([pscustomobject]@{ Type = 'BEGIN'; Base = $indent })
            $indent += 2
            $declarationBase = $null
            $exceptionBase = $null
            $inExceptionHandler = $false
            $i++
            continue
        }

        if ($upper -match '^EXCEPTION\b') {
            $base = Get-StackBase -Stack $stack -Types @('BEGIN')
            $indent = $base
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $exceptionBase = $base
            $indent = $base + 2
            $inExceptionHandler = $false
            $i++
            continue
        }

        if ($null -ne $exceptionBase -and $upper -match '^WHEN\b.*\bTHEN\b') {
            $indent = [int]$exceptionBase + 2
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $indent = [int]$exceptionBase + 4
            $inExceptionHandler = $true
            $i++
            continue
        }

        if ($upper -match '^ELSIF\b.*\bTHEN\b|^ELSE\b') {
            $base = Get-StackBase -Stack $stack -Types @('IF')
            $indent = $base
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $indent = $base + 2
            $i++
            continue
        }

        if ($upper -match '^IF\b.*\bTHEN\b') {
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            [void]$stack.Add([pscustomobject]@{ Type = 'IF'; Base = $indent })
            $indent += 2
            $i++
            continue
        }

        if ($upper -match '^(FOR\b.*\bLOOP\b|WHILE\b.*\bLOOP\b|LOOP\b)') {
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            [void]$stack.Add([pscustomobject]@{ Type = 'LOOP'; Base = $indent })
            $indent += 2
            $i++
            continue
        }

        if ($upper -match '^CASE\b') {
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            [void]$stack.Add([pscustomobject]@{ Type = 'CASE'; Base = $indent })
            $indent += 2
            $i++
            continue
        }

        if ($upper -match '^END\s+IF\b') {
            $base = Pop-StackType -Stack $stack -Types @('IF')
            $indent = $base
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $i++
            continue
        }

        if ($upper -match '^END\s+LOOP\b') {
            $base = Pop-StackType -Stack $stack -Types @('LOOP')
            $indent = $base
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $i++
            continue
        }

        if ($upper -match '^END\s+CASE\b') {
            $base = Pop-StackType -Stack $stack -Types @('CASE')
            $indent = $base
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $i++
            continue
        }

        if ($upper -match '^END\b') {
            $base = Pop-StackType -Stack $stack -Types @('BEGIN')
            $indent = $base
            Add-ProgramLine -Out $out -Indent $indent -Text $trim
            $exceptionBase = $null
            $inExceptionHandler = $false
            $i++
            continue
        }

        Add-ProgramLine -Out $out -Indent $indent -Text $trim
        $i++
    }

    return ($out -join [Environment]::NewLine).TrimEnd()
}

$inputSql = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputSql)) { exit 0 }

$formatted = $inputSql |
    powershell -NoProfile -ExecutionPolicy Bypass -File $Engine |
    Out-String
$formatted = $formatted.TrimEnd("`r", "`n")

if (Test-PlsqlProgramUnit $inputSql) {
    $formatted = Format-PlsqlProgramIndentation $formatted
}

[Console]::Out.Write($formatted)