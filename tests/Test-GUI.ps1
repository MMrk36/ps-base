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
    throw 'The Windows desktop launcher is missing.'
}

Write-Host '[PASS] Desktop interface PowerShell syntax is valid.'
Write-Host '[PASS] Windows desktop launcher exists.'
