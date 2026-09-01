[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PortableRoot,
    [Parameter(Mandatory)] [string] $OutputArchive,
    [string] $Version = '11.0.1',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $PortableRoot).Path
$Archive = [IO.Path]::GetFullPath($OutputArchive)
$ArchiveParent = Split-Path -Parent $Archive
if (-not (Test-Path -LiteralPath $ArchiveParent -PathType Container)) {
    New-Item -ItemType Directory -Path $ArchiveParent -Force | Out-Null
}
if (Test-Path -LiteralPath $Archive) {
    if (-not $Force) { throw "Output archive already exists: $Archive" }
    Remove-Item -LiteralPath $Archive -Force
}

$Stage = Join-Path ([IO.Path]::GetTempPath()) ('dlss5-core-models-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Stage | Out-Null
function Get-Sha256Hex([string] $Path) {
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
    finally { $Stream.Dispose(); $Sha.Dispose() }
}
try {
    $Entries = @(
        [pscustomobject]@{ Source='models\depth_anything_v2_small.onnx'; Target='models\depth_anything_v2_small.onnx'; Role='DA2 Small realtime depth' },
        [pscustomobject]@{ Source='models\depth\da3-small\config.json'; Target='models\depth\da3-small\config.json'; Role='DA3 Small configuration' },
        [pscustomobject]@{ Source='models\depth\da3-small\model.safetensors'; Target='models\depth\da3-small\model.safetensors'; Role='DA3 Small quality and VR depth' },
        [pscustomobject]@{ Source='models\depth\da3-small\README.md'; Target='models\depth\da3-small\README.md'; Role='DA3 Small model card' },
        [pscustomobject]@{ Source='models\motion\raft_small_C_T_V2-01064c6d.pth'; Target='models\motion\raft_small_C_T_V2-01064c6d.pth'; Role='TorchVision RAFT Small neural motion' },
        [pscustomobject]@{ Source='licenses\DEPTH_ANYTHING_V2_APACHE2.txt'; Target='licenses\model-pack\Depth-Anything-V2-Apache-2.0.txt'; Role='DA2 license' },
        [pscustomobject]@{ Source='licenses\DEPTH_ANYTHING_ONNX_APACHE2.txt'; Target='licenses\model-pack\Depth-Anything-ONNX-Apache-2.0.txt'; Role='DA2 ONNX license' },
        [pscustomobject]@{ Source='third_party\depth-anything-3\LICENSE'; Target='licenses\model-pack\Depth-Anything-3-Apache-2.0.txt'; Role='DA3 license' },
        [pscustomobject]@{ Source='runtime\python\Lib\site-packages\torchvision-0.25.0+cu128.dist-info\LICENSE'; Target='licenses\model-pack\TorchVision-BSD-3-Clause.txt'; Role='TorchVision license' }
    )

    foreach ($Entry in $Entries) {
        $Source = Join-Path $Root $Entry.Source
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required model-pack file is missing: $Source" }
        $Target = Join-Path $Stage $Entry.Target
        New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }

    $VerifierSource = Join-Path $PSScriptRoot 'Test-CoreModelPack.ps1'
    Copy-Item -LiteralPath $VerifierSource -Destination (Join-Path $Stage 'VERIFY_CORE_MODELS.ps1') -Force
    $Cmd = @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0VERIFY_CORE_MODELS.ps1" -ProgramRoot "%~dp0"
pause
'@
    [IO.File]::WriteAllText((Join-Path $Stage 'VERIFY_CORE_MODELS.cmd'), ($Cmd.Trim() -replace "`n","`r`n") + "`r`n", [Text.Encoding]::ASCII)

    $Readme = @'
DLSS5 VIDEO STUDIO — CORE MODELS V11

Распакуйте содержимое архива прямо в корень portable-папки программы,
рядом с DLSS5 Video Studio.exe. Дополнительную вложенную папку создавать не нужно.

После распаковки запустите VERIFY_CORE_MODELS.cmd.
Успешная проверка заканчивается строкой CORE_MODEL_PACK_VERIFY_OK.

Включено: DA2 Small, DA3 Small, TorchVision RAFT Small C_T_V2.
Не включено: программа, NVIDIA DLL, Python/CUDA runtime и тяжёлые опциональные модели.
'@
    [IO.File]::WriteAllText((Join-Path $Stage 'README_CORE_MODELS_RU.txt'), $Readme.Trim() + "`r`n", (New-Object Text.UTF8Encoding($true)))

    $Files = @()
    foreach ($File in Get-ChildItem -LiteralPath $Stage -Recurse -File | Sort-Object FullName) {
        $Relative = $File.FullName.Substring($Stage.Length).TrimStart('\').Replace('\','/')
        $Files += [pscustomobject][ordered]@{
            path = $Relative
            size = [int64]$File.Length
            sha256 = Get-Sha256Hex $File.FullName
            role = if (($Entries | Where-Object Target -eq ($Relative.Replace('/','\')) | Select-Object -First 1)) { ($Entries | Where-Object Target -eq ($Relative.Replace('/','\')) | Select-Object -First 1).Role } else { 'Model pack documentation or verifier' }
        }
    }
    $TotalBytes = [int64](($Files | Measure-Object size -Sum).Sum)
    $Manifest = [ordered]@{
        schema = 'dlss5-video-studio-core-model-pack/1'
        version = $Version
        extractionRoot = 'DLSS5 Video Studio portable root'
        includedProfiles = @('DA2Small','DA3Small','RAFTSmall')
        totalBytes = $TotalBytes
        files = $Files
    }
    [IO.File]::WriteAllText((Join-Path $Stage 'MODEL_PACK_MANIFEST.json'), ($Manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))

    $Tar = (Get-Command tar.exe -ErrorAction Stop).Source
    & $Tar -a -cf $Archive -C $Stage .
    if ($LASTEXITCODE -ne 0) { throw "Archive creation failed: tar exit $LASTEXITCODE" }
    $ArchiveItem = Get-Item -LiteralPath $Archive
    $ArchiveHash = Get-Sha256Hex $Archive
    Write-Output ("CORE_MODEL_PACK_OK archive={0} bytes={1} sha256={2} payload_bytes={3} payload_files={4}" -f $Archive,$ArchiveItem.Length,$ArchiveHash,$TotalBytes,$Files.Count)
}
finally {
    if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
}
