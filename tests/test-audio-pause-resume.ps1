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
    if (-not $hostProcess) { throw 'native preview host was not found' }
    $hostProcess.Refresh()
    if ($hostProcess.MainWindowHandle -eq [IntPtr]::Zero) { throw 'native preview window is not ready' }
    if (-not [StudioTestWindowMessage]::PostMessage($hostProcess.MainWindowHandle,0x0100,[IntPtr]0x20,[IntPtr]::Zero)) {
        throw 'could not post Space to the native preview window'
    }
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
$resumedAt = -1.0
$audioStarts = 0
$startedPid = 0
$suspendedPid = 0
$resumedPid = 0
$closeSent = $false
$errors = [Collections.Generic.List[string]]::new()
try {
    while ($watch.Elapsed.TotalSeconds -lt 100) {
        if ($stdout -and $stdout.IsCompleted) {
            $line = $stdout.Result
            if ($null -eq $line) { $stdout = $null } else {
                if ($line -match '^STUDIO_PLAYER_AUDIO_STARTED .*pid=(?<pid>[0-9]+)$') {
                    $audioStarts++
                    $startedPid = [int]$Matches.pid
                } elseif ($line -match '^STUDIO_PLAYER_PLAYING ') {
                    $playingAt = $watch.Elapsed.TotalSeconds
                } elseif ($line -match '^STUDIO_PLAYER_AUDIO_SUSPENDED .*pid=(?<pid>[0-9]+)$') {
                    $suspendedPid = [int]$Matches.pid
                    $suspendedAt = $watch.Elapsed.TotalSeconds
                } elseif ($line -match '^STUDIO_PLAYER_AUDIO_RESUMED .*pid=(?<pid>[0-9]+)$') {
                    $resumedPid = [int]$Matches.pid
                    $resumedAt = $watch.Elapsed.TotalSeconds
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
        if ($playingAt -ge 0 -and $suspendedAt -lt 0 -and ($watch.Elapsed.TotalSeconds-$playingAt) -ge 0.8) {
            Toggle-NativePause
            $playingAt = -999.0
        }
        if ($suspendedAt -ge 0 -and $resumedAt -lt 0 -and ($watch.Elapsed.TotalSeconds-$suspendedAt) -ge 0.8) {
            Toggle-NativePause
            $suspendedAt = -999.0
        }
        if ($resumedAt -ge 0 -and -not $closeSent -and ($watch.Elapsed.TotalSeconds-$resumedAt) -ge 1.0) {
            [IO.File]::WriteAllText($control,'CLOSE',$utf8NoBom)
            $closeSent = $true
        }
        if ($process.HasExited -and -not $stdout -and -not $stderr) { break }
        Start-Sleep -Milliseconds 20
    }
    if (-not $process.HasExited) { throw 'audio pause/resume test timed out' }
    if ($process.ExitCode -ne 0 -or $errors.Count) { throw ('audio pause/resume pipeline failed: ' + ($errors -join ' | ')) }
    if (-not $closeSent -or $startedPid -le 0 -or $suspendedPid -ne $startedPid -or $resumedPid -ne $startedPid) {
        throw "audio process was not preserved: starts=$audioStarts started=$startedPid suspended=$suspendedPid resumed=$resumedPid close=$closeSent"
    }
    if ($audioStarts -ne 1) { throw "audio was restarted $audioStarts times" }
    [pscustomobject]@{
        status='ok';audio_starts=$audioStarts;audio_pid=$startedPid
        same_process_after_pause=$true;clean_close=$closeSent
        elapsed_seconds=[math]::Round($watch.Elapsed.TotalSeconds,2)
    } | ConvertTo-Json -Compress
} finally {
    if (-not $process.HasExited) { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null }
    $process.Dispose()
}
