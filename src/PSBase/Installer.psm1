Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'FileManifest.psm1') -Force

function Test-PSBasePathWithin {
    param([string]$Parent, [string]$Child)

    $parentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $childPath = [System.IO.Path]::GetFullPath($Child)
    return $childPath.StartsWith($parentPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Set-PSBaseLockfile {
    param([string]$Path, [string]$ResourceId, [hashtable]$Entry)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $lock = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        }
        catch {
            throw "Existing PS Base lockfile is invalid: $($_.Exception.Message)"
        }

        if ($lock.schemaVersion -ne 1 -or $lock.installedResources -isnot [System.Collections.IDictionary]) {
            throw 'Existing PS Base lockfile has an unsupported structure.'
        }
    }
    else {
        $lock = @{ schemaVersion = 1; installedResources = @{} }
    }

    $lock.installedResources[$ResourceId] = $Entry
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"

    try {
        $json = $lock | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Install-PSBaseResource {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$PlanItem,
        [Parameter(Mandatory)][string]$StagedPath,
        [Parameter(Mandatory)][string]$ServerRoot,
        [Parameter(Mandatory)][string]$ResourcesPath,
        [string[]]$PreservePaths = @()
    )

    if ($PlanItem.Id -notmatch '^[a-z0-9][a-z0-9_-]*$') {
        throw "Unsafe resource ID '$($PlanItem.Id)'."
    }

    if (-not (Test-Path -LiteralPath $ServerRoot -PathType Container)) {
        throw "Server root does not exist: $ServerRoot"
    }

    if (-not (Test-Path -LiteralPath $ResourcesPath -PathType Container)) {
        throw "Resources directory does not exist: $ResourcesPath"
    }

    if (-not (Test-PSBasePathWithin -Parent $ServerRoot -Child $ResourcesPath)) {
        throw 'The resources directory must be inside the selected server root.'
    }

    if (-not (Test-Path -LiteralPath $StagedPath -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $StagedPath 'fxmanifest.lua') -PathType Leaf)) {
        throw 'Staged resource must be a directory containing a root-level fxmanifest.lua.'
    }

    $targetPath = Join-Path $ResourcesPath $PlanItem.Id
    if (-not (Test-PSBasePathWithin -Parent $ResourcesPath -Child $targetPath)) {
        throw 'Resolved resource path escapes the resources directory.'
    }

    foreach ($relativePath in $PreservePaths) {
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            $relativePath.StartsWith('/') -or
            $relativePath.Contains('\') -or
            $relativePath.Contains(':') -or
            ($relativePath.TrimEnd('/').Split('/') -contains '..') -or
            ($relativePath.TrimEnd('/').Split('/') -contains '.')) {
            throw "Unsafe configuration preservation path '$relativePath'."
        }
    }

    $lockPath = Join-Path $ServerRoot '.ps-base/lock.json'
    $stateDirectory = Join-Path $ServerRoot '.ps-base'
    $backupDirectory = Join-Path $stateDirectory 'backups'
    $backupPath = Join-Path $backupDirectory ($PlanItem.Id + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N'))
    $previousPath = "$targetPath.psbase-old-$([guid]::NewGuid().ToString('N'))"
    $hadPrevious = Test-Path -LiteralPath $targetPath
    $manifestPath = Join-Path $stateDirectory ("manifests/" + $PlanItem.Id + ".json")
    $manifestBackupPath = "$manifestPath.$([guid]::NewGuid().ToString('N')).bak"
    $hadManifest = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $movedNew = $false
    $movedOld = $false
    $manifestWritten = $false
    $releaseManifest = Get-PSBaseFileManifest -Root $StagedPath

    if ($hadPrevious -and -not (Test-Path -LiteralPath $targetPath -PathType Container)) {
        throw "Existing resource target is not a directory: $targetPath"
    }

    if (-not $PSCmdlet.ShouldProcess($targetPath, "Install $($PlanItem.Id) $($PlanItem.Version)")) {
        return $null
    }

    try {
        if ($hadPrevious) {
            foreach ($relativePath in $PreservePaths) {
                $oldConfigPath = Join-Path $targetPath $relativePath
                if (-not (Test-Path -LiteralPath $oldConfigPath)) {
                    continue
                }

                $newConfigPath = Join-Path $StagedPath $relativePath
                if (Test-Path -LiteralPath $newConfigPath) {
                    Remove-Item -LiteralPath $newConfigPath -Recurse -Force
                }

                $newParent = Split-Path -Parent $newConfigPath
                if (-not (Test-Path -LiteralPath $newParent -PathType Container)) {
                    New-Item -ItemType Directory -Path $newParent -Force | Out-Null
                }

                Copy-Item -LiteralPath $oldConfigPath -Destination $newConfigPath -Recurse -Force
            }

            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
            Copy-Item -LiteralPath $targetPath -Destination $backupPath -Recurse
            Move-Item -LiteralPath $targetPath -Destination $previousPath
            $movedOld = $true
        }

        Move-Item -LiteralPath $StagedPath -Destination $targetPath
        $movedNew = $true

        $entry = @{
            version = $PlanItem.Version
            tag = $PlanItem.Tag
            sha256 = $PlanItem.Sha256
            repository = $PlanItem.Repository
            installedPath = [System.IO.Path]::GetRelativePath($ServerRoot, $targetPath)
            installedAt = [DateTime]::UtcNow.ToString('o')
            backupPath = if ($hadPrevious) { [System.IO.Path]::GetRelativePath($ServerRoot, $backupPath) } else { $null }
        }

        if ($hadManifest) {
            Copy-Item -LiteralPath $manifestPath -Destination $manifestBackupPath
        }

        Save-PSBaseFileManifest -Manifest $releaseManifest -Path $manifestPath
        $manifestWritten = $true
        Set-PSBaseLockfile -Path $lockPath -ResourceId $PlanItem.Id -Entry $entry

        if (Test-Path -LiteralPath $manifestBackupPath) {
            Remove-Item -LiteralPath $manifestBackupPath -Force
        }

        if ($movedOld) {
            Remove-Item -LiteralPath $previousPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        return [pscustomobject]@{
            Id = $PlanItem.Id
            Version = $PlanItem.Version
            InstalledPath = $targetPath
            BackupPath = if ($hadPrevious) { $backupPath } else { $null }
        }
    }
    catch {
        if ($manifestWritten) {
            Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $manifestBackupPath -PathType Leaf) {
            Move-Item -LiteralPath $manifestBackupPath -Destination $manifestPath -Force
        }

        if ($movedNew -and (Test-Path -LiteralPath $targetPath)) {
            Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        if ($movedOld -and (Test-Path -LiteralPath $previousPath)) {
            Move-Item -LiteralPath $previousPath -Destination $targetPath -ErrorAction SilentlyContinue
        }

        throw "Installation of '$($PlanItem.Id)' failed and was rolled back where possible: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $manifestBackupPath -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Install-PSBaseResource
