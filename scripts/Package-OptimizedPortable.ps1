param(
    [string] $Target = 'D:\DLSS5_VIDEO_STUDIO_PORTABLE_NEURAL_V5',
    [string] $DependencyRoot = 'D:\DLSS5VideoStudioDeps',
    [string] $Base = 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_PORTABLE',
    [string] $MainModelSource = ''
)

$ErrorActionPreference = 'Stop'
$Build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Base = [IO.Path]::GetFullPath($Base)
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
    'app','engine','licenses','licenses\upscalers','licenses\vr','models','models\upscalers','models\vr','models\vr\m2svid','models\vr\moebius',
    'models\upscalers\nanovsr','models\upscalers\animesr','models\depth','models\motion','models\vr\migan','output','settings','temp',
    'runtime','runtime\python','third_party','third_party\FlashVSR_Ultra_Fast','third_party\DLoRAL','third_party\spatial-media','third_party\moebius',
    'tools','tools\guidegen','tools\upscaler','tools\upscaler\backends','tools\spatialmedia','tools\vr_depth','tools\vr_generative','scripts'
)
foreach ($Relative in $Directories) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Target $Relative) | Out-Null
}

foreach ($Name in @('START.cmd','NVIDIA_RUNTIME_NOTICE.txt','THIRD_PARTY_NOTICES.md')) {
    Copy-Item -LiteralPath (Join-Path $Base $Name) -Destination (Join-Path $Target $Name) -Force
}
Copy-Item -LiteralPath (Join-Path $Build 'INSTALL_VIDEO_DEPTH.cmd'),(Join-Path $Build 'INSTALL_DA3_LARGE.cmd'),(Join-Path $Build 'INSTALL_M2SVID_EXPERIMENTAL.cmd'),(Join-Path $Build 'INSTALL_MOEBIUS_EXPERIMENTAL.cmd') -Destination $Target -Force
Copy-Item -Path (Join-Path $Base 'licenses\*') -Destination (Join-Path $Target 'licenses') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $Build 'licenses\vr\MI-GAN-MIT.txt') -Destination (Join-Path $Target 'licenses\vr') -Force
Copy-Item -LiteralPath (Join-Path $Build 'licenses\NVENC-header-MIT.txt') -Destination (Join-Path $Target 'licenses') -Force
Copy-Item -LiteralPath (Join-Path $Base 'models\depth_anything_v2_small.onnx') -Destination (Join-Path $Target 'models') -Force
if (-not [string]::IsNullOrWhiteSpace($MainModelSource)) {
    $ResolvedModelSource = [IO.Path]::GetFullPath($MainModelSource)
    foreach ($Relative in @(
        'models\depth\da3-small',
        'models\depth\video_depth_anything_vits.pth',
        'third_party\video-depth-anything',
        'models\motion\raft_small_C_T_V2-01064c6d.pth',
        'models\vr\migan'
    )) {
        $SourcePath = Join-Path $ResolvedModelSource $Relative
        if (-not (Test-Path -LiteralPath $SourcePath)) { throw "Missing main model payload: $SourcePath" }
        $DestinationPath = Join-Path $Target $Relative
        if ((Get-Item -LiteralPath $SourcePath).PSIsContainer) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Copy-Item -Path (Join-Path $SourcePath '*') -Destination $DestinationPath -Recurse -Force
        } else {
            Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
        }
    }
}
$MediaTools = @(
    (Join-Path $Base 'tools\ffmpeg.exe'),
    (Join-Path $Base 'tools\ffprobe.exe'),
    (Join-Path $Base 'tools\ffplay.exe'),
    (Join-Path $Build 'tools\yt-dlp.exe')
)
foreach ($MediaTool in $MediaTools) {
    if (-not (Test-Path -LiteralPath $MediaTool -PathType Leaf)) { throw "Missing portable media tool: $MediaTool" }
}
Copy-Item -LiteralPath $MediaTools -Destination (Join-Path $Target 'tools') -Force

