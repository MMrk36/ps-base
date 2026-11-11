Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Auth.psm1') -Force

function Get-PSBaseGitHubAssetContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Token
    )

    $currentUri = [uri]$Url
    if ($currentUri.Scheme -ne 'https' -or $currentUri.Host -ine 'api.github.com') {
        throw 'Release metadata assets must be downloaded from the GitHub API over HTTPS.'
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $currentUri)
            try {
                if ($currentUri.Host -ieq 'api.github.com') {
                    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
                    $request.Headers.Accept.ParseAdd('application/octet-stream')
                    $request.Headers.Add('X-GitHub-Api-Version', '2022-11-28')
                }

                $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try {
                    if ($response.StatusCode -in @(
                        [System.Net.HttpStatusCode]::MovedPermanently,
                        [System.Net.HttpStatusCode]::Found,
                        [System.Net.HttpStatusCode]::SeeOther,
                        [System.Net.HttpStatusCode]::TemporaryRedirect,
                        [System.Net.HttpStatusCode]::PermanentRedirect
                    )) {
                        $location = $response.Headers.Location
                        if ($null -eq $location) { throw 'GitHub returned an asset redirect without a destination.' }
                        $nextUri = if ($location.IsAbsoluteUri) { $location } else { [uri]::new($currentUri, $location) }
                        if ($nextUri.Scheme -ne 'https' -or $nextUri.Host -notin @('api.github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com')) {
                            throw 'GitHub returned an untrusted asset redirect.'
                        }
                        $currentUri = $nextUri
                        continue
                    }

                    if (-not $response.IsSuccessStatusCode) {
                        $status = [int]$response.StatusCode
                        $hostName = $currentUri.Host
                        $path = $currentUri.AbsolutePath
                        $requestId = $response.Headers.GetValues('X-GitHub-Request-Id') -join ','
                        $detail = ''

                        if ($hostName -ieq 'api.github.com') {
                            try {
                                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                                if (-not [string]::IsNullOrWhiteSpace($body)) {
                                    $detail = ($body -replace '[\r\n\t]+', ' ').Trim()
                                    if ($detail.Length -gt 1000) { $detail = $detail.Substring(0, 1000) }
                                }
                            }
                            catch { $detail = 'The response body could not be read.' }
                        }

                        $message = "Could not download GitHub release metadata asset (HTTP $status) from $hostName$path."
                        if (-not [string]::IsNullOrWhiteSpace($requestId)) { $message += " GitHub request ID: $requestId." }
                        if (-not [string]::IsNullOrWhiteSpace($detail)) { $message += " GitHub response: $detail" }
                        elseif ($hostName -ine 'api.github.com') { $message += ' The failure occurred after redirecting to the release asset host; the signed URL query was intentionally omitted.' }
                        throw $message
                    }

                    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    return [System.Text.Encoding]::UTF8.GetString($bytes)
                }
                finally { $response.Dispose() }
            }
            finally { $request.Dispose() }
        }
        throw 'GitHub asset download exceeded the redirect limit.'
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function ConvertTo-PSBaseReleaseEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GitHubRelease,
        [Parameter(Mandatory)]$Metadata,
        [Parameter(Mandatory)][string]$ChecksumText
    )

    $tag = [string]$GitHubRelease.tag_name
    if ($tag -notmatch '^v?([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)$') {
        throw "Release tag '$tag' is not a supported semantic version tag."
    }
    $tagVersion = $Matches[1]

    if ($Metadata.schemaVersion -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$Metadata.id) -or
        [string]::IsNullOrWhiteSpace([string]$Metadata.version) -or
        $Metadata.version -cne $tagVersion -or
        $Metadata.id -notmatch '^[a-z0-9][a-z0-9_-]*$') {
        throw "Release '$tag' has invalid or mismatched PS Base metadata."
    }

    if ($Metadata.status -notin @('preview', 'stable')) {
        throw "Release '$tag' has an unsupported status '$($Metadata.status)'."
    }

    $hash = ($ChecksumText -split '\s+', 2)[0].Trim().ToLowerInvariant()
    if ($hash -notmatch '^[a-f0-9]{64}$') {
        throw "Release '$tag' has an invalid SHA-256 sidecar."
    }

    if ($GitHubRelease.prerelease -ne ($Metadata.status -eq 'preview')) {
        throw "Release '$tag' prerelease flag does not match its PS Base status."
    }

    $zipName = "$($Metadata.id)-$tag.zip"
    $zipAsset = @($GitHubRelease.assets | Where-Object { $_.name -ceq $zipName }) | Select-Object -First 1
    if ($null -eq $zipAsset -or $zipAsset.url -notmatch '^https://api\.github\.com/repos/[^/]+/[^/]+/releases/assets/[0-9]+$') {
        throw "Release '$tag' is missing the expected ZIP asset '$zipName'."
    }

    $entry = [ordered]@{
        version = [string]$Metadata.version
        tag = $tag
        status = [string]$Metadata.status
        asset = $zipName
        url = [string]$zipAsset.url
        sha256 = $hash
        dependencies = @($Metadata.dependencies)
    }

    foreach ($field in @('apiVersion', 'psCoreApi', 'minimumArtifact', 'releaseNotes', 'license')) {
        if ($null -ne $Metadata.PSObject.Properties[$field]) {
            $entry[$field] = $Metadata.$field
        }
    }

    return $entry
}

