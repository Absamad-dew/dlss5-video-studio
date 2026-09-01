[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $InputVideo,
    [string] $OutputVideo,
    [Parameter(Mandatory)] [string] $ConfigPath,
    [ValidateSet('H264','H265')] [string] $Codec = 'H265',
    [ValidateRange(0,51)] [int] $Quality = 18,
    [ValidateSet('Source','Same','4K','2160p','1440p','1080p','720p','540p')] [string] $OutputMode = 'Source',
    [ValidateSet('Quality','Balanced','Turbo','Realtime')] [string] $PerformanceProfile = 'Turbo',
    [ValidateSet('Auto','Laptop8GB','RTX5080')] [string] $HardwareProfile = 'Auto',
    [ValidateSet('Auto','Native','Quality','Balanced','Performance')] [string] $RealtimeRenderPreset = 'Auto',
    [ValidateSet('DA2Small','VideoDepthSmall','DA3Small','DA3Base')] [string] $DepthModelProfile = 'DA2Small',
    [ValidateSet('None','NanoVSR','AnimeSR','FlashVSR','DLoRAL')] [string] $Upscaler = 'None',
    [ValidateSet('Auto','Realtime','Balanced','Quality','Max')] [string] $UpscalerVariant = 'Auto',
    [ValidateRange(0.0,1.0)] [double] $UpscalerStrength = 1.0,
    [ValidateSet('DLSSOnly','VSRThenDLSS','DLSSThenVSR')] [string] $PipelineOrder = 'VSRThenDLSS',
    [ValidateSet('Off','CinemaSBS','DepthSBS','Equirect360')] [string] $VRMode = 'Off',
    [ValidateSet('HalfSBS','FullSBS')] [string] $VRSbsLayout = 'HalfSBS',
    [ValidateRange(0.1,3.0)] [double] $VREyeSeparation = 1.0,
    [ValidateRange(0.1,0.9)] [double] $VRConvergence = 0.48,
    [double] $StartSeconds = 0,
    [int] $FrameCount = 8,
    [int] $OverrideFps = 0,
    [switch] $LivePreview,
    [switch] $PreviewOnly,
    [ValidateRange(3,30)] [int] $RealtimeBufferSeconds = 5,
    [string] $RealtimeControlPath,
    [switch] $RealtimeFullscreen,
    [string] $InputHeadersPath,
    [switch] $InputTlsNoVerify,
    [ValidateRange(256,768)] [int] $RealtimeGuideWidth = 320,
    [ValidateRange(1,24)] [int] $RealtimeDepthInterval = 24,
    [ValidateRange(1,24)] [int] $RealtimeDepthMinInterval = 12,
    [ValidateRange(0.0,1.0)] [double] $RealtimeAdaptiveConfidence = 0.75,
    [ValidateRange(0.0,30.0)] [double] $RealtimeAdaptiveMotion = 10.0,
    [ValidateRange(0.0,0.9)] [double] $RealtimeTemporalDepth = 0.55,
    [ValidateRange(0.03,0.35)] [double] $RealtimeSceneCutThreshold = 0.12,
    [ValidateSet('quality','balanced','realtime')] [string] $RealtimeMotionPreset = 'realtime',
    [ValidateSet('dis','raft')] [string] $RealtimeMotionBackend = 'dis',
    [ValidateRange(1,12)] [int] $RealtimeRaftUpdates = 4,
    [ValidateSet('Source','Double','60')] [string] $RealtimeFpsMode = 'Source',
    [ValidateSet('Off','MotionGPU','CompatibilityBlend','NvidiaDLSSG','NvidiaOpticalFlow','Rife')] [string] $RealtimeFrameGeneration = 'Off',
    [switch] $CreateComparison,
    [switch] $KeepTemporaryFiles
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Engine = Join-Path $Root 'engine'
$Tools = Join-Path $Root 'tools'
$Ffmpeg = Join-Path $Tools 'ffmpeg.exe'
$Ffprobe = Join-Path $Tools 'ffprobe.exe'
$GuideGenerator = Join-Path $Tools 'guidegen\guidegen.exe'
$GuideGeneratorScript = Join-Path $Tools 'guidegen\guidegen.py'
$DepthCodeRoot = $null
switch ($DepthModelProfile) {
    'VideoDepthSmall' {
        $DepthModel = Join-Path $Root 'models\depth\video_depth_anything_vits.pth'
        $DepthCodeRoot = Join-Path $Root 'third_party\video-depth-anything'
        $DepthEngine = 'video-depth-small'
    }
    'DA3Small' {
        $DepthModel = Join-Path $Root 'models\depth\da3-small'
        $DepthCodeRoot = Join-Path $Root 'third_party\depth-anything-3'
        $DepthEngine = 'da3-small'
    }
    'DA3Base' {
        $DepthModel = Join-Path $Root 'models\depth\da3-base'
        $DepthCodeRoot = Join-Path $Root 'third_party\depth-anything-3'
        $DepthEngine = 'da3-base'
    }
    default {
        $DepthModel = Join-Path $Root 'models\depth_anything_v2_small.onnx'
        $DepthEngine = 'da2-small'
    }
}
$VideoHost = Join-Path $Engine 'dlss5-video-host.exe'
$UpscalerPython = Join-Path $Root 'runtime\python\python.exe'
$UpscalerWorker = Join-Path $Root 'tools\upscaler\upscaler_worker.py'
$UpscalerModels = Join-Path $Root 'models\upscalers'
$UpscalerBackends = Join-Path $Root 'tools\upscaler\backends'
$UpscalerThirdParty = Join-Path $Root 'third_party'
$RaftWeights = Join-Path $Root 'models\motion\raft_small_C_T_V2-01064c6d.pth'
$SpatialMediaTool = Join-Path $Tools 'spatialmedia\__main__.py'
$VRDepthWorker = Join-Path $Tools 'vr_depth\vr_depth_worker.py'

function Stage([int] $Current, [int] $Total, [string] $Message) {
    Write-Output "STUDIO_STAGE $Current/$Total $Message"
}

function Emit-Progress([string] $Phase, [string] $Message, [double] $Percent, [int] $ProcessedFrames, [int] $PhaseFrames, [double] $PhaseElapsedSeconds) {
    $Clamped = [math]::Max(0.0,[math]::Min(100.0,$Percent))
    $Elapsed = $PipelineWatch.Elapsed.TotalSeconds
    $Eta = if ($Clamped -gt 0.25 -and $Clamped -lt 100) { [math]::Max(0.0,$Elapsed*(100.0-$Clamped)/$Clamped) } else { $null }
    $PhaseFps = if ($PhaseElapsedSeconds -gt 0 -and $ProcessedFrames -gt 0) { $ProcessedFrames/$PhaseElapsedSeconds } else { 0.0 }
    $Payload = [ordered]@{
        phase=$Phase; message=$Message; percent=[math]::Round($Clamped,3)
        processed_frames=$ProcessedFrames; total_frames=$PhaseFrames
        elapsed_seconds=[math]::Round($Elapsed,3); eta_seconds=if($null-ne$Eta){[math]::Round($Eta,3)}else{$null}
        phase_fps=[math]::Round($PhaseFps,4)
    }
    Write-Output ('STUDIO_PROGRESS_JSON '+($Payload|ConvertTo-Json -Compress))
}

function Join-EncodedChunks([string] $Directory, [string] $Destination, [int] $ExpectedChunks, [string] $ListName) {
    $ConcatList = Join-Path $Work $ListName
    $Lines = Get-ChildItem -LiteralPath $Directory -Filter 'chunk-*.mp4' | Sort-Object Name | ForEach-Object {
        $EscapedPath = $_.FullName.Replace("'", "''")
        "file '$EscapedPath'"
    }
    if (@($Lines).Count -ne $ExpectedChunks) { throw "Encoded chunk count in $Directory does not match the requested range." }
    [IO.File]::WriteAllLines($ConcatList, $Lines, $Utf8NoBom)
    Run-Tool $Ffmpeg @('-y','-v','error','-f','concat','-safe','0','-i',$ConcatList,'-c','copy',$Destination) 'Chunk joining failed'
}

function Run-Tool([string] $File, [object[]] $Arguments, [string] $Failure) {
    & $File @Arguments 2>&1 | ForEach-Object { Write-Output ([string]$_) }
    if ($LASTEXITCODE -ne 0) { throw "$Failure (exit code $LASTEXITCODE)" }
}

function Parse-Rate([string] $Value) {
    if ($Value -match '^(?<a>[0-9.]+)\/(?<b>[0-9.]+)$') {
        $A = [double]::Parse($Matches.a, [Globalization.CultureInfo]::InvariantCulture)
        $B = [double]::Parse($Matches.b, [Globalization.CultureInfo]::InvariantCulture)
        if ($B -gt 0) { return $A / $B }
    }
    return [double]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Even([double] $Value) { return [int](2 * [math]::Max(1, [math]::Floor($Value / 2))) }
function MultipleOfFour([double] $Value) { return [int](4 * [math]::Max(16, [math]::Floor($Value / 4))) }

function Resolve-HardwareProfile([string] $Requested) {
    if ($Requested -ne 'Auto') { return $Requested }
    try {
        $Smi = Get-Command nvidia-smi.exe -ErrorAction Stop
        $GpuLine = (& $Smi.Source --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if ($GpuLine -match '^(?<name>.*),\s*(?<memory>[0-9]+)\s*$') {
            $MemoryMiB = [int]$Matches.memory
            if ($Matches.name -match 'RTX\s*5080' -or $MemoryMiB -ge 14000) { return 'RTX5080' }
        }
    } catch {}
    return 'Laptop8GB'
}

function Resolve-RealtimeRenderScale([string] $Preset, [string] $ResolvedHardware, [int] $TargetWidth, [int] $TargetHeight) {
    if ($Preset -eq 'Native') { return 1.0 }
    if ($Preset -eq 'Quality') { return 0.75 }
    if ($Preset -eq 'Balanced') { return 2.0 / 3.0 }
    if ($Preset -eq 'Performance') { return 0.5 }

    # Auto targets the actual machines this package is built for. Detect 4K by
    # width as well as height so 3840x1600/1640 ultrawide sources do not fall
    # into the much heavier 1440p profile merely because they are letterboxed.
    # These are DLSS inputs, not an extra post-resize filter.
    if ($ResolvedHardware -eq 'RTX5080') {
        if ($TargetWidth -ge 3600 -or $TargetHeight -ge 2000) { return 2.0 / 3.0 }
        return 0.75
    }
    if ($TargetHeight -ge 2000) { return 0.5 }
    if ($TargetHeight -ge 1300) { return 0.625 }
    if ($TargetHeight -ge 900) { return 2.0 / 3.0 }
    return 0.75
}

function Quote-ProcessArgument([string] $Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Start-ProtocolProcess([string] $File, [string[]] $Arguments, [string] $WorkingDirectory) {
    $Psi = New-Object Diagnostics.ProcessStartInfo
    $Psi.FileName = $File
    $Psi.Arguments = (($Arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
    $Psi.WorkingDirectory = $WorkingDirectory
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardInput = $true
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    $Psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $Psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $Process = New-Object Diagnostics.Process
    $Process.StartInfo = $Psi
    if (-not $Process.Start()) { throw "Could not start $File" }
    $Process.StandardInput.AutoFlush = $true
    return $Process
}

function Wait-ProtocolLine($Process, [string] $Prefix, [string] $Name) {
    while ($true) {
        $Line = $Process.StandardOutput.ReadLine()
        if ($null -eq $Line) { break }
        Write-Output $Line
        if ($Line.StartsWith($Prefix, [StringComparison]::Ordinal)) {
            $script:LastProtocolLine = $Line
            return
        }
    }
    $Details = $Process.StandardError.ReadToEnd().Trim()
    if ($Details) { Write-Output ("$Name stderr: $Details") }
    throw "$Name exited before '$Prefix'"
}

$IsNetworkSource = $InputVideo -match '^https?://'
$RequiredFiles = @($ConfigPath,$Ffmpeg,$Ffprobe,$GuideGenerator,$VideoHost)
$RequiredDirectories = @()
if ($DepthModelProfile -in @('DA3Small','DA3Base')) { $RequiredDirectories += $DepthModel } else { $RequiredFiles += $DepthModel }
if (-not $IsNetworkSource) { $RequiredFiles += $InputVideo }
if (-not [string]::IsNullOrWhiteSpace($InputHeadersPath)) { $RequiredFiles += $InputHeadersPath }
if ($Upscaler -ne 'None') { $RequiredFiles += @($UpscalerPython,$UpscalerWorker) }
if ($PerformanceProfile -eq 'Realtime') { $RequiredFiles += @($UpscalerPython,$GuideGeneratorScript) }
if ($DepthModelProfile -ne 'DA2Small') {
    $RequiredFiles += @($UpscalerPython,$GuideGeneratorScript)
    $RequiredDirectories += $DepthCodeRoot
}
if ($PerformanceProfile -eq 'Realtime' -and $RealtimeMotionBackend -eq 'raft') { $RequiredFiles += $RaftWeights }
if ($VRMode -ne 'Off') { $RequiredFiles += @($UpscalerPython,$SpatialMediaTool) }
if ($VRMode -eq 'DepthSBS') { $RequiredFiles += $VRDepthWorker }
foreach ($Path in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" }
}
foreach ($Path in $RequiredDirectories) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Required directory is missing: $Path" }
}
if ($Upscaler -eq 'DLoRAL') {
    $DLoRALCheckpoint = Join-Path $UpscalerModels 'dloral\model.pkl'
    if (-not (Test-Path -LiteralPath $DLoRALCheckpoint -PathType Leaf)) {
        throw 'DLoRAL checkpoint is not installed because the official Google Drive quota is exhausted. Run INSTALL_MODELS.cmd later; the other neural models are ready now.'
    }
}
if ($StartSeconds -lt 0) { throw 'Start time cannot be negative.' }

$InputVideo = if ($IsNetworkSource) { [string]$InputVideo } else { [IO.Path]::GetFullPath($InputVideo) }
$InputHeadersPath = if ([string]::IsNullOrWhiteSpace($InputHeadersPath)) { $null } else { [IO.Path]::GetFullPath($InputHeadersPath) }
$InputHeaderBlock = $null
if ($InputHeadersPath) {
    try {
        $HeaderObject = Get-Content -LiteralPath $InputHeadersPath -Raw | ConvertFrom-Json
        $HeaderLines = foreach ($Property in $HeaderObject.PSObject.Properties) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Property.Value)) { '{0}: {1}' -f $Property.Name,$Property.Value }
        }
        if ($HeaderLines) { $InputHeaderBlock = ($HeaderLines -join "`r`n") + "`r`n" }
    } catch { throw 'Input HTTP headers file is invalid.' }
}
$NetworkInputOptions = @()
if ($InputTlsNoVerify) { $NetworkInputOptions += @('-tls_verify','0') }
if ($InputHeaderBlock) { $NetworkInputOptions += @('-headers',$InputHeaderBlock) }
$IsPreviewOnly = [bool]$PreviewOnly -or $PerformanceProfile -eq 'Realtime'
if (-not $IsPreviewOnly -and $RealtimeFrameGeneration -ne 'Off') { throw 'Realtime frame generation is available only in display mode.' }
if ($RealtimeFrameGeneration -in @('NvidiaOpticalFlow','Rife')) {
    throw "$RealtimeFrameGeneration is not active in this build yet; use MotionGPU or CompatibilityBlend."
}
if ($RealtimeFrameGeneration -eq 'NvidiaDLSSG') {
    foreach ($RequiredStreamlineFile in @('sl.interposer.dll','sl.common.dll','sl.dlss_g.dll','sl.reflex.dll','sl.pcl.dll','nvngx_dlssg.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Engine $RequiredStreamlineFile))) {
            throw "NVIDIA DLSS-G runtime is incomplete: $RequiredStreamlineFile is missing from engine."
        }
    }
}
if ($Upscaler -eq 'None') { $PipelineOrder = 'DLSSOnly' }
elseif ($PipelineOrder -eq 'DLSSOnly') { throw 'DLSSOnly cannot be combined with an external VSR model.' }
if ($IsPreviewOnly -and $PipelineOrder -eq 'DLSSThenVSR') { throw 'DLSSThenVSR is an offline recording order; realtime display requires VSRThenDLSS.' }
if ($IsPreviewOnly -and $VRMode -ne 'Off') { throw 'VR packaging requires a recorded video and is unavailable in display-only mode.' }
if (-not $IsPreviewOnly -and [string]::IsNullOrWhiteSpace($OutputVideo)) {
    throw 'OutputVideo is required for Quality and Balanced recording profiles.'
}
if ($IsPreviewOnly) {
    $LivePreview = $true
    $CreateComparison = $false
    $OutputVideo = $null
    $OutputDirectory = $null
} else {
    $OutputVideo = [IO.Path]::GetFullPath($OutputVideo)
    $OutputDirectory = [IO.Path]::GetDirectoryName($OutputVideo)
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
}

Stage 1 8 'Reading the input video'
$ProbeArguments = @('-v','error') + $NetworkInputOptions + @(
    '-select_streams','v:0','-show_entries','stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration',
    '-show_entries','format=duration','-of','json',$InputVideo
)
$ProbeText = & $Ffprobe @ProbeArguments
if ($LASTEXITCODE -ne 0) { throw 'ffprobe could not read the input video.' }
$Probe = $ProbeText | ConvertFrom-Json
$Stream = $Probe.streams[0]
if ($null -eq $Stream -or [int]$Stream.width -lt 64 -or [int]$Stream.height -lt 64) {
    throw 'The input does not contain a supported video stream.'
}
$SourceWidth = [int]$Stream.width
$SourceHeight = [int]$Stream.height
$RateText = if ($Stream.avg_frame_rate -and $Stream.avg_frame_rate -ne '0/0') { $Stream.avg_frame_rate } else { $Stream.r_frame_rate }
$SourceRate = Parse-Rate ([string]$RateText)
$UseCompatibilityInterpolation = $IsPreviewOnly -and $RealtimeFrameGeneration -eq 'CompatibilityBlend' -and $RealtimeFpsMode -ne 'Source'
$Fps = if ($OverrideFps -gt 0) {
    $OverrideFps
} elseif ($UseCompatibilityInterpolation -and $RealtimeFpsMode -eq 'Double') {
    [int][math]::Round([math]::Min(60.0,$SourceRate*2.0))
} elseif ($UseCompatibilityInterpolation -and $RealtimeFpsMode -eq '60') {
    60
} else {
    [int][math]::Round($SourceRate)
}
$Fps = [math]::Max(1, [math]::Min(120, $Fps))
$Duration = if ($Stream.duration) { [double]::Parse([string]$Stream.duration, [Globalization.CultureInfo]::InvariantCulture) } else { [double]$Probe.format.duration }
if ($Duration -le $StartSeconds) { throw 'Start time is outside the video.' }
$AvailableFrames = [int][math]::Max(1, [math]::Floor(($Duration - $StartSeconds) * $Fps))
$TotalFrames = if ($FrameCount -gt 0) { [math]::Min($FrameCount, $AvailableFrames) } else { $AvailableFrames }

function Fit-Geometry([int] $Width, [int] $Height, [int] $MaxWidth, [int] $MaxHeight, [bool] $AllowUpscale) {
    $Scale = [math]::Min($MaxWidth / [double]$Width, $MaxHeight / [double]$Height)
    if (-not $AllowUpscale) { $Scale = [math]::Min(1.0, $Scale) }
    return @((Even ($Width * $Scale)), (Even ($Height * $Scale)))
}

$Mode = if ($OutputMode -eq 'Same') { 'Source' } elseif ($OutputMode -eq '4K') { '2160p' } else { $OutputMode }
switch ($Mode) {
    '2160p' { $TargetBox = @(3840,2160); $AllowUpscale = $true }
    '1440p' { $TargetBox = @(2560,1440); $AllowUpscale = $true }
    '1080p' { $TargetBox = @(1920,1080); $AllowUpscale = $true }
    '720p'  { $TargetBox = @(1280,720);  $AllowUpscale = $true }
    '540p'  { $TargetBox = @(960,540);   $AllowUpscale = $true }
    default { $TargetBox = @(3840,2160); $AllowUpscale = $false }
}
$OutputGeometry = Fit-Geometry $SourceWidth $SourceHeight $TargetBox[0] $TargetBox[1] $AllowUpscale
$OutputWidth = $OutputGeometry[0]
$OutputHeight = $OutputGeometry[1]
$ResolvedHardwareProfile = Resolve-HardwareProfile $HardwareProfile
$UseExternalUpscaler = $Upscaler -ne 'None'
$VsrBeforeDlss = $UseExternalUpscaler -and $PipelineOrder -eq 'VSRThenDLSS'
$VsrAfterDlss = $UseExternalUpscaler -and $PipelineOrder -eq 'DLSSThenVSR'
if ($UseExternalUpscaler) {
    # All selected VSR networks are native x4 models. Keep the exact display
    # aspect while making both dimensions legal x4 outputs.
    $UpscalerInputWidth = Even ((MultipleOfFour $OutputWidth) / 4)
    $UpscalerInputHeight = Even ((MultipleOfFour $OutputHeight) / 4)
    $OutputWidth = $UpscalerInputWidth * 4
    $OutputHeight = $UpscalerInputHeight * 4
}
$RenderScale = [math]::Min(1.0, [math]::Min($OutputWidth / [double]$SourceWidth, $OutputHeight / [double]$SourceHeight))
if ($UseExternalUpscaler) {
    $RenderWidth = $OutputWidth
    $RenderHeight = $OutputHeight
} elseif ($IsPreviewOnly) {
    $ResolvedRealtimeRenderScale = Resolve-RealtimeRenderScale $RealtimeRenderPreset $ResolvedHardwareProfile $OutputWidth $OutputHeight
    $RenderWidth = MultipleOfFour ($OutputWidth * $ResolvedRealtimeRenderScale)
    $RenderHeight = MultipleOfFour ($OutputHeight * $ResolvedRealtimeRenderScale)
} elseif ($RenderScale -lt 1.0) {
    $RenderWidth = $OutputWidth
    $RenderHeight = $OutputHeight
} else {
    $RenderWidth = Even $SourceWidth
    $RenderHeight = Even $SourceHeight
}
$ResolvedRealtimeRenderPreset = if (-not $IsPreviewOnly) { 'Native' } elseif ($RealtimeRenderPreset -ne 'Auto') { $RealtimeRenderPreset } else { 'Auto' }
$DlssInputWidth = if ($VsrAfterDlss) { $UpscalerInputWidth } else { $RenderWidth }
$DlssInputHeight = if ($VsrAfterDlss) { $UpscalerInputHeight } else { $RenderHeight }
$DlssOutputWidth = if ($VsrAfterDlss) { $UpscalerInputWidth } else { $OutputWidth }
$DlssOutputHeight = if ($VsrAfterDlss) { $UpscalerInputHeight } else { $OutputHeight }
if ($VRMode -eq 'Equirect360' -and [math]::Abs(($OutputWidth/[double]$OutputHeight)-2.0) -gt 0.035) {
    throw 'Equirect360 requires a 2:1 panoramic source/output (for example 3840x1920). Use CinemaSBS for ordinary flat video.'
}

$SceneCutThreshold = 0.12
switch ($PerformanceProfile) {
    'Quality' {
        $GuideWidth = 640; $DepthInterval = 1; $DepthMinInterval = 1
        $AdaptiveConfidence = 0.55; $AdaptiveMotion = 6.0; $TemporalDepth = 0.25
        $MotionPreset = 'quality'; $ChunkSize = if ($RenderWidth -ge 3000) { 32 } else { 64 }
    }
    'Realtime' {
        # Realtime stability profile: DML depth refreshes often enough to stop
        # long optical-flow drift, while adaptive refresh catches difficult
        # motion between regular keyframes. The guide generator performs affine
        # depth alignment, edge-aware refinement and confidence masking.
        $GuideWidth = $RealtimeGuideWidth
        $DepthInterval = $RealtimeDepthInterval
        $DepthMinInterval = [math]::Min($RealtimeDepthMinInterval,$RealtimeDepthInterval)
        $AdaptiveConfidence = $RealtimeAdaptiveConfidence
        $AdaptiveMotion = $RealtimeAdaptiveMotion
        $TemporalDepth = $RealtimeTemporalDepth
        $SceneCutThreshold = $RealtimeSceneCutThreshold
        $MotionPreset = $RealtimeMotionPreset
        $ChunkSize = if ($RenderWidth -ge 3000) { 48 } elseif ($RenderWidth -ge 1900) { 64 } else { 96 }
    }
    'Turbo' {
        # Real motion and neural depth stay enabled, but the guide grid and
        # depth refresh cadence are tuned for throughput. Feature 18 still
        # evaluates every full-resolution frame.
        $GuideWidth = 256; $DepthInterval = 8; $DepthMinInterval = 8
        $AdaptiveConfidence = 0.0; $AdaptiveMotion = 0.0; $TemporalDepth = 0.70
        $MotionPreset = 'realtime'
        $ChunkSize = if ($RenderWidth -ge 3000) { 48 } elseif ($RenderWidth -ge 1900) { 72 } else { 128 }
    }
    default {
        $GuideWidth = 480; $DepthInterval = 2; $DepthMinInterval = 2
        $AdaptiveConfidence = 0.45; $AdaptiveMotion = 10.0; $TemporalDepth = 0.35
        $MotionPreset = 'balanced'; $ChunkSize = if ($RenderWidth -ge 3000) { 48 } elseif ($RenderWidth -ge 1900) { 72 } else { 96 }
    }
}

if ($UseExternalUpscaler) {
    switch ($Upscaler) {
        'NanoVSR' { $ChunkSize = 15 }
        'AnimeSR' { $ChunkSize = if ($OutputWidth -ge 3000) { 6 } elseif ($OutputWidth -ge 1900) { 12 } else { 24 } }
        'FlashVSR' { $ChunkSize = 21 }
        'DLoRAL' { $ChunkSize = 1 }
    }
}

# The native NGX host still consumes narrow command-line arguments. The whole
# working set therefore lives in a stable ASCII path; source and final output
# may contain any Unicode characters because FFmpeg/PowerShell handle them.
$RunId = 'job-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0,8))
$FastDrive = [IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq [IO.DriveType]::Fixed } | Sort-Object AvailableFreeSpace -Descending | Select-Object -First 1
$WorkBase = if ($IsPreviewOnly) {
    # Realtime is latency-sensitive and constantly writes/reads motion+depth
    # chunks.  The old "most free space" rule often selected a large archive
    # disk; use the local system SSD instead so other disk jobs cannot stall
    # playback between chunks.
    Join-Path $env:LOCALAPPDATA 'DLSS5VideoStudio\temp'
} elseif ($FastDrive) {
    Join-Path $FastDrive.RootDirectory.FullName 'DLSS5VideoStudio\temp'
} else {
    Join-Path $env:ProgramData 'DLSS5VideoStudio\temp'
}
$Work = Join-Path $WorkBase $RunId
$ChunkDirectory = Join-Path $Work 'chunks'
$LogDirectory = if ($IsPreviewOnly) { $null } else { [IO.Path]::ChangeExtension($OutputVideo, '.logs') }
New-Item -ItemType Directory -Force -Path $Work,$ChunkDirectory | Out-Null
Write-Output "STUDIO_WORK $Work"
if ($LogDirectory) { New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null }
$VideoOnly = Join-Path $Work 'video-only.mp4'
$EncodedChunkDirectory = Join-Path $Work 'encoded'
$HostEncodedChunkDirectory = if ($VsrAfterDlss) { Join-Path $Work 'encoded-dlss' } else { $EncodedChunkDirectory }
$DlssIntermediate = Join-Path $Work 'dlss-intermediate.mp4'
$FlatOutput = if ($VRMode -eq 'Off') { $OutputVideo } else { Join-Path $Work 'flat-output.mp4' }
$VrEncoded = Join-Path $Work 'vr-encoded.mp4'
# On RTX 4060 the continuous NVENC pipe contends with Feature 18 and is much
# slower than short post-chunk encode bursts. Keep the paths isolated.
$DirectEncode = $false
if (-not $IsPreviewOnly) {
    New-Item -ItemType Directory -Force -Path $EncodedChunkDirectory | Out-Null
    if ($VsrAfterDlss) { New-Item -ItemType Directory -Force -Path $HostEncodedChunkDirectory | Out-Null }
}
$DepthCache = Join-Path (Join-Path $env:ProgramData 'DLSS5VideoStudio') 'depth-cache'
New-Item -ItemType Directory -Force -Path $DepthCache | Out-Null

$RealtimeBufferFrames = if ($IsPreviewOnly) { [int][math]::Max(1,[math]::Ceiling($Fps*$RealtimeBufferSeconds)) } else { 0 }
$StartupChunkSize = if ($IsPreviewOnly) {
    [math]::Min($TotalFrames,$RealtimeBufferFrames)
} elseif (-not $UseExternalUpscaler -and $TotalFrames -gt 1) {
    if ($PerformanceProfile -eq 'Turbo') { 2 } elseif ($PerformanceProfile -eq 'Quality') { 4 } else { 8 }
} else { $ChunkSize }
$ChunkFrameCounts = New-Object 'Collections.Generic.List[int]'
$RemainingFrames = $TotalFrames
if ($IsPreviewOnly -and $RemainingFrames -gt $StartupChunkSize) {
    $ChunkFrameCounts.Add([int]$StartupChunkSize)
    $RemainingFrames -= $StartupChunkSize
} elseif ($StartupChunkSize -lt $ChunkSize -and $RemainingFrames -gt $StartupChunkSize) {
    $ChunkFrameCounts.Add([int]$StartupChunkSize)
    $RemainingFrames -= $StartupChunkSize
}
while ($RemainingFrames -gt 0) {
    $FramesInChunk = [math]::Min($ChunkSize,$RemainingFrames)
    $ChunkFrameCounts.Add([int]$FramesInChunk)
    $RemainingFrames -= $FramesInChunk
}
$Chunks = $ChunkFrameCounts.Count
$ChunkOffsets = New-Object 'Collections.Generic.List[int]'
$ChunkEndFrames = New-Object 'Collections.Generic.List[int]'
$ChunkCursor = 0
foreach ($FramesInChunk in $ChunkFrameCounts) {
    $ChunkOffsets.Add([int]$ChunkCursor)
    $ChunkCursor += $FramesInChunk
    $ChunkEndFrames.Add([int]$ChunkCursor)
}
$CodecName = if ($Codec -eq 'H265') { 'h265' } else { 'h264' }
$PreviousPath = $env:PATH
$env:PATH = $Tools + ';' + $env:PATH
$GuideProcess = $null
$HostProcess = $null
$UpscalerProcess = $null
$PipelineWatch = [Diagnostics.Stopwatch]::StartNew()
$GuideReadySeconds = 0.0
$HostReadySeconds = 0.0
$FirstGuideChunkSeconds = 0.0
$FirstHostChunkSeconds = 0.0
$GuideComputeSeconds = 0.0
$GuideQualityFrames = 0
$GuideLowConfidenceWeighted = 0.0
$GuideDepthFrames = 0
$GuideSceneCuts = 0
$DecoderSeconds = 0.0
$UpscalerSeconds = 0.0
$UpscalerResolvedVariant = $null
$UpscalerGpu = $null
$UpscalerLoadSeconds = 0.0
$UpscalerPeakVramMb = 0
$UpscalerReservedVramMb = 0
$DepthProvider = 'unknown'
$MotionProvider = $null
$PipelineLabel = switch ($PipelineOrder) { 'DLSSThenVSR' { "DLSS5 -> $Upscaler" } 'VSRThenDLSS' { "$Upscaler -> DLSS5" } default { 'DLSS5' } }
$ContainerWidth = if ($VRMode -in @('CinemaSBS','DepthSBS') -and $VRSbsLayout -eq 'FullSBS') { $OutputWidth*2 } else { $OutputWidth }
$Plan = [ordered]@{
    source_geometry=@($SourceWidth,$SourceHeight); output_geometry=@($OutputWidth,$OutputHeight)
    render_geometry=@($DlssInputWidth,$DlssInputHeight); hardware_profile=$ResolvedHardwareProfile
    realtime_render_preset=if($IsPreviewOnly){$ResolvedRealtimeRenderPreset}else{$null}
    depth_model_profile=$DepthModelProfile
    container_geometry=@($ContainerWidth,$OutputHeight); source_fps=$SourceRate; fps=$Fps
    duration_seconds=$Duration; total_frames=$TotalFrames; pipeline_order=$PipelineOrder
    pipeline_label=$PipelineLabel; vr_mode=$VRMode; vr_layout=$VRSbsLayout
    vr_eye_separation=if($VRMode-eq'DepthSBS'){$VREyeSeparation}else{$null}
    vr_convergence=if($VRMode-eq'DepthSBS'){$VRConvergence}else{$null}
    realtime_buffer_seconds=if($IsPreviewOnly){$RealtimeBufferSeconds}else{$null}
    realtime_buffer_frames=if($IsPreviewOnly){$RealtimeBufferFrames}else{$null}
    source_kind=if($IsNetworkSource){'network'}else{'file'}
    realtime_quality=if($IsPreviewOnly){[ordered]@{
        guide_width=$GuideWidth; depth_interval=$DepthInterval; depth_min_interval=$DepthMinInterval
        adaptive_confidence=$AdaptiveConfidence; adaptive_motion=$AdaptiveMotion
        temporal_depth=$TemporalDepth; scene_cut_threshold=$SceneCutThreshold; motion_preset=$MotionPreset
        motion_backend=$RealtimeMotionBackend; raft_updates=$RealtimeRaftUpdates
        fps_mode=$RealtimeFpsMode
        frame_generation=$RealtimeFrameGeneration
    }}else{$null}
}
Write-Output ('STUDIO_PLAN '+($Plan|ConvertTo-Json -Compress -Depth 4))
Emit-Progress 'Setup' 'Preparing engines and temporary workspace' 1 0 $TotalFrames 0

try {
    Stage 2 8 $(if ($VsrBeforeDlss) { "Starting persistent $Upscaler, DLSS5 and guide engines" } elseif ($VsrAfterDlss) { "Starting DLSS5 and guide engines; $Upscaler follows" } else { 'Starting persistent DLSS5 and guide engines' })
    $EngineConfig = Join-Path $Engine 'ReShade.ini'
    Copy-Item -LiteralPath $ConfigPath -Destination $EngineConfig -Force
    $ConfigText = Get-Content -LiteralPath $EngineConfig -Raw
    $UpscalingFlag = if ($DlssOutputWidth -gt $DlssInputWidth -or $DlssOutputHeight -gt $DlssInputHeight) { '1' } else { '0' }
    $ConfigText = [regex]::Replace($ConfigText, '(?m)^NREnableUpscaling=.*$', "NREnableUpscaling=$UpscalingFlag")
    # ReShade treats a fresh portable folder as a first launch and otherwise
    # paints its tutorial banner over the real-time image. Mark the tutorial as
    # completed and suppress transient overlay messages while preserving Home
    # as the manual settings hotkey.
    $OverlaySettings = [ordered]@{
        TutorialProgress = '4'
        ShowScreenshotMessage = '0'
        ShowForceLoadEffectsButton = '0'
        ShowPresetName = '0'
        ShowFPS = '0'
        ShowFrameTime = '0'
        ShowClock = '0'
    }
    if ($ConfigText -notmatch '(?mi)^\[OVERLAY\]\s*$') {
        $ConfigText = $ConfigText.TrimEnd() + "`r`n`r`n[OVERLAY]`r`n"
        foreach ($Entry in $OverlaySettings.GetEnumerator()) { $ConfigText += "$($Entry.Key)=$($Entry.Value)`r`n" }
    } else {
        foreach ($Entry in $OverlaySettings.GetEnumerator()) {
            $KeyPattern = '(?mi)^' + [regex]::Escape([string]$Entry.Key) + '=.*$'
            if ($ConfigText -match $KeyPattern) {
                $ConfigText = [regex]::Replace($ConfigText,$KeyPattern,"$($Entry.Key)=$($Entry.Value)")
            } else {
                $ConfigText = [regex]::Replace($ConfigText,'(?mi)^\[OVERLAY\]\s*$',"[OVERLAY]`r`n$($Entry.Key)=$($Entry.Value)")
            }
        }
    }
    [IO.File]::WriteAllText($EngineConfig, $ConfigText, $Utf8NoBom)
    foreach ($Name in @('ReShade.log','dlss5-video-host.log')) {
        $Old = Join-Path $Engine $Name
        if (Test-Path -LiteralPath $Old) { Move-Item -LiteralPath $Old -Destination ($Old + '.previous') -Force }
    }

    $GuideArgs = @(
        '--server','--width',$DlssInputWidth,'--height',$DlssInputHeight,'--depth-model',$DepthModel,
        '--depth-engine',$DepthEngine,'--depth-backend','auto','--cache-dir',$DepthCache,'--guide-width',$GuideWidth,
        '--depth-interval',$DepthInterval,'--depth-min-interval',$DepthMinInterval,
        '--motion-preset',$MotionPreset,
        '--motion-backend',$(if($IsPreviewOnly){$RealtimeMotionBackend}else{'dis'}),
        '--scene-cut-threshold',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$SceneCutThreshold)),'--adaptive-confidence',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$AdaptiveConfidence)),
        '--adaptive-motion',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$AdaptiveMotion)),
        '--temporal-depth',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$TemporalDepth))
    )
    if ($DepthCodeRoot) { $GuideArgs += @('--depth-code-root',$DepthCodeRoot) }
    if ($IsPreviewOnly -and $RealtimeMotionBackend -eq 'raft') {
        $GuideArgs += @('--raft-weights',$RaftWeights,'--raft-updates',$RealtimeRaftUpdates,'--raft-batch-size','4')
    }
    if ($IsPreviewOnly) { $GuideArgs += @('--opencv-threads','2') }
    if (-not $VsrBeforeDlss) {
        $GuideArgs += @(
            '--decode-video',$InputVideo,'--ffmpeg',$Ffmpeg,
            '--start-seconds',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.######}',$StartSeconds)),
            '--fps',$Fps,'--total-frames',$TotalFrames
        )
        if ($UseCompatibilityInterpolation) { $GuideArgs += @('--frame-interpolation','blend') }
        if ($InputHeadersPath) { $GuideArgs += @('--input-headers-json',$InputHeadersPath) }
        if ($InputTlsNoVerify) { $GuideArgs += '--input-tls-no-verify' }
    }
    $HostArgs = @(
        '--batch-stream',
        '--width',$DlssInputWidth,'--height',$DlssInputHeight,'--output-width',$DlssOutputWidth,'--output-height',$DlssOutputHeight,
        '--frames',$TotalFrames,'--fps',$Fps,'--codec',$CodecName,'--quality',$Quality,
        '--timings','--quiet-frames'
    )
    if (-not $UseExternalUpscaler) { $HostArgs += '--fast-start' }
    if ($IsPreviewOnly) {
        $HostArgs += @('--preview-only','--media-start-seconds',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.######}',$StartSeconds)),'--media-duration-seconds',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.######}',$Duration)))
        if ($RealtimeControlPath) { $HostArgs += @('--control-file',[IO.Path]::GetFullPath($RealtimeControlPath)) }
        if ($RealtimeFullscreen) { $HostArgs += '--fullscreen' }
        if ($RealtimeFrameGeneration -eq 'MotionGPU') { $HostArgs += '--frame-generation-motion' }
        if ($RealtimeFrameGeneration -eq 'NvidiaDLSSG') { $HostArgs += '--frame-generation-nvidia' }
    }
    elseif ($DirectEncode) { $HostArgs += @('--encode-mp4',$VideoOnly) }
    else { $HostArgs += @('--encode-chunks-dir',$HostEncodedChunkDirectory) }
    if (-not $IsPreviewOnly -and -not $DirectEncode) {
        # A new writer thread per frame costs 10-50 ms on Windows, while the
        # buffered RGB write itself is sub-millisecond on the target SSD.
        $HostArgs += '--sync-write'
    }
    if (-not $KeepTemporaryFiles -and $VRMode -ne 'DepthSBS') { $HostArgs += '--delete-chunks' }
    if ($LivePreview -and -not $IsPreviewOnly -and -not $VsrAfterDlss) { $HostArgs += '--preview' }
    if ($IsPreviewOnly -or $DepthModelProfile -ne 'DA2Small') {
        $GuideProcess = Start-ProtocolProcess $UpscalerPython (@('-B',$GuideGeneratorScript)+$GuideArgs) $Root
    } else {
        $GuideProcess = Start-ProtocolProcess $GuideGenerator $GuideArgs $Root
    }
    if ($VsrBeforeDlss) {
        $UpscalerArgs = @(
            '-B',$UpscalerWorker,'--server','--backend',$Upscaler.ToLowerInvariant(),
            '--variant',$UpscalerVariant.ToLowerInvariant(),
            '--model-root',$UpscalerModels,'--backend-root',$UpscalerBackends,'--third-party-root',$UpscalerThirdParty,
            '--input-width',$UpscalerInputWidth,'--input-height',$UpscalerInputHeight,
            '--output-width',$OutputWidth,'--output-height',$OutputHeight,
            '--strength',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$UpscalerStrength))
        )
        $UpscalerProcess = Start-ProtocolProcess $UpscalerPython $UpscalerArgs $Root
    }
    $HostProcess = Start-ProtocolProcess $VideoHost $HostArgs $Engine
    Wait-ProtocolLine $GuideProcess 'GUIDE_SERVER_READY ' 'Guide engine'
    $GuideReadySeconds = $PipelineWatch.Elapsed.TotalSeconds
    try {
        $GuideReady = (($script:LastProtocolLine.Substring('GUIDE_SERVER_READY '.Length)) | ConvertFrom-Json)
        $DepthProvider = $GuideReady.provider
        $MotionProvider = $GuideReady.motion_provider
    } catch {}
    if ($VsrBeforeDlss) {
        Wait-ProtocolLine $UpscalerProcess 'UPSCALER_SERVER_READY ' "$Upscaler engine"
        try {
            $UpscalerReady = ($script:LastProtocolLine.Substring('UPSCALER_SERVER_READY '.Length)) | ConvertFrom-Json
            $UpscalerResolvedVariant = [string]$UpscalerReady.variant
            $UpscalerGpu = [string]$UpscalerReady.gpu
            $UpscalerLoadSeconds = [double]$UpscalerReady.load_s
        } catch {}
    }
    Wait-ProtocolLine $HostProcess 'HOST_STREAM_READY' 'DLSS5 host'
    $HostReadySeconds = $PipelineWatch.Elapsed.TotalSeconds

    Stage 3 8 $(if ($VsrBeforeDlss) { "$Upscaler x4 -> DLSS5" } elseif ($VsrAfterDlss) { "DLSS5 at model input resolution -> $Upscaler x4" } else { "DLSS5 with adaptive motion/depth ($PerformanceProfile)" })
    $AcknowledgedChunks = 0
    $PrimaryPhaseWatch = [Diagnostics.Stopwatch]::StartNew()
    if ($VsrBeforeDlss) {
        for ($ChunkIndex = 0; $ChunkIndex -lt $Chunks; $ChunkIndex++) {
            $FirstFrame = $ChunkOffsets[$ChunkIndex]
            $ThisFrames = $ChunkFrameCounts[$ChunkIndex]
            $Prefix = Join-Path $ChunkDirectory ('chunk-{0:D4}' -f $ChunkIndex)
            $LowRaw = $Prefix + '.lq.rgb'
            $Raw = $Prefix + '.rgb'
            $Motion = $Prefix + '.motion'
            $Depth = $Prefix + '.depth'
            $ChunkStart = $StartSeconds + $FirstFrame / [double]$Fps
            $ChunkStartText = [string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.######}',$ChunkStart)

            $DecodeWatch = [Diagnostics.Stopwatch]::StartNew()
            $DecodeFilter = "scale=$($UpscalerInputWidth):$($UpscalerInputHeight):flags=lanczos"
            if ($UseCompatibilityInterpolation) { $DecodeFilter += ",minterpolate=fps=$Fps`:mi_mode=blend" } else { $DecodeFilter += ",fps=$Fps" }
            $DecodeFilter += ',format=rgb24'
            $DecodeArguments = @('-y','-v','error') + $NetworkInputOptions + @(
                '-ss',$ChunkStartText,'-i',$InputVideo,
                '-vf',$DecodeFilter,
                '-frames:v',$ThisFrames,'-an','-f','rawvideo','-pix_fmt','rgb24',$LowRaw
            )
            Run-Tool $Ffmpeg $DecodeArguments 'Low-resolution model input decode failed'
            $DecodeWatch.Stop()
            $DecoderSeconds += $DecodeWatch.Elapsed.TotalSeconds

            $UpscalerCommand = [ordered]@{cmd='chunk';id=$ChunkIndex;input=$LowRaw;output=$Raw;frames=$ThisFrames} | ConvertTo-Json -Compress
            $UpscalerProcess.StandardInput.WriteLine($UpscalerCommand)
            Wait-ProtocolLine $UpscalerProcess 'UPSCALER_CHUNK_READY ' "$Upscaler engine"
            try {
                $UpscalerResult = ($script:LastProtocolLine.Substring('UPSCALER_CHUNK_READY '.Length)) | ConvertFrom-Json
                $UpscalerSeconds += [double]$UpscalerResult.elapsed_s
                $UpscalerPeakVramMb = [math]::Max($UpscalerPeakVramMb,[int]$UpscalerResult.peak_vram_mb)
                $UpscalerReservedVramMb = [math]::Max($UpscalerReservedVramMb,[int]$UpscalerResult.reserved_vram_mb)
            } catch {}

            $GuideCommand = [ordered]@{
                cmd='guides';id=$ChunkIndex;input=$Raw;frames=$ThisFrames
                motion_output=$Motion;depth_output=$Depth
            } | ConvertTo-Json -Compress
            $GuideProcess.StandardInput.WriteLine($GuideCommand)
            Wait-ProtocolLine $GuideProcess 'GUIDE_CHUNK_READY ' 'Guide engine'
            try {
                $GuideResult = ($script:LastProtocolLine.Substring('GUIDE_CHUNK_READY '.Length)) | ConvertFrom-Json
                $GuideComputeSeconds += [double]$GuideResult.elapsed_s
                $GuideQualityFrames += [int]$GuideResult.frames
                $GuideLowConfidenceWeighted += [double]$GuideResult.low_confidence_fraction * [int]$GuideResult.frames
                $GuideDepthFrames += [int]$GuideResult.depth_frames
                $GuideSceneCuts += [int]$GuideResult.scene_cuts
            } catch {}

            $HostProcess.StandardInput.WriteLine("CHUNK`t$ChunkIndex`t$ThisFrames`t$Raw`t$Motion`t$Depth")
            Wait-ProtocolLine $HostProcess 'HOST_CHUNK_SUBMITTED ' 'DLSS5 host'
            if ($AcknowledgedChunks -eq 0) { $FirstHostChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
            $AcknowledgedChunks++
            $DoneFrames = [math]::Min($TotalFrames, $FirstFrame + $ThisFrames)
            $Percent = 5.0 + 85.0*$DoneFrames/[double]$TotalFrames
            Emit-Progress "$Upscaler -> DLSS5" 'VSR restoration, motion/depth guides and DLSS5' $Percent $DoneFrames $TotalFrames $PrimaryPhaseWatch.Elapsed.TotalSeconds
        }
        $UpscalerProcess.StandardInput.WriteLine('{"cmd":"end"}')
        Wait-ProtocolLine $UpscalerProcess 'UPSCALER_SERVER_DONE' "$Upscaler engine"
        $UpscalerProcess.StandardInput.Close()
        $UpscalerProcess.WaitForExit()
        if ($UpscalerProcess.ExitCode -ne 0) { throw "$Upscaler engine failed: $($UpscalerProcess.StandardError.ReadToEnd())" }
    } else {
    for ($ChunkIndex = 0; $ChunkIndex -lt $Chunks; $ChunkIndex++) {
        $FirstFrame = $ChunkOffsets[$ChunkIndex]
        $ThisFrames = $ChunkFrameCounts[$ChunkIndex]
        $Prefix = Join-Path $ChunkDirectory ('chunk-{0:D4}' -f $ChunkIndex)
        $Raw = $Prefix + '.rgb'
        $Motion = $Prefix + '.motion'
        $Depth = $Prefix + '.depth'
        $CommandData = [ordered]@{
            id=$ChunkIndex; input=$Raw; frames=$ThisFrames; first_frame=$FirstFrame
            motion_output=$Motion; depth_output=$Depth
        }
        $PrefetchData = $null
        if ($ChunkIndex + 1 -lt $Chunks) {
            $NextPrefix = Join-Path $ChunkDirectory ('chunk-{0:D4}' -f ($ChunkIndex + 1))
            $PrefetchData = [ordered]@{
                input=($NextPrefix + '.rgb')
                frames=$ChunkFrameCounts[$ChunkIndex + 1]
                first_frame=$ChunkOffsets[$ChunkIndex + 1]
            }
        }
        $GuideChunkWatch = [Diagnostics.Stopwatch]::StartNew()
        if ($ChunkIndex -ge 1) {
            $DecodeWatch = [Diagnostics.Stopwatch]::StartNew()
            $DecodeData = [ordered]@{cmd='decode';id=$ChunkIndex;input=$Raw;frames=$ThisFrames;first_frame=$FirstFrame}
            if ($PrefetchData) { $DecodeData['prefetch'] = $PrefetchData }
            $DecodeCommand = $DecodeData | ConvertTo-Json -Compress -Depth 4
            $GuideProcess.StandardInput.WriteLine($DecodeCommand)
            Wait-ProtocolLine $GuideProcess 'GUIDE_DECODE_READY ' 'Guide decoder'
            $DecodeWatch.Stop()
            try {
                $DecodeResult = $script:LastProtocolLine.Substring('GUIDE_DECODE_READY '.Length) | ConvertFrom-Json
                $DecoderSeconds += [double]$DecodeResult.elapsed_s
            } catch {
                $DecoderSeconds += $DecodeWatch.Elapsed.TotalSeconds
            }
            if (-not $IsPreviewOnly) {
                Wait-ProtocolLine $HostProcess 'HOST_CHUNK_SUBMITTED ' 'DLSS5 host'
                if ($AcknowledgedChunks -eq 0) { $FirstHostChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
                $AcknowledgedChunks++
                $DoneFrames = $ChunkEndFrames[$AcknowledgedChunks - 1]
                $Span = if($VsrAfterDlss){42.0}else{85.0}; $Percent=5.0+$Span*$DoneFrames/[double]$TotalFrames
                Emit-Progress 'DLSS5' 'DLSS5 motion/depth neural rendering' $Percent $DoneFrames $TotalFrames $PrimaryPhaseWatch.Elapsed.TotalSeconds
            }
            $CommandData.cmd = 'guides'
            $GuideChunkWatch.Restart()
        } else {
            $CommandData.cmd = 'chunk'
            if ($PrefetchData) { $CommandData['prefetch'] = $PrefetchData }
        }
        $GuideProcess.StandardInput.WriteLine(($CommandData | ConvertTo-Json -Compress))
        Wait-ProtocolLine $GuideProcess 'GUIDE_CHUNK_READY ' 'Guide engine'
        $GuideChunkWatch.Stop()
        if ($ChunkIndex -eq 0) { $FirstGuideChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
        try {
            $GuideResult = ($script:LastProtocolLine.Substring('GUIDE_CHUNK_READY '.Length)) | ConvertFrom-Json
            $GuideComputeSeconds += [double]$GuideResult.elapsed_s
            $GuideQualityFrames += [int]$GuideResult.frames
            $GuideLowConfidenceWeighted += [double]$GuideResult.low_confidence_fraction * [int]$GuideResult.frames
            $GuideDepthFrames += [int]$GuideResult.depth_frames
            $GuideSceneCuts += [int]$GuideResult.scene_cuts
            if ($ChunkIndex -eq 0) {
                if ($null -ne $GuideResult.decode_s) {
                    $DecoderSeconds += [double]$GuideResult.decode_s
                } else {
                    $DecoderSeconds += [math]::Max(0.0, $GuideChunkWatch.Elapsed.TotalSeconds - [double]$GuideResult.elapsed_s)
                }
            }
        } catch {}

        # Display-only mode generates the next lightweight guide chunk while
        # the current chunk is on screen.  This removes the visible pause that
        # a record-oriented sequential scheduler would introduce at boundaries.
        if ($IsPreviewOnly -and $ChunkIndex -ge 1) {
            Wait-ProtocolLine $HostProcess 'HOST_CHUNK_SUBMITTED ' 'DLSS5 host'
            if ($AcknowledgedChunks -eq 0) { $FirstHostChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
            $AcknowledgedChunks++
            $DoneFrames = $ChunkEndFrames[$AcknowledgedChunks - 1]
            $Span = if($VsrAfterDlss){42.0}else{85.0}; $Percent=5.0+$Span*$DoneFrames/[double]$TotalFrames
            Emit-Progress 'DLSS5' 'DLSS5 motion/depth neural rendering' $Percent $DoneFrames $TotalFrames $PrimaryPhaseWatch.Elapsed.TotalSeconds
        }

        $HostProcess.StandardInput.WriteLine("CHUNK`t$ChunkIndex`t$ThisFrames`t$Raw`t$Motion`t$Depth")
    }
    }

    $GuideProcess.StandardInput.WriteLine('{"cmd":"end"}')
    Wait-ProtocolLine $GuideProcess 'GUIDE_SERVER_DONE' 'Guide engine'
    $GuideProcess.StandardInput.Close()
    $GuideProcess.WaitForExit()
    if ($GuideProcess.ExitCode -ne 0) { throw "Guide engine failed: $($GuideProcess.StandardError.ReadToEnd())" }

    Stage 4 8 $(if ($IsPreviewOnly) { 'Displaying the remaining DLSS5 frames' } elseif ($DirectEncode) { 'Draining the DLSS5 GPU pipeline and continuous NVENC stream' } else { 'Draining the DLSS5 GPU pipeline and NVENC encoder' })
    while ($AcknowledgedChunks -lt $Chunks) {
        Wait-ProtocolLine $HostProcess 'HOST_CHUNK_SUBMITTED ' 'DLSS5 host'
        if ($AcknowledgedChunks -eq 0) { $FirstHostChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
        $AcknowledgedChunks++
        $DoneFrames = $ChunkEndFrames[$AcknowledgedChunks - 1]
        $Span = if($VsrAfterDlss){42.0}else{85.0}; $Percent=5.0+$Span*$DoneFrames/[double]$TotalFrames
        Emit-Progress 'DLSS5' 'Draining DLSS5 and NVENC queues' $Percent $DoneFrames $TotalFrames $PrimaryPhaseWatch.Elapsed.TotalSeconds
    }
    $HostProcess.StandardInput.Close()
    Wait-ProtocolLine $HostProcess 'HOST_STREAM_DONE ' 'DLSS5 host'
    $HostProcess.WaitForExit()
    if ($HostProcess.ExitCode -ne 0) { throw "DLSS5 host failed: $($HostProcess.StandardError.ReadToEnd())" }

    $HostLog = Join-Path $Engine 'dlss5-video-host.log'
    $ReShadeLog = Join-Path $Engine 'ReShade.log'
    $HostText = Get-Content -LiteralPath $HostLog -Raw
    $ReShadeText = Get-Content -LiteralPath $ReShadeLog -Raw
    if ($HostText -notmatch "DLSS5_BATCH_OK frames=$TotalFrames" -or
        $ReShadeText -notmatch 'feature 18 created' -or
        $ReShadeText -notmatch 'inline feature 18 evaluation succeeded') {
        throw 'The renderer finished but the DLSS5 Feature 18 acceptance check failed.'
    }
    if (-not $IsPreviewOnly) {
        Copy-Item -LiteralPath $HostLog -Destination (Join-Path $LogDirectory 'persistent.host.log') -Force
        Copy-Item -LiteralPath $ReShadeLog -Destination (Join-Path $LogDirectory 'persistent.ReShade.log') -Force
    }

    if ($VsrAfterDlss -and -not $IsPreviewOnly) {
        Stage 5 8 "Starting final $Upscaler x4 pass"
        Join-EncodedChunks $HostEncodedChunkDirectory $DlssIntermediate $Chunks 'chunks-dlss.txt'
        $UpscalerArgs = @(
            '-B',$UpscalerWorker,'--server','--backend',$Upscaler.ToLowerInvariant(),
            '--variant',$UpscalerVariant.ToLowerInvariant(),
            '--model-root',$UpscalerModels,'--backend-root',$UpscalerBackends,'--third-party-root',$UpscalerThirdParty,
            '--input-width',$UpscalerInputWidth,'--input-height',$UpscalerInputHeight,
            '--output-width',$OutputWidth,'--output-height',$OutputHeight,
            '--strength',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$UpscalerStrength))
        )
        $UpscalerProcess = Start-ProtocolProcess $UpscalerPython $UpscalerArgs $Root
        Wait-ProtocolLine $UpscalerProcess 'UPSCALER_SERVER_READY ' "$Upscaler engine"
        try {
            $UpscalerReady = ($script:LastProtocolLine.Substring('UPSCALER_SERVER_READY '.Length)) | ConvertFrom-Json
            $UpscalerResolvedVariant = [string]$UpscalerReady.variant
            $UpscalerGpu = [string]$UpscalerReady.gpu
            $UpscalerLoadSeconds = [double]$UpscalerReady.load_s
        } catch {}
        $VsrPhaseWatch=[Diagnostics.Stopwatch]::StartNew()
        $Encoder = if ($Codec -eq 'H265') { 'hevc_nvenc' } else { 'h264_nvenc' }
        $CodecTag = if ($Codec -eq 'H265') { @('-tag:v','hvc1') } else { @() }
        for ($ChunkIndex=0;$ChunkIndex -lt $Chunks;$ChunkIndex++) {
            $FirstFrame=$ChunkOffsets[$ChunkIndex]
            $ThisFrames=$ChunkFrameCounts[$ChunkIndex]
            $Prefix=Join-Path $ChunkDirectory ('post-dlss-{0:D4}' -f $ChunkIndex)
            $LowRaw=$Prefix+'.lq.rgb'; $Raw=$Prefix+'.rgb'
            $Seek=[string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.######}',($FirstFrame/[double]$Fps))
            $DecodeWatch=[Diagnostics.Stopwatch]::StartNew()
            Run-Tool $Ffmpeg @('-y','-v','error','-ss',$Seek,'-i',$DlssIntermediate,'-vf',"scale=$($UpscalerInputWidth):$($UpscalerInputHeight):flags=lanczos,format=rgb24",'-frames:v',$ThisFrames,'-an','-f','rawvideo','-pix_fmt','rgb24',$LowRaw) 'DLSS intermediate decode failed'
            $DecodeWatch.Stop(); $DecoderSeconds+=$DecodeWatch.Elapsed.TotalSeconds
            $UpscalerCommand=[ordered]@{cmd='chunk';id=$ChunkIndex;input=$LowRaw;output=$Raw;frames=$ThisFrames}|ConvertTo-Json -Compress
            $UpscalerProcess.StandardInput.WriteLine($UpscalerCommand)
            Wait-ProtocolLine $UpscalerProcess 'UPSCALER_CHUNK_READY ' "$Upscaler engine"
            try{$UpscalerResult=($script:LastProtocolLine.Substring('UPSCALER_CHUNK_READY '.Length))|ConvertFrom-Json;$UpscalerSeconds+=[double]$UpscalerResult.elapsed_s;$UpscalerPeakVramMb=[math]::Max($UpscalerPeakVramMb,[int]$UpscalerResult.peak_vram_mb);$UpscalerReservedVramMb=[math]::Max($UpscalerReservedVramMb,[int]$UpscalerResult.reserved_vram_mb)}catch{}
            $FinalChunk=Join-Path $EncodedChunkDirectory ('chunk-{0:D4}.mp4' -f $ChunkIndex)
            $EncodeArgs=@('-y','-v','error','-f','rawvideo','-pix_fmt','rgb24','-s:v',"$($OutputWidth)x$($OutputHeight)",'-r',$Fps,'-i',$Raw,'-frames:v',$ThisFrames,'-an','-c:v',$Encoder,'-preset','p2','-rc','constqp','-qp',$Quality)+$CodecTag+@('-movflags','+faststart',$FinalChunk)
            Run-Tool $Ffmpeg $EncodeArgs 'Final VSR chunk encode failed'
            $DoneFrames=[math]::Min($TotalFrames,$FirstFrame+$ThisFrames)
            $Percent=47.0+43.0*$DoneFrames/[double]$TotalFrames
            Emit-Progress "$Upscaler x4" 'Final VSR x4 pass after DLSS5' $Percent $DoneFrames $TotalFrames $VsrPhaseWatch.Elapsed.TotalSeconds
        }
        $UpscalerProcess.StandardInput.WriteLine('{"cmd":"end"}')
        Wait-ProtocolLine $UpscalerProcess 'UPSCALER_SERVER_DONE' "$Upscaler engine"
        $UpscalerProcess.StandardInput.Close();$UpscalerProcess.WaitForExit()
        if($UpscalerProcess.ExitCode-ne 0){throw "$Upscaler engine failed: $($UpscalerProcess.StandardError.ReadToEnd())"}
    }

    if (-not $IsPreviewOnly) {
        Stage 6 8 'Joining encoded chunks and restoring source audio'
        Emit-Progress 'Assembly' 'Joining neural-rendered chunks' 91 $TotalFrames $TotalFrames $PipelineWatch.Elapsed.TotalSeconds
        if (-not $DirectEncode) { Join-EncodedChunks $EncodedChunkDirectory $VideoOnly $Chunks 'chunks-final.txt' }
        $StartText = [string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.######}',$StartSeconds)
        $MuxArguments = @('-y','-v','error') + $NetworkInputOptions + @(
            '-ss',$StartText,'-i',$InputVideo,'-i',$VideoOnly,
            '-map','1:v:0','-map','0:a?','-c:v','copy','-c:a','aac','-b:a','192k','-shortest','-movflags','+faststart',$FlatOutput
        )
        Run-Tool $Ffmpeg $MuxArguments 'Final audio/video mux failed'

        if ($VRMode -eq 'CinemaSBS') {
            Stage 7 8 'Creating VR cinema SBS container and stereo metadata'
            Emit-Progress 'VR' 'Creating the headset SBS container' 95 $TotalFrames $TotalFrames $PipelineWatch.Elapsed.TotalSeconds
            $Encoder = if ($Codec -eq 'H265') { 'hevc_nvenc' } else { 'h264_nvenc' }
            $CodecTag = if ($Codec -eq 'H265') { @('-tag:v','hvc1') } else { @() }
            $VrFilter = if ($VRSbsLayout -eq 'FullSBS') { '[0:v]split=2[left][right];[left][right]hstack=inputs=2[v]' } else { '[0:v]split=2[left][right];[left]scale=iw/2:ih:flags=lanczos[l];[right]scale=iw/2:ih:flags=lanczos[r];[l][r]hstack=inputs=2[v]' }
            $VrArgs=@('-y','-v','error','-i',$FlatOutput,'-filter_complex',$VrFilter,'-map','[v]','-map','0:a?','-c:v',$Encoder,'-preset','p2','-rc','constqp','-qp',$Quality)+$CodecTag+@('-c:a','copy','-metadata:s:v:0','stereo_mode=left_right','-movflags','+faststart',$VrEncoded)
            Run-Tool $Ffmpeg $VrArgs 'VR SBS encoding failed'
            Run-Tool $UpscalerPython @('-B',$SpatialMediaTool,'-i','--v2','--projection','none','--stereo','left-right',$VrEncoded,$OutputVideo) 'VR stereo metadata injection failed'
        } elseif ($VRMode -eq 'DepthSBS') {
            Stage 7 8 'Creating depth-warped stereoscopic 3D VR views'
            Emit-Progress '3D VR' 'Synthesizing distinct left/right views from neural depth' 95 $TotalFrames $TotalFrames $PipelineWatch.Elapsed.TotalSeconds
            $VrDepthVideoOnly = Join-Path $Work 'vr-depth-video-only.mp4'
            $LayoutName = if ($VRSbsLayout -eq 'FullSBS') { 'full-sbs' } else { 'half-sbs' }
            $CodecNameVr = if ($Codec -eq 'H265') { 'h265' } else { 'h264' }
            Run-Tool $UpscalerPython @(
                '-B',$VRDepthWorker,'--ffmpeg',$Ffmpeg,'--input-video',$FlatOutput,
                '--depth-directory',$ChunkDirectory,'--output-video',$VrDepthVideoOnly,
                '--width',$OutputWidth,'--height',$OutputHeight,'--frames',$TotalFrames,'--fps',$Fps,
                '--layout',$LayoutName,
                '--eye-separation',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$VREyeSeparation)),
                '--convergence',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$VRConvergence)),
                '--codec',$CodecNameVr,'--quality',$Quality
            ) 'Depth-warped VR synthesis failed'
            Run-Tool $Ffmpeg @('-y','-v','error','-i',$VrDepthVideoOnly,'-i',$FlatOutput,'-map','0:v:0','-map','1:a?','-c','copy','-shortest','-metadata:s:v:0','stereo_mode=left_right','-movflags','+faststart',$VrEncoded) 'Depth VR audio mux failed'
            Run-Tool $UpscalerPython @('-B',$SpatialMediaTool,'-i','--v2','--projection','none','--stereo','left-right',$VrEncoded,$OutputVideo) 'Depth VR metadata injection failed'
        } elseif ($VRMode -eq 'Equirect360') {
            Stage 7 8 'Injecting spherical-video v2 metadata'
            Emit-Progress 'VR 360' 'Injecting equirectangular sv3d metadata' 97 $TotalFrames $TotalFrames $PipelineWatch.Elapsed.TotalSeconds
            Run-Tool $UpscalerPython @('-B',$SpatialMediaTool,'-i','--v2','--projection','equirectangular','--stereo','none',$FlatOutput,$OutputVideo) 'VR 360 metadata injection failed'
        }
    }
    $ProcessingElapsedSeconds = $PipelineWatch.Elapsed.TotalSeconds

    $Comparison = $null
    if ($CreateComparison -and -not $IsPreviewOnly) {
        Stage 7 8 'Building the original/result comparison'
        Emit-Progress 'Comparison' 'Original left, processed flat result right' 98 $TotalFrames $TotalFrames $PipelineWatch.Elapsed.TotalSeconds
        $Comparison = [IO.Path]::Combine($OutputDirectory, [IO.Path]::GetFileNameWithoutExtension($OutputVideo) + '.comparison.mp4')
        $Encoder = if ($Codec -eq 'H265') { 'hevc_nvenc' } else { 'h264_nvenc' }
        $Tag = if ($Codec -eq 'H265') { @('-tag:v','hvc1') } else { @() }
        $Filter = "[0:v]scale=1920:1080:flags=neighbor:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[left];[1:v]scale=1920:1080:flags=lanczos:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[right];[left][right]hstack=inputs=2[v]"
        $ComparisonSource = if ($VRMode -eq 'Off') { $OutputVideo } else { $FlatOutput }
        $Args = @('-y','-v','error') + $NetworkInputOptions + @('-ss',$StartText,'-i',$InputVideo,'-i',$ComparisonSource,'-filter_complex',$Filter,'-map','[v]','-map','1:a?','-frames:v',$TotalFrames,'-c:v',$Encoder,'-preset','p2','-rc','constqp','-qp',$Quality) + $Tag + @('-c:a','copy','-movflags','+faststart',$Comparison)
        Run-Tool $Ffmpeg $Args 'Comparison render failed'
    }

    Stage 8 8 'Finalizing the result'
    Emit-Progress 'Done' 'Finalizing report and verification data' 100 $TotalFrames $TotalFrames $PipelineWatch.Elapsed.TotalSeconds
    $PipelineWatch.Stop()
    $TimingMatch = [regex]::Match($HostText, 'DLSS5_BATCH_TIMING[^\r\n]*per_frame_ms=(?<ms>[0-9.]+)')
    $MeanMs = if ($TimingMatch.Success) { [double]::Parse($TimingMatch.Groups['ms'].Value, [Globalization.CultureInfo]::InvariantCulture) } else { 0.0 }
    $TotalTimingMatch = [regex]::Match($HostText, 'DLSS5_BATCH_TIMING[^\r\n]*\stotal_ms=(?<total>[0-9.]+)')
    $EncodeTimingMatch = [regex]::Match($HostText, 'DLSS5_BATCH_TIMING[^\r\n]*\schunk_encode_ms=(?<encode>[0-9.]+)')
    $PreviewFpsMatch = [regex]::Match($HostText, 'DLSS5_BATCH_TIMING[^\r\n]*\spreview_present_fps=(?<fps>[0-9.]+)')
    $HostDeliveryFps = if ($TotalTimingMatch.Success -and $EncodeTimingMatch.Success) {
        $HostDeliveryMs = [double]::Parse($TotalTimingMatch.Groups['total'].Value, [Globalization.CultureInfo]::InvariantCulture) + [double]::Parse($EncodeTimingMatch.Groups['encode'].Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($HostDeliveryMs -gt 0) { 1000.0 * $TotalFrames / $HostDeliveryMs } else { 0.0 }
    } else { 0.0 }
    $GuideFps = if ($GuideComputeSeconds -gt 0) { $TotalFrames / $GuideComputeSeconds } else { 0.0 }
    $DecoderFps = if ($DecoderSeconds -gt 0) { $TotalFrames / $DecoderSeconds } else { 0.0 }
    $UpscalerFps = if ($UpscalerSeconds -gt 0) { $TotalFrames / $UpscalerSeconds } else { 0.0 }
    $OverlapFps = if ($HostDeliveryFps -gt 0 -and $DecoderFps -gt 0) { [math]::Min($HostDeliveryFps,$DecoderFps) } else { [math]::Max($HostDeliveryFps,$DecoderFps) }
    $SteadyFps = if ($OverlapFps -gt 0 -and $GuideFps -gt 0) { 1.0 / (1.0 / $OverlapFps + 1.0 / $GuideFps) } else { 0.0 }
    if ($UseExternalUpscaler -and $SteadyFps -gt 0 -and $UpscalerFps -gt 0) {
        $SteadyFps = 1.0 / (1.0 / $SteadyFps + 1.0 / $UpscalerFps)
    }
    $WallFps = if ($ProcessingElapsedSeconds -gt 0) { $TotalFrames / $ProcessingElapsedSeconds } else { 0.0 }
    $DisplayFps = if ($PreviewFpsMatch.Success) { [double]::Parse($PreviewFpsMatch.Groups['fps'].Value, [Globalization.CultureInfo]::InvariantCulture) } else { 0.0 }
    $Result = [ordered]@{
        schema = 'dlss5-video-studio-run/5'
        status = 'ok'
        input_video = if ($IsNetworkSource) { '[network stream]' } else { $InputVideo }
        source_kind = if ($IsNetworkSource) { 'network' } else { 'file' }
        output_video = if ($IsPreviewOnly) { $null } else { $OutputVideo }
        comparison_video = $Comparison
        recording = -not $IsPreviewOnly
        codec = if ($IsPreviewOnly) { $null } else { $Codec }
        quality = if ($IsPreviewOnly) { $null } else { $Quality }
        performance_profile = $PerformanceProfile
        hardware_profile = $ResolvedHardwareProfile
        realtime_render_preset = if($IsPreviewOnly){$ResolvedRealtimeRenderPreset}else{$null}
        upscaler = $Upscaler
        upscaler_variant = $UpscalerResolvedVariant
        upscaler_strength = [double]$UpscalerStrength
        upscaler_gpu = $UpscalerGpu
        upscaler_load_seconds = [double]$UpscalerLoadSeconds
        upscaler_peak_vram_mb = [int]$UpscalerPeakVramMb
        upscaler_reserved_vram_mb = [int]$UpscalerReservedVramMb
        upscaler_input_geometry = if ($UseExternalUpscaler) { @($UpscalerInputWidth,$UpscalerInputHeight) } else { $null }
        pipeline_order = $PipelineOrder
        pipeline_label = $PipelineLabel
        vr_mode = $VRMode
        vr_sbs_layout = if ($VRMode -in @('CinemaSBS','DepthSBS')) { $VRSbsLayout } else { $null }
        vr_eye_separation = if($VRMode-eq'DepthSBS'){$VREyeSeparation}else{$null}
        vr_convergence = if($VRMode-eq'DepthSBS'){$VRConvergence}else{$null}
        output_mode = $Mode
        depth_backend = $DepthProvider
        depth_model_profile = $DepthModelProfile
        guide_width = $GuideWidth
        depth_interval = $DepthInterval
        depth_min_interval = $DepthMinInterval
        adaptive_confidence = $AdaptiveConfidence
        adaptive_motion = $AdaptiveMotion
        temporal_depth = $TemporalDepth
        scene_cut_threshold = $SceneCutThreshold
        motion_preset = $MotionPreset
        motion_backend = if($MotionProvider){$MotionProvider}else{$RealtimeMotionBackend}
        raft_updates = if($RealtimeMotionBackend-eq'raft'){$RealtimeRaftUpdates}else{$null}
        source_geometry = @($SourceWidth,$SourceHeight)
        render_geometry = @($DlssInputWidth,$DlssInputHeight)
        dlss_output_geometry = @($DlssOutputWidth,$DlssOutputHeight)
        output_geometry = @($OutputWidth,$OutputHeight)
        container_geometry = @($ContainerWidth,$OutputHeight)
        fps = $Fps
        source_fps = $SourceRate
        realtime_fps_mode = if($IsPreviewOnly){$RealtimeFpsMode}else{$null}
        realtime_frame_generation = if($IsPreviewOnly){$RealtimeFrameGeneration}else{$null}
        start_seconds = $StartSeconds
        frames = $TotalFrames
        chunks = $Chunks
        startup_chunk_frames = [int]$ChunkFrameCounts[0]
        regular_chunk_frames = [int]$ChunkSize
        persistent_pipeline = $true
        persistent_decoder = -not $VsrBeforeDlss
        fast_start = -not $UseExternalUpscaler
        continuous_nvenc = [bool]$DirectEncode
        guide_ready_seconds = [double]$GuideReadySeconds
        host_ready_seconds = [double]$HostReadySeconds
        first_guide_chunk_seconds = [double]$FirstGuideChunkSeconds
        first_host_chunk_seconds = [double]$FirstHostChunkSeconds
        live_preview = [bool]$LivePreview
        gpu_direct_preview = [bool]$IsPreviewOnly
        realtime_buffer_seconds = if ($IsPreviewOnly) { [int]$RealtimeBufferSeconds } else { $null }
        realtime_buffer_frames = if ($IsPreviewOnly) { [int]$RealtimeBufferFrames } else { $null }
        realtime_fullscreen = [bool]($IsPreviewOnly -and $RealtimeFullscreen)
        display_fps = [double]$DisplayFps
        dlss5_ms_per_frame = [double]$MeanMs
        dlss5_fps = if ($MeanMs -gt 0) { 1000.0 / $MeanMs } else { 0.0 }
        upscaler_fps = [double]$UpscalerFps
        guide_fps = [double]$GuideFps
        guide_low_confidence_fraction = if($GuideQualityFrames-gt 0){[double]($GuideLowConfidenceWeighted/$GuideQualityFrames)}else{$null}
        guide_depth_frames = [int]$GuideDepthFrames
        guide_scene_cuts = [int]$GuideSceneCuts
        decoder_fps = [double]$DecoderFps
        host_delivery_fps = [double]$HostDeliveryFps
        estimated_steady_fps = [double]$SteadyFps
        end_to_end_fps = [double]$WallFps
        elapsed_seconds = [double]$ProcessingElapsedSeconds
        total_elapsed_seconds = [double]$PipelineWatch.Elapsed.TotalSeconds
        config = [IO.Path]::GetFullPath($ConfigPath)
        logs = $LogDirectory
        temporary_directory = if ($KeepTemporaryFiles) { $Work } else { $null }
    }
    if (-not $IsPreviewOnly) {
        $Summary = [IO.Path]::ChangeExtension($OutputVideo, '.run.json')
        [IO.File]::WriteAllText($Summary, ($Result | ConvertTo-Json -Depth 5), $Utf8NoBom)
    }
    Write-Output ('STUDIO_RESULT ' + ($Result | ConvertTo-Json -Compress -Depth 5))
} catch {
    Write-Output ('STUDIO_ERROR ' + $_.Exception.Message)
    if (-not $IsPreviewOnly -and $OutputVideo) {
        try {
            $ErrorReport = [IO.Path]::ChangeExtension($OutputVideo, '.error.log')
            $ErrorText = (Get-Date).ToString('o') + [Environment]::NewLine + $_.Exception.ToString() + [Environment]::NewLine
            [IO.File]::WriteAllText($ErrorReport,$ErrorText,$Utf8NoBom)
            Write-Output ('STUDIO_ERROR_LOG ' + $ErrorReport)
        } catch {}
    }
    throw
} finally {
    $env:PATH = $PreviousPath
    foreach ($Process in @($GuideProcess,$UpscalerProcess,$HostProcess)) {
        if ($Process -and -not $Process.HasExited) {
            try { & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null } catch {}
        }
    }
    if (-not $KeepTemporaryFiles -and (Test-Path -LiteralPath $Work)) {
        Remove-Item -LiteralPath $Work -Recurse -Force
    }
}
