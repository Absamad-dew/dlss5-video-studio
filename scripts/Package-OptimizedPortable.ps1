param(
    [string] $Target = 'D:\DLSS5_VIDEO_STUDIO_PORTABLE_NEURAL_V5',
    [string] $DependencyRoot = 'D:\DLSS5VideoStudioDeps'
)

$ErrorActionPreference = 'Stop'
$Build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Base = 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_PORTABLE'
$Target = [IO.Path]::GetFullPath($Target)

foreach ($Path in @($Build,$Base,$DependencyRoot)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Missing source directory: $Path" }
}

# Always build a clean, shareable package.  The target is a generated artifact;
# keeping an old directory would also keep run logs, output videos, and stale DLLs.
$TargetRoot = [IO.Path]::GetPathRoot($Target)
if ($Target -eq $Build -or $Target -eq $Base -or $Target -eq $TargetRoot) {
    throw "Refusing to clean unsafe package target: $Target"
}
if (Test-Path -LiteralPath $Target) {
    Remove-Item -LiteralPath $Target -Recurse -Force
}

$Directories = @(
    'app','engine','licenses','licenses\upscalers','models','models\upscalers',
    'models\upscalers\nanovsr','models\upscalers\animesr','output','settings','temp',
    'runtime','runtime\python','third_party','third_party\FlashVSR_Ultra_Fast','third_party\DLoRAL','third_party\spatial-media',
    'tools','tools\guidegen','tools\upscaler','tools\upscaler\backends','tools\spatialmedia'
)
foreach ($Relative in $Directories) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Target $Relative) | Out-Null
}

foreach ($Name in @('START.cmd','NVIDIA_RUNTIME_NOTICE.txt','THIRD_PARTY_NOTICES.md')) {
    Copy-Item -LiteralPath (Join-Path $Base $Name) -Destination (Join-Path $Target $Name) -Force
}
Copy-Item -Path (Join-Path $Base 'licenses\*') -Destination (Join-Path $Target 'licenses') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $Base 'models\depth_anything_v2_small.onnx') -Destination (Join-Path $Target 'models') -Force
Copy-Item -LiteralPath (Join-Path $Base 'tools\ffmpeg.exe'),(Join-Path $Base 'tools\ffprobe.exe'),(Join-Path $Base 'tools\ffplay.exe') -Destination (Join-Path $Target 'tools') -Force

$PortablePython = Join-Path $DependencyRoot 'runtime\python\cpython-3.11.16-windows-x86_64-none'
if (-not (Test-Path -LiteralPath (Join-Path $PortablePython 'Lib\site-packages\torch') -PathType Container)) {
    throw "Portable CUDA runtime is incomplete: $PortablePython"
}
Copy-Item -Path (Join-Path $PortablePython '*') -Destination (Join-Path $Target 'runtime\python') -Recurse -Force
Copy-Item -Path (Join-Path $DependencyRoot 'models\nanovsr\*') -Destination (Join-Path $Target 'models\upscalers\nanovsr') -Force
Copy-Item -Path (Join-Path $DependencyRoot 'models\animesr\*') -Destination (Join-Path $Target 'models\upscalers\animesr') -Force
$FlashWeights = Join-Path $DependencyRoot 'models\flashvsr-v1.1'
if (Test-Path -LiteralPath $FlashWeights -PathType Container) {
    $FlashTarget = Join-Path $Target 'models\upscalers\flashvsr-v1.1'
    New-Item -ItemType Directory -Force -Path $FlashTarget | Out-Null
    foreach ($Name in @(
        'diffusion_pytorch_model_streaming_dmd.safetensors',
        'LQ_proj_in.ckpt',
        'TCDecoder.ckpt'
    )) {
        $SourceFile = Join-Path $FlashWeights $Name
        if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) { throw "Missing FlashVSR model file: $SourceFile" }
        Copy-Item -LiteralPath $SourceFile -Destination $FlashTarget -Force
    }
}
$DLoRALWeights = Join-Path $DependencyRoot 'models\dloral'
if (Test-Path -LiteralPath $DLoRALWeights -PathType Container) {
    $DLoRALTarget = Join-Path $Target 'models\upscalers\dloral'
    New-Item -ItemType Directory -Force -Path $DLoRALTarget | Out-Null
    foreach ($Name in @('model.pkl','spynet_20210409-c6c1bd09.pth')) {
        $SourceFile = Join-Path $DLoRALWeights $Name
        if (Test-Path -LiteralPath $SourceFile -PathType Leaf) {
            Copy-Item -LiteralPath $SourceFile -Destination $DLoRALTarget -Force
        }
    }

    # DLoRAL needs SD 2.1 as a backbone, but only the FP16 safetensors and
    # configuration/tokenizer files.  Copying the complete HF/git checkout
    # would add FP32, .bin and LFS duplicates without changing inference.
    $SdSource = Join-Path $DLoRALWeights 'stable-diffusion-2-1-base'
    $SdTarget = Join-Path $DLoRALTarget 'stable-diffusion-2-1-base'
    $SdFiles = @(
        'scheduler\scheduler_config.json',
        'tokenizer\merges.txt',
        'tokenizer\special_tokens_map.json',
        'tokenizer\tokenizer_config.json',
        'tokenizer\vocab.json',
        'text_encoder\config.json',
        'text_encoder\model.fp16.safetensors',
        'unet\config.json',
        'unet\diffusion_pytorch_model.fp16.safetensors',
        'vae\config.json',
        'vae\diffusion_pytorch_model.fp16.safetensors'
    )
    foreach ($Relative in $SdFiles) {
        $SourceFile = Join-Path $SdSource $Relative
        if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) { throw "Missing DLoRAL SD2.1 file: $SourceFile" }
        $DestinationFile = Join-Path $SdTarget $Relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DestinationFile) | Out-Null
        Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile -Force
    }
}
Copy-Item -LiteralPath (Join-Path $Build 'python\upscaler_worker.py') -Destination (Join-Path $Target 'tools\upscaler') -Force
if (Test-Path -LiteralPath (Join-Path $Build 'python\backends')) {
    Copy-Item -Path (Join-Path $Build 'python\backends\*') -Destination (Join-Path $Target 'tools\upscaler\backends') -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $DependencyRoot 'src\NanoVSR\LICENSE') -Destination (Join-Path $Target 'licenses\upscalers\NanoVSR-MIT.txt') -Force
