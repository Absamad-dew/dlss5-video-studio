param([Parameter(Mandatory)][string]$PortableRoot,[Parameter(Mandatory)][string]$BundleRoot)
$ErrorActionPreference='Stop'
$Root=(Resolve-Path -LiteralPath $PortableRoot).Path
$Bundle=(Resolve-Path -LiteralPath $BundleRoot).Path
$Items=@(
    @{source='iw3_worker.py';target='tools/iw3/iw3_worker.py';before='F8E8FB05BF2BA6D1C9ACE0BECB2E77B2526D5C24640BD6D6E759F4359EA4F1BF'},
    @{source='iw3_model_assets.py';target='tools/iw3/iw3_model_assets.py';before=$null},
    @{source='studio.ps1';target='app/studio.ps1';before='577B61FCC332B4AF0E70683699DC07A6C336A3C9812A1BCB1DF12332FD3C0966'},
    @{source='VERSION_OPTIMIZED.txt';target='VERSION_OPTIMIZED.txt';before='22DDEFC2D1963F70534CEAECD2C8EF2FAA953F77028F756731ECD060CAF5B815'},
    @{source='IW3_DA3_V22_2_RU.md';target='IW3_DA3_V22_2_RU.md';before='0E6C8A7C3E9FA705CE871A4C8650743EA3B56B6FA012DE5FAEA496FCB07F36BF'}
)
foreach($Item in $Items){
    $Source=Join-Path $Bundle $Item.source
    $Target=Join-Path $Root $Item.target
    if(-not(Test-Path -LiteralPath $Source -PathType Leaf)){throw "Missing bundle file: $Source"}
    if(Test-Path -LiteralPath $Target){
        $Current=(Get-FileHash -LiteralPath $Target).Hash
        if($Current -eq (Get-FileHash -LiteralPath $Source).Hash){continue}
        if(-not $Item.before -or $Current -ne $Item.before){throw "Target has unrelated changes: $Target"}
    }elseif($Item.before){throw "Expected target missing: $Target"}
}
$Backup=Join-Path $Root ('temp/iw3-download-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $Backup | Out-Null
$ManifestPath=Join-Path $Root 'MANIFEST.json'
Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $Backup 'MANIFEST.json')
$Manifest=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Records=@()
foreach($Item in $Items){
    $Source=Join-Path $Bundle $Item.source
    $Target=Join-Path $Root $Item.target
    if(Test-Path -LiteralPath $Target){Copy-Item -LiteralPath $Target -Destination (Join-Path $Backup $Item.source)}
    Copy-Item -LiteralPath $Source -Destination $Target -Force
    $Hash=(Get-FileHash -LiteralPath $Target).Hash.ToLowerInvariant()
    if($Hash -ne (Get-FileHash -LiteralPath $Source).Hash.ToLowerInvariant()){throw "Copy verification failed: $Target"}
    $Record=[pscustomobject]@{path=$Item.target;size=(Get-Item -LiteralPath $Target).Length;sha256=$Hash}
    $Manifest.files=@($Manifest.files | Where-Object {$_.path -ne $Item.target})+@($Record)
    $Records+=@($Record)
}
$Manifest.fileCount=@($Manifest.files).Count
$Manifest.totalBytes=($Manifest.files | Measure-Object size -Sum).Sum
$Manifest.generatedAtUtc=[DateTime]::UtcNow.ToString('o')
[IO.File]::WriteAllText($ManifestPath,($Manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[pscustomobject]@{status='applied';backup=$Backup;files=$Records} | ConvertTo-Json -Depth 5
