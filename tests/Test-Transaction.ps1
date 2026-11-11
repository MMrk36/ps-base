[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/Transaction.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/BackupManager.psm1') -Force
Import-Module (Join-Path $root 'src/PSBase/FileManifest.psm1') -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-transaction-tests-" + [guid]::NewGuid().ToString('N'))
$server = Join-Path $testRoot 'server'
$resources = Join-Path $server 'resources'
$one = Join-Path $resources 'ps-one'
$two = Join-Path $resources 'ps-two'
$stageOne = Join-Path $testRoot 'stage-one'
$stageTwo = Join-Path $testRoot 'stage-two'

foreach ($path in @($one, $two, $stageOne, $stageTwo)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

try {
    foreach ($path in @($one, $two)) {
        Set-Content -LiteralPath (Join-Path $path 'fxmanifest.lua') -Value 'old manifest' -NoNewline
        Set-Content -LiteralPath (Join-Path $path 'file.lua') -Value 'old content' -NoNewline
    }
    foreach ($path in @($stageOne, $stageTwo)) {
        Set-Content -LiteralPath (Join-Path $path 'fxmanifest.lua') -Value 'new manifest' -NoNewline
        Set-Content -LiteralPath (Join-Path $path 'file.lua') -Value 'new content' -NoNewline
    }

    $manifestOne = Get-PSBaseFileManifest -Root $one
    $manifestTwo = Get-PSBaseFileManifest -Root $two
    $manifestDirectory = Join-Path $server '.ps-base/manifests'
    Save-PSBaseFileManifest -Manifest $manifestOne -Path (Join-Path $manifestDirectory 'ps-one.json')
    Save-PSBaseFileManifest -Manifest $manifestTwo -Path (Join-Path $manifestDirectory 'ps-two.json')

    $lock = @{
        schemaVersion = 1
        installedResources = @{
            'ps-one' = @{ version = '1.0.0'; tag = 'v1.0.0'; sha256 = 'a' * 64; repository = 'MMrk36/ps-one'; installedPath = 'resources/ps-one'; installedAt = [DateTime]::UtcNow.ToString('o'); backupPath = $null }
            'ps-two' = @{ version = '1.0.0'; tag = 'v1.0.0'; sha256 = 'a' * 64; repository = 'MMrk36/ps-two'; installedPath = 'resources/ps-two'; installedAt = [DateTime]::UtcNow.ToString('o'); backupPath = $null }
        }
    }
    $lockDirectory = Join-Path $server '.ps-base'
    New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
    $lock | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $lockDirectory 'lock.json')

    $prepared = @(
        [pscustomobject]@{
            Item = [pscustomobject]@{ Id = 'ps-one'; Version = '2.0.0'; Tag = 'v2.0.0'; Sha256 = 'b' * 64; Repository = 'MMrk36/ps-one' }
            StagePath = $stageOne
            TargetPath = $one
            Policies = $null
            FilePlan = @([pscustomobject]@{ Action = 'Replace' })
        },
        [pscustomobject]@{
            Item = [pscustomobject]@{ Id = 'ps-two'; Version = '2.0.0'; Tag = 'v2.0.0'; Sha256 = 'b' * 64; Repository = 'MMrk36/ps-two' }
            StagePath = $stageTwo
            TargetPath = $two
            Policies = $null
            FilePlan = @([pscustomobject]@{ Action = 'Replace' })
        }
    )

    Set-Content -LiteralPath (Join-Path $manifestDirectory 'ps-two.json') -Value 'invalid manifest data'
    $failed = $false
    try {
        Invoke-PSBaseUpdateTransaction -PreparedItems $prepared -ServerRoot $server | Out-Null
    }
    catch {
        $failed = $_.Exception.Message -match 'restored'
    }
    if (-not $failed) { throw 'A failed multi-resource update did not report a completed rollback.' }
    if ((Get-Content (Join-Path $one 'file.lua') -Raw) -ne 'old content') { throw 'The first resource was not rolled back after the second failed.' }

    $lockAfterRollback = Get-Content (Join-Path $lockDirectory 'lock.json') -Raw | ConvertFrom-Json
    if ($lockAfterRollback.installedResources.'ps-one'.version -ne '1.0.0') { throw 'The first resource lock entry was not rolled back.' }

    $journals = @(Get-PSBaseTransactionList -ServerRoot $server)
    if (-not ($journals | Where-Object Status -eq 'rolled-back')) { throw 'The failed transaction journal was not marked rolled back.' }

    $recoveryBackup = New-PSBaseBackup -ResourceId 'ps-one' -ServerRoot $server -InstalledPath $one -Reason 'transaction'
    Set-Content -LiteralPath (Join-Path $one 'file.lua') -Value 'interrupted update' -NoNewline
    $recoveryId = [guid]::NewGuid().ToString('N')
    $journalDirectory = Join-Path $server '.ps-base/transactions'
    New-Item -ItemType Directory -Path $journalDirectory -Force | Out-Null
    $journal = @{
        schemaVersion = 1
        transactionId = $recoveryId
        startedAt = [DateTime]::UtcNow.ToString('o')
        updatedAt = [DateTime]::UtcNow.ToString('o')
        status = 'applying'
        resources = @(@{
            resourceId = 'ps-one'
            version = '2.0.0'
            state = 'prepared'
            backupId = $recoveryBackup.BackupId
            changes = 1
        })
    }
    $journal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $journalDirectory ($recoveryId + '.json'))

    $recovery = Restore-PSBaseUpdateTransaction -TransactionId $recoveryId -ServerRoot $server
    if ($recovery.Status -ne 'rolled-back') { throw 'Interrupted transaction recovery did not complete.' }
    if ((Get-Content (Join-Path $one 'file.lua') -Raw) -ne 'old content') { throw 'Interrupted transaction recovery did not restore the backup.' }

    Write-Host '[PASS] Multi-resource update transaction rolls back earlier resources after a later failure.'
    Write-Host '[PASS] Transaction journals record outcomes and recover interrupted updates.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
