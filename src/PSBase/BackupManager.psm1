Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'FileManifest.psm1') -Force

function Get-PSBaseBackupState {
    param([string]$ServerRoot, [string]$ResourceId)

    $lockPath = Join-Path $ServerRoot '.ps-base/lock.json'
    $lock = $null
    $entry = $null

    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        try {
            $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable
        }
        catch {
            throw "PS Base lockfile is invalid: $($_.Exception.Message)"
        }

        if ($lock.schemaVersion -ne 1 -or $lock.installedResources -isnot [System.Collections.IDictionary]) {
            throw 'PS Base lockfile has an unsupported structure.'
        }

        if ($lock.installedResources.Contains($ResourceId)) {
            $entry = $lock.installedResources[$ResourceId]
        }
    }

    $manifestPath = Join-Path $ServerRoot (".ps-base/manifests/" + $ResourceId + ".json")
    $manifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Read-PSBaseFileManifest -Path $manifestPath
    }
    else {
        $null
    }

    return [pscustomobject]@{
        LockPath = $lockPath
        Lock = $lock
        LockEntry = $entry
        ManifestPath = $manifestPath
        Manifest = $manifest
    }
}

function New-PSBaseBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$ServerRoot,
        [Parameter(Mandatory)][string]$InstalledPath,
        [string]$Reason = 'manual',
        [string]$BackupId
    )

    $server = [System.IO.Path]::GetFullPath($ServerRoot)
    $installed = [System.IO.Path]::GetFullPath($InstalledPath)
    $prefix = $server.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

    if ($ResourceId -notmatch '^[a-z0-9][a-z0-9_-]*$' -or
        $Reason -notmatch '^[a-z-]+$' -or
        -not $installed.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $installed) -ine $ResourceId) {
        throw 'Backup target must be the named resource directory inside the server root.'
    }

    if (-not (Test-Path -LiteralPath $installed -PathType Container)) {
        throw "Resource directory not found: $installed"
    }

    foreach ($item in Get-ChildItem -LiteralPath $installed -Recurse -Force) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Cannot back up a resource containing a symbolic link or reparse point: $($item.FullName)"
        }
    }

    if ([string]::IsNullOrWhiteSpace($BackupId)) {
        $BackupId = $ResourceId + '-' + $Reason + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N')
    }
    elseif ($BackupId -notmatch ('^' + [regex]::Escape($ResourceId + '-' + $Reason + '-') + '[0-9]{8}-[0-9]{6}-[0-9]{3}-[a-f0-9]{32}$')) {
        throw 'The supplied backup ID is invalid for this resource and backup reason.'
    }

    $backupId = $BackupId
    $state = Get-PSBaseBackupState -ServerRoot $server -ResourceId $ResourceId
    $backupDirectory = Join-Path $server '.ps-base/backups'
    $metadataDirectory = Join-Path $server '.ps-base/backup-metadata'
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $metadataDirectory -Force | Out-Null

    $backupPath = Join-Path $backupDirectory $backupId
    $metadataPath = Join-Path $metadataDirectory ($backupId + '.json')

    if ((Test-Path -LiteralPath $backupPath) -or (Test-Path -LiteralPath $metadataPath)) {
        throw "Backup identifier '$backupId' is already in use."
    }

    try {
        Copy-Item -LiteralPath $installed -Destination $backupPath -Recurse
        $metadata = [ordered]@{
            schemaVersion = 1
            backupId = $backupId
            resourceId = $ResourceId
            createdAt = [DateTime]::UtcNow.ToString('o')
            reason = $Reason
            installedPath = [System.IO.Path]::GetRelativePath($server, $installed)
            manifest = $state.Manifest
            lockEntry = $state.LockEntry
        }

        $temporary = "$metadataPath.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [System.IO.File]::WriteAllText($temporary, ($metadata | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporary -Destination $metadataPath -Force
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue
        throw "Could not create backup for '$ResourceId': $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        BackupId = $backupId
        ResourceId = $ResourceId
        BackupPath = $backupPath
        MetadataPath = $metadataPath
    }
}

