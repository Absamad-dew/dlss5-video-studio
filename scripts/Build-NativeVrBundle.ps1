[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$Build=Split-Path -Parent $PSScriptRoot
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$Payload=Join-Path $OutputDirectory ('payload-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $Payload -Force | Out-Null
$Files=@('app/studio.ps1','app/studio-workspace.ps1','app/studio-theme.xaml','app/studio-shell.xaml','app/process-video.ps1','python/guidegen.py','python/vr_depth_worker.py',
    'python/vr_shared_depth.py','python/vr_cuda_graph.py','python/vr_reconstruction.py','python/vr_quality_worker.py',
    'python/vr_atlas.py','python/vr_depth_execution.py','python/vr_stream.py',
    'scripts/Deploy-NativeVrUpdate.ps1','NATIVE_VR_RU.md','NATIVE_VR_QA_RU.md')
foreach($Name in $Files){
    $Destination=Join-Path $Payload $Name
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Build $Name) -Destination $Destination
}
$Zip=Join-Path $OutputDirectory ('native-vr-update-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.zip')
Compress-Archive -Path (Join-Path $Payload '*') -DestinationPath $Zip -CompressionLevel Optimal
[pscustomobject]@{path=$Zip;sha256=(Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash;bytes=(Get-Item -LiteralPath $Zip).Length}|ConvertTo-Json
