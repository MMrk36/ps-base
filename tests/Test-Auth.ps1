[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/PSBase/Auth.psm1') -Force

if (-not $IsWindows) {
    Write-Host '[SKIP] DPAPI credential tests require Windows.'
    return
}

$previous = $env:PSBASE_GITHUB_TOKEN
$path = Join-Path $env:LOCALAPPDATA 'PedroScripts/PSBase/github-token.dpapi'
try {
    Remove-Item Env:PSBASE_GITHUB_TOKEN -ErrorAction SilentlyContinue
    Clear-PSBaseGitHubToken -Confirm:$false

    $expected = 'github-token-test-value-0123456789'
    $secure = ConvertTo-SecureString $expected -AsPlainText -Force
    Set-PSBaseGitHubToken -Token $secure | Out-Null
    $secure.Dispose()

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'The protected credential file was not created.'
    }
    $stored = Get-Content -LiteralPath $path -Raw
    if ($stored.Contains($expected)) {
        throw 'The credential file contains the plaintext token.'
    }
    if ((Get-PSBaseGitHubToken) -cne $expected) {
        throw 'The DPAPI credential did not round-trip.'
    }

    $env:PSBASE_GITHUB_TOKEN = 'environment-token-test'
    if ((Get-PSBaseGitHubToken) -cne $env:PSBASE_GITHUB_TOKEN) {
        throw 'The environment token did not take precedence.'
    }

    Remove-Item Env:PSBASE_GITHUB_TOKEN
    Clear-PSBaseGitHubToken -Confirm:$false
    if (Test-Path -LiteralPath $path) {
        throw 'The saved credential was not removed.'
    }

    Write-Host '[PASS] GitHub tokens are stored encrypted for the current Windows user.'
    Write-Host '[PASS] Environment credentials override saved credentials.'
    Write-Host '[PASS] Saved credentials can be cleared.'
}
finally {
    if ($null -ne $previous) { $env:PSBASE_GITHUB_TOKEN = $previous }
    else { Remove-Item Env:PSBASE_GITHUB_TOKEN -ErrorAction SilentlyContinue }
    Clear-PSBaseGitHubToken -Confirm:$false
}
