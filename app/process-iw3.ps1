[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputVideo,
    [Parameter(Mandatory)][string]$OutputVideo,
    [Parameter(Mandatory)][string]$SettingsPath,
    [string]$ConfigPath,
    [ValidateSet('H264','H265')][string]$Codec='H265',
    [ValidateRange(0,51)][int]$Quality=18,
    [ValidateSet('Source','2160p','1440p','1080p','720p','540p')][string]$OutputMode='Source',
    [double]$StartSeconds=0,
    [int]$FrameCount=0,
    [ValidateSet('UltraFast','Fast','Medium','Heavy','Maximum')][string]$PerformanceProfile='Medium',
    [string]$DepthModelProfile='DA2Small',
    [int]$NetworkMaxHeight=2160,
    [ValidateSet('None','chrome','edge','firefox')][string]$NetworkCookiesBrowser='None',
    [switch]$KeepTemporaryFiles
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Python=Join-Path $Root 'runtime/python/python.exe'
$Worker=Join-Path $Root 'tools/iw3/iw3_worker.py'
$Net=$null
$HeaderPath=$null
$NetPath=$null
try {
    foreach($Path in @($Python,$Worker,$SettingsPath)){
        if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Missing component: $Path. Run INSTALL_IW3.cmd."}
    }
    $Arguments=@('-s','-B',$Worker,'--root',$Root,'--input',$InputVideo,'--output',$OutputVideo,
        '--settings',$SettingsPath,'--codec',$Codec,'--quality',$Quality,'--output-mode',$OutputMode,
        '--start',$StartSeconds.ToString('0.######',[Globalization.CultureInfo]::InvariantCulture),
        '--frames',$FrameCount,'--profile',$PerformanceProfile,'--depth-profile',$DepthModelProfile)
    if($ConfigPath){$Arguments+=@('--config',$ConfigPath)}
    if($KeepTemporaryFiles){$Arguments+='--keep-temp'}
    if($InputVideo -match '^https?://'){
        Import-Module (Join-Path $PSScriptRoot 'source-resolver.psm1') -Force
        $NetworkDir=Join-Path $Root 'temp/iw3-network'
        New-Item -ItemType Directory -Force -Path $NetworkDir|Out-Null
        $HeaderPath=Join-Path $NetworkDir ([Guid]::NewGuid().ToString('N')+'.headers.json')
        Write-Output 'STUDIO_SOURCE Resolving online video'
        $Net=Resolve-OnlineVideoSource -PageUrl $InputVideo -YtDlpPath (Join-Path $Root 'tools/yt-dlp.exe') -MaxHeight $NetworkMaxHeight -CookiesBrowser $NetworkCookiesBrowser -HeadersPath $HeaderPath
        $NetPath=$HeaderPath+'.source.json'
        [IO.File]::WriteAllText($NetPath,($Net|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $Arguments+=@('--network',$NetPath)
        Write-Output ('STUDIO_SOURCE_JSON '+(@{title=$Net.Title;width=$Net.Width;height=$Net.Height;format_id=$Net.FormatId;duration_seconds=$Net.Duration}|ConvertTo-Json -Compress))
    }
    # PowerShell 5 treats native stderr progress as an error record. Preserve the
    # actual process exit code instead of failing on a model-download progress bar.
    $ErrorActionPreference='Continue'
    & $Python @Arguments 2>&1 | ForEach-Object { Write-Output ([string]$_) }
    $Code=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    if($Code -ne 0){throw "iw3 processing failed (exit $Code). See preceding error."}
} catch {
    Write-Output ('STUDIO_ERROR '+$_.Exception.Message)
    exit 1
} finally {
    foreach($Path in @($NetPath,$HeaderPath,$Net.AudioHeadersPath)){
        if($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)){Remove-Item -LiteralPath $Path -Force}
    }
}
