Set-StrictMode -Version Latest

function Get-PSBaseRelativeFilePath {
    param([string]$Root, [string]$Path)

    $relative = [System.IO.Path]::GetRelativePath($Root, $Path).Replace('\\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or
        $relative -match '(^|/)\.\.?(/|$)' -or $relative.Contains(':')) {
        throw "Unsafe relative file path '$relative'."
    }

    return $relative
}

function Get-PSBaseFileManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [object]$FilePolicies
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Manifest root does not exist: $Root"
    }

    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $files = [ordered]@{}

    foreach ($entry in Get-ChildItem -LiteralPath $rootPath -Recurse -Force) {
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Resource contains a reparse point or symbolic link: $($entry.FullName)"
        }
    }

    foreach ($file in Get-ChildItem -LiteralPath $rootPath -File -Recurse -Force) {

        $relative = Get-PSBaseRelativeFilePath -Root $rootPath -Path $file.FullName
        $policy = 'managed'

        if ($null -ne $FilePolicies) {
            if ($FilePolicies.default) {
                $policy = [string]$FilePolicies.default
            }

            $rules = @()
            if ($FilePolicies -is [System.Collections.IDictionary]) {
                if ($FilePolicies.Contains('rules')) { $rules = @($FilePolicies['rules']) }
            }
            elseif ($null -ne $FilePolicies.PSObject.Properties['rules']) {
                $rules = @($FilePolicies.rules)
            }
            foreach ($rule in $rules) {
                if ([string]::IsNullOrWhiteSpace([string]$rule.pattern) -or
                    $rule.policy -notin @('managed', 'preserve', 'replace')) {
                    throw 'File policy rules require a pattern and a valid policy.'
                }

                $pattern = [string]$rule.pattern
                if ($relative -like $pattern) {
                    $policy = [string]$rule.policy
                }
            }
        }

        if ($policy -notin @('managed', 'preserve', 'replace')) {
            throw "Invalid file policy '$policy' for '$relative'."
        }

        $files[$relative] = [ordered]@{
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            size = [long]$file.Length
            policy = $policy
        }
    }

    return [ordered]@{
        schemaVersion = 1
        generatedAt = [DateTime]::UtcNow.ToString('o')
        files = $files
    }
}

function Save-PSBaseFileManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Path
    )

    if ($Manifest.schemaVersion -ne 1 -or $Manifest.files -isnot [System.Collections.IDictionary]) {
        throw 'Cannot save an invalid PS Base file manifest.'
    }

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Manifest | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Read-PSBaseFileManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Installed file manifest not found: $Path. A safe update cannot be planned without a baseline."
    }

    try {
        $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "Installed file manifest is invalid: $($_.Exception.Message)"
    }

    if ($manifest.schemaVersion -ne 1 -or $manifest.files -isnot [System.Collections.IDictionary]) {
        throw 'Installed file manifest has an unsupported structure.'
    }

    foreach ($entry in $manifest.files.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($entry.Key) -or
            $entry.Key.StartsWith('/') -or $entry.Key.Contains('\\') -or
            $entry.Key -match '(^|/)\.\.?(/|$)' -or $entry.Key.Contains(':') -or
            $entry.Value.sha256 -notmatch '^[a-f0-9]{64}$' -or
            $entry.Value.policy -notin @('managed', 'preserve', 'replace')) {
            throw "Installed file manifest contains an invalid entry '$($entry.Key)'."
        }
    }

    return $manifest
}

function Get-PSBaseUpdatePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstalledPath,
        [Parameter(Mandatory)]$PreviousManifest,
        [Parameter(Mandatory)]$NewManifest
    )

    if (-not (Test-Path -LiteralPath $InstalledPath -PathType Container)) {
        throw "Installed resource directory does not exist: $InstalledPath"
    }

    foreach ($manifest in @($PreviousManifest, $NewManifest)) {
        if ($manifest.schemaVersion -ne 1 -or $manifest.files -isnot [System.Collections.IDictionary]) {
            throw 'Update planning requires valid version 1 file manifests.'
        }
    }

    $root = [System.IO.Path]::GetFullPath($InstalledPath)
    foreach ($entry in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed resource contains a reparse point or symbolic link: $($entry.FullName)"
        }
    }

    $paths = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $PreviousManifest.files.Keys) { [void]$paths.Add([string]$path) }
    foreach ($path in $NewManifest.files.Keys) { [void]$paths.Add([string]$path) }

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in $paths) {
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or
            $relative.Contains('\\') -or $relative -match '(^|/)\.\.?(/|$)' -or $relative.Contains(':')) {
            throw "Unsafe path in update manifest: '$relative'."
        }

        $target = [System.IO.Path]::GetFullPath((Join-Path $root ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
        $prefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Update path escapes the installed resource: '$relative'."
        }

        $old = $PreviousManifest.files[$relative]
        $new = $NewManifest.files[$relative]
        $exists = Test-Path -LiteralPath $target -PathType Leaf
        $currentHash = if ($exists) { (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }

        $action = 'Keep'
        $reason = 'No change required.'
        $policy = 'managed'
        if (($null -ne $old -and $old.policy -eq 'preserve') -or ($null -ne $new -and $new.policy -eq 'preserve')) {
            $policy = 'preserve'
        }
        elseif ($null -ne $new) {
            $policy = [string]$new.policy
        }
        elseif ($null -ne $old) {
            $policy = [string]$old.policy
        }

        if ($null -eq $old -and $null -ne $new) {
            if ($exists) {
                $reason = 'An untracked local file already occupies this path.'
            }
            else {
                $action = 'Add'
                $reason = 'New upstream file.'
            }
        }
        elseif ($null -ne $old -and $null -eq $new) {
            if (-not $exists) {
                $reason = 'The previously managed file is already absent.'
            }
            elseif ($currentHash -ne $old.sha256) {
                $reason = 'Locally modified file removed upstream; local copy is protected.'
            }
            elseif ($policy -eq 'preserve') {
                $reason = 'Preserve policy prevents automatic deletion.'
            }
            else {
                $action = 'Delete'
                $reason = 'Unmodified file removed upstream.'
            }
        }
        elseif ($null -ne $old -and $null -ne $new) {
            if (-not $exists) {
                $reason = 'Locally deleted file; deletion is preserved.'
            }
            elseif ($currentHash -ne $old.sha256) {
                $reason = 'Local modification detected; local copy is protected.'
            }
            elseif ($policy -eq 'preserve') {
                $reason = 'Preserve policy prevents automatic replacement.'
            }
            elseif ($currentHash -ne $new.sha256) {
                $action = 'Replace'
                $reason = 'Unmodified managed file has an upstream update.'
            }
        }

        $plan.Add([pscustomobject]@{
            Path = $relative
            Action = $action
            Reason = $reason
            Policy = $policy
            CurrentHash = $currentHash
            PreviousHash = if ($null -ne $old) { $old.sha256 } else { $null }
            NewHash = if ($null -ne $new) { $new.sha256 } else { $null }
        })
    }

    return $plan.ToArray()
}

Export-ModuleMember -Function Get-PSBaseFileManifest, Save-PSBaseFileManifest, Read-PSBaseFileManifest, Get-PSBaseUpdatePlan
