# Shared by the UI, realtime controller and command-line runner. Check the
# selected model before resolving a URL, starting audio or creating GPU hosts.
function Get-DepthModelRequirements {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Profile)
    switch ($Profile) {
        'DA2Small' { 'models\depth_anything_v2_small.onnx' }
        'VideoDepthSmall' {
            'models\depth\video_depth_anything_vits.pth'
            'third_party\video-depth-anything\video_depth_anything\video_depth_stream.py'
            'third_party\video-depth-anything\video_depth_anything\dinov2.py'
            'third_party\video-depth-anything\utils\util.py'
        }
        { $_ -in @('DA3Small','DA3Base','DA3Large') } {
            $Name = @{DA3Small='da3-small';DA3Base='da3-base';DA3Large='da3-large'}[$Profile]
            "models\depth\$Name\config.json"
            "models\depth\$Name\model.safetensors"
            'third_party\depth-anything-3\src\depth_anything_3\api.py'
        }
        default { throw "Unknown depth model: $Profile" }
    }
}

function Get-DepthModelStatus {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Profile)
    $Missing = @(Get-DepthModelRequirements -Root $Root -Profile $Profile | Where-Object {
        $File = Get-Item -LiteralPath (Join-Path $Root $_) -ErrorAction SilentlyContinue
        -not $File -or $File.PSIsContainer -or $File.Length -eq 0
    })
    $Install = switch ($Profile) {
        'VideoDepthSmall' { 'INSTALL_VIDEO_DEPTH.cmd' }
        'DA3Large' { 'INSTALL_DA3_LARGE.cmd' }
        default { 'scripts\Install-DepthModels.ps1' }
    }
    [pscustomobject]@{ Profile=$Profile; Ready=($Missing.Count -eq 0); Missing=$Missing; Installer=$Install }
}

function Assert-DepthModelReady {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Profile)
    $Status = Get-DepthModelStatus -Root $Root -Profile $Profile
    if (-not $Status.Ready) {
        throw "Depth model $Profile is not fully installed. Missing: $($Status.Missing -join ', '). Run $($Status.Installer) in the program folder, or explicitly select an installed depth model."
    }
}
Export-ModuleMember -Function Get-DepthModelRequirements,Get-DepthModelStatus,Assert-DepthModelReady
