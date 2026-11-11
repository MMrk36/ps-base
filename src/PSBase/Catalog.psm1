Set-StrictMode -Version Latest

function Get-PSBaseCatalog {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'catalog/resources.json')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Resource catalog not found: $Path"
    }

    try {
        $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not parse resource catalog '$Path': $($_.Exception.Message)"
    }

    if ($catalog.schemaVersion -ne 1) {
        throw "Unsupported catalog schema version '$($catalog.schemaVersion)'."
    }

    if ($catalog.resources -isnot [System.Array]) {
        throw 'Catalog resources must be an array.'
    }

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($resource in $catalog.resources) {
        foreach ($field in @('id', 'name', 'repository', 'status', 'installable', 'releases')) {
            if ($null -eq $resource.PSObject.Properties[$field]) {
                throw "A catalog resource is missing required field '$field'."
            }
        }

        if ([string]::IsNullOrWhiteSpace($resource.id) -or -not $ids.Add($resource.id)) {
            throw "Catalog contains an empty or duplicate resource ID '$($resource.id)'."
        }

        if ($resource.installable -isnot [bool]) {
            throw "Resource '$($resource.id)' has an invalid installable value."
        }

        if ($resource.releases -isnot [System.Array]) {
            throw "Resource '$($resource.id)' releases must be an array."
        }

        if ($resource.installable -and $resource.releases.Count -eq 0) {
            throw "Resource '$($resource.id)' is installable but has no releases."
        }

        foreach ($release in $resource.releases) {
            foreach ($field in @('version', 'tag', 'asset', 'url', 'sha256')) {
                if ($null -eq $release.PSObject.Properties[$field] -or
                    [string]::IsNullOrWhiteSpace([string]$release.$field)) {
                    throw "Release for '$($resource.id)' is missing '$field'."
                }
            }

            if ($release.url -notmatch '^https://' -or $release.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                throw "Release '$($resource.id)@$($release.version)' has an invalid URL or SHA-256 checksum."
            }
        }
    }

    return $catalog
}

function Get-PSBaseResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Id
    )

    $resource = @($Catalog.resources | Where-Object { $_.id -ieq $Id }) | Select-Object -First 1
    if ($null -eq $resource) {
        throw "Resource '$Id' is not present in the catalog."
    }

    return $resource
}

function Get-PSBaseRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Resource,
        [string]$Version
    )

    if (-not $Resource.installable) {
        throw "Resource '$($Resource.id)' is not installable yet. It is currently marked '$($Resource.status)'."
    }

    $releases = @($Resource.releases)

    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $release = $releases | Where-Object { $_.version -eq $Version } | Select-Object -First 1
        if ($null -eq $release) {
            throw "Version '$Version' is not published for '$($Resource.id)'."
        }

        return $release
    }

    $stable = foreach ($release in $releases) {
        if ($release.version -match '^(\d+)\.(\d+)\.(\d+)$') {
            [pscustomobject]@{
                Release = $release
                Parsed = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
            }
        }
    }

    $selected = $stable | Sort-Object -Property Parsed -Descending | Select-Object -First 1
    if ($null -eq $selected) {
        throw "No stable semantic version is available for '$($Resource.id)'. Specify a published version explicitly."
    }

    return $selected.Release
}

Export-ModuleMember -Function Get-PSBaseCatalog, Get-PSBaseResource, Get-PSBaseRelease
