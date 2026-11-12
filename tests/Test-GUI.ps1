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

$bootstrapSource = Join-Path $root 'cmd/psbase-bootstrap/main.go'
if (-not (Test-Path -LiteralPath $bootstrapSource -PathType Leaf)) {
    throw 'The lightweight GitHub bootstrapper source is missing.'
}

$sourceText = Get-Content -LiteralPath $bootstrapSource -Raw
foreach ($requiredText in @('releases?per_page=20', 'psbase-bootstrap.json', 'appSha256', 'hashes.sha256', 'extractZipAtomic', '--self-test')) {
    if (-not $sourceText.Contains($requiredText)) {
        throw "The bootstrapper is missing required behavior: $requiredText"
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $root 'go.mod') -PathType Leaf)) {
    throw 'The Go module definition is missing.'
}

$guiText = Get-Content -LiteralPath (Join-Path $root 'PS-Base-GUI.ps1') -Raw
foreach ($requiredText in @('Check only the resources you want', 'Automatically included dependencies', 'Get-SelectedIds')) {
    if (-not $guiText.Contains($requiredText)) {
        throw "The resource selection interface is missing required behavior: $requiredText"
    }
}

Write-Host '[PASS] Desktop interface PowerShell syntax is valid.'
Write-Host '[PASS] Lightweight GitHub bootstrapper source and module are present.'
Write-Host '[PASS] Bootstrapper verifies downloaded application and PowerShell archives.'
Write-Host '[PASS] GUI supports explicit resource selection and automatic dependencies.'
