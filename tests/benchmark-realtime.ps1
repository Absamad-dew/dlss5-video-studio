[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)] [string] $InputVideo,
    [ValidateSet('540p','720p','1080p','1440p','2160p')] [string] $OutputMode = '540p',
    [ValidateSet('dis','raft')] [string] $MotionBackend = 'raft',
    [ValidateSet('Auto','Standard','HighVram')] [string] $HardwareProfile = 'Auto',
    [ValidateSet('Auto','Native','Quality','Balanced','Performance')] [string] $RenderPreset = 'Auto',
    [ValidateSet('Source','Double','60','72','90','120')] [string] $FpsMode = 'Source',
    [ValidateSet('Off','MotionGPU','CompatibilityBlend','NvidiaDLSSGx2','NvidiaMFGx3','NvidiaMFGx4','NvidiaDynamicMFG')] [string] $FrameGeneration = 'Off',
    [ValidateSet(0,60,72,90,120)] [int] $TargetFps = 0,
    [ValidateRange(0,16)] [int] $GuideWorkerThreads = 0,
    [ValidateRange(60,600)] [int] $Frames = 180,
    [ValidateRange(0,86400)] [double] $StartSeconds = 0,
    [ValidateRange(256,768)] [int] $GuideWidth = 320,
    [ValidateRange(1,24)] [int] $DepthInterval = 24,
    [ValidateRange(0.0,1.0)] [double] $AdaptiveConfidence = 0.75,
    [ValidateRange(0.0,30.0)] [double] $AdaptiveMotion = 10,
    [ValidateRange(0.0,0.9)] [double] $TemporalDepth = 0.55
)

$ErrorActionPreference='Stop'
$Runner=Join-Path $Root 'app\process-video.ps1'
$Config=Join-Path $Root ('temp\benchmark-reshade-{0}.ini' -f [guid]::NewGuid().ToString('N'))
$Control=Join-Path $Root ('temp\benchmark-control-{0}.txt' -f [guid]::NewGuid().ToString('N'))
try {
    Copy-Item -LiteralPath (Join-Path $Root 'engine\ReShade.ini') -Destination $Config -Force
    & $Runner -InputVideo $InputVideo -ConfigPath $Config -OutputMode $OutputMode `
        -PerformanceProfile Fast -Upscaler None -PipelineOrder DLSSOnly `
        -HardwareProfile $HardwareProfile -RealtimeRenderPreset $RenderPreset `
        -StartSeconds $StartSeconds -FrameCount $Frames -PreviewOnly -RealtimeBufferSeconds 3 `
        -RealtimeControlPath $Control -RealtimeGuideWidth $GuideWidth `
        -RealtimeDepthInterval $DepthInterval -RealtimeDepthMinInterval ([math]::Max(1,[math]::Floor($DepthInterval/2))) `
        -RealtimeAdaptiveConfidence $AdaptiveConfidence -RealtimeAdaptiveMotion $AdaptiveMotion -RealtimeTemporalDepth $TemporalDepth `
        -RealtimeSceneCutThreshold 0.12 -RealtimeMotionPreset realtime `
        -RealtimeMotionBackend $MotionBackend -RealtimeRaftUpdates 4 -RealtimeFpsMode $FpsMode -RealtimeFrameGeneration $FrameGeneration `
        -RealtimeTargetFps $TargetFps -GuideWorkerThreads $GuideWorkerThreads
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
} finally {
    if(Test-Path -LiteralPath $Control){Remove-Item -LiteralPath $Control -Force}
    if(Test-Path -LiteralPath $Config){Remove-Item -LiteralPath $Config -Force}
}
