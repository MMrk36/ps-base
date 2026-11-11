Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Update.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BackupManager.psm1') -Force

function Save-PSBaseTransaction {
    param([string]$Path, $Transaction)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, ($Transaction | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PSBaseUpdateTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$PreparedItems,
        [Parameter(Mandatory)][string]$ServerRoot
    )

    $server = [System.IO.Path]::GetFullPath($ServerRoot)
    $transactionId = [guid]::NewGuid().ToString('N')
    $journalPath = Join-Path $server (".ps-base/transactions/" + $transactionId + '.json')
    $resources = [System.Collections.Generic.List[object]]::new()

    foreach ($prepared in $PreparedItems) {
        $resources.Add(@{
            resourceId = $prepared.Item.Id
            version = $prepared.Item.Version
            state = 'pending'
            backupId = $null
            changes = 0
        })
    }

    $transaction = [ordered]@{
        schemaVersion = 1
        transactionId = $transactionId
        startedAt = [DateTime]::UtcNow.ToString('o')
        updatedAt = [DateTime]::UtcNow.ToString('o')
        status = 'applying'
        resources = $resources.ToArray()
    }

    Save-PSBaseTransaction -Path $journalPath -Transaction $transaction
    $results = [System.Collections.Generic.List[object]]::new()

    try {
        for ($index = 0; $index -lt $PreparedItems.Count; $index++) {
            $prepared = $PreparedItems[$index]
            $record = $transaction.resources[$index]

            if (@($prepared.FilePlan | Where-Object { $_.Action -ne 'Keep' }).Count -eq 0) {
                $record.state = 'no-change'
                Save-PSBaseTransaction -Path $journalPath -Transaction $transaction
                continue
            }

            $backup = New-PSBaseBackup -ResourceId $prepared.Item.Id -ServerRoot $server -InstalledPath $prepared.TargetPath -Reason 'transaction'
            $record.backupId = $backup.BackupId
            $record.state = 'prepared'
            $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-PSBaseTransaction -Path $journalPath -Transaction $transaction

            $result = Invoke-PSBaseResourceUpdate -PlanItem $prepared.Item -StagedPath $prepared.StagePath -ServerRoot $server -InstalledPath $prepared.TargetPath -FilePolicies $prepared.Policies -Backup $backup -Confirm:$false
            $record.state = 'updated'
            $record.changes = $result.Changes
            $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
            Save-PSBaseTransaction -Path $journalPath -Transaction $transaction
            $results.Add($result)
        }

        $transaction.status = 'completed'
        $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-PSBaseTransaction -Path $journalPath -Transaction $transaction

        return [pscustomobject]@{
            TransactionId = $transactionId
            JournalPath = $journalPath
            Status = $transaction.status
            Results = $results.ToArray()
        }
    }
    catch {
        $originalError = $_.Exception.Message
        $transaction.status = 'rolling-back'
        $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
        try { Save-PSBaseTransaction -Path $journalPath -Transaction $transaction } catch { }

        $rollbackFailures = [System.Collections.Generic.List[string]]::new()
        for ($index = $PreparedItems.Count - 1; $index -ge 0; $index--) {
            $record = $transaction.resources[$index]
            if ($record.state -notin @('prepared', 'updated', 'rollback-failed') -or [string]::IsNullOrWhiteSpace([string]$record.backupId)) {
                continue
            }

            try {
                Restore-PSBaseBackup -BackupId $record.backupId -ServerRoot $server -Confirm:$false | Out-Null
                $record.state = 'rolled-back'
            }
            catch {
                $record.state = 'rollback-failed'
                $rollbackFailures.Add("$($record.resourceId): $($_.Exception.Message)")
            }

            $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
            try { Save-PSBaseTransaction -Path $journalPath -Transaction $transaction } catch { }
        }

        $transaction.status = if ($rollbackFailures.Count -eq 0) { 'rolled-back' } else { 'rollback-failed' }
        $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
        try { Save-PSBaseTransaction -Path $journalPath -Transaction $transaction } catch { }

        if ($rollbackFailures.Count -gt 0) {
            throw "Update transaction '$transactionId' failed: $originalError. Automatic rollback also had failures: $($rollbackFailures -join '; '). Use the transaction recovery command and retained backups."
        }

        throw "Update transaction '$transactionId' failed and all previously applied resources were restored: $originalError"
    }
}

function Get-PSBaseTransactionList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerRoot)

    $directory = Join-Path ([System.IO.Path]::GetFullPath($ServerRoot)) '.ps-base/transactions'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return @()
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File) {
        try {
            $transaction = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        }
        catch {
            throw "Transaction journal '$($file.Name)' is invalid: $($_.Exception.Message)"
        }

        if ($transaction.schemaVersion -ne 1 -or
            $transaction.transactionId -notmatch '^[a-f0-9]{32}$' -or
            $transaction.transactionId -ne [System.IO.Path]::GetFileNameWithoutExtension($file.Name) -or
            $transaction.status -notin @('applying', 'rolling-back', 'completed', 'rolled-back', 'rollback-failed')) {
            throw "Transaction journal '$($file.Name)' has an unsupported structure."
        }

        $results.Add([pscustomobject]@{
            TransactionId = $transaction.transactionId
            Status = $transaction.status
            StartedAt = $transaction.startedAt
            UpdatedAt = $transaction.updatedAt
            JournalPath = $file.FullName
        })
    }

    return $results.ToArray()
}

function Restore-PSBaseUpdateTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][string]$ServerRoot
    )

    if ($TransactionId -notmatch '^[a-f0-9]{32}$') {
        throw 'Invalid transaction ID.'
    }

    $server = [System.IO.Path]::GetFullPath($ServerRoot)
    $journalPath = Join-Path $server (".ps-base/transactions/" + $TransactionId + '.json')
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw "Transaction '$TransactionId' was not found."
    }

    $transaction = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -AsHashtable
    if ($transaction.schemaVersion -ne 1 -or $transaction.transactionId -ne $TransactionId -or
        $transaction.status -notin @('applying', 'rolling-back', 'rollback-failed')) {
        throw 'Only incomplete or failed transactions can be recovered.'
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    $transaction.status = 'rolling-back'
    Save-PSBaseTransaction -Path $journalPath -Transaction $transaction

    for ($index = $transaction.resources.Count - 1; $index -ge 0; $index--) {
        $record = $transaction.resources[$index]
        if ($record.state -notin @('prepared', 'updated', 'rollback-failed') -or
            [string]::IsNullOrWhiteSpace([string]$record.backupId)) {
            continue
        }

        try {
            Restore-PSBaseBackup -BackupId $record.backupId -ServerRoot $server -Confirm:$false | Out-Null
            $record.state = 'rolled-back'
        }
        catch {
            $record.state = 'rollback-failed'
            $failures.Add("$($record.resourceId): $($_.Exception.Message)")
        }

        $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
        Save-PSBaseTransaction -Path $journalPath -Transaction $transaction
    }

    $transaction.status = if ($failures.Count -eq 0) { 'rolled-back' } else { 'rollback-failed' }
    $transaction.updatedAt = [DateTime]::UtcNow.ToString('o')
    Save-PSBaseTransaction -Path $journalPath -Transaction $transaction

    if ($failures.Count -gt 0) {
        throw "Transaction recovery failed for: $($failures -join '; ')"
    }

    return [pscustomobject]@{
        TransactionId = $TransactionId
        Status = $transaction.status
    }
}

Export-ModuleMember -Function Invoke-PSBaseUpdateTransaction, Get-PSBaseTransactionList, Restore-PSBaseUpdateTransaction
