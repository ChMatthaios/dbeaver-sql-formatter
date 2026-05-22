<#
    SQL Formatter Test Runner
    ------------------------------------------------------------
    Usage:
      format --runall
      format --file 01
      format --file 04_complicated_multiline_statements.sql
      format --list

    This script calls format-sql.ps1, which is the actual SQL formatter.
#>

param(
    [switch]$runall,
    [switch]$list,
    [string]$file
)

$RootDir = $PSScriptRoot
$Formatter = Join-Path $RootDir "format-sql.ps1"
$TestDir = Join-Path $RootDir "tests"
$OutDir = Join-Path $RootDir "tests_out"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Format-OneFile {
    param(
        [System.IO.FileInfo]$InputFile
    )

    $OutputFile = Join-Path $OutDir ($InputFile.BaseName + ".out.sql")

    Get-Content $InputFile.FullName -Raw |
    powershell -NoProfile -ExecutionPolicy Bypass -File $Formatter |
    Set-Content $OutputFile -Encoding UTF8

    Write-Host "Formatted:" $InputFile.Name "->" (Split-Path $OutputFile -Leaf)
}

if ($list) {
    Get-ChildItem $TestDir -Filter "*.sql" |
    Where-Object { $_.Name -notlike "*.out.sql" } |
    Sort-Object Name |
    Select-Object -ExpandProperty Name

    exit 0
}

if ($runall) {
    Get-ChildItem $TestDir -Filter "*.sql" |
    Where-Object { $_.Name -notlike "*.out.sql" } |
    Sort-Object Name |
    ForEach-Object {
        Format-OneFile -InputFile $_
    }

    Write-Host ""
    Write-Host "Done. Output folder:" $OutDir
    exit 0
}

if ($file) {
    $matches = Get-ChildItem $TestDir -Filter "*.sql" |
    Where-Object { $_.Name -notlike "*.out.sql" } |
    Where-Object {
        $_.Name -eq $file -or
        $_.BaseName -eq $file -or
        $_.Name -like "$file*"
    } |
    Sort-Object Name

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
Write-Host "  format --file 01"
Write-Host "  format --file 04_complicated_multiline_statements.sql"
Write-Host "  format --list"