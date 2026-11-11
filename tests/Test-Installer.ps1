[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/Installer.psm1') -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-install-tests-" + [guid]::NewGuid().ToString('N'))
$serverRoot = Join-Path $testRoot 'server'
$resourcesPath = Join-Path $serverRoot 'resources'
$targetPath = Join-Path $resourcesPath 'ps-test-resource'
$stagedPath = Join-Path $testRoot 'staged'

New-Item -ItemType Directory -Path $resourcesPath -Force | Out-Null
New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
New-Item -ItemType Directory -Path $stagedPath -Force | Out-Null

try {
    Set-Content -LiteralPath (Join-Path $targetPath 'fxmanifest.lua') -Value 'old manifest'
    Set-Content -LiteralPath (Join-Path $targetPath 'config.lua') -Value 'user setting'
    Set-Content -LiteralPath (Join-Path $targetPath 'old-file.lua') -Value 'old file'

    Set-Content -LiteralPath (Join-Path $stagedPath 'fxmanifest.lua') -Value 'new manifest'
    Set-Content -LiteralPath (Join-Path $stagedPath 'config.lua') -Value 'default setting'
    Set-Content -LiteralPath (Join-Path $stagedPath 'new-file.lua') -Value 'new file'

    $planItem = [pscustomobject]@{
        Id = 'ps-test-resource'
        Version = '1.2.3'
        Tag = 'v1.2.3'
        Sha256 = 'a' * 64
        Repository = 'MMrk36/ps-test-resource'
    }

    $result = Install-PSBaseResource -PlanItem $planItem -StagedPath $stagedPath -ServerRoot $serverRoot -ResourcesPath $resourcesPath -PreservePaths @('config.lua') -Confirm:$false

    if ((Get-Content -LiteralPath (Join-Path $targetPath 'config.lua') -Raw).Trim() -ne 'user setting') {
        throw 'Existing user configuration was not preserved.'
    }

    if (-not (Test-Path -LiteralPath (Join-Path $targetPath 'new-file.lua'))) {
        throw 'The new resource file was not installed.'
    }

    if (Test-Path -LiteralPath (Join-Path $targetPath 'old-file.lua')) {
        throw 'An obsolete resource file was not replaced.'
    }

    if (-not (Test-Path -LiteralPath $result.BackupPath -PathType Container)) {
        throw 'The previous resource backup was not created.'
    }

    $lockPath = Join-Path $serverRoot '.ps-base/lock.json'
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    if ($lock.installedResources.'ps-test-resource'.version -ne '1.2.3') {
        throw 'Installed resource version was not recorded in the lockfile.'
    }

    $manifestPath = Join-Path $serverRoot '.ps-base/manifests/ps-test-resource.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The installed release file manifest was not recorded.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.files.'config.lua'.sha256 -ne (Get-FileHash -LiteralPath (Join-Path $stagedPath 'config.lua') -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'The manifest did not retain the original upstream configuration baseline.'
    }

    Write-Host '[PASS] Staged installation replaces resource files.'
    Write-Host '[PASS] Existing configuration is preserved.'
    Write-Host '[PASS] Previous resource backup, lockfile and upstream file manifest are created.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
