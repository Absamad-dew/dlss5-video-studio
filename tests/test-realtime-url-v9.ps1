[CmdletBinding()]
param(
    [string] $Root = 'D:\DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V9',
    [string] $PageUrl = 'https://vkvideo.ru/video-225794656_456244076'
)

$ErrorActionPreference = 'Stop'
$Wrapper = Join-Path $Root 'app\realtime-player.ps1'
$Runner = Join-Path $Root 'app\process-video.ps1'
$Config = 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_BUILD\qa.ReShade.ini'
$Control = Join-Path $Root 'temp\qa-network-control.txt'
$PowerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Quote-Argument([string] $Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$Arguments = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$Wrapper,
    '-Runner',$Runner,'-InputVideo',$PageUrl,'-ConfigPath',$Config,'-ControlPath',$Control,
    '-OutputMode','540p','-Upscaler','None','-PipelineOrder','DLSSOnly',
    '-BufferSeconds','3','-StartSeconds','30','-NetworkMaxHeight','720','-CookiesBrowser','None',
    '-GuideWidth','320','-DepthInterval','24','-DepthMinInterval','12',
    '-AdaptiveConfidence','0','-AdaptiveMotion','0','-TemporalDepth','0.85',
    '-SceneCutThreshold','0.15','-MotionPreset','realtime','-MotionBackend','raft','-RaftUpdates','4',
    '-FpsMode','Double','-EnableAudio','-Volume','60'
)
$Psi = [Diagnostics.ProcessStartInfo]::new()
$Psi.FileName = $PowerShell
$Psi.Arguments = (($Arguments | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
$Psi.WorkingDirectory = $Root
$Psi.UseShellExecute = $false
$Psi.CreateNoWindow = $true
$Psi.RedirectStandardOutput = $true
$Psi.RedirectStandardError = $true
$Psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$Psi.StandardErrorEncoding = [Text.Encoding]::UTF8
$Process = [Diagnostics.Process]::new()
$Process.StartInfo = $Psi
if (-not $Process.Start()) { throw 'realtime wrapper did not start' }
$OutputTask = $Process.StandardOutput.ReadLineAsync()
$ErrorTask = $Process.StandardError.ReadLineAsync()
$Watch = [Diagnostics.Stopwatch]::StartNew()
$SawSource = $false
$SawPlan = $false
$SawHostSubmit = $false
$SawPlaying = $false
$SawAudio = $false
$PlanFps = 0.0
$CloseSent = $false
$Errors = [Collections.Generic.List[string]]::new()
try {
    while ($Watch.Elapsed.TotalSeconds -lt 90) {
        if ($OutputTask -and $OutputTask.IsCompleted) {
            $Line = $OutputTask.Result
            if ($null -eq $Line) { $OutputTask = $null } else {
                if ($Line.StartsWith('STUDIO_SOURCE_JSON ')) { $SawSource = $true }
                if ($Line.StartsWith('STUDIO_PLAN ')) {
                    $SawPlan = $true
                    try { $PlanFps=[double](($Line.Substring('STUDIO_PLAN '.Length)|ConvertFrom-Json).fps) } catch {}
                }
                if ($Line.StartsWith('HOST_CHUNK_SUBMITTED ')) { $SawHostSubmit = $true }
                if ($Line.StartsWith('STUDIO_PLAYER_PLAYING ')) {
                    $SawPlaying = $true
                    try { $SawAudio=[bool](($Line.Substring('STUDIO_PLAYER_PLAYING '.Length)|ConvertFrom-Json).audio) } catch {}
                }
                if ($Line -match '^STUDIO_ERROR ') { $Errors.Add($Line) }
                if ($SawSource -and $SawPlan -and $SawHostSubmit -and $SawPlaying -and -not $CloseSent) {
                    [IO.File]::WriteAllText($Control,'CLOSE',$Utf8NoBom)
                    $CloseSent = $true
                }
                $OutputTask = $Process.StandardOutput.ReadLineAsync()
            }
        }
        if ($ErrorTask -and $ErrorTask.IsCompleted) {
            $Line = $ErrorTask.Result
            if ($null -eq $Line) { $ErrorTask = $null } else { $Errors.Add($Line); $ErrorTask = $Process.StandardError.ReadLineAsync() }
        }
        if ($Process.HasExited -and -not $OutputTask -and -not $ErrorTask) { break }
        Start-Sleep -Milliseconds 20
    }
    if (-not $Process.HasExited) { throw 'realtime URL test timed out before clean close' }
    if ($Process.ExitCode -ne 0 -or $Errors.Count -gt 0) { throw ('realtime URL test failed: ' + ($Errors -join ' | ')) }
    if (-not ($SawSource -and $SawPlan -and $SawHostSubmit -and $SawPlaying -and $CloseSent)) { throw 'realtime URL test did not reach synchronized playback' }
    if ($PlanFps -lt 45.0) { throw "realtime URL test did not produce x2 output: $PlanFps FPS" }
    if (-not $SawAudio) { throw 'realtime URL test did not start synchronized audio' }
    [pscustomobject]@{status='ok';source_resolved=$SawSource;plan_ready=$SawPlan;target_fps=$PlanFps;first_chunk_displayed=$SawHostSubmit;playing=$SawPlaying;synchronized_audio=$SawAudio;clean_close=$CloseSent;elapsed_seconds=[math]::Round($Watch.Elapsed.TotalSeconds,2)}|ConvertTo-Json -Compress
} finally {
    if (-not $Process.HasExited) { & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null }
    $Process.Dispose()
}
