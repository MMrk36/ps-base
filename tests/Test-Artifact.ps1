[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/PSBase/Artifact.psm1') -Force

Add-Type -AssemblyName System.IO.Compression

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-base-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function New-TestArchive {
    param(
        [string]$Path,
        [string[]]$Entries
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
    $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)

    try {
        foreach ($entryName in $Entries) {
            $entry = $zip.CreateEntry($entryName)
            $writer = [System.IO.StreamWriter]::new($entry.Open())
            try {
                $writer.Write('test')
            }
            finally {
                $writer.Dispose()
            }
        }
    }
    finally {
        $zip.Dispose()
        $stream.Dispose()
    }
}

try {
    $validArchive = Join-Path $testRoot 'valid.zip'
    $validDestination = Join-Path $testRoot 'valid'
    New-TestArchive -Path $validArchive -Entries @('fxmanifest.lua', 'client.lua', 'config/settings.lua')

    $hash = (Get-FileHash -LiteralPath $validArchive -Algorithm SHA256).Hash
    if (-not (Test-PSBaseArtifactChecksum -Path $validArchive -Sha256 $hash)) {
        throw 'Valid artifact checksum was not accepted.'
    }

    Expand-PSBaseArtifact -ArchivePath $validArchive -DestinationPath $validDestination | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $validDestination 'fxmanifest.lua'))) {
        throw 'The valid resource manifest was not extracted.'
    }

    $badChecksumRejected = $false
    try {
        Test-PSBaseArtifactChecksum -Path $validArchive -Sha256 ('0' * 64) | Out-Null
    }
    catch {
        $badChecksumRejected = $_.Exception.Message -match 'checksum mismatch'
    }

    if (-not $badChecksumRejected) {
        throw 'An invalid artifact checksum was not rejected.'
    }

    $unsafeArchive = Join-Path $testRoot 'unsafe.zip'
    $unsafeDestination = Join-Path $testRoot 'unsafe'
    New-TestArchive -Path $unsafeArchive -Entries @('fxmanifest.lua', '../outside.txt')

    $unsafeRejected = $false
    try {
        Expand-PSBaseArtifact -ArchivePath $unsafeArchive -DestinationPath $unsafeDestination | Out-Null
    }
    catch {
        $unsafeRejected = $_.Exception.Message -match 'unsafe path'
    }

    if (-not $unsafeRejected) {
        throw 'An archive path traversal entry was not rejected.'
    }

    if (Test-Path -LiteralPath (Join-Path $testRoot 'outside.txt')) {
        throw 'An unsafe archive entry was written outside the extraction directory.'
    }

    Write-Host '[PASS] Artifact SHA-256 verification.'
    Write-Host '[PASS] Safe ZIP extraction and resource manifest validation.'
    Write-Host '[PASS] ZIP path traversal rejection.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
