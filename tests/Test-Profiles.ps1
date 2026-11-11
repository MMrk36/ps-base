[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/DependencyResolver.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/Catalog.psm1') -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-profile-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

function New-TestRelease {
    param([string]$Version, [string[]]$Dependencies = @())
    return @{
        version = $Version
        tag = "v$Version"
        asset = 'resource.zip'
        url = 'https://example.com/resource.zip'
        sha256 = 'a' * 64
        dependencies = $Dependencies
    }
}

try {
    $catalogData = @{
        schemaVersion = 1
        catalogVersion = '1.0.0'
        resources = @(
            @{
                id = 'ps-base-lib'; name = 'Base Library'; repository = 'Pedro/base-lib'; submodulePath = 'ps-base-lib'
                status = 'stable'; installable = $true; releases = @((New-TestRelease '1.0.0'), (New-TestRelease '2.0.0'))
            },
            @{
                id = 'ps-widget'; name = 'Widget'; repository = 'Pedro/widget'; submodulePath = 'ps-widget'
                status = 'stable'; installable = $true; releases = @((New-TestRelease '1.0.0' @('ps-base-lib')))
            },
            @{
                id = 'ps-tool'; name = 'Tool'; repository = 'Pedro/tool'; submodulePath = 'ps-tool'
                status = 'stable'; installable = $true; releases = @((New-TestRelease '1.0.0' @('ps-base-lib@1.0.0')))
            }
        )
        profiles = @(
            @{
                id = 'standard'; name = 'Standard'; description = 'Pinned base installation'
                resources = @(
                    @{ id = 'ps-widget'; version = '1.0.0' },
                    @{ id = 'ps-base-lib'; version = '1.0.0' }
                )
            },
            @{
                id = 'conflict'; name = 'Conflict'; description = 'Intentional version conflict'
                resources = @(
                    @{ id = 'ps-tool'; version = '1.0.0' },
                    @{ id = 'ps-base-lib'; version = '2.0.0' }
                )
            }
        )
    }

    $catalogPath = Join-Path $testRoot 'catalog.json'
    $catalogData | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $catalogPath
    $catalog = Get-PSBaseCatalog -Path $catalogPath

    $plan = @(Resolve-PSBaseProfilePlan -Catalog $catalog -ProfileId 'standard')
    if ($plan.Count -ne 2) { throw 'Profile did not resolve to the expected resource count.' }
    if ($plan[0].Id -ne 'ps-base-lib' -or $plan[0].Version -ne '1.0.0') { throw 'Profile dependency was not pinned and ordered first.' }
    if ($plan[1].Id -ne 'ps-widget') { throw 'Profile dependent resource was not ordered after its dependency.' }

    $conflictDetected = $false
    try {
        Resolve-PSBaseProfilePlan -Catalog $catalog -ProfileId 'conflict' | Out-Null
    }
    catch {
        $conflictDetected = $_.Exception.Message -match 'Conflicting versions'
    }
    if (-not $conflictDetected) { throw 'Profile resolver did not reject conflicting exact dependency pins.' }

    Write-Host '[PASS] Profiles validate exact published versions.'
    Write-Host '[PASS] Profile resolution applies pinned versions to unpinned dependencies.'
    Write-Host '[PASS] Conflicting profile and dependency pins are rejected.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
