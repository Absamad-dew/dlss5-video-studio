param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$Build=Split-Path -Parent $PSScriptRoot
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$Stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$Payload=Join-Path $OutputDirectory ('interface-payload-'+$Stamp)
New-Item -ItemType Directory -Force -Path $Payload|Out-Null
function Bundle-Hash([string]$Path){$Stream=[IO.File]::OpenRead($Path);$Hash=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($Hash.ComputeHash($Stream))).Replace('-','')}finally{$Stream.Dispose();$Hash.Dispose()}}
$Manifest=@()
foreach($Name in @('app/studio-theme.xaml','app/studio-shell.xaml','app/studio-workspace.ps1','app/iw3-ui.ps1','app/studio.ps1','dist/DLSS5 Video Studio.exe','dist/engine/dlss5-video-host.exe','scripts/Deploy-InterfaceUpdate.ps1','INTERFACE_RU.md')){
    $Destination=Join-Path $Payload $Name
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination)|Out-Null
    Copy-Item -LiteralPath (Join-Path $Build $Name) -Destination $Destination
    $Manifest+=@{path=$Name;sha256=(Bundle-Hash $Destination)}
}
[IO.File]::WriteAllText((Join-Path $Payload 'interface-manifest.json'),($Manifest|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$Zip=Join-Path $OutputDirectory ('interface-update-'+$Stamp+'.zip')
Compress-Archive -Path (Join-Path $Payload '*') -DestinationPath $Zip -CompressionLevel Optimal
[pscustomobject]@{path=$Zip;sha256=(Bundle-Hash $Zip);bytes=(Get-Item -LiteralPath $Zip).Length}|ConvertTo-Json
