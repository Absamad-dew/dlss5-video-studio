[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Video,
    [Parameter(Mandatory)] [string] $Ffmpeg,
    [Parameter(Mandatory)] [string] $Directory,
    [int] $Width=2560, [int] $Height=1440, [int] $Frames=120,
    [double] $StartSeconds=120, [int] $Fps=25
)
$ErrorActionPreference='Stop'
if ($Width -le 0 -or $Height -le 0 -or ($Width -band 1) -or ($Height -band 1) -or $Frames -le 0) { throw 'Invalid NV12 fixture geometry/count' }
$Directory=[IO.Path]::GetFullPath($Directory)
New-Item -ItemType Directory -Path $Directory -Force | Out-Null
& $Ffmpeg -y -v error -ss $StartSeconds -i $Video -frames:v $Frames -an -vf "fps=$Fps,scale=${Width}:${Height}:flags=lanczos" -pix_fmt nv12 -f rawvideo (Join-Path $Directory 'input.nv12')
if ($LASTEXITCODE -ne 0) { throw 'Fixture decode failed' }
if ((Get-Item -LiteralPath (Join-Path $Directory 'input.nv12')).Length -ne [long]$Width*$Height*3L/2L*$Frames) { throw 'Incomplete fixture' }
# Neutral guide fields isolate transport/encoding. This is NOT a depth/motion
# quality test or an end-to-end throughput measurement.
$Tile=[int][math]::Ceiling($Width/256.0)
$X=[int][math]::Ceiling($Width/[double]$Tile)
$Y=[int][math]::Ceiling($Height/[double]$Tile)
foreach($Kind in @('motion','depth')) {
    $Stream=[IO.File]::Create((Join-Path $Directory ($Kind+'.bin')))
    $Writer=[IO.BinaryWriter]::new($Stream)
    try {
        if($Kind -eq 'motion') {
            $Writer.Write([Text.Encoding]::ASCII.GetBytes('D5MV0003'))
            foreach($V in @($Width,$Height,$Tile,$Frames,$X,$Y,6,1)) { $Writer.Write([uint32]$V) }
            $Frame=[byte[]]::new($X*$Y*6)
            for($i=0;$i -lt $Frame.Length;$i+=6) { $Frame[$i+4]=1; $Frame[$i+5]=255 }
        } else {
            $Writer.Write([Text.Encoding]::ASCII.GetBytes('D5DP0002'))
            foreach($V in @($Width,$Height,$Frames,2,(1 -bor ($Tile -shl 8)))) { $Writer.Write([uint32]$V) }
            $Frame=[byte[]]::new($X*$Y*2)
            for($i=1;$i -lt $Frame.Length;$i+=2) { $Frame[$i]=0x38 }
        }
        for($f=0;$f -lt $Frames;$f++) { $Writer.Write($Frame) }
    } finally { $Writer.Dispose(); $Stream.Dispose() }
}
Write-Output "FIXTURE_OK ${Width}x${Height} frames=$Frames neutral_guides=1"
