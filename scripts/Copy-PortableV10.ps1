[CmdletBinding()]
param(
    [string] $Source = 'D:\DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V9',
    [string] $Destination = 'D:\DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V10'
)

$ErrorActionPreference = 'Stop'
$SourcePath = (Resolve-Path -LiteralPath $Source).Path
$DestinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $DestinationPath) {
    throw "Destination already exists: $DestinationPath"
}
if (-not $DestinationPath.StartsWith('D:\DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V10', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unexpected destination: $DestinationPath"
}

New-Item -ItemType Directory -Path $DestinationPath | Out-Null
& robocopy.exe $SourcePath $DestinationPath /E /R:1 /W:1 /MT:8 /XD (Join-Path $SourcePath 'temp') /XF MANIFEST.json /NFL /NDL /NP
$RobocopyCode = $LASTEXITCODE
if ($RobocopyCode -gt 7) {
    throw "Robocopy failed with exit code $RobocopyCode"
}
New-Item -ItemType Directory -Path (Join-Path $DestinationPath 'temp') -Force | Out-Null
Write-Output "PORTABLE_COPY_OK source=$SourcePath destination=$DestinationPath robocopy=$RobocopyCode"
