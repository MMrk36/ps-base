[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/FileManifest.psm1') -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-manifest-tests-" + [guid]::NewGuid().ToString('N'))
$installed = Join-Path $testRoot 'installed'
$release = Join-Path $testRoot 'release'
New-Item -ItemType Directory -Path $installed -Force | Out-Null
New-Item -ItemType Directory -Path $release -Force | Out-Null

try {
    Set-Content -LiteralPath (Join-Path $installed 'unchanged.lua') -Value 'same' -NoNewline
    Set-Content -LiteralPath (Join-Path $installed 'modified.lua') -Value 'user edit' -NoNewline
    Set-Content -LiteralPath (Join-Path $installed 'removed.lua') -Value 'remove me' -NoNewline
    Set-Content -LiteralPath (Join-Path $installed 'preserved.lua') -Value 'local config' -NoNewline
    Set-Content -LiteralPath (Join-Path $installed 'user-created.lua') -Value 'user file' -NoNewline

    Set-Content -LiteralPath (Join-Path $release 'unchanged.lua') -Value 'updated' -NoNewline
    Set-Content -LiteralPath (Join-Path $release 'modified.lua') -Value 'upstream' -NoNewline
    Set-Content -LiteralPath (Join-Path $release 'preserved.lua') -Value 'default config' -NoNewline
    Set-Content -LiteralPath (Join-Path $release 'new.lua') -Value 'new upstream file' -NoNewline

    $old = Get-PSBaseFileManifest -Root $installed
    $old.files['modified.lua'].sha256 = (Get-FileHash (Join-Path $installed 'modified.lua') -Algorithm SHA256).Hash.ToLowerInvariant()
    $old.files['preserved.lua'].policy = 'preserve'
    $old.files['removed.lua'].policy = 'managed'
    $old.files.Remove('user-created.lua')
    $old.files.Remove('unchanged.lua')
    $old.files.Remove('modified.lua')
    $old.files.Remove('preserved.lua')
    $old.files.Remove('removed.lua')

    $old = [ordered]@{
        schemaVersion = 1
        generatedAt = [DateTime]::UtcNow.ToString('o')
        files = [ordered]@{}
    }
    foreach ($name in @('unchanged.lua', 'modified.lua', 'removed.lua', 'preserved.lua')) {
        $path = Join-Path $installed $name
        $policy = if ($name -eq 'preserved.lua') { 'preserve' } else { 'managed' }
        $old.files[$name] = @{
            sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
            size = (Get-Item $path).Length
            policy = $policy
        }
    }

    $new = Get-PSBaseFileManifest -Root $release
    $plan = @(Get-PSBaseUpdatePlan -InstalledPath $installed -PreviousManifest $old -NewManifest $new)
    $byPath = @{}
    foreach ($item in $plan) { $byPath[$item.Path] = $item }

    if ($byPath['unchanged.lua'].Action -ne 'Replace') { throw 'Unmodified managed file was not scheduled for update.' }
    if ($byPath['modified.lua'].Action -ne 'Keep') { throw 'Locally modified file was not protected.' }
    if ($byPath['removed.lua'].Action -ne 'Delete') { throw 'Unmodified upstream-deleted file was not scheduled for deletion.' }
    if ($byPath['preserved.lua'].Action -ne 'Keep') { throw 'Preserve policy was not honored.' }
    if ($byPath['new.lua'].Action -ne 'Add') { throw 'New upstream file was not scheduled for addition.' }
    if ($byPath['user-created.lua'].Action -ne 'Keep') { throw 'Untracked user file was not protected.' }

    $manifestPath = Join-Path $testRoot '.ps-base/manifests/test.json'
    Save-PSBaseFileManifest -Manifest $new -Path $manifestPath
    $loaded = Read-PSBaseFileManifest -Path $manifestPath
    if ($loaded.files['new.lua'].sha256 -ne $new.files['new.lua'].sha256) {
        throw 'Manifest persistence did not preserve file hashes.'
    }

    Write-Host '[PASS] Update planner protects locally modified and untracked files.'
    Write-Host '[PASS] Managed additions, replacements and upstream deletions are classified.'
    Write-Host '[PASS] Preserve policies and atomic manifest persistence.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
