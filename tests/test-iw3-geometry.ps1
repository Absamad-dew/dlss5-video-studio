[CmdletBinding()]
param([string]$Python='D:/DLSS5_VIDEO_STUDIO_PORTABLE_REALTIME_V20/runtime/python/python.exe')
$ErrorActionPreference='Stop'
$Repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $Repo 'app/studio.ps1') -ValidateUi
$Cases=(& $Python -s -B (Join-Path $PSScriptRoot 'iw3-geometry-matrix.py'))|ConvertFrom-Json
if($LASTEXITCODE-ne 0){throw 'Python geometry fixtures failed'}
foreach($Case in $Cases){
    $Actual=Get-Iw3Geometry $Case.width $Case.height $Case.settings $Case.mode $Case.codec
    foreach($Field in @('source_geometry','input_geometry','content_eye_geometry','eye_geometry','packed_eye_geometry','output_geometry','bounds','output_mode','layout','codec','encoder_limit','video_filter','valid','errors')){
        $A=ConvertTo-Json -InputObject $Actual.$Field -Compress
        $B=ConvertTo-Json -InputObject $Case.expected.$Field -Compress
        if($A-ne$B){throw "Geometry mismatch $Field $($Case.width)x$($Case.height) $($Case.mode) $($Case.settings.layout): $A vs $B"}
    }
}
$Window.Close()
Write-Output "IW3_GEOMETRY_PARITY_OK $($Cases.Count) cases"