function Get-PSBaseBackupList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerRoot)

    $server = [System.IO.Path]::GetFullPath($ServerRoot)
    $metadataDirectory = Join-Path $server '.ps-base/backup-metadata'
    if (-not (Test-Path -LiteralPath $metadataDirectory -PathType Container)) {
        return @()
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $metadataDirectory -Filter '*.json' -File) {
        try {
            $metadata = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        }
        catch {
            throw "Backup metadata '$($file.Name)' is invalid: $($_.Exception.Message)"
        }

        $backupId = [string]$metadata.backupId
        if ($metadata.schemaVersion -ne 1 -or
            $backupId -ne [System.IO.Path]::GetFileNameWithoutExtension($file.Name) -or
            $backupId -notmatch '^[a-z0-9][a-z0-9_-]*-[a-z-]+-[0-9]{8}-[0-9]{6}-[0-9]{3}-[a-f0-9]{32}$' -or
            $metadata.resourceId -notmatch '^[a-z0-9][a-z0-9_-]*$') {
            throw "Backup metadata '$($file.Name)' has an unsupported structure."
        }

        $backupPath = Join-Path $server (".ps-base/backups/" + $backupId)
        $results.Add([pscustomobject]@{
            BackupId = $backupId
            ResourceId = $metadata.resourceId
            CreatedAt = $metadata.createdAt
            Reason = $metadata.reason
            Exists = Test-Path -LiteralPath $backupPath -PathType Container
            BackupPath = $backupPath
        })
    }

    return $results.ToArray()
}

