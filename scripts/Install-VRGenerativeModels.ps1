[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $SkipDependencies
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Python = Join-Path $Root 'runtime\python\python.exe'
$Ffmpeg = Join-Path $Root 'tools\ffmpeg.exe'
$Worker = Join-Path $Root 'tools\vr_generative\m2svid_worker.py'
$Repository = Join-Path $Root 'third_party\m2svid'
$ModelRoot = Join-Path $Root 'models\vr\m2svid'
$Checkpoint = Join-Path $ModelRoot 'm2svid_weights.pt'
$OpenClip = Join-Path $ModelRoot 'open_clip_pytorch_model.bin'
$Commit = '11b0133093d6abfcc6ff953890edf05457975318'

foreach ($Path in @($Python,$Ffmpeg,$Worker)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Portable component is missing: $Path" }
}
New-Item -ItemType Directory -Force -Path $ModelRoot,(Join-Path $Root 'licenses\vr') | Out-Null

function Assert-SafeChild([string] $Path) {
    $ResolvedRoot = $Root.TrimEnd('\') + '\'
    $ResolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $ResolvedPath.StartsWith($ResolvedRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the portable folder: $ResolvedPath"
    }
}

function Get-ValidLargeFile([string] $Path, [int64] $ExpectedBytes) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path).Length -eq $ExpectedBytes
}

function Receive-LargeFile([string] $Uri, [string] $Destination, [int64] $ExpectedBytes, [string] $Label) {
    if (-not $Force -and (Get-ValidLargeFile $Destination $ExpectedBytes)) {
        Write-Output "$Label already verified ($ExpectedBytes bytes)."
        return
    }
    $Partial = $Destination + '.partial'
    Assert-SafeChild $Partial
    if ($Force -and (Test-Path -LiteralPath $Partial -PathType Leaf)) { Remove-Item -LiteralPath $Partial -Force }
    $Curl = (Get-Command curl.exe -ErrorAction Stop).Source
    Write-Output "Downloading $Label. The .partial file is resumable after interruption."
    & $Curl '--location' '--fail' '--retry' '8' '--retry-delay' '3' '--continue-at' '-' '--output' $Partial $Uri
    if ($LASTEXITCODE -ne 0) { throw "$Label download failed with curl exit code $LASTEXITCODE" }
    if (-not (Get-ValidLargeFile $Partial $ExpectedBytes)) {
        $Actual = if (Test-Path -LiteralPath $Partial -PathType Leaf) { (Get-Item -LiteralPath $Partial).Length } else { 0 }
        throw "$Label is incomplete: $Actual of $ExpectedBytes bytes"
    }
    Move-Item -LiteralPath $Partial -Destination $Destination -Force
    Write-Output "$Label verified ($ExpectedBytes bytes)."
}

function Receive-WebFile([string] $Uri, [string] $Destination, [string] $Label) {
    $Curl = (Get-Command curl.exe -ErrorAction Stop).Source
    Write-Output "Downloading $Label..."
    & $Curl '--location' '--fail' '--retry' '8' '--retry-all-errors' '--retry-delay' '3' `
        '--connect-timeout' '30' '--output' $Destination $Uri
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "$Label download failed with curl exit code $LASTEXITCODE"
    }
}

if ($Force -or -not (Test-Path -LiteralPath (Join-Path $Repository 'm2svid\models_for_sgm\m2svid_model.py') -PathType Leaf)) {
    Assert-SafeChild $Repository
    $TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dlss5-m2svid-' + [guid]::NewGuid().ToString('N'))
    $Archive = Join-Path $TempRoot 'm2svid.zip'
    $Expanded = Join-Path $TempRoot 'expanded'
    New-Item -ItemType Directory -Force -Path $Expanded | Out-Null
    try {
        Write-Output "Downloading official M2SVid source at commit $Commit..."
        Receive-WebFile -Uri "https://github.com/google-research/m2svid/archive/$Commit.zip" -Destination $Archive -Label 'official M2SVid source'
        Expand-Archive -LiteralPath $Archive -DestinationPath $Expanded -Force
        $SourceDirectory = Get-ChildItem -LiteralPath $Expanded -Directory | Select-Object -First 1
        if ($null -eq $SourceDirectory -or -not (Test-Path -LiteralPath (Join-Path $SourceDirectory.FullName 'LICENSE') -PathType Leaf)) {
            throw 'The downloaded M2SVid source archive is invalid.'
        }
        if (Test-Path -LiteralPath $Repository) { Remove-Item -LiteralPath $Repository -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $Repository | Out-Null
        Copy-Item -Path (Join-Path $SourceDirectory.FullName '*') -Destination $Repository -Recurse -Force
    }
    finally {
        if (Test-Path -LiteralPath $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
    }
}

Copy-Item -LiteralPath (Join-Path $Repository 'LICENSE') -Destination (Join-Path $Root 'licenses\vr\M2SVid-Apache-2.0.txt') -Force
if (-not (Test-Path -LiteralPath (Join-Path $Root 'licenses\vr\OpenCLIP-MIT.txt') -PathType Leaf)) {
    Receive-WebFile -Uri 'https://raw.githubusercontent.com/mlfoundations/open_clip/main/LICENSE' `
        -Destination (Join-Path $Root 'licenses\vr\OpenCLIP-MIT.txt') -Label 'OpenCLIP license'
}

if (-not $SkipDependencies) {
    Write-Output 'Installing the small M2SVid Python dependency layer into the shared CUDA runtime...'
    & $Python -m pip install --break-system-packages --disable-pip-version-check --no-warn-script-location `
        'pytorch-lightning==2.5.5' 'open-clip-torch==3.2.0' 'ffmpeg-python==0.2.0' `
        'pytorch-msssim==1.0.0' 'kornia==0.8.1'
    if ($LASTEXITCODE -ne 0) { throw 'M2SVid Python dependency installation failed.' }
}

Receive-LargeFile `
    -Uri 'https://storage.googleapis.com/gresearch/m2svid/m2svid_weights.pt' `
    -Destination $Checkpoint -ExpectedBytes 4978220327 -Label 'M2SVid full-attention checkpoint'
Receive-LargeFile `
    -Uri 'https://huggingface.co/laion/CLIP-ViT-H-14-laion2B-s32B-b79K/resolve/main/open_clip_pytorch_model.bin?download=true' `
    -Destination $OpenClip -ExpectedBytes 3944692325 -Label 'OpenCLIP ViT-H-14 checkpoint'

& $Python -s -B $Worker --check --ffmpeg $Ffmpeg --repository $Repository --checkpoint $Checkpoint --open-clip $OpenClip
if ($LASTEXITCODE -ne 0) { throw 'M2SVid installation verification failed.' }

$Status = [ordered]@{
    schema = 'dlss5-video-studio-vr-generative/1'
    backend = 'M2SVid'
    source_commit = $Commit
    checkpoint_bytes = (Get-Item -LiteralPath $Checkpoint).Length
    open_clip_bytes = (Get-Item -LiteralPath $OpenClip).Length
    installed_utc = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText(
    (Join-Path $ModelRoot 'install.json'),
    ($Status | ConvertTo-Json -Depth 4),
    (New-Object Text.UTF8Encoding($false))
)
Write-Output 'VR_GENERATIVE_MODELS_READY backend=M2SVid mode=full-attention'
