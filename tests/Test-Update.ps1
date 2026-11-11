[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/Update.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/FileManifest.psm1') -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-update-tests-" + [guid]::NewGuid().ToString('N'))
$server = Join-Path $testRoot 'server'
$resources = Join-Path $server 'resources'
$installed = Join-Path $resources 'ps-test-resource'
$oldRelease = Join-Path $testRoot 'old-release'
$newRelease = Join-Path $testRoot 'new-release'
New-Item -ItemType Directory -Path $installed -Force | Out-Null
New-Item -ItemType Directory -Path $oldRelease -Force | Out-Null
New-Item -ItemType Directory -Path $newRelease -Force | Out-Null

try {
    foreach ($path in @($installed, $oldRelease)) {
        Set-Content -LiteralPath (Join-Path $path 'fxmanifest.lua') -Value 'manifest v1' -NoNewline
        Set-Content -LiteralPath (Join-Path $path 'unchanged.lua') -Value 'old upstream' -NoNewline
        Set-Content -LiteralPath (Join-Path $path 'modified.lua') -Value 'original upstream' -NoNewline
        Set-Content -LiteralPath (Join-Path $path 'removed.lua') -Value 'obsolete' -NoNewline
        Set-Content -LiteralPath (Join-Path $path 'config.lua') -Value 'default config' -NoNewline
    }

    Set-Content -LiteralPath (Join-Path $installed 'modified.lua') -Value 'user modification' -NoNewline
    Set-Content -LiteralPath (Join-Path $installed 'user-file.txt') -Value 'user-created' -NoNewline

    Set-Content -LiteralPath (Join-Path $newRelease 'fxmanifest.lua') -Value 'manifest v2' -NoNewline
    Set-Content -LiteralPath (Join-Path $newRelease 'unchanged.lua') -Value 'new upstream' -NoNewline
    Set-Content -LiteralPath (Join-Path $newRelease 'modified.lua') -Value 'new upstream code' -NoNewline
    Set-Content -LiteralPath (Join-Path $newRelease 'config.lua') -Value 'new default config' -NoNewline
    Set-Content -LiteralPath (Join-Path $newRelease 'added.lua') -Value 'new file' -NoNewline

    $oldManifest = Get-PSBaseFileManifest -Root $oldRelease
    $oldManifest.files['config.lua'].policy = 'preserve'
    $manifestPath = Join-Path $server '.ps-base/manifests/ps-test-resource.json'
    Save-PSBaseFileManifest -Manifest $oldManifest -Path $manifestPath

    $newManifest = Get-PSBaseFileManifest -Root $newRelease
    $newManifest.files['config.lua'].policy = 'preserve'
    $planItem = [pscustomobject]@{
        Id = 'ps-test-resource'
        Version = '2.0.0'
        Tag = 'v2.0.0'
        Sha256 = 'b' * 64
        Repository = 'MMrk36/ps-test-resource'
    }

    $result = Invoke-PSBaseResourceUpdate -PlanItem $planItem -StagedPath $newRelease -ServerRoot $server -InstalledPath $installed -Confirm:$false

    if ((Get-Content (Join-Path $installed 'unchanged.lua') -Raw) -ne 'new upstream') { throw 'Managed file was not updated.' }
    if ((Get-Content (Join-Path $installed 'modified.lua') -Raw) -ne 'user modification') { throw 'Local modification was overwritten.' }
    if ((Get-Content (Join-Path $installed 'config.lua') -Raw) -ne 'default config') { throw 'Preserve policy file was overwritten.' }
    if (Test-Path (Join-Path $installed 'removed.lua')) { throw 'Unmodified upstream-deleted file was not removed.' }
    if ((Get-Content (Join-Path $installed 'user-file.txt') -Raw) -ne 'user-created') { throw 'Untracked user file was not preserved.' }
    if ((Get-Content (Join-Path $installed 'added.lua') -Raw) -ne 'new file') { throw 'New upstream file was not installed.' }
    if (-not (Test-Path -LiteralPath $result.BackupPath -PathType Container)) { throw 'Update backup was not retained.' }

    $lock = Get-Content (Join-Path $server '.ps-base/lock.json') -Raw | ConvertFrom-Json
    if ($lock.installedResources.'ps-test-resource'.version -ne '2.0.0') { throw 'Updated version was not recorded.' }

    Write-Host '[PASS] Update applies safe managed file changes.'
    Write-Host '[PASS] Local modifications, preserve-policy and untracked files remain untouched.'
    Write-Host '[PASS] Update backup, manifest and lockfile are recorded.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
