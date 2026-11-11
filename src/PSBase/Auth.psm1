Set-StrictMode -Version Latest

function Get-PSBaseCredentialPath {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'PS Base credential storage requires a Windows user profile. Set PSBASE_GITHUB_TOKEN for a temporary session instead.'
    }

    $directory = Join-Path $env:LOCALAPPDATA 'PedroScripts/PSBase'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    return Join-Path $directory 'github-token.dpapi'
}

function Set-PSBaseGitHubToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Security.SecureString]$Token)

    if ($Token.Length -lt 20) {
        throw 'The GitHub token is too short to be valid.'
    }

    $path = Get-PSBaseCredentialPath
    $encrypted = ConvertFrom-SecureString -SecureString $Token
    [System.IO.File]::WriteAllText($path, $encrypted, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function Get-PSBaseGitHubToken {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:PSBASE_GITHUB_TOKEN)) {
        return $env:PSBASE_GITHUB_TOKEN
    }

    $path = Get-PSBaseCredentialPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $encrypted = Get-Content -LiteralPath $path -Raw
    if ([string]::IsNullOrWhiteSpace($encrypted)) {
        throw 'The saved GitHub credential is empty. Remove it and sign in again.'
    }

    $secure = ConvertTo-SecureString -String $encrypted
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
        $secure.Dispose()
    }
}

function Clear-PSBaseGitHubToken {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $path = Get-PSBaseCredentialPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ($PSCmdlet.ShouldProcess($path, 'Remove saved GitHub credential')) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

Export-ModuleMember -Function Set-PSBaseGitHubToken, Get-PSBaseGitHubToken, Clear-PSBaseGitHubToken