$BasePython = Join-Path $Base 'runtime\python'
$PortablePython = if (
    (Test-Path -LiteralPath (Join-Path $BasePython 'Lib\site-packages\torch') -PathType Container) -and
    (Test-Path -LiteralPath (Join-Path $BasePython 'Lib\site-packages\cv2') -PathType Container) -and
    (Test-Path -LiteralPath (Join-Path $BasePython 'Lib\site-packages\onnxruntime') -PathType Container)
) { $BasePython } else { Join-Path $DependencyRoot 'runtime\python\cpython-3.11.16-windows-x86_64-none' }
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
$StreamlineBin = Join-Path $Build 'third_party\streamline-sdk-v2.12.0\bin\x64'
foreach ($Name in @('sl.interposer.dll','sl.common.dll','sl.dlss_g.dll','sl.reflex.dll','sl.pcl.dll','nvngx_dlssg.dll','reflex.license.txt')) {
    $StreamlineRuntime = Join-Path $StreamlineBin $Name
    if (-not (Test-Path -LiteralPath $StreamlineRuntime -PathType Leaf)) {
        throw "Missing Streamline runtime dependency: $StreamlineRuntime"
    }
    Copy-Item -LiteralPath $StreamlineRuntime -Destination (Join-Path $Target 'engine') -Force
}
Copy-Item -LiteralPath (Join-Path $Build 'dist\engine\dlss5-video-host.exe') -Destination (Join-Path $Target 'engine') -Force
Copy-Item -Path (Join-Path $Build 'dist\guidegen\*') -Destination (Join-Path $Target 'tools\guidegen') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $Build 'python\guidegen.py') -Destination (Join-Path $Target 'tools\guidegen') -Force
Copy-Item -LiteralPath (Join-Path $Build 'python\vr_depth_worker.py') -Destination (Join-Path $Target 'tools\vr_depth') -Force
Copy-Item -LiteralPath (Join-Path $Build 'python\m2svid_worker.py') -Destination (Join-Path $Target 'tools\vr_generative') -Force
Copy-Item -LiteralPath (Join-Path $Build 'python\moebius_worker.py') -Destination (Join-Path $Target 'tools\vr_generative') -Force
Copy-Item -LiteralPath (Join-Path $Build 'python\temporal_atlas_worker.py') -Destination (Join-Path $Target 'tools\vr_generative') -Force
Copy-Item -LiteralPath (Join-Path $Build 'python\install_depth_models.py') -Destination (Join-Path $Target 'tools') -Force
New-Item -ItemType Directory -Force -Path (Join-Path $Target 'tools/iw3')|Out-Null
foreach($Name in @('iw3_worker.py','iw3_model_assets.py','install_iw3.py','iw3-lock.json','iw3_da3.py','iw3_da3_install.py')){
    Copy-Item -LiteralPath (Join-Path $Build "python/$Name") -Destination (Join-Path $Target "tools/iw3/$Name") -Force
}
foreach($Name in @('iw3-ui.ps1','process-iw3.ps1','iw3-settings.json','iw3-da3-models.json')){
    Copy-Item -LiteralPath (Join-Path $Build "app/$Name") -Destination (Join-Path $Target "app/$Name") -Force
}
Copy-Item -LiteralPath (Join-Path $Build 'scripts/Install-Iw3.ps1') -Destination (Join-Path $Target 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $Build 'scripts/Install-Iw3Da3.ps1') -Destination (Join-Path $Target 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $Build 'INSTALL_IW3.cmd') -Destination $Target -Force
if($MainModelSource){
    # Keep the DA3 readiness metadata and actual installed Main checkpoints together.
    $Da3Catalog=Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $Build 'app/iw3-da3-models.json')|ConvertFrom-Json
    foreach($Da3Model in $Da3Catalog.models){
        if(-not $Da3Model.path.StartsWith('models/depth/')){continue}
        $Da3Source=Join-Path $MainModelSource $Da3Model.path
        if(Test-Path -LiteralPath $Da3Source -PathType Leaf){
            $Da3Destination=Split-Path -Parent (Join-Path $Target $Da3Model.path)
            New-Item -ItemType Directory -Force -Path $Da3Destination|Out-Null
            Copy-Item -LiteralPath $Da3Source -Destination $Da3Destination -Force
            Get-ChildItem -LiteralPath (Split-Path -Parent $Da3Source) -Filter '*MODEL_CARD.md' -File | Copy-Item -Destination $Da3Destination -Force
        }
    }
    foreach($Relative in @('third_party/nunif','third_party/iw3-da3','third_party/iw3-da3-mono','models/iw3','licenses/iw3')){
        if($Relative-eq'models/iw3'){
            $Source=Join-Path $MainModelSource $Relative
            if(Test-Path -LiteralPath $Source){
                $Destination=Join-Path $Target $Relative
                New-Item -ItemType Directory -Force -Path $Destination|Out-Null
                Get-ChildItem -LiteralPath $Source | Where-Object {$_.Name-ne'scene_cache'} | Copy-Item -Destination $Destination -Recurse -Force
            }
            continue
        }
        $Source=Join-Path $MainModelSource $Relative
        if(Test-Path -LiteralPath $Source -PathType Container){
            $Destination=Join-Path $Target $Relative
            New-Item -ItemType Directory -Force -Path $Destination|Out-Null
            Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
        }
    }
}
Copy-Item -LiteralPath (Join-Path $Build 'scripts\Install-DepthModels.ps1') -Destination (Join-Path $Target 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $Build 'INSTALL_VR_MODELS.cmd') -Destination $Target -Force
Copy-Item -LiteralPath (Join-Path $Build 'scripts\Install-VRGenerativeModels.ps1') -Destination (Join-Path $Target 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $Build 'scripts\Install-MoebiusModels.ps1') -Destination (Join-Path $Target 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $Build 'scripts\Install-TemporalAtlasModels.ps1') -Destination (Join-Path $Target 'scripts') -Force
Copy-Item -LiteralPath `
    (Join-Path $Build 'app\process-video.ps1'), `
    (Join-Path $Build 'app\realtime-player.ps1'), `
    (Join-Path $Build 'app\source-resolver.psm1'), `
    (Join-Path $Build 'app\depth-models.psm1'), `
    (Join-Path $Build 'app\studio.ps1') `
    -Destination (Join-Path $Target 'app') -Force
