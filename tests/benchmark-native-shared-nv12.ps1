[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EngineDirectory,
    [int] $Width = 2560,
    [int] $Height = 1440,
    [ValidateRange(16,240)] [int] $Frames = 64,
    [int] $Fps = 25,
    [ValidateSet('h264','h265')] [string] $Codec = 'h265',
    [ValidateRange(0,51)] [int] $Quality = 18
)

$ErrorActionPreference = 'Stop'
$EngineDirectory = (Resolve-Path -LiteralPath $EngineDirectory).Path
$HostExe = Join-Path $EngineDirectory 'dlss5-video-host.exe'
if (-not (Test-Path -LiteralPath $HostExe -PathType Leaf)) { throw "Missing native host: $HostExe" }
if (($Width -band 1) -or ($Height -band 1)) { throw 'NV12 geometry must be even.' }
if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) { throw 'ffmpeg.exe is not on PATH.' }

# Pagefile-backed mappings keep the timed path independent from source/video
# disk traffic. The frames are deliberately simple but ABI-correct: a black
# NV12 picture, valid zero motion with full confidence, and constant 0.5 depth.
$Suffix = [guid]::NewGuid().ToString('N')
$InputName = "d5bench_${Suffix}_rgb"
$MotionName = "d5bench_${Suffix}_motion"
$DepthName = "d5bench_${Suffix}_depth"
$Tile = 16
$TilesX = [int][math]::Ceiling($Width / [double]$Tile)
$TilesY = [int][math]::Ceiling($Height / [double]$Tile)
$GridPixels = [int64]$TilesX * $TilesY
$FrameBytes = [int64]$Width * $Height * 3 / 2
$InputBytes = $FrameBytes * $Frames
$MotionBytes = 40L + $GridPixels * 6L * $Frames
$DepthBytes = 28L + $GridPixels * 2L * $Frames
$Access = [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite
$InputMap = $null
$MotionMap = $null
$DepthMap = $null
$MotionStream = $null
$DepthStream = $null
$MotionWriter = $null
$DepthWriter = $null

try {
    $InputMap = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew("Local\$InputName",$InputBytes,$Access)
    $MotionMap = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew("Local\$MotionName",$MotionBytes,$Access)
    $DepthMap = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew("Local\$DepthName",$DepthBytes,$Access)

    $MotionStream = $MotionMap.CreateViewStream(0,$MotionBytes,$Access)
    $MotionWriter = [IO.BinaryWriter]::new($MotionStream,[Text.Encoding]::ASCII,$true)
    $MotionWriter.Write([Text.Encoding]::ASCII.GetBytes('D5MV0003'))
    foreach ($Value in @($Width,$Height,$Tile,$Frames,$TilesX,$TilesY,6,1)) {
        $MotionWriter.Write([uint32]$Value)
    }
    $MotionFrame = [byte[]]::new([int]($GridPixels * 6L))
    for ($Index = 0; $Index -lt $MotionFrame.Length; $Index += 6) {
        $MotionFrame[$Index + 4] = 1
        $MotionFrame[$Index + 5] = 255
    }
    for ($Frame = 0; $Frame -lt $Frames; $Frame++) {
        $MotionWriter.Write($MotionFrame)
    }
    $MotionWriter.Flush()

    $DepthStream = $DepthMap.CreateViewStream(0,$DepthBytes,$Access)
    $DepthWriter = [IO.BinaryWriter]::new($DepthStream,[Text.Encoding]::ASCII,$true)
    $DepthWriter.Write([Text.Encoding]::ASCII.GetBytes('D5DP0002'))
    foreach ($Value in @($Width,$Height,$Frames,2,(1 -bor ($Tile -shl 8)))) {
        $DepthWriter.Write([uint32]$Value)
    }
    $DepthFrame = [byte[]]::new([int]($GridPixels * 2L))
    for ($Index = 0; $Index -lt $DepthFrame.Length; $Index += 2) {
        # IEEE-754 half 0.5 == 0x3800, little endian.
        $DepthFrame[$Index + 1] = 0x38
    }
    for ($Frame = 0; $Frame -lt $Frames; $Frame++) {
        $DepthWriter.Write($DepthFrame)
    }
    $DepthWriter.Flush()

    Push-Location $EngineDirectory
    try {
        $Console = (& $HostExe --batch --input "shm://$InputName" --input-format nv12 `
            --motion "shm://$MotionName" --depth "shm://$DepthName" --encode-mp4 'NUL.mp4' `
            --width $Width --height $Height --output-width $Width --output-height $Height `
            --frames $Frames --fps $Fps --codec $Codec --quality $Quality --fast-start --timings --quiet-frames 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "native shared-memory benchmark failed: $Console" }
    } finally {
        Pop-Location
    }

    $HostLog = Get-Content -LiteralPath (Join-Path $EngineDirectory 'dlss5-video-host.log') -Raw
    $TimingMatches = [regex]::Matches($HostLog,'DLSS5_BATCH_TIMING[^\r\n]+')
    if ($TimingMatches.Count -eq 0) { throw 'native timing line was not produced' }
    $Timing = $TimingMatches[$TimingMatches.Count - 1]
    function Metric([string] $Name) {
        $Match = [regex]::Match($Timing.Value,"(?:^|\s)$([regex]::Escape($Name))=(?<v>[0-9.]+)")
        if (-not $Match.Success) { return $null }
        return [double]::Parse($Match.Groups['v'].Value,[Globalization.CultureInfo]::InvariantCulture)
    }
    $TotalMs = Metric 'total_ms'
    [ordered]@{
        status = 'ok'
        transport = 'pagefile-shared-nv12'
        geometry = @($Width,$Height)
        frames = $Frames
        pipeline = [int](Metric 'pipeline')
        host_fps = if($TotalMs -gt 0){[math]::Round(1000.0*$Frames/$TotalMs,3)}else{0}
        per_frame_ms = Metric 'per_frame_ms'
        writer_wait_ms = Metric 'writer_wait_ms'
        write_ms = Metric 'write_ms'
        readback_wait_ms = Metric 'readback_wait_ms'
        readback_pack_ms = Metric 'readback_pack_ms'
    } | ConvertTo-Json -Compress
} finally {
    if ($DepthWriter) { $DepthWriter.Dispose() }
    if ($MotionWriter) { $MotionWriter.Dispose() }
    if ($DepthStream) { $DepthStream.Dispose() }
    if ($MotionStream) { $MotionStream.Dispose() }
    if ($DepthMap) { $DepthMap.Dispose() }
    if ($MotionMap) { $MotionMap.Dispose() }
    if ($InputMap) { $InputMap.Dispose() }
}
