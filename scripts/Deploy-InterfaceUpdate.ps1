[CmdletBinding()]
param([Parameter(Mandatory)][string]$TargetRoot,[string]$SourceRoot)
$ErrorActionPreference='Stop'
if(-not $SourceRoot){$SourceRoot=Split-Path -Parent $PSScriptRoot}
$SourceRoot=[IO.Path]::GetFullPath($SourceRoot)
$TargetRoot=[IO.Path]::GetFullPath($TargetRoot).TrimEnd('\','/')
if(-not(Test-Path -LiteralPath (Join-Path $TargetRoot 'app/process-video.ps1'))){throw 'Not an existing Studio installation'}
function Ui-Hash([string]$Path){
    $Stream=[IO.File]::OpenRead($Path);$Hasher=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-','')}finally{$Hasher.Dispose();$Stream.Dispose()}
}
$Mutex=[Threading.Mutex]::new($false,'Local\DLSS5VideoStudioPipelineV2');$Held=$false
try{
    try{$Held=$Mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$Held=$true}
    if(-not $Held){throw 'Studio is processing. No files changed.'}
    $Busy=@(Get-CimInstance Win32_Process|Where-Object {
        $_.ProcessId-ne$PID -and $_.CommandLine -and $_.CommandLine.Replace('/','\').IndexOf($TargetRoot,[StringComparison]::OrdinalIgnoreCase)-ge 0 -and
        (($_.Name-match'^(python|ffmpeg|dlss5-video-host)') -or ($_.Name-eq'powershell.exe' -and $_.CommandLine-match'-(File|file)\s+.*(process-video|process-iw3|realtime-player)\.ps1'))
    })
    if($Busy.Count){throw 'Active processing found; update refused without stopping it.'}
    $Files=[ordered]@{
        'app/studio-theme.xaml'='app/studio-theme.xaml'
        'app/studio-shell.xaml'='app/studio-shell.xaml'
        'app/studio-workspace.ps1'='app/studio-workspace.ps1'
        'app/iw3-ui.ps1'='app/iw3-ui.ps1'
        'app/studio.ps1'='app/studio.ps1'
        'dist/DLSS5 Video Studio.exe'='DLSS5 Video Studio.exe'
        'dist/engine/dlss5-video-host.exe'='engine/dlss5-video-host.exe'
        'INTERFACE_RU.md'='INTERFACE_RU.md'
    }
    foreach($Name in $Files.Keys){if(-not(Test-Path -LiteralPath (Join-Path $SourceRoot $Name))){throw "Missing payload: $Name"}}
    $LauncherPath=Join-Path $TargetRoot 'DLSS5 Video Studio.exe'
    if((Ui-Hash $LauncherPath)-ne(Ui-Hash (Join-Path $SourceRoot 'dist/DLSS5 Video Studio.exe')) -and (Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -eq $LauncherPath})){
        throw 'Close all Studio windows before updating the launcher. No files changed.'
    }
    $ManifestPath=Join-Path $SourceRoot 'interface-manifest.json'
    if(Test-Path -LiteralPath $ManifestPath){
        foreach($Entry in (Get-Content -LiteralPath $ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json)){
            $EntryPath=[IO.Path]::GetFullPath((Join-Path $SourceRoot $Entry.path))
            if(-not $EntryPath.StartsWith($SourceRoot.TrimEnd('\','/')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid manifest path'}
            if((Ui-Hash $EntryPath)-ne$Entry.sha256){throw "Invalid payload hash: $($Entry.path)"}
        }
    }
    $Protected=@('app/process-video.ps1','app/process-iw3.ps1','app/realtime-player.ps1','app/iw3-settings.json','app/iw3-da3-models.json','settings/iw3.json','settings/presets.json')
    $Before=@{};foreach($Name in $Protected){$Path=Join-Path $TargetRoot $Name;if(Test-Path -LiteralPath $Path){$Before[$Name]=Ui-Hash $Path}}
    $Backup=Join-Path $TargetRoot ('temp/interface-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $Backup|Out-Null
    $Applied=[Collections.Generic.List[object]]::new();$Manifest=@()
    try{
        foreach($Item in $Files.GetEnumerator()){
            $Source=Join-Path $SourceRoot $Item.Key
            $Destination=[IO.Path]::GetFullPath((Join-Path $TargetRoot $Item.Value))
            if(-not $Destination.StartsWith($TargetRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid destination'}
            $Old=Join-Path $Backup $Item.Value;$Existed=Test-Path -LiteralPath $Destination
            if($Existed -and (Ui-Hash $Destination)-eq(Ui-Hash $Source)){
                $Manifest+=@{path=$Item.Value;sha256=(Ui-Hash $Destination);bytes=(Get-Item -LiteralPath $Destination).Length}
                continue
            }
            if($Existed){New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Old)|Out-Null;Copy-Item -LiteralPath $Destination -Destination $Old}
            $Applied.Add(@{path=$Destination;backup=$Old;existed=$Existed})
            Copy-Item -LiteralPath $Source -Destination $Destination -Force
            $Hash=Ui-Hash $Destination;if($Hash-ne(Ui-Hash $Source)){throw 'Checksum mismatch'}
            $Manifest+=@{path=$Item.Value;sha256=$Hash;bytes=(Get-Item -LiteralPath $Destination).Length}
        }
        foreach($Name in $Before.Keys){if((Ui-Hash (Join-Path $TargetRoot $Name))-ne$Before[$Name]){throw "Protected file changed: $Name"}}
        $Report=[ordered]@{target=$TargetRoot;backup=$Backup;restart_studio_required=$true;files=$Manifest;processing_scripts_and_settings_unchanged=$true;tests_on_target=$false}
        $Json=$Report|ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText((Join-Path $Backup 'update.json'),$Json,[Text.UTF8Encoding]::new($false));$Json
    }catch{
        foreach($Item in $Applied){if($Item.existed){Copy-Item -LiteralPath $Item.backup -Destination $Item.path -Force}elseif(Test-Path -LiteralPath $Item.path){Remove-Item -LiteralPath $Item.path}}
        throw
    }
}finally{if($Held){$Mutex.ReleaseMutex()};$Mutex.Dispose()}
