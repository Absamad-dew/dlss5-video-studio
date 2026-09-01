$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Lab = 'D:\DLSS5_PERF_LAB\guide-server-smoke'
New-Item -ItemType Directory -Force -Path $Lab | Out-Null
$Command = [ordered]@{
    cmd = 'chunk'
    id = 0
    input = (Join-Path $Lab 'chunk.rgb')
    frames = 4
    motion_output = (Join-Path $Lab 'chunk.motion')
    depth_output = (Join-Path $Lab 'chunk.depth')
} | ConvertTo-Json -Compress
$InputLines = @($Command, '{"cmd":"end"}')
$InputLines | & (Join-Path $Root 'python\.venv\Scripts\python.exe') (Join-Path $Root 'python\guidegen.py') `
    --server --width 1280 --height 546 `
    --depth-model 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_PORTABLE\models\depth_anything_v2_small.onnx' `
    --depth-backend auto --cache-dir (Join-Path $Lab 'cache') --guide-width 320 `
    --depth-interval 2 --depth-min-interval 2 --scene-cut-threshold 0.12 `
    --decode-video 'D:\DLSS5_PERF_LAB\host-480-h265-24-no-prefetch.mp4' `
    --ffmpeg 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_PORTABLE\tools\ffmpeg.exe' `
    --start-seconds 0 --fps 25 --total-frames 4
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Get-Item -LiteralPath (Join-Path $Lab 'chunk.rgb'),(Join-Path $Lab 'chunk.motion'),(Join-Path $Lab 'chunk.depth') |
    Select-Object Name,Length
