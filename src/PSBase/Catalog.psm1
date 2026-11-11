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

        if ($null -ne $resource.PSObject.Properties['filePolicies']) {
            $policies = $resource.filePolicies
            if ($null -ne $policies.PSObject.Properties['default'] -and $policies.default -notin @('managed', 'preserve', 'replace')) {
                throw "Resource '$($resource.id)' has an invalid default file policy."
            }
            $policyRules = if ($null -ne $policies.PSObject.Properties['rules']) { @($policies.rules) } else { @() }
            foreach ($rule in $policyRules) {
                if ([string]::IsNullOrWhiteSpace([string]$rule.pattern) -or $rule.policy -notin @('managed', 'preserve', 'replace')) {
                    throw "Resource '$($resource.id)' has an invalid file policy rule."
                }
            }
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

            if ($null -ne $release.PSObject.Properties['apiVersion'] -and
                $release.apiVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
                throw "Release '$($resource.id)@$($release.version)' has an invalid PS Core API version."
            }

            if ($null -ne $release.PSObject.Properties['minimumArtifact'] -and
                $release.minimumArtifact -notmatch '^[0-9]+(?:\.[0-9]+){0,3}$') {
                throw "Release '$($resource.id)@$($release.version)' has an invalid minimum artifact version."
            }

            if ($null -ne $release.PSObject.Properties['psCoreApi']) {
                $range = $release.psCoreApi
                $hasMinimum = $null -ne $range.PSObject.Properties['minVersion']
                $hasMaximum = $null -ne $range.PSObject.Properties['maxVersion']
                if (-not $hasMinimum -and -not $hasMaximum) {
                    throw "Release '$($resource.id)@$($release.version)' has an empty PS Core API range."
                }
                if ($hasMinimum -and $range.minVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
                    throw "Release '$($resource.id)@$($release.version)' has an invalid minimum PS Core API version."
                }
                if ($hasMaximum -and $range.maxVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
                    throw "Release '$($resource.id)@$($release.version)' has an invalid maximum PS Core API version."
                }
                if ($hasMinimum -and $hasMaximum -and ([version]$range.minVersion -ge [version]$range.maxVersion)) {
                    throw "Release '$($resource.id)@$($release.version)' has an invalid PS Core API version range."
                }
            }
        }
    }

    if ($null -ne $catalog.PSObject.Properties['profiles']) {
        if ($catalog.profiles -isnot [System.Array]) {
            throw 'Catalog profiles must be an array.'
        }

        $profileIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($profile in $catalog.profiles) {
            foreach ($field in @('id', 'name', 'resources')) {
                if ($null -eq $profile.PSObject.Properties[$field]) {
                    throw "A catalog profile is missing required field '$field'."
                }
            }

            if ($profile.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or -not $profileIds.Add($profile.id)) {
                throw "Catalog contains an invalid or duplicate profile ID '$($profile.id)'."
            }
            if ($profile.resources -isnot [System.Array] -or $profile.resources.Count -eq 0) {
                throw "Profile '$($profile.id)' must contain at least one resource."
            }

            $profileResources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($item in $profile.resources) {
                if ([string]::IsNullOrWhiteSpace([string]$item.id) -or
                    [string]::IsNullOrWhiteSpace([string]$item.version) -or
                    $item.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
                    throw "Profile '$($profile.id)' contains a resource without a valid exact version pin."
                }
                if (-not $profileResources.Add([string]$item.id)) {
                    throw "Profile '$($profile.id)' contains duplicate resource '$($item.id)'."
                }

                $profileResource = @($catalog.resources | Where-Object { $_.id -ieq $item.id }) | Select-Object -First 1
                if ($null -eq $profileResource) {
                    throw "Profile '$($profile.id)' references unknown resource '$($item.id)'."
                }
                if (-not $profileResource.installable -or
                    @($profileResource.releases | Where-Object { $_.version -eq $item.version }).Count -eq 0) {
                    throw "Profile '$($profile.id)' references unpublished version '$($item.id)@$($item.version)'."
                }
            }
        }
    }

    return $catalog
}

function Get-PSBaseProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Id
    )

    if ($null -eq $Catalog.PSObject.Properties['profiles']) {
        throw 'The catalog does not define any installation profiles.'
    }

    $profile = @($Catalog.profiles | Where-Object { $_.id -ieq $Id }) | Select-Object -First 1
    if ($null -eq $profile) {
        throw "Profile '$Id' is not present in the catalog."
    }

    return $profile
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

Export-ModuleMember -Function Get-PSBaseCatalog, Get-PSBaseProfile, Get-PSBaseResource, Get-PSBaseRelease