Copy-Item -LiteralPath (Join-Path $Build 'dist\DLSS5 Video Studio.exe') -Destination $Target -Force
Copy-Item -LiteralPath (Join-Path $Build 'README_OPTIMIZED_RU.md') -Destination (Join-Path $Target 'README_RU.md') -Force
Copy-Item -LiteralPath (Join-Path $Build 'OPTIMIZATION_V22_RU.md'),(Join-Path $Build 'THIRD_PARTY_NOTICES.md') -Destination $Target -Force
Copy-Item -LiteralPath (Join-Path $Build 'REALTIME_DEPTH_FIX_V22_0_1_RU.md') -Destination $Target -Force
Copy-Item -LiteralPath (Join-Path $Build 'IW3_VR_V22_1_RU.md') -Destination $Target -Force
Copy-Item -LiteralPath (Join-Path $Build 'IW3_DA3_V22_2_RU.md') -Destination $Target -Force
Copy-Item -LiteralPath (Join-Path $Build 'VR_RESEARCH_RU.md') -Destination $Target -Force
Copy-Item -LiteralPath (Join-Path $Build 'VERSION_OPTIMIZED.txt') -Destination (Join-Path $Target 'VERSION.txt') -Force

$PackageVersion = (Get-Content -LiteralPath (Join-Path $Build 'VERSION_OPTIMIZED.txt') -First 1).Trim()
& (Join-Path $Build 'scripts\New-PortableManifest.ps1') -PortableRoot $Target -Version $PackageVersion
& (Join-Path $Build 'scripts\Test-PortableManifest.ps1') -PortableRoot $Target

Write-Output "OPTIMIZED_PORTABLE_OK $Target"
