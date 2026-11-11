[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('gui', 'menu', 'list', 'plan', 'install', 'update', 'status', 'uninstall', 'backups', 'restore', 'transactions', 'recover', 'profiles')]
    [string]$Command = 'gui',

    [string[]]$Resource,

    [string]$Version,

    [string]$CatalogPath,

    [string]$ServerPath,

    [string]$ResourcesPath,

    [string]$BackupId,

    [string]$TransactionId,

    [string]$Profile,

    [string]$ArtifactVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$catalogModule = Join-Path $root 'src/PSBase/Catalog.psm1'
$resolverModule = Join-Path $root 'src/PSBase/DependencyResolver.psm1'
$artifactModule = Join-Path $root 'src/PSBase/Artifact.psm1'
$installerModule = Join-Path $root 'src/PSBase/Installer.psm1'
$updateModule = Join-Path $root 'src/PSBase/Update.psm1'
$fileManifestModule = Join-Path $root 'src/PSBase/FileManifest.psm1'
$resourceManagementModule = Join-Path $root 'src/PSBase/ResourceManagement.psm1'
$backupManagerModule = Join-Path $root 'src/PSBase/BackupManager.psm1'
$transactionModule = Join-Path $root 'src/PSBase/Transaction.psm1'
$compatibilityModule = Join-Path $root 'src/PSBase/Compatibility.psm1'

Import-Module $resolverModule -Force
Import-Module $catalogModule -Force
Import-Module $artifactModule -Force
Import-Module $installerModule -Force
Import-Module $updateModule -Force
Import-Module $resourceManagementModule -Force
Import-Module $backupManagerModule -Force
Import-Module $transactionModule -Force
Import-Module $compatibilityModule -Force
Import-Module $fileManifestModule -Force

