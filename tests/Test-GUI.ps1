[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'PS-Base-GUI.ps1'),
    [ref]$tokens,
    [ref]$errors
) | Out-Null

if ($errors.Count -gt 0) {
    $details = $errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" }
    throw "Desktop interface has PowerShell syntax errors: $($details -join '; ')"
}

if (-not (Test-Path -LiteralPath (Join-Path $root 'Start-PSBase.cmd') -PathType Leaf)) {
    throw 'The Windows development launcher is missing.'
}

$launcherProject = Join-Path $root 'src/PSBase.Launcher/PSBase.Launcher.csproj'
$launcherSource = Join-Path $root 'src/PSBase.Launcher/Program.cs'
if (-not (Test-Path -LiteralPath $launcherProject -PathType Leaf) -or
    -not (Test-Path -LiteralPath $launcherSource -PathType Leaf)) {
    throw 'The single-file Windows EXE launcher project is incomplete.'
}

[xml]$project = Get-Content -LiteralPath $launcherProject -Raw
if ($project.Project.PropertyGroup.TargetFramework -ne 'net10.0-windows' -or
    $project.Project.PropertyGroup.PublishSingleFile -ne 'true' -or
    $project.Project.PropertyGroup.SelfContained -ne 'true') {
    throw 'The launcher must publish as a self-contained single-file Windows application.'
}

$sourceText = Get-Content -LiteralPath $launcherSource -Raw
foreach ($requiredText in @('PSBase.Launcher.payload.zip', 'EnsurePayloadExtracted', 'runtime/pwsh.exe', '--self-test')) {
    if (-not $sourceText.Contains($requiredText)) {
        throw "The EXE launcher is missing required behavior: $requiredText"
    }
}

Write-Host '[PASS] Desktop interface PowerShell syntax is valid.'
Write-Host '[PASS] Windows development launcher exists.'
Write-Host '[PASS] Single-file EXE launcher project is configured.'
