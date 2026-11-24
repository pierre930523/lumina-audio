<#
.SYNOPSIS
    Downloads, SHA256-verifies, and stages Lumina Audio's vendored Windows x64 runtime binaries
    (yt-dlp.exe, deno.exe, ffmpeg.exe) and generates the merged THIRD_PARTY_LICENSES.txt.

.DESCRIPTION
    Fetches official Windows x64 release artifacts from GitHub Releases:
      1. yt-dlp/yt-dlp        -> yt-dlp.exe + SHA2-256SUMS + LICENSE + THIRD_PARTY_LICENSES.txt
      2. denoland/deno        -> deno-x86_64-pc-windows-msvc.zip + .sha256sum + LICENSE.md
      3. BtbN/FFmpeg-Builds   -> official Windows x64 LGPL static zip + checksums.sha256 + LICENSE.txt
         (Note: yt-dlp/FFmpeg-Builds only publishes GPL builds; BtbN/FFmpeg-Builds provides the
          official upstream Windows x64 LGPL static builds required for LGPL compliance.)

    Every artifact is strictly verified against its official release SHA256 checksum before any file
    is placed into app/windows/vendor/bin/. Any missing checksum or hash mismatch aborts immediately
    with a non-zero exit code.

.PARAMETER YtDlpVersion
    yt-dlp GitHub release tag (default: "latest").

.PARAMETER DenoVersion
    Deno GitHub release tag (default: "latest", e.g. "v2.9.8").

.PARAMETER FfmpegVersion
    BtbN/FFmpeg-Builds GitHub release tag (default: "latest", e.g. "autobuild-2026-11-22-12-36").

.PARAMETER Force
    Re-download and re-stage all artifacts even when existing staged binaries already match
    the target release SHA256 checksums.
#>
[CmdletBinding()]
param(
    [string]$YtDlpVersion = "latest",
    [string]$DenoVersion = "latest",
    [string]$FfmpegVersion = "latest",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2+ on Windows PowerShell 5.1
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # Ignore on newer .NET runtimes that manage TLS automatically
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$VendorBinDir = Join-Path $RepoRoot 'app\windows\vendor\bin'
$CacheDir = Join-Path ([System.IO.Path]::GetTempPath()) 'lumina-audio-release-deps-cache'
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lumina-audio-deps-" + [System.Guid]::NewGuid().ToString('N'))

New-Item -ItemType Directory -Path $VendorBinDir -Force | Out-Null
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

$UserAgent = 'lumina-audio-prepare-release-deps'
$CurlCmd = Get-Command 'curl.exe' -ErrorAction SilentlyContinue

function Get-GitHubHeaders {
    $headers = @{
        'User-Agent' = $UserAgent
        'Accept'     = 'application/vnd.github+json'
    }
    $token = $env:GITHUB_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = $env:GH_TOKEN
    }
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers['Authorization'] = "Bearer $token"
    }
    return $headers
}

function Get-GitHubRelease {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Version
    )
    if ($Version -eq 'latest') {
        $uri = "https://api.github.com/repos/$Repo/releases/latest"
    } else {
        $uri = "https://api.github.com/repos/$Repo/releases/tags/$Version"
    }
    Write-Host "Querying GitHub Release: $Repo ($Version) ..." -ForegroundColor Cyan
    return Invoke-RestMethod -Uri $uri -Headers (Get-GitHubHeaders)
}

function Get-ReleaseAsset {
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$ExactName,
        [switch]$Optional
    )
    $asset = @($Release.assets | Where-Object { $_.name -eq $ExactName }) | Select-Object -First 1
    if ($null -eq $asset -and -not $Optional) {
        throw "Required release asset '$ExactName' not found in release '$($Release.tag_name)' ($($Release.html_url))."
    }
    return $asset
}

