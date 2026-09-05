[CmdletBinding()]
param([string]$Portable='D:/DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V20')
$ErrorActionPreference='Stop'
$Build=Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Build
$Python=Join-Path $Portable 'runtime/python/python.exe'
$Ffmpeg=Join-Path $Portable 'tools/ffmpeg.exe'
function Check([string]$File,[string[]]$Arguments){
    & $File @Arguments
    if($LASTEXITCODE-ne 0){throw "QA failed ($LASTEXITCODE): $File $($Arguments -join ' ')"}
}
& (Join-Path $Build 'scripts/Deploy-NativeVrUpdate.ps1') -TargetRoot $Portable | Out-Null
Check $Python @('-m','unittest','discover','-s','tests','-p','test_vr*.py')
Check $Python @('-m','unittest','discover','-s','tests','-p','test_iw3*.py')
Check 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File','tests/test-native-vr-ui.ps1')
Check 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File','tests/test-iw3-ui.ps1')
Check $Python @('tests/qa_vr_depth_execution.py','--root',$Portable,'--source','qa-output/v22-record-real-1440p.mp4','--model','Studio_DA3_Base','--resolution','812','--frames','6','--out','qa-output/native-vr/da3-base-depth-only-812.json')
Check $Python @('tests/qa_atlas_compare.py','--gpu','--report','qa-output/native-vr/atlas-v2-final-gpu.json')
$Common=@('--root',$Portable,'--ffmpeg',$Ffmpeg,'--input-video','qa-output/temporal-atlas-v39/person-source-uhd-portrait.mp4',
    '--depth-directory','qa-output/native-vr/person-depth','--width','2160','--height','3840','--frames','8','--fps','25',
    '--layout','full-sbs','--stereo-method','rowflow-v3','--rowflow-width','1024','--eye-separation','3','--native-depth','--native-fill','temporal-video')
Check $Python (@('qa-output/atlas-v2-baseline-20260905/vr_depth_worker.py')+$Common+@('--output-video','qa-output/native-vr/atlas-v2-reference-portrait.mp4'))
Check $Python (@('python/vr_depth_worker.py')+$Common+@('--output-video','qa-output/native-vr/atlas-v2-final-portrait.mp4'))
Check $Python @('tests/qa_atlas_compare.py','--ffmpeg',$Ffmpeg,'--left','qa-output/native-vr/atlas-v2-reference-portrait.mp4','--right','qa-output/native-vr/atlas-v2-final-portrait.mp4','--report','qa-output/native-vr/atlas-v2-portrait-equivalence.json')
$Controller=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Portable 'app/process-video.ps1'),
    '-InputVideo',(Join-Path $Build 'qa-output/v22-record-real-1440p.mp4'),'-ConfigPath',(Join-Path $Build 'qa-output/iw3-dlss-config.ini'),
    '-OutputVideo',(Join-Path $Build 'qa-output/native-vr/stream-final-1440p.mp4'),'-OutputMode','1440p','-FrameCount','96',
    '-StartSeconds','1.2','-VRMode','DepthSBS','-VRSbsLayout','FullSBS','-VRStereoMethod','RowFlowV3','-VRDepthModel','Studio_DA3_Base',
    '-VRGenerativeBackend','SourceAtlas','-VRRowFlowWidth','1024','-VRConvergenceMode','Manual','-PipelineOrder','DLSSOnly',
    '-FineGuideSettings','-ChunkFramesOverride','24')
Check 'powershell.exe' $Controller
Check $Python @('tests/qa_native_video.py','--tools',(Join-Path $Portable 'tools'),'--source','qa-output/v22-record-real-1440p.mp4','--video','qa-output/native-vr/stream-final-1440p.mp4','--start','1.2','--frames','96','--report','qa-output/native-vr/stream-final-media-check.json')
Check $Python @('tests/qa_native_video.py','--tools',(Join-Path $Portable 'tools'),'--source','qa-output/v22-record-real-1440p.mp4','--video','qa-output/native-vr/stream-bench-4k.mp4','--frames','48','--report','qa-output/native-vr/stream-4k-media-check.json')
'NATIVE_V2_QA_PASSED'
