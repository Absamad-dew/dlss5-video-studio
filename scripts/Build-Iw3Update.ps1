param([Parameter(Mandatory)][string]$PortableRoot,[Parameter(Mandatory)][string]$OutputZip)
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $PortableRoot).Path
if(Test-Path -LiteralPath $OutputZip){throw 'Update archive already exists.'}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-Hash([string]$Path){
    $Sha=[Security.Cryptography.SHA256]::Create();$Stream=[IO.File]::OpenRead($Path)
    try{return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant()}
    finally{$Stream.Dispose();$Sha.Dispose()}
}
$Singles=@('app/studio.ps1','app/process-video.ps1','app/process-iw3.ps1','app/iw3-ui.ps1','app/iw3-settings.json',
    'tools/iw3/iw3_worker.py','tools/iw3/install_iw3.py','tools/iw3/iw3-lock.json','tools/iw3/iw3_da3.py','tools/iw3/iw3_da3_install.py','app/iw3-da3-models.json','scripts/Install-Iw3Da3.ps1',
    'scripts/Install-Iw3.ps1','scripts/New-PortableManifest.ps1','INSTALL_IW3.cmd',
    'IW3_VR_V22_1_RU.md','IW3_DA3_V22_2_RU.md','README_RU.md','THIRD_PARTY_NOTICES.md','VERSION_OPTIMIZED.txt')
$Files=[Collections.Generic.List[object]]::new()
foreach($Relative in $Singles){$Files.Add((Get-Item -LiteralPath (Join-Path $Root $Relative)))}
foreach($Relative in @('third_party/nunif','models/iw3','licenses/iw3','third_party/iw3-da3','third_party/iw3-da3-mono')){
    if(-not(Test-Path -LiteralPath (Join-Path $Root $Relative))){continue}
    foreach($Item in (Get-ChildItem -LiteralPath (Join-Path $Root $Relative) -File -Recurse)){
        $Name=$Item.FullName.Substring($Root.Length).TrimStart('\').Replace('\','/')
        if($Name -match '(^|/)(__pycache__|scene_cache)/' -or $Name -match '\.py[co]$'){continue}
        $Files.Add($Item)
    }
}
# Include DA3 Main checkpoints only if present; never bundle a readiness marker
# while silently omitting its installed model from an all-model update archive.
$Da3=Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $Root 'app/iw3-da3-models.json')|ConvertFrom-Json
foreach($Model in $Da3.models){
    if($Model.path.StartsWith('models/iw3/')){continue}
    $Checkpoint=Join-Path $Root $Model.path
    if(Test-Path -LiteralPath $Checkpoint){
        $Files.Add((Get-Item -LiteralPath $Checkpoint))
        Get-ChildItem -LiteralPath (Split-Path -Parent $Checkpoint) -Filter '*MODEL_CARD.md' -File | ForEach-Object {$Files.Add($_)}
    }
}
$Manifest=[Collections.Generic.List[object]]::new()
$Archive=[IO.Compression.ZipFile]::Open($OutputZip,[IO.Compression.ZipArchiveMode]::Create)
try{
    foreach($Item in $Files){
        $Relative=$Item.FullName.Substring($Root.Length).TrimStart('\').Replace('\','/')
        $Manifest.Add([ordered]@{path=$Relative;bytes=$Item.Length;sha256=(Get-Hash $Item.FullName)})
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive,$Item.FullName,$Relative,[IO.Compression.CompressionLevel]::Fastest)|Out-Null
    }
    $Entry=$Archive.CreateEntry('IW3_UPDATE_MANIFEST.json')
    $Writer=[IO.StreamWriter]::new($Entry.Open(),[Text.UTF8Encoding]::new($false))
    try{$Writer.Write((@{version='22.2.1-iw3-geometry';files=@($Manifest.ToArray())}|ConvertTo-Json -Depth 5))}finally{$Writer.Dispose()}
}finally{$Archive.Dispose()}
Write-Output ('IW3_UPDATE_BUILT '+(Get-Hash $OutputZip)+' '+(Get-Item -LiteralPath $OutputZip).Length)
