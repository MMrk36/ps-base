[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $root 'catalog/resources.json'
$gitModulesPath = Join-Path $root '.gitmodules'

function Write-Check {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Stop-Check {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    throw $Message
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-Check 'Git is required but was not found in PATH.'
}

if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    Stop-Check "Resource catalog not found: $catalogPath"
}

if (-not (Test-Path -LiteralPath $gitModulesPath -PathType Leaf)) {
    Stop-Check '.gitmodules was not found.'
}

try {
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
}
catch {
    Stop-Check "Resource catalog is not valid JSON: $($_.Exception.Message)"
}

if ($catalog.schemaVersion -ne 1) {
    Stop-Check "Unsupported catalog schema version: $($catalog.schemaVersion)"
}

if (-not ($catalog.resources -is [System.Array]) -or $catalog.resources.Count -eq 0) {
    Stop-Check 'The catalog must contain at least one resource.'
}

$ids = @{}
$paths = @{}

foreach ($resource in $catalog.resources) {
    foreach ($field in @('id', 'name', 'repository', 'submodulePath', 'status', 'installable', 'releases')) {
        if ($null -eq $resource.PSObject.Properties[$field]) {
            Stop-Check "Resource entry is missing required field '$field'."
        }
    }

    foreach ($field in @('id', 'name', 'repository', 'submodulePath', 'status')) {
        if ([string]::IsNullOrWhiteSpace([string]$resource.$field)) {
            Stop-Check "Resource field '$field' cannot be empty."
        }
    }

    if ($resource.installable -isnot [bool]) {
        Stop-Check "Resource '$($resource.id)' must use a boolean installable value."
    }

    if ($resource.releases -isnot [System.Array]) {
        Stop-Check "Resource '$($resource.id)' releases must be an array."
    }

    if ($ids.ContainsKey($resource.id)) {
        Stop-Check "Duplicate resource ID: $($resource.id)"
    }

    if ($paths.ContainsKey($resource.submodulePath)) {
        Stop-Check "Duplicate submodule path: $($resource.submodulePath)"
    }

    $ids[$resource.id] = $true
    $paths[$resource.submodulePath] = $true

    if ($resource.installable -and $resource.releases.Count -eq 0) {
        Stop-Check "Resource '$($resource.id)' is marked installable but has no release entries."
    }

    if ($resource.submodulePath -match '(^/|\\|(^|/)\.\.(/|$))') {
        Stop-Check "Unsafe submodule path for '$($resource.id)': $($resource.submodulePath)"
    }
}

$submoduleOutput = & git -C $root config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>$null
if ($LASTEXITCODE -ne 0) {
    Stop-Check 'Could not read submodule paths from .gitmodules.'
}

$registeredPaths = @()
foreach ($line in $submoduleOutput) {
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2) {
        $registeredPaths += $parts[1]
    }
}

foreach ($resource in $catalog.resources) {
    if ($resource.submodulePath -notin $registeredPaths) {
        Stop-Check "Catalog resource '$($resource.id)' points to '$($resource.submodulePath)', which is not registered in .gitmodules."
    }
}

$catalogSubmodules = @($catalog.resources | ForEach-Object { $_.submodulePath })
$unlistedSubmodules = @($registeredPaths | Where-Object { $_ -notin $catalogSubmodules })
if ($unlistedSubmodules.Count -gt 0) {
    Write-Warning "Submodules not represented in the resource catalog: $($unlistedSubmodules -join ', ')"
}

Write-Check "Catalog JSON and schema version $($catalog.schemaVersion) are valid."
Write-Check "$($catalog.resources.Count) catalog resources have unique IDs and paths."
Write-Check "All catalog submodule paths exist in .gitmodules."

$submoduleStatus = & git -C $root submodule status --recursive
if ($LASTEXITCODE -ne 0) {
    Stop-Check 'Git could not read submodule status.'
}

foreach ($line in $submoduleStatus) {
    if ($line -match '^[-+U]') {
        Write-Warning "Submodule needs attention: $line"
    }
}

Write-Host 'Repository validation completed.' -ForegroundColor Cyan
