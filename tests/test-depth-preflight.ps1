$ErrorActionPreference = 'Stop'
$Build = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Build 'app\depth-models.psm1') -Force
$Lab = Join-Path $Build ('temp\depth-preflight-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Lab -Force | Out-Null
$Checks = 0
foreach ($Profile in @('DA2Small','VideoDepthSmall','DA3Small','DA3Base','DA3Large')) {
    $ModelRoot = Join-Path $Lab $Profile
    New-Item -ItemType Directory -Path $ModelRoot | Out-Null
    if ((Get-DepthModelStatus $ModelRoot $Profile).Ready) { throw "Missing $Profile accepted" }
    foreach ($Relative in @(Get-DepthModelRequirements $ModelRoot $Profile)) {
        $Path = Join-Path $ModelRoot $Relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        [IO.File]::WriteAllText($Path,'fixture')
    }
    Assert-DepthModelReady $ModelRoot $Profile
    # Empty files and missing implementation files must not pass as installed.
    [IO.File]::WriteAllText($Path,'')
    if ((Get-DepthModelStatus $ModelRoot $Profile).Ready) { throw "Empty $Profile file accepted" }
    $Checks += 3
}
$App = New-Item -ItemType Directory -Path (Join-Path $Lab 'app')
Copy-Item -LiteralPath (Join-Path $Build 'app\depth-models.psm1'),(Join-Path $Build 'app\realtime-player.ps1'),(Join-Path $Build 'app\process-video.ps1') -Destination $App.FullName
foreach ($Profile in @('Medium','Maximum')) {
    # Nonexistent config/video/ffprobe are deliberate. Depth preflight must
    # happen before network access, audio startup and native initialization.
    $ErrorActionPreference = 'Continue' # Expected native stderr, not a test failure.
    $Output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'realtime-player.ps1') `
        -Runner missing -InputVideo 'https://invalid.example/video' -ConfigPath missing -ControlPath (Join-Path $Lab 'control.txt') `
        -PerformanceProfile $Profile -DepthModelProfile VideoDepthSmall 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -eq 0 -or $Output -notmatch 'Depth model VideoDepthSmall is not fully installed') { throw "Wrong preflight: $Output" }
    if ($Output -match 'STUDIO_PLAYER_AUDIO|STUDIO_SOURCE_RESOLVING' -or (Test-Path (Join-Path $Lab 'control.txt'))) { throw 'Preflight started playback' }
    $Checks++
}
Write-Output "DEPTH_PREFLIGHT_OK checks=$Checks artifacts=$Lab"
