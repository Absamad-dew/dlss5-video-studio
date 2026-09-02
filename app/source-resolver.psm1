Set-StrictMode -Version Latest

function Test-HttpVideoSource {
    param([string] $Value)
    $Uri = $null
    return [Uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$Uri) -and $Uri.Scheme -in @('http','https')
}

function Quote-NativeArgument {
    param([string] $Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    $Psi = [Diagnostics.ProcessStartInfo]::new()
    $Psi.FileName = $FilePath
    $Psi.Arguments = (($Arguments | ForEach-Object { Quote-NativeArgument ([string]$_) }) -join ' ')
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    $Psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $Psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $Process = [Diagnostics.Process]::new()
    $Process.StartInfo = $Psi
    if (-not $Process.Start()) { throw "Could not start $FilePath" }
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    $Process.WaitForExit()
    $Stdout = $StdoutTask.Result
    $Stderr = $StderrTask.Result
    $ExitCode = $Process.ExitCode
    $Process.Dispose()
    return [pscustomobject]@{ ExitCode=$ExitCode; Stdout=$Stdout; Stderr=$Stderr }
}

function Resolve-OnlineVideoSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PageUrl,
        [Parameter(Mandatory)] [string] $YtDlpPath,
        [ValidateSet(0,540,720,1080,1440,2160,4320)] [int] $MaxHeight = 1080,
        [ValidateSet('None','chrome','edge','firefox')] [string] $CookiesBrowser = 'None',
        [Parameter(Mandatory)] [string] $HeadersPath
    )
    if (-not (Test-HttpVideoSource $PageUrl)) { throw 'The URL must start with http:// or https://.' }
    if (-not (Test-Path -LiteralPath $YtDlpPath -PathType Leaf)) { throw 'The yt-dlp network video component is missing.' }

    # Prefer separate AVC/AAC HTTPS tracks. VK commonly advertises a direct
    # `url1080` entry as "best", but that entry is video-only. Treating it as
    # progressive made realtime playback silent. Separate direct tracks also
    # seek more reliably than VK's HLS playlists with their nested TLS URLs.
    $Format = if ($MaxHeight -gt 0) {
        "bestvideo[height<=$MaxHeight][protocol=https][ext=mp4]+bestaudio[protocol=https][ext=m4a]/bestvideo[height<=$MaxHeight][protocol=https]+bestaudio[protocol=https]/best[height<=$MaxHeight][protocol=https]/best[height<=$MaxHeight]/best"
    } else {
        'bestvideo[protocol=https][ext=mp4]+bestaudio[protocol=https][ext=m4a]/bestvideo[protocol=https]+bestaudio[protocol=https]/best[protocol=https]/best'
    }
    $Args = @('--no-playlist','--no-warnings','--dump-single-json','-f',$Format)
    if ($CookiesBrowser -ne 'None') { $Args += @('--cookies-from-browser',$CookiesBrowser) }
    $Args += @('--',$PageUrl)
    $Result = Invoke-CapturedProcess -FilePath $YtDlpPath -Arguments $Args
    if ($Result.ExitCode -ne 0) {
        $Message = ($Result.Stderr -replace '(?m)^ERROR:\s*','').Trim()
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = 'the site did not return a playable video stream' }
        throw "Could not open the URL: $Message"
    }
    try { $Info = $Result.Stdout | ConvertFrom-Json } catch { throw 'The site returned an invalid video stream description.' }
    $RequestedFormatsProperty = $Info.PSObject.Properties['requested_formats']
    $RequestedFormats = if ($RequestedFormatsProperty -and $RequestedFormatsProperty.Value) { @($RequestedFormatsProperty.Value) } else { @() }
    $VideoFormat = $Info
    $AudioFormat = $Info
    if ($RequestedFormats.Count -gt 0) {
        $VideoFormat = $RequestedFormats | Where-Object { [string]$_.vcodec -ne 'none' } | Select-Object -First 1
        $AudioFormat = $RequestedFormats | Where-Object { [string]$_.acodec -ne 'none' } | Select-Object -First 1
    }
    if (-not $VideoFormat -or [string]::IsNullOrWhiteSpace([string]$VideoFormat.url)) { throw 'The source description has no direct video stream.' }
    if (-not $AudioFormat -or [string]::IsNullOrWhiteSpace([string]$AudioFormat.url)) { $AudioFormat = $VideoFormat }

    function Write-TrackHeaders($FormatInfo, [string] $Path) {
        $Headers = [ordered]@{}
        $HttpHeadersProperty = $FormatInfo.PSObject.Properties['http_headers']
        if ($HttpHeadersProperty -and $HttpHeadersProperty.Value) {
            foreach ($Property in $HttpHeadersProperty.Value.PSObject.Properties) {
                if (-not [string]::IsNullOrWhiteSpace([string]$Property.Value)) {
                    $Headers[[string]$Property.Name] = [string]$Property.Value
                }
            }
        }
        # yt-dlp exposes per-track cookies in Set-Cookie form. FFmpeg needs a
        # normal Cookie request header; keep only the leading name=value pair.
        $CookiesProperty = $FormatInfo.PSObject.Properties['cookies']
        if ($CookiesProperty -and -not [string]::IsNullOrWhiteSpace([string]$CookiesProperty.Value)) {
            $CookiePair = (([string]$CookiesProperty.Value -split ';',2)[0]).Trim()
            if ($CookiePair -match '^[^=;\s]+=[^;]+$') { $Headers['Cookie'] = $CookiePair }
        }
        $HeaderDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
        New-Item -ItemType Directory -Force -Path $HeaderDirectory | Out-Null
        [IO.File]::WriteAllText($Path,($Headers | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        return [IO.Path]::GetFullPath($Path)
    }

    $VideoHeadersPath = Write-TrackHeaders $VideoFormat $HeadersPath
    $AudioHeadersPath = [IO.Path]::ChangeExtension([IO.Path]::GetFullPath($HeadersPath),'.audio.headers.json')
    $AudioHeadersPath = Write-TrackHeaders $AudioFormat $AudioHeadersPath

    function Test-TrackTlsNoVerify($FormatInfo) {
        $TrackUri = [Uri][string]$FormatInfo.url
        return $TrackUri.DnsSafeHost -eq 'okcdn.ru' -or $TrackUri.DnsSafeHost.EndsWith('.okcdn.ru',[StringComparison]::OrdinalIgnoreCase)
    }

    $WidthProperty = $VideoFormat.PSObject.Properties['width']
    $HeightProperty = $VideoFormat.PSObject.Properties['height']
    $ExtractorProperty = $Info.PSObject.Properties['extractor_key']
    return [pscustomobject]@{
        PageUrl = $PageUrl
        MediaUrl = [string]$VideoFormat.url
        AudioUrl = [string]$AudioFormat.url
        Title = [string]$Info.title
        Duration = [double]$Info.duration
        Height = if ($HeightProperty -and $HeightProperty.Value) { [int]$HeightProperty.Value } else { 0 }
        Width = if ($WidthProperty -and $WidthProperty.Value) { [int]$WidthProperty.Value } else { 0 }
        FormatId = [string]$VideoFormat.format_id
        AudioFormatId = [string]$AudioFormat.format_id
        Extractor = if ($ExtractorProperty) { [string]$ExtractorProperty.Value } else { '' }
        HeadersPath = $VideoHeadersPath
        AudioHeadersPath = $AudioHeadersPath
        TlsNoVerify = Test-TrackTlsNoVerify $VideoFormat
        AudioTlsNoVerify = Test-TrackTlsNoVerify $AudioFormat
    }
}

Export-ModuleMember -Function Test-HttpVideoSource,Resolve-OnlineVideoSource
