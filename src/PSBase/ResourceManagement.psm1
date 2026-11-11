Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'FileManifest.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BackupManager.psm1') -Force

function Get-PSBaseResourceStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerRoot)

    $server = [System.IO.Path]::GetFullPath($ServerRoot)
    $lockPath = Join-Path $server '.ps-base/lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        return @()
    }

    try {
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "PS Base lockfile is invalid: $($_.Exception.Message)"
    }

    if ($lock.schemaVersion -ne 1 -or $lock.installedResources -isnot [System.Collections.IDictionary]) {
        throw 'PS Base lockfile has an unsupported structure.'
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($resource in $lock.installedResources.GetEnumerator()) {
        $relativeInstall = [string]$resource.Value.installedPath
        if ([string]::IsNullOrWhiteSpace($relativeInstall) -or [System.IO.Path]::IsPathRooted($relativeInstall) -or ($relativeInstall -split '[\\/]+' -contains '..') -or (Split-Path -Leaf $relativeInstall) -ine $resource.Key) {
            throw "Unsafe installed path for '$($resource.Key)'."
        }

        $installed = [System.IO.Path]::GetFullPath((Join-Path $server $relativeInstall))
        $prefix = $server.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $installed.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Installed path for '$($resource.Key)' escapes the server root."
        }

        $manifestPath = Join-Path $server (".ps-base/manifests/" + $resource.Key + ".json")
        $modified = 0
        $missing = 0
        $untracked = 0
        $manifestState = 'Available'

        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $manifestState = 'Missing'
        }
        else {
            $manifest = Read-PSBaseFileManifest -Path $manifestPath
            foreach ($file in $manifest.files.GetEnumerator()) {
                $path = Join-Path $installed ($file.Key -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $missing++
                }
                elseif ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $file.Value.sha256) {
                    $modified++
                }
            }

            foreach ($file in Get-ChildItem -LiteralPath $installed -File -Recurse -Force -ErrorAction SilentlyContinue) {
                $relative = [System.IO.Path]::GetRelativePath($installed, $file.FullName).Replace('\\', '/')
                if (-not $manifest.files.Contains($relative)) { $untracked++ }
            }
        }

        $state = if ($manifestState -eq 'Missing') { 'NoBaseline' } elseif ($modified -gt 0 -or $missing -gt 0 -or $untracked -gt 0) { 'Attention' } else { 'Clean' }
        $results.Add([pscustomobject]@{
            Id = $resource.Key
            Version = $resource.Value.version
            State = $state
            Manifest = $manifestState
            ModifiedFiles = $modified
            MissingFiles = $missing
            UntrackedFiles = $untracked
            InstalledPath = $installed
            BackupPath = $resource.Value.backupPath
        })
    }

    return $results.ToArray()
}

function Invoke-PSBaseResourceUninstall {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$ServerRoot
    )

    if ($ResourceId -notmatch '^[a-z0-9][a-z0-9_-]*$') { throw "Unsafe resource ID '$ResourceId'." }
    $server = [System.IO.Path]::GetFullPath($ServerRoot)
    $lockPath = Join-Path $server '.ps-base/lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw 'No PS Base lockfile exists.' }

    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable
    if ($lock.schemaVersion -ne 1 -or $lock.installedResources -isnot [System.Collections.IDictionary] -or
        -not $lock.installedResources.Contains($ResourceId)) {
        throw "Resource '$ResourceId' is not registered as installed."
    }

    $entry = $lock.installedResources[$ResourceId]
    $relativeInstall = [string]$entry.installedPath
    if ([string]::IsNullOrWhiteSpace($relativeInstall) -or [System.IO.Path]::IsPathRooted($relativeInstall) -or ($relativeInstall -split '[\\/]+' -contains '..') -or (Split-Path -Leaf $relativeInstall) -ine $ResourceId) {
        throw 'The installed resource path in the lockfile is unsafe.'
    }

    $installed = [System.IO.Path]::GetFullPath((Join-Path $server $relativeInstall))
    $prefix = $server.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $installed.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $installed -PathType Container)) {
        throw 'The installed resource directory is missing or outside the server root.'
    }

    if (((Get-Item -LiteralPath $installed).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The installed resource directory cannot be a symbolic link or reparse point.'
    }
    foreach ($item in Get-ChildItem -LiteralPath $installed -Recurse -Force) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Resource contains a symbolic link or reparse point: $($item.FullName)"
        }
    }

    $manifestPath = Join-Path $server (".ps-base/manifests/" + $ResourceId + ".json")
    $manifest = Read-PSBaseFileManifest -Path $manifestPath
    $backupDirectory = Join-Path $server '.ps-base/backups'
    $backup = $null

    $removable = [System.Collections.Generic.List[string]]::new()
    $protected = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $manifest.files.GetEnumerator()) {
        $path = Join-Path $installed ($file.Key -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($file.Value.policy -ne 'preserve' -and $hash -ieq $file.Value.sha256) {
            $removable.Add($path)
        }
        else {
            $protected.Add($path)
        }
    }

    if (-not $PSCmdlet.ShouldProcess($installed, "Safely uninstall $ResourceId; preserve $($protected.Count) changed or protected files")) {
        return $null
    }

    $backupMetadata = New-PSBaseBackup -ResourceId $ResourceId -ServerRoot $server -InstalledPath $installed -Reason 'uninstall'
    $backup = $backupMetadata.BackupPath
    $manifestBackup = "$manifestPath.$([guid]::NewGuid().ToString('N')).bak"
    Copy-Item -LiteralPath $manifestPath -Destination $manifestBackup
    try {
        foreach ($path in $removable) {
            Remove-Item -LiteralPath $path -Force
        }

        Get-ChildItem -LiteralPath $installed -Directory -Recurse -Force |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                if (@(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $_.FullName -Force
                }
            }

        $remaining = @(Get-ChildItem -LiteralPath $installed -File -Recurse -Force)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $installed -Recurse -Force
            [void]$lock.installedResources.Remove($ResourceId)
            Remove-Item -LiteralPath $manifestPath -Force
            $state = 'Removed'
        }
        else {
            $entry.state = 'partially-uninstalled'
            $entry.lastUninstallAt = [DateTime]::UtcNow.ToString('o')
            $entry.backupPath = [System.IO.Path]::GetRelativePath($server, $backup)
            $state = 'Partial'
        }

        $temporary = "$lockPath.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [System.IO.File]::WriteAllText($temporary, ($lock | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporary -Destination $lockPath -Force
        }
        finally {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }

        return [pscustomobject]@{
            Id = $ResourceId
            State = $state
            RemovedFiles = $removable.Count
            PreservedFiles = $remaining.Count
            BackupPath = $backup
        }
    }
    catch {
        if (Test-Path -LiteralPath $backup -PathType Container) {
            if (Test-Path -LiteralPath $installed) { Remove-Item -LiteralPath $installed -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-Item -LiteralPath $backup -Destination $installed -Recurse
        }
        if (Test-Path -LiteralPath $manifestBackup -PathType Leaf) { Move-Item -LiteralPath $manifestBackup -Destination $manifestPath -Force }
        throw "Uninstall of '$ResourceId' failed; the backup was used to restore the resource where possible. $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $manifestBackup -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-PSBaseResourceStatus, Invoke-PSBaseResourceUninstall
