[CmdletBinding()]
param(
    [string] $ProgramRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($ProgramRoot)
$ManifestPath = Join-Path $Root 'MODEL_PACK_MANIFEST.json'
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Core model manifest is missing: $ManifestPath"
}

$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$Failures = New-Object System.Collections.Generic.List[string]
function Get-Sha256Hex([string] $Path) {
    $Sha = [Security.Cryptography.SHA256]::Create()
    $Stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($Sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
    finally { $Stream.Dispose(); $Sha.Dispose() }
}
foreach ($Entry in $Manifest.files) {
    $Relative = ([string]$Entry.path).Replace('/', '\')
    $Path = Join-Path $Root $Relative
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Failures.Add("missing: $($Entry.path)")
        continue
    }
    $Item = Get-Item -LiteralPath $Path
    if ($Item.Length -ne [int64]$Entry.size) {
        $Failures.Add("size: $($Entry.path)")
        continue
    }
    $Hash = Get-Sha256Hex $Path
    if ($Hash -ne [string]$Entry.sha256) {
        $Failures.Add("sha256: $($Entry.path)")
    }
}

if ($Failures.Count) {
    $Failures | ForEach-Object { Write-Error $_ }
    exit 1
}

$EngineReady = (Test-Path -LiteralPath (Join-Path $Root 'engine\nvngx_dlssnr.dll') -PathType Leaf)
Write-Output ("CORE_MODEL_PACK_VERIFY_OK files={0} bytes={1} engine_ready={2}" -f $Manifest.files.Count,$Manifest.totalBytes,$EngineReady)
