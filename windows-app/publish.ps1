param(
    [string]$Runtime = 'win-x64',
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'

$project = Join-Path $PSScriptRoot 'SqlFormatterApp\SqlFormatterApp.csproj'
$outDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\SqlFormatterApp'

Write-Host "Publishing SQL Formatter app..."
Write-Host "Project: $project"
Write-Host "Runtime: $Runtime"
Write-Host "Output:  $outDir"

dotnet publish $project `
    -c $Configuration `
    -r $Runtime `
    --self-contained true `
    -p:PublishSingleFile=false `
    -o $outDir

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$exe = Join-Path $outDir 'SqlFormatterApp.exe'
if (-not (Test-Path $exe)) {
    throw "Publish completed but $exe was not found."
}

Write-Host ""
Write-Host "Done. Run:"
Write-Host $exe
