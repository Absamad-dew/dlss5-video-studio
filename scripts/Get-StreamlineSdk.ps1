[CmdletBinding()]
param(
    [string] $Version = '2.12.0'
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Zip = Join-Path $Root "third_party\streamline-sdk-v$Version.zip"
$Destination = Join-Path $Root "third_party\streamline-sdk-v$Version"
$Uri = "https://github.com/NVIDIA-RTX/Streamline/releases/download/v$Version/streamline-sdk-v$Version.zip"

if (-not (Test-Path -LiteralPath $Zip)) {
    & curl.exe -L --fail --output $Zip $Uri
    if ($LASTEXITCODE -ne 0) { throw "Streamline download failed with exit code $LASTEXITCODE" }
}
if (-not (Test-Path -LiteralPath $Destination)) {
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination
}
$Item = Get-Item -LiteralPath $Zip
Write-Output "STREAMLINE_SDK_OK version=$Version bytes=$($Item.Length) path=$Destination"
