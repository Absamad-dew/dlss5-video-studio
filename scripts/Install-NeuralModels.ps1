param([switch] $Force)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($PSScriptRoot)
if ((Split-Path -Leaf $Root) -eq 'scripts') { $Root = Split-Path -Parent $Root }
$Python = Join-Path $Root 'runtime\python\python.exe'
$Models = Join-Path $Root 'models\upscalers'

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Portable Python runtime is missing: $Python"
}
New-Item -ItemType Directory -Force -Path $Models | Out-Null

function Has-LargeFile([string] $Path, [int64] $MinimumBytes) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path).Length -ge $MinimumBytes
}

$Flash = Join-Path $Models 'flashvsr-v1.1'
$FlashCheckpoint = Join-Path $Flash 'diffusion_pytorch_model_streaming_dmd.safetensors'
if ($Force -or -not (Has-LargeFile $FlashCheckpoint 5GB)) {
    Write-Output 'Downloading official FlashVSR v1.1 weights...'
    & $Python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='JunhaoZhuang/FlashVSR-v1.1', local_dir=r'$Flash', allow_patterns=['diffusion_pytorch_model_streaming_dmd.safetensors','LQ_proj_in.ckpt','TCDecoder.ckpt'])"
    if ($LASTEXITCODE -ne 0) { throw 'FlashVSR v1.1 download failed.' }
}

$DLoRAL = Join-Path $Models 'dloral'
New-Item -ItemType Directory -Force -Path $DLoRAL | Out-Null
$Sd21 = Join-Path $DLoRAL 'stable-diffusion-2-1-base'
$SdUnet = Join-Path $Sd21 'unet\diffusion_pytorch_model.fp16.safetensors'
if ($Force -or -not (Has-LargeFile $SdUnet 1GB)) {
    Write-Output 'Downloading the minimal FP16 Stable Diffusion 2.1 backbone required by DLoRAL...'
    & $Python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='yujingsun/stable-diffusion-2-1-base', local_dir=r'$Sd21', allow_patterns=['scheduler/scheduler_config.json','tokenizer/*','text_encoder/config.json','text_encoder/model.fp16.safetensors','unet/config.json','unet/diffusion_pytorch_model.fp16.safetensors','vae/config.json','vae/diffusion_pytorch_model.fp16.safetensors'])"
    if ($LASTEXITCODE -ne 0) { throw 'Stable Diffusion 2.1 download failed.' }
}

$SpyNet = Join-Path $DLoRAL 'spynet_20210409-c6c1bd09.pth'
if ($Force -or -not (Has-LargeFile $SpyNet 1MB)) {
    Write-Output 'Downloading the official SPyNet optical-flow weights required by DLoRAL...'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://download.openmmlab.com/mmediting/restorers/basicvsr/spynet_20210409-c6c1bd09.pth' -OutFile $SpyNet
}

$DLoRALCheckpoint = Join-Path $DLoRAL 'model.pkl'
if ($Force -or -not (Has-LargeFile $DLoRALCheckpoint 100MB)) {
    Write-Output 'Downloading the official DLoRAL checkpoint from Google Drive...'
    $Urls = @(
        'https://drive.google.com/uc?id=1C2TLERta3a-PkoMpqQhHoM_S54pNEASO',
        'https://drive.google.com/uc?id=1ycreq0wxmqVUaN3ORQXJfCtqDyD7RlUV'
    )
    $Downloaded = $false
    foreach ($Url in $Urls) {
        & $Python -m gdown $Url -O $DLoRALCheckpoint
        if ($LASTEXITCODE -eq 0 -and (Has-LargeFile $DLoRALCheckpoint 100MB)) {
            $Downloaded = $true
            break
        }
    }
    if (-not $Downloaded) {
        Write-Warning 'The official Google Drive links are rate-limited. Trying the checksum-pinned Hugging Face mirror...'
        & $Python -c "from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='ighoshsubho/DLoraL-Upscaler-Models', filename='model.pkl', local_dir=r'$DLoRAL')"
        if ($LASTEXITCODE -eq 0 -and (Has-LargeFile $DLoRALCheckpoint 3GB)) {
            & $Python -c "import hashlib,pathlib; p=pathlib.Path(r'$DLoRALCheckpoint'); f=p.open('rb'); h=hashlib.file_digest(f,'sha256').hexdigest(); f.close(); assert p.stat().st_size==3572333304 and h=='89ca79785c99fac07f59ad6876d2d707fcce87a088c15930956cb393e517d0df', (p.stat().st_size,h); print('DLoRAL mirror checksum verified.')"
            if ($LASTEXITCODE -eq 0) { $Downloaded = $true }
        }
    }
    if (-not $Downloaded) {
        if (Test-Path -LiteralPath $DLoRALCheckpoint -PathType Leaf) { Remove-Item -LiteralPath $DLoRALCheckpoint -Force }
        Write-Warning 'DLoRAL could not be downloaded or verified. FlashVSR, NanoVSR and AnimeSR remain ready. Retry INSTALL_MODELS.cmd later.'
        Write-Output 'MODEL_STATUS NanoVSR=ready AnimeSR_v2=ready FlashVSR_v1.1=ready DLoRAL=pending-download'
        exit 0
    }
}

Write-Output 'MODEL_STATUS NanoVSR=ready AnimeSR_v2=ready FlashVSR_v1.1=ready DLoRAL=ready'
