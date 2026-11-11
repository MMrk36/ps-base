[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/DependencyResolver.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/Catalog.psm1') -Force

$catalog = Get-PSBaseCatalog
if ($catalog.resources.Count -ne 6) {
    throw "Expected six catalog resources, found $($catalog.resources.Count)."
}

foreach ($resource in $catalog.resources) {
    if ($resource.installable -and $resource.releases.Count -eq 0) {
        throw "Installable resource '$($resource.id)' has no published release."
    }

    foreach ($release in $resource.releases) {
        if ([string]::IsNullOrWhiteSpace([string]$release.version) -or
            [string]::IsNullOrWhiteSpace([string]$release.tag) -or
            [string]::IsNullOrWhiteSpace([string]$release.asset) -or
            $release.url -notmatch '^https://' -or
            $release.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Resource '$($resource.id)' contains an incomplete or invalid release entry."
        }
    }
}

$core = Get-PSBaseResource -Catalog $catalog -Id 'ps-core'
$blocked = $false
try {
    Get-PSBaseRelease -Resource $core | Out-Null
}
catch {
    $blocked = $_.Exception.Message -match 'No stable semantic version'
}

if (-not $blocked) {
    throw 'A preview release was incorrectly selected as the default stable release.'
}

$corePlan = @(Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds @('ps-core') -Version '0.1.0')
if ($corePlan.Count -ne 1 -or $corePlan[0].Id -ne 'ps-core' -or $corePlan[0].Version -ne '0.1.0') {
    throw 'An explicitly selected preview release could not be installed.'
}

$databasePlan = @(Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds @('ps-database') -Version '0.1.0')
if ($databasePlan.Count -ne 2 -or
    $databasePlan[0].Id -ne 'ps-core' -or
    $databasePlan[0].Version -ne '0.1.0' -or
    $databasePlan[1].Id -ne 'ps-database') {
    throw 'Preview dependency pins did not resolve in dependency-first order.'
}

$unavailable = [pscustomobject]@{
    id = 'ps-unavailable'
    name = 'Unavailable Resource'
    repository = 'MMrk36/ps-unavailable'
    status = 'development'
    installable = $false
    releases = @()
}
$blocked = $false
try {
    Get-PSBaseRelease -Resource $unavailable | Out-Null
}
catch {
    $blocked = $_.Exception.Message -match 'not installable'
}

if (-not $blocked) {
    throw 'The resolver did not reject a resource marked as non-installable.'
}

$hash = 'a' * 64
$fixture = [pscustomobject]@{
    schemaVersion = 1
    resources = @(
        [pscustomobject]@{
            id = 'ps-test-base'
            name = 'Test Base'
            repository = 'MMrk36/ps-test-base'
            status = 'stable'
            installable = $true
            releases = @(
                [pscustomobject]@{
                    version = '1.0.0'
                    tag = 'v1.0.0'
                    asset = 'ps-test-base.zip'
                    url = 'https://example.com/ps-test-base.zip'
                    sha256 = $hash
                }
            )
        },
        [pscustomobject]@{
            id = 'ps-test-addon'
            name = 'Test Addon'
            repository = 'MMrk36/ps-test-addon'
            status = 'stable'
            installable = $true
            releases = @(
                [pscustomobject]@{
                    version = '1.2.0'
                    tag = 'v1.2.0'
                    asset = 'ps-test-addon.zip'
                    url = 'https://example.com/ps-test-addon.zip'
                    sha256 = $hash
                    dependencies = @('ps-test-base@1.0.0')
                }
            )
        }
    )
}

$plan = @(Resolve-PSBaseInstallPlan -Catalog $fixture -ResourceIds @('ps-test-addon'))
if ($plan.Count -ne 2 -or $plan[0].Id -ne 'ps-test-base' -or $plan[1].Id -ne 'ps-test-addon') {
    throw 'Dependency resolution did not return dependencies before their dependent resource.'
}

$cycle = [pscustomobject]@{
    schemaVersion = 1
    resources = @(
        [pscustomobject]@{
            id = 'cycle-a'
            name = 'Cycle A'
            repository = 'MMrk36/cycle-a'
            status = 'stable'
            installable = $true
            releases = @(
                [pscustomobject]@{
                    version = '1.0.0'
                    tag = 'v1.0.0'
                    asset = 'cycle-a.zip'
                    url = 'https://example.com/cycle-a.zip'
                    sha256 = $hash
                    dependencies = @('cycle-b')
                }
            )
        },
        [pscustomobject]@{
            id = 'cycle-b'
            name = 'Cycle B'
            repository = 'MMrk36/cycle-b'
            status = 'stable'
            installable = $true
            releases = @(
                [pscustomobject]@{
                    version = '1.0.0'
                    tag = 'v1.0.0'
                    asset = 'cycle-b.zip'
                    url = 'https://example.com/cycle-b.zip'
                    sha256 = $hash
                    dependencies = @('cycle-a')
                }
            )
        }
    )
}

$cycleBlocked = $false
try {
    Resolve-PSBaseInstallPlan -Catalog $cycle -ResourceIds @('cycle-a')
}
catch {
    $cycleBlocked = $_.Exception.Message -match 'cycle'
}

if (-not $cycleBlocked) {
    throw 'The resolver did not detect a dependency cycle.'
}

Write-Host '[PASS] Installable preview releases are validated and remain explicitly selectable.'
Write-Host '[PASS] Preview dependencies resolve through exact version pins.'
Write-Host '[PASS] Non-installable resources remain blocked.'
Write-Host '[PASS] Dependency-first ordering and exact version pins.'
Write-Host '[PASS] Dependency cycle detection.'
