[CmdletBinding()]
param([ValidateSet('All','Native','Launcher','Streamline')][string]$Target='All', [switch]$Json)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$Checks=New-Object 'Collections.Generic.List[object]'
function Check([string]$Name,[bool]$Ready,[string]$Expected){
    $Checks.Add([pscustomobject]@{name=$Name;ready=$Ready;expected=$Expected})
}
Check 'windows-x64' ($env:OS-eq'Windows_NT' -and [Environment]::Is64BitOperatingSystem) 'Windows x64 build host'
if($Target-in @('All','Launcher')){
    Check 'csharp-compiler' (Test-Path -LiteralPath "$env:WINDIR/Microsoft.NET/Framework64/v4.0.30319/csc.exe") '.NET Framework 4.x csc'
    Check 'windows-powershell-sdk' (Test-Path -LiteralPath "$env:WINDIR/Microsoft.Net/assembly/GAC_MSIL/System.Management.Automation/v4.0_3.0.0.0__31bf3856ad364e35/System.Management.Automation.dll") 'Windows PowerShell 5.1 assembly'
    foreach($File in @('Program.cs','app/studio.ps1','app/studio-workspace.ps1','app/studio-shell.xaml','app/studio-theme.xaml','app/depth-models.psm1','app/iw3-ui.ps1','app/iw3-settings.json','app/iw3-da3-models.json')){
        Check ('source:'+ $File) (Test-Path -LiteralPath (Join-Path $Root $File)) $File
    }
}
if($Target-in @('All','Native','Streamline')){
    $VsWhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $VsRoot=if(Test-Path -LiteralPath $VsWhere){& $VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath}else{''}
    Check 'visual-cpp-x64' ([bool]$VsRoot -and (Test-Path -LiteralPath (Join-Path $VsRoot 'VC/Auxiliary/Build/vcvars64.bat'))) 'Visual Studio 2022 C++ x64 tools'
    $KitRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/Include'
    $Kits=@(Get-ChildItem -LiteralPath $KitRoot -Directory -ErrorAction SilentlyContinue | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'um/d3d12.h')})
    Check 'windows-sdk' ($Kits.Count-gt 0) 'Windows SDK with D3D12 headers'
    $Sl=if($env:DLSS5_STREAMLINE_SDK){$env:DLSS5_STREAMLINE_SDK}else{Join-Path $Root 'third_party/streamline-sdk-v2.12.0'}
    foreach($File in @('include/sl.h','include/sl_dlss_g.h','include/sl_reflex.h','lib/x64/sl.interposer.lib')){
        Check ('streamline:'+ $File) (Test-Path -LiteralPath (Join-Path $Sl $File)) ('Streamline 2.12.0 / '+$File)
    }
    $VersionFile=Join-Path $Sl 'include/sl_version.h'
    $VersionText=if(Test-Path -LiteralPath $VersionFile){[IO.File]::ReadAllText($VersionFile)}else{''}
    Check 'streamline-version' ($VersionText-match '#define\s+SL_VERSION_MAJOR\s+2\b' -and $VersionText-match '#define\s+SL_VERSION_MINOR\s+12\b' -and $VersionText-match '#define\s+SL_VERSION_PATCH\s+0\b') 'Streamline 2.12.0 version metadata'
}
if($Target-in @('All','Native')){
    $Ngx=if($env:DLSS5_NGX_SDK){$env:DLSS5_NGX_SDK}else{Join-Path $Root 'third_party/nvidia_ngx_sdk'}
    $NvCodec=if($env:DLSS5_NVCODEC_INCLUDE){$env:DLSS5_NVCODEC_INCLUDE}else{Join-Path $Root 'third_party/nvcodec/include'}
    foreach($File in @('include/nvsdk_ngx.h','include/nvsdk_ngx_helpers.h','lib/Windows_x86_64/x64/nvsdk_ngx_d.lib')){
        Check ('ngx:'+ $File) (Test-Path -LiteralPath (Join-Path $Ngx $File)) ('NGX SDK / '+$File)
    }
    Check 'nvenc-header' (Test-Path -LiteralPath (Join-Path $NvCodec 'ffnvcodec/nvEncodeAPI.h')) 'NVENC header 13.0.19.0; explicit Install-NvCodecHeaders.ps1'
    $Header=Join-Path $NvCodec 'ffnvcodec/nvEncodeAPI.h'
    # A Windows PowerShell child can inherit PS7 module paths. Hash with .NET
    # directly rather than depending on the Get-FileHash script cmdlet.
    $HeaderHash=''
    if(Test-Path -LiteralPath $Header){
        $Stream=[IO.File]::OpenRead($Header)
        try{
            $Sha=[Security.Cryptography.SHA256]::Create()
            try{$HeaderHash=[BitConverter]::ToString($Sha.ComputeHash($Stream)).Replace('-','')}
            finally{$Sha.Dispose()}
        }finally{$Stream.Dispose()}
    }
    $HeaderMatches=$HeaderHash-eq'4FE4094541EF0F8A13249D97A8692DC5F835A6E9DD42EEADB3E2F7321D54DC7E'
    Check 'nvenc-header-sha256' $HeaderMatches 'Pinned public NVENC 13.0.19.0 header digest'
}
$Ready=@($Checks | Where-Object {-not $_.ready}).Count-eq 0
$Result=[pscustomobject]@{schema_version=1;target=$Target;ready=$Ready;checks=$Checks.ToArray();downloads_performed=$false;checks_runtime_readiness=$false}
if($Json){$Result|ConvertTo-Json -Depth 5}else{
    foreach($Row in $Checks){'{0} {1}: {2}' -f $(if($Row.ready){'OK'}else{'MISSING'}),$Row.name,$Row.expected}
    'Build preflight only; no runtime, model or GPU validation. No downloads.'
}
if(-not $Ready){exit 2}
