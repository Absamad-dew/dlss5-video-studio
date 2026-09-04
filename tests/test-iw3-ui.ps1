[CmdletBinding()]
param([string]$StudioRoot,[string]$OutputConfigPath,[string]$ScreenshotPath)
$ErrorActionPreference='Stop'
if(-not $StudioRoot){$StudioRoot=Split-Path -Parent $PSScriptRoot}
. (Join-Path $StudioRoot 'app/studio.ps1') -ValidateUi
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$ExpertCheck.IsChecked=$false
$WorkspaceTabs.SelectedIndex=2
Update-WorkspaceUi
Assert ($NeuralGroup.Visibility -eq 'Visible') 'VR DLSS controls are hidden'
Assert ($NeuralGroup.IsEnabled) 'VR DLSS controls are disabled'
$VrModeCombo.SelectedIndex=1
Select-StringTag $VRGenerativeBackendCombo 'Off'
$StereoExpectations=[ordered]@{
    GAPW=@('РЕКОМЕНДАЦИЯ ДЛЯ КАЧЕСТВА','Temporal Atlas')
    TemporalLDI=@('МНОГОСЛОЙНЫЙ КЛАССИЧЕСКИЙ ПУТЬ','Moebius')
    Layered=@('БАЛАНС БЕЗ ГЕНЕРАТИВНОЙ МОДЕЛИ','z-buffer')
    Inverse=@('МАКСИМАЛЬНАЯ СКОРОСТЬ','backward/inverse warp')
}
foreach($Method in $StereoExpectations.Keys){
    Select-StringTag $VRStereoMethodCombo $Method
    Update-VrUi
    foreach($Fragment in $StereoExpectations[$Method]){Assert ($VRStereoMethodInfo.Text.Contains($Fragment)) ("Stereo explanation missing for $Method`: $Fragment")}
    Assert (-not [string]::IsNullOrWhiteSpace([string]$VRStereoMethodCombo.SelectedItem.ToolTip)) ("Stereo option tooltip missing: $Method")
}
Select-StringTag $VRStereoMethodCombo 'GAPW'
$IntensitySlider.Value=.45;$StructureSlider.Value=1.35;$SkinSlider.Value=.25
$Ini=Get-Ini
Assert ($Ini.Contains('NRIntensity=0.45')) 'Intensity not forwarded to DLSS'
Assert ($Ini.Contains('NRLocalStructure=1.35')) 'Environment not forwarded to DLSS'
Assert ($Ini.Contains('NRSkinStructure=0.25')) 'Character not forwarded to DLSS'
if($OutputConfigPath){[IO.File]::WriteAllText($OutputConfigPath,$Ini,[Text.UTF8Encoding]::new($false))}
$WorkspaceTabs.SelectedIndex=3
Set-Iw3Settings @{}
Update-WorkspaceUi
Assert ($Iw3Group.Visibility -eq 'Visible') 'Separate iw3 panel not visible'
Assert ($VrGroup.Visibility -eq 'Collapsed') 'Studio VR corrections leaked into iw3 panel'
Assert (-not $NeuralGroup.IsEnabled) 'DLSS unexpectedly enabled for reference mode'
Set-Iw3Settings @{dlss_mode='PreStereo';divergence=0;scene_detect=$false;method='mlbw_l2_inpaint'}
Update-Iw3Ui
Assert ($NeuralGroup.IsEnabled) 'Optional iw3 DLSS controls not enabled'
Assert ($Iw3HelpBlocks['method'].Text.Contains('12-кадровая видеомодель')) 'Selected IW3 stereo method explanation missing'
Assert (-not [string]::IsNullOrWhiteSpace([string]$Iw3Controls['method'].SelectedItem.ToolTip)) 'IW3 method option tooltip missing'
$Saved=Get-Iw3Settings
Assert ($Saved.divergence -eq 0 -and -not $Saved.scene_detect) 'Zero/false settings lost'
Assert ($Iw3Controls['mask_outer_dilation'].IsEnabled) 'Inpaint mask controls inaccessible'
foreach($Model in $Iw3Da3Catalog.models){
    Set-Iw3Settings @{depth_model=$Model.id}
    Update-Iw3Ui
    Assert ((Get-Iw3Settings).depth_model -eq $Model.id) ('DA3 selection lost: '+$Model.id)
    Assert ($Iw3Da3InstallButton.IsEnabled) ('DA3 installer inaccessible: '+$Model.id)
    Assert ($Iw3Controls['da3_microbatch'].IsEnabled) 'DA3 microbatch inaccessible'
    Assert ($Iw3Controls['da3_sky_strength'].IsEnabled -eq ($Model.id -eq 'Any_V3_Mono')) 'Sky mask exposed for unsupported DA3'
    Assert ($Iw3Controls['depth_aa'].IsEnabled -eq ($Model.id -eq 'Any_V3_Mono')) 'Untrained DepthAA exposed for DA3 Main'
    Assert ($Iw3Da3Status.Text.Contains($Model.name)) 'DA3 model details missing'
}
Set-Iw3Settings @{depth_model='Any_V2_S'};Update-Iw3Ui
Assert (-not $Iw3Controls['da3_microbatch'].IsEnabled) 'DA3 controls enabled for V2'
Assert (-not $Iw3Da3InstallButton.IsEnabled) 'DA3 installer enabled for non-DA3'
$InputBox.Text='geometry-test.mp4'
$script:SourceInfo=[pscustomobject]@{input=$InputBox.Text;width=3840;height=1632;fps=25;duration=12}
Select-StringTag $ModeCombo '2160p';Select-StringTag $CodecCombo 'H265'
Update-Iw3Geometry
Assert ($Iw3GeometryInfo.Text.Contains('7680×1632')) '4K SBS geometry not visible'
$Iw3Controls['ipd_offset'].Value=10
Assert ($Iw3GeometryInfo.Text.Contains('8192×8192')) 'IPD limit warning not refreshed'
$Iw3Controls['ipd_offset'].Value=0
Select-StringTag $CodecCombo 'H264'
Assert ($Iw3GeometryInfo.Text.Contains('4096×4096')) 'Codec geometry warning not refreshed'
Select-StringTag $CodecCombo 'H265'
$InputBox.Text='another-video.mp4'
Assert (-not $Iw3GeometryInfo.Text.Contains('7680×1632')) 'Stale geometry shown for another source'
$InputBox.Text='geometry-test.mp4'
Update-Iw3Geometry
if($ScreenshotPath){
    $WorkspaceTabs.SelectedIndex=2
    Select-StringTag $VrModeCombo 'DepthSBS'
    Select-StringTag $VRGenerativeBackendCombo 'Off'
    Select-StringTag $VRStereoMethodCombo 'GAPW'
    $VRFineStereoExpander.IsExpanded=$true
    Update-WorkspaceUi
    $Visual=$Window.Content
    $Visual.Measure([Windows.Size]::new(1500,1000));$Visual.Arrange([Windows.Rect]::new(0,0,1500,1000));$Visual.UpdateLayout()
    $VRStereoMethodInfo.BringIntoView();$Visual.UpdateLayout()
    $Bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1500,1000,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $Bitmap.Render($Visual)
    $Encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$Encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $Stream=[IO.File]::Create($ScreenshotPath);try{$Encoder.Save($Stream)}finally{$Stream.Dispose()}
}
$WorkspaceTabs.SelectedIndex=2
Update-WorkspaceUi
Assert ($NeuralGroup.IsEnabled -and $NeuralGroup.Visibility -eq 'Visible') 'Returning to VR hides DLSS controls'
$Window.Close()
Write-Output 'IW3_UI_TESTS_PASSED'
