[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ArchivePath
)

$ErrorActionPreference = 'Stop'
$Archive = (Resolve-Path -LiteralPath $ArchivePath).Path
$Stage = Join-Path ([IO.Path]::GetTempPath()) ('dlss5-core-models-qa-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Stage | Out-Null
try {
    $Tar = (Get-Command tar.exe -ErrorAction Stop).Source
    & $Tar -xf $Archive -C $Stage
    if ($LASTEXITCODE -ne 0) { throw "Archive extraction failed: tar exit $LASTEXITCODE" }

    $RequiredRootFile = Join-Path $Stage 'models\depth_anything_v2_small.onnx'
    if (-not (Test-Path -LiteralPath $RequiredRootFile -PathType Leaf)) {
        throw 'Archive has an unexpected top-level wrapper; it cannot be extracted directly into the program root.'
    }
    $Verifier = Join-Path $Stage 'VERIFY_CORE_MODELS.ps1'
    & $Verifier -ProgramRoot $Stage
    if ($LASTEXITCODE -ne 0) { throw "Extracted model verification failed: exit $LASTEXITCODE" }

    $Manifest = Get-Content -LiteralPath (Join-Path $Stage 'MODEL_PACK_MANIFEST.json') -Raw | ConvertFrom-Json
    Write-Output ("CORE_MODEL_ARCHIVE_OK files={0} bytes={1}" -f $Manifest.files.Count,$Manifest.totalBytes)
}
finally {
    if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
}
