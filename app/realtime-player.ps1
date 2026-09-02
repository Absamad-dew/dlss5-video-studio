[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Runner,
    [Parameter(Mandatory)] [string] $InputVideo,
    [Parameter(Mandatory)] [string] $ConfigPath,
    [Parameter(Mandatory)] [string] $ControlPath,
    [ValidateSet('Source','Same','4K','2160p','1440p','1080p','720p','540p')] [string] $OutputMode = 'Source',
    [ValidateSet('UltraFast','Fast','Medium','Heavy','Maximum')] [string] $PerformanceProfile = 'Medium',
    [ValidateSet('Auto','Standard','HighVram')] [string] $HardwareProfile = 'Auto',
    [ValidateSet('Auto','Native','Quality','Balanced','Performance')] [string] $RenderPreset = 'Auto',
    [ValidateSet('DA2Small','VideoDepthSmall','DA3Small','DA3Base')] [string] $DepthModelProfile = 'DA2Small',
    [ValidateSet('None','NanoVSR','AnimeSR','FlashVSR','DLoRAL')] [string] $Upscaler = 'None',
    [ValidateSet('Auto','Realtime','Balanced','Quality','Max')] [string] $UpscalerVariant = 'Auto',
    [ValidateRange(0.0,1.0)] [double] $UpscalerStrength = 1.0,
    [ValidateSet('DLSSOnly','VSRThenDLSS')] [string] $PipelineOrder = 'DLSSOnly',
    [ValidateRange(3,30)] [int] $BufferSeconds = 5,
    [ValidateRange(0,192)] [int] $ChunkFrames = 0,
    [double] $StartSeconds = 0,
    [ValidateSet(0,540,720,1080,1440,2160,4320)] [int] $NetworkMaxHeight = 1080,
    [ValidateSet('None','chrome','edge','firefox')] [string] $CookiesBrowser = 'None',
    [ValidateRange(256,768)] [int] $GuideWidth = 320,
    [ValidateRange(1,24)] [int] $DepthInterval = 24,
    [ValidateRange(1,24)] [int] $DepthMinInterval = 12,
    [ValidateRange(0.0,1.0)] [double] $AdaptiveConfidence = 0.0,
    [ValidateRange(0.0,30.0)] [double] $AdaptiveMotion = 0.0,
    [ValidateRange(0.0,0.9)] [double] $TemporalDepth = 0.85,
    [ValidateRange(0.03,0.35)] [double] $SceneCutThreshold = 0.12,
    [ValidateSet('quality','balanced','realtime')] [string] $MotionPreset = 'realtime',
    [ValidateSet('dis','raft')] [string] $MotionBackend = 'dis',
    [ValidateRange(1,12)] [int] $RaftUpdates = 4,
    [ValidateSet('Source','Double','60','72','90','120')] [string] $FpsMode = 'Source',
    [ValidateSet('Off','MotionGPU','CompatibilityBlend','NvidiaDLSSG','NvidiaDLSSGx2','NvidiaMFGx3','NvidiaMFGx4','NvidiaDynamicMFG','NvidiaOpticalFlow','Rife')] [string] $FrameGeneration = 'Off',
    [ValidateSet(0,60,72,90,120)] [int] $TargetFps = 0,
    [ValidateRange(0,16)] [int] $GuideWorkerThreads = 0,
    [switch] $EnableAudio,
    [ValidateRange(0,100)] [int] $Volume = 80,
    [switch] $FillBufferOnPause,
    [switch] $Fullscreen
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Ffprobe = Join-Path $Root 'tools\ffprobe.exe'
$Ffplay = Join-Path $Root 'tools\ffplay.exe'
$YtDlp = Join-Path $Root 'tools\yt-dlp.exe'
$SourceResolver = Join-Path $PSScriptRoot 'source-resolver.psm1'
$PowerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$Invariant = [Globalization.CultureInfo]::InvariantCulture

# Control ffplay through its SDL window. Suspending the process is not a valid
# audio pause: samples already queued in the Windows endpoint keep playing and
# make sound run ahead while video is stopped. A native ffplay pause freezes
# both the SDL device and its sample clock.
if (-not ('StudioNativeAudioControl' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class StudioNativeAudioControl {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr window);
}
'@
}

function Quote-Argument([string] $Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Remove-RealtimeWork([string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    try {
        $Resolved = [IO.Path]::GetFullPath($Path)
        $Parent = [IO.Directory]::GetParent($Resolved)
        $GrandParent = if ($Parent) { $Parent.Parent } else { $null }
        if ([IO.Path]::GetFileName($Resolved) -like 'job-*' -and $Parent -and $Parent.Name -eq 'temp' -and $GrandParent -and $GrandParent.Name -eq 'DLSS5VideoStudio') {
            Remove-Item -LiteralPath $Resolved -Recurse -Force
            Write-Output "STUDIO_PLAYER_CLEANUP $Resolved"
        }
    } catch {
        Write-Output ('STUDIO_PLAYER_CLEANUP_WARNING ' + $_.Exception.Message)
    }
}

function Stop-ChildTree($Child) {
    if ($Child -and -not $Child.HasExited) {
        try { & taskkill.exe /PID $Child.Id /T /F 2>$null | Out-Null } catch {}
        try { if (-not $Child.WaitForExit(10000)) { $Child.Kill() } } catch {}
    }
}

if (-not (Test-Path -LiteralPath $Runner -PathType Leaf)) { throw "Realtime runner is missing: $Runner" }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Realtime config is missing: $ConfigPath" }
if (-not (Test-Path -LiteralPath $Ffprobe -PathType Leaf)) { throw "ffprobe is missing: $Ffprobe" }
if (-not (Test-Path -LiteralPath $SourceResolver -PathType Leaf)) { throw "Online source resolver is missing: $SourceResolver" }
Import-Module $SourceResolver -Force
$IsOnline = Test-HttpVideoSource $InputVideo
if (-not $IsOnline -and -not (Test-Path -LiteralPath $InputVideo -PathType Leaf)) { throw "Input video is missing: $InputVideo" }
if ($EnableAudio -and -not (Test-Path -LiteralPath $Ffplay -PathType Leaf)) {
    Write-Output 'STUDIO_PLAYER_WARNING Audio component ffplay is missing; continuing without sound.'
    $EnableAudio = $false
}

$ControlPath = [IO.Path]::GetFullPath($ControlPath)
$ControlDirectory = [IO.Path]::GetDirectoryName($ControlPath)
New-Item -ItemType Directory -Force -Path $ControlDirectory | Out-Null
[IO.File]::WriteAllText($ControlPath,'',$Utf8NoBom)
$TelemetryPath = $ControlPath + '.telemetry'
$NativeEventPath = $ControlPath + '.events'
$PlaybackStatePath = $ControlPath + '.playback'
$BufferStatePath = $ControlPath + '.buffer'
if (Test-Path -LiteralPath $TelemetryPath) { Remove-Item -LiteralPath $TelemetryPath -Force }
if (Test-Path -LiteralPath $NativeEventPath) { Remove-Item -LiteralPath $NativeEventPath -Force }
[IO.File]::WriteAllText($PlaybackStatePath,'buffering',$Utf8NoBom)
if (Test-Path -LiteralPath $BufferStatePath) { Remove-Item -LiteralPath $BufferStatePath -Force }

$ResolvedInput = $InputVideo
$HeadersPath = $null
$InputTlsNoVerify = $false
$OnlineInfo = $null
if ($IsOnline) {
    $HeadersPath = $ControlPath + '.headers.json'
    Write-Output 'STUDIO_SOURCE_RESOLVING network-source'
    $OnlineInfo = Resolve-OnlineVideoSource -PageUrl $InputVideo -YtDlpPath $YtDlp -MaxHeight $NetworkMaxHeight -CookiesBrowser $CookiesBrowser -HeadersPath $HeadersPath
    $ResolvedInput = $OnlineInfo.MediaUrl
    $InputTlsNoVerify = [bool]$OnlineInfo.TlsNoVerify
    $Duration = [double]$OnlineInfo.Duration
    Write-Output ('STUDIO_SOURCE_JSON ' + ([ordered]@{
        kind='network'; title=$OnlineInfo.Title; duration_seconds=[math]::Round($Duration,3)
        width=$OnlineInfo.Width; height=$OnlineInfo.Height; format_id=$OnlineInfo.FormatId
        extractor=$OnlineInfo.Extractor; max_height=$NetworkMaxHeight
    } | ConvertTo-Json -Compress))
} else {
    $Probe = (& $Ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $InputVideo | Select-Object -First 1)
    $Duration = 0.0
    if (-not [double]::TryParse([string]$Probe,[Globalization.NumberStyles]::Float,$Invariant,[ref]$Duration) -or $Duration -le 0) {
        throw 'Could not determine the video duration for realtime seeking.'
    }
}
if ($Duration -le 0) { throw 'Could not determine the video duration for realtime seeking.' }
$CurrentStart = [math]::Max(0.0,[math]::Min($Duration-0.05,$StartSeconds))
$AudioProcess = $null
$AudioStderrReadTask = $null
$AudioStderrBytes = $null
$AudioStderrBuffer = ''
$AudioErrorTail = ''
$AudioWindowHandle = [IntPtr]::Zero
$AudioMuted = $false
$AudioSuspended = $false
$AudioSuspendedPosition = 0.0
$AudioSuspendReason = ''
$AudioPausePending = $false
$AudioPausePendingPosition = 0.0
$AudioPausePendingReason = ''
$AudioSeekPosition = 0.0
$AudioPlaybackRate = 1.0
$AudioClockMedia = [double]::NaN
$AudioClockObservedWall = 0.0
$LatestVideoRate = 1.0
$AudioPendingStart = $false
$AudioPendingSince = 0.0
$AudioPendingPosition = 0.0
$VideoPaused = $false
$BufferingPaused = $false
$LastAudioStartWall = 0.0
$LastTelemetryWall = 0.0
$LastTelemetryFrame = -1L
$VideoPlaybackStarted = $false
$LatestVideoPosition = $CurrentStart
$LatestRealFrames = 0L
$ProducerSentFrames = 0L
$ProducerTargetFrames = 0L
$ProducerFps = 0.0
$ProducerRateFps = 0.0
$ProducerLastEventWall = 0.0
$ProducerLastEventFrames = 0L
$ProducerSamples = @()
$LastBufferPublishWall = 0.0
$InputHeaderBlock = $null
if ($HeadersPath -and (Test-Path -LiteralPath $HeadersPath)) {
    $HeaderObject = Get-Content -LiteralPath $HeadersPath -Raw | ConvertFrom-Json
    $HeaderLines = foreach($Property in $HeaderObject.PSObject.Properties){if($Property.Value){'{0}: {1}'-f $Property.Name,$Property.Value}}
    if($HeaderLines){$InputHeaderBlock=($HeaderLines-join "`r`n")+"`r`n"}
}

function Stop-Audio {
    if ($script:AudioProcess) {
        $WasExited = $script:AudioProcess.HasExited
        $StoppedPid = $script:AudioProcess.Id
        $StoppedExitCode = if ($WasExited) { $script:AudioProcess.ExitCode } else { $null }
        Stop-ChildTree $script:AudioProcess
        Poll-AudioStatus
        if ($script:AudioErrorTail -match '(?i)\b(error|failed|invalid|unable)\b') {
            $AudioError = (($script:AudioErrorTail -replace "\x1B\[[0-?]*[ -/]*[@-~]",'') -replace '[\r\n]+',' | ').Trim()
            if ($AudioError) { Write-Output ('STUDIO_PLAYER_AUDIO_ERROR ' + $AudioError) }
        }
        try { $script:AudioProcess.Dispose() } catch {}
        if ($WasExited) {
            Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_EXITED pid={0} exit_code={1}',$StoppedPid,$StoppedExitCode))
        }
        $script:AudioProcess = $null
    }
    $script:AudioStderrReadTask = $null
    $script:AudioStderrBytes = $null
    $script:AudioStderrBuffer = ''
    $script:AudioErrorTail = ''
    $script:AudioWindowHandle = [IntPtr]::Zero
    $script:AudioSuspended = $false
    $script:AudioSuspendedPosition = 0.0
    $script:AudioSuspendReason = ''
    $script:AudioPausePending = $false
    $script:AudioPausePendingPosition = 0.0
    $script:AudioPausePendingReason = ''
    $script:AudioClockMedia = [double]::NaN
    $script:AudioClockObservedWall = 0.0
}

function Get-MonotonicSeconds {
    return [Diagnostics.Stopwatch]::GetTimestamp() / [double][Diagnostics.Stopwatch]::Frequency
}

function Find-AudioWindow([int] $WaitMilliseconds = 0) {
    if (-not $script:AudioProcess -or $script:AudioProcess.HasExited) { return [IntPtr]::Zero }
    $Deadline = (Get-MonotonicSeconds) + ($WaitMilliseconds/1000.0)
    do {
        if ($script:AudioWindowHandle -ne [IntPtr]::Zero -and
            [StudioNativeAudioControl]::IsWindow($script:AudioWindowHandle)) {
            return $script:AudioWindowHandle
        }
        try {
            $script:AudioProcess.Refresh()
            $Handle = $script:AudioProcess.MainWindowHandle
            if ($Handle -ne [IntPtr]::Zero) {
                $script:AudioWindowHandle = $Handle
                [StudioNativeAudioControl]::ShowWindow($Handle,0) | Out-Null
                return $Handle
            }
        } catch {}
        if ((Get-MonotonicSeconds) -ge $Deadline) { break }
        Start-Sleep -Milliseconds 15
    } while (-not $script:AudioProcess.HasExited)
    return [IntPtr]::Zero
}

function Poll-AudioStatus {
    if (-not $script:AudioProcess) { return }
    $PublishedAudioWindow = Find-AudioWindow
    if ($script:AudioPausePending -and $PublishedAudioWindow -ne [IntPtr]::Zero -and -not $script:AudioSuspended) {
        $PendingPosition = $script:AudioPausePendingPosition
        $PendingReason = $script:AudioPausePendingReason
        if (Set-AudioDevicePaused $true $PendingPosition $PendingReason) {
            $script:AudioPausePending = $false
            $script:AudioPausePendingPosition = 0.0
            $script:AudioPausePendingReason = ''
            Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_DEFERRED_PAUSE_APPLIED position={0:0.######} reason={1} pid={2}',
                $PendingPosition,$PendingReason,$script:AudioProcess.Id))
        }
    }
    $Reads = 0
    while ($script:AudioStderrReadTask -and $script:AudioStderrReadTask.IsCompleted -and $Reads -lt 16) {
        try { $Count = $script:AudioStderrReadTask.GetAwaiter().GetResult() } catch { $Count = 0 }
        if ($Count -le 0) { $script:AudioStderrReadTask = $null; break }
        $Chunk = [Text.Encoding]::UTF8.GetString($script:AudioStderrBytes,0,$Count)
        $script:AudioStderrBuffer += $Chunk
        if ($script:AudioStderrBuffer.Length -gt 16384) {
            $script:AudioStderrBuffer = $script:AudioStderrBuffer.Substring($script:AudioStderrBuffer.Length-16384)
        }
        $ClockMatches = [regex]::Matches($script:AudioStderrBuffer,'(?:^|[\r\n])\s*(?<clock>-?[0-9]+\.[0-9]+)\s+M-A:')
        if ($ClockMatches.Count -gt 0) {
            $RawClock = 0.0
            $LatestClockMatch = $ClockMatches[$ClockMatches.Count-1]
            if ([double]::TryParse($LatestClockMatch.Groups['clock'].Value,[Globalization.NumberStyles]::Float,$Invariant,[ref]$RawClock)) {
                # ffplay runs at source speed, so its master clock maps directly
                # onto the source-media timeline after the seek offset.
                $script:AudioClockMedia = $script:AudioSeekPosition + [math]::Max(0.0,$RawClock)*$script:AudioPlaybackRate
                $script:AudioClockObservedWall = Get-MonotonicSeconds
            }
        }
        $CleanTail = ($script:AudioStderrBuffer -replace "`r","`n")
        $ErrorLines = @($CleanTail -split "`n" | Where-Object { $_ -match '(?i)\b(error|failed|invalid|unable)\b' } | Select-Object -Last 4)
        if ($ErrorLines.Count) { $script:AudioErrorTail = ($ErrorLines -join "`n") }
        $script:AudioStderrBytes = [byte[]]::new(4096)
        $script:AudioStderrReadTask = $script:AudioProcess.StandardError.BaseStream.ReadAsync($script:AudioStderrBytes,0,$script:AudioStderrBytes.Length)
        ++$Reads
    }
}

function Get-EstimatedAudioPosition([double] $Now = [double]::NaN) {
    Poll-AudioStatus
    if ([double]::IsNaN($script:AudioClockMedia)) { return [double]::NaN }
    if ([double]::IsNaN($Now)) { $Now = Get-MonotonicSeconds }
    $Position = $script:AudioClockMedia
    if (-not $script:AudioSuspended -and $script:AudioClockObservedWall -gt 0) {
        $Position += [math]::Max(0.0,$Now-$script:AudioClockObservedWall)*$script:AudioPlaybackRate
    }
    return $Position
}

function Set-AudioDevicePaused([bool] $Paused,[double] $Position,[string] $Reason) {
    if (-not $script:AudioProcess -or $script:AudioProcess.HasExited) { return $false }
    if ($script:AudioSuspended -eq $Paused) {
        if ($Paused -and $Reason) { $script:AudioSuspendReason = $Reason }
        return $true
    }
    $Handle = Find-AudioWindow 900
    if ($Handle -eq [IntPtr]::Zero) { return $false }
    try {
        # SDL requires a real key transition with the Space scan code. A bare
        # PostMessage without lParam was accepted by Windows but ignored by
        # ffplay, which is why the old pause test gave a false sense of safety.
        [StudioNativeAudioControl]::SendMessage($Handle,0x0100,[IntPtr]0x20,[IntPtr]0x00390001) | Out-Null
        [StudioNativeAudioControl]::SendMessage($Handle,0x0101,[IntPtr]0x20,[IntPtr]0xC0390001) | Out-Null
        $script:AudioSuspended = $Paused
        if ($Paused) {
            $script:AudioSuspendedPosition = $Position
            $script:AudioSuspendReason = $Reason
        } else {
            $script:AudioSuspendedPosition = 0.0
            $script:AudioSuspendReason = ''
        }
        return $true
    } catch {
        Write-Output ('STUDIO_PLAYER_AUDIO_DEVICE_WARNING ' + $_.Exception.Message)
        return $false
    }
}

function Set-PlaybackState([string] $State) {
    try { [IO.File]::WriteAllText($PlaybackStatePath,$State,$Utf8NoBom) } catch {}
}

function Update-ProducerBufferFromLine([string] $Line) {
    if ($Line -notmatch '^STUDIO_REALTIME_BUFFER_(?:READY_JSON|LEVEL) (?<j>.+)$') { return }
    try { $Payload = $Matches.j | ConvertFrom-Json } catch { return }
    $Now = Get-MonotonicSeconds
    $SentProperty = $Payload.PSObject.Properties['sent_frames']
    $TargetProperty = $Payload.PSObject.Properties['target_frames']
    $FpsProperty = $Payload.PSObject.Properties['source_fps']
    $ElapsedProperty = $Payload.PSObject.Properties['producer_elapsed_seconds']
    $NewSent = if ($SentProperty) { [long]$SentProperty.Value } else { [long]$Payload.ready_frames }
    if ($TargetProperty) { $script:ProducerTargetFrames = [long]$TargetProperty.Value }
    if ($FpsProperty -and [double]$FpsProperty.Value -gt 0) { $script:ProducerFps = [double]$FpsProperty.Value }
    $EventTime = if ($ElapsedProperty -and [double]$ElapsedProperty.Value -gt 0) { [double]$ElapsedProperty.Value } else { $Now }
    if ($NewSent -gt $script:ProducerLastEventFrames) {
        $script:ProducerSamples += [pscustomobject]@{Time=$EventTime;Frames=$NewSent}
        $Cutoff = $EventTime - 3.0
        $script:ProducerSamples = @($script:ProducerSamples | Where-Object { $_.Time -ge $Cutoff })
        if ($script:ProducerSamples.Count -ge 2) {
            $FirstSample = $script:ProducerSamples[0]
            $LastSample = $script:ProducerSamples[-1]
            $SampleSeconds = [double]$LastSample.Time - [double]$FirstSample.Time
            if ($SampleSeconds -ge 0.25) {
                $script:ProducerRateFps = ([long]$LastSample.Frames-[long]$FirstSample.Frames)/$SampleSeconds
            }
        } elseif ($EventTime -gt 0.25) {
            $script:ProducerRateFps = $NewSent/$EventTime
        }
    }
    $script:ProducerSentFrames = $NewSent
    $script:ProducerLastEventFrames = $NewSent
    $script:ProducerLastEventWall = $Now
}

function Publish-LiveBufferStatus([switch] $Force) {
    if ($script:ProducerFps -le 0 -or $script:ProducerTargetFrames -le 0) { return }
    $Now = Get-MonotonicSeconds
    if (-not $Force -and ($Now-$script:LastBufferPublishWall) -lt 0.45) { return }
    $RemainingFrames = [long][math]::Max(0,$script:ProducerSentFrames-$script:LatestRealFrames)
    $RemainingSeconds = $RemainingFrames/[double]$script:ProducerFps
    $TargetSeconds = $script:ProducerTargetFrames/[double]$script:ProducerFps
    $RateRatio = if ($script:ProducerFps -gt 0) { $script:ProducerRateFps/$script:ProducerFps } else { 0.0 }
    $IsFull = $RemainingFrames -ge $script:ProducerTargetFrames
    $State = if ($script:BufferingPaused) { 'rebuffering' } elseif ($script:VideoPaused) {
        if ($FillBufferOnPause -and -not $IsFull) { 'pause-filling' } elseif ($IsFull) { 'pause-full' } else { 'paused' }
    } elseif ($IsFull) { 'full' } else { 'filling' }
    $Payload = [ordered]@{
        remaining_frames=$RemainingFrames;remaining_seconds=[math]::Round($RemainingSeconds,3)
        target_frames=$script:ProducerTargetFrames;target_seconds=[math]::Round($TargetSeconds,3)
        sent_frames=$script:ProducerSentFrames;presented_real_frames=$script:LatestRealFrames
        refill_fps=[math]::Round($script:ProducerRateFps,3);refill_realtime=[math]::Round($RateRatio,3)
        full=[bool]$IsFull;paused=[bool]$script:VideoPaused;rebuffering=[bool]$script:BufferingPaused;fill_on_pause=[bool]$FillBufferOnPause;state=$State
    }
    $Json = $Payload | ConvertTo-Json -Compress
    Write-Output ('STUDIO_REALTIME_BUFFER_STATUS ' + $Json)
    $StateLine = [string]::Format($Invariant,
        'remaining_seconds={0:0.###} target_seconds={1:0.###} refill_fps={2:0.###} refill_realtime={3:0.###} paused={4} fill_on_pause={5} full={6} rebuffering={7}',
        $RemainingSeconds,$TargetSeconds,$script:ProducerRateFps,$RateRatio,[int]$script:VideoPaused,[int][bool]$FillBufferOnPause,[int]$IsFull,[int]$script:BufferingPaused)
    try { [IO.File]::WriteAllText($BufferStatePath,$StateLine,$Utf8NoBom) } catch {}
    $script:LastBufferPublishWall = $Now
}

function Start-Audio([double] $Position) {
    if (-not $EnableAudio -or $script:AudioMuted -or $script:VideoPaused -or $script:BufferingPaused) { return }
    $script:AudioPendingStart = $false
    Stop-Audio
    $SeekPosition = [math]::Max(0.0,[math]::Min($Duration-0.01,$Position))
    $WindowTitle = 'DLSS5AudioClock-' + [guid]::NewGuid().ToString('N')
    # An off-screen waveform window gives us the SDL event endpoint required
    # for a true device pause. It is hidden as soon as Windows publishes its
    # handle and never appears over the video player.
    $AudioArgs=@('-autoexit','-hide_banner','-loglevel','info','-stats','-volume',$Volume,
        '-x','64','-y','64','-left','-32000','-top','-32000','-showmode','1','-window_title',$WindowTitle)
    if($InputTlsNoVerify){$AudioArgs+=@('-tls_verify','0')}
    if($InputHeaderBlock){$AudioArgs+=@('-headers',$InputHeaderBlock)}
    $AudioFilter = 'aresample=async=0,asetpts=N/SR/TB'
    $AudioArgs+=@('-ss',([string]::Format($Invariant,'{0:0.######}',$SeekPosition)),'-i',$ResolvedInput,
        '-vn','-sn','-sync','audio','-af',$AudioFilter)
    $Psi=[Diagnostics.ProcessStartInfo]::new();$Psi.FileName=$Ffplay
    $Psi.Arguments=(($AudioArgs|ForEach-Object{Quote-Argument([string]$_)})-join' ')
    $Psi.WorkingDirectory=$Root;$Psi.UseShellExecute=$false;$Psi.CreateNoWindow=$true
    $Psi.RedirectStandardOutput=$false;$Psi.RedirectStandardError=$true
    $script:AudioProcess=[Diagnostics.Process]::new();$script:AudioProcess.StartInfo=$Psi
    if(-not $script:AudioProcess.Start()){$script:AudioProcess=$null;return}
    $script:AudioStderrBuffer='';$script:AudioErrorTail=''
    $script:AudioStderrBytes=[byte[]]::new(4096)
    $script:AudioStderrReadTask=$script:AudioProcess.StandardError.BaseStream.ReadAsync($script:AudioStderrBytes,0,$script:AudioStderrBytes.Length)
    $script:AudioWindowHandle=[IntPtr]::Zero
    $script:AudioSuspended=$false
    $script:AudioSuspendedPosition=$SeekPosition
    $script:AudioSuspendReason=''
    $script:AudioPausePending=$false
    $script:AudioPausePendingPosition=0.0
    $script:AudioPausePendingReason=''
    $script:AudioSeekPosition=$SeekPosition
    $script:AudioClockMedia=[double]::NaN
    $script:AudioClockObservedWall=0.0
    $script:LastAudioStartWall=Get-MonotonicSeconds
    Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_STARTED position={0:0.######} rate={1:0.###} pid={2}',$SeekPosition,$script:AudioPlaybackRate,$script:AudioProcess.Id))
}

function Suspend-Audio([double] $Position,[string] $Reason = 'explicit') {
    if (-not $EnableAudio -or $script:AudioMuted -or -not $script:AudioProcess -or $script:AudioProcess.HasExited) { return }
    $AudioAtPause = Get-EstimatedAudioPosition
    if (Set-AudioDevicePaused $true $Position $Reason) {
        Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_SUSPENDED position={0:0.######} audio={1:0.######} reason={2} pid={3}',$Position,$AudioAtPause,$Reason,$script:AudioProcess.Id))
    } else {
        $script:AudioPausePending=$true
        $script:AudioPausePendingPosition=$Position
        $script:AudioPausePendingReason=$Reason
        Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_PAUSE_DEFERRED position={0:0.######} reason={1} pid={2}',
            $Position,$Reason,$script:AudioProcess.Id))
    }
}

function Resume-Audio([double] $Position) {
    if (-not $EnableAudio -or $script:AudioMuted -or $script:VideoPaused -or $script:BufferingPaused) { return }
    if ($script:AudioProcess -and -not $script:AudioProcess.HasExited) {
        if ($script:AudioPausePending -and -not $script:AudioSuspended) {
            $script:AudioPausePending=$false
            $script:AudioPausePendingPosition=0.0
            $script:AudioPausePendingReason=''
            Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_DEFERRED_PAUSE_CANCELLED position={0:0.######} pid={1}',
                $Position,$script:AudioProcess.Id))
            return
        }
        if (-not $script:AudioSuspended) {
            # Duplicate PLAYING/BUFFER_READY/RESUME events must never restart a
            # healthy device or create a second network seek.
            return
        }
        $AudioPosition = Get-EstimatedAudioPosition
        $ResumeDelta = if ([double]::IsNaN($AudioPosition)) { 0.0 } else { [math]::Abs($Position-$AudioPosition) }
        # Pause/rebuffer must never reopen a healthy endpoint. If the clocks
        # differ, the continuous drift controller holds or releases this same
        # device; a new seek is reserved for an actual player SEEK operation.
        if (Set-AudioDevicePaused $false $Position '') {
            Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_RESUMED position={0:0.######} audio={1:0.######} drift={2:0.###} pid={3}',$Position,$AudioPosition,$ResumeDelta,$script:AudioProcess.Id))
            return
        }
        Write-Output 'STUDIO_PLAYER_AUDIO_RESUME_WARNING ffplay SDL audio window was unavailable'
    }
    Start-Audio $Position
}

function Update-AudioClockFromTelemetry {
    Poll-AudioStatus
    if (-not (Test-Path -LiteralPath $TelemetryPath -PathType Leaf)) { return }
    try { $Telemetry = [IO.File]::ReadAllText($TelemetryPath,$Utf8NoBom).Trim() } catch { return }
    if ($Telemetry -notmatch 'media_seconds=(?<p>[0-9.]+)\s+real_fps=(?<r>[0-9.]+)\s+display_fps=(?<d>[0-9.]+)\s+real_frames=(?<f>[0-9]+)') { return }
    $Frame = [long]$Matches.f
    $Position = [double]::Parse($Matches.p,$Invariant)
    $RealFps = [double]::Parse($Matches.r,$Invariant)
    $Now = Get-MonotonicSeconds
    if ($Frame -ne $script:LastTelemetryFrame) {
        $script:LastTelemetryFrame = $Frame
        $script:LastTelemetryWall = $Now
        $script:LatestVideoPosition = $Position
        $script:LatestRealFrames = $Frame
        if ($script:ProducerFps -gt 0.1 -and $RealFps -gt 0.1) {
            $ObservedRate = [math]::Max(0.1,[math]::Min(1.0,$RealFps/$script:ProducerFps))
            $script:LatestVideoRate = $ObservedRate
        }
    } else {
        $Position = $script:LatestVideoPosition
    }
    if (-not $script:VideoPlaybackStarted -or -not $EnableAudio -or $script:AudioMuted -or $script:VideoPaused -or $script:BufferingPaused) { return }
    if ($script:AudioPendingStart) {
        if (($Now-$script:AudioPendingSince) -lt 0.22) { return }
        $StartPosition = $script:LatestVideoPosition + [math]::Max(0.0,$Now-$script:LastTelemetryWall)*$script:LatestVideoRate
        $StartPosition = [math]::Max($script:AudioPendingPosition,$StartPosition)
        # Keep one normal-speed audio endpoint for the whole playback session.
        # Early display-rate telemetry is deliberately ignored here: startup
        # scheduling can report a transient 0.5x rate even when the prepared
        # realtime buffer immediately settles at source speed. Reopening ffplay
        # to change tempo caused the audible dropout/rush cycle. Fine sync and
        # rebuffering below pause this same SDL device against its sample clock.
        $script:AudioPlaybackRate = 1.0
        $script:AudioPendingStart = $false
        Start-Audio $StartPosition
        Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_ALIGNED_START position={0:0.###}',$StartPosition))
        return
    }
    if ((-not $script:AudioProcess -or $script:AudioProcess.HasExited) -and
        ($Now-$script:LastAudioStartWall) -ge 2.0) {
        Start-Audio $Position
        Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_RECOVERED position={0:0.###}',$Position))
        return
    }

    # Fine sync uses the actual ffplay sample clock. Hold only audio when it is
    # ahead; resume after the next displayed frames close the gap. This also
    # bounds drift if display progress temporarily falls behind source speed.
    $AudioPosition = Get-EstimatedAudioPosition $Now
    if (-not [double]::IsNaN($AudioPosition)) {
        $VideoPosition = $Position + [math]::Max(0.0,$Now-$script:LastTelemetryWall)*$script:LatestVideoRate
        $Drift = $AudioPosition-$VideoPosition
        if (-not $script:AudioSuspended -and $Drift -gt 0.18) {
            Suspend-Audio $VideoPosition 'drift'
            Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_HOLD drift={0:0.###} audio={1:0.###} video={2:0.###}',$Drift,$AudioPosition,$VideoPosition))
        } elseif ($script:AudioSuspended -and $script:AudioSuspendReason -eq 'drift' -and $Drift -le 0.025) {
            if (Set-AudioDevicePaused $false $VideoPosition '') {
                Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_AUDIO_RELEASE drift={0:0.###} audio={1:0.###} video={2:0.###}',$Drift,$AudioPosition,$VideoPosition))
            }
        }
    }
}

Write-Output ('STUDIO_PLAYER_READY ' + (@{
    duration_seconds=[math]::Round($Duration,3);buffer_seconds=$BufferSeconds;chunk_frames=$ChunkFrames;fullscreen=[bool]$Fullscreen
    source_kind=if($IsOnline){'network'}else{'file'};guide_width=$GuideWidth;depth_interval=$DepthInterval
    motion_backend=$MotionBackend;fps_mode=$FpsMode;frame_generation=$FrameGeneration;audio=[bool]$EnableAudio;volume=$Volume
    performance_profile=$PerformanceProfile;hardware_profile=$HardwareProfile;render_preset=$RenderPreset;target_fps=$TargetFps;guide_worker_threads=$GuideWorkerThreads
    depth_model_profile=$DepthModelProfile;fill_buffer_on_pause=[bool]$FillBufferOnPause
}|ConvertTo-Json -Compress))

while ($true) {
    [IO.File]::WriteAllText($ControlPath,'',$Utf8NoBom)
    [IO.File]::WriteAllText($NativeEventPath,'',$Utf8NoBom)
    $NativeEventOffset = 0
    if (Test-Path -LiteralPath $TelemetryPath) { Remove-Item -LiteralPath $TelemetryPath -Force }
    Set-PlaybackState 'buffering'
    if (Test-Path -LiteralPath $BufferStatePath) { Remove-Item -LiteralPath $BufferStatePath -Force }
    $script:LastTelemetryWall=0.0;$script:LastTelemetryFrame=-1L;$script:LastAudioStartWall=0.0
    $script:AudioSuspended=$false;$script:AudioSuspendedPosition=0.0;$script:AudioSuspendReason=''
    $script:AudioPausePending=$false;$script:AudioPausePendingPosition=0.0;$script:AudioPausePendingReason=''
    $script:AudioPlaybackRate=1.0;$script:LatestVideoRate=1.0
    $script:AudioPendingStart=$false;$script:AudioPendingSince=0.0;$script:AudioPendingPosition=$CurrentStart
    $script:VideoPlaybackStarted=$false;$script:VideoPaused=$false;$script:BufferingPaused=$false;$script:LatestVideoPosition=$CurrentStart
    $script:LatestRealFrames=0L;$script:ProducerSentFrames=0L;$script:ProducerTargetFrames=0L;$script:ProducerFps=0.0
    $script:ProducerRateFps=0.0;$script:ProducerLastEventWall=Get-MonotonicSeconds;$script:ProducerLastEventFrames=0L;$script:ProducerSamples=@();$script:LastBufferPublishWall=0.0
    $ChildArgs = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$Runner,
        '-InputVideo',$ResolvedInput,'-ConfigPath',$ConfigPath,
        '-OutputMode',$OutputMode,'-PerformanceProfile',$PerformanceProfile,
        '-HardwareProfile',$HardwareProfile,'-RealtimeRenderPreset',$RenderPreset,
        '-DepthModelProfile',$DepthModelProfile,
        '-Upscaler',$Upscaler,'-UpscalerVariant',$UpscalerVariant,
        '-UpscalerStrength',([string]::Format($Invariant,'{0:0.###}',$UpscalerStrength)),
        '-PipelineOrder',$PipelineOrder,'-VRMode','Off','-VRSbsLayout','HalfSBS',
        '-StartSeconds',([string]::Format($Invariant,'{0:0.######}',$CurrentStart)),
        '-FrameCount','0','-PreviewOnly','-RealtimeBufferSeconds',$BufferSeconds,'-RealtimeChunkFrames',$ChunkFrames,
        '-RealtimeControlPath',$ControlPath,
        '-RealtimeGuideWidth',$GuideWidth,'-RealtimeDepthInterval',$DepthInterval,
        '-RealtimeDepthMinInterval',([math]::Min($DepthMinInterval,$DepthInterval)),
        '-RealtimeAdaptiveConfidence',([string]::Format($Invariant,'{0:0.###}',$AdaptiveConfidence)),
        '-RealtimeAdaptiveMotion',([string]::Format($Invariant,'{0:0.###}',$AdaptiveMotion)),
        '-RealtimeTemporalDepth',([string]::Format($Invariant,'{0:0.###}',$TemporalDepth)),
        '-RealtimeSceneCutThreshold',([string]::Format($Invariant,'{0:0.###}',$SceneCutThreshold)),
        '-RealtimeMotionPreset',$MotionPreset,'-RealtimeMotionBackend',$MotionBackend,'-RealtimeRaftUpdates',$RaftUpdates,
        '-RealtimeFpsMode',$FpsMode,'-RealtimeFrameGeneration',$FrameGeneration,
        '-RealtimeTargetFps',$TargetFps,'-GuideWorkerThreads',$GuideWorkerThreads
    )
    if ($FillBufferOnPause) { $ChildArgs += '-RealtimeFillBufferOnPause' }
    if ($HeadersPath) { $ChildArgs += @('-InputHeadersPath',$HeadersPath) }
    if ($InputTlsNoVerify) { $ChildArgs += '-InputTlsNoVerify' }
    if ($Fullscreen) { $ChildArgs += '-RealtimeFullscreen' }

    $Psi = [Diagnostics.ProcessStartInfo]::new()
    $Psi.FileName = $PowerShell
    $Psi.Arguments = (($ChildArgs | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
    $Psi.WorkingDirectory = $Root
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    $Psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $Psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $Child = [Diagnostics.Process]::new()
    $Child.StartInfo = $Psi
    if (-not $Child.Start()) { throw 'Could not start the realtime processing pipeline.' }

    Write-Output ('STUDIO_PLAYER_SESSION ' + (@{start_seconds=[math]::Round($CurrentStart,3);pid=$Child.Id}|ConvertTo-Json -Compress))
    $Stdout = $Child.StandardOutput.ReadLineAsync()
    $Stderr = $Child.StandardError.ReadLineAsync()
    $ActiveWork = $null
    $Action = $null
    $Target = $CurrentStart
    $DlssgFallbackRequested = $false

    while ($true) {
        $StdoutLines = 0
        while ($Stdout -and $Stdout.IsCompleted -and $StdoutLines -lt 128) {
            $Line = $Stdout.Result
            if ($null -eq $Line) { $Stdout = $null; break }
            Update-ProducerBufferFromLine $Line
            Write-Output $Line
            if ($Line -match '^STUDIO_WORK (?<p>.+)$') { $ActiveWork = $Matches.p }
            if ($Line -match 'HOST_DLSSG_FALLBACK') { $DlssgFallbackRequested = $true }
            $Stdout = $Child.StandardOutput.ReadLineAsync()
            ++$StdoutLines
        }
        $StderrLines = 0
        while ($Stderr -and $Stderr.IsCompleted -and $StderrLines -lt 64) {
            $Line = $Stderr.Result
            if ($null -eq $Line) { $Stderr = $null; break }
            Write-Output ('PLAYER_CHILD_ERROR: ' + $Line)
            if ($Line -match 'HOST_DLSSG_FALLBACK') { $DlssgFallbackRequested = $true }
            $Stderr = $Child.StandardError.ReadLineAsync()
            ++$StderrLines
        }

        Update-AudioClockFromTelemetry
        Publish-LiveBufferStatus
        # The actual ffplay sample clock is continuously compared with the
        # media position of displayed frames. Pause, buffering and sustained
        # render slowdown are all handled by the same timeline controller.

        try {
            $Commands = [Collections.Generic.List[string]]::new()
            $NativeEvents = @(Get-Content -LiteralPath $NativeEventPath -ErrorAction SilentlyContinue)
            if ((Get-Item -LiteralPath $ControlPath -ErrorAction Stop).Length -gt 0) {
                $ExternalCommand = [IO.File]::ReadAllText($ControlPath,$Utf8NoBom).Trim()
                [IO.File]::WriteAllText($ControlPath,'',$Utf8NoBom)
                if (-not [string]::IsNullOrWhiteSpace($ExternalCommand)) { $Commands.Add($ExternalCommand) }
            }
            # Drain every native event already written instead of handling only
            # one per UI tick. Falling behind here previously replayed obsolete
            # BUFFERING timestamps seconds later and repeatedly disturbed audio.
            while ($NativeEventOffset -lt $NativeEvents.Count) {
                $NativeCommand = ([string]$NativeEvents[$NativeEventOffset]).Trim()
                $NativeEventOffset++
                if (-not [string]::IsNullOrWhiteSpace($NativeCommand)) { $Commands.Add($NativeCommand) }
            }
            if ($Commands.Count -gt 1) {
                $CoalescedCommands = [Collections.Generic.List[string]]::new()
                $PendingBufferCommand = $null
                foreach ($QueuedCommand in $Commands) {
                    if ($QueuedCommand -match '^BUFFER(?:ING|_READY)\s+') {
                        $PendingBufferCommand = $QueuedCommand
                    } else {
                        if ($PendingBufferCommand) { $CoalescedCommands.Add($PendingBufferCommand);$PendingBufferCommand=$null }
                        $CoalescedCommands.Add($QueuedCommand)
                    }
                }
                if ($PendingBufferCommand) { $CoalescedCommands.Add($PendingBufferCommand) }
                $Commands = $CoalescedCommands
            }
            foreach ($Command in $Commands) {
                if ($Command -match '^SEEK\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $ParsedTarget = 0.0
                    if ([double]::TryParse($Matches.s,[Globalization.NumberStyles]::Float,$Invariant,[ref]$ParsedTarget)) {
                        $Target = [math]::Max(0.0,[math]::Min($Duration-0.05,$ParsedTarget))
                        $Action = 'seek'
                    }
                } elseif ($Command -match '^PLAYING\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:VideoPaused=$false
                    $Position=[double]::Parse($Matches.s,$Invariant)
                    $script:VideoPlaybackStarted=$true
                    Set-PlaybackState 'playing'
                    # Native events are file-backed and can be observed after
                    # later frames have already reached the swap chain. Start
                    # at the newest displayed-frame telemetry so decoder start
                    # latency cannot leave sound several seconds behind.
                    $AudioPosition=if($script:LatestVideoPosition -gt $Position){$script:LatestVideoPosition}else{$Position}
                    if ($EnableAudio -and -not $script:AudioMuted -and (-not $script:AudioProcess -or $script:AudioProcess.HasExited)) {
                        # Let the first telemetry sample settle before opening
                        # audio. This removes decoder/window startup latency
                        # from A/V alignment without adding a blind fixed seek.
                        $script:AudioPendingStart=$true
                        $script:AudioPendingSince=Get-MonotonicSeconds
                        $script:AudioPendingPosition=$AudioPosition
                    } else {
                        Resume-Audio $AudioPosition
                    }
                    Write-Output ('STUDIO_PLAYER_PLAYING ' + (@{
                        position_seconds=[math]::Round($Position,3);audio_position_seconds=[math]::Round($AudioPosition,3)
                        audio=[bool]($EnableAudio -and -not $script:AudioMuted)
                        audio_pid=if($script:AudioProcess){$script:AudioProcess.Id}else{$null};muted=[bool]$script:AudioMuted;volume=$Volume
                    }|ConvertTo-Json -Compress))
                } elseif ($Command -match '^BUFFERING\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:BufferingPaused=$true;Set-PlaybackState 'rebuffering';Suspend-Audio ([double]::Parse($Matches.s,$Invariant)) 'buffering';Publish-LiveBufferStatus -Force
                    Write-Output ('STUDIO_PLAYER_REBUFFERING ' + $Matches.s)
                } elseif ($Command -match '^BUFFER_READY\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:BufferingPaused=$false
                    if(-not $script:VideoPaused){Set-PlaybackState 'playing';Resume-Audio ([double]::Parse($Matches.s,$Invariant))}
                    Publish-LiveBufferStatus -Force
                    Write-Output ('STUDIO_PLAYER_REBUFFERED ' + $Matches.s)
                } elseif ($Command -match '^PAUSE\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:VideoPaused=$true;Set-PlaybackState 'paused';Suspend-Audio ([double]::Parse($Matches.s,$Invariant)) 'user';Publish-LiveBufferStatus -Force
                    Write-Output ('STUDIO_PLAYER_PAUSED ' + $Matches.s)
                } elseif ($Command -match '^RESUME\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:VideoPaused=$false;Set-PlaybackState 'playing';Resume-Audio ([double]::Parse($Matches.s,$Invariant));Publish-LiveBufferStatus -Force
                    Write-Output ('STUDIO_PLAYER_RESUMED ' + $Matches.s)
                } elseif ($Command -match '^MUTE\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:AudioMuted=$true;Stop-Audio
                    Write-Output ('STUDIO_PLAYER_MUTED ' + $Matches.s)
                } elseif ($Command -match '^UNMUTE\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:AudioMuted=$false
                    if(-not $script:VideoPaused){Resume-Audio ([double]::Parse($Matches.s,$Invariant))}
                    Write-Output ('STUDIO_PLAYER_UNMUTED ' + $Matches.s)
                } elseif ($Command -eq 'CLOSE') {
                    $Action = 'close'
                }
                if ($Action) { break }
            }
        } catch {}

        if ($Action) {
            $script:VideoPlaybackStarted=$false
            Stop-Audio
            Stop-ChildTree $Child
        }
        if ($Child.HasExited -and -not $Stdout -and -not $Stderr) { break }
        Start-Sleep -Milliseconds 20
    }

    $ExitCode = $Child.ExitCode
    $script:VideoPlaybackStarted=$false
    Stop-Audio
    $Child.Dispose()
    if (-not $Action -and $DlssgFallbackRequested -and $FrameGeneration -match '^Nvidia') {
        Remove-RealtimeWork $ActiveWork
        if ($script:LatestVideoPosition -ge $CurrentStart -and $script:LatestVideoPosition -lt ($Duration-0.05)) {
            $CurrentStart = $script:LatestVideoPosition
        }
        $FrameGeneration = 'MotionGPU'
        Write-Output ([string]::Format($Invariant,'STUDIO_PLAYER_WARNING NVIDIA DLSSG presentation failed; restarting at {0:0.###} s with MotionGPU so the player cannot remain black.',$CurrentStart))
        continue
    }
    if ($Action -eq 'seek') {
        Remove-RealtimeWork $ActiveWork
        $CurrentStart = $Target
        Write-Output ('STUDIO_PLAYER_SEEK ' + ([string]::Format($Invariant,'{0:0.###}',$CurrentStart)))
        continue
    }
    if ($Action -eq 'close') {
        Remove-RealtimeWork $ActiveWork
        if ($HeadersPath -and (Test-Path -LiteralPath $HeadersPath)) { Remove-Item -LiteralPath $HeadersPath -Force }
        if (Test-Path -LiteralPath $TelemetryPath) { Remove-Item -LiteralPath $TelemetryPath -Force }
        if (Test-Path -LiteralPath $NativeEventPath) { Remove-Item -LiteralPath $NativeEventPath -Force }
        if (Test-Path -LiteralPath $PlaybackStatePath) { Remove-Item -LiteralPath $PlaybackStatePath -Force }
        if (Test-Path -LiteralPath $BufferStatePath) { Remove-Item -LiteralPath $BufferStatePath -Force }
        Write-Output 'STUDIO_PLAYER_CLOSED'
        exit 0
    }
    if ($HeadersPath -and (Test-Path -LiteralPath $HeadersPath)) { Remove-Item -LiteralPath $HeadersPath -Force }
    if (Test-Path -LiteralPath $TelemetryPath) { Remove-Item -LiteralPath $TelemetryPath -Force }
    if (Test-Path -LiteralPath $NativeEventPath) { Remove-Item -LiteralPath $NativeEventPath -Force }
    if (Test-Path -LiteralPath $PlaybackStatePath) { Remove-Item -LiteralPath $PlaybackStatePath -Force }
    if (Test-Path -LiteralPath $BufferStatePath) { Remove-Item -LiteralPath $BufferStatePath -Force }
    exit $ExitCode
}
