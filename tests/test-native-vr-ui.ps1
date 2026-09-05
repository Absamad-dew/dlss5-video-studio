$ErrorActionPreference='Stop'
$Repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $Repo 'app/studio.ps1') -ValidateUi
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Test-VrGenerativeBackendInstalled([string]$Backend){return $true}
$script:RowFlowReady=$true
$WorkspaceTabs.SelectedIndex=2
Select-StringTag $VrModeCombo 'DepthSBS'
Select-StringTag $VRGenerativeBackendCombo 'TemporalVideo'
Update-VrUi
Assert ((Combo-Tag $VRStereoMethodCombo)-eq'RowFlowV3') 'Native fill must select RowFlow'
Assert ((Combo-Tag $VRQualityPipelineCombo)-eq'Native') 'Native fill must use raw-depth pipeline'
Select-StringTag $VRGeometryModeCombo 'IW3';Update-VrUi
Assert (-not $VRDepthGammaSlider.IsEnabled) 'Unused gamma should be disabled'
Assert (-not $VRGenerativeChunkSlider.IsEnabled) 'Original network window must not be misrepresented'
Assert ($VREyeAnchorCombo.IsEnabled) 'Native must allow either eye anchor'
Select-StringTag $VRGeometryModeCombo 'Studio';Update-VrUi
Assert ($VRDepthGammaSlider.IsEnabled) 'Studio corrections must remain available'
Select-StringTag $VRDepthModelCombo 'Selected';Update-VrUi
Assert (-not $VRDepthResolutionCombo.IsEnabled) 'Dedicated DA3 resolution must not affect common model'
Select-StringTag $VRDepthModelCombo 'Any_V3_Mono';Update-VrUi
Assert ($VRDepthResolutionCombo.IsEnabled) 'DA3 input resolution control missing'
$Before=(Get-Iw3Settings)|ConvertTo-Json -Compress
Select-StringTag $VRDepthResolutionCombo '812'
Select-StringTag $VRGeometryModeCombo 'IW3'
Select-StringTag $VRPipelineSchedulingCombo 'Serial'
Assert ((Combo-Tag $VRPipelineSchedulingCombo)-eq'Serial') 'Serial compatibility path missing'
Assert ($VRPipelineSchedulingCombo.IsEnabled) 'Native stream control disabled'
Assert (((Get-Iw3Settings)|ConvertTo-Json -Compress)-eq$Before) 'Studio controls changed separate IW3 settings'
'NATIVE_VR_UI_TESTS_PASSED'