function Get-RemoteUtf8Text {
    param([Parameter(Mandatory)][string]$Url)
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent }
        if ($resp.Content -is [byte[]]) {
            $text = [System.Text.Encoding]::UTF8.GetString($resp.Content)
        } else {
            $text = [string]$resp.Content
        }
        # Strip UTF-8 BOM if present
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            $text = $text.Substring(1)
        }
        return $text
    } finally {
        $ProgressPreference = $prevProgress
    }
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )
    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force
    }
    Write-Host "  Downloading: $Url"
    if ($null -ne $CurlCmd) {
        & $CurlCmd.Source -fsSL --retry 3 --retry-delay 2 --connect-timeout 30 -A $UserAgent -o $OutFile $Url
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
            throw "curl.exe failed with exit code $LASTEXITCODE while downloading $Url"
        }
    } else {
        $prevProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent }
        } finally {
            $ProgressPreference = $prevProgress
        }
    }
    if (-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -le 0) {
        throw "Downloaded file is missing or empty: $OutFile"
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string]$FilePath)
    return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-ValidSha256String {
    param(
        [Parameter(Mandatory)][string]$Hash,
        [Parameter(Mandatory)][string]$Context
    )
    if ($Hash -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Invalid or missing SHA256 checksum ($Context): '$Hash'"
    }
    return $Hash.ToLowerInvariant()
}

function Assert-FileSha256 {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Label,
        [bool]$DeleteOnMismatch = $true
    )
    $expected = Assert-ValidSha256String -Hash $ExpectedSha256 -Context $Label
    $actual = Get-Sha256Hex -FilePath $FilePath
    if ($actual -ne $expected) {
        if ($DeleteOnMismatch -and (Test-Path -LiteralPath $FilePath)) {
            Remove-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
        }
        throw "SHA256 verification FAILED for $Label!`n  Expected: $expected`n  Actual:   $actual"
    }
    Write-Host "  [SHA256 OK] $Label ($actual)" -ForegroundColor Green
    return $actual
}

function Assert-AssetDigestMatches {
    param(
        [Parameter(Mandatory)]$Asset,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Label
    )
    $digestProp = $Asset.PSObject.Properties['digest']
    if ($null -ne $digestProp -and -not [string]::IsNullOrWhiteSpace([string]$digestProp.Value)) {
        $digestVal = [string]$digestProp.Value
        if ($digestVal -match '^sha256:([0-9a-fA-F]{64})$') {
            $apiHash = $Matches[1].ToLowerInvariant()
            if ($apiHash -ne $ExpectedSha256.ToLowerInvariant()) {
                throw "Checksum file and GitHub API digest disagree for $Label! ChecksumFile=$ExpectedSha256 GitHubDigest=$apiHash"
            }
        }
    }
}

function Parse-ChecksumListEntry {
    param(
        [Parameter(Mandatory)][string]$ChecksumContent,
        [Parameter(Mandatory)][string]$FileName
    )
    $escaped = [regex]::Escape($FileName)
    foreach ($line in ($ChecksumContent -split "`r?`n")) {
        if ($line -match "^\s*([0-9a-fA-F]{64})\s+\*?(?:\./)?$escaped\s*$") {
            return $Matches[1].ToLowerInvariant()
        }
    }
    throw "Official SHA256 checksum entry for '$FileName' was not found in checksum file."
}

function Parse-SingleChecksumFile {
    param(
        [Parameter(Mandatory)][string]$ChecksumContent,
        [Parameter(Mandatory)][string]$Context
    )
    # Handle PowerShell Get-FileHash | Format-List output (used by denoland/deno Windows assets):
    #   Algorithm : SHA256
    #   Hash      : <64-hex>
    if ($ChecksumContent -match '(?mi)^\s*Hash\s*:\s*([0-9a-fA-F]{64})\s*$') {
        return $Matches[1].ToLowerInvariant()
    }
    # Handle standard GNU sha256sum output:
    #   <64-hex>  <filename>
    if ($ChecksumContent -match '(?m)^\s*([0-9a-fA-F]{64})(?:\s|$)') {
        return $Matches[1].ToLowerInvariant()
    }
    throw "Unable to parse official SHA256 checksum from $Context."
}

function Extract-ZipEntryToFile {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchiveEntry]$Entry,
        [Parameter(Mandatory)][string]$DestinationPath
    )
    $inStream = $Entry.Open()
    try {
        $outStream = [System.IO.File]::Create($DestinationPath)
        try {
            $inStream.CopyTo($outStream)
        } finally {
            $outStream.Dispose()
        }
    } finally {
        $inStream.Dispose()
    }
}

