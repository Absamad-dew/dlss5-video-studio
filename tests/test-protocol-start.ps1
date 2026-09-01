$ErrorActionPreference = 'Stop'
function Q([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}
$Root = 'C:\Users\Lenovo\Documents\Codex\DLSS5_VIDEO_STUDIO_PORTABLE_OPTIMIZED'
$ArgsList = @(
    '--server','--width','1280','--height','546',
    '--depth-model',(Join-Path $Root 'models\depth_anything_v2_small.onnx'),
    '--depth-backend','auto','--cache-dir','D:\DLSS5_PERF_LAB\protocol-cache',
    '--guide-width','320','--depth-interval','2','--depth-min-interval','2',
    '--scene-cut-threshold','0.12','--motion-preset','balanced'
)
$Psi = New-Object Diagnostics.ProcessStartInfo
$Psi.FileName = Join-Path $Root 'tools\guidegen\guidegen.exe'
$Psi.Arguments = (($ArgsList | ForEach-Object { Q ([string]$_) }) -join ' ')
$Psi.WorkingDirectory = $Root
$Psi.UseShellExecute = $false
$Psi.CreateNoWindow = $true
$Psi.RedirectStandardInput = $true
$Psi.RedirectStandardOutput = $true
$Psi.RedirectStandardError = $true
$Psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$Psi.StandardErrorEncoding = [Text.Encoding]::UTF8
$P = New-Object Diagnostics.Process
$P.StartInfo = $Psi
[void]$P.Start()
$P.StandardInput.AutoFlush = $true
Write-Output "TYPE $($P.GetType().FullName) PID $($P.Id) ARGS $($Psi.Arguments)"
for ($i=0; $i -lt 4; $i++) {
    $Line = $P.StandardOutput.ReadLine()
    Write-Output "LINE[$i]=$Line"
    if ($Line -like 'GUIDE_SERVER_READY*') { break }
}
$P.StandardInput.WriteLine('{"cmd":"end"}')
$P.StandardInput.Close()
Write-Output "DONE=$($P.StandardOutput.ReadLine())"
$P.WaitForExit()
Write-Output "EXIT=$($P.ExitCode) STDERR=$($P.StandardError.ReadToEnd())"
