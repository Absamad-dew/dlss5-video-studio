[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $InputVideo,
    [string] $OutputVideo,
    [Parameter(Mandatory)] [string] $ConfigPath,
    [ValidateSet('H264','H265')] [string] $Codec = 'H265',
    [ValidateRange(0,51)] [int] $Quality = 18,
    [ValidateSet('Source','Same','4K','2160p','1440p','1080p','720p','540p')] [string] $OutputMode = 'Source',
    [ValidateSet('UltraFast','Fast','Medium','Heavy','Maximum')] [string] $PerformanceProfile = 'Medium',
    [ValidateSet('Auto','Standard','HighVram')] [string] $HardwareProfile = 'Auto',
    [ValidateSet('Auto','Native','Quality','Balanced','Performance')] [string] $RealtimeRenderPreset = 'Auto',
    [ValidateSet('DA2Small','VideoDepthSmall','DA3Small','DA3Base')] [string] $DepthModelProfile = 'DA2Small',
    [ValidateSet('Auto','Dml','Cpu','Cuda','TensorRT','TensorRTRTX')] [string] $DepthComputeBackend = 'Auto',
    [ValidateSet('None','NanoVSR','AnimeSR','FlashVSR','DLoRAL')] [string] $Upscaler = 'None',
    [ValidateSet('Auto','Realtime','Balanced','Quality','Max')] [string] $UpscalerVariant = 'Auto',
    [ValidateRange(0.0,1.0)] [double] $UpscalerStrength = 1.0,
    [ValidateSet('DLSSOnly','VSRThenDLSS','DLSSThenVSR')] [string] $PipelineOrder = 'VSRThenDLSS',
    [ValidateSet('Off','CinemaSBS','DepthSBS','Equirect360')] [string] $VRMode = 'Off',
    [ValidateSet('HalfSBS','FullSBS','HalfOU','FullOU')] [string] $VRSbsLayout = 'HalfSBS',
    [ValidateRange(0.1,3.0)] [double] $VREyeSeparation = 1.0,
    [ValidateRange(0.1,0.9)] [double] $VRConvergence = 0.48,
    [ValidateRange(0.25,3.0)] [double] $VRDepthGamma = 1.0,
    [ValidateRange(0.0,1.0)] [double] $VROcclusionFill = 0.65,
    [ValidateRange(0.0,24.0)] [double] $VREdgeFeather = 2.0,
    [ValidateRange(0.0,0.95)] [double] $VRTemporalSmoothing = 0.55,
    [ValidateRange(0.5,5.0)] [double] $VRMaxDisparityPercent = 2.4,
    [ValidateSet(0,72,90,120)] [int] $VRTargetFps = 0,
    [switch] $VREyeSwap,
    [double] $StartSeconds = 0,
    [int] $FrameCount = 8,
    [int] $OverrideFps = 0,
    [switch] $LivePreview,
    [switch] $PreviewOnly,
    [ValidateRange(3,30)] [int] $RealtimeBufferSeconds = 5,
    [ValidateRange(0,192)] [int] $RealtimeChunkFrames = 0,
    [string] $RealtimeControlPath,
    [switch] $RealtimeFillBufferOnPause,
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
    [ValidateSet('Source','Double','60','72','90','120')] [string] $RealtimeFpsMode = 'Source',
    [ValidateSet('Off','MotionGPU','CompatibilityBlend','NvidiaDLSSG','NvidiaDLSSGx2','NvidiaMFGx3','NvidiaMFGx4','NvidiaDynamicMFG','NvidiaOpticalFlow','Rife')] [string] $RealtimeFrameGeneration = 'Off',
    [ValidateSet(0,60,72,90,120)] [int] $RealtimeTargetFps = 0,
    [ValidateRange(0,16)] [int] $GuideWorkerThreads = 0,
    [ValidateSet(0,540,720,1080,1440,2160,4320)] [int] $NetworkMaxHeight = 2160,
    [ValidateSet('None','chrome','edge','firefox')] [string] $NetworkCookiesBrowser = 'None',
    [switch] $FineGuideSettings,
    [ValidateRange(256,1024)] [int] $GuideWidthOverride = 480,
    [ValidateRange(1,48)] [int] $DepthIntervalOverride = 2,
    [ValidateRange(1,48)] [int] $DepthMinIntervalOverride = 2,
    [ValidateRange(0.0,1.0)] [double] $AdaptiveConfidenceOverride = 0.45,
    [ValidateRange(0.0,40.0)] [double] $AdaptiveMotionOverride = 10.0,
    [ValidateRange(0.0,0.95)] [double] $TemporalDepthOverride = 0.35,
    [ValidateRange(0.03,0.35)] [double] $SceneCutThresholdOverride = 0.12,
    [ValidateSet('quality','balanced','realtime')] [string] $MotionPresetOverride = 'balanced',
    [ValidateSet('dis','raft')] [string] $MotionBackendOverride = 'dis',
    [ValidateRange(1,12)] [int] $RaftUpdatesOverride = 4,
    [ValidateRange(0,256)] [int] $ChunkFramesOverride = 0,
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
$SourceResolver = Join-Path $PSScriptRoot 'source-resolver.psm1'
$YtDlp = Join-Path $Tools 'yt-dlp.exe'

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
            if ($MemoryMiB -ge 12000) { return 'HighVram' }
        }
    } catch {}
    return 'Standard'
}

