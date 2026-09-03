[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EngineDirectory,
    [Parameter(Mandatory)] [string] $Ffmpeg,
    [Parameter(Mandatory)] [string] $Fixture,
    [ValidateSet('h264','h265')] [string] $Codec='h265',
    [int] $Width=2560, [int] $Height=1440, [int] $Frames=120, [int] $Fps=25
)
$ErrorActionPreference='Stop'
$Fixture=[IO.Path]::GetFullPath($Fixture)
if ((Get-Item -LiteralPath (Join-Path $Fixture 'input.nv12')).Length -ne [long]$Width*$Height*3L/2L*$Frames) {
    throw 'Fixture must contain exactly the requested frames/geometry; prepare a separate fixture for a short-drain test.'
}
$Capture=Join-Path $Fixture "rendered-$Codec.nv12"
$Direct=Join-Path $Fixture "direct-$Codec.mp4"
$Reference=Join-Path $Fixture "reference-$Codec.mp4"
& (Join-Path $PSScriptRoot 'benchmark-native-nv12-pipe.ps1') -EngineDirectory $EngineDirectory -Ffmpeg $Ffmpeg `
    -InputFile (Join-Path $Fixture 'input.nv12') -Motion (Join-Path $Fixture 'motion.bin') -Depth (Join-Path $Fixture 'depth.bin') `
    -Width $Width -Height $Height -Frames $Frames -Fps $Fps -Codec $Codec -Output $Direct -DirectD3D12 -CaptureReference $Capture
if($LASTEXITCODE -ne 0) { throw 'Direct capture failed' }
$Encoder=if($Codec -eq 'h265'){'hevc_nvenc'}else{'h264_nvenc'}
$Tag=if($Codec -eq 'h265'){@('-tag:v','hvc1')}else{@()}
$Color=@('-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709','-color_range','tv')
# Encode the EXACT rendered bytes captured from the direct run. Separate NGX
# runs can differ slightly; that must not masquerade as encoder quality loss.
& $Ffmpeg -y -v error -f rawvideo -pixel_format nv12 -video_size "${Width}x${Height}" -framerate $Fps @Color `
    -i $Capture -frames:v $Frames -an -c:v $Encoder -preset p1 -tune ll -rc constqp -qp 18 -pix_fmt nv12 @Color @Tag -movflags +faststart $Reference
if($LASTEXITCODE -ne 0) { throw 'Reference encode failed' }
& (Join-Path $PSScriptRoot 'compare-video-frames.ps1') -Reference $Reference -Candidate $Direct -Ffmpeg $Ffmpeg
if($LASTEXITCODE -ne 0) { throw 'Direct encoder did not preserve reference pixels/timestamps' }
