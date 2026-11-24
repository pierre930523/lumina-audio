<#
.SYNOPSIS
    Builds a complete, verified Lumina Audio Windows x64 Release bundle.

.DESCRIPTION
    1. Runs scripts/prepare_release_deps.ps1 (unless -SkipPrepareDeps is passed).
    2. Verifies app/windows/vendor/bin/{yt-dlp.exe, deno.exe, ffmpeg.exe, THIRD_PARTY_LICENSES.txt}
       all exist and are non-empty.
    3. Ensures target/release/core_ffi.dll exists (runs `cargo build --release -p core-ffi` if missing).
    4. Runs `flutter build windows --release` inside app/.
    5. Verifies app/build/windows/x64/runner/Release/ contains all required deliverables and reports
       MSVC Runtime DLL presence. Aborts non-zero if any required deliverable is missing.
#>
[CmdletBinding()]
param(
    [switch]$SkipPrepareDeps,
    [string]$YtDlpVersion = "latest",
    [string]$DenoVersion = "latest",
    [string]$FfmpegVersion = "latest",
    [switch]$ForcePrepareDeps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AppDir = Join-Path $RepoRoot 'app'
$VendorBinDir = Join-Path $RepoRoot 'app\windows\vendor\bin'
$CoreFfiDll = Join-Path $RepoRoot 'target\release\core_ffi.dll'
$ReleaseDir = Join-Path $RepoRoot 'app\build\windows\x64\runner\Release'
$PrepareDepsScript = Join-Path $PSScriptRoot 'prepare_release_deps.ps1'

function Assert-NonEmptyFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required deliverable missing: $Label ($Path)"
    }
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -le 0) {
        throw "Required deliverable is empty (0 bytes): $Label ($Path)"
    }
    return $len
}

Write-Host "=== Lumina Audio Windows Release Build ===" -ForegroundColor Yellow
Write-Host "Repo root   : $RepoRoot"
Write-Host "Release dir : $ReleaseDir"
Write-Host ""

# -----------------------------------------------------------------------------
# Step 1: Prepare vendored runtime dependencies
# -----------------------------------------------------------------------------
if (-not $SkipPrepareDeps) {
    Write-Host "[Step 1/5] Preparing vendored runtime dependencies..." -ForegroundColor Cyan
    $prepParams = @{
        YtDlpVersion  = $YtDlpVersion
        DenoVersion   = $DenoVersion
        FfmpegVersion = $FfmpegVersion
    }
    if ($ForcePrepareDeps) {
        $prepParams['Force'] = $true
    }
    & $PrepareDepsScript @prepParams
    if ($LASTEXITCODE -ne 0) {
        throw "prepare_release_deps.ps1 failed with exit code $LASTEXITCODE."
    }
} else {
    Write-Host "[Step 1/5] Skipping prepare_release_deps.ps1 (-SkipPrepareDeps)." -ForegroundColor DarkYellow
}

# -----------------------------------------------------------------------------
# Step 2: Verify staged vendor binaries & license bundle
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "[Step 2/5] Verifying staged files in $VendorBinDir ..." -ForegroundColor Cyan
$requiredStaged = @(
    'yt-dlp.exe',
    'deno.exe',
    'ffmpeg.exe',
    'THIRD_PARTY_LICENSES.txt'
)
foreach ($name in $requiredStaged) {
    $full = Join-Path $VendorBinDir $name
    $bytes = Assert-NonEmptyFile -Path $full -Label "vendor/bin/$name"
    Write-Host ("  [OK] {0,-26} ({1:N0} bytes)" -f $name, $bytes) -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Step 3: Ensure Rust core_ffi.dll (Release) exists
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "[Step 3/5] Checking Rust core_ffi.dll ..." -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $CoreFfiDll -PathType Leaf) -or (Get-Item -LiteralPath $CoreFfiDll).Length -le 0) {
    Write-Host "  target/release/core_ffi.dll not found. Building via cargo build --release -p core-ffi ..." -ForegroundColor Yellow
    Push-Location $RepoRoot
    try {
        & cargo build --release -p core-ffi
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build --release -p core-ffi failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}
$coreBytes = Assert-NonEmptyFile -Path $CoreFfiDll -Label 'target/release/core_ffi.dll'
Write-Host ("  [OK] target/release/core_ffi.dll ({0:N0} bytes)" -f $coreBytes) -ForegroundColor Green

# -----------------------------------------------------------------------------
# Step 4: Build Flutter Windows Release
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "[Step 4/5] Running flutter build windows --release in $AppDir ..." -ForegroundColor Cyan
Push-Location $AppDir
try {
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows --release failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}

# -----------------------------------------------------------------------------
# Step 5: Verify Release bundle deliverables & report MSVC runtime DLLs
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "[Step 5/5] Verifying Release deliverables in $ReleaseDir ..." -ForegroundColor Cyan
$requiredReleaseFiles = @(
    'lumina_app.exe',
    'core_ffi.dll',
    'flutter_windows.dll',
    'WebView2Loader.dll',
    'bin\yt-dlp.exe',
    'bin\deno.exe',
    'bin\ffmpeg.exe',
    'THIRD_PARTY_LICENSES.txt'
)

$missingDeliverables = @()
foreach ($rel in $requiredReleaseFiles) {
    $full = Join-Path $ReleaseDir $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Get-Item -LiteralPath $full).Length -le 0) {
        $missingDeliverables += $rel
        Write-Host ("  [MISSING] {0}" -f $rel) -ForegroundColor Red
    } else {
        $sizeMb = [math]::Round((Get-Item -LiteralPath $full).Length / 1MB, 2)
        Write-Host ("  [OK]      {0,-28} ({1,6} MB)" -f $rel, $sizeMb) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "MSVC Runtime DLL status in Release bundle:" -ForegroundColor Cyan
$coreMsvcDlls = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
$extraMsvcDlls = @(Get-ChildItem -LiteralPath $ReleaseDir -Filter '*.dll' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -imatch '^(vcruntime|msvcp|concrt|vccorlib|api-ms-win-crt).*\.dll$' } |
    Sort-Object Name)

foreach ($dllName in $coreMsvcDlls) {
    $dllPath = Join-Path $ReleaseDir $dllName
    if (Test-Path -LiteralPath $dllPath -PathType Leaf) {
        $sizeKb = [math]::Round((Get-Item -LiteralPath $dllPath).Length / 1KB, 1)
        Write-Host ("  [PRESENT] {0,-24} ({1,6} KB)" -f $dllName, $sizeKb) -ForegroundColor Green
    } else {
        Write-Host ("  [ABSENT]  {0,-24} (target machines will need VC++ 2015-2022 Redist x64)" -f $dllName) -ForegroundColor Yellow
    }
}
if ($extraMsvcDlls.Count -gt 0) {
    $extraNames = ($extraMsvcDlls | Select-Object -ExpandProperty Name) -join ', '
    Write-Host "  All detected CRT/MSVC DLLs ($($extraMsvcDlls.Count)): $extraNames"
}

if ($missingDeliverables.Count -gt 0) {
    throw ("Release bundle verification FAILED. Missing required deliverable(s): " + ($missingDeliverables -join ', '))
}

Write-Host ""
Write-Host "=== Lumina Audio Windows Release Build SUCCEEDED ===" -ForegroundColor Green
exit 0
