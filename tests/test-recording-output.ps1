[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Video,
    [Parameter(Mandatory)] [string] $Ffmpeg,
    [Parameter(Mandatory)] [string] $Ffprobe,
    [Parameter(Mandatory)] [int] $ExpectedWidth,
    [Parameter(Mandatory)] [int] $ExpectedHeight,
    [Parameter(Mandatory)] [int] $ExpectedFrames,
    [Parameter(Mandatory)] [double] $ExpectedDuration
)

$ErrorActionPreference = 'Stop'
foreach ($Path in @($Video,$Ffmpeg,$Ffprobe)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing test input: $Path" }
}

$Probe = (& $Ffprobe -v error -count_frames -show_entries `
    'stream=index,codec_type,codec_name,width,height,nb_read_frames,duration:format=duration' `
    -of json $Video | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'ffprobe failed' }
$VideoStream = @($Probe.streams | Where-Object codec_type -eq 'video')
$AudioStream = @($Probe.streams | Where-Object codec_type -eq 'audio')
if ($VideoStream.Count -ne 1) { throw "Expected one video stream, got $($VideoStream.Count)" }
if ($AudioStream.Count -ne 1) { throw "Expected one audio stream, got $($AudioStream.Count)" }
if ([int]$VideoStream[0].width -ne $ExpectedWidth -or [int]$VideoStream[0].height -ne $ExpectedHeight) {
    throw "Unexpected geometry $($VideoStream[0].width)x$($VideoStream[0].height)"
}
if ([int]$VideoStream[0].nb_read_frames -ne $ExpectedFrames) {
    throw "Expected $ExpectedFrames decoded frames, got $($VideoStream[0].nb_read_frames)"
}
$Duration = [double]$Probe.format.duration
if ([math]::Abs($Duration-$ExpectedDuration) -gt 0.06) {
    throw "Expected duration $ExpectedDuration s, got $Duration s"
}

& $Ffmpeg -v error -i $Video -map '0:v:0' -map '0:a:0' -f null NUL
if ($LASTEXITCODE -ne 0) { throw 'Full video/audio decode failed' }

[pscustomobject]@{
    status='ok'
    video=[IO.Path]::GetFullPath($Video)
    codec=$VideoStream[0].codec_name
    geometry=@([int]$VideoStream[0].width,[int]$VideoStream[0].height)
    frames=[int]$VideoStream[0].nb_read_frames
    duration_seconds=$Duration
    audio_codec=$AudioStream[0].codec_name
} | ConvertTo-Json -Compress
