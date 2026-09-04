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
$Saved=Get-Iw3Settings
Assert ($Saved.divergence -eq 0 -and -not $Saved.scene_detect) 'Zero/false settings lost'
Assert ($Iw3Controls['mask_outer_dilation'].IsEnabled) 'Inpaint mask controls inaccessible'
if($ScreenshotPath){
    $Visual=$Window.Content
    $Visual.Measure([Windows.Size]::new(1500,1000));$Visual.Arrange([Windows.Rect]::new(0,0,1500,1000));$Visual.UpdateLayout()
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
