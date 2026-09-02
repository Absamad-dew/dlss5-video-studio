[CmdletBinding()]
param([Parameter(Mandatory)] [string] $ArchivePath)

$ErrorActionPreference = 'Stop'
$Archive = (Resolve-Path -LiteralPath $ArchivePath).Path
$ArchiveParent = Split-Path -Parent $Archive
$Stage = Join-Path $ArchiveParent ('.main-model-pack-qa-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Stage | Out-Null
try {
    $Tar = (Get-Command tar.exe -ErrorAction Stop).Source
    & $Tar -xf $Archive -C $Stage
    if ($LASTEXITCODE -ne 0) { throw "Archive extraction failed: tar exit $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath (Join-Path $Stage 'models\vr\migan\migan_pipeline_v2.onnx') -PathType Leaf)) {
        throw 'Archive has an unexpected wrapper or no Temporal Atlas MI-GAN payload.'
    }
    & (Join-Path $Stage 'VERIFY_MAIN_MODELS.ps1') -ProgramRoot $Stage
    if ($LASTEXITCODE -ne 0) { throw "Extracted main-model verification failed: exit $LASTEXITCODE" }
    Write-Output 'MAIN_MODEL_ARCHIVE_OK'
}
finally {
    $ResolvedParent = [IO.Path]::GetFullPath($ArchiveParent).TrimEnd('\') + '\'
    $ResolvedStage = [IO.Path]::GetFullPath($Stage)
    if ($ResolvedStage.StartsWith($ResolvedParent,[StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $ResolvedStage)) {
        Remove-Item -LiteralPath $ResolvedStage -Recurse -Force
    }
}
