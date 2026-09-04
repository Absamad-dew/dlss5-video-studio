[CmdletBinding()]
param([ValidateSet('Any_V3_Mono','Studio_DA3_Small','Studio_DA3_Base','Studio_DA3_Large_11','Studio_DA3_Giant_11')][string[]]$Model=@('Any_V3_Mono'))
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
& (Join-Path $Root 'runtime/python/python.exe') -s -B (Join-Path $Root 'tools/iw3/iw3_da3_install.py') --root $Root --models @Model --limit-gb 50
if($LASTEXITCODE -ne 0){throw 'DA3 installation failed. See temp/iw3-da3-install.log and .errors. Existing models were preserved.'}