try {
    $catalog = if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
        Get-PSBaseCatalog
    }
    else {
        Get-PSBaseCatalog -Path $CatalogPath
    }

    switch ($Command) {
        'gui' {
            if (-not $IsWindows) {
                throw 'The desktop interface currently requires Windows and PowerShell 7. Use the CLI commands on other platforms.'
            }
            $guiPath = Join-Path $root 'PS-Base-GUI.ps1'
            if (-not (Test-Path -LiteralPath $guiPath -PathType Leaf)) {
                throw "Desktop interface not found: $guiPath"
            }
            $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
            Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-STA', '-File', "`"$guiPath`"")
        }

        'list' {
            $catalog.resources |
                Sort-Object name |
                Select-Object id, name, status, installable,
                    @{Name = 'PublishedVersions'; Expression = { @($_.releases).Count }} |
                Format-Table -AutoSize
        }

        'plan' {
            if (-not $Profile -and (-not $Resource -or $Resource.Count -eq 0)) {
                throw 'Specify at least one resource with -Resource or an installation profile with -Profile.'
            }
            if ($Profile -and $Version) {
                throw 'Profiles pin exact versions. Do not combine -Profile with -Version.'
            }

            $plan = if ($Profile) {
                Resolve-PSBaseProfilePlan -Catalog $catalog -ProfileId $Profile
            }
            else {
                Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds $Resource -Version $Version
            }
            $compatibility = Test-PSBaseCompatibility -Catalog $catalog -Plan $plan -ServerRoot $ServerPath -ArtifactVersion $ArtifactVersion
            foreach ($warning in $compatibility.Warnings) { Write-Warning $warning }
            Write-Host 'Resolved installation plan:' -ForegroundColor Cyan
            $plan | Format-Table Id, Version, Name -AutoSize
            Write-Host 'No files have been downloaded or changed.' -ForegroundColor Yellow
        }

        'install' {
            if (-not $Profile -and (-not $Resource -or $Resource.Count -eq 0)) {
                throw 'Specify at least one resource with -Resource or an installation profile with -Profile.'
            }
            if ($Profile -and $Version) {
                throw 'Profiles pin exact versions. Do not combine -Profile with -Version.'
            }

            if ([string]::IsNullOrWhiteSpace($ServerPath)) {
                throw 'Specify the RedM server root with -ServerPath.'
            }

            if (-not (Test-Path -LiteralPath $ServerPath -PathType Container)) {
                throw "Server root does not exist: $ServerPath"
            }

            $serverRoot = [System.IO.Path]::GetFullPath($ServerPath)
            $resourcesRoot = if ([string]::IsNullOrWhiteSpace($ResourcesPath)) {
                Join-Path $serverRoot 'resources'
            }
            else {
                [System.IO.Path]::GetFullPath($ResourcesPath)
            }

            if (-not (Test-Path -LiteralPath $resourcesRoot -PathType Container)) {
                throw "Resources directory does not exist: $resourcesRoot"
            }

            $plan = if ($Profile) { @(Resolve-PSBaseProfilePlan -Catalog $catalog -ProfileId $Profile) } else { @(Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds $Resource -Version $Version) }
            $compatibility = Test-PSBaseCompatibility -Catalog $catalog -Plan $plan -ServerRoot $serverRoot -ArtifactVersion $ArtifactVersion
            foreach ($warning in $compatibility.Warnings) { Write-Warning $warning }
            Write-Host 'Installation plan:' -ForegroundColor Cyan
            $plan | Format-Table Id, Version, Name -AutoSize

            $summary = ($plan | ForEach-Object { "$($_.Id) $($_.Version)" }) -join ', '
            if (-not $PSCmdlet.ShouldProcess($serverRoot, "Install $summary")) {
                return
            }

            $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-" + [guid]::NewGuid().ToString('N'))
            $installed = [System.Collections.Generic.List[string]]::new()

            try {
                foreach ($item in $plan) {
                    $resourceEntry = Get-PSBaseResource -Catalog $catalog -Id $item.Id
                    $release = Get-PSBaseRelease -Resource $resourceEntry -Version $item.Version
                    $downloadDirectory = Join-Path $temporaryRoot 'downloads'
                    $stagePath = Join-Path (Join-Path $temporaryRoot 'staging') $item.Id

                    $archivePath = Get-PSBaseArtifact -Release $release -DestinationDirectory $downloadDirectory
                    Expand-PSBaseArtifact -ArchivePath $archivePath -DestinationPath $stagePath | Out-Null

                    $preservePaths = if ($null -ne $resourceEntry.PSObject.Properties['preservePaths']) {
                        @($resourceEntry.preservePaths)
                    }
                    else {
                        @()
                    }

                    Install-PSBaseResource -PlanItem $item -StagedPath $stagePath -ServerRoot $serverRoot -ResourcesPath $resourcesRoot -PreservePaths $preservePaths -Confirm:$false | Out-Null
                    $installed.Add($item.Id)
                    Write-Host "Installed $($item.Id) $($item.Version)." -ForegroundColor Green
                }
            }
            catch {
                if ($installed.Count -gt 0) {
                    Write-Warning "Installation stopped after: $($installed -join ', '). Those resources remain installed."
                }
                throw
            }
            finally {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }


        'update' {
            if (-not $Profile -and (-not $Resource -or $Resource.Count -eq 0)) {
                throw 'Specify at least one installed resource with -Resource or an installation profile with -Profile.'
            }
            if ($Profile -and $Version) {
                throw 'Profiles pin exact versions. Do not combine -Profile with -Version.'
            }
            if ([string]::IsNullOrWhiteSpace($ServerPath) -or -not (Test-Path -LiteralPath $ServerPath -PathType Container)) {
                throw 'Specify an existing RedM server root with -ServerPath.'
            }

            $serverRoot = [System.IO.Path]::GetFullPath($ServerPath)
            $resourcesRoot = if ([string]::IsNullOrWhiteSpace($ResourcesPath)) { Join-Path $serverRoot 'resources' } else { [System.IO.Path]::GetFullPath($ResourcesPath) }
            if (-not (Test-Path -LiteralPath $resourcesRoot -PathType Container)) { throw "Resources directory does not exist: $resourcesRoot" }
            $plan = if ($Profile) { @(Resolve-PSBaseProfilePlan -Catalog $catalog -ProfileId $Profile) } else { @(Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds $Resource -Version $Version) }
            $compatibility = Test-PSBaseCompatibility -Catalog $catalog -Plan $plan -ServerRoot $serverRoot -ArtifactVersion $ArtifactVersion
            foreach ($warning in $compatibility.Warnings) { Write-Warning $warning }
            $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-update-" + [guid]::NewGuid().ToString('N'))
            $prepared = [System.Collections.Generic.List[object]]::new()

            try {
                foreach ($item in $plan) {
                    $resourceEntry = Get-PSBaseResource -Catalog $catalog -Id $item.Id
                    $targetPath = Join-Path $resourcesRoot $item.Id
                    if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
                        throw "Resource '$($item.Id)' is not installed at '$targetPath'. Install it before updating."
                    }

                    $release = Get-PSBaseRelease -Resource $resourceEntry -Version $item.Version
                    $downloadDirectory = Join-Path $temporaryRoot 'downloads'
                    $stagePath = Join-Path (Join-Path $temporaryRoot 'staging') $item.Id
                    $archivePath = Get-PSBaseArtifact -Release $release -DestinationDirectory $downloadDirectory
                    Expand-PSBaseArtifact -ArchivePath $archivePath -DestinationPath $stagePath | Out-Null

                    $policies = [ordered]@{ default = 'managed'; rules = @() }
                    if ($null -ne $resourceEntry.PSObject.Properties['filePolicies']) {
                        if ($null -ne $resourceEntry.filePolicies.PSObject.Properties['default'] -and $resourceEntry.filePolicies.default) {
                            $policies.default = [string]$resourceEntry.filePolicies.default
                        }
                        if ($null -ne $resourceEntry.filePolicies.PSObject.Properties['rules']) {
                            $policies.rules += @($resourceEntry.filePolicies.rules)
                        }
                    }
                    if ($null -ne $resourceEntry.PSObject.Properties['preservePaths']) {
                        foreach ($preservePath in @($resourceEntry.preservePaths)) {
                            $policies.rules += [pscustomobject]@{ pattern = $preservePath; policy = 'preserve' }
                        }
                    }

                    $manifest = Get-PSBaseFileManifest -Root $stagePath -FilePolicies $policies
                    $manifestPath = Join-Path $serverRoot (".ps-base/manifests/" + $item.Id + ".json")
                    $previousManifest = Read-PSBaseFileManifest -Path $manifestPath
                    $filePlan = @(Get-PSBaseUpdatePlan -InstalledPath $targetPath -PreviousManifest $previousManifest -NewManifest $manifest)
                    $prepared.Add([pscustomobject]@{
                        Item = $item
                        StagePath = $stagePath
                        TargetPath = $targetPath
                        Policies = $policies
                        FilePlan = $filePlan
                    })
                }

                foreach ($entry in $prepared) {
                    Write-Host "Update plan: $($entry.Item.Id) -> $($entry.Item.Version)" -ForegroundColor Cyan
                    $entry.FilePlan | Format-Table Path, Action, Reason -Wrap -AutoSize
                }

                $summary = ($plan | ForEach-Object { "$($_.Id) $($_.Version)" }) -join ', '
                if (-not $PSCmdlet.ShouldProcess($serverRoot, "Update $summary")) { return }

                $transaction = Invoke-PSBaseUpdateTransaction -PreparedItems $prepared.ToArray() -ServerRoot $serverRoot
                Write-Host "Update transaction $($transaction.TransactionId) completed." -ForegroundColor Green
                foreach ($result in $transaction.Results) {
                    Write-Host "Updated $($result.Id) to $($result.Version). Applied $($result.Changes) file changes." -ForegroundColor Green
                }
            }
            finally {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }


        'status' {
            if ([string]::IsNullOrWhiteSpace($ServerPath) -or -not (Test-Path -LiteralPath $ServerPath -PathType Container)) {
                throw 'Specify an existing RedM server root with -ServerPath.'
            }
            $status = @(Get-PSBaseResourceStatus -ServerRoot $ServerPath)
            if ($status.Count -eq 0) {
                Write-Host 'No PS Base-managed resources were found.'
            }
            else {
                $status | Format-Table Id, Version, State, ModifiedFiles, MissingFiles, UntrackedFiles -AutoSize
            }
        }

        'uninstall' {
            if (-not $Resource -or $Resource.Count -ne 1) {
                throw 'Specify exactly one resource with -Resource.'
            }
            if ([string]::IsNullOrWhiteSpace($ServerPath) -or -not (Test-Path -LiteralPath $ServerPath -PathType Container)) {
                throw 'Specify an existing RedM server root with -ServerPath.'
            }
            if (-not $PSCmdlet.ShouldProcess($ServerPath, "Safely uninstall $($Resource[0])")) { return }
            $result = Invoke-PSBaseResourceUninstall -ResourceId $Resource[0] -ServerRoot $ServerPath -Confirm:$false
            Write-Host "Uninstall result: $($result.State). Removed $($result.RemovedFiles) managed files; preserved $($result.PreservedFiles) local files." -ForegroundColor Green
            Write-Host "Backup: $($result.BackupPath)"
        }


        'backups' {
            if ([string]::IsNullOrWhiteSpace($ServerPath) -or -not (Test-Path -LiteralPath $ServerPath -PathType Container)) {
                throw 'Specify an existing RedM server root with -ServerPath.'
            }
            $backups = @(Get-PSBaseBackupList -ServerRoot $ServerPath)
            if ($backups.Count -eq 0) {
                Write-Host 'No PS Base-managed backups were found.'
            }
            else {
                $backups | Sort-Object CreatedAt -Descending | Format-Table BackupId, ResourceId, CreatedAt, Reason, Exists -AutoSize
            }
        }

        'restore' {
            if ([string]::IsNullOrWhiteSpace($BackupId)) {
                throw 'Specify the exact backup identifier with -BackupId. Use the backups command to list available backups.'
            }
            if ([string]::IsNullOrWhiteSpace($ServerPath) -or -not (Test-Path -LiteralPath $ServerPath -PathType Container)) {
                throw 'Specify an existing RedM server root with -ServerPath.'
            }
            if (-not $PSCmdlet.ShouldProcess($ServerPath, "Restore backup $BackupId")) { return }
            $result = Restore-PSBaseBackup -BackupId $BackupId -ServerRoot $ServerPath -Confirm:$false
            Write-Host "Restored $($result.ResourceId) from $($result.BackupId)." -ForegroundColor Green
            if ($result.SafetyBackupPath) { Write-Host "Previous state backed up to: $($result.SafetyBackupPath)" }
        }


        'transactions' {
            if ([string]::IsNullOrWhiteSpace($ServerPath) -or -not (Test-Path -LiteralPath $ServerPath -PathType Container)) {
                throw 'Specify an existing RedM server root with -ServerPath.'
            }
            $transactions = @(Get-PSBaseTransactionList -ServerRoot $ServerPath)
            if ($transactions.Count -eq 0) {
                Write-Host 'No PS Base update transactions were found.'
            }
            else {
                $transactions | Sort-Object StartedAt -Descending | Format-Table TransactionId, Status, StartedAt, UpdatedAt -AutoSize
            }
        }

        'recover' {
            if ([string]::IsNullOrWhiteSpace($TransactionId)) {
                throw 'Specify the transaction ID with -TransactionId. Use the transactions command to list journals.'
            }
            if ([string]::IsNullOrWhiteSpace($ServerPath) -or -not (Test-Path -LiteralPath $ServerPath -PathType Container)) {
                throw 'Specify an existing RedM server root with -ServerPath.'
            }
            if (-not $PSCmdlet.ShouldProcess($ServerPath, "Recover update transaction $TransactionId")) { return }
            $result = Restore-PSBaseUpdateTransaction -TransactionId $TransactionId -ServerRoot $ServerPath
            Write-Host "Transaction $($result.TransactionId) recovery finished: $($result.Status)." -ForegroundColor Green
        }


        'profiles' {
            $profiles = @($catalog.profiles)
            if ($profiles.Count -eq 0) {
                Write-Host 'No installation profiles are published yet.'
            }
            else {
                $profiles | Select-Object id, name, description,
                    @{Name = 'PinnedResources'; Expression = { @($_.resources).Count }} |
                    Format-Table -AutoSize
            }
        }

        'menu' {
            Write-Host 'Pedro Scripts Base' -ForegroundColor Cyan
            Write-Host ''
            Write-Host '1. List catalog resources'
            Write-Host '2. Resolve an installation plan'
            Write-Host '3. Install resources'
            Write-Host '4. Exit'
            $choice = Read-Host 'Select an option'

            switch ($choice) {
                '1' {
                    & $PSCommandPath -Command list -CatalogPath $CatalogPath
                }
                '2' {
                    $available = @($catalog.resources | Where-Object { $_.installable })
                    if ($available.Count -eq 0) {
                        Write-Host 'No resources have verified releases available yet.' -ForegroundColor Yellow
                        break
                    }

                    $available | Select-Object id, name | Format-Table -AutoSize
                    $selected = Read-Host 'Enter resource IDs separated by commas'
                    $selectedIds = @($selected -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($selectedIds.Count -eq 0) {
                        Write-Host 'No resources selected.'
                        break
                    }

                    $selectedVersion = Read-Host 'Optional exact version (press Enter for latest stable)'
                    $planParameters = @{ Catalog = $catalog; ResourceIds = $selectedIds }
                    if (-not [string]::IsNullOrWhiteSpace($selectedVersion)) {
                        $planParameters.Version = $selectedVersion.Trim()
                    }

                    $plan = Resolve-PSBaseInstallPlan @planParameters
                    Write-Host 'Resolved installation plan:' -ForegroundColor Cyan
                    $plan | Format-Table Id, Version, Name -AutoSize
                    Write-Host 'Planning only. No files have been changed.' -ForegroundColor Yellow
                }
                '3' {
                    $available = @($catalog.resources | Where-Object { $_.installable })
                    if ($available.Count -eq 0) {
                        Write-Host 'No resources have verified releases available yet.' -ForegroundColor Yellow
                        break
                    }

                    $available | Select-Object id, name | Format-Table -AutoSize
                    $selected = Read-Host 'Enter resource IDs separated by commas'
                    $selectedIds = @($selected -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($selectedIds.Count -eq 0) {
                        Write-Host 'No resources selected.'
                        break
                    }

                    $selectedServer = Read-Host 'Enter the RedM server root directory'
                    $selectedVersion = Read-Host 'Optional exact version (press Enter for latest stable)'
                    $installParameters = @{
                        Command = 'install'
                        Resource = $selectedIds
                        ServerPath = $selectedServer
                        Confirm = $true
                    }
                    if (-not [string]::IsNullOrWhiteSpace($selectedVersion)) {
                        $installParameters.Version = $selectedVersion.Trim()
                    }
                    if (-not [string]::IsNullOrWhiteSpace($CatalogPath)) {
                        $installParameters.CatalogPath = $CatalogPath
                    }

                    & $PSCommandPath @installParameters
                }
                default {
                    Write-Host 'No changes made.'
                }
            }
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
