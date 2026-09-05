[CmdletBinding()]
param([Parameter(Mandatory)][string]$TargetRoot,[string]$SourceRoot)
$ErrorActionPreference='Stop'
# Direct SHA-256 avoids module autoload differences between Windows PS5 and PS7.
function Get-NativeFileHash([string]$LiteralPath,[string]$Algorithm='SHA256'){
    $Stream=[IO.File]::OpenRead($LiteralPath); $Hasher=[Security.Cryptography.SHA256]::Create()
    try{[pscustomobject]@{Hash=([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-','')}}
    finally{$Hasher.Dispose();$Stream.Dispose()}
}
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$TargetRoot=[IO.Path]::GetFullPath($TargetRoot).TrimEnd('\','/')
$SourceRoot=[IO.Path]::GetFullPath($SourceRoot)
if(-not (Test-Path -LiteralPath (Join-Path $TargetRoot 'app/process-video.ps1'))){throw 'Target is not an existing Studio installation'}
$Busy=Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId-ne$PID -and $_.CommandLine -and $_.CommandLine.Replace('/','\').IndexOf($TargetRoot,[StringComparison]::OrdinalIgnoreCase)-ge 0 -and
    $_.Name -match '^(python|dlss5-video-host|ffmpeg)' -and
    $_.CommandLine -match '(vr_depth_worker|guidegen|dlss5-video-host|realtime|upscaler_worker)'
}
if($Busy){throw 'Studio processing is active. Update was not applied; let that job finish first.'}
$Files=[ordered]@{
    'app/studio-workspace.ps1'='app/studio-workspace.ps1'
    'app/studio-theme.xaml'='app/studio-theme.xaml'
    'app/studio-shell.xaml'='app/studio-shell.xaml'
    'app/studio.ps1'='app/studio.ps1'
    'app/process-video.ps1'='app/process-video.ps1'
    'python/guidegen.py'='tools/guidegen/guidegen.py'
    'python/vr_cuda_graph.py'='tools/guidegen/vr_cuda_graph.py'
    'python/vr_shared_depth.py'='tools/guidegen/vr_shared_depth.py'
    'python/vr_depth_execution.py'='tools/guidegen/vr_depth_execution.py'
    'python/vr_depth_worker.py'='tools/vr_depth/vr_depth_worker.py'
    'python/vr_quality_worker.py'='tools/vr_depth/vr_quality_worker.py'
    'python/vr_reconstruction.py'='tools/vr_depth/vr_reconstruction.py'
    'python/vr_atlas.py'='tools/vr_depth/vr_atlas.py'
    'python/vr_stream.py'='tools/vr_depth/vr_stream.py'
    'NATIVE_VR_RU.md'='NATIVE_VR_RU.md'
    'NATIVE_VR_QA_RU.md'='NATIVE_VR_QA_RU.md'
}
# Shared module has two consumers, but no IW3 files are copied or patched.
$Copies=@($Files.GetEnumerator() | ForEach-Object {[pscustomobject]@{source=$_.Key;target=$_.Value}})
$Copies+=[pscustomobject]@{source='python/vr_shared_depth.py';target='tools/vr_depth/vr_shared_depth.py'}
$Protected=@('app/iw3-ui.ps1','app/process-iw3.ps1','app/iw3-settings.json','app/iw3-da3-models.json',
    'tools/iw3/iw3_worker.py','tools/iw3/iw3_da3.py')
$Hashes=@{}
foreach($Name in $Protected){$Path=Join-Path $TargetRoot $Name;if(Test-Path -LiteralPath $Path){$Hashes[$Name]=(Get-NativeFileHash -LiteralPath $Path).Hash}}
foreach($Item in $Copies){if(-not (Test-Path -LiteralPath (Join-Path $SourceRoot $Item.source))){throw "Missing payload: $($Item.source)"}}
$Backup=Join-Path $TargetRoot ('temp/native-vr-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $Backup | Out-Null
$Applied=@();$Manifest=@()
try{
    foreach($Item in $Copies){
        $Source=Join-Path $SourceRoot $Item.source
        $Destination=[IO.Path]::GetFullPath((Join-Path $TargetRoot $Item.target))
        if(-not $Destination.StartsWith($TargetRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe update destination'}
        $Old=Join-Path $Backup $Item.target
        $Existed=Test-Path -LiteralPath $Destination
        if($Existed){New-Item -ItemType Directory -Path (Split-Path -Parent $Old) -Force | Out-Null;Copy-Item -LiteralPath $Destination -Destination $Old}
        New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
        $Applied+=@{path=$Destination;backup=$Old;existed=$Existed}
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        $Hash=(Get-NativeFileHash -LiteralPath $Destination).Hash
        if($Hash-ne(Get-NativeFileHash -LiteralPath $Source).Hash){throw 'Update checksum mismatch'}
        $Manifest+=[ordered]@{path=$Item.target;sha256=$Hash;bytes=(Get-Item -LiteralPath $Destination).Length}
    }
    foreach($Name in $Hashes.Keys){if((Get-NativeFileHash -LiteralPath (Join-Path $TargetRoot $Name)).Hash-ne$Hashes[$Name]){throw "Protected IW3 file changed: $Name"}}
    $Report=[ordered]@{target=$TargetRoot;backup=$Backup;files=$Manifest;iw3_unchanged=$true;tests_on_target=$false;payload_bytes=($Manifest|ForEach-Object {[long]$_['bytes']}|Measure-Object -Sum).Sum}
    $Json=$Report|ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $Backup 'update.json'),$Json,[Text.UTF8Encoding]::new($false))
    $Json
}catch{
    foreach($Item in $Applied){
        if($Item.existed){Copy-Item -LiteralPath $Item.backup -Destination $Item.path -Force}
        elseif(Test-Path -LiteralPath $Item.path){Remove-Item -LiteralPath $Item.path}
    }
    throw
}
