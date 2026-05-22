<#
    SQL Formatter Test Runner
    ------------------------------------------------------------
    Usage:
      .\format.ps1 -runall
      .\format.ps1 -check
      .\format.ps1 -file 01
      .\format.ps1 -file 04_complicated_multiline_statements.sql
      .\format.ps1 -list

    This script calls format-sql.ps1, which is the actual SQL formatter.

    Modes:
      -runall  Formats all tests and writes outputs to tests_out.
      -check   Formats all tests into a temporary folder and compares them
               against the committed outputs in tests_out.
      -file    Formats one matching test file and writes output to tests_out.
      -list    Lists available test input files.
#>

param(
    [switch]$runall,
    [switch]$check,
    [switch]$list,
    [string]$file
)

$RootDir = $PSScriptRoot
$Formatter = Join-Path $RootDir "format-sql.ps1"
$TestDir = Join-Path $RootDir "tests"
$OutDir = Join-Path $RootDir "tests_out"

function Get-TestFiles {
    Get-ChildItem $TestDir -Filter "*.sql" |
    Where-Object { $_.Name -notlike "*.out.sql" } |
    Sort-Object Name
}

function Format-OneFile {
    param(
        [System.IO.FileInfo]$InputFile,
        [string]$OutputDirectory = $OutDir,
        [switch]$Quiet
    )

    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

    $OutputFile = Join-Path $OutputDirectory ($InputFile.BaseName + ".out.sql")

    Get-Content $InputFile.FullName -Raw |
    powershell -NoProfile -ExecutionPolicy Bypass -File $Formatter |
    Set-Content $OutputFile -Encoding UTF8

    if (-not $Quiet) {
        Write-Host "Formatted:" $InputFile.Name "->" (Split-Path $OutputFile -Leaf)
    }

    return $OutputFile
}

function Test-FormatterOutput {
    $TempOutDir = Join-Path ([System.IO.Path]::GetTempPath()) ("sqlfmt-check-" + [guid]::NewGuid().ToString("N"))

    New-Item -ItemType Directory -Force -Path $TempOutDir | Out-Null

    $failed = 0
    $passed = 0

    try {
        foreach ($InputFile in Get-TestFiles) {
            $ActualFile = Format-OneFile -InputFile $InputFile -OutputDirectory $TempOutDir -Quiet
            $ExpectedFile = Join-Path $OutDir ($InputFile.BaseName + ".out.sql")

            if (-not (Test-Path $ExpectedFile)) {
                Write-Host "FAIL" $InputFile.Name "- missing expected output:" (Split-Path $ExpectedFile -Leaf) -ForegroundColor Red
                $failed++
                continue
            }

            $Actual = Get-Content $ActualFile -Raw
            $Expected = Get-Content $ExpectedFile -Raw

            if ($Actual -eq $Expected) {
                Write-Host "PASS" $InputFile.Name -ForegroundColor Green
                $passed++
            }
            else {
                Write-Host "FAIL" $InputFile.Name "- output differs from expected" -ForegroundColor Red
                $failed++
            }
        }
    }
    finally {
        Remove-Item $TempOutDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Check complete. Passed: $passed. Failed: $failed."

    if ($failed -gt 0) {
        exit 1
    }

    exit 0
}

if ($list) {
    Get-TestFiles | Select-Object -ExpandProperty Name
    exit 0
}

if ($runall) {
    Get-TestFiles | ForEach-Object {
        Format-OneFile -InputFile $_
    }

    Write-Host ""
    Write-Host "Done. Output folder:" $OutDir
    exit 0
}

if ($check) {
    Test-FormatterOutput
}

if ($file) {
    $matches = Get-TestFiles |
    Where-Object {
        $_.Name -eq $file -or
        $_.BaseName -eq $file -or
        $_.Name -like "$file*"
    }

    if ($matches.Count -eq 0) {
        Write-Host "No matching test file found for:" $file
        exit 1
    }

    if ($matches.Count -gt 1) {
        Write-Host "Multiple files matched. Be more specific:"
        $matches | Select-Object -ExpandProperty Name
        exit 1
    }

    Format-OneFile -InputFile $matches[0]

    Write-Host ""
    Write-Host "Done. Output folder:" $OutDir
    exit 0
}

Write-Host "Usage:"
Write-Host "  format --runall"
Write-Host "  format --check"
Write-Host "  format --file 01"
Write-Host "  format --file 04_complicated_multiline_statements.sql"
Write-Host "  format --list"