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
if (Test-Path -LiteralPath $TelemetryPath) { Remove-Item -LiteralPath $TelemetryPath -Force }

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
$AudioStderrTask = $null
$AudioMuted = $false
$VideoPaused = $false
$LastAudioStartWall = 0.0
$LastTelemetryWall = 0.0
$LastTelemetryFrame = -1L
$VideoPlaybackStarted = $false
$LatestVideoPosition = $CurrentStart
$InputHeaderBlock = $null
if ($HeadersPath -and (Test-Path -LiteralPath $HeadersPath)) {
    $HeaderObject = Get-Content -LiteralPath $HeadersPath -Raw | ConvertFrom-Json
    $HeaderLines = foreach($Property in $HeaderObject.PSObject.Properties){if($Property.Value){'{0}: {1}'-f $Property.Name,$Property.Value}}
    if($HeaderLines){$InputHeaderBlock=($HeaderLines-join "`r`n")+"`r`n"}
}

function Stop-Audio {
    if ($script:AudioProcess) {
        Stop-ChildTree $script:AudioProcess
        if ($script:AudioStderrTask) {
            try {
                $AudioError = (([string]$script:AudioStderrTask.Result) -replace "\x1B\[[0-?]*[ -/]*[@-~]",'').Trim()
                if ($AudioError) { Write-Output ('STUDIO_PLAYER_AUDIO_ERROR ' + ($AudioError -replace '[\r\n]+',' | ')) }
            } catch {}
        }
        try { $script:AudioProcess.Dispose() } catch {}
        $script:AudioProcess = $null
        $script:AudioStderrTask = $null
    }
}

function Get-MonotonicSeconds {
    return [Diagnostics.Stopwatch]::GetTimestamp() / [double][Diagnostics.Stopwatch]::Frequency
}

function Start-Audio([double] $Position) {
    if (-not $EnableAudio -or $script:AudioMuted -or $script:VideoPaused) { return }
    Stop-Audio
    $SeekPosition = [math]::Max(0.0,[math]::Min($Duration-0.01,$Position))
    $AudioArgs=@('-nodisp','-autoexit','-loglevel','error','-volume',$Volume)
    if($InputTlsNoVerify){$AudioArgs+=@('-tls_verify','0')}
    if($InputHeaderBlock){$AudioArgs+=@('-headers',$InputHeaderBlock)}
    $AudioArgs+=@('-ss',([string]::Format($Invariant,'{0:0.######}',$SeekPosition)),'-i',$ResolvedInput,
        '-vn','-sn','-sync','audio','-af','aresample=async=1:min_hard_comp=0.100:first_pts=0')
    $Psi=[Diagnostics.ProcessStartInfo]::new();$Psi.FileName=$Ffplay
    $Psi.Arguments=(($AudioArgs|ForEach-Object{Quote-Argument([string]$_)})-join' ')
    $Psi.WorkingDirectory=$Root;$Psi.UseShellExecute=$false;$Psi.CreateNoWindow=$true
    $Psi.RedirectStandardOutput=$false;$Psi.RedirectStandardError=$true
    $script:AudioProcess=[Diagnostics.Process]::new();$script:AudioProcess.StartInfo=$Psi
    if(-not $script:AudioProcess.Start()){$script:AudioProcess=$null;return}
    $script:AudioStderrTask=$script:AudioProcess.StandardError.ReadToEndAsync()
    $script:LastAudioStartWall=Get-MonotonicSeconds
}

function Update-AudioClockFromTelemetry {
    if (-not (Test-Path -LiteralPath $TelemetryPath -PathType Leaf)) { return }
    try { $Telemetry = [IO.File]::ReadAllText($TelemetryPath,$Utf8NoBom).Trim() } catch { return }
    if ($Telemetry -notmatch 'media_seconds=(?<p>[0-9.]+)\s+real_fps=(?<r>[0-9.]+)\s+display_fps=(?<d>[0-9.]+)\s+real_frames=(?<f>[0-9]+)') { return }
    $Frame = [long]$Matches.f
    if ($Frame -eq $script:LastTelemetryFrame) { return }
    $Position = [double]::Parse($Matches.p,$Invariant)
    $Now = Get-MonotonicSeconds
    $script:LastTelemetryFrame = $Frame
    $script:LastTelemetryWall = $Now
    $script:LatestVideoPosition = $Position
    if (-not $script:VideoPlaybackStarted -or -not $EnableAudio -or $script:AudioMuted -or $script:VideoPaused) { return }
    # Audio is the continuous master clock. Never kill/restart a healthy audio
    # device merely because video telemetry is early, late or temporarily
    # absent: those corrective restarts were heard as recurring drop-outs.
    # Recover only when ffplay actually exited, with a retry guard for broken
    # network streams or inputs without an audio track.
    if ((-not $script:AudioProcess -or $script:AudioProcess.HasExited) -and
        ($Now-$script:LastAudioStartWall) -ge 2.0) {
        Start-Audio $Position
        Write-Output ('STUDIO_PLAYER_AUDIO_RECOVERED position={0:0.###}' -f $Position)
    }
}

