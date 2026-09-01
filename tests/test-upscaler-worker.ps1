param(
    [ValidateSet('nanovsr','animesr','flashvsr','dloral')] [string] $Backend = 'nanovsr',
    [string] $Python = 'D:\DLSS5VideoStudioDeps\runtime\python\cpython-3.11.16-windows-x86_64-none\python.exe',
    [string] $ModelRoot = 'D:\DLSS5VideoStudioDeps\models',
    [string] $ThirdPartyRoot = 'D:\DLSS5VideoStudioDeps\src',
    [ValidateRange(64,512)] [int] $InputSize = 64,
    [int] $InputWidth = 0,
    [int] $InputHeight = 0,
    [int] $Frames = 3,
    [ValidateSet('auto','realtime','balanced','quality','max')] [string] $Variant = 'auto'
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Ffmpeg = Join-Path $Root 'dist\portable-placeholder\ffmpeg.exe'
if (-not (Test-Path -LiteralPath $Ffmpeg)) {
    $Ffmpeg = 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_PORTABLE\tools\ffmpeg.exe'
}
$InputVideo = 'D:\DLSS5VideoStudioDeps\src\FlashVSR\examples\WanVSR\inputs\example0.mp4'
$Work = Join-Path 'D:\DLSS5VideoStudioDeps\tests' ($Backend + '-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$InputRaw = Join-Path $Work 'input.rgb'
$OutputRaw = Join-Path $Work 'output.rgb'

try {
    if ($InputWidth -le 0) { $InputWidth = $InputSize }
    if ($InputHeight -le 0) { $InputHeight = $InputSize }
    $OutputWidth = $InputWidth * 4
    $OutputHeight = $InputHeight * 4
    & $Ffmpeg -y -v error -i $InputVideo -vf "scale=$($InputWidth):$($InputHeight):flags=lanczos,format=rgb24" -frames:v $Frames -f rawvideo -pix_fmt rgb24 $InputRaw
    if ($LASTEXITCODE -ne 0) { throw 'Test frame decode failed.' }
    if ($Backend -eq 'nanovsr' -and $Variant -eq 'auto') { $Variant = '226k' }
    $Commands = @(
        (@{cmd='chunk';id=0;input=$InputRaw;output=$OutputRaw;frames=$Frames} | ConvertTo-Json -Compress),
        '{"cmd":"end"}'
    )
    $Output = $Commands | & $Python (Join-Path $Root 'python\upscaler_worker.py') `
        --server --backend $Backend --variant $Variant --model-root $ModelRoot `
        --backend-root (Join-Path $Root 'python\backends') `
        --third-party-root $ThirdPartyRoot `
        --input-width $InputWidth --input-height $InputHeight --output-width $OutputWidth --output-height $OutputHeight --strength 1
    $Output | ForEach-Object { Write-Output $_ }
    if ($LASTEXITCODE -ne 0) { throw "$Backend worker test failed." }
    $Expected = [int64]$Frames * $OutputWidth * $OutputHeight * 3
    $Actual = (Get-Item -LiteralPath $OutputRaw).Length
    if ($Actual -ne $Expected) { throw "Unexpected output size: $Actual, expected $Expected" }
    Write-Output "UPSCALER_TEST_OK backend=$Backend frames=$Frames bytes=$Actual"
}
finally {
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
}
