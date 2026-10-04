<#
.SYNOPSIS
    Makes the lab's PowerShell modules load from C:\PSModules instead of the
    OneDrive-synced Documents folder (which fails with "The cloud file provider is not running").

.DESCRIPTION
    - First run: downloads the modules the lab needs into C:\PSModules (a few minutes).
    - Every run: removes OneDrive paths from this session's module search path and puts
      C:\PSModules first. Run it once at the start of each PowerShell session.

.EXAMPLE
    .\scripts\Enable-LabModules.ps1
#>
$ErrorActionPreference = 'Stop'
$LocalPath = 'C:\PSModules'
$Modules   = @(
    'ExchangeOnlineManagement'
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Users.Actions'
    'Microsoft.Graph.Identity.DirectoryManagement'
)

New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null

# Session module path: C:\PSModules first, OneDrive paths removed (env vars are process-wide,
# so this applies to every script run afterwards in this window).
$clean = $env:PSModulePath -split ';' | Where-Object { $_ -and $_ -notlike '*OneDrive*' -and $_ -ne $LocalPath }
$env:PSModulePath = (@($LocalPath) + $clean) -join ';'

# Download anything missing (PSResourceGet ships with PowerShell 7.4+, no OneDrive dependency)
foreach ($m in $Modules) {
    if (-not (Test-Path (Join-Path $LocalPath $m))) {
        Write-Host "Downloading $m to $LocalPath ..." -ForegroundColor Cyan
        Save-PSResource -Name $m -Path $LocalPath -TrustRepository -Quiet
    }
}

Write-Host "`nModule path for this session:" -ForegroundColor Cyan
$env:PSModulePath -split ';' | ForEach-Object { "  $_" }

Write-Host "`nLab modules available:" -ForegroundColor Cyan
Get-Module -ListAvailable $Modules | Sort-Object Name |
    Select-Object Name, Version, @{ n = 'Path'; e = { Split-Path $_.ModuleBase -Parent } } |
    Format-Table -AutoSize

Write-Host "Ready. Run the lab scripts in this same window." -ForegroundColor Green
