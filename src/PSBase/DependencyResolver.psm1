Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Catalog.psm1') -Force

function Resolve-PSBaseInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string[]]$ResourceIds,
        [string]$Version,
        [System.Collections.IDictionary]$VersionOverrides
    )

    $ordered = [System.Collections.Generic.List[object]]::new()
    $selectedVersions = @{}
    $visiting = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Add-ResourceToPlan {
        param(
            [string]$Id,
            [string]$RequestedVersion
        )

        $resource = Get-PSBaseResource -Catalog $Catalog -Id $Id
        if ([string]::IsNullOrWhiteSpace($RequestedVersion) -and $null -ne $VersionOverrides -and $VersionOverrides.Contains($Id)) {
            $RequestedVersion = [string]$VersionOverrides[$Id]
        }
        $release = Get-PSBaseRelease -Resource $resource -Version $RequestedVersion
        $key = $resource.id.ToLowerInvariant()

        if ($visiting.Contains($key)) {
            throw "Dependency cycle detected at '$($resource.id)'."
        }

        if ($visited.Contains($key)) {
            if ($selectedVersions[$key] -ne $release.version) {
                throw "Conflicting versions requested for '$($resource.id)': '$($selectedVersions[$key])' and '$($release.version)'."
            }
            return
        }

        [void]$visiting.Add($key)

        $dependencies = if ($null -ne $release.PSObject.Properties['dependencies']) { @($release.dependencies) } else { @() }
        foreach ($dependency in $dependencies) {
            if ([string]::IsNullOrWhiteSpace([string]$dependency)) {
                throw "Resource '$($resource.id)' contains an empty dependency entry."
            }

            $parts = $dependency -split '@', 2
            $dependencyId = $parts[0]
            $dependencyVersion = if ($parts.Count -eq 2) { $parts[1] } else { $null }

            if ([string]::IsNullOrWhiteSpace($dependencyId) -or
                ($parts.Count -eq 2 -and [string]::IsNullOrWhiteSpace($dependencyVersion))) {
                throw "Resource '$($resource.id)' has an invalid dependency '$dependency'. Use resource-id or resource-id@exact-version."
            }

            Add-ResourceToPlan -Id $dependencyId -RequestedVersion $dependencyVersion
        }

        [void]$visiting.Remove($key)
        [void]$visited.Add($key)
        $selectedVersions[$key] = $release.version

        $ordered.Add([pscustomobject]@{
            Id = $resource.id
            Name = $resource.name
            Version = $release.version
            Tag = $release.tag
            Asset = $release.asset
            Url = $release.url
            Sha256 = $release.sha256.ToLowerInvariant()
            Repository = $resource.repository
        })
    }

    foreach ($id in $ResourceIds) {
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'Resource IDs cannot be empty.'
        }

        Add-ResourceToPlan -Id $id -RequestedVersion $Version
    }

    return $ordered.ToArray()
}


function Resolve-PSBaseProfilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$ProfileId
    )

    $profile = Get-PSBaseProfile -Catalog $Catalog -Id $ProfileId
    $overrides = @{}
    $resourceIds = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $profile.resources) {
        if ([string]::IsNullOrWhiteSpace([string]$item.id) -or
            [string]::IsNullOrWhiteSpace([string]$item.version)) {
            throw "Profile '$ProfileId' contains a resource without an exact version pin."
        }

        if ($overrides.ContainsKey([string]$item.id) -and $overrides[[string]$item.id] -ne [string]$item.version) {
            throw "Profile '$ProfileId' pins resource '$($item.id)' to conflicting versions."
        }

        $overrides[[string]$item.id] = [string]$item.version
        if (-not $resourceIds.Contains([string]$item.id)) {
            $resourceIds.Add([string]$item.id)
        }
    }

    if ($resourceIds.Count -eq 0) {
        throw "Profile '$ProfileId' does not contain any resources."
    }

    return Resolve-PSBaseInstallPlan -Catalog $Catalog -ResourceIds $resourceIds.ToArray() -VersionOverrides $overrides
}

Export-ModuleMember -Function Resolve-PSBaseInstallPlan, Resolve-PSBaseProfilePlan
