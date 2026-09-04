[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PortableRoot,
    [Parameter(Mandatory)] [string] $OutputArchive,
    [string] $Version = '21.0.0',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $PortableRoot).Path
$Archive = [IO.Path]::GetFullPath($OutputArchive)
$ArchiveParent = Split-Path -Parent $Archive
New-Item -ItemType Directory -Path $ArchiveParent -Force | Out-Null
if (Test-Path -LiteralPath $Archive) {
    if (-not $Force) { throw "Output archive already exists: $Archive" }
    Remove-Item -LiteralPath $Archive -Force
}
$Stage = Join-Path $ArchiveParent ('.main-model-pack-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Stage | Out-Null

function Get-Sha256Hex([string] $Path) {
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
    finally { $Stream.Dispose(); $Sha.Dispose() }
}

function Copy-PackPath([string] $RelativePath) {
    $Source = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $Source)) { throw "Required main-model path is missing: $Source" }
    $Target = Join-Path $Stage $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
    if ((Get-Item -LiteralPath $Source).PSIsContainer) {
        Copy-Item -LiteralPath $Source -Destination $Target -Recurse -Force
    } else {
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }
}

try {
    foreach ($Relative in @(
        'models\depth_anything_v2_small.onnx',
        'models\depth\da3-small',
        'models\depth\video_depth_anything_vits.pth',
        'third_party\video-depth-anything',
        'models\motion\raft_small_C_T_V2-01064c6d.pth',
        'models\vr\migan',
        'licenses\DEPTH_ANYTHING_V2_APACHE2.txt',
        'licenses\DEPTH_ANYTHING_ONNX_APACHE2.txt',
        'licenses\vr\MI-GAN-MIT.txt'
    )) { Copy-PackPath $Relative }

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-MainModelPack.ps1') -Destination (Join-Path $Stage 'VERIFY_MAIN_MODELS.ps1') -Force
    $Cmd = @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0VERIFY_MAIN_MODELS.ps1" -ProgramRoot "%~dp0"
pause
'@
    [IO.File]::WriteAllText((Join-Path $Stage 'VERIFY_MAIN_MODELS.cmd'), ($Cmd.Trim() -replace "`n","`r`n") + "`r`n", [Text.Encoding]::ASCII)
    $Readme = @'
DLSS5 VIDEO STUDIO — MAIN MODELS V{VERSION}

Распакуйте содержимое прямо в корень portable-папки рядом с
DLSS5 Video Studio.exe. Дополнительную вложенную папку создавать не нужно.

Архив добавляет главные модели: DA2 Small, DA3 Small, Video Depth Anything Small
(вместе с кодом потоковой обработки), RAFT Small и
компактную MI-GAN для остаточных областей Temporal Atlas. После
распаковки запустите VERIFY_MAIN_MODELS.cmd.
Успешная проверка заканчивается строкой MAIN_MODEL_PACK_VERIFY_OK.

Программа, NVIDIA DLL и тяжёлые экспериментальные модели сюда не входят.
'@
    $Readme = $Readme.Replace('{VERSION}',$Version)
    [IO.File]::WriteAllText((Join-Path $Stage 'README_MAIN_MODELS_RU.txt'), $Readme.Trim() + "`r`n", (New-Object Text.UTF8Encoding($true)))

    $Files = @()
    foreach ($File in Get-ChildItem -LiteralPath $Stage -Recurse -File | Sort-Object FullName) {
        if ($File.Name -eq 'MAIN_MODEL_PACK_MANIFEST.json') { continue }
        $Relative = $File.FullName.Substring($Stage.Length).TrimStart('\').Replace('\','/')
        $Files += [pscustomobject][ordered]@{
            path = $Relative
            size = [int64]$File.Length
            sha256 = Get-Sha256Hex $File.FullName
        }
    }
    $TotalBytes = [int64](($Files | Measure-Object size -Sum).Sum)
    $Manifest = [ordered]@{
        schema = 'dlss5-video-studio-main-model-pack/1'
        version = $Version
        extractionRoot = 'DLSS5 Video Studio portable root'
        includedProfiles = @('DA2Small','DA3Small','VideoDepthSmall','RAFTSmall','TemporalAtlasMIGAN')
        totalBytes = $TotalBytes
        files = $Files
    }
    [IO.File]::WriteAllText((Join-Path $Stage 'MAIN_MODEL_PACK_MANIFEST.json'), ($Manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))

    $Tar = (Get-Command tar.exe -ErrorAction Stop).Source
    & $Tar -a -cf $Archive -C $Stage .
    if ($LASTEXITCODE -ne 0) { throw "Archive creation failed: tar exit $LASTEXITCODE" }
    $ArchiveItem = Get-Item -LiteralPath $Archive
    Write-Output ("MAIN_MODEL_PACK_OK archive={0} bytes={1} sha256={2} payload_bytes={3} payload_files={4}" -f $Archive,$ArchiveItem.Length,(Get-Sha256Hex $Archive),$TotalBytes,$Files.Count)
}
finally {
    $ResolvedParent = [IO.Path]::GetFullPath($ArchiveParent).TrimEnd('\') + '\'
    $ResolvedStage = [IO.Path]::GetFullPath($Stage)
    if ($ResolvedStage.StartsWith($ResolvedParent,[StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $ResolvedStage)) {
        Remove-Item -LiteralPath $ResolvedStage -Recurse -Force
    }
}
