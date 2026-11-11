[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('menu', 'list', 'plan', 'install', 'update', 'status', 'uninstall')]
    [string]$Command = 'menu',

    [string[]]$Resource,

    [string]$Version,

    [string]$CatalogPath,

    [string]$ServerPath,

    [string]$ResourcesPath
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

Import-Module $resolverModule -Force
Import-Module $catalogModule -Force
Import-Module $artifactModule -Force
Import-Module $installerModule -Force
Import-Module $updateModule -Force
Import-Module $resourceManagementModule -Force
Import-Module $fileManifestModule -Force

try {
    $catalog = if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
        Get-PSBaseCatalog
    }
    else {
        Get-PSBaseCatalog -Path $CatalogPath
    }

    switch ($Command) {
        'list' {
            $catalog.resources |
                Sort-Object name |
                Select-Object id, name, status, installable,
                    @{Name = 'PublishedVersions'; Expression = { @($_.releases).Count }} |
                Format-Table -AutoSize
        }

        'plan' {
            if (-not $Resource -or $Resource.Count -eq 0) {
                throw 'Specify at least one resource with -Resource.'
            }

            $plan = Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds $Resource -Version $Version
            Write-Host 'Resolved installation plan:' -ForegroundColor Cyan
            $plan | Format-Table Id, Version, Name -AutoSize
            Write-Host 'No files have been downloaded or changed.' -ForegroundColor Yellow
        }

        'install' {
            if (-not $Resource -or $Resource.Count -eq 0) {
                throw 'Specify at least one resource with -Resource.'
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

            $plan = @(Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds $Resource -Version $Version)
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
            if (-not $Resource -or $Resource.Count -eq 0) {
                throw 'Specify at least one installed resource with -Resource.'
            }
            if ([string]::IsNullOrWhiteSpace($ServerPath) -or -not (Test-Path -LiteralPath $ServerPath -PathType Container)) {
                throw 'Specify an existing RedM server root with -ServerPath.'
            }

            $serverRoot = [System.IO.Path]::GetFullPath($ServerPath)
            $resourcesRoot = if ([string]::IsNullOrWhiteSpace($ResourcesPath)) { Join-Path $serverRoot 'resources' } else { [System.IO.Path]::GetFullPath($ResourcesPath) }
            if (-not (Test-Path -LiteralPath $resourcesRoot -PathType Container)) { throw "Resources directory does not exist: $resourcesRoot" }
            $plan = @(Resolve-PSBaseInstallPlan -Catalog $catalog -ResourceIds $Resource -Version $Version)
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

                foreach ($entry in $prepared) {
                    $result = Invoke-PSBaseResourceUpdate -PlanItem $entry.Item -StagedPath $entry.StagePath -ServerRoot $serverRoot -InstalledPath $entry.TargetPath -FilePolicies $entry.Policies -Confirm:$false
                    Write-Host "Updated $($entry.Item.Id) to $($entry.Item.Version). Applied $($result.Changes) file changes." -ForegroundColor Green
                    if ($result.Changes -eq 0) { Write-Host 'No file changes were necessary.' }
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
