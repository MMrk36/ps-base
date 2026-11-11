[CmdletBinding(SupportsShouldProcess)]
param([string]$CatalogPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/CatalogSync.psm1') -Force

$path = if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
    Join-Path $root 'catalog/resources.json'
}
else {
    [System.IO.Path]::GetFullPath($CatalogPath)
}

$result = Update-PSBaseCatalogFromGitHub -CatalogPath $path -WhatIf:$WhatIfPreference
Write-Host "Catalog sync complete. Resources: $($result.Resources); installable: $($result.Installable); published releases: $($result.Releases)." -ForegroundColor Green