function Set-PSBaseRestoredLockEntry {
    param([string]$LockPath, [string]$ResourceId, $Entry)

    $lock = if (Test-Path -LiteralPath $LockPath -PathType Leaf) {
        Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        @{ schemaVersion = 1; installedResources = @{} }
    }

    if ($lock.schemaVersion -ne 1 -or $lock.installedResources -isnot [System.Collections.IDictionary]) {
        throw 'PS Base lockfile has an unsupported structure.'
    }

    if ($null -eq $Entry) {
        [void]$lock.installedResources.Remove($ResourceId)
    }
    else {
        $lock.installedResources[$ResourceId] = $Entry
    }

    $temporary = "$LockPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, ($lock | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $LockPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Restore-PSBaseBackup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$BackupId,
        [Parameter(Mandatory)][string]$ServerRoot
    )

    if ([string]::IsNullOrWhiteSpace($BackupId) -or
        $BackupId -notmatch '^[a-z0-9][a-z0-9_-]*-[a-z-]+-[0-9]{8}-[0-9]{6}-[0-9]{3}-[a-f0-9]{32}$') {
        throw 'Invalid backup ID.'
    }

    $server = [System.IO.Path]::GetFullPath($ServerRoot)
    $metadataPath = Join-Path $server (".ps-base/backup-metadata/" + $BackupId + '.json')
    $backupPath = Join-Path $server (".ps-base/backups/" + $BackupId)

    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $backupPath -PathType Container)) {
        throw "Backup '$BackupId' or its metadata was not found."
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable
    if ($metadata.schemaVersion -ne 1 -or
        $metadata.backupId -ne $BackupId -or
        $metadata.resourceId -notmatch '^[a-z0-9][a-z0-9_-]*$') {
        throw 'Backup metadata has an unsupported structure.'
    }

    $relativeInstall = [string]$metadata.installedPath
    if ([string]::IsNullOrWhiteSpace($relativeInstall) -or
        [System.IO.Path]::IsPathRooted($relativeInstall) -or
        ($relativeInstall -split '[\\/]+') -contains '..' -or
        (Split-Path -Leaf $relativeInstall) -ine $metadata.resourceId) {
        throw 'Backup metadata contains an unsafe installation path.'
    }

    $target = [System.IO.Path]::GetFullPath((Join-Path $server $relativeInstall))
    $serverPrefix = $server.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($serverPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Backup target escapes the server root.'
    }

    if (-not (Test-Path -LiteralPath (Join-Path $backupPath 'fxmanifest.lua') -PathType Leaf)) {
        throw 'Backup does not contain a root-level fxmanifest.lua.'
    }

    foreach ($item in Get-ChildItem -LiteralPath $backupPath -Recurse -Force) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Backup contains a symbolic link or reparse point: $($item.FullName)"
        }
    }

    if (-not $PSCmdlet.ShouldProcess($target, "Restore backup $BackupId for $($metadata.resourceId)")) {
        return $null
    }

    if ((Test-Path -LiteralPath $target) -and
        -not (Test-Path -LiteralPath $target -PathType Container)) {
        throw 'The current resource target exists but is not a directory.'
    }

    $currentBackup = $null
    if (Test-Path -LiteralPath $target -PathType Container) {
        $currentBackup = New-PSBaseBackup -ResourceId $metadata.resourceId -ServerRoot $server -InstalledPath $target -Reason 'pre-restore'
    }

    $state = Get-PSBaseBackupState -ServerRoot $server -ResourceId $metadata.resourceId
    $previousPath = "$target.psbase-restore-$([guid]::NewGuid().ToString('N'))"
    $stagePath = "$target.psbase-stage-$([guid]::NewGuid().ToString('N'))"
    $movedPrevious = $false
    $movedRestored = $false
    $manifestChanged = $false

    try {
        Copy-Item -LiteralPath $backupPath -Destination $stagePath -Recurse
        if (Test-Path -LiteralPath $target -PathType Container) {
            Move-Item -LiteralPath $target -Destination $previousPath
            $movedPrevious = $true
        }

        Move-Item -LiteralPath $stagePath -Destination $target
        $movedRestored = $true

        if ($null -ne $metadata.manifest) {
            Save-PSBaseFileManifest -Manifest $metadata.manifest -Path $state.ManifestPath
        }
        else {
            Remove-Item -LiteralPath $state.ManifestPath -Force -ErrorAction SilentlyContinue
        }
        $manifestChanged = $true

        Set-PSBaseRestoredLockEntry -LockPath $state.LockPath -ResourceId $metadata.resourceId -Entry $metadata.lockEntry

        if ($movedPrevious) {
            Remove-Item -LiteralPath $previousPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        return [pscustomobject]@{
            ResourceId = $metadata.resourceId
            BackupId = $BackupId
            RestoredPath = $target
            SafetyBackupPath = if ($null -ne $currentBackup) { $currentBackup.BackupPath } else { $null }
        }
    }
    catch {
        if ($movedRestored -and (Test-Path -LiteralPath $target)) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($movedPrevious -and (Test-Path -LiteralPath $previousPath)) {
            Move-Item -LiteralPath $previousPath -Destination $target -ErrorAction SilentlyContinue
        }

        if ($manifestChanged) {
            if ($null -ne $state.Manifest) {
                Save-PSBaseFileManifest -Manifest $state.Manifest -Path $state.ManifestPath
            }
            else {
                Remove-Item -LiteralPath $state.ManifestPath -Force -ErrorAction SilentlyContinue
            }
        }

        if ($null -ne $state.Lock) {
            Set-PSBaseRestoredLockEntry -LockPath $state.LockPath -ResourceId $metadata.resourceId -Entry $state.LockEntry
        }
        elseif (Test-Path -LiteralPath $state.LockPath -PathType Leaf) {
            Remove-Item -LiteralPath $state.LockPath -Force
        }

        throw "Restore of '$BackupId' failed; the current resource was restored where possible. $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $previousPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function New-PSBaseBackup, Get-PSBaseBackupList, Restore-PSBaseBackup
