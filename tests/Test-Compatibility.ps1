[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/Compatibility.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/DependencyResolver.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/Catalog.psm1') -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-compatibility-tests-" + [guid]::NewGuid().ToString('N'))
$server = Join-Path $testRoot 'server'
$resources = Join-Path $server 'resources'
New-Item -ItemType Directory -Path $resources -Force | Out-Null

function New-CompatibilityRelease {
    param(
        [string]$Version,
        [string]$ApiVersion,
        $PsCoreApi,
        [string]$MinimumArtifact
    )

    $release = @{
        version = $Version
        tag = "v$Version"
        asset = 'resource.zip'
        url = 'https://example.com/resource.zip'
        sha256 = 'a' * 64
    }
    if ($ApiVersion) { $release.apiVersion = $ApiVersion }
    if ($null -ne $PsCoreApi) { $release.psCoreApi = $PsCoreApi }
    if ($MinimumArtifact) { $release.minimumArtifact = $MinimumArtifact }
    return $release
}

try {
    $catalogData = @{
        schemaVersion = 1
        catalogVersion = '1.0.0'
        resources = @(
            @{
                id = 'ps-core'; name = 'PS Core'; repository = 'Pedro/ps-core'; submodulePath = 'ps-core'
                status = 'stable'; installable = $true
                releases = @(
                    (New-CompatibilityRelease '1.0.0' '1.5.0' $null $null),
                    (New-CompatibilityRelease '2.0.0' '2.0.0' $null $null)
                )
            },
            @{
                id = 'ps-addon'; name = 'PS Addon'; repository = 'Pedro/ps-addon'; submodulePath = 'ps-addon'
                status = 'stable'; installable = $true
                releases = @(
                    (New-CompatibilityRelease '1.0.0' $null @{ minVersion = '1.0.0'; maxVersion = '2.0.0' } '1400')
                )
            }
        )
        profiles = @()
    }

    $catalogPath = Join-Path $testRoot 'catalog.json'
    $catalogData | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $catalogPath
    $catalog = Get-PSBaseCatalog -Path $catalogPath

    $lockDirectory = Join-Path $server '.ps-base'
    New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
    $lock = @{
        schemaVersion = 1
        installedResources = @{
            'ps-core' = @{ version = '1.0.0'; apiVersion = '1.5.0'; installedPath = 'resources/ps-core' }
            'ps-addon' = @{ version = '1.0.0'; installedPath = 'resources/ps-addon' }
        }
    }
    $lock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $lockDirectory 'lock.json')

    $coreTwoPlan = @(Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds @('ps-core') -Version '2.0.0')
    $blocked = $false
    try {
        Test-PSBaseCompatibility -Catalog $catalog -Plan $coreTwoPlan -ServerRoot $server | Out-Null
    }
    catch {
        $blocked = $_.Exception.Message -match 'older than 2.0.0'
    }
    if (-not $blocked) { throw 'A PS Core upgrade that breaks an installed add-on was not blocked.' }

    $coreOnePlan = @(Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds @('ps-core') -Version '1.0.0')
    Test-PSBaseCompatibility -Catalog $catalog -Plan $coreOnePlan -ServerRoot $server | Out-Null

    $addonPlan = @(Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds @('ps-addon') -Version '1.0.0')
    $artifactBlocked = $false
    try {
        Test-PSBaseCompatibility -Catalog $catalog -Plan $addonPlan -ServerRoot $server -ArtifactVersion '1399' | Out-Null
    }
    catch {
        $artifactBlocked = $_.Exception.Message -match 'requires server artifact 1400'
    }
    if (-not $artifactBlocked) { throw 'An insufficient server artifact version was not blocked.' }

    Test-PSBaseCompatibility -Catalog $catalog -Plan $addonPlan -ServerRoot $server -ArtifactVersion '1400' | Out-Null

    Write-Host '[PASS] PS Core API incompatibilities block unsafe core upgrades.'
    Write-Host '[PASS] Installed dependent resource compatibility is checked from release metadata.'
    Write-Host '[PASS] Minimum server artifact requirements are enforced.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
