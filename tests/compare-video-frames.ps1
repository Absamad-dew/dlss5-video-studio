[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Reference,
    [Parameter(Mandatory)] [string] $Candidate,
    [Parameter(Mandatory)] [string] $Ffmpeg,
    [string] $Ffprobe = (Join-Path (Split-Path -Parent $Ffmpeg) 'ffprobe.exe')
)
$ErrorActionPreference = 'Stop'
foreach ($Path in @($Reference,$Candidate,$Ffmpeg,$Ffprobe)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing comparison file: $Path" }
}

function Read-VideoEvidence([string] $Path) {
    $ProbeText = & $Ffprobe -v error -select_streams v:0 -show_entries 'stream=width,height,avg_frame_rate,pix_fmt,color_range,color_space,color_transfer,color_primaries,duration:format=duration' -of json $Path
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed for $Path" }
    $Probe = ($ProbeText -join "`n") | ConvertFrom-Json
    if (@($Probe.streams).Count -ne 1) { throw "Expected one primary video stream in $Path" }
    # No scaling/quality filter is allowed in this equivalence test. Both
    # native delivery paths produce 8-bit NV12/yuv420p with BT.709 metadata.
    $Lines = @(& $Ffmpeg -v error -i $Path -map 0:v:0 -an -c:v rawvideo -pix_fmt yuv420p -fps_mode passthrough -f framemd5 -)
    if ($LASTEXITCODE -ne 0) { throw "Frame decode failed for $Path" }
    $Frames = @($Lines | Where-Object { $_ -match '^\s*\d+\s*,' } | ForEach-Object {
        $Fields = $_ -split ','
        if ($Fields.Count -ne 6) { throw 'Unexpected framemd5 schema' }
        [pscustomobject]@{ dts=$Fields[1].Trim(); pts=$Fields[2].Trim(); duration=$Fields[3].Trim(); size=$Fields[4].Trim(); hash=$Fields[5].Trim() }
    })
    if ($Frames.Count -eq 0) { throw "No decoded frames in $Path" }
    [pscustomobject]@{ stream=$Probe.streams[0]; duration=$Probe.format.duration; frames=$Frames; timebase=@($Lines|Where-Object{$_ -match '^#tb '}) }
}

$A = Read-VideoEvidence $Reference
$B = Read-VideoEvidence $Candidate
$Mismatch = [Collections.Generic.List[int]]::new()
$TimingMismatch = [Collections.Generic.List[int]]::new()
for ($i = 0; $i -lt [math]::Min($A.frames.Count,$B.frames.Count); $i++) {
    if ($A.frames[$i].hash -ne $B.frames[$i].hash -or $A.frames[$i].size -ne $B.frames[$i].size) { $Mismatch.Add($i) }
    if ($A.frames[$i].pts -ne $B.frames[$i].pts -or $A.frames[$i].dts -ne $B.frames[$i].dts -or $A.frames[$i].duration -ne $B.frames[$i].duration) { $TimingMismatch.Add($i) }
}
$Fields = @('width','height','avg_frame_rate','pix_fmt','color_range','color_space','color_transfer','color_primaries')
$MetadataMismatch = @($Fields | Where-Object { $A.stream.$_ -ne $B.stream.$_ })
$Identical = $A.frames.Count -eq $B.frames.Count -and $Mismatch.Count -eq 0 -and $TimingMismatch.Count -eq 0 -and $MetadataMismatch.Count -eq 0 -and ($A.timebase -join ',') -eq ($B.timebase -join ',') -and $A.duration -eq $B.duration
[ordered]@{
    status = if($Identical){'exact'}else{'different'}
    reference = [IO.Path]::GetFullPath($Reference)
    candidate = [IO.Path]::GetFullPath($Candidate)
    reference_frames = $A.frames.Count
    candidate_frames = $B.frames.Count
    pixel_mismatches = $Mismatch.Count
    first_pixel_mismatches = @($Mismatch | Select-Object -First 10)
    timing_mismatches = $TimingMismatch.Count
    metadata_mismatches = $MetadataMismatch
    reference_duration = $A.duration
    candidate_duration = $B.duration
    reference_timebase = $A.timebase
    candidate_timebase = $B.timebase
} | ConvertTo-Json -Depth 4
if (-not $Identical) { exit 1 }
