[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EngineDirectory,
    [Parameter(Mandatory)] [string] $Ffmpeg,
    [Parameter(Mandatory)] [string] $InputFile,
    [Parameter(Mandatory)] [string] $Motion,
    [Parameter(Mandatory)] [string] $Depth,
    [Parameter(Mandatory)] [string] $Output,
    [int] $Width = 2560,
    [int] $Height = 1440,
    [int] $Frames = 120,
    [int] $Fps = 25
)

$ErrorActionPreference = 'Stop'
$EngineDirectory = (Resolve-Path -LiteralPath $EngineDirectory).Path
$HostExe = Join-Path $EngineDirectory 'dlss5-video-host.exe'
foreach ($Path in @($HostExe,$Ffmpeg,$InputFile,$Motion,$Depth)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing benchmark input: $Path" }
}
$Ffmpeg = (Resolve-Path -LiteralPath $Ffmpeg).Path
$InputFile = (Resolve-Path -LiteralPath $InputFile).Path
$Motion = (Resolve-Path -LiteralPath $Motion).Path
$Depth = (Resolve-Path -LiteralPath $Depth).Path
$Output = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Path (Split-Path -Parent $Output) -Force | Out-Null
$PreviousPath = $env:Path
try {
    $env:Path = (Split-Path -Parent ([IO.Path]::GetFullPath($Ffmpeg))) + ';' + $env:Path
    Push-Location $EngineDirectory
    try {
        $Console = (& $HostExe --batch --input $InputFile --input-format nv12 --motion $Motion --depth $Depth `
            --encode-mp4 $Output --width $Width --height $Height --output-width $Width --output-height $Height `
            --frames $Frames --fps $Fps --codec h265 --quality 18 --fast-start --timings --quiet-frames 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "native benchmark failed: $Console" }
    } finally { Pop-Location }
} finally { $env:Path = $PreviousPath }

$HostLog = Get-Content -LiteralPath (Join-Path $EngineDirectory 'dlss5-video-host.log') -Raw
$Timing = [regex]::Match($HostLog,'DLSS5_BATCH_TIMING[^\r\n]+')
if (-not $Timing.Success) { throw 'native timing line was not produced' }
function Metric([string] $Name) {
    $Match = [regex]::Match($Timing.Value,"(?:^|\s)$([regex]::Escape($Name))=(?<v>[0-9.]+)")
    if (-not $Match.Success) { return $null }
    return [double]::Parse($Match.Groups['v'].Value,[Globalization.CultureInfo]::InvariantCulture)
}
$TotalMs = Metric 'total_ms'
[ordered]@{
    status = 'ok'
    geometry = @($Width,$Height)
    frames = $Frames
    host_fps = if($TotalMs -gt 0){[math]::Round(1000.0*$Frames/$TotalMs,3)}else{0}
    per_frame_ms = Metric 'per_frame_ms'
    writer_wait_ms = Metric 'writer_wait_ms'
    write_ms = Metric 'write_ms'
    readback_wait_ms = Metric 'readback_wait_ms'
    readback_pack_ms = Metric 'readback_pack_ms'
    output = $Output
} | ConvertTo-Json -Compress
