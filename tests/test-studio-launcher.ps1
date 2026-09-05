param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
# A PS7 parent can pass a module search path containing incompatible PS7 modules.
# Use the Windows PowerShell module for the policy snapshot, never change policy.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1') -Force
$Repo=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $Repo ('qa-output/launcher-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new isolated test directory'}
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
function Get-PersistentPolicies {
    foreach($Scope in @('MachinePolicy','UserPolicy','CurrentUser','LocalMachine')){
        '{0}={1}' -f $Scope,(Get-ExecutionPolicy -Scope $Scope)
    }
}
$Before=(Get-PersistentPolicies)-join';'
if((Get-ExecutionPolicy -Scope MachinePolicy)-ne'Undefined' -or (Get-ExecutionPolicy -Scope UserPolicy)-ne'Undefined'){
    throw 'This regression requires an unmanaged policy environment; do not override Group Policy.'
}
$Results=@()
foreach($Policy in @('Clean','Restricted','RemoteSigned')){
    $Case=Join-Path $OutputDirectory $Policy
    New-Item -ItemType Directory -Path $Case|Out-Null
    Copy-Item -LiteralPath (Join-Path $Repo 'dist/DLSS5 Video Studio.exe') -Destination $Case
    Copy-Item -LiteralPath (Join-Path $Repo 'app') -Destination $Case -Recurse
    $Start=[Diagnostics.ProcessStartInfo]::new()
    $Start.FileName=Join-Path $Case 'DLSS5 Video Studio.exe'
    $Start.Arguments='--validate-ui'
    $Start.WorkingDirectory=$env:TEMP # Ensure root resolution is independent of cwd.
    $Start.UseShellExecute=$false
    $Start.CreateNoWindow=$true
    $Start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    if($Policy-eq'Clean'){$Start.EnvironmentVariables.Remove('PSExecutionPolicyPreference')}
    else{$Start.EnvironmentVariables['PSExecutionPolicyPreference']=$Policy}
    $Process=[Diagnostics.Process]::Start($Start)
    try{
        if(-not $Process.WaitForExit(45000)){$Process.Kill();throw "Launcher timeout: $Policy"}
        if($Process.ExitCode-ne 0){
            $Failure=Get-Content -LiteralPath (Join-Path $Case 'studio.error.log') -Raw -ErrorAction SilentlyContinue
            throw "Launcher failed: $Policy ($($Process.ExitCode)) $Failure"
        }
        $Log=Get-Content -LiteralPath (Join-Path $Case 'studio.validation.log') -Raw
        if($Log-notmatch'STUDIO_UI_VALIDATED'){throw "Missing real UI validation: $Policy"}
        if(Test-Path -LiteralPath (Join-Path $Case 'studio.error.log')){throw "Unexpected error log: $Policy"}
        $Results+=[pscustomobject]@{inherited_policy=$Policy;exit_code=$Process.ExitCode;validated=$true}
    }finally{$Process.Dispose()}
}
if($Before-ne((Get-PersistentPolicies)-join';')){throw 'Persistent execution policy changed'}
[pscustomobject]@{cases=$Results;persistent_policy_unchanged=$true;output=$OutputDirectory}|ConvertTo-Json -Depth 4
'STUDIO_LAUNCHER_TESTS_PASSED'
