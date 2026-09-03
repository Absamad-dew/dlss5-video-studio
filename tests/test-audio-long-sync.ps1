param(
    [string] $PortableRoot = 'D:\DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V20',
    [string] $InputVideo = '',
    [string] $ConfigPath = '',
    [ValidateSet('540p','1080p','1440p')] [string] $OutputMode = '540p',
    [ValidateSet('UltraFast','Fast','Medium','Heavy','Maximum')] [string] $PerformanceProfile = 'UltraFast',
    [ValidateSet('Native','Quality','Balanced','Performance')] [string] $RenderPreset = 'Native',
    [ValidateSet('dis','raft')] [string] $MotionBackend = 'dis',
    [ValidateRange(256,768)] [int] $GuideWidth = 256,
    [ValidateRange(1,24)] [int] $DepthInterval = 24,
    [ValidateRange(5,30)] [int] $PlaybackSeconds = 15
)
$ErrorActionPreference = 'Stop'
$root = $PortableRoot
$wrapper = Join-Path $root 'app\realtime-player.ps1'
$runner = Join-Path $root 'app\process-video.ps1'
if ([string]::IsNullOrWhiteSpace($InputVideo)) { $InputVideo = Join-Path $root 'temp\local-av-buffer-sample.mp4' }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_BUILD\qa.ReShade.ini' }
$inputVideo = $InputVideo
$config = $ConfigPath
$control = Join-Path $root 'temp\qa-audio-long-control.txt'
$telemetry = $control + '.telemetry'
$powerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Quote-Argument([string] $value) {
    if ($value -notmatch '[\s"]') { return $value }
    return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$arguments = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper,
    '-Runner',$runner,'-InputVideo',$inputVideo,'-ConfigPath',$config,'-ControlPath',$control,
    '-OutputMode',$OutputMode,'-PerformanceProfile',$PerformanceProfile,'-RenderPreset',$RenderPreset,
    '-Upscaler','None','-PipelineOrder','DLSSOnly','-BufferSeconds','3','-ChunkFrames','8',
    '-GuideWidth',$GuideWidth,'-DepthInterval',$DepthInterval,'-DepthMinInterval',$DepthInterval,
    '-AdaptiveConfidence','0','-AdaptiveMotion','0','-TemporalDepth','0.85',
    '-SceneCutThreshold','0.16','-MotionPreset','quality','-MotionBackend',$MotionBackend,'-RaftUpdates','8',
    '-FpsMode','Source','-FrameGeneration','Off','-EnableAudio','-Volume','20','-FillBufferOnPause'
)
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $powerShell
$psi.Arguments = (($arguments | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [Text.Encoding]::UTF8
$process = [Diagnostics.Process]::new()
$process.StartInfo = $psi
if (-not $process.Start()) { throw 'realtime wrapper did not start' }
$stdout = $process.StandardOutput.ReadLineAsync()
$stderr = $process.StandardError.ReadLineAsync()
$watch = [Diagnostics.Stopwatch]::StartNew()
$playingAt = -1.0
$closeSent = $false
$lines = [Collections.Generic.List[string]]::new()
$errors = [Collections.Generic.List[string]]::new()
$performance = [Collections.Generic.List[object]]::new()
$lastTelemetry = ''
try {
    while ($watch.Elapsed.TotalSeconds -lt 75) {
        if ($stdout -and $stdout.IsCompleted) {
            $line = $stdout.Result
            if ($null -eq $line) { $stdout = $null } else {
                $lines.Add($line)
                if ($line -match '^STUDIO_PLAYER_PLAYING ' -and $playingAt -lt 0) { $playingAt = $watch.Elapsed.TotalSeconds }
                if ($line -match '^(STUDIO_ERROR|PLAYER_CHILD_ERROR) ') { $errors.Add($line) }
                $stdout = $process.StandardOutput.ReadLineAsync()
            }
        }
        if ($stderr -and $stderr.IsCompleted) {
            $line = $stderr.Result
            if ($null -eq $line) { $stderr = $null } else {
                if (-not [string]::IsNullOrWhiteSpace($line)) { $errors.Add($line) }
                $stderr = $process.StandardError.ReadLineAsync()
            }
        }
        if ($playingAt -ge 0 -and -not $closeSent -and ($watch.Elapsed.TotalSeconds-$playingAt) -ge $PlaybackSeconds) {
            [IO.File]::WriteAllText($control,'CLOSE',$utf8NoBom)
            $closeSent = $true
        }
        if ($playingAt -ge 0 -and -not $closeSent -and (Test-Path -LiteralPath $telemetry -PathType Leaf)) {
            try { $sample = [IO.File]::ReadAllText($telemetry,$utf8NoBom).Trim() } catch { $sample = '' }
            if ($sample -and $sample -ne $lastTelemetry -and
                $sample -match 'real_fps=(?<real>[0-9.]+)\s+display_fps=(?<display>[0-9.]+)') {
                $performance.Add([pscustomobject]@{
                    Time=$watch.Elapsed.TotalSeconds-$playingAt
                    Real=[double]$Matches.real
                    Display=[double]$Matches.display
                })
                $lastTelemetry = $sample
            }
        }
        if ($process.HasExited -and -not $stdout -and -not $stderr) { break }
        Start-Sleep -Milliseconds 20
    }
    if (-not $process.HasExited) { throw 'long audio-sync test timed out' }
    if ($process.ExitCode -ne 0 -or $errors.Count) { throw ('long audio-sync pipeline failed: ' + ($errors -join ' | ')) }
    $text = $lines -join "`n"
    $starts = [regex]::Matches($text,'(?m)^STUDIO_PLAYER_AUDIO_STARTED position=(?<position>[0-9.]+) rate=(?<rate>[0-9.]+) pid=(?<pid>[0-9]+)$')
    $holds = [regex]::Matches($text,'(?m)^STUDIO_PLAYER_AUDIO_HOLD drift=(?<drift>[0-9.]+)')
    $maxHoldDrift = if ($holds.Count) { ($holds | ForEach-Object { [double]$_.Groups['drift'].Value } | Measure-Object -Maximum).Maximum } else { 0.0 }
    $syncSamples = [regex]::Matches($text,'(?m)^STUDIO_PLAYER_AUDIO_SYNC video=(?<video>[0-9.]+) audio=[0-9.]+ drift=(?<drift>-?[0-9.]+)$')
    # The first published sample can precede the first full native telemetry
    # interval. Measure steady playback after two media seconds.
    $steadySyncSamples = @($syncSamples | Where-Object { [double]$_.Groups['video'].Value -ge 2.0 })
    $maxAbsoluteSyncDrift = if ($steadySyncSamples.Count) {
        ($steadySyncSamples | ForEach-Object { [math]::Abs([double]$_.Groups['drift'].Value) } | Measure-Object -Maximum).Maximum
    } else { [double]::PositiveInfinity }
    if (-not $closeSent -or $starts.Count -ne 1) {
        $audioEvents = @($lines | Where-Object { $_ -match '^STUDIO_PLAYER_AUDIO_' })
        throw "audio endpoint was not stable: starts=$($starts.Count) close=$closeSent events=$($audioEvents -join ' || ')"
    }
    if ($holds.Count -ne 0 -or $steadySyncSamples.Count -lt 4 -or $maxAbsoluteSyncDrift -gt 0.15) {
        $syncLines = @($lines | Where-Object { $_ -match '^STUDIO_PLAYER_AUDIO_SYNC ' })
        throw "audio timeline was unstable: holds=$($holds.Count) samples=$($syncSamples.Count) max_drift=$maxAbsoluteSyncDrift timeline=$($syncLines -join ' || ')"
    }
    $steadyPerformance = @($performance | Where-Object { $_.Time -ge 2.0 })
    [ordered]@{
        status='ok';output_mode=$OutputMode;performance_profile=$PerformanceProfile;render_preset=$RenderPreset
        motion_backend=$MotionBackend;guide_width=$GuideWidth;depth_interval=$DepthInterval
        audio_starts=$starts.Count;audio_pid=[int]$starts[0].Groups['pid'].Value
        initial_media_position=[double]$starts[0].Groups['position'].Value
        selected_playback_rate=[double]$starts[0].Groups['rate'].Value
        drift_holds=$holds.Count;max_hold_drift_seconds=[math]::Round([double]$maxHoldDrift,3)
        sync_samples=$syncSamples.Count;steady_sync_samples=$steadySyncSamples.Count;max_absolute_sync_drift_seconds=[math]::Round([double]$maxAbsoluteSyncDrift,3)
        audio_exits=([regex]::Matches($text,'(?m)^STUDIO_PLAYER_AUDIO_EXITED ')).Count
        audio_errors=([regex]::Matches($text,'(?m)^STUDIO_PLAYER_AUDIO_ERROR ')).Count
        realtime_samples=$steadyPerformance.Count
        realtime_real_fps=if($steadyPerformance.Count){[math]::Round(($steadyPerformance.Real|Measure-Object -Average).Average,3)}else{0}
        realtime_display_fps=if($steadyPerformance.Count){[math]::Round(($steadyPerformance.Display|Measure-Object -Average).Average,3)}else{0}
        realtime_real_fps_min=if($steadyPerformance.Count){[math]::Round(($steadyPerformance.Real|Measure-Object -Minimum).Minimum,3)}else{0}
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,2)
    } | ConvertTo-Json -Compress
} finally {
    if (-not $process.HasExited) { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null }
    $process.Dispose()
}
