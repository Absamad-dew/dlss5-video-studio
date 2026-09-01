param(
    [Parameter(Mandatory = $true)]
    [string]$PortableRoot,
    [string]$Product = 'DLSS5 Video Studio Realtime RAFT Player Portable',
    [string]$Version = '10.0.0'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $PortableRoot).Path
$manifestPath = Join-Path $root 'MANIFEST.json'
$mutableDirectories = @('output', 'settings', 'temp')
$runtimeFiles = @(
    'engine/ReShade.ini',
    'engine/ReShade.log',
    'engine/ReShade.log.previous',
    'engine/dlss5-video-host.log',
    'engine/dlss5-video-host.log.previous'
)

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

$files = @(
    foreach ($item in (Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)) {
        if ($item.FullName -eq $manifestPath) { continue }
        $relative = $item.FullName.Substring($root.Length).TrimStart('\') -replace '\\', '/'
        $isMutable = $runtimeFiles -contains $relative
        if ($relative -match '(^|/)__pycache__/' -or $relative -match '\.py[co]$') {
            $isMutable = $true
        }
        foreach ($directory in $mutableDirectories) {
            if ($relative -eq $directory -or $relative.StartsWith($directory + '/', [StringComparison]::OrdinalIgnoreCase)) {
                $isMutable = $true
                break
            }
        }
        if ($isMutable) { continue }
        [ordered]@{
            path = $relative
            size = [int64]$item.Length
            sha256 = Get-Sha256Hex -Path $item.FullName
        }
    }
)

$totalBytes = [int64]0
foreach ($entry in @($files)) {
    $totalBytes += [int64]$entry['size']
}

$manifest = [ordered]@{
    schema = 'dlss5-video-studio-portable/1'
    product = $Product
    version = $Version
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    mutableDirectories = $mutableDirectories
    runtimeFiles = $runtimeFiles
    fileCount = @($files).Count
    totalBytes = $totalBytes
    files = @($files)
}

$json = $manifest | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($manifestPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Write-Output "MANIFEST_OK files=$($manifest.fileCount) bytes=$($manifest.totalBytes) path=$manifestPath"
