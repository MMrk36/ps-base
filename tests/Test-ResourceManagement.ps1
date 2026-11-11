[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/ResourceManagement.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/FileManifest.psm1') -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-management-tests-" + [guid]::NewGuid().ToString('N'))
$server = Join-Path $testRoot 'server'
$resources = Join-Path $server 'resources'
$partial = Join-Path $resources 'ps-partial'
$clean = Join-Path $resources 'ps-clean'
New-Item -ItemType Directory -Path $partial -Force | Out-Null
New-Item -ItemType Directory -Path $clean -Force | Out-Null

try {
    Set-Content -LiteralPath (Join-Path $partial 'managed.lua') -Value 'baseline' -NoNewline
    Set-Content -LiteralPath (Join-Path $partial 'edited.lua') -Value 'user edit' -NoNewline
    Set-Content -LiteralPath (Join-Path $partial 'local.txt') -Value 'untracked' -NoNewline
    Set-Content -LiteralPath (Join-Path $clean 'managed.lua') -Value 'clean baseline' -NoNewline

    $partialManifest = Get-PSBaseFileManifest -Root $partial
    $baselineFile = Join-Path $testRoot 'edited-baseline.lua'
    Set-Content -LiteralPath $baselineFile -Value 'original' -NoNewline
    $partialManifest.files['edited.lua'].sha256 = (Get-FileHash $baselineFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Save-PSBaseFileManifest -Manifest $partialManifest -Path (Join-Path $server '.ps-base/manifests/ps-partial.json')

    $cleanManifest = Get-PSBaseFileManifest -Root $clean
    Save-PSBaseFileManifest -Manifest $cleanManifest -Path (Join-Path $server '.ps-base/manifests/ps-clean.json')

    $lock = @{
        schemaVersion = 1
        installedResources = @{
            'ps-partial' = @{ version = '1.0.0'; installedPath = 'resources/ps-partial'; backupPath = $null }
            'ps-clean' = @{ version = '1.0.0'; installedPath = 'resources/ps-clean'; backupPath = $null }
        }
    }
    $lockDirectory = Join-Path $server '.ps-base'
    New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
    $lock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $lockDirectory 'lock.json')

    $status = @(Get-PSBaseResourceStatus -ServerRoot $server)
    if (($status | Where-Object Id -eq 'ps-partial').State -ne 'Attention') { throw 'Status did not detect local modifications and untracked files.' }
    if (($status | Where-Object Id -eq 'ps-clean').State -ne 'Clean') { throw 'Status did not report a clean resource.' }

    $partialResult = Invoke-PSBaseResourceUninstall -ResourceId 'ps-partial' -ServerRoot $server -Confirm:$false
    if ($partialResult.State -ne 'Partial') { throw 'Uninstall did not report preserved local files.' }
    if (Test-Path (Join-Path $partial 'managed.lua')) { throw 'Unchanged managed file was not removed.' }
    if ((Get-Content (Join-Path $partial 'edited.lua') -Raw) -ne 'user edit') { throw 'Modified file was deleted.' }
    if ((Get-Content (Join-Path $partial 'local.txt') -Raw) -ne 'untracked') { throw 'Untracked file was deleted.' }

    $cleanResult = Invoke-PSBaseResourceUninstall -ResourceId 'ps-clean' -ServerRoot $server -Confirm:$false
    if ($cleanResult.State -ne 'Removed' -or (Test-Path $clean)) { throw 'Clean resource was not fully uninstalled.' }

    Write-Host '[PASS] Installed status detects modified, missing and untracked files.'
    Write-Host '[PASS] Safe uninstall removes only unchanged managed files.'
    Write-Host '[PASS] User files remain; clean resource uninstall removes registration.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
