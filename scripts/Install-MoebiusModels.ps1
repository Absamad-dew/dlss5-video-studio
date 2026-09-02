[CmdletBinding()]
param([switch] $Force, [switch] $SkipDependencies)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Python = Join-Path $Root 'runtime\python\python.exe'
$Ffmpeg = Join-Path $Root 'tools\ffmpeg.exe'
$Worker = Join-Path $Root 'tools\vr_generative\moebius_worker.py'
$Repository = Join-Path $Root 'third_party\moebius'
$ModelRoot = Join-Path $Root 'models\vr\moebius'
$Checkpoint = Join-Path $ModelRoot 'ft_places2\diffusion_pytorch_model.bin'
$VaeRoot = Join-Path $ModelRoot 'vae'
$VaeConfig = Join-Path $VaeRoot 'config.json'
$VaeWeights = Join-Path $VaeRoot 'diffusion_pytorch_model.bin'
$SitePackages = Join-Path $ModelRoot 'site-packages'
$Commit = 'b88d462bacb9af6e7128a3b4cc4a07418bedfd61'

foreach ($Path in @($Python,$Ffmpeg,$Worker)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Portable component is missing: $Path" }
}
New-Item -ItemType Directory -Force -Path $ModelRoot,$VaeRoot,$SitePackages,(Join-Path $Root 'licenses\vr') | Out-Null

function Assert-SafeChild([string] $Path) {
    $ResolvedRoot = $Root.TrimEnd('\') + '\'
    $ResolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $ResolvedPath.StartsWith($ResolvedRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the portable folder: $ResolvedPath"
    }
}

function Get-Sha256Hex([string] $Path) {
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
    finally { $Stream.Dispose(); $Sha.Dispose() }
}

function Test-VerifiedFile([string] $Path, [int64] $ExpectedBytes, [string] $ExpectedSha256) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne $ExpectedBytes) { return $false }
    return (Get-Sha256Hex $Path) -eq $ExpectedSha256
}

function Receive-VerifiedFile(
    [string] $Uri,
    [string] $Destination,
    [int64] $ExpectedBytes,
    [string] $ExpectedSha256,
    [string] $Label
) {
    if (-not $Force -and (Test-VerifiedFile $Destination $ExpectedBytes $ExpectedSha256)) {
        Write-Output "$Label already verified ($ExpectedBytes bytes)."
        return
    }
    $Partial = $Destination + '.partial'
    Assert-SafeChild $Partial
    if ($Force -and (Test-Path -LiteralPath $Partial -PathType Leaf)) { Remove-Item -LiteralPath $Partial -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $Curl = (Get-Command curl.exe -ErrorAction Stop).Source
    Write-Output "Downloading $Label. The .partial file is resumable."
    & $Curl '--location' '--fail' '--retry' '8' '--retry-all-errors' '--retry-delay' '3' `
        '--speed-limit' '1024' '--speed-time' '30' '--continue-at' '-' '--output' $Partial $Uri
    if ($LASTEXITCODE -ne 0) { throw "$Label download failed with curl exit code $LASTEXITCODE" }
    if (-not (Test-VerifiedFile $Partial $ExpectedBytes $ExpectedSha256)) {
        $Actual = if (Test-Path -LiteralPath $Partial -PathType Leaf) { (Get-Item -LiteralPath $Partial).Length } else { 0 }
        throw "$Label verification failed: $Actual of $ExpectedBytes bytes"
    }
    Move-Item -LiteralPath $Partial -Destination $Destination -Force
    Write-Output "$Label verified ($ExpectedBytes bytes)."
}

function Receive-WebFile([string] $Uri, [string] $Destination, [string] $Label) {
    $Curl = (Get-Command curl.exe -ErrorAction Stop).Source
    & $Curl '--location' '--fail' '--retry' '8' '--retry-all-errors' '--retry-delay' '3' `
        '--connect-timeout' '30' '--output' $Destination $Uri
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "$Label download failed with curl exit code $LASTEXITCODE"
    }
}

