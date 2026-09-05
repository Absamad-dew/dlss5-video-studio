param([string]$SnapshotDirectory)
$ErrorActionPreference='Stop'
$Repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $Repo 'app/studio.ps1') -ValidateUi
$script:Checks=0
function Assert($Value,[string]$Message){$script:Checks++;if(-not $Value){throw $Message}}
function Values {
    $Result=[ordered]@{}
    foreach($Control in @(Get-StudioLogicalChildren $Window)){
        if(-not $Control.Name -or $Control.Name -like 'Simple*'){continue}
        if($Control -is [Windows.Controls.ComboBox]){$Result[$Control.Name]=$Control.SelectedIndex}
        elseif($Control -is [Windows.Controls.Slider]){$Result[$Control.Name]=$Control.Value}
        elseif($Control -is [Windows.Controls.CheckBox]){$Result[$Control.Name]=$Control.IsChecked}
    }
    $Result.Iw3=Get-Iw3Settings
    return $Result|ConvertTo-Json -Depth 5 -Compress
}
function Layout([int]$Width,[int]$Height){
    $Window.Content.Measure([Windows.Size]::new($Width,$Height))
    $Window.Content.Arrange([Windows.Rect]::new(0,0,$Width,$Height));$Window.Content.UpdateLayout()
}
$Modes=@('Realtime','Recording','VR','IW3');$Tiers=@('UltraFast','Fast','Medium','Heavy','Maximum')
# Pure fixture for availability: never create pretend model files or run a GPU.
function Get-StudioSimpleDepth([string]$Tier,[bool]$Stereo){
    return [pscustomobject]@{Id=$(if($Stereo){'Studio_DA3_Small'}else{'DA2Small'});Ready=$true;Preferred=$(if($Stereo){'Studio_DA3_Small'}else{'DA2Small'})}
}
function Test-VrGenerativeBackendInstalled([string]$Backend){return $false}
$script:RowFlowReady=$true
foreach($Mode in $Modes){
    $WorkspaceTabs.SelectedIndex=$Modes.IndexOf($Mode);Update-WorkspaceUi
    $Before=Values
    $SimpleModeCheck.IsChecked=$true;$SimpleModeCheck.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert ($Before-eq(Values)) "Simple toggle mutated processing: $Mode"
    Assert ((@(Get-StudioVisiblePages)-join',')-eq'Source,Simple') "Simple navigation incorrect: $Mode"
    Assert ($QuickGroup.Visibility-eq'Collapsed') 'Conflicting quick scenario is still visible'
    Show-StudioSection 'Simple'
    foreach($Width in @(1040,1480)){
        Layout $Width 760
        Assert ($SimpleProfileCombo.ActualWidth-ge 160) "Profile dropdown collapsed: $Mode / $Width"
        Assert ($ApplySimpleProfile.ActualWidth-ge 140) 'Apply button too narrow'
        Assert ([math]::Abs($ApplySimpleProfile.ActualHeight-$SimpleProfileCombo.ActualHeight)-lt 1) 'Profile row heights differ'
        Assert ($SimpleResolutionCombo.ActualWidth-ge 350) 'Main fields collapsed'
    }
    Select-StringTag $SimpleResolutionCombo '1440p'
    Assert ((Combo-Tag $ModeCombo)-eq'1440p') 'Simple resolution does not reach backend control'
    Select-StringTag $ModeCombo '1080p'
    Assert ((Combo-Tag $SimpleResolutionCombo)-eq'1080p') 'Detailed resolution does not reach simple view'
    if($Mode-in @('VR','IW3')){
        Select-StringTag $SimpleLayoutCombo 'FullOU'
        $LayoutSource=if($Mode-eq'VR'){$VrLayoutCombo}else{$Iw3Controls['layout']}
        Assert ((Combo-Tag $LayoutSource)-eq'FullOU') 'Stereo mirror does not reach backend'
        $SimpleStereoSlider.Value=1.2
        $DepthSource=if($Mode-eq'VR'){$VREyeSlider}else{$Iw3Controls['divergence']}
        Assert ([math]::Abs($DepthSource.Value-1.2)-lt 0.001) 'Stereo strength mirror incorrect'
    }
    foreach($Tier in $Tiers){
        $Before=Values;Select-StringTag $SimpleProfileCombo $Tier
        Assert ($Before-eq(Values)) "Selecting a profile applied it without confirmation: $Mode / $Tier"
        $Paths=@($InputBox.Text,$OutputBox.Text,$StartBox.Text,$FramesBox.Text,$FullVideoCheck.IsChecked,(Combo-Tag $ModeCombo),(Combo-Tag $CodecCombo)) -join '|'
        Apply-StudioGlobalProfile $Tier
        Assert ((Get-WorkspaceMode)-eq$Mode) "Profile switched workspace: $Mode / $Tier"
        Assert ((Combo-Tag $PerformanceCombo)-eq$Tier) "Performance mapping failed: $Mode / $Tier"
        Assert ((Combo-Tag $UpscalerCombo)-eq'None') 'External heavy upscaler unexpectedly enabled'
        Assert ($Paths-eq(@($InputBox.Text,$OutputBox.Text,$StartBox.Text,$FramesBox.Text,$FullVideoCheck.IsChecked,(Combo-Tag $ModeCombo),(Combo-Tag $CodecCombo)) -join '|')) "Profile changed source/output/range: $Mode / $Tier"
        Assert ($SimpleProfileStatus.Text.StartsWith('Применено:')) 'No applied profile feedback'
        if($Mode-eq'Realtime'){
            Assert ([int]$GuideWidthSlider.Value-eq$RealtimeProfiles[$Tier].guide) 'Realtime guide mapping failed'
            Assert ((Combo-Tag $RealtimeQualityCombo)-eq$Tier) 'Realtime unexpectedly marked Custom'
        }elseif($Mode-eq'VR'){
            Assert ((Combo-Tag $VRStereoMethodCombo)-eq'RowFlowV3') 'Native RowFlow not enabled'
            Assert ((Combo-Tag $VRDepthModelCombo)-eq'Studio_DA3_Small') 'Native installed depth not used'
            Assert ((Combo-Tag $VRDLSSModeCombo)-in @('PreStereo','PreAndPerEye')) 'Native VR lost DLSS'
            Assert ((Combo-Tag $VrLayoutCombo)-eq'FullOU') 'VR profile changed selected layout'
        }elseif($Mode-eq'IW3'){
            $S=Get-Iw3Settings
            Assert ($S.method-eq'row_flow_v3' -and $S.depth_model-eq'Studio_DA3_Small') 'IW3 pipeline mapping failed'
            Assert ($S.ema_normalize -and -not $S.disable_amp -and $S.da3_microbatch-eq 1) 'IW3 safety/performance settings lost'
            Assert ($S.resolution-eq@(392,392,518,644,812)[$Tiers.IndexOf($Tier)]) 'IW3 tier resolution mapping failed'
        }else{Assert (-not $RecordFineGuideCheck.IsChecked) 'Recording override hides profile values'}
    }
    $Before=Values
    $SimpleDetailsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert ($Before-eq(Values)) 'Returning to detailed mode changes quality'
    Assert (-not $SimpleModeCheck.IsChecked) 'Details button does not exit simple mode'
}
# Missing installations remain explicit, no fake success and no download.
function Get-StudioSimpleDepth([string]$Tier,[bool]$Stereo){return [pscustomobject]@{Id=$(if($Stereo){'Selected'}else{'DA2Small'});Ready=$false;Preferred='DA3Large'}}
$script:RowFlowReady=$false
$WorkspaceTabs.SelectedIndex=2;Update-WorkspaceUi;Apply-StudioGlobalProfile 'Maximum'
Assert ((Combo-Tag $VRStereoMethodCombo)-eq'GAPW') 'Missing RowFlow fallback incorrect'
Assert ($SimpleProfileStatus.Text.Contains('не установлен') -and $SimpleProfileStatus.Text.Contains('отсутствует')) 'Missing model warning lost'
$Before=Values;$script:Process=[pscustomobject]@{active=$true};$Threw=$false
try{Apply-StudioGlobalProfile 'Fast'}catch{$Threw=$true}finally{$script:Process=$null}
Assert $Threw 'Profile applied during a running job'
Assert ($Before-eq(Values)) 'Blocked apply changed settings'
# Regression for the screenshot: path row height, baseline, and intrinsic buttons.
Show-StudioSection 'Source';Layout 1040 760
Assert ([math]::Abs($OutputBox.ActualHeight-$BrowseOutput.ActualHeight)-lt 1) 'Output folder is clipped/misaligned'
Assert ([math]::Abs($OutputBox.TranslatePoint([Windows.Point]::new(0,0),$OutputBox.Parent).Y-$BrowseOutput.TranslatePoint([Windows.Point]::new(0,0),$OutputBox.Parent).Y)-lt 1) 'Output button baseline differs'
$TextHost=$OutputBox.Template.FindName('PART_ContentHost',$OutputBox)
Assert ($TextHost.Margin.Top-eq 0 -and $TextHost.Margin.Bottom-eq 0) 'TextBox padding was duplicated on content host'
Assert ($TextHost.ExtentHeight-le$TextHost.ViewportHeight+1) 'Single-line output text clips vertically'
Show-StudioSection 'Neural';Layout 1040 760
Assert ($SavePreset.Parent.ColumnDefinitions[1].Width.IsAuto) 'Save preset still in fixed column'
Assert ([math]::Abs($PresetBox.ActualHeight-$SavePreset.ActualHeight)-lt 1) 'Preset row heights differ'
if($SnapshotDirectory){
    New-Item -ItemType Directory -Force -Path $SnapshotDirectory|Out-Null
    foreach($Mode in $Modes){
        $WorkspaceTabs.SelectedIndex=$Modes.IndexOf($Mode);Update-WorkspaceUi
        $StudioSimpleModes[$Mode]=$true;Update-StudioNavigation;Show-StudioSection 'Simple';Layout 1480 870
        $Bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1480,870,96,96,[Windows.Media.PixelFormats]::Pbgra32);$Bitmap.Render($Window.Content)
        $Encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$Encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
        $Stream=[IO.File]::Create((Join-Path $SnapshotDirectory ($Mode+'.png')));try{$Encoder.Save($Stream)}finally{$Stream.Dispose()}
    }
}
$Window.Close()
Write-Output "STUDIO_SIMPLE_TESTS_PASSED checks=$script:Checks profiles=20"
