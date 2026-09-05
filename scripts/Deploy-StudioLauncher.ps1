[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetRoot,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$ExpectedSha256
)
$ErrorActionPreference='Stop'
function Launcher-Hash([string]$Path){
    $Stream=[IO.File]::OpenRead($Path);$Hasher=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-','')}finally{$Hasher.Dispose();$Stream.Dispose()}
}
$TargetRoot=[IO.Path]::GetFullPath($TargetRoot).TrimEnd('\','/')
$SourcePath=[IO.Path]::GetFullPath($SourcePath)
$Destination=Join-Path $TargetRoot 'DLSS5 Video Studio.exe'
if(-not(Test-Path -LiteralPath (Join-Path $TargetRoot 'app/studio.ps1')) -or -not(Test-Path -LiteralPath $Destination)){
    throw 'Not an existing Studio installation'
}
if((Launcher-Hash $SourcePath)-ne $ExpectedSha256){throw 'Launcher payload hash mismatch'}
$Backup=Join-Path $TargetRoot ('temp/launcher-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $Backup|Out-Null
$Staged=Join-Path $Backup 'launcher.new.exe'
$Old=Join-Path $Backup 'DLSS5 Video Studio.exe'
$PreviousHash=Launcher-Hash $Destination
Copy-Item -LiteralPath $SourcePath -Destination $Staged
if((Launcher-Hash $Staged)-ne$ExpectedSha256){throw 'Staged launcher hash mismatch'}
# Rename only this executable; existing Windows processes keep their old image.
# Never stop a running Studio or touch scripts, models, settings or output.
Move-Item -LiteralPath $Destination -Destination $Old
try{
    Move-Item -LiteralPath $Staged -Destination $Destination
    if((Launcher-Hash $Destination)-ne$ExpectedSha256){throw 'Installed launcher hash mismatch'}
}catch{
    if(Test-Path -LiteralPath $Destination){Move-Item -LiteralPath $Destination -Destination (Join-Path $Backup 'launcher.failed.exe')}
    Move-Item -LiteralPath $Old -Destination $Destination
    throw
}
$Report=[ordered]@{target=$Destination;sha256=(Launcher-Hash $Destination);previous_sha256=$PreviousHash;backup=$Old;running_processes_stopped=$false;tests_on_target=$false}
$Json=$Report|ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $Backup 'update.json'),$Json,[Text.UTF8Encoding]::new($false))
$Json
