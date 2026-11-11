[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('menu', 'list', 'plan', 'install')]
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

Import-Module $resolverModule -Force
Import-Module $catalogModule -Force
Import-Module $artifactModule -Force
Import-Module $installerModule -Force

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