if ($Force -or -not (Test-Path -LiteralPath (Join-Path $Repository 'removal\v1_2\pipeline.py') -PathType Leaf)) {
    Assert-SafeChild $Repository
    $TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dlss5-moebius-' + [guid]::NewGuid().ToString('N'))
    $Archive = Join-Path $TempRoot 'moebius.zip'
    $Expanded = Join-Path $TempRoot 'expanded'
    New-Item -ItemType Directory -Force -Path $Expanded | Out-Null
    try {
        Write-Output "Downloading official Moebius source at commit $Commit..."
        Receive-WebFile -Uri "https://github.com/hustvl/Moebius/archive/$Commit.zip" -Destination $Archive -Label 'official Moebius source'
        Expand-Archive -LiteralPath $Archive -DestinationPath $Expanded -Force
        $SourceDirectory = Get-ChildItem -LiteralPath $Expanded -Directory | Select-Object -First 1
        if ($null -eq $SourceDirectory -or -not (Test-Path -LiteralPath (Join-Path $SourceDirectory.FullName 'LICENSE') -PathType Leaf)) {
            throw 'The downloaded Moebius source archive is invalid.'
        }
        if (Test-Path -LiteralPath $Repository) { Remove-Item -LiteralPath $Repository -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $Repository | Out-Null
        Copy-Item -Path (Join-Path $SourceDirectory.FullName '*') -Destination $Repository -Recurse -Force

        # The upstream package imports its large PixelHacker teacher and the
        # CUDA-only flash-linear-attention extension from model_lib/__init__
        # even for student inference.  The Moebius checkpoint never touches
        # that branch, so remove only the eager teacher import.  This makes the
        # official student usable in the existing portable CUDA runtime.
        $ModelInit = Join-Path $Repository 'model_lib\__init__.py'
        $ModelInitText = Get-Content -LiteralPath $ModelInit -Raw
        $ModelInitText = $ModelInitText -replace '(?m)^from \.nets\.unet_gla import UNet2DGLAConditionModel\r?\n?', ''
        $ModelInitText = "# Modified by DLSS5 Video Studio: the unused teacher import is intentionally disabled for portable inference.`r`n" + $ModelInitText
        [IO.File]::WriteAllText($ModelInit,$ModelInitText,(New-Object Text.UTF8Encoding($false)))
    }
    finally {
        if (Test-Path -LiteralPath $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
    }
}

Copy-Item -LiteralPath (Join-Path $Repository 'LICENSE') -Destination (Join-Path $Root 'licenses\vr\Moebius-Apache-2.0.txt') -Force
if ($Force -or -not (Test-Path -LiteralPath (Join-Path $Root 'licenses\vr\PixelHacker-Apache-2.0.txt') -PathType Leaf)) {
    Receive-WebFile `
        -Uri 'https://raw.githubusercontent.com/hustvl/PixelHacker/main/LICENSE' `
        -Destination (Join-Path $Root 'licenses\vr\PixelHacker-Apache-2.0.txt') `
        -Label 'PixelHacker license'
}

$DependencyMissing = @(
    'diffusers\__init__.py','huggingface_hub\__init__.py','transformers\__init__.py',
    'tokenizers\__init__.py','accelerate\__init__.py','peft\__init__.py'
) | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SitePackages $_) -PathType Leaf) }
if (-not $SkipDependencies -and ($Force -or $DependencyMissing.Count -gt 0)) {
    Write-Output 'Installing an isolated Moebius compatibility layer (the shared Torch/CUDA runtime is preserved)...'
    & $Python -s -m pip install --break-system-packages --disable-pip-version-check --no-warn-script-location `
        --target $SitePackages --upgrade --no-deps 'diffusers==0.38.0' 'huggingface-hub==0.36.0' `
        'transformers==4.56.2' 'tokenizers==0.22.1' 'accelerate==1.14.0' 'peft==0.17.1'
    if ($LASTEXITCODE -ne 0) { throw 'Moebius compatibility-layer installation failed.' }
} elseif (-not $SkipDependencies) {
    Write-Output 'Moebius compatibility layer is already installed.'
}

Receive-VerifiedFile `
    -Uri 'https://huggingface.co/hustvl/Moebius/resolve/main/ft_places2/diffusion_pytorch_model.bin?download=true' `
    -Destination $Checkpoint -ExpectedBytes 905298356 `
    -ExpectedSha256 '6525afb888e55f9b5c74fa0a5d19ca0762d720d6c716fb0f8422fbeb6868a09a' `
    -Label 'Moebius Places2 checkpoint'
if ($Force -or -not (Test-Path -LiteralPath $VaeConfig -PathType Leaf) -or (Get-Item -LiteralPath $VaeConfig).Length -ne 788) {
    Receive-WebFile `
        -Uri 'https://huggingface.co/hustvl/PixelHacker/resolve/main/vae/config.json?download=true' `
        -Destination $VaeConfig -Label 'Moebius VAE configuration'
}
if ((Get-Item -LiteralPath $VaeConfig).Length -ne 788) { throw 'Moebius VAE configuration is incomplete.' }
Receive-VerifiedFile `
    -Uri 'https://huggingface.co/hustvl/PixelHacker/resolve/main/vae/diffusion_pytorch_model.bin?download=true' `
    -Destination $VaeWeights -ExpectedBytes 167394306 `
    -ExpectedSha256 'a59d7ea697f2942d22002dc3469e8c53db807a6b78f7f5ec03bd4c1f70f98efe' `
    -Label 'Moebius VAE checkpoint'

& $Python -s -B $Worker --check --ffmpeg $Ffmpeg --repository $Repository `
    --checkpoint $Checkpoint --vae $VaeRoot --site-packages $SitePackages
if ($LASTEXITCODE -ne 0) { throw 'Moebius installation verification failed.' }

$Status = [ordered]@{
    schema = 'dlss5-video-studio-vr-generative/2'
    backend = 'Moebius-Sparse-Temporal'
    source_commit = $Commit
    checkpoint_sha256 = Get-Sha256Hex $Checkpoint
    checkpoint_bytes = (Get-Item -LiteralPath $Checkpoint).Length
    vae_sha256 = Get-Sha256Hex $VaeWeights
    vae_bytes = (Get-Item -LiteralPath $VaeWeights).Length
    installed_utc = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText(
    (Join-Path $ModelRoot 'install.json'),
    ($Status | ConvertTo-Json -Depth 4),
    (New-Object Text.UTF8Encoding($false))
)
Write-Output 'VR_GENERATIVE_MODELS_READY backend=Moebius-Sparse-Temporal download=1.0GB'
