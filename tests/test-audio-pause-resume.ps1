$ErrorActionPreference = 'Stop'
# End-to-end regression: native pause must preserve one ffplay PID.
$root = 'D:\DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V11'
$wrapper = Join-Path $root 'app\realtime-player.ps1'
$runner = Join-Path $root 'app\process-video.ps1'
$inputVideo = Join-Path $root 'temp\local-av-buffer-sample.mp4'
$config = 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_BUILD\qa.ReShade.ini'
$control = Join-Path $root 'temp\qa-audio-pause-control.txt'
$powerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$utf8NoBom = [Text.UTF8Encoding]::new($false)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class StudioTestWindowMessage {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
}
'@

function Quote-Argument([string] $value) {
    if ($value -notmatch '[\s"]') { return $value }
    return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Toggle-NativePause {
    $hostProcess = Get-Process -Name 'dlss5-video-host' -ErrorAction SilentlyContinue |
        Sort-Object StartTime -Descending | Select-Object -First 1
    if (-not $hostProcess) { return $false }
    try { $hostProcess.Refresh(); if ($hostProcess.HasExited) { return $false }; $handle = $hostProcess.MainWindowHandle } catch { return $false }
    if ($null -eq $handle -or $handle -eq [IntPtr]::Zero) { return $false }
    if (-not [StudioTestWindowMessage]::PostMessage($handle,0x0100,[IntPtr]0x20,[IntPtr]::Zero)) {
        return $false
    }
    return $true
}

$arguments = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper,
    '-Runner',$runner,'-InputVideo',$inputVideo,'-ConfigPath',$config,'-ControlPath',$control,
    '-OutputMode','540p','-PerformanceProfile','UltraFast','-RenderPreset','Native',
    '-Upscaler','None','-PipelineOrder','DLSSOnly','-BufferSeconds','3','-ChunkFrames','8',
    '-GuideWidth','256','-DepthInterval','24','-DepthMinInterval','24',
    '-AdaptiveConfidence','0','-AdaptiveMotion','0','-TemporalDepth','0.85',
    '-SceneCutThreshold','0.16','-MotionPreset','realtime','-MotionBackend','dis',
    '-FpsMode','Source','-FrameGeneration','Off','-EnableAudio','-Volume','35','-FillBufferOnPause'
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
$suspendedAt = -1.0
$lastResumeAt = -1.0
$videoPausedAt = -1.0
$pauseCommandSent = $false
$resumeCommandSent = $false
$targetPauseCycles = 3
$completedPauseCycles = 0
$audioStarts = 0
$startedPid = 0
$suspendedPid = 0
$audioAtSuspend = [double]::NaN
$pausedClockAdvances = [Collections.Generic.List[double]]::new()
$pausePids = [Collections.Generic.List[int]]::new()
$closeSent = $false
$errors = [Collections.Generic.List[string]]::new()
$audioEvents = [Collections.Generic.List[string]]::new()
try {
    while ($watch.Elapsed.TotalSeconds -lt 100) {
        if ($stdout -and $stdout.IsCompleted) {
            $line = $stdout.Result
            if ($null -eq $line) { $stdout = $null } else {
                if ($line -match '^STUDIO_PLAYER_AUDIO_') { $audioEvents.Add($line) }
                if ($line -match '^STUDIO_PLAYER_AUDIO_STARTED .*pid=(?<pid>[0-9]+)$') {
                    $audioStarts++
                    $startedPid = [int]$Matches.pid
                } elseif ($line -match '^STUDIO_PLAYER_PLAYING ') {
                    $playingAt = $watch.Elapsed.TotalSeconds
                } elseif ($line -match '^STUDIO_PLAYER_AUDIO_SUSPENDED .*audio=(?<audio>(?:NaN|-?[0-9.]+)).*reason=user .*pid=(?<pid>[0-9]+)$') {
                    $suspendedPid = [int]$Matches.pid
                    $audioAtSuspend = [double]::Parse($Matches.audio,[Globalization.CultureInfo]::InvariantCulture)
                    $suspendedAt = $watch.Elapsed.TotalSeconds
                } elseif ($suspendedPid -gt 0 -and $line -match '^STUDIO_PLAYER_AUDIO_RESUMED .*audio=(?<audio>(?:NaN|-?[0-9.]+)).*pid=(?<pid>[0-9]+)$') {
                    $resumedPid = [int]$Matches.pid
                    $audioAtResume = [double]::Parse($Matches.audio,[Globalization.CultureInfo]::InvariantCulture)
                    $pausedClockAdvances.Add([math]::Abs($audioAtResume-$audioAtSuspend))
                    $pausePids.Add($suspendedPid);$pausePids.Add($resumedPid)
                    $completedPauseCycles++
                    $lastResumeAt = $watch.Elapsed.TotalSeconds
                    $suspendedPid = 0
                    $videoPausedAt = -1.0
                    $pauseCommandSent = $false
                    $resumeCommandSent = $false
                } elseif ($line -match '^STUDIO_PLAYER_PAUSED ') {
                    $videoPausedAt = $watch.Elapsed.TotalSeconds
                } elseif ($line -match '^(STUDIO_ERROR|PLAYER_CHILD_ERROR) ') {
                    $errors.Add($line)
                }
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
        $PauseAnchor = if ($completedPauseCycles -eq 0) { $playingAt } else { $lastResumeAt }
        if ($completedPauseCycles -lt $targetPauseCycles -and $PauseAnchor -ge 0 -and -not $pauseCommandSent -and ($watch.Elapsed.TotalSeconds-$PauseAnchor) -ge 0.8) {
            $pauseCommandSent = Toggle-NativePause
        }
        if ($videoPausedAt -ge 0 -and -not $resumeCommandSent -and ($watch.Elapsed.TotalSeconds-$videoPausedAt) -ge 0.8) {
            $resumeCommandSent = Toggle-NativePause
        }
        if ($completedPauseCycles -eq $targetPauseCycles -and $lastResumeAt -ge 0 -and -not $closeSent -and ($watch.Elapsed.TotalSeconds-$lastResumeAt) -ge 1.0) {
            [IO.File]::WriteAllText($control,'CLOSE',$utf8NoBom)
            $closeSent = $true
        }
        if ($process.HasExited -and -not $stdout -and -not $stderr) { break }
        Start-Sleep -Milliseconds 20
    }
    if (-not $process.HasExited) { throw "audio pause/resume test timed out: cycles=$completedPauseCycles/$targetPauseCycles events=$($audioEvents -join ' || ')" }
    if ($process.ExitCode -ne 0 -or $errors.Count) { throw ('audio pause/resume pipeline failed: ' + ($errors -join ' | ')) }
    $wrongPid = @($pausePids | Where-Object { $_ -ne $startedPid })
    if (-not $closeSent -or $completedPauseCycles -ne $targetPauseCycles -or $startedPid -le 0 -or $wrongPid.Count) {
        throw "audio process was not preserved: starts=$audioStarts started=$startedPid cycles=$completedPauseCycles/$targetPauseCycles wrong_pids=$($wrongPid -join ',') close=$closeSent events=$($audioEvents -join ' || ')"
    }
    if ($audioStarts -ne 1) { throw "audio was restarted $audioStarts times" }
    $maxPausedClockAdvance = ($pausedClockAdvances | Measure-Object -Maximum).Maximum
    if ($pausedClockAdvances.Count -ne $targetPauseCycles -or [double]::IsNaN($maxPausedClockAdvance) -or $maxPausedClockAdvance -gt 0.12) {
        throw "ffplay sample clock advanced during repeated pause: samples=$($pausedClockAdvances -join ',') max=$maxPausedClockAdvance"
    }
    [pscustomobject]@{
        status='ok';audio_starts=$audioStarts;audio_pid=$startedPid
        pause_cycles=$completedPauseCycles;same_process_after_pause=$true;sample_clock_frozen=$true
        max_paused_clock_advance_seconds=[math]::Round([double]$maxPausedClockAdvance,3);clean_close=$closeSent
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,2)
    } | ConvertTo-Json -Compress
} finally {
    if (-not $process.HasExited) { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null }
    $process.Dispose()
}
