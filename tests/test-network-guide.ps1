[CmdletBinding()]
param(
    [string] $Root = 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_BUILD',
    [string] $RuntimeRoot = 'D:\DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V8',
    [string] $PageUrl = 'https://vkvideo.ru/video-225794656_456244076',
    [ValidateSet('dis','raft')] [string] $MotionBackend = 'dis'
)

$ErrorActionPreference = 'Stop'
$Resolver = Join-Path $Root 'app\source-resolver.psm1'
$YtDlp = Join-Path $Root 'tools\yt-dlp.exe'
$Guidegen = if($MotionBackend-eq'raft'){Join-Path $RuntimeRoot 'runtime\python\python.exe'}else{Join-Path $Root 'python\dist\guidegen\guidegen.exe'}
$GuideScript = Join-Path $Root 'python\guidegen.py'
$Ffmpeg = Join-Path $RuntimeRoot 'tools\ffmpeg.exe'
$DepthModel = Join-Path $RuntimeRoot 'models\depth_anything_v2_small.onnx'
$OutputDirectory = Join-Path $Root 'qa-output\network-guide-v9'
$Headers = Join-Path $OutputDirectory 'source.headers.json'
$Raw = Join-Path $OutputDirectory 'frames.rgb'
$Motion = Join-Path $OutputDirectory 'frames.motion'
$Depth = Join-Path $OutputDirectory 'frames.depth'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Import-Module $Resolver -Force
$Source = Resolve-OnlineVideoSource -PageUrl $PageUrl -YtDlpPath $YtDlp -MaxHeight 1080 -CookiesBrowser None -HeadersPath $Headers

$Arguments = @()
if($MotionBackend-eq'raft'){$Arguments+=@('-B',$GuideScript)}
$Arguments += @(
    '--server','--width','320','--height','180','--depth-model',$DepthModel,
    '--depth-backend','auto','--cache-dir',(Join-Path $OutputDirectory 'cache'),
    '--guide-width','256','--depth-interval','1','--depth-min-interval','1',
    '--motion-preset','realtime','--scene-cut-threshold','0.12',
    '--adaptive-confidence','0.75','--adaptive-motion','10','--temporal-depth','0.55',
    '--motion-backend',$MotionBackend,
    '--decode-video',$Source.MediaUrl,'--ffmpeg',$Ffmpeg,'--input-headers-json',$Headers,
    '--input-tls-no-verify','--start-seconds','30','--fps','30','--total-frames','3'
)
if($MotionBackend-eq'raft'){$Arguments+=@('--raft-weights',(Join-Path $RuntimeRoot 'models\motion\raft_small_C_T_V2-01064c6d.pth'),'--raft-updates','4','--raft-batch-size','4')}

function Quote-Argument([string] $Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$Psi = [Diagnostics.ProcessStartInfo]::new()
$Psi.FileName = $Guidegen
$Psi.Arguments = (($Arguments | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
$Psi.UseShellExecute = $false
$Psi.CreateNoWindow = $true
$Psi.RedirectStandardInput = $true
$Psi.RedirectStandardOutput = $true
$Psi.RedirectStandardError = $true
$Process = [Diagnostics.Process]::new()
$Process.StartInfo = $Psi
if (-not $Process.Start()) { throw 'guidegen did not start' }
try {
    $Ready = $null
    while ($null -ne ($Line = $Process.StandardOutput.ReadLine())) {
        if ($Line.StartsWith('GUIDE_SERVER_READY ')) { $Ready = $Line; break }
    }
    if (-not $Ready) { throw ('guidegen did not become ready: ' + $Process.StandardError.ReadToEnd()) }
    $Command = [ordered]@{cmd='chunk';id=0;input=$Raw;frames=3;first_frame=0;motion_output=$Motion;depth_output=$Depth}|ConvertTo-Json -Compress
    $Process.StandardInput.WriteLine($Command)
    $Process.StandardInput.Flush()
    $ResultLine = $null
    while ($null -ne ($Line = $Process.StandardOutput.ReadLine())) {
        if ($Line.StartsWith('GUIDE_CHUNK_READY ')) { $ResultLine = $Line; break }
    }
    if (-not $ResultLine) { throw ('network chunk failed: ' + $Process.StandardError.ReadToEnd()) }
    $Process.StandardInput.WriteLine('{"cmd":"end"}')
    $Process.StandardInput.Close()
    if (-not $Process.WaitForExit(30000)) { throw 'guidegen did not exit after end command' }
    if ($Process.ExitCode -ne 0) { throw ('guidegen failed: ' + $Process.StandardError.ReadToEnd()) }
    $Result = $ResultLine.Substring('GUIDE_CHUNK_READY '.Length) | ConvertFrom-Json
    [pscustomobject]@{
        status='ok'; format=$Source.FormatId; source_height=$Source.Height; frames=[int]$Result.frames
        depth_provider=[string]$Result.depth_provider; persistent_decode=[bool]$Result.persistent_decode
        raw_bytes=(Get-Item -LiteralPath $Raw).Length; motion_bytes=(Get-Item -LiteralPath $Motion).Length; depth_bytes=(Get-Item -LiteralPath $Depth).Length
    } | ConvertTo-Json -Compress
} finally {
    if (-not $Process.HasExited) { try { $Process.Kill() } catch {} }
    $Process.Dispose()
}
