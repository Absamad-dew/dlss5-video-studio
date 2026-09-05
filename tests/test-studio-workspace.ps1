param([string]$SnapshotDirectory)
$ErrorActionPreference='Stop'
$Repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $Repo 'app/studio.ps1') -ValidateUi
$script:Checks=0
function Assert($Condition,[string]$Message){$script:Checks++;if(-not $Condition){throw $Message}}
function Test-Displayed($Node){
    # IsVisible stays false in offscreen WPF tests. Follow actual visibility
    # and tab selection instead, so clipping checks really run.
    while($Node -and $Node-ne$Window){
        if($Node -is [Windows.UIElement] -and $Node.Visibility-ne'Visible'){return $false}
        if($Node -is [Windows.Controls.TabItem] -and -not $Node.IsSelected){return $false}
        if($Node -is [Windows.Controls.Expander] -and -not $Node.IsExpanded){return $false}
        $Node=[Windows.LogicalTreeHelper]::GetParent($Node)
    }
    return $true
}
$Raw=Get-Content -LiteralPath (Join-Path $Repo 'app/studio.ps1') -Encoding UTF8 -Raw
$Catalogue=[xml]([regex]::Match($Raw,"(?s)\`$Xaml = @'\r?\n(.*?)\r?\n'@").Groups[1].Value)
foreach($Element in $Catalogue.SelectNodes('//*[@*[local-name()="Name"]]')){
    $Name=$Element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
    if($Name-eq'B'){continue}
    $Control=$Window.FindName($Name)
    Assert ($null-ne$Control) "Lost control: $Name"
    if($Element.LocalName-eq'Slider'){
        Assert ($Control.Minimum-eq[double]::Parse($Element.Minimum,$Invariant)) "Slider minimum changed: $Name"
        Assert ($Control.Maximum-eq[double]::Parse($Element.Maximum,$Invariant)) "Slider maximum changed: $Name"
    }
    if($Element.LocalName-eq'ComboBox'){
        $Tags=@($Element.ChildNodes|Where-Object LocalName -eq 'ComboBoxItem'|ForEach-Object {$_.Tag})
        if($Tags.Count){Assert (($Tags-join',')-eq(@($Control.Items|ForEach-Object {$_.Tag})-join',')) "Choice contract changed: $Name"}
    }
}
function Test-WorkspaceLayout([int]$Width,[int]$Height){
    $Visual=$Window.Content
    $Visual.Measure([Windows.Size]::new($Width,$Height));$Visual.Arrange([Windows.Rect]::new(0,0,$Width,$Height));$Visual.UpdateLayout()
    $RunOrigin=$RunButton.TranslatePoint([Windows.Point]::new(0,0),$Visual)
    Assert ($RunOrigin.X-ge 0 -and $RunOrigin.X+$RunButton.ActualWidth-le$Width+1) "Run button cropped at $Width"
    Assert ($RunOrigin.Y-ge 0 -and $RunOrigin.Y+$RunButton.ActualHeight-le$Height+1) "Run button below viewport at $Height"
    Assert ($SettingsScroll.ViewportHeight-gt 150) "Unusable settings height at $Width"
    foreach($Control in @(Get-StudioLogicalChildren $script:StudioPages[$script:StudioActivePage])){
        if(-not(Test-Displayed $Control)){continue}
        if($Control -is [Windows.Controls.ComboBox]){Assert ($Control.ActualWidth-gt 60) "Collapsed dropdown $($Control.Name)"}
        if($Control -is [Windows.Controls.Grid] -and $Control.Tag-eq'SettingRow'){
            $Slider=@($Control.Children|Where-Object {$_ -is [Windows.Controls.Slider]})[0]
            Assert ($Slider.ActualWidth-gt 90) "Unusable slider in compact row: $($Slider.Name)"
            foreach($Child in $Control.Children){
                $Point=$Child.TranslatePoint([Windows.Point]::new(0,0),$Control)
                Assert ($Point.X-ge -1 -and $Point.X+$Child.ActualWidth-le$Control.ActualWidth+1) "Clipped setting row: $($Slider.Name)"
            }
        }
    }
}
$ModeIndex=0
foreach($Mode in @('Realtime','Recording','VR','IW3')){
    $WorkspaceTabs.SelectedIndex=$ModeIndex++;Update-WorkspaceUi
    Assert ((Get-WorkspaceMode)-eq$Mode) "Mode changed unexpectedly: $Mode"
    foreach($Key in $script:StudioModePages[$Mode]){
        Show-StudioSection $Key
        foreach($Expander in @(Get-StudioLogicalChildren $script:StudioPages[$Key]|Where-Object {$_ -is [Windows.Controls.Expander]})){$Expander.IsExpanded=$true}
        Assert (@($script:StudioPages.Values|Where-Object Visibility -eq 'Visible').Count-eq 1) 'More than one settings page visible'
        Assert ($script:StudioPages[$Key].Visibility-eq'Visible') "Page did not open: $Key"
        Test-WorkspaceLayout 1040 650
        Test-WorkspaceLayout 1480 870
    }
}
# Navigation and show/hide must not alter neural values or IW3 settings.
$Before=(Get-Iw3Settings)|ConvertTo-Json -Compress
$NeuralBefore=(Current-Settings)|ConvertTo-Json -Compress
foreach($Key in @('Source','Output','IW3','Neural')){Show-StudioSection $Key}
Set-StudioReviewPane $true;Set-StudioReviewPane $false
Assert ($Before-eq((Get-Iw3Settings)|ConvertTo-Json -Compress)) 'Navigation mutated IW3 processing settings'
Assert ($NeuralBefore-eq((Current-Settings)|ConvertTo-Json -Compress)) 'Navigation mutated DLSS settings'
$WorkspaceTabs.SelectedIndex=0;Update-WorkspaceUi
Assert ($FramesBox.Parent.Visibility-eq'Collapsed') 'Realtime asks for frame count'
Assert ($CodecCombo.Parent.Visibility-eq'Collapsed') 'Realtime shows recording codec'
$SettingsSearch.Text='буфер'
Assert ($SearchResults.Items.Count-gt 0) 'Buffer is not searchable'
Open-StudioSearchResult $SearchResults.Items[0]
Assert ($script:StudioActivePage-eq'Player') 'Search navigated to wrong page'
$WorkspaceTabs.SelectedIndex=2;Update-WorkspaceUi
$SettingsSearch.Text='VRDepthGammaSlider'
Assert ($SearchResults.Items.Count-eq 1) 'Advanced stereo control missing from index'
Open-StudioSearchResult $SearchResults.Items[0]
Assert ($script:StudioActivePage-eq'Comfort') 'Advanced search does not navigate'
Assert ($VRFineStereoExpander.IsExpanded) 'Search did not expand advanced settings'
$WorkspaceTabs.SelectedIndex=3;Update-WorkspaceUi
$SettingsSearch.Text='Параллакс'
Assert ($SearchResults.Items.Count-gt 0) 'IW3 fields missing from search'
$InlineHelpCheck.IsChecked=$true;Update-StudioInlineHelp
Assert ($script:StudioHelpNodes.Count-gt 20) 'Descriptions not registered'
Assert (@($script:StudioHelpNodes|Where-Object Visibility -ne 'Visible').Count-eq 0) 'Some descriptions remain hidden'
$InlineHelpCheck.IsChecked=$false;Update-StudioInlineHelp
Assert ($HelpCard.Visibility-eq'Collapsed') 'Help switch ignored'
$SettingsSearch.Clear()
$WorkspaceTabs.SelectedIndex=0;Update-WorkspaceUi;Show-StudioSection 'Source';Test-WorkspaceLayout 1040 650
Assert ($ExpectedTimeText.Text-notmatch'IW3') 'Stale IW3 message in realtime'
Assert ([math]::Abs($InputBox.ActualHeight-$BrowseInput.ActualHeight)-le 1) 'Source buttons and field are misaligned'
Assert ($QuickScenarioCombo.ActualHeight-le 36) 'Editable combo has nested oversized padding'
Assert ($StartBox.ActualWidth-le 180) 'Numeric start field stretches across the page'
if($SnapshotDirectory){
    New-Item -ItemType Directory -Force -Path $SnapshotDirectory|Out-Null
    foreach($View in @(@(0,'Source'),@(0,'Player'),@(1,'Output'),@(2,'Comfort'),@(2,'Neural'),@(3,'IW3'))){
        $WorkspaceTabs.SelectedIndex=$View[0];Update-WorkspaceUi;Show-StudioSection $View[1];Test-WorkspaceLayout 1480 870
        $Bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1480,870,96,96,[Windows.Media.PixelFormats]::Pbgra32);$Bitmap.Render($Window.Content)
        $Encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$Encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
        $Stream=[IO.File]::Create((Join-Path $SnapshotDirectory ($View[1]+'.png')));try{$Encoder.Save($Stream)}finally{$Stream.Dispose()}
    }
}
$Window.Close()
Write-Output "STUDIO_WORKSPACE_TESTS_PASSED checks=$script:Checks indexed=$($script:StudioSearchIndex.Count)"
