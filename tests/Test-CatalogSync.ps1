[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PSBase/CatalogSync.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PSBase/Catalog.psm1') -Force

$metadata = [pscustomobject]@{
    schemaVersion = 1
    id = 'ps-core'
    version = '0.1.0'
    status = 'preview'
    dependencies = @()
    apiVersion = '1.0.0'
    filePolicies = @{ default = 'managed'; rules = @() }
}
$release = [pscustomobject]@{
    tag_name = 'v0.1.0'
    prerelease = $true
    assets = @(
        [pscustomobject]@{
            name = 'ps-core-v0.1.0.zip'
            url = 'https://api.github.com/repos/MMrk36/ps-core/releases/assets/12'
        }
    )
}
$checksum = ('a' * 64) + '  ps-core-v0.1.0.zip'

$entry = ConvertTo-PSBaseReleaseEntry -GitHubRelease $release -Metadata $metadata -ChecksumText $checksum
if ($entry.version -ne '0.1.0' -or $entry.tag -ne 'v0.1.0' -or $entry.sha256 -ne ('a' * 64)) {
    throw 'Release catalog entry was not created correctly.'
}
if ($entry.apiVersion -ne '1.0.0' -or $entry.dependencies.Count -ne 0 -or $entry.status -ne 'preview') {
    throw 'Release compatibility or dependency metadata was not retained.'
}

$catalogRelease = $entry | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$resource = [pscustomobject]@{ id = 'ps-core'; installable = $true; status = 'preview'; releases = @($catalogRelease) }
$failed = $false
try {
    Get-PSBaseRelease -Resource $resource | Out-Null
}
catch {
    $failed = $_.Exception.Message -match 'No stable semantic version'
}
if (-not $failed) { throw 'A preview release was incorrectly selected as the default stable release.' }
if ((Get-PSBaseRelease -Resource $resource -Version '0.1.0').version -ne '0.1.0') { throw 'An explicitly selected preview release was not available.' }

$failed = $false
try {
    ConvertTo-PSBaseReleaseEntry -GitHubRelease $release -Metadata $metadata -ChecksumText 'not-a-checksum' | Out-Null
}
catch {
    $failed = $_.Exception.Message -match 'SHA-256'
}
if (-not $failed) { throw 'An invalid checksum sidecar was accepted.' }

$wrongMetadata = $metadata | Select-Object *
$wrongMetadata.version = '0.2.0'
$failed = $false
try {
    ConvertTo-PSBaseReleaseEntry -GitHubRelease $release -Metadata $wrongMetadata -ChecksumText $checksum | Out-Null
}
catch {
    $failed = $_.Exception.Message -match 'mismatched'
}
if (-not $failed) { throw 'A release tag and metadata version mismatch was accepted.' }

$unversionedEntry = [pscustomobject]@{ dependencies = @('ps-core') }
$existingEntry = [pscustomobject]@{ dependencies = @('ps-core@0.1.0') }
$preservedEntry = Preserve-PSBaseDependencyPins -ReleaseEntry $unversionedEntry -ExistingRelease $existingEntry
if ($preservedEntry.dependencies.Count -ne 1 -or $preservedEntry.dependencies[0] -ne 'ps-core@0.1.0') {
    throw 'Catalog synchronization did not preserve an existing exact dependency pin for an unchanged release.'
}

$explicitEntry = [pscustomobject]@{ dependencies = @('ps-core@0.2.0') }
$explicitResult = Preserve-PSBaseDependencyPins -ReleaseEntry $explicitEntry -ExistingRelease $existingEntry
if ($explicitResult.dependencies[0] -ne 'ps-core@0.2.0') {
    throw 'An explicit dependency version from release metadata was incorrectly replaced.'
}

$changedEntry = [pscustomobject]@{ dependencies = @('ps-database') }
$changedResult = Preserve-PSBaseDependencyPins -ReleaseEntry $changedEntry -ExistingRelease $existingEntry
if ($changedResult.dependencies[0] -ne 'ps-database') {
    throw 'An existing dependency pin was incorrectly preserved after the dependency identity changed.'
}

Write-Host '[PASS] GitHub release metadata is converted into exact catalog entries.'
Write-Host '[PASS] Preview releases require explicit version selection and remain installable by exact version.'
Write-Host '[PASS] Invalid checksum sidecars are rejected.'
Write-Host '[PASS] Tag and release metadata version mismatches are rejected.'
Write-Host '[PASS] Catalog synchronization preserves exact pins for unchanged release dependencies.'