Write-Output ('STUDIO_PLAYER_READY ' + (@{
    duration_seconds=[math]::Round($Duration,3);buffer_seconds=$BufferSeconds;chunk_frames=$ChunkFrames;fullscreen=[bool]$Fullscreen
    source_kind=if($IsOnline){'network'}else{'file'};guide_width=$GuideWidth;depth_interval=$DepthInterval
    motion_backend=$MotionBackend;fps_mode=$FpsMode;frame_generation=$FrameGeneration;audio=[bool]$EnableAudio;volume=$Volume
    performance_profile=$PerformanceProfile;hardware_profile=$HardwareProfile;render_preset=$RenderPreset;target_fps=$TargetFps;guide_worker_threads=$GuideWorkerThreads
    depth_model_profile=$DepthModelProfile
}|ConvertTo-Json -Compress))

while ($true) {
    [IO.File]::WriteAllText($ControlPath,'',$Utf8NoBom)
    if (Test-Path -LiteralPath $TelemetryPath) { Remove-Item -LiteralPath $TelemetryPath -Force }
    $script:LastTelemetryWall=0.0;$script:LastTelemetryFrame=-1L;$script:LastAudioStartWall=0.0
    $script:VideoPlaybackStarted=$false;$script:LatestVideoPosition=$CurrentStart
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
        while ($Stdout -and $Stdout.IsCompleted -and $StdoutLines -lt 16) {
            $Line = $Stdout.Result
            if ($null -eq $Line) { $Stdout = $null; break }
            Write-Output $Line
            if ($Line -match '^STUDIO_WORK (?<p>.+)$') { $ActiveWork = $Matches.p }
            if ($Line -match 'HOST_DLSSG_FALLBACK') { $DlssgFallbackRequested = $true }
            $Stdout = $Child.StandardOutput.ReadLineAsync()
            ++$StdoutLines
        }
        $StderrLines = 0
        while ($Stderr -and $Stderr.IsCompleted -and $StderrLines -lt 16) {
            $Line = $Stderr.Result
            if ($null -eq $Line) { $Stderr = $null; break }
            Write-Output ('PLAYER_CHILD_ERROR: ' + $Line)
            if ($Line -match 'HOST_DLSSG_FALLBACK') { $DlssgFallbackRequested = $true }
            $Stderr = $Child.StandardError.ReadLineAsync()
            ++$StderrLines
        }

        Update-AudioClockFromTelemetry
        # Audio intentionally runs continuously. Buffering protects the video
        # clock; telemetry is used for position/recovery, never as a reason to
        # interrupt a healthy audio device.

        try {
            if ((Get-Item -LiteralPath $ControlPath -ErrorAction Stop).Length -gt 0) {
                $Command = [IO.File]::ReadAllText($ControlPath,$Utf8NoBom).Trim()
                [IO.File]::WriteAllText($ControlPath,'',$Utf8NoBom)
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
                    $AudioPosition=$Position
                    if ($script:LatestVideoPosition -ge $Position -and ($script:LatestVideoPosition-$Position) -lt 5.0) {
                        $AudioPosition=$script:LatestVideoPosition
                    }
                    Start-Audio $AudioPosition
                    Write-Output ('STUDIO_PLAYER_PLAYING ' + (@{
                        position_seconds=[math]::Round($Position,3);audio_position_seconds=[math]::Round($AudioPosition,3)
                        audio=[bool]($EnableAudio -and -not $script:AudioMuted)
                        audio_pid=if($script:AudioProcess){$script:AudioProcess.Id}else{$null};muted=[bool]$script:AudioMuted;volume=$Volume
                    }|ConvertTo-Json -Compress))
                } elseif ($Command -match '^PAUSE\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:VideoPaused=$true;Stop-Audio
                    Write-Output ('STUDIO_PLAYER_PAUSED ' + $Matches.s)
                } elseif ($Command -match '^RESUME\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:VideoPaused=$false;Start-Audio ([double]::Parse($Matches.s,$Invariant))
                    Write-Output ('STUDIO_PLAYER_RESUMED ' + $Matches.s)
                } elseif ($Command -match '^MUTE\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:AudioMuted=$true;Stop-Audio
                    Write-Output ('STUDIO_PLAYER_MUTED ' + $Matches.s)
                } elseif ($Command -match '^UNMUTE\s+(?<s>[0-9]+(?:\.[0-9]+)?)$') {
                    $script:AudioMuted=$false
                    if(-not $script:VideoPaused){Start-Audio ([double]::Parse($Matches.s,$Invariant))}
                    Write-Output ('STUDIO_PLAYER_UNMUTED ' + $Matches.s)
                } elseif ($Command -eq 'CLOSE') {
                    $Action = 'close'
                }
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
        Write-Output ('STUDIO_PLAYER_WARNING NVIDIA DLSSG presentation failed; restarting at {0:0.###} s with MotionGPU so the player cannot remain black.' -f $CurrentStart)
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
        Write-Output 'STUDIO_PLAYER_CLOSED'
        exit 0
    }
    if ($HeadersPath -and (Test-Path -LiteralPath $HeadersPath)) { Remove-Item -LiteralPath $HeadersPath -Force }
    if (Test-Path -LiteralPath $TelemetryPath) { Remove-Item -LiteralPath $TelemetryPath -Force }
    exit $ExitCode
}
