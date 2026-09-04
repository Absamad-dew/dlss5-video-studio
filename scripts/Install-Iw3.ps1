[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
& (Join-Path $Root 'runtime/python/python.exe') -s -B (Join-Path $Root 'tools/iw3/install_iw3.py') --root $Root
if ($LASTEXITCODE -ne 0) { throw 'iw3 installation failed. See the log above.' }
