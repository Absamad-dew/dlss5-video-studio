param(
    [Parameter(Mandatory = $true)]
    [string]$PortableRoot
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $PortableRoot).Path
$manifestPath = Join-Path $root 'MANIFEST.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$failures = New-Object System.Collections.Generic.List[string]
$mutableDirectories = @($manifest.mutableDirectories)
$runtimeFiles = @($manifest.runtimeFiles)

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

$declared = @{}
foreach ($entry in $manifest.files) {
    $declared[$entry.path] = $true
    $path = Join-Path $root ($entry.path -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("missing: $($entry.path)")
        continue
    }
    $item = Get-Item -LiteralPath $path
    if ([int64]$item.Length -ne [int64]$entry.size) {
        $failures.Add("size: $($entry.path)")
        continue
    }
    $actualHash = Get-Sha256Hex -Path $path
    if ($actualHash -ne $entry.sha256) {
        $failures.Add("sha256: $($entry.path)")
    }
}

Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -ne $manifestPath } |
    ForEach-Object {
        $relative = $_.FullName.Substring($root.Length).TrimStart('\') -replace '\\', '/'
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
        if ($isMutable) { return }
        if (-not $declared.ContainsKey($relative)) {
            $failures.Add("undeclared: $relative")
        }
    }

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output "MANIFEST_VERIFY_OK files=$($manifest.fileCount) bytes=$($manifest.totalBytes)"
