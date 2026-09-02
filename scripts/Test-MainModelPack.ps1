[CmdletBinding()]
param([Parameter(Mandatory)] [string] $ProgramRoot)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($ProgramRoot)
$ManifestPath = Join-Path $Root 'MAIN_MODEL_PACK_MANIFEST.json'
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Main model manifest is missing: $ManifestPath"
}
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($Manifest.schema -ne 'dlss5-video-studio-main-model-pack/1') {
    throw "Unsupported main model pack schema: $($Manifest.schema)"
}

function Get-Sha256Hex([string] $Path) {
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
    finally { $Stream.Dispose(); $Sha.Dispose() }
}

foreach ($Entry in $Manifest.files) {
    $Path = Join-Path $Root ([string]$Entry.path).Replace('/','\')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing model-pack file: $Path" }
    $Item = Get-Item -LiteralPath $Path
    if ([int64]$Item.Length -ne [int64]$Entry.size) { throw "Wrong size for $Path" }
    if ((Get-Sha256Hex $Path) -ne [string]$Entry.sha256) { throw "Wrong SHA256 for $Path" }
}
Write-Output ("MAIN_MODEL_PACK_VERIFY_OK version={0} files={1} bytes={2}" -f $Manifest.version,$Manifest.files.Count,$Manifest.totalBytes)
