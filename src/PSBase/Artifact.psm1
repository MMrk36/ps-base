Set-StrictMode -Version Latest

function Test-PSBaseArtifactChecksum {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Artifact file not found: $Path"
    }

    if ($Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'A valid SHA-256 checksum is required.'
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ine $Sha256) {
        throw "Artifact checksum mismatch. Expected $Sha256, received $actual."
    }

    return $true
}

function Get-PSBaseArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    if ($Release.url -notmatch '^https://') {
        throw 'Artifact downloads require an HTTPS URL.'
    }

    if ([string]::IsNullOrWhiteSpace($Release.asset) -or
        [System.IO.Path]::GetFileName($Release.asset) -ne $Release.asset -or
        $Release.asset -match '[\\/:]') {
        throw "Unsafe artifact file name '$($Release.asset)'."
    }

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }

    $destination = Join-Path $DestinationDirectory $Release.asset
    Invoke-WebRequest -Uri $Release.url -OutFile $destination -MaximumRedirection 5

    try {
        Test-PSBaseArtifactChecksum -Path $destination -Sha256 $Release.sha256 | Out-Null
    }
    catch {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw
    }

    return $destination
}

function Expand-PSBaseArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MaximumEntries = 5000,
        [long]$MaximumExpandedBytes = 1073741824
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Archive not found: $ArchivePath"
    }

    if ($MaximumEntries -lt 1 -or $MaximumExpandedBytes -lt 1) {
        throw 'Archive safety limits must be positive values.'
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container) -or
            @(Get-ChildItem -LiteralPath $DestinationPath -Force).Count -gt 0) {
            throw 'Extraction destination must be a new or empty directory.'
        }
    }
    else {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $destinationRoot = [System.IO.Path]::GetFullPath($DestinationPath)
    $destinationPrefix = $destinationRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $archiveStream = [System.IO.File]::OpenRead($ArchivePath)
    $archive = $null

    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $archiveStream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false
        )

        if ($archive.Entries.Count -gt $MaximumEntries) {
            throw "Archive contains more than $MaximumEntries entries."
        }

        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $expandedBytes = [long]0
        $hasManifest = $false

        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName

            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains([char]0) -or
                $name.Contains('\') -or $name.StartsWith('/') -or $name -match '^[A-Za-z]:') {
                throw "Archive contains an unsafe path '$name'."
            }

            $isDirectory = $name.EndsWith('/')
            $relativePath = $name.TrimEnd('/')
            $segments = $relativePath.Split('/')
            if ($segments.Count -eq 0 -or $segments -contains '.' -or $segments -contains '..' -or $relativePath.Contains(':')) {
                throw "Archive contains an unsafe path '$name'."
            }

            if (-not $seen.Add($relativePath)) {
                throw "Archive contains a duplicate path '$relativePath'."
            }

            $unixFileType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixFileType -eq 0xA000) {
                throw "Archive contains a symbolic link '$name'."
            }

            $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destinationRoot ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
            if (-not $targetPath.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escapes the extraction directory: '$name'."
            }

            if (-not $isDirectory) {
                $expandedBytes += $entry.Length
                if ($expandedBytes -gt $MaximumExpandedBytes) {
                    throw "Archive expands beyond the $MaximumExpandedBytes byte safety limit."
                }

                if ($relativePath -ieq 'fxmanifest.lua') {
                    $hasManifest = $true
                }
            }
        }

        if (-not $hasManifest) {
            throw 'Archive does not contain fxmanifest.lua at its root.'
        }

        foreach ($entry in $archive.Entries) {
            $relativePath = $entry.FullName.TrimEnd('/')
            $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destinationRoot ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))

            if ($entry.FullName.EndsWith('/')) {
                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                continue
            }

            $parent = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            $inputStream = $entry.Open()
            $outputStream = [System.IO.File]::Open(
                $targetPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

            try {
                $inputStream.CopyTo($outputStream)
            }
            finally {
                $outputStream.Dispose()
                $inputStream.Dispose()
            }
        }
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
        $archiveStream.Dispose()
    }

    return $DestinationPath
}

Export-ModuleMember -Function Test-PSBaseArtifactChecksum, Get-PSBaseArtifact, Expand-PSBaseArtifact
