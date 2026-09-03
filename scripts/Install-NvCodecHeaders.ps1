[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$Header = Join-Path $Root 'third_party\nvcodec\include\ffnvcodec\nvEncodeAPI.h'
$Expected = '4FE4094541EF0F8A13249D97A8692DC5F835A6E9DD42EEADB3E2F7321D54DC7E'
if (Test-Path -LiteralPath $Header) {
    if ((Get-FileHash -LiteralPath $Header -Algorithm SHA256).Hash -eq $Expected) {
        Write-Output 'NVENC_HEADERS_OK version=13.0.19.0'
        exit 0
    }
    throw 'Existing NVENC header has an unexpected hash; refusing to overwrite it.'
}
New-Item -ItemType Directory -Path (Split-Path -Parent $Header) -Force | Out-Null
$Download = $Header + '.download'
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/FFmpeg/nv-codec-headers/n13.0.19.0/include/ffnvcodec/nvEncodeAPI.h' -OutFile $Download
if ((Get-FileHash -LiteralPath $Download -Algorithm SHA256).Hash -ne $Expected) {
    throw 'Downloaded NVENC header failed SHA-256 verification.'
}
Move-Item -LiteralPath $Download -Destination $Header
Write-Output 'NVENC_HEADERS_OK version=13.0.19.0'