Copy-Item -LiteralPath (Join-Path $DependencyRoot 'src\AnimeSR\LICENSE') -Destination (Join-Path $Target 'licenses\upscalers\AnimeSR-Apache-2.0.txt') -Force
$FlashSource = Join-Path $DependencyRoot 'src\ComfyUI-FlashVSR_Ultra_Fast'
$DLoRALSource = Join-Path $DependencyRoot 'src\DLoRAL'
Get-ChildItem -LiteralPath $FlashSource -Force | Where-Object Name -ne '.git' | Copy-Item -Destination (Join-Path $Target 'third_party\FlashVSR_Ultra_Fast') -Recurse -Force
Get-ChildItem -LiteralPath $DLoRALSource -Force | Where-Object Name -ne '.git' | Copy-Item -Destination (Join-Path $Target 'third_party\DLoRAL') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $FlashSource 'LICENSE') -Destination (Join-Path $Target 'licenses\upscalers\FlashVSR-Ultra-Fast-GPL-3.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $DLoRALSource 'LICENSE') -Destination (Join-Path $Target 'licenses\upscalers\DLoRAL-MIT.txt') -Force
$SpatialMediaSource = Join-Path $DependencyRoot 'src\spatial-media'
if (-not (Test-Path -LiteralPath (Join-Path $SpatialMediaSource 'spatialmedia\__main__.py') -PathType Leaf)) {
    throw "Missing Google Spatial Media source: $SpatialMediaSource"
}
Get-ChildItem -LiteralPath $SpatialMediaSource -Force | Where-Object Name -ne '.git' | Copy-Item -Destination (Join-Path $Target 'third_party\spatial-media') -Recurse -Force
Copy-Item -Path (Join-Path $SpatialMediaSource 'spatialmedia\*') -Destination (Join-Path $Target 'tools\spatialmedia') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $SpatialMediaSource 'LICENSE') -Destination (Join-Path $Target 'licenses\upscalers\Google-Spatial-Media-Apache-2.0.txt') -Force
Copy-Item -LiteralPath (Join-Path $Build 'INSTALL_MODELS.cmd'),(Join-Path $Build 'scripts\Install-NeuralModels.ps1') -Destination $Target -Force

foreach ($Name in @('dxgi.dll','renodx-dlss5.addon64','nvngx_dlss.dll','nvngx_dlssnr.dll','ReShade.ini')) {
    Copy-Item -LiteralPath (Join-Path $Base "engine\$Name") -Destination (Join-Path $Target 'engine') -Force
}
Copy-Item -LiteralPath (Join-Path $Build 'dist\engine\dlss5-video-host.exe') -Destination (Join-Path $Target 'engine') -Force
Copy-Item -Path (Join-Path $Build 'dist\guidegen\*') -Destination (Join-Path $Target 'tools\guidegen') -Recurse -Force
Copy-Item -LiteralPath `
    (Join-Path $Build 'app\process-video.ps1'), `
    (Join-Path $Build 'app\realtime-player.ps1'), `
    (Join-Path $Build 'app\source-resolver.psm1'), `
    (Join-Path $Build 'app\studio.ps1') `
    -Destination (Join-Path $Target 'app') -Force
Copy-Item -LiteralPath (Join-Path $Build 'dist\DLSS5 Video Studio.exe') -Destination $Target -Force
Copy-Item -LiteralPath (Join-Path $Build 'README_OPTIMIZED_RU.md') -Destination (Join-Path $Target 'README_RU.md') -Force
Copy-Item -LiteralPath (Join-Path $Build 'VERSION_OPTIMIZED.txt') -Destination (Join-Path $Target 'VERSION.txt') -Force

$PackageVersion = (Get-Content -LiteralPath (Join-Path $Build 'VERSION_OPTIMIZED.txt') -First 1).Trim()
& (Join-Path $Build 'scripts\New-PortableManifest.ps1') -PortableRoot $Target -Version $PackageVersion
& (Join-Path $Build 'scripts\Test-PortableManifest.ps1') -PortableRoot $Target

Write-Output "OPTIMIZED_PORTABLE_OK $Target"
