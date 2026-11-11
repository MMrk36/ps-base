Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'FileManifest.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BackupManager.psm1') -Force

function Set-PSBaseUpdateLockEntry {
    param([string]$Path, [string]$ResourceId, $PlanItem, [string]$BackupPath)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lock = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        if ($lock.schemaVersion -ne 1 -or $lock.installedResources -isnot [System.Collections.IDictionary]) {
            throw 'Existing PS Base lockfile has an unsupported structure.'
        }
    }
    else {
        $lock = @{ schemaVersion = 1; installedResources = @{} }
    }

    $apiVersion = $null
    $psCoreApi = $null
    $minimumArtifact = $null
    if ($PlanItem -is [System.Collections.IDictionary]) {
        if ($PlanItem.Contains('ApiVersion')) { $apiVersion = $PlanItem['ApiVersion'] }
        if ($PlanItem.Contains('PsCoreApi')) { $psCoreApi = $PlanItem['PsCoreApi'] }
        if ($PlanItem.Contains('MinimumArtifact')) { $minimumArtifact = $PlanItem['MinimumArtifact'] }
    }
    else {
        if ($null -ne $PlanItem.PSObject.Properties['ApiVersion']) { $apiVersion = $PlanItem.ApiVersion }
        if ($null -ne $PlanItem.PSObject.Properties['PsCoreApi']) { $psCoreApi = $PlanItem.PsCoreApi }
        if ($null -ne $PlanItem.PSObject.Properties['MinimumArtifact']) { $minimumArtifact = $PlanItem.MinimumArtifact }
    }
    $lock.installedResources[$ResourceId] = @{
        version = $PlanItem.Version
        tag = $PlanItem.Tag
        sha256 = $PlanItem.Sha256
        repository = $PlanItem.Repository
        apiVersion = $apiVersion
        psCoreApi = $psCoreApi
        minimumArtifact = $minimumArtifact
        installedPath = $PlanItem.InstalledPath
        installedAt = [DateTime]::UtcNow.ToString('o')
        backupPath = $BackupPath
    }

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, ($lock | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PSBaseResourceUpdate {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]$PlanItem,
        [Parameter(Mandatory)][string]$StagedPath,
        [Parameter(Mandatory)][string]$ServerRoot,
        [Parameter(Mandatory)][string]$InstalledPath,
        [object]$FilePolicies,
        [object]$Backup
    )

    if ($PlanItem.Id -notmatch '^[a-z0-9][a-z0-9_-]*$') {
        throw "Unsafe resource ID '$($PlanItem.Id)'."
    }

    $server = [System.IO.Path]::GetFullPath($ServerRoot)
    $target = [System.IO.Path]::GetFullPath($InstalledPath)
    $prefix = $server.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $target) -ine $PlanItem.Id) {
        throw 'Installed resource path must be the named resource directory inside the selected server root.'
    }
    if ((Get-Item -LiteralPath $target).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw 'Installed resource directory cannot be a symbolic link or reparse point.'
    }

    if (-not (Test-Path -LiteralPath $target -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $StagedPath 'fxmanifest.lua') -PathType Leaf)) {
        throw 'Update requires an installed resource and a staged release with root fxmanifest.lua.'
    }

    $state = Join-Path $server '.ps-base'
    $manifestPath = Join-Path $state ("manifests/" + $PlanItem.Id + ".json")
    $lockPath = Join-Path $state 'lock.json'
    $oldManifest = Read-PSBaseFileManifest -Path $manifestPath
    $newManifest = Get-PSBaseFileManifest -Root $StagedPath -FilePolicies $FilePolicies
    $plan = @(Get-PSBaseUpdatePlan -InstalledPath $target -PreviousManifest $oldManifest -NewManifest $newManifest)
    $changes = @($plan | Where-Object { $_.Action -ne 'Keep' })

    if ($changes.Count -eq 0) {
        return [pscustomobject]@{ Id = $PlanItem.Id; Version = $PlanItem.Version; Changes = 0; BackupPath = $null; Plan = $plan }
    }

    if (-not $PSCmdlet.ShouldProcess($target, "Update $($PlanItem.Id) to $($PlanItem.Version)")) {
        return $null
    }

    $backupPath = $null
    $manifestBackup = "$manifestPath.$([guid]::NewGuid().ToString('N')).bak"
    $lockBackup = "$lockPath.$([guid]::NewGuid().ToString('N')).bak"
    $targetChanged = $false
    $manifestChanged = $false
    $lockChanged = $false

    try {
        if ($null -ne $Backup) {
            if ($Backup.ResourceId -ine $PlanItem.Id -or -not (Test-Path -LiteralPath $Backup.BackupPath -PathType Container)) {
                throw 'The supplied update backup does not match the selected resource.'
            }
            $backup = $Backup
        }
        else {
            $backup = New-PSBaseBackup -ResourceId $PlanItem.Id -ServerRoot $server -InstalledPath $target -Reason 'update'
        }
        $backupPath = $backup.BackupPath
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Copy-Item $manifestPath $manifestBackup }
        if (Test-Path -LiteralPath $lockPath -PathType Leaf) { Copy-Item $lockPath $lockBackup }

        foreach ($item in $changes) {
            $destination = [System.IO.Path]::GetFullPath((Join-Path $target ($item.Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
            $targetPrefix = $target.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
            if (-not $destination.StartsWith($targetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Update path escapes resource directory: '$($item.Path)'."
            }

            if ($item.Action -eq 'Delete') {
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    Remove-Item -LiteralPath $destination -Force
                    $targetChanged = $true
                }
                continue
            }

            $source = [System.IO.Path]::GetFullPath((Join-Path $StagedPath ($item.Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
            if (-not $source.StartsWith(([System.IO.Path]::GetFullPath($StagedPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "Staged update file is missing or unsafe: '$($item.Path)'."
            }

            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            $temporary = "$destination.$([guid]::NewGuid().ToString('N')).psbase-tmp"
            try {
                Copy-Item -LiteralPath $source -Destination $temporary
                Move-Item -LiteralPath $temporary -Destination $destination -Force
            }
            finally {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
            $targetChanged = $true
        }

        Save-PSBaseFileManifest -Manifest $newManifest -Path $manifestPath
        $manifestChanged = $true
        $relativeBackup = [System.IO.Path]::GetRelativePath($server, $backupPath)
        $entry = @{
            Id = $PlanItem.Id
            Version = $PlanItem.Version
            Tag = $PlanItem.Tag
            Sha256 = $PlanItem.Sha256
            Repository = $PlanItem.Repository
            InstalledPath = [System.IO.Path]::GetRelativePath($server, $target)
        }
        Set-PSBaseUpdateLockEntry -Path $lockPath -ResourceId $PlanItem.Id -PlanItem $entry -BackupPath $relativeBackup
        $lockChanged = $true

        return [pscustomobject]@{
            Id = $PlanItem.Id
            Version = $PlanItem.Version
            Changes = $changes.Count
            BackupPath = $backupPath
            Plan = $plan
        }
    }
    catch {
        if ($targetChanged -and (Test-Path -LiteralPath $backupPath -PathType Container)) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $backupPath -Destination $target -Recurse
        }

        if ($manifestChanged) {
            if (Test-Path -LiteralPath $manifestBackup -PathType Leaf) {
                Move-Item -LiteralPath $manifestBackup -Destination $manifestPath -Force
            }
            else {
                Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
            }
        }

        if ($lockChanged) {
            if (Test-Path -LiteralPath $lockBackup -PathType Leaf) {
                Move-Item -LiteralPath $lockBackup -Destination $lockPath -Force
            }
            else {
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
            }
        }

        throw "Update of '$($PlanItem.Id)' failed; the previous resource was restored where possible. $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $manifestBackup -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $lockBackup -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-PSBaseResourceUpdate