function Update-PSBaseCatalogFromGitHub {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$CatalogPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'catalog/resources.json'),
        [string]$Token = (Get-PSBaseGitHubToken)
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'A GitHub token with read access to every catalog resource repository is required.'
    }
    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        throw "Catalog not found: $CatalogPath"
    }

    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    if ($catalog.schemaVersion -ne 1 -or $catalog.resources -isnot [System.Array]) {
        throw 'The existing catalog has an unsupported structure.'
    }

    $headers = @{
        Authorization = "Bearer $Token"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'PedroScripts-PSBase'
    }

    foreach ($resource in $catalog.resources) {
        $endpoint = "https://api.github.com/repos/$($resource.repository)/releases?per_page=100"
        try {
            $githubReleases = @(Invoke-RestMethod -Method Get -Uri $endpoint -Headers $headers -ErrorAction Stop)
        }
        catch {
            throw "Could not read releases for '$($resource.id)'. Check repository access. $($_.Exception.Message)"
        }

        $entries = [System.Collections.Generic.List[object]]::new()
        $latestMetadata = $null

        foreach ($release in ($githubReleases | Sort-Object published_at -Descending)) {
            if ($release.draft) { continue }
            if ($release.tag_name -notmatch '^v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') { continue }

            $metadataAsset = @($release.assets | Where-Object { $_.name -ceq 'ps-base-release.json' }) | Select-Object -First 1
            $checksumAsset = @($release.assets | Where-Object { $_.name -ceq "$($resource.id)-$($release.tag_name).zip.sha256" }) | Select-Object -First 1
            if ($null -eq $metadataAsset -or $null -eq $checksumAsset) {
                throw "Release '$($resource.id)@$($release.tag_name)' is missing its metadata or checksum asset."
            }

            $metadataText = Get-PSBaseGitHubAssetContent -Url $metadataAsset.url -Token $Token
            $checksumText = Get-PSBaseGitHubAssetContent -Url $checksumAsset.url -Token $Token
            try { $metadata = $metadataText | ConvertFrom-Json }
            catch { throw "Release '$($resource.id)@$($release.tag_name)' has invalid metadata JSON." }

            if ($metadata.id -cne $resource.id) {
                throw "Release '$($resource.id)@$($release.tag_name)' identifies itself as '$($metadata.id)'."
            }

            $entry = ConvertTo-PSBaseReleaseEntry -GitHubRelease $release -Metadata $metadata -ChecksumText $checksumText
            $entries.Add($entry)
            if ($null -eq $latestMetadata) { $latestMetadata = $metadata }
        }

        if ($entries.Count -gt 0) {
            $resource.status = [string]$latestMetadata.status
            $resource.installable = $true
            $resource.releases = $entries.ToArray()
            if ($null -ne $latestMetadata.PSObject.Properties['filePolicies']) {
                $resource | Add-Member -NotePropertyName filePolicies -NotePropertyValue $latestMetadata.filePolicies -Force
            }
            if ($null -ne $latestMetadata.PSObject.Properties['preservePaths']) {
                $resource | Add-Member -NotePropertyName preservePaths -NotePropertyValue $latestMetadata.preservePaths -Force
            }
        }
        else {
            $resource.status = 'development'
            $resource.installable = $false
            $resource.releases = @()
        }
    }

    $temporary = "$CatalogPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $catalog | ConvertTo-Json -Depth 50
        [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
        Import-Module (Join-Path $PSScriptRoot 'Catalog.psm1') -Force
        Get-PSBaseCatalog -Path $temporary | Out-Null

        if ($PSCmdlet.ShouldProcess($CatalogPath, 'Replace catalog with verified GitHub release metadata')) {
            Move-Item -LiteralPath $temporary -Destination $CatalogPath -Force
        }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Resources = $catalog.resources.Count
        Installable = @($catalog.resources | Where-Object { $_.installable }).Count
        Releases = @($catalog.resources | ForEach-Object { @($_.releases).Count } | Measure-Object -Sum).Sum
    }
}

Export-ModuleMember -Function ConvertTo-PSBaseReleaseEntry, Update-PSBaseCatalogFromGitHub