function Resolve-RealtimeRenderScale([string] $Preset, [string] $ResolvedHardware, [int] $TargetWidth, [int] $TargetHeight) {
    if ($Preset -eq 'Native') { return 1.0 }
    if ($Preset -eq 'Quality') { return 0.75 }
    if ($Preset -eq 'Balanced') { return 2.0 / 3.0 }
    if ($Preset -eq 'Performance') { return 0.5 }

    # Auto targets the available VRAM tier, without exposing GPU-specific
    # profiles. Detect 4K by
    # width as well as height so 3840x1600/1640 ultrawide sources do not fall
    # into the much heavier 1440p profile merely because they are letterboxed.
    # These are DLSS inputs, not an extra post-resize filter.
    if ($ResolvedHardware -eq 'HighVram') {
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

function Get-RealtimeAffinityPartition {
    # Partition only CPUs already available to this process. This respects
    # CoreBroker/job-object constraints in tests and the full machine mask in
    # normal launches. Guide/decode is CPU-heavy; the native host is primarily
    # a D3D12 submission thread and needs fewer, isolated logical processors.
    $AvailableMask = [uint64]([int64](Get-Process -Id $PID).ProcessorAffinity)
    $Available = New-Object 'Collections.Generic.List[int]'
    for ($Bit = 0; $Bit -lt 63; $Bit++) {
        if (($AvailableMask -band ([uint64]1 -shl $Bit)) -ne 0) { $Available.Add($Bit) }
    }
    if ($Available.Count -lt 8) { return $null }
    # Keep one complete SMT core outside both AboveNormal worker processes.
    # The Normal-priority controller owns buffer accounting and IPC; without a
    # reserved core it can remain runnable for seconds while host/guide occupy
    # every CPU, even though their GPU/compute stages are already >2x realtime.
    $ControllerCount = if ($Available.Count -ge 12) { 2 } else { 1 }
    $WorkerCount = $Available.Count-$ControllerCount
    $GuideCount = [math]::Min($WorkerCount-2,[math]::Max(4,[int][math]::Ceiling($WorkerCount*0.5625)))
    [uint64]$GuideMask = 0
    [uint64]$HostMask = 0
    [uint64]$ControllerMask = 0
    for ($Index=0;$Index -lt $WorkerCount;$Index++) {
        $Value = [uint64]1 -shl $Available[$Index]
        if ($Index -lt $GuideCount) { $GuideMask = $GuideMask -bor $Value }
        else { $HostMask = $HostMask -bor $Value }
    }
    for ($Index=$WorkerCount;$Index -lt $Available.Count;$Index++) {
        $ControllerMask = $ControllerMask -bor ([uint64]1 -shl $Available[$Index])
    }
    return [pscustomobject]@{
        GuideMask=[int64]$GuideMask;HostMask=[int64]$HostMask;ControllerMask=[int64]$ControllerMask
        GuideLogicalProcessors=$GuideCount;HostLogicalProcessors=($WorkerCount-$GuideCount)
        ControllerLogicalProcessors=$ControllerCount
    }
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

function Wait-HostChunkSubmitted($Process, $AcknowledgementCounter, [long] $ExpectedCount) {
    if (-not $AcknowledgementCounter) {
        Wait-ProtocolLine $Process 'HOST_CHUNK_SUBMITTED ' 'DLSS5 host'
        return
    }
    while ($AcknowledgementCounter.ReadInt64(0) -lt $ExpectedCount) {
        if ($Process.HasExited) {
            if ($AcknowledgementCounter.ReadInt64(0) -ge $ExpectedCount) { return }
            $Details = $Process.StandardError.ReadToEnd().Trim()
            if ($Details) { Write-Output ("DLSS5 host stderr: $Details") }
            throw 'DLSS5 host exited before acknowledging the submitted chunk'
        }
        Start-Sleep -Milliseconds 2
    }
}

$IsNetworkSource = $InputVideo -match '^https?://'
$ResolvedOnlineSource = $null
if ($IsNetworkSource -and [string]::IsNullOrWhiteSpace($InputHeadersPath)) {
    if (-not (Test-Path -LiteralPath $SourceResolver -PathType Leaf)) { throw "Required file is missing: $SourceResolver" }
    Import-Module $SourceResolver -Force
    $NetworkState = Join-Path $env:LOCALAPPDATA ('DLSS5VideoStudio\network\source-' + [Guid]::NewGuid().ToString('N') + '.headers.json')
    $ResolvedOnlineSource = Resolve-OnlineVideoSource -PageUrl $InputVideo -YtDlpPath $YtDlp `
        -MaxHeight $NetworkMaxHeight -CookiesBrowser $NetworkCookiesBrowser -HeadersPath $NetworkState
    $InputVideo = [string]$ResolvedOnlineSource.MediaUrl
    $InputHeadersPath = [string]$ResolvedOnlineSource.HeadersPath
    $InputTlsNoVerify = [bool]$ResolvedOnlineSource.TlsNoVerify
    Write-Output ('STUDIO_SOURCE_JSON ' + ([ordered]@{
        kind='network'; title=$ResolvedOnlineSource.Title; duration_seconds=$ResolvedOnlineSource.Duration
        width=$ResolvedOnlineSource.Width; height=$ResolvedOnlineSource.Height; format_id=$ResolvedOnlineSource.FormatId
        extractor=$ResolvedOnlineSource.Extractor; max_height=$NetworkMaxHeight
    } | ConvertTo-Json -Compress))
}
$RequiredFiles = @($ConfigPath,$Ffmpeg,$Ffprobe,$GuideGeneratorScript,$UpscalerPython,$VideoHost)
$RequiredDirectories = @()
if ($DepthModelProfile -in @('DA3Small','DA3Base')) { $RequiredDirectories += $DepthModel } else { $RequiredFiles += $DepthModel }
if (-not $IsNetworkSource) { $RequiredFiles += $InputVideo }
if (-not [string]::IsNullOrWhiteSpace($InputHeadersPath)) { $RequiredFiles += $InputHeadersPath }
if ($Upscaler -ne 'None') { $RequiredFiles += @($UpscalerPython,$UpscalerWorker) }
if ($PreviewOnly) { $RequiredFiles += @($UpscalerPython,$GuideGeneratorScript) }
if ($DepthModelProfile -ne 'DA2Small') {
    $RequiredFiles += @($UpscalerPython,$GuideGeneratorScript)
    $RequiredDirectories += $DepthCodeRoot
}
if (($PreviewOnly -and $RealtimeMotionBackend -eq 'raft') -or
    ($FineGuideSettings -and $MotionBackendOverride -eq 'raft') -or
    (-not $PreviewOnly -and -not $FineGuideSettings -and $PerformanceProfile -in @('Heavy','Maximum'))) {
    $RequiredFiles += $RaftWeights
}
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
$IsPreviewOnly = [bool]$PreviewOnly
$RealtimePlaybackStatePath = if ($IsPreviewOnly -and -not [string]::IsNullOrWhiteSpace($RealtimeControlPath)) {
    [IO.Path]::GetFullPath($RealtimeControlPath) + '.playback'
} else { $null }

function Wait-RealtimePlaybackGate {
    if (-not $IsPreviewOnly -or $RealtimeFillBufferOnPause -or -not $RealtimePlaybackStatePath) { return }
    while (Test-Path -LiteralPath $RealtimePlaybackStatePath -PathType Leaf) {
        $PlaybackState = ''
        try { $PlaybackState = [IO.File]::ReadAllText($RealtimePlaybackStatePath,$Utf8NoBom).Trim() } catch {}
        if ($PlaybackState -ne 'paused') { return }
        Start-Sleep -Milliseconds 25
    }
}

$UseNvidiaDlssg = $RealtimeFrameGeneration -in @('NvidiaDLSSG','NvidiaDLSSGx2','NvidiaMFGx3','NvidiaMFGx4','NvidiaDynamicMFG')
$ResolvedRealtimeTargetFps = $RealtimeTargetFps
if (-not $IsPreviewOnly -and $RealtimeFrameGeneration -ne 'Off') { throw 'Realtime frame generation is available only in display mode.' }
if ($RealtimeFrameGeneration -in @('NvidiaOpticalFlow','Rife')) {
    throw "$RealtimeFrameGeneration is not active in this build yet; use MotionGPU or CompatibilityBlend."
}
if ($UseNvidiaDlssg) {
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
    throw 'OutputVideo is required in recording mode.'
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
} elseif ($UseCompatibilityInterpolation -and $RealtimeFpsMode -in @('72','90','120')) {
    [int]$RealtimeFpsMode
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
$ResolvedGuideWorkerThreads = if ($GuideWorkerThreads -gt 0) {
    $GuideWorkerThreads
} elseif ($IsPreviewOnly) {
    # OpenCV's own workers contend with the persistent decoder, audio feeder,
    # native DLSS host and DirectML. One guide worker is faster in the live
    # pipeline on the laptop; HighVram has enough CPU/GPU headroom for two.
    if ($ResolvedHardwareProfile -eq 'HighVram') { 2 } else { 1 }
} elseif ($ResolvedHardwareProfile -eq 'HighVram') {
    [math]::Max(2,[math]::Min(8,[int][math]::Ceiling([Environment]::ProcessorCount/2.0)))
} else {
    [math]::Max(2,[math]::Min(4,[int][math]::Ceiling([Environment]::ProcessorCount/4.0)))
}
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
$DepthBackendPolicy = 'requested'
if ($IsPreviewOnly -and $DepthComputeBackend -eq 'Auto' -and
    $ResolvedHardwareProfile -eq 'Standard' -and $DlssOutputWidth -ge 2560) {
    # At 1440p the laptop DLSS queue is almost saturated. Running sparse DA2
    # depth on four isolated CPU workers avoids multi-second DirectML GPU
    # scheduling stalls while preserving the same model, input and output size.
    $DepthComputeBackend = 'Cpu'
    $DepthBackendPolicy = 'laptop-high-resolution-cpu-isolation'
}
# Preserve the complete source frame (or downscale only when it exceeds the
# DLSS render extent). The native cubic path avoids expanding every RGB frame
# in system RAM; its unaligned RGB24 reads are coalesced in the input shader.
$RgbTransportGeometry = if ($IsPreviewOnly -and -not $UseExternalUpscaler) {
    Fit-Geometry $SourceWidth $SourceHeight $DlssInputWidth $DlssInputHeight $false
} else { @($DlssInputWidth,$DlssInputHeight) }
$RgbTransportWidth = [int]$RgbTransportGeometry[0]
$RgbTransportHeight = [int]$RgbTransportGeometry[1]
if ($VRMode -eq 'Equirect360' -and [math]::Abs(($OutputWidth/[double]$OutputHeight)-2.0) -gt 0.035) {
    throw 'Equirect360 requires a 2:1 panoramic source/output (for example 3840x1920). Use CinemaSBS for ordinary flat video.'
}

$SceneCutThreshold = 0.12
switch ($PerformanceProfile) {
    { $IsPreviewOnly } {
        # Realtime gets its exact values from the dedicated player controls.
        # The universal profile remains in the report and UI, but does not
        # silently overwrite a manual/custom guide configuration.
        $GuideWidth = $RealtimeGuideWidth
        $DepthInterval = $RealtimeDepthInterval
        $DepthMinInterval = [math]::Min($RealtimeDepthMinInterval,$RealtimeDepthInterval)
        $AdaptiveConfidence = $RealtimeAdaptiveConfidence
        $AdaptiveMotion = $RealtimeAdaptiveMotion
        $TemporalDepth = $RealtimeTemporalDepth
        $SceneCutThreshold = $RealtimeSceneCutThreshold
        $MotionPreset = $RealtimeMotionPreset
        $ChunkSize = if ($RenderWidth -ge 3000) { 48 } elseif ($RenderWidth -ge 1900) { 64 } else { 96 }
        break
    }
    'Heavy' {
        $GuideWidth = 640; $DepthInterval = 1; $DepthMinInterval = 1
        $AdaptiveConfidence = 0.55; $AdaptiveMotion = 6.0; $TemporalDepth = 0.25
        $MotionPreset = 'quality'; $ChunkSize = if ($RenderWidth -ge 3000) { 32 } else { 64 }
    }
    'Maximum' {
        $GuideWidth = 768; $DepthInterval = 1; $DepthMinInterval = 1
        $AdaptiveConfidence = 0.50; $AdaptiveMotion = 5.0; $TemporalDepth = 0.20
        $MotionPreset = 'quality'; $ChunkSize = if ($RenderWidth -ge 3000) { 24 } else { 48 }
    }
    'Fast' {
        $GuideWidth = 384; $DepthInterval = 4; $DepthMinInterval = 2
        $AdaptiveConfidence = 0.58; $AdaptiveMotion = 12.0; $TemporalDepth = 0.48
        $MotionPreset = 'balanced'
        $ChunkSize = if ($RenderWidth -ge 3000) { 48 } elseif ($RenderWidth -ge 1900) { 64 } else { 96 }
    }
    'UltraFast' {
        # Real motion and neural depth stay enabled, but the guide grid and
        # depth refresh cadence are tuned for throughput. Feature 18 still
        # evaluates every full-resolution frame.
        $GuideWidth = 256; $DepthInterval = 8; $DepthMinInterval = 8
        $AdaptiveConfidence = 0.0; $AdaptiveMotion = 0.0; $TemporalDepth = 0.70
        $MotionPreset = 'realtime'
        $ChunkSize = if ($RenderWidth -ge 3000) { 48 } elseif ($RenderWidth -ge 1900) { 72 } else { 128 }
    }
    default { # Medium
        $GuideWidth = 480; $DepthInterval = 2; $DepthMinInterval = 2
        $AdaptiveConfidence = 0.45; $AdaptiveMotion = 10.0; $TemporalDepth = 0.35
        $MotionPreset = 'balanced'; $ChunkSize = if ($RenderWidth -ge 3000) { 48 } elseif ($RenderWidth -ge 1900) { 72 } else { 96 }
    }
}

# Recording and VR use the same guide engine as realtime.  Keep the convenient
# presets, but let the dedicated mode tabs replace every quality/performance
# decision without forcing the user into the realtime profile.
if ($FineGuideSettings -and -not $IsPreviewOnly) {
    $GuideWidth = $GuideWidthOverride
    $DepthInterval = $DepthIntervalOverride
    $DepthMinInterval = [math]::Min($DepthMinIntervalOverride,$DepthIntervalOverride)
    $AdaptiveConfidence = $AdaptiveConfidenceOverride
    $AdaptiveMotion = $AdaptiveMotionOverride
    $TemporalDepth = $TemporalDepthOverride
    $SceneCutThreshold = $SceneCutThresholdOverride
    $MotionPreset = $MotionPresetOverride
    if ($ChunkFramesOverride -gt 0) { $ChunkSize = $ChunkFramesOverride }
}
$SelectedMotionBackend = if ($IsPreviewOnly) {
    $RealtimeMotionBackend
} elseif ($FineGuideSettings) {
    $MotionBackendOverride
} elseif ($PerformanceProfile -in @('Heavy','Maximum')) {
    'raft'
} else {
    'dis'
}
$SelectedRaftUpdates = if ($IsPreviewOnly) {
    $RealtimeRaftUpdates
} elseif ($FineGuideSettings) {
    $RaftUpdatesOverride
} elseif ($PerformanceProfile -eq 'Maximum') {
    8
} else {
    4
}

if ($IsPreviewOnly) {
    # Refill the realtime queue several times per second. Multi-second chunks
    # made a single hard depth scene consume the entire safety margin before a
    # new command could be published, even when average processing was faster
    # than realtime. Keep automatic chunks near 0.5 s (smaller at 4K to cap
    # per-chunk RAM/SSD traffic); the expert slider can still override this.
    $HalfSecondFrames = [int][math]::Max(8,[math]::Ceiling($Fps*0.5))
    $AutoRealtimeChunk = if ($RenderWidth -ge 3000) {
        [int][math]::Min(12,$HalfSecondFrames)
    } elseif ($RenderWidth -ge 1900) {
        [int][math]::Min(16,$HalfSecondFrames)
    } else {
        [int][math]::Min(24,$HalfSecondFrames)
    }
    $ChunkSize = if ($RealtimeChunkFrames -gt 0) { $RealtimeChunkFrames } else { $AutoRealtimeChunk }
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
# A continuous NVENC pipe can contend with Feature 18 on bandwidth-limited
# systems, so keep recording and display paths isolated.
$DirectEncode = $false
if (-not $IsPreviewOnly) {
    New-Item -ItemType Directory -Force -Path $EncodedChunkDirectory | Out-Null
    if ($VsrAfterDlss) { New-Item -ItemType Directory -Force -Path $HostEncodedChunkDirectory | Out-Null }
}
$DepthCache = Join-Path (Join-Path $env:ProgramData 'DLSS5VideoStudio') 'depth-cache'
New-Item -ItemType Directory -Force -Path $DepthCache | Out-Null

$RealtimeBufferFrames = if ($IsPreviewOnly) { [int][math]::Max(1,[math]::Ceiling($Fps*$RealtimeBufferSeconds)) } else { 0 }
$StartupChunkSize = if (-not $IsPreviewOnly -and -not $UseExternalUpscaler -and $TotalFrames -gt 1) {
    if ($PerformanceProfile -eq 'UltraFast') { 2 } elseif ($PerformanceProfile -in @('Heavy','Maximum')) { 4 } else { 8 }
} else { $ChunkSize }
$ChunkFrameCounts = New-Object 'Collections.Generic.List[int]'
$RemainingFrames = $TotalFrames
if ($StartupChunkSize -lt $ChunkSize -and $RemainingFrames -gt $StartupChunkSize) {
    $ChunkFrameCounts.Add([int]$StartupChunkSize)
    $RemainingFrames -= $StartupChunkSize
}
while ($RemainingFrames -gt 0) {
    $FramesInChunk = [math]::Min($ChunkSize,$RemainingFrames)
    $ChunkFrameCounts.Add([int]$FramesInChunk)
    $RemainingFrames -= $FramesInChunk
}
$Chunks = $ChunkFrameCounts.Count
# Chunk granularity may round the selected duration upward, never downward.
# Pause-fill keeps several complete look-ahead chunks publishable. This lets the
# producer keep using CPU/GPU at full speed during startup transients and when
# playback stops between two acknowledgements. The selected duration remains
# the minimum reserve; the extra aligned look-ahead is a short safety margin.
$RealtimeCapacitySlackChunks = if ($IsPreviewOnly -and $RealtimeFillBufferOnPause) { 4 } else { 2 }
$RealtimeBufferCapacityFrames = if ($IsPreviewOnly) {
    # Align the high-water mark to a complete chunk. Otherwise (for example
    # 179 capacity with 15-frame chunks) the producer has to wait for two
    # acknowledgements before it may publish one replacement, causing a
    # needless half-second sawtooth below the selected reserve.
    $AlignedCapacity = [int]([math]::Ceiling(($RealtimeBufferFrames+$RealtimeCapacitySlackChunks*$ChunkSize)/[double]$ChunkSize)*$ChunkSize)
    [int][math]::Min($TotalFrames,$AlignedCapacity)
} else { 0 }
$RealtimeStartupBufferFrames = if ($IsPreviewOnly) {
    # Prime two already-budgeted producer look-ahead slots before playback.
    # The first depth inference submitted alongside an active DLSS queue can
    # have a multi-second one-time scheduling delay on Windows. Preparing it
    # before the media clock starts absorbs that delay without weakening depth,
    # motion or output resolution, and the normal high-water mark is preserved.
    [int][math]::Min($TotalFrames,$RealtimeBufferCapacityFrames+2*$ChunkSize)
} else { 0 }
$RealtimePrebufferChunks = if ($IsPreviewOnly) {
    [int][math]::Max(1,[math]::Min($Chunks,[math]::Ceiling($RealtimeStartupBufferFrames/[double]$ChunkSize)))
} else { 0 }
$PhysicalMemoryBytes = try {
    [long](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
} catch { 16GB }
$SharedTransportBudgetBytes = [long][math]::Min([double]6GB,[math]::Max([double]1GB,[double]$PhysicalMemoryBytes*0.25))
$SharedRgbPlannedBytes = if ($IsPreviewOnly) {
    [long]($RealtimeBufferCapacityFrames+2*$ChunkSize)*[long]$RgbTransportWidth*[long]$RgbTransportHeight*3L
} else { 0L }
$SharedGuideTile = [int][math]::Max(1,[math]::Ceiling($DlssInputWidth/[double][math]::Max(64,$GuideWidth)))
$SharedGuideWidth = [int][math]::Ceiling($DlssInputWidth/[double]$SharedGuideTile)
$SharedGuideHeight = [int][math]::Ceiling($DlssInputHeight/[double]$SharedGuideTile)
$SharedGuidePlannedBytes = if ($IsPreviewOnly) {
    # Six packed motion bytes plus one FP16 depth value per guide pixel.
    [long]($RealtimeBufferCapacityFrames+2*$ChunkSize)*[long]$SharedGuideWidth*[long]$SharedGuideHeight*8L
} else { 0L }
$SharedTransportPlannedBytes = $SharedRgbPlannedBytes + $SharedGuidePlannedBytes
# Pagefile-backed named mappings remove both RGB and compact motion/depth from
# the SSD path. Keep a strict RAM/commit budget so long buffers fall back to
# files instead of pressuring the machine.
$UseSharedRgbTransport = $IsPreviewOnly -and -not $VsrBeforeDlss -and `
    $SharedTransportPlannedBytes -gt 0 -and $SharedTransportPlannedBytes -le $SharedTransportBudgetBytes
$UseSharedGuideTransport = $UseSharedRgbTransport
$SharedRgbNamePrefix = 'd5rgb_' + (($RunId -replace '[^A-Za-z0-9_-]','_'))
$SharedGuideNamePrefix = 'd5guide_' + (($RunId -replace '[^A-Za-z0-9_-]','_'))
$RealtimeChunkAckMapName = if ($IsPreviewOnly) {
    'Local\DLSS5VideoStudioChunkAckMap_' + (($RunId -replace '[^A-Za-z0-9_-]','_'))
} else { $null }
$RealtimeChunkAckMap = $null
$RealtimeChunkAckCounter = $null
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
$GuideDepthComputeSeconds = 0.0
$GuideDepthWaitSeconds = 0.0
$GuideDepthOverlapSeconds = 0.0
$GuideDepthPrefetchDiscards = 0
$GuideDepthPrefetchHits = 0
$DecoderSeconds = 0.0
$UpscalerSeconds = 0.0
$UpscalerResolvedVariant = $null
$UpscalerGpu = $null
$UpscalerLoadSeconds = 0.0
$UpscalerPeakVramMb = 0
$UpscalerReservedVramMb = 0
$DepthProvider = 'unknown'
$MotionProvider = $null
$RealtimeAffinityPartition = if ($IsPreviewOnly) { Get-RealtimeAffinityPartition } else { $null }
$RealtimeHostOpenMpThreads = if ($RealtimeAffinityPartition) {
    [int][math]::Min(8,$RealtimeAffinityPartition.HostLogicalProcessors)
} else { 0 }
$PreviousControllerAffinity = [int64](Get-Process -Id $PID).ProcessorAffinity
$PreviousControllerPriority = (Get-Process -Id $PID).PriorityClass
$PipelineLabel = switch ($PipelineOrder) { 'DLSSThenVSR' { "DLSS5 -> $Upscaler" } 'VSRThenDLSS' { "$Upscaler -> DLSS5" } default { 'DLSS5' } }
$ContainerWidth = if ($VRMode -in @('CinemaSBS','DepthSBS') -and $VRSbsLayout -eq 'FullSBS') { $OutputWidth*2 } else { $OutputWidth }
$ContainerHeight = if ($VRMode -in @('CinemaSBS','DepthSBS') -and $VRSbsLayout -eq 'FullOU') { $OutputHeight*2 } else { $OutputHeight }
$Plan = [ordered]@{
    source_geometry=@($SourceWidth,$SourceHeight); output_geometry=@($OutputWidth,$OutputHeight)
    render_geometry=@($DlssInputWidth,$DlssInputHeight); hardware_profile=$ResolvedHardwareProfile
    rgb_transport_geometry=@($RgbTransportWidth,$RgbTransportHeight)
    realtime_render_preset=if($IsPreviewOnly){$ResolvedRealtimeRenderPreset}else{$null}
    depth_model_profile=$DepthModelProfile
    depth_backend_policy=$DepthBackendPolicy
    container_geometry=@($ContainerWidth,$ContainerHeight); source_fps=$SourceRate; fps=$Fps
    duration_seconds=$Duration; total_frames=$TotalFrames; pipeline_order=$PipelineOrder
    pipeline_label=$PipelineLabel; vr_mode=$VRMode; vr_layout=$VRSbsLayout
    vr_eye_separation=if($VRMode-eq'DepthSBS'){$VREyeSeparation}else{$null}
    vr_convergence=if($VRMode-eq'DepthSBS'){$VRConvergence}else{$null}
    vr_depth_gamma=if($VRMode-eq'DepthSBS'){$VRDepthGamma}else{$null}
    vr_occlusion_fill=if($VRMode-eq'DepthSBS'){$VROcclusionFill}else{$null}
    vr_edge_feather=if($VRMode-eq'DepthSBS'){$VREdgeFeather}else{$null}
    vr_temporal_smoothing=if($VRMode-eq'DepthSBS'){$VRTemporalSmoothing}else{$null}
    vr_max_disparity_percent=if($VRMode-eq'DepthSBS'){$VRMaxDisparityPercent}else{$null}
    vr_target_fps=if($VRMode-ne'Off' -and $VRTargetFps-gt 0){$VRTargetFps}else{$null}
    vr_eye_swap=if($VRMode-eq'DepthSBS'){[bool]$VREyeSwap}else{$null}
    realtime_buffer_seconds=if($IsPreviewOnly){$RealtimeBufferSeconds}else{$null}
    realtime_buffer_frames=if($IsPreviewOnly){$RealtimeBufferFrames}else{$null}
    realtime_startup_buffer_frames=if($IsPreviewOnly){$RealtimeStartupBufferFrames}else{$null}
    realtime_buffer_capacity_frames=if($IsPreviewOnly){$RealtimeBufferCapacityFrames}else{$null}
    realtime_chunk_frames=if($IsPreviewOnly){$ChunkSize}else{$null}
    realtime_prebuffer_chunks=if($IsPreviewOnly){$RealtimePrebufferChunks}else{$null}
    realtime_fill_buffer_on_pause=if($IsPreviewOnly){[bool]$RealtimeFillBufferOnPause}else{$null}
    realtime_rgb_transport=if($IsPreviewOnly){if($UseSharedRgbTransport){'shared-memory'}else{'ssd-file'}}else{$null}
    realtime_guide_transport=if($IsPreviewOnly){if($UseSharedGuideTransport){'shared-memory'}else{'ssd-file'}}else{$null}
    realtime_ack_transport=if($IsPreviewOnly){'shared-monotonic-counter'}else{$null}
    realtime_host_openmp_threads=if($IsPreviewOnly -and $RealtimeAffinityPartition){$RealtimeHostOpenMpThreads}else{$null}
    realtime_shared_rgb_planned_mb=if($IsPreviewOnly){[math]::Round($SharedRgbPlannedBytes/1MB,1)}else{$null}
    realtime_shared_guide_planned_mb=if($IsPreviewOnly){[math]::Round($SharedGuidePlannedBytes/1MB,1)}else{$null}
    realtime_cpu_partition=if($RealtimeAffinityPartition){[ordered]@{
        guide_logical_processors=$RealtimeAffinityPartition.GuideLogicalProcessors
        host_logical_processors=$RealtimeAffinityPartition.HostLogicalProcessors
        controller_reserved_logical_processors=$RealtimeAffinityPartition.ControllerLogicalProcessors
    }}else{$null}
    source_kind=if($IsNetworkSource){'network'}else{'file'}
    source_page=if($ResolvedOnlineSource){$ResolvedOnlineSource.PageUrl}else{$null}
    fine_guide_settings=[bool]$FineGuideSettings
    recording_quality=if(-not $IsPreviewOnly){[ordered]@{
        guide_width=$GuideWidth; depth_interval=$DepthInterval; depth_min_interval=$DepthMinInterval
        adaptive_confidence=$AdaptiveConfidence; adaptive_motion=$AdaptiveMotion
        temporal_depth=$TemporalDepth; scene_cut_threshold=$SceneCutThreshold
        motion_preset=$MotionPreset; motion_backend=$SelectedMotionBackend; raft_updates=$SelectedRaftUpdates
        chunk_frames=$ChunkSize
    }}else{$null}
    realtime_quality=if($IsPreviewOnly){[ordered]@{
        guide_width=$GuideWidth; depth_interval=$DepthInterval; depth_min_interval=$DepthMinInterval
        adaptive_confidence=$AdaptiveConfidence; adaptive_motion=$AdaptiveMotion
        temporal_depth=$TemporalDepth; scene_cut_threshold=$SceneCutThreshold; motion_preset=$MotionPreset
        motion_backend=$SelectedMotionBackend; raft_updates=$SelectedRaftUpdates
        fps_mode=$RealtimeFpsMode
        frame_generation=$RealtimeFrameGeneration
        target_fps=if($UseNvidiaDlssg){$ResolvedRealtimeTargetFps}else{$null}
        guide_worker_threads=$ResolvedGuideWorkerThreads
    }}else{$null}
}
Write-Output ('STUDIO_PLAN '+($Plan|ConvertTo-Json -Compress -Depth 4))
Emit-Progress 'Setup' 'Preparing engines and temporary workspace' 1 0 $TotalFrames 0

try {
    if ($IsPreviewOnly) {
        $RealtimeChunkAckMap = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew(
            $RealtimeChunkAckMapName, 4096, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
        $RealtimeChunkAckCounter = $RealtimeChunkAckMap.CreateViewAccessor(
            0, 8, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
        $RealtimeChunkAckCounter.Write(0,[long]0)
    }
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
        ShowPresetTransitionMessage = '0'
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
        '--server','--width',$DlssInputWidth,'--height',$DlssInputHeight,
        '--input-width',$RgbTransportWidth,'--input-height',$RgbTransportHeight,'--depth-model',$DepthModel,
        '--depth-engine',$DepthEngine,'--depth-backend',($DepthComputeBackend.ToLowerInvariant().Replace('tensorrtrtx','tensorrt-rtx')),'--cache-dir',$DepthCache,'--guide-width',$GuideWidth,
        '--depth-interval',$DepthInterval,'--depth-min-interval',$DepthMinInterval,
        '--depth-prefetch-mode',$(if($IsPreviewOnly){'synchronous'}else{'threaded'}),
        '--motion-preset',$MotionPreset,
        '--motion-backend',$SelectedMotionBackend,
        '--scene-cut-threshold',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$SceneCutThreshold)),'--adaptive-confidence',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$AdaptiveConfidence)),
        '--adaptive-motion',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$AdaptiveMotion)),
        '--temporal-depth',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$TemporalDepth))
    )
    if ($DepthCodeRoot) { $GuideArgs += @('--depth-code-root',$DepthCodeRoot) }
    if ($SelectedMotionBackend -eq 'raft') {
        $RaftBatchSize = if ($ResolvedHardwareProfile -eq 'HighVram') { 8 } else { 4 }
        $GuideArgs += @('--raft-weights',$RaftWeights,'--raft-updates',$SelectedRaftUpdates,'--raft-batch-size',$RaftBatchSize)
    }
    $GuideArgs += @('--opencv-threads',$ResolvedGuideWorkerThreads)
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
        $HostArgs += @('--chunk-ack-map',$RealtimeChunkAckMapName)
        if ($RealtimeControlPath) {
            $ResolvedControlPath = [IO.Path]::GetFullPath($RealtimeControlPath)
            $HostArgs += @('--control-file',$ResolvedControlPath,'--telemetry-file',($ResolvedControlPath + '.telemetry'))
        }
        if ($RealtimeFullscreen) { $HostArgs += '--fullscreen' }
        if ($RealtimeFrameGeneration -eq 'MotionGPU') { $HostArgs += '--frame-generation-motion' }
        if ($UseNvidiaDlssg) {
            $GeneratedFrames = switch ($RealtimeFrameGeneration) {
                'NvidiaMFGx3' { 2 }
                'NvidiaMFGx4' { 3 }
                default { 1 }
            }
            $HostArgs += @('--frame-generation-nvidia','--dlssg-generated-frames',$GeneratedFrames)
            if ($RealtimeFrameGeneration -eq 'NvidiaDynamicMFG') {
                $HostArgs += @('--dlssg-dynamic','--dlssg-dynamic-target',$ResolvedRealtimeTargetFps)
            }
        }
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
    # One current runtime serves realtime, recording and VR.  -s is essential
    # in portable builds: otherwise a user's global onnxruntime package can
    # shadow bundled DirectML and silently move depth inference to the CPU.
    # Keeping the old frozen exe here also
    # made offline mode reject newer motion/depth controls.
    $GuideProcess = Start-ProtocolProcess $UpscalerPython (@('-s','-B',$GuideGeneratorScript)+$GuideArgs) $Root
    if ($IsPreviewOnly) {
        # FFmpeg is spawned by this process and inherits its class. Matching the
        # native preview host prevents high-resolution rendering from starving
        # decode/motion/depth for a whole display chunk.
        try { $GuideProcess.PriorityClass = [Diagnostics.ProcessPriorityClass]::AboveNormal } catch {}
        if ($RealtimeAffinityPartition) {
            try { $GuideProcess.ProcessorAffinity = [intptr]$RealtimeAffinityPartition.GuideMask } catch {}
        }
    }
    if ($VsrBeforeDlss) {
        $UpscalerArgs = @(
            '-s','-B',$UpscalerWorker,'--server','--backend',$Upscaler.ToLowerInvariant(),
            '--variant',$UpscalerVariant.ToLowerInvariant(),
            '--model-root',$UpscalerModels,'--backend-root',$UpscalerBackends,'--third-party-root',$UpscalerThirdParty,
            '--input-width',$UpscalerInputWidth,'--input-height',$UpscalerInputHeight,
            '--output-width',$OutputWidth,'--output-height',$OutputHeight,
            '--strength',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$UpscalerStrength))
        )
        $UpscalerProcess = Start-ProtocolProcess $UpscalerPython $UpscalerArgs $Root
    }
    $PreviousOmpThreads = $env:OMP_NUM_THREADS
    $PreviousOmpWaitPolicy = $env:OMP_WAIT_POLICY
    try {
        if ($IsPreviewOnly -and $RealtimeAffinityPartition) {
            # A bounded, passive OpenMP pool prevents the native upload helpers
            # from spin-waiting across every CPU while D3D12 is presenting.
            $env:OMP_NUM_THREADS = [string]$RealtimeHostOpenMpThreads
            $env:OMP_WAIT_POLICY = 'PASSIVE'
        }
        $HostProcess = Start-ProtocolProcess $VideoHost $HostArgs $Engine
    } finally {
        $env:OMP_NUM_THREADS = $PreviousOmpThreads
        $env:OMP_WAIT_POLICY = $PreviousOmpWaitPolicy
    }
    if ($RealtimeAffinityPartition) {
        try { $HostProcess.ProcessorAffinity = [intptr]$RealtimeAffinityPartition.HostMask } catch {}
        try { (Get-Process -Id $PID).ProcessorAffinity = [intptr]$RealtimeAffinityPartition.ControllerMask } catch {}
        # Buffer control does almost no compute, but it must wake within a few
        # milliseconds even when the two AboveNormal worker processes saturate
        # a CoreBroker/job-object CPU set that cannot be narrowed by affinity.
        try { (Get-Process -Id $PID).PriorityClass = [Diagnostics.ProcessPriorityClass]::High } catch {}
    }
    Wait-ProtocolLine $GuideProcess 'GUIDE_SERVER_READY ' 'Guide engine'
    $GuideReadySeconds = $PipelineWatch.Elapsed.TotalSeconds
    try {
        $GuideReady = (($script:LastProtocolLine.Substring('GUIDE_SERVER_READY '.Length)) | ConvertFrom-Json)
        $DepthProvider = $GuideReady.provider
        $MotionProvider = $GuideReady.motion_provider
    } catch {}
    if ($IsPreviewOnly -and $DepthComputeBackend -eq 'Auto' -and $DepthModelProfile -eq 'DA2Small' -and $DepthProvider -match 'CPUExecutionProvider') {
        throw 'Realtime depth fell back to CPU. The bundled DirectML runtime was shadowed or could not initialize; portable Python is now launched with -s, so reinstall/update this package instead of accepting a stuttering fallback.'
    }
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

    function Release-SharedChunk([int] $ReleasedChunkIndex) {
        $References = New-Object 'Collections.Generic.List[string]'
        if ($UseSharedRgbTransport) {
            $References.Add(('shm://{0}_{1:D5}' -f $SharedRgbNamePrefix,$ReleasedChunkIndex))
        }
        if ($UseSharedGuideTransport) {
            $References.Add(('shm://{0}_{1:D5}_motion' -f $SharedGuideNamePrefix,$ReleasedChunkIndex))
            $References.Add(('shm://{0}_{1:D5}_depth' -f $SharedGuideNamePrefix,$ReleasedChunkIndex))
        }
        if ($References.Count -eq 0) { return }
        $ReleaseCommand = [ordered]@{cmd='release';inputs=@($References)} | ConvertTo-Json -Compress
        $GuideProcess.StandardInput.WriteLine($ReleaseCommand)
        $GuideProcess.StandardInput.Flush()
        if (-not $IsPreviewOnly) {
            Wait-ProtocolLine $GuideProcess 'GUIDE_RELEASED ' 'Guide shared-memory release'
        }
    }

    Stage 3 8 $(if ($VsrBeforeDlss) { "$Upscaler x4 -> DLSS5" } elseif ($VsrAfterDlss) { "DLSS5 at model input resolution -> $Upscaler x4" } else { "DLSS5 with adaptive motion/depth ($PerformanceProfile)" })
    $AcknowledgedChunks = 0
    $SentChunks = 0
    $AcknowledgedFrames = 0
    $SentFrames = 0
    $StartupPreparedFrames = 0
    $StartupHostCommands = New-Object 'Collections.Generic.List[object]'
    $PrimaryPhaseWatch = [Diagnostics.Stopwatch]::StartNew()
    if ($VsrBeforeDlss) {
        for ($ChunkIndex = 0; $ChunkIndex -lt $Chunks; $ChunkIndex++) {
            Wait-RealtimePlaybackGate
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
                $GuideDepthComputeSeconds += [double]$GuideResult.depth_infer_s
                $GuideDepthWaitSeconds += [double]$GuideResult.depth_wait_s
                $GuideDepthOverlapSeconds += [double]$GuideResult.depth_overlap_s
                $GuideDepthPrefetchDiscards += [int]$GuideResult.depth_prefetch_discarded
                $GuideDepthPrefetchHits += [int]$GuideResult.depth_prefetch_hits
            } catch {}

            $HostCommand = "CHUNK`t$ChunkIndex`t$ThisFrames`t$Raw`t$Motion`t$Depth`t$RgbTransportWidth`t$RgbTransportHeight"
            if ($IsPreviewOnly -and $SentChunks -eq 0) {
                $StartupHostCommands.Add([pscustomobject]@{Command=$HostCommand;Frames=[int]$ThisFrames})
                $StartupPreparedFrames += $ThisFrames
                if ($StartupPreparedFrames -ge $RealtimeStartupBufferFrames -or $ChunkIndex -eq $Chunks - 1) {
                    foreach ($ReadyChunk in $StartupHostCommands) {
                        $HostProcess.StandardInput.WriteLine($ReadyChunk.Command)
                        $SentChunks++;$SentFrames += [int]$ReadyChunk.Frames
                    }
                    $ReadySeconds=[math]::Round($SentFrames/[double]$Fps,3)
                    Write-Output ('STUDIO_REALTIME_BUFFER_READY_JSON '+([ordered]@{
                        ready_frames=$SentFrames;ready_seconds=$ReadySeconds;sent_frames=$SentFrames
                        target_frames=$RealtimeBufferFrames;capacity_frames=$RealtimeBufferCapacityFrames
                        target_seconds=$RealtimeBufferSeconds;source_fps=$Fps;chunk_frames=$ChunkSize;chunks=$SentChunks
                        producer_elapsed_seconds=[math]::Round($PrimaryPhaseWatch.Elapsed.TotalSeconds,6)
                        fill_on_pause=[bool]$RealtimeFillBufferOnPause
                    }|ConvertTo-Json -Compress))
                }
            } elseif ($IsPreviewOnly) {
                while (($SentFrames-$AcknowledgedFrames+$ThisFrames) -gt $RealtimeBufferCapacityFrames) {
                    Wait-HostChunkSubmitted $HostProcess $RealtimeChunkAckCounter ($AcknowledgedChunks+1)
                    if ($AcknowledgedChunks -eq 0) { $FirstHostChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
                    $AcknowledgedFrames += [int]$ChunkFrameCounts[$AcknowledgedChunks]
                    $AcknowledgedChunks++
                }
                Wait-RealtimePlaybackGate
                $HostProcess.StandardInput.WriteLine($HostCommand)
                $SentChunks++;$SentFrames += $ThisFrames
                $ReadyFrames=[math]::Max(0,$SentFrames-$AcknowledgedFrames)
                $ReadySeconds=[math]::Round($ReadyFrames/[double]$Fps,3)
                Write-Output ('STUDIO_REALTIME_BUFFER_LEVEL '+([ordered]@{
                    ready_frames=$ReadyFrames;ready_seconds=$ReadySeconds;sent_frames=$SentFrames
                    target_frames=$RealtimeBufferFrames;capacity_frames=$RealtimeBufferCapacityFrames
                    target_seconds=$RealtimeBufferSeconds;source_fps=$Fps;fill_on_pause=[bool]$RealtimeFillBufferOnPause
                    producer_elapsed_seconds=[math]::Round($PrimaryPhaseWatch.Elapsed.TotalSeconds,6)
                }|ConvertTo-Json -Compress))
            } else {
                $HostProcess.StandardInput.WriteLine($HostCommand)
                $SentChunks++;$SentFrames += $ThisFrames
                Wait-HostChunkSubmitted $HostProcess $RealtimeChunkAckCounter ($AcknowledgedChunks+1)
                if ($AcknowledgedChunks -eq 0) { $FirstHostChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
                $AcknowledgedFrames += [int]$ThisFrames
                $AcknowledgedChunks++
            }
            $DoneFrames = if($IsPreviewOnly){$AcknowledgedFrames}else{[math]::Min($TotalFrames, $FirstFrame + $ThisFrames)}
            $Percent = 5.0 + 85.0*$DoneFrames/[double]$TotalFrames
            $ProgressMessage = if($IsPreviewOnly){"Buffer $([math]::Round(($SentFrames-$AcknowledgedFrames)/[double]$Fps,2))/$RealtimeBufferSeconds s"}else{'VSR restoration, motion/depth guides and DLSS5'}
            Emit-Progress "$Upscaler -> DLSS5" $ProgressMessage $Percent $DoneFrames $TotalFrames $PrimaryPhaseWatch.Elapsed.TotalSeconds
        }
        $UpscalerProcess.StandardInput.WriteLine('{"cmd":"end"}')
        Wait-ProtocolLine $UpscalerProcess 'UPSCALER_SERVER_DONE' "$Upscaler engine"
        $UpscalerProcess.StandardInput.Close()
        $UpscalerProcess.WaitForExit()
        if ($UpscalerProcess.ExitCode -ne 0) { throw "$Upscaler engine failed: $($UpscalerProcess.StandardError.ReadToEnd())" }
    } else {
    for ($ChunkIndex = 0; $ChunkIndex -lt $Chunks; $ChunkIndex++) {
        Wait-RealtimePlaybackGate
        $FirstFrame = $ChunkOffsets[$ChunkIndex]
        $ThisFrames = $ChunkFrameCounts[$ChunkIndex]
        $Prefix = Join-Path $ChunkDirectory ('chunk-{0:D4}' -f $ChunkIndex)
        $RawStorage = $Prefix + '.rgb'
        $Raw = if ($UseSharedRgbTransport) {
            'shm://{0}_{1:D5}' -f $SharedRgbNamePrefix,$ChunkIndex
        } else { $RawStorage }
        $Motion = if ($UseSharedGuideTransport) {
            'shm://{0}_{1:D5}_motion' -f $SharedGuideNamePrefix,$ChunkIndex
        } else { $Prefix + '.motion' }
        $Depth = if ($UseSharedGuideTransport) {
            'shm://{0}_{1:D5}_depth' -f $SharedGuideNamePrefix,$ChunkIndex
        } else { $Prefix + '.depth' }
        $CommandData = [ordered]@{
            id=$ChunkIndex; input=$Raw; frames=$ThisFrames; first_frame=$FirstFrame
            motion_output=$Motion; depth_output=$Depth
        }
        $PrefetchData = $null
        if ($ChunkIndex + 1 -lt $Chunks) {
            $NextPrefix = Join-Path $ChunkDirectory ('chunk-{0:D4}' -f ($ChunkIndex + 1))
            $PrefetchData = [ordered]@{
                input=if($UseSharedRgbTransport){'shm://{0}_{1:D5}' -f $SharedRgbNamePrefix,($ChunkIndex+1)}else{($NextPrefix+'.rgb')}
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
                Wait-HostChunkSubmitted $HostProcess $RealtimeChunkAckCounter ($AcknowledgedChunks+1)
                if ($AcknowledgedChunks -eq 0) { $FirstHostChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
                $AcknowledgedFrames += [int]$ChunkFrameCounts[$AcknowledgedChunks]
                $AcknowledgedChunks++
                Release-SharedChunk ($AcknowledgedChunks-1)
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
            $GuideDepthComputeSeconds += [double]$GuideResult.depth_infer_s
            $GuideDepthWaitSeconds += [double]$GuideResult.depth_wait_s
            $GuideDepthOverlapSeconds += [double]$GuideResult.depth_overlap_s
            $GuideDepthPrefetchDiscards += [int]$GuideResult.depth_prefetch_discarded
            $GuideDepthPrefetchHits += [int]$GuideResult.depth_prefetch_hits
            if ($ChunkIndex -eq 0) {
                if ($null -ne $GuideResult.decode_s) {
                    $DecoderSeconds += [double]$GuideResult.decode_s
                } else {
                    $DecoderSeconds += [math]::Max(0.0, $GuideChunkWatch.Elapsed.TotalSeconds - [double]$GuideResult.elapsed_s)
                }
            }
        } catch {}

        $HostCommand = "CHUNK`t$ChunkIndex`t$ThisFrames`t$Raw`t$Motion`t$Depth`t$RgbTransportWidth`t$RgbTransportHeight"
        if ($IsPreviewOnly -and $SentChunks -eq 0) {
            # Do not start on a chunk count approximation: accumulate the exact
            # number of fully decoded RGB+motion+depth frames selected by the
            # user, then publish them as one ready queue to the native consumer.
            $StartupHostCommands.Add([pscustomobject]@{Command=$HostCommand;Frames=[int]$ThisFrames})
            $StartupPreparedFrames += $ThisFrames
            if ($StartupPreparedFrames -ge $RealtimeStartupBufferFrames -or $ChunkIndex -eq $Chunks - 1) {
                foreach ($ReadyChunk in $StartupHostCommands) {
                    $HostProcess.StandardInput.WriteLine($ReadyChunk.Command)
                    $SentChunks++
                    $SentFrames += [int]$ReadyChunk.Frames
                }
                $HostProcess.StandardInput.Flush()
                $ReadySeconds=[math]::Round($SentFrames/[double]$Fps,3)
                Write-Output ('STUDIO_REALTIME_BUFFER_READY_JSON '+([ordered]@{
                    ready_frames=$SentFrames;ready_seconds=$ReadySeconds;sent_frames=$SentFrames
                    target_frames=$RealtimeBufferFrames;capacity_frames=$RealtimeBufferCapacityFrames
                    target_seconds=$RealtimeBufferSeconds;source_fps=$Fps;chunk_frames=$ChunkSize;chunks=$SentChunks
                    producer_elapsed_seconds=[math]::Round($PrimaryPhaseWatch.Elapsed.TotalSeconds,6)
                    fill_on_pause=[bool]$RealtimeFillBufferOnPause
                }|ConvertTo-Json -Compress))
            }
        } elseif ($IsPreviewOnly) {
            # Acknowledgements arrive only after every frame of a chunk was
            # displayed. Maintain the selected high-water mark in exact frames,
            # not in coarse chunk counts, for a constant prepared-time reserve.
            $ReleasedAfterPublish = New-Object 'Collections.Generic.List[int]'
            $LastAckElapsedSeconds = $null
            while (($SentFrames-$AcknowledgedFrames+$ThisFrames) -gt $RealtimeBufferCapacityFrames) {
                Wait-HostChunkSubmitted $HostProcess $RealtimeChunkAckCounter ($AcknowledgedChunks+1)
                $LastAckElapsedSeconds = $PrimaryPhaseWatch.Elapsed.TotalSeconds
                if ($AcknowledgedChunks -eq 0) { $FirstHostChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
                $AcknowledgedFrames += [int]$ChunkFrameCounts[$AcknowledgedChunks]
                $AcknowledgedChunks++
                $ReleasedAfterPublish.Add($AcknowledgedChunks-1)
                $DoneFrames = $ChunkEndFrames[$AcknowledgedChunks - 1]
                $Percent = 5.0 + 85.0*$DoneFrames/[double]$TotalFrames
            }
            Wait-RealtimePlaybackGate
            # Publish first: the native player may already be at a chunk
            # boundary. Releasing the retired Python mappings is independent
            # and must not add a protocol round-trip to the display critical
            # path. The newly published chunk uses different named mappings.
            $HostProcess.StandardInput.WriteLine($HostCommand)
            $HostProcess.StandardInput.Flush()
            $PublishedElapsedSeconds = $PrimaryPhaseWatch.Elapsed.TotalSeconds
            $SentChunks++
            $SentFrames += $ThisFrames
            foreach ($ReleasedChunk in $ReleasedAfterPublish) { Release-SharedChunk $ReleasedChunk }
            $ReadyFrames=[math]::Max(0,$SentFrames-$AcknowledgedFrames)
            $ReadySeconds=[math]::Round($ReadyFrames/[double]$Fps,3)
            $DoneFrames=$AcknowledgedFrames
            $Percent = 5.0 + 85.0*$DoneFrames/[double]$TotalFrames
            Write-Output ('STUDIO_REALTIME_BUFFER_LEVEL '+([ordered]@{
                ready_frames=$ReadyFrames;ready_seconds=$ReadySeconds;sent_frames=$SentFrames
                target_frames=$RealtimeBufferFrames;capacity_frames=$RealtimeBufferCapacityFrames
                target_seconds=$RealtimeBufferSeconds;source_fps=$Fps;fill_on_pause=[bool]$RealtimeFillBufferOnPause
                producer_elapsed_seconds=[math]::Round($PrimaryPhaseWatch.Elapsed.TotalSeconds,6)
                ack_elapsed_seconds=if($null-ne$LastAckElapsedSeconds){[math]::Round($LastAckElapsedSeconds,6)}else{$null}
                publish_elapsed_seconds=[math]::Round($PublishedElapsedSeconds,6)
                release_mode='asynchronous'
            }|ConvertTo-Json -Compress))
            Emit-Progress 'DLSS5' "Realtime buffer $ReadySeconds/$RealtimeBufferSeconds s" $Percent $DoneFrames $TotalFrames $PrimaryPhaseWatch.Elapsed.TotalSeconds
        } else {
            $HostProcess.StandardInput.WriteLine($HostCommand)
            $HostProcess.StandardInput.Flush()
            $SentChunks++
            $SentFrames += $ThisFrames
        }
    }
    }

    if (-not $UseSharedRgbTransport) {
        $GuideProcess.StandardInput.WriteLine('{"cmd":"end"}')
        Wait-ProtocolLine $GuideProcess 'GUIDE_SERVER_DONE' 'Guide engine'
        $GuideProcess.StandardInput.Close()
        $GuideProcess.WaitForExit()
        if ($GuideProcess.ExitCode -ne 0) { throw "Guide engine failed: $($GuideProcess.StandardError.ReadToEnd())" }
    }

    Stage 4 8 $(if ($IsPreviewOnly) { 'Displaying the remaining DLSS5 frames' } elseif ($DirectEncode) { 'Draining the DLSS5 GPU pipeline and continuous NVENC stream' } else { 'Draining the DLSS5 GPU pipeline and NVENC encoder' })
    while ($AcknowledgedChunks -lt $Chunks) {
        Wait-HostChunkSubmitted $HostProcess $RealtimeChunkAckCounter ($AcknowledgedChunks+1)
        if ($AcknowledgedChunks -eq 0) { $FirstHostChunkSeconds = $PipelineWatch.Elapsed.TotalSeconds }
        $AcknowledgedFrames += [int]$ChunkFrameCounts[$AcknowledgedChunks]
        $AcknowledgedChunks++
        Release-SharedChunk ($AcknowledgedChunks-1)
        $DoneFrames = $ChunkEndFrames[$AcknowledgedChunks - 1]
        $Span = if($VsrAfterDlss){42.0}else{85.0}; $Percent=5.0+$Span*$DoneFrames/[double]$TotalFrames
        Emit-Progress 'DLSS5' 'Draining DLSS5 and NVENC queues' $Percent $DoneFrames $TotalFrames $PrimaryPhaseWatch.Elapsed.TotalSeconds
    }
    if ($UseSharedRgbTransport) {
        $GuideProcess.StandardInput.WriteLine('{"cmd":"end"}')
        Wait-ProtocolLine $GuideProcess 'GUIDE_SERVER_DONE' 'Guide engine'
        $GuideProcess.StandardInput.Close()
        $GuideProcess.WaitForExit()
        if ($GuideProcess.ExitCode -ne 0) { throw "Guide engine failed: $($GuideProcess.StandardError.ReadToEnd())" }
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
            '-s','-B',$UpscalerWorker,'--server','--backend',$Upscaler.ToLowerInvariant(),
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
            $VrFilter = switch ($VRSbsLayout) {
                'FullSBS' { '[0:v]split=2[left][right];[left][right]hstack=inputs=2[v]' }
                'HalfOU' { '[0:v]split=2[left][right];[left]scale=iw:ih/2:flags=lanczos[l];[right]scale=iw:ih/2:flags=lanczos[r];[l][r]vstack=inputs=2[v]' }
                'FullOU' { '[0:v]split=2[left][right];[left][right]vstack=inputs=2[v]' }
                default { '[0:v]split=2[left][right];[left]scale=iw/2:ih:flags=lanczos[l];[right]scale=iw/2:ih:flags=lanczos[r];[l][r]hstack=inputs=2[v]' }
            }
            $StereoMetadata = if ($VRSbsLayout -in @('HalfOU','FullOU')) { 'top_bottom' } else { 'left_right' }
            $SpatialStereo = if ($VRSbsLayout -in @('HalfOU','FullOU')) { 'top-bottom' } else { 'left-right' }
            $VrArgs=@('-y','-v','error','-i',$FlatOutput,'-filter_complex',$VrFilter,'-map','[v]','-map','0:a?','-c:v',$Encoder,'-preset','p2','-rc','constqp','-qp',$Quality)+$CodecTag+@('-c:a','copy','-metadata:s:v:0',"stereo_mode=$StereoMetadata",'-movflags','+faststart',$VrEncoded)
            Run-Tool $Ffmpeg $VrArgs 'VR SBS encoding failed'
            $VrMetadataInput = $VrEncoded
            if ($VRTargetFps -gt 0) {
                $VrRateEncoded = Join-Path $Work 'vr-target-fps.mp4'
                $VrRateFilter = "minterpolate=fps=$($VRTargetFps):mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1"
                Run-Tool $Ffmpeg (@('-y','-v','error','-i',$VrEncoded,'-vf',$VrRateFilter,'-map','0:v:0','-map','0:a?','-c:v',$Encoder,'-preset','p2','-rc','constqp','-qp',$Quality)+$CodecTag+@('-c:a','copy','-shortest','-metadata:s:v:0',"stereo_mode=$StereoMetadata",'-movflags','+faststart',$VrRateEncoded)) 'VR target frame-rate synthesis failed'
                $VrMetadataInput = $VrRateEncoded
            }
            Run-Tool $UpscalerPython @('-s','-B',$SpatialMediaTool,'-i','--v2','--projection','none','--stereo',$SpatialStereo,$VrMetadataInput,$OutputVideo) 'VR stereo metadata injection failed'
        } elseif ($VRMode -eq 'DepthSBS') {
            Stage 7 8 'Creating depth-warped stereoscopic 3D VR views'
            Emit-Progress '3D VR' 'Synthesizing distinct left/right views from neural depth' 95 $TotalFrames $TotalFrames $PipelineWatch.Elapsed.TotalSeconds
            $VrDepthVideoOnly = Join-Path $Work 'vr-depth-video-only.mp4'
            $LayoutName = switch ($VRSbsLayout) { 'FullSBS' {'full-sbs'} 'HalfOU' {'half-ou'} 'FullOU' {'full-ou'} default {'half-sbs'} }
            $CodecNameVr = if ($Codec -eq 'H265') { 'h265' } else { 'h264' }
            $VrDepthArgs = @(
                '-s','-B',$VRDepthWorker,'--ffmpeg',$Ffmpeg,'--input-video',$FlatOutput,
                '--depth-directory',$ChunkDirectory,'--output-video',$VrDepthVideoOnly,
                '--width',$OutputWidth,'--height',$OutputHeight,'--frames',$TotalFrames,'--fps',$Fps,
                '--layout',$LayoutName,
                '--eye-separation',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$VREyeSeparation)),
                '--convergence',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$VRConvergence)),
                '--depth-gamma',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$VRDepthGamma)),
                '--occlusion-fill',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$VROcclusionFill)),
                '--edge-feather',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$VREdgeFeather)),
                '--temporal-smoothing',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$VRTemporalSmoothing)),
                '--max-disparity-percent',([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.###}',$VRMaxDisparityPercent)),
                '--codec',$CodecNameVr,'--quality',$Quality
            )
            if ($VREyeSwap) { $VrDepthArgs += '--eye-swap' }
            Run-Tool $UpscalerPython $VrDepthArgs 'Depth-warped VR synthesis failed'
            $StereoMetadata = if ($VRSbsLayout -in @('HalfOU','FullOU')) { 'top_bottom' } else { 'left_right' }
            $SpatialStereo = if ($VRSbsLayout -in @('HalfOU','FullOU')) { 'top-bottom' } else { 'left-right' }
            Run-Tool $Ffmpeg @('-y','-v','error','-i',$VrDepthVideoOnly,'-i',$FlatOutput,'-map','0:v:0','-map','1:a?','-c','copy','-shortest','-metadata:s:v:0',"stereo_mode=$StereoMetadata",'-movflags','+faststart',$VrEncoded) 'Depth VR audio mux failed'
            $VrMetadataInput = $VrEncoded
            if ($VRTargetFps -gt 0) {
                $VrRateEncoded = Join-Path $Work 'vr-target-fps.mp4'
                $Encoder = if ($Codec -eq 'H265') { 'hevc_nvenc' } else { 'h264_nvenc' }
                $CodecTag = if ($Codec -eq 'H265') { @('-tag:v','hvc1') } else { @() }
                $VrRateFilter = "minterpolate=fps=$($VRTargetFps):mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1"
                Run-Tool $Ffmpeg (@('-y','-v','error','-i',$VrEncoded,'-vf',$VrRateFilter,'-map','0:v:0','-map','0:a?','-c:v',$Encoder,'-preset','p2','-rc','constqp','-qp',$Quality)+$CodecTag+@('-c:a','copy','-shortest','-metadata:s:v:0',"stereo_mode=$StereoMetadata",'-movflags','+faststart',$VrRateEncoded)) 'Depth VR target frame-rate synthesis failed'
                $VrMetadataInput = $VrRateEncoded
            }
            Run-Tool $UpscalerPython @('-s','-B',$SpatialMediaTool,'-i','--v2','--projection','none','--stereo',$SpatialStereo,$VrMetadataInput,$OutputVideo) 'Depth VR metadata injection failed'
        } elseif ($VRMode -eq 'Equirect360') {
            Stage 7 8 'Injecting spherical-video v2 metadata'
            Emit-Progress 'VR 360' 'Injecting equirectangular sv3d metadata' 97 $TotalFrames $TotalFrames $PipelineWatch.Elapsed.TotalSeconds
            $VrMetadataInput = $FlatOutput
            if ($VRTargetFps -gt 0) {
                $VrRateEncoded = Join-Path $Work 'vr-target-fps.mp4'
                $Encoder = if ($Codec -eq 'H265') { 'hevc_nvenc' } else { 'h264_nvenc' }
                $CodecTag = if ($Codec -eq 'H265') { @('-tag:v','hvc1') } else { @() }
                $VrRateFilter = "minterpolate=fps=$($VRTargetFps):mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1"
                Run-Tool $Ffmpeg (@('-y','-v','error','-i',$FlatOutput,'-vf',$VrRateFilter,'-map','0:v:0','-map','0:a?','-c:v',$Encoder,'-preset','p2','-rc','constqp','-qp',$Quality)+$CodecTag+@('-c:a','copy','-shortest','-movflags','+faststart',$VrRateEncoded)) 'VR 360 target frame-rate synthesis failed'
                $VrMetadataInput = $VrRateEncoded
            }
            Run-Tool $UpscalerPython @('-s','-B',$SpatialMediaTool,'-i','--v2','--projection','equirectangular','--stereo','none',$VrMetadataInput,$OutputVideo) 'VR 360 metadata injection failed'
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
    $MfgStatsMatch = [regex]::Match($HostText, '(?:HOST_DLSSG_STATS real_frames=|\[streamline\] aggregate real=)(?<real>[0-9]+) presented=(?<presented>[0-9]+) generated=(?<generated>[0-9]+) (?:actual_)?multiplier=(?<multiplier>[0-9.]+) max_per_render=(?<max>[0-9]+)')
    $UnderrunMatch = [regex]::Match($HostText, 'DLSS5_BATCH_TIMING[^\r\n]*\sbuffer_underruns=(?<count>[0-9]+)')
    $MaxStreamWaitMatch = [regex]::Match($HostText, 'DLSS5_BATCH_TIMING[^\r\n]*\sbuffer_underrun_max_ms=(?<ms>[0-9.]+)')
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
        schema = 'dlss5-video-studio-run/7'
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
        vr_depth_gamma = if($VRMode-eq'DepthSBS'){$VRDepthGamma}else{$null}
        vr_occlusion_fill = if($VRMode-eq'DepthSBS'){$VROcclusionFill}else{$null}
        vr_edge_feather = if($VRMode-eq'DepthSBS'){$VREdgeFeather}else{$null}
        vr_temporal_smoothing = if($VRMode-eq'DepthSBS'){$VRTemporalSmoothing}else{$null}
        vr_max_disparity_percent = if($VRMode-eq'DepthSBS'){$VRMaxDisparityPercent}else{$null}
        vr_target_fps = if($VRMode-ne'Off' -and $VRTargetFps-gt 0){$VRTargetFps}else{$null}
        vr_eye_swap = if($VRMode-eq'DepthSBS'){[bool]$VREyeSwap}else{$null}
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
        motion_backend = if($MotionProvider){$MotionProvider}else{$SelectedMotionBackend}
        raft_updates = if($SelectedMotionBackend-eq'raft'){$SelectedRaftUpdates}else{$null}
        realtime_chunk_frames = if($IsPreviewOnly){$ChunkSize}else{$null}
        realtime_prebuffer_chunks = if($IsPreviewOnly){$RealtimePrebufferChunks}else{$null}
        realtime_buffer_underruns = if($IsPreviewOnly -and $UnderrunMatch.Success){[int]$UnderrunMatch.Groups['count'].Value}else{$null}
        realtime_max_chunk_wait_ms = if($IsPreviewOnly -and $MaxStreamWaitMatch.Success){[math]::Round([double]::Parse($MaxStreamWaitMatch.Groups['ms'].Value,[Globalization.CultureInfo]::InvariantCulture),3)}else{$null}
        source_geometry = @($SourceWidth,$SourceHeight)
        render_geometry = @($DlssInputWidth,$DlssInputHeight)
        rgb_transport_geometry = @($RgbTransportWidth,$RgbTransportHeight)
        dlss_output_geometry = @($DlssOutputWidth,$DlssOutputHeight)
        output_geometry = @($OutputWidth,$OutputHeight)
        container_geometry = @($ContainerWidth,$ContainerHeight)
        fps = $Fps
        source_fps = $SourceRate
        realtime_fps_mode = if($IsPreviewOnly){$RealtimeFpsMode}else{$null}
        realtime_frame_generation = if($IsPreviewOnly){$RealtimeFrameGeneration}else{$null}
        realtime_target_fps = if($IsPreviewOnly -and $UseNvidiaDlssg){$ResolvedRealtimeTargetFps}else{$null}
        mfg_presented_frames = if($MfgStatsMatch.Success){[long]$MfgStatsMatch.Groups['presented'].Value}else{$null}
        mfg_generated_frames = if($MfgStatsMatch.Success){[long]$MfgStatsMatch.Groups['generated'].Value}else{$null}
        mfg_actual_multiplier = if($MfgStatsMatch.Success){[double]::Parse($MfgStatsMatch.Groups['multiplier'].Value,[Globalization.CultureInfo]::InvariantCulture)}else{$null}
        mfg_max_presented_per_render = if($MfgStatsMatch.Success){[int]$MfgStatsMatch.Groups['max'].Value}else{$null}
        mfg_actually_generated = if($MfgStatsMatch.Success){[long]$MfgStatsMatch.Groups['generated'].Value -gt 0}else{$null}
        guide_worker_threads = [int]$ResolvedGuideWorkerThreads
        start_seconds = $StartSeconds
        frames = $TotalFrames
        chunks = $Chunks
        startup_chunk_frames = [int]$ChunkFrameCounts[0]
        regular_chunk_frames = [int]$ChunkSize
        persistent_pipeline = $true
        persistent_decoder = -not $VsrBeforeDlss
        rgb_transport = if($UseSharedRgbTransport){'shared-memory'}else{'ssd-file'}
        guide_transport = if($UseSharedGuideTransport){'shared-memory'}else{'ssd-file'}
        shared_rgb_planned_mb = if($IsPreviewOnly){[math]::Round($SharedRgbPlannedBytes/1MB,1)}else{0.0}
        shared_guide_planned_mb = if($IsPreviewOnly){[math]::Round($SharedGuidePlannedBytes/1MB,1)}else{0.0}
        gpu_compact_guide_expansion = $true
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
        guide_depth_compute_seconds = [double]$GuideDepthComputeSeconds
        guide_depth_wait_seconds = [double]$GuideDepthWaitSeconds
        guide_depth_overlap_seconds = [double]$GuideDepthOverlapSeconds
        guide_depth_prefetch_discards = [int]$GuideDepthPrefetchDiscards
        guide_depth_prefetch_hits = [int]$GuideDepthPrefetchHits
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
    try { (Get-Process -Id $PID).PriorityClass = $PreviousControllerPriority } catch {}
    try { (Get-Process -Id $PID).ProcessorAffinity = [intptr]$PreviousControllerAffinity } catch {}
    $env:PATH = $PreviousPath
    foreach ($Process in @($GuideProcess,$UpscalerProcess,$HostProcess)) {
        if ($Process -and -not $Process.HasExited) {
            try { & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null } catch {}
        }
    }
    if ($RealtimeChunkAckCounter) { try { $RealtimeChunkAckCounter.Dispose() } catch {} }
    if ($RealtimeChunkAckMap) { try { $RealtimeChunkAckMap.Dispose() } catch {} }
    if (-not $KeepTemporaryFiles -and (Test-Path -LiteralPath $Work)) {
        Remove-Item -LiteralPath $Work -Recurse -Force
    }
    if (-not $KeepTemporaryFiles -and $ResolvedOnlineSource -and $ResolvedOnlineSource.HeadersPath -and
        (Test-Path -LiteralPath $ResolvedOnlineSource.HeadersPath -PathType Leaf)) {
        Remove-Item -LiteralPath $ResolvedOnlineSource.HeadersPath -Force
    }
}
