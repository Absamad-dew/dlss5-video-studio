[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root)

$ErrorActionPreference = 'Stop'
$resolved = [IO.Path]::GetFullPath($Root)
$rows = foreach ($directory in Get-ChildItem -LiteralPath $resolved -Directory) {
    $files = @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
    $sum = ($files | Measure-Object Length -Sum).Sum
    [pscustomobject]@{
        name = $directory.Name
        gigabytes = [math]::Round($sum / 1GB, 3)
        files = $files.Count
    }
}
$all = @(Get-ChildItem -LiteralPath $resolved -Recurse -File -Force -ErrorAction SilentlyContinue)
[ordered]@{
    root = $resolved
    total_gigabytes = [math]::Round((($all | Measure-Object Length -Sum).Sum) / 1GB, 3)
    total_files = $all.Count
    directories = @($rows | Sort-Object gigabytes -Descending)
} | ConvertTo-Json -Depth 4
