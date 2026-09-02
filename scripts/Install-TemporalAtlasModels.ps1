[CmdletBinding()]
param([switch] $Force)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Python = Join-Path $Root 'runtime\python\python.exe'
$Worker = Join-Path $Root 'tools\vr_generative\temporal_atlas_worker.py'
$RaftWeights = Join-Path $Root 'models\motion\raft_small_C_T_V2-01064c6d.pth'
$ModelRoot = Join-Path $Root 'models\vr\migan'
$Model = Join-Path $ModelRoot 'migan_pipeline_v2.onnx'
$ExpectedBytes = 28079181
$ExpectedSha256 = '6f1f3530a1a2324b19752018ce756088b07973cda8d7d890034ace5c8a48c40b'
$Uri = 'https://huggingface.co/andraniksargsyan/migan/resolve/main/migan_pipeline_v2.onnx?download=true'

foreach ($Path in @($Python,$Worker,$RaftWeights)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Portable component is missing: $Path"
    }
}

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

function Test-VerifiedModel([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne $ExpectedBytes) { return $false }
    return (Get-Sha256Hex $Path) -eq $ExpectedSha256
}

New-Item -ItemType Directory -Force -Path $ModelRoot | Out-Null
if ($Force -or -not (Test-VerifiedModel $Model)) {
    $Partial = $Model + '.partial'
    Assert-SafeChild $Partial
    if ($Force -and (Test-Path -LiteralPath $Partial -PathType Leaf)) {
        Remove-Item -LiteralPath $Partial -Force
    }
    $Curl = (Get-Command curl.exe -ErrorAction Stop).Source
    Write-Output 'Downloading MI-GAN ONNX for residual Temporal Atlas regions (~28 MB).'
    & $Curl '--location' '--fail' '--retry' '8' '--retry-all-errors' '--retry-delay' '3' `
        '--speed-limit' '1024' '--speed-time' '30' '--continue-at' '-' '--output' $Partial $Uri
    if ($LASTEXITCODE -ne 0) { throw "MI-GAN download failed with curl exit code $LASTEXITCODE" }
    if (-not (Test-VerifiedModel $Partial)) {
        $Actual = if (Test-Path -LiteralPath $Partial -PathType Leaf) { (Get-Item -LiteralPath $Partial).Length } else { 0 }
        throw "MI-GAN verification failed: $Actual of $ExpectedBytes bytes"
    }
    Move-Item -LiteralPath $Partial -Destination $Model -Force
} else {
    Write-Output 'MI-GAN model is already present and verified.'
}

& $Python -s -c "import cv2, onnxruntime, torch, torchvision; print('TEMPORAL_ATLAS_RUNTIME_OK')"
if ($LASTEXITCODE -ne 0) { throw 'Temporal Atlas Python runtime verification failed.' }

$Status = [ordered]@{
    schema = 'dlss5-video-studio-temporal-atlas/1'
    backend = 'Temporal-Atlas-MI-GAN'
    checkpoint_sha256 = Get-Sha256Hex $Model
    checkpoint_bytes = (Get-Item -LiteralPath $Model).Length
    installed_utc = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText(
    (Join-Path $ModelRoot 'install.json'),
    ($Status | ConvertTo-Json -Depth 4),
    (New-Object Text.UTF8Encoding($false))
)
Write-Output 'TEMPORAL_ATLAS_MODELS_READY backend=Temporal-Atlas-MI-GAN download=28MB'
