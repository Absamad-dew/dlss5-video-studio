[CmdletBinding()]
param(
    [string] $PortableRoot = 'D:\DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V11',
    [ValidateSet('All','VideoSmall','DA3Small','DA3Base','DA3Large')] [string] $Selection = 'All'
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($PortableRoot)
$Python = Join-Path $Root 'runtime\python\python.exe'
$Installer = Join-Path $PSScriptRoot '..\python\install_depth_models.py'
if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
    $Installer = Join-Path $Root 'tools\install_depth_models.py'
}
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "Portable Python is missing: $Python" }
if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) { throw "Installer is missing: $Installer" }
$Models = switch ($Selection) {
    'VideoSmall' { @('video-small') }
    'DA3Small' { @('da3-small') }
    'DA3Base' { @('da3-base') }
    'DA3Large' { @('da3-large') }
    default { @('video-small','da3-small','da3-base') }
}
& $Python -B $Installer --target-root (Join-Path $Root 'models\depth') --models @Models
if ($LASTEXITCODE -ne 0) { throw "Depth model installation failed with exit code $LASTEXITCODE" }
