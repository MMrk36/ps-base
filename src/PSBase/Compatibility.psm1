Set-StrictMode -Version Latest

function ConvertTo-PSBaseComparableVersion {
    param([string]$Value, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?(?:\.([0-9]+))?(?:[-+][0-9A-Za-z.-]+)?$') {
        throw "$Label '$Value' is not a supported numeric version."
    }

    $parts = @($Matches[1], $Matches[2], $Matches[3], $Matches[4])
    $numbers = [System.Collections.Generic.List[int]]::new()
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) { $numbers.Add(0) }
        else { $numbers.Add([int]$part) }
    }

    return [version]::new($numbers[0], $numbers[1], $numbers[2], $numbers[3])
}

function Test-PSBaseApiRange {
    param([string]$ApiVersion, $Range, [string]$ResourceId)

    if ($null -eq $Range) { return $true }
    if ([string]::IsNullOrWhiteSpace($ApiVersion)) {
        throw "Cannot verify '$ResourceId': the selected PS Core release does not publish an API version."
    }

    $actual = ConvertTo-PSBaseComparableVersion -Value $ApiVersion -Label 'PS Core API version'
    if ($Range -is [System.Collections.IDictionary]) {
        $minimumVersion = if ($Range.Contains('minVersion')) { [string]$Range['minVersion'] } else { $null }
        $maximumVersion = if ($Range.Contains('maxVersion')) { [string]$Range['maxVersion'] } else { $null }
    }
    else {
        $minimumVersion = if ($null -ne $Range.PSObject.Properties['minVersion']) { [string]$Range.minVersion } else { $null }
        $maximumVersion = if ($null -ne $Range.PSObject.Properties['maxVersion']) { [string]$Range.maxVersion } else { $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($minimumVersion)) {
        $minimum = ConvertTo-PSBaseComparableVersion -Value $minimumVersion -Label 'Minimum PS Core API version'
        if ($actual -lt $minimum) {
            throw "Resource '$ResourceId' requires PS Core API $($Range.minVersion) or newer; selected API is $ApiVersion."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($maximumVersion)) {
        $maximum = ConvertTo-PSBaseComparableVersion -Value $maximumVersion -Label 'Maximum PS Core API version'
        if ($actual -ge $maximum) {
            throw "Resource '$ResourceId' requires a PS Core API older than $maximumVersion; selected API is $ApiVersion."
        }
    }

    return $true
}

function Test-PSBaseCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][object[]]$Plan,
        [string]$ServerRoot,
        [string]$ArtifactVersion
    )

    $selected = @{}
    foreach ($item in $Plan) {
        $selected[$item.Id] = $item
    }

    $lock = $null
    if (-not [string]::IsNullOrWhiteSpace($ServerRoot)) {
        $lockPath = Join-Path ([System.IO.Path]::GetFullPath($ServerRoot)) '.ps-base/lock.json'
        if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
            try {
                $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable
            }
            catch {
                throw "Cannot verify compatibility because the PS Base lockfile is invalid: $($_.Exception.Message)"
            }
            if ($lock.schemaVersion -ne 1 -or $lock.installedResources -isnot [System.Collections.IDictionary]) {
                throw 'Cannot verify compatibility because the PS Base lockfile has an unsupported structure.'
            }
        }
    }

    $coreApiVersion = $null
    if ($selected.ContainsKey('ps-core')) {
        $coreApiVersion = [string]$selected['ps-core'].ApiVersion
    }
    elseif ($null -ne $lock -and $lock.installedResources.Contains('ps-core')) {
        $coreApiVersion = [string]$lock.installedResources['ps-core'].apiVersion
    }

    $warnings = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $Plan) {
        if ($null -ne $item.PsCoreApi) {
            if ([string]::IsNullOrWhiteSpace($coreApiVersion)) {
                if ([string]::IsNullOrWhiteSpace($ServerRoot) -and -not $selected.ContainsKey('ps-core')) {
                    $warnings.Add("Cannot check PS Core API compatibility for '$($item.Id)' without -ServerPath or ps-core in the plan.")
                }
                else {
                    throw "Cannot verify PS Core API compatibility for '$($item.Id)': no installed or selected PS Core API version is recorded."
                }
            }
            else {
                Test-PSBaseApiRange -ApiVersion $coreApiVersion -Range $item.PsCoreApi -ResourceId $item.Id | Out-Null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$item.MinimumArtifact)) {
            if ([string]::IsNullOrWhiteSpace($ArtifactVersion)) {
                throw "Resource '$($item.Id)' requires server artifact $($item.MinimumArtifact) or newer. Supply -ArtifactVersion to verify the target server."
            }

            $actualArtifact = ConvertTo-PSBaseComparableVersion -Value $ArtifactVersion -Label 'Server artifact version'
            $minimumArtifact = ConvertTo-PSBaseComparableVersion -Value $item.MinimumArtifact -Label 'Minimum artifact version'
            if ($actualArtifact -lt $minimumArtifact) {
                throw "Resource '$($item.Id)' requires server artifact $($item.MinimumArtifact) or newer; target is $ArtifactVersion."
            }
        }
    }

    if ($selected.ContainsKey('ps-core') -and $null -ne $lock) {
        foreach ($entry in $lock.installedResources.GetEnumerator()) {
            $resourceId = [string]$entry.Key
            if ($resourceId -ieq 'ps-core' -or $selected.ContainsKey($resourceId)) { continue }

            $range = $entry.Value.psCoreApi
            if ($null -eq $range) {
                $resource = @($Catalog.resources | Where-Object { $_.id -ieq $resourceId }) | Select-Object -First 1
                if ($null -ne $resource) {
                    $release = @($resource.releases | Where-Object { $_.version -eq $entry.Value.version }) | Select-Object -First 1
                    if ($null -ne $release -and $null -ne $release.PSObject.Properties['psCoreApi']) { $range = $release.psCoreApi }
                }
            }

            if ($null -ne $range) {
                Test-PSBaseApiRange -ApiVersion $coreApiVersion -Range $range -ResourceId $resourceId | Out-Null
            }
            else {
                $warnings.Add("Cannot verify PS Core API compatibility for installed resource '$resourceId': no compatibility metadata is available.")
            }
        }
    }

    return [pscustomobject]@{
        Compatible = $true
        PsCoreApiVersion = $coreApiVersion
        Warnings = $warnings.ToArray()
    }
}

Export-ModuleMember -Function Test-PSBaseCompatibility
