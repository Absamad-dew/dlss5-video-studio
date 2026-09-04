[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$InputVideo,
    [ValidateSet('Medium','Maximum')][string]$Profile='Medium',
    [ValidateSet('1080p','1440p','2160p')][string]$OutputMode='1080p',
    [ValidateRange(24,300)][int]$Frames=75,
    [ValidateSet('Off','NvidiaDLSSGx2')][string]$FrameGeneration='NvidiaDLSSGx2'
)
$ErrorActionPreference='Stop'
# Use the UI's literal profile data to prevent a Fast-only test accidentally
# claiming coverage for Medium/Maximum again.
$Tokens=$null; $ParseErrors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'app\studio.ps1'),[ref]$Tokens,[ref]$ParseErrors)
if ($ParseErrors.Count) { throw $ParseErrors[0] }
$Assignment=$Ast.Find({param($Node) $Node -is [Management.Automation.Language.AssignmentStatementAst] -and $Node.Left.Extent.Text -eq '$RealtimeProfiles'},$true)
$Profiles=& ([scriptblock]::Create($Assignment.Right.Extent.Text))
$P=$Profiles[$Profile]
$Config=Join-Path $Root ('temp\depth-profile-'+[guid]::NewGuid().ToString('N')+'.ini')
$Control=$Config+'.control'
Copy-Item -LiteralPath (Join-Path $Root 'engine\ReShade.ini') -Destination $Config
try {
    & (Join-Path $Root 'app\process-video.ps1') -InputVideo $InputVideo -ConfigPath $Config -OutputMode $OutputMode `
        -PerformanceProfile $Profile -DepthModelProfile VideoDepthSmall -Upscaler None -PipelineOrder DLSSOnly `
        -HardwareProfile Auto -RealtimeRenderPreset Auto -StartSeconds 120 -FrameCount $Frames -PreviewOnly `
        -RealtimeBufferSeconds 3 -RealtimeControlPath $Control -RealtimeGuideWidth $P.guide `
        -RealtimeDepthInterval $P.interval -RealtimeDepthMinInterval $P.minimum -RealtimeAdaptiveConfidence $P.confidence `
        -RealtimeAdaptiveMotion $P.motion -RealtimeTemporalDepth $P.temporal -RealtimeSceneCutThreshold $P.scene `
        -RealtimeMotionPreset $P.preset -RealtimeMotionBackend $P.backend -RealtimeRaftUpdates $P.updates `
        -RealtimeFrameGeneration $FrameGeneration -RealtimeTargetFps 90
    if ($LASTEXITCODE -ne 0) { throw "Profile $Profile failed: $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath $Config -Force -ErrorAction SilentlyContinue
}
