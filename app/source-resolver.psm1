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

    # Prefer one progressive HTTPS stream: it starts faster and provides
    # deterministic random access for the player's restart-on-seek model.
    $Format = if ($MaxHeight -gt 0) {
        "best[height<=$MaxHeight][protocol=https]/best[height<=$MaxHeight]/best"
    } else {
        'best[protocol=https]/best'
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
    if ([string]::IsNullOrWhiteSpace([string]$Info.url)) { throw 'The source description has no direct video stream.' }

    $Headers = [ordered]@{}
    if ($Info.http_headers) {
        foreach ($Property in $Info.http_headers.PSObject.Properties) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Property.Value)) {
                $Headers[[string]$Property.Name] = [string]$Property.Value
            }
        }
    }
    $HeaderDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($HeadersPath))
    New-Item -ItemType Directory -Force -Path $HeaderDirectory | Out-Null
    [IO.File]::WriteAllText($HeadersPath,($Headers | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))

    $MediaUri = [Uri][string]$Info.url
    $TlsNoVerify = $MediaUri.DnsSafeHost -eq 'okcdn.ru' -or $MediaUri.DnsSafeHost.EndsWith('.okcdn.ru',[StringComparison]::OrdinalIgnoreCase)
    $WidthProperty = $Info.PSObject.Properties['width']
    $HeightProperty = $Info.PSObject.Properties['height']
    $ExtractorProperty = $Info.PSObject.Properties['extractor_key']
    return [pscustomobject]@{
        PageUrl = $PageUrl
        MediaUrl = [string]$Info.url
        Title = [string]$Info.title
        Duration = [double]$Info.duration
        Height = if ($HeightProperty -and $HeightProperty.Value) { [int]$HeightProperty.Value } else { 0 }
        Width = if ($WidthProperty -and $WidthProperty.Value) { [int]$WidthProperty.Value } else { 0 }
        FormatId = [string]$Info.format_id
        Extractor = if ($ExtractorProperty) { [string]$ExtractorProperty.Value } else { '' }
        HeadersPath = [IO.Path]::GetFullPath($HeadersPath)
        TlsNoVerify = $TlsNoVerify
    }
}

Export-ModuleMember -Function Test-HttpVideoSource,Resolve-OnlineVideoSource