function Read-ZipEntryUtf8Text {
    param([Parameter(Mandatory)][System.IO.Compression.ZipArchiveEntry]$Entry)
    $stream = $Entry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        try {
            $text = $reader.ReadToEnd()
            if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
                $text = $text.Substring(1)
            }
            return $text
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

try {
    Write-Host "=== Lumina Audio: Prepare Windows Release Runtime Dependencies ===" -ForegroundColor Yellow
    Write-Host "Repo root  : $RepoRoot"
    Write-Host "Vendor dir : $VendorBinDir"
    Write-Host ""

    # -------------------------------------------------------------------------
    # 1. yt-dlp (yt-dlp/yt-dlp)
    # -------------------------------------------------------------------------
    $ytRelease = Get-GitHubRelease -Repo 'yt-dlp/yt-dlp' -Version $YtDlpVersion
    $ytTag = [string]$ytRelease.tag_name
    $ytExeAsset = Get-ReleaseAsset -Release $ytRelease -ExactName 'yt-dlp.exe'
    $ytSumsAsset = Get-ReleaseAsset -Release $ytRelease -ExactName 'SHA2-256SUMS'
    $ytThirdPartyAsset = Get-ReleaseAsset -Release $ytRelease -ExactName 'THIRD_PARTY_LICENSES.txt' -Optional

    $ytSumsText = Get-RemoteUtf8Text -Url $ytSumsAsset.browser_download_url
    $ytExpectedSha = Parse-ChecksumListEntry -ChecksumContent $ytSumsText -FileName 'yt-dlp.exe'
    Assert-AssetDigestMatches -Asset $ytExeAsset -ExpectedSha256 $ytExpectedSha -Label 'yt-dlp.exe'

    $ytDestPath = Join-Path $VendorBinDir 'yt-dlp.exe'
    $ytNeedDownload = $true
    if (-not $Force -and (Test-Path -LiteralPath $ytDestPath)) {
        $existingSha = Get-Sha256Hex -FilePath $ytDestPath
        if ($existingSha -eq $ytExpectedSha) {
            Write-Host "  [UP TO DATE] yt-dlp.exe ($ytTag) already matches official SHA256 ($existingSha)" -ForegroundColor Green
            $ytNeedDownload = $false
        }
    }
    if ($ytNeedDownload) {
        $ytTmpPath = Join-Path $TempDir 'yt-dlp.exe.tmp'
        Invoke-FileDownload -Url $ytExeAsset.browser_download_url -OutFile $ytTmpPath
        Assert-FileSha256 -FilePath $ytTmpPath -ExpectedSha256 $ytExpectedSha -Label "yt-dlp.exe ($ytTag)" | Out-Null
        Move-Item -LiteralPath $ytTmpPath -Destination $ytDestPath -Force
    }

    $ytUnlicenseText = Get-RemoteUtf8Text -Url "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$ytTag/LICENSE"
    if ($null -ne $ytThirdPartyAsset) {
        $ytThirdPartyText = Get-RemoteUtf8Text -Url $ytThirdPartyAsset.browser_download_url
    } else {
        $ytThirdPartyText = Get-RemoteUtf8Text -Url "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$ytTag/THIRD_PARTY_LICENSES.txt"
    }
    if ([string]::IsNullOrWhiteSpace($ytUnlicenseText) -or [string]::IsNullOrWhiteSpace($ytThirdPartyText)) {
        throw "Failed to retrieve yt-dlp license texts for tag $ytTag."
    }

    # -------------------------------------------------------------------------
    # 2. Deno (denoland/deno)
    # -------------------------------------------------------------------------
    $denoRelease = Get-GitHubRelease -Repo 'denoland/deno' -Version $DenoVersion
    $denoTag = [string]$denoRelease.tag_name
    $denoZipName = 'deno-x86_64-pc-windows-msvc.zip'
    $denoZipAsset = Get-ReleaseAsset -Release $denoRelease -ExactName $denoZipName
    $denoZipSumAsset = Get-ReleaseAsset -Release $denoRelease -ExactName "$denoZipName.sha256sum"
    $denoBinSumAsset = Get-ReleaseAsset -Release $denoRelease -ExactName 'deno-x86_64-pc-windows-msvc.sha256sum' -Optional

    $denoZipSumText = Get-RemoteUtf8Text -Url $denoZipSumAsset.browser_download_url
    $denoExpectedZipSha = Parse-SingleChecksumFile -ChecksumContent $denoZipSumText -Context "$denoZipName.sha256sum"
    Assert-AssetDigestMatches -Asset $denoZipAsset -ExpectedSha256 $denoExpectedZipSha -Label $denoZipName

    $denoExpectedExeSha = $null
    if ($null -ne $denoBinSumAsset) {
        $denoBinSumText = Get-RemoteUtf8Text -Url $denoBinSumAsset.browser_download_url
        $denoExpectedExeSha = Parse-SingleChecksumFile -ChecksumContent $denoBinSumText -Context 'deno-x86_64-pc-windows-msvc.sha256sum'
    }

    $denoDestPath = Join-Path $VendorBinDir 'deno.exe'
    $denoLicenseText = $null
    $denoNeedDownload = $true

    if (-not $Force -and (Test-Path -LiteralPath $denoDestPath) -and -not [string]::IsNullOrWhiteSpace($denoExpectedExeSha)) {
        $existingDenoSha = Get-Sha256Hex -FilePath $denoDestPath
        if ($existingDenoSha -eq $denoExpectedExeSha) {
            Write-Host "  [UP TO DATE] deno.exe ($denoTag) already matches official binary SHA256 ($existingDenoSha)" -ForegroundColor Green
            $denoNeedDownload = $false
        }
    }

    if ($denoNeedDownload) {
        $denoZipTmp = Join-Path $TempDir $denoZipName
        Invoke-FileDownload -Url $denoZipAsset.browser_download_url -OutFile $denoZipTmp
        Assert-FileSha256 -FilePath $denoZipTmp -ExpectedSha256 $denoExpectedZipSha -Label "$denoZipName ($denoTag)" | Out-Null

        $denoExeTmp = Join-Path $TempDir 'deno.exe.tmp'
        $zip = [System.IO.Compression.ZipFile]::OpenRead($denoZipTmp)
        try {
            $denoEntry = @($zip.Entries | Where-Object { $_.Name -ieq 'deno.exe' }) | Select-Object -First 1
            if ($null -eq $denoEntry) {
                throw "deno.exe not found inside $denoZipName"
            }
            Extract-ZipEntryToFile -Entry $denoEntry -DestinationPath $denoExeTmp

            $licEntry = @($zip.Entries | Where-Object { $_.Name -imatch '^LICENSE(\.md|\.txt)?$' }) | Select-Object -First 1
            if ($null -ne $licEntry) {
                $denoLicenseText = Read-ZipEntryUtf8Text -Entry $licEntry
            }
        } finally {
            $zip.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($denoExpectedExeSha)) {
            Assert-FileSha256 -FilePath $denoExeTmp -ExpectedSha256 $denoExpectedExeSha -Label "deno.exe ($denoTag)" | Out-Null
        }
        Move-Item -LiteralPath $denoExeTmp -Destination $denoDestPath -Force
    }

    if ([string]::IsNullOrWhiteSpace($denoLicenseText)) {
        $denoLicenseText = Get-RemoteUtf8Text -Url "https://raw.githubusercontent.com/denoland/deno/$denoTag/LICENSE.md"
    }
    if ([string]::IsNullOrWhiteSpace($denoLicenseText)) {
        throw "Failed to retrieve Deno MIT LICENSE.md for tag $denoTag."
    }
    $denoFinalExeSha = Get-Sha256Hex -FilePath $denoDestPath

    # -------------------------------------------------------------------------
    # 3. FFmpeg Windows x64 LGPL Static Build (BtbN/FFmpeg-Builds)
    # -------------------------------------------------------------------------
    # Note: yt-dlp/FFmpeg-Builds only publishes GPL builds. We use the official
    # upstream BtbN/FFmpeg-Builds repository for Windows x64 LGPL static builds.
    $ffmpegRepo = 'BtbN/FFmpeg-Builds'
    $ffmpegRelease = Get-GitHubRelease -Repo $ffmpegRepo -Version $FfmpegVersion
    $ffmpegTag = [string]$ffmpegRelease.tag_name
    $ffmpegReleaseName = [string]$ffmpegRelease.name

    $ffmpegZipAsset = Get-ReleaseAsset -Release $ffmpegRelease -ExactName 'ffmpeg-master-latest-win64-lgpl.zip' -Optional
    if ($null -eq $ffmpegZipAsset) {
        $ffmpegZipAsset = @($ffmpegRelease.assets | Where-Object {
            $_.name -match '^ffmpeg-(?!.*-shared).*-win64-lgpl\.zip$'
        }) | Select-Object -First 1
    }
    if ($null -eq $ffmpegZipAsset) {
        $ffmpegZipAsset = @($ffmpegRelease.assets | Where-Object {
            $_.name -match '^ffmpeg-(?!.*-shared).*-win64-lgpl(?:-[0-9.]+)?\.zip$'
        }) | Select-Object -First 1
    }
    if ($null -eq $ffmpegZipAsset) {
        throw "No official Windows x64 LGPL static zip asset found in $ffmpegRepo release '$ffmpegTag'."
    }
    $ffmpegZipName = [string]$ffmpegZipAsset.name
    if ($ffmpegZipName -notmatch 'win64-lgpl' -or $ffmpegZipName -match '-shared' -or $ffmpegZipName -match '-gpl') {
        throw "Refusing non-LGPL-static FFmpeg asset: $ffmpegZipName"
    }

    $ffmpegSumsAsset = Get-ReleaseAsset -Release $ffmpegRelease -ExactName 'checksums.sha256'
    $ffmpegSumsText = Get-RemoteUtf8Text -Url $ffmpegSumsAsset.browser_download_url
    $ffmpegExpectedZipSha = Parse-ChecksumListEntry -ChecksumContent $ffmpegSumsText -FileName $ffmpegZipName
    Assert-AssetDigestMatches -Asset $ffmpegZipAsset -ExpectedSha256 $ffmpegExpectedZipSha -Label $ffmpegZipName

    $ffmpegDestPath = Join-Path $VendorBinDir 'ffmpeg.exe'
    $ffmpegStatePath = Join-Path $CacheDir 'ffmpeg-state.json'
    $ffmpegCachedLicensePath = Join-Path $CacheDir 'ffmpeg-LICENSE.txt'
    $ffmpegLicenseText = $null
    $ffmpegNeedDownload = $true

    if (-not $Force -and (Test-Path -LiteralPath $ffmpegDestPath) -and (Test-Path -LiteralPath $ffmpegStatePath) -and (Test-Path -LiteralPath $ffmpegCachedLicensePath)) {
        try {
            $state = Get-Content -LiteralPath $ffmpegStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existingFfmpegSha = Get-Sha256Hex -FilePath $ffmpegDestPath
            if ($state.zipSha256 -eq $ffmpegExpectedZipSha -and $state.ffmpegExeSha256 -eq $existingFfmpegSha) {
                $cachedLic = Get-Content -LiteralPath $ffmpegCachedLicensePath -Raw -Encoding UTF8
                if (-not [string]::IsNullOrWhiteSpace($cachedLic)) {
                    Write-Host "  [UP TO DATE] ffmpeg.exe ($ffmpegZipName) matches cached verified zip SHA256 ($ffmpegExpectedZipSha)" -ForegroundColor Green
                    $ffmpegLicenseText = $cachedLic
                    $ffmpegNeedDownload = $false
                }
            }
        } catch {
            # Ignore stale/corrupt cache metadata and re-download cleanly
        }
    }

    if ($ffmpegNeedDownload) {
        $ffmpegZipTmp = Join-Path $TempDir $ffmpegZipName
        Invoke-FileDownload -Url $ffmpegZipAsset.browser_download_url -OutFile $ffmpegZipTmp
        Assert-FileSha256 -FilePath $ffmpegZipTmp -ExpectedSha256 $ffmpegExpectedZipSha -Label "$ffmpegZipName ($ffmpegTag)" | Out-Null

        $ffmpegExeTmp = Join-Path $TempDir 'ffmpeg.exe.tmp'
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ffmpegZipTmp)
        try {
            # Extract ONLY ffmpeg.exe (never ffplay.exe or ffprobe.exe)
            $ffmpegEntry = @($zip.Entries | Where-Object { $_.FullName -imatch '(^|/)bin/ffmpeg\.exe$' }) | Select-Object -First 1
            if ($null -eq $ffmpegEntry) {
                $ffmpegEntry = @($zip.Entries | Where-Object { $_.Name -ieq 'ffmpeg.exe' }) | Select-Object -First 1
            }
            if ($null -eq $ffmpegEntry) {
                throw "ffmpeg.exe not found inside $ffmpegZipName"
            }
            Extract-ZipEntryToFile -Entry $ffmpegEntry -DestinationPath $ffmpegExeTmp

            $licEntry = @($zip.Entries | Where-Object { $_.Name -imatch '^(LICENSE(\.txt)?|COPYING\.LGPL.*)$' }) | Select-Object -First 1
            if ($null -ne $licEntry) {
                $ffmpegLicenseText = Read-ZipEntryUtf8Text -Entry $licEntry
            }
        } finally {
            $zip.Dispose()
        }

        if ([string]::IsNullOrWhiteSpace($ffmpegLicenseText)) {
            throw "LGPL license text was not found inside $ffmpegZipName."
        }

        Move-Item -LiteralPath $ffmpegExeTmp -Destination $ffmpegDestPath -Force
        $ffmpegExtractedSha = Get-Sha256Hex -FilePath $ffmpegDestPath

        [System.IO.File]::WriteAllText($ffmpegCachedLicensePath, $ffmpegLicenseText, (New-Object System.Text.UTF8Encoding($false)))
        $stateObj = [ordered]@{
            repo            = $ffmpegRepo
            tag             = $ffmpegTag
            releaseName     = $ffmpegReleaseName
            zipAssetName    = $ffmpegZipName
            zipSha256       = $ffmpegExpectedZipSha
            ffmpegExeSha256 = $ffmpegExtractedSha
            updatedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        }
        [System.IO.File]::WriteAllText($ffmpegStatePath, ($stateObj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }
    $ffmpegFinalExeSha = Get-Sha256Hex -FilePath $ffmpegDestPath

    # Guard: ensure no stray ffplay.exe / ffprobe.exe remain in vendor/bin
    foreach ($unwanted in @('ffplay.exe', 'ffprobe.exe')) {
        $unwantedPath = Join-Path $VendorBinDir $unwanted
        if (Test-Path -LiteralPath $unwantedPath) {
            Remove-Item -LiteralPath $unwantedPath -Force
        }
    }

    # -------------------------------------------------------------------------
    # 4. Generate merged THIRD_PARTY_LICENSES.txt
    # -------------------------------------------------------------------------
    $generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $sepMajor = '=' * 80
    $sepMinor = '-' * 80

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($sepMajor)
    [void]$sb.AppendLine('LUMINA AUDIO - THIRD-PARTY RUNTIME BINARIES & LICENSES')
    [void]$sb.AppendLine($sepMajor)
    [void]$sb.AppendLine("Generated (UTC): $generatedUtc")
    [void]$sb.AppendLine('This file documents the third-party Windows x64 runtime executables bundled')
    [void]$sb.AppendLine('under bin/ in Lumina Audio Windows desktop releases.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Bundled Components:')
    [void]$sb.AppendLine("  1. yt-dlp  : $ytTag")
    [void]$sb.AppendLine("     Asset   : yt-dlp.exe")
    [void]$sb.AppendLine("     SHA256  : $ytExpectedSha")
    [void]$sb.AppendLine("     License : The Unlicense (+ PyInstaller bundled third-party licenses)")
    [void]$sb.AppendLine("     Release : $($ytRelease.html_url)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("  2. Deno    : $denoTag")
    [void]$sb.AppendLine("     Asset   : $denoZipName (extracted: deno.exe)")
    [void]$sb.AppendLine("     ZipSHA  : $denoExpectedZipSha")
    [void]$sb.AppendLine("     ExeSHA  : $denoFinalExeSha")
    [void]$sb.AppendLine("     License : MIT License")
    [void]$sb.AppendLine("     Release : $($denoRelease.html_url)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("  3. FFmpeg  : $ffmpegTag ($ffmpegReleaseName)")
    [void]$sb.AppendLine("     Asset   : $ffmpegZipName (extracted: ffmpeg.exe only)")
    [void]$sb.AppendLine("     ZipSHA  : $ffmpegExpectedZipSha")
    [void]$sb.AppendLine("     ExeSHA  : $ffmpegFinalExeSha")
    [void]$sb.AppendLine("     License : GNU Lesser General Public License (LGPL)")
    [void]$sb.AppendLine("     Release : $($ffmpegRelease.html_url)")
    [void]$sb.AppendLine('')

    # Section 1: yt-dlp
    [void]$sb.AppendLine($sepMajor)
    [void]$sb.AppendLine("1. yt-dlp ($ytTag) - The Unlicense")
    [void]$sb.AppendLine("Official Release: $($ytRelease.html_url)")
    [void]$sb.AppendLine($sepMajor)
    [void]$sb.AppendLine($ytUnlicenseText.TrimEnd())
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine($sepMinor)
    [void]$sb.AppendLine("yt-dlp ($ytTag) - PyInstaller Bundled THIRD_PARTY_LICENSES.txt")
    [void]$sb.AppendLine($sepMinor)
    [void]$sb.AppendLine($ytThirdPartyText.TrimEnd())
    [void]$sb.AppendLine('')

    # Section 2: Deno
    [void]$sb.AppendLine($sepMajor)
    [void]$sb.AppendLine("2. Deno ($denoTag) - MIT License")
    [void]$sb.AppendLine("Official Release: $($denoRelease.html_url)")
    [void]$sb.AppendLine($sepMajor)
    [void]$sb.AppendLine($denoLicenseText.TrimEnd())
    [void]$sb.AppendLine('')

    # Section 3: FFmpeg LGPL
    [void]$sb.AppendLine($sepMajor)
    [void]$sb.AppendLine("3. FFmpeg ($ffmpegZipName) - GNU Lesser General Public License (LGPL)")
    [void]$sb.AppendLine("Official Release: $($ffmpegRelease.html_url)")
    [void]$sb.AppendLine($sepMajor)
    [void]$sb.AppendLine('LGPL Compliance Notice:')
    [void]$sb.AppendLine('  - Lumina Audio bundles an unmodified LGPL build of ffmpeg.exe as a separate')
    [void]$sb.AppendLine('    standalone command-line executable invoked out-of-process (never statically')
    [void]$sb.AppendLine('    or dynamically linked into lumina_app.exe or core_ffi.dll).')
    [void]$sb.AppendLine('  - Users may replace bin/ffmpeg.exe with any compatible FFmpeg build.')
    [void]$sb.AppendLine('  - Upstream FFmpeg source code: https://ffmpeg.org/download.html')
    [void]$sb.AppendLine('  - Official Windows LGPL build scripts: https://github.com/BtbN/FFmpeg-Builds')
    [void]$sb.AppendLine($sepMinor)
    [void]$sb.AppendLine($ffmpegLicenseText.TrimEnd())
    [void]$sb.AppendLine('')

    $licensesTmpPath = Join-Path $TempDir 'THIRD_PARTY_LICENSES.txt.tmp'
    $licensesDestPath = Join-Path $VendorBinDir 'THIRD_PARTY_LICENSES.txt'
    [System.IO.File]::WriteAllText($licensesTmpPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $licensesTmpPath -Destination $licensesDestPath -Force

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== Staged Windows Runtime Dependencies Ready ===" -ForegroundColor Green
    foreach ($fileName in @('yt-dlp.exe', 'deno.exe', 'ffmpeg.exe', 'THIRD_PARTY_LICENSES.txt')) {
        $fullPath = Join-Path $VendorBinDir $fileName
        if (-not (Test-Path -LiteralPath $fullPath)) {
            throw "Expected staged output missing: $fullPath"
        }
        $item = Get-Item -LiteralPath $fullPath
        if ($item.Length -le 0) {
            throw "Expected staged output is empty: $fullPath"
        }
        $sizeMb = [math]::Round($item.Length / 1MB, 2)
        $sha = Get-Sha256Hex -FilePath $fullPath
        Write-Host ("  {0,-26} {1,7} MB  SHA256={2}" -f $fileName, $sizeMb, $sha)
    }
    exit 0
} finally {
    if (Test-Path -LiteralPath $TempDir) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
