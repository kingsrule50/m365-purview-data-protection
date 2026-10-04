<#
.SYNOPSIS
    Read-only evidence script for the KRU pilot organisation Purview pilot lab.
    Proves every pilot policy is scoped to the pilot boundary and exports the results.

.DESCRIPTION
    - Makes NO changes. Only Get-* cmdlets are used.
    - Stores NO credentials. Uses interactive modern authentication (MFA supported).
    - Writes a transcript and CSV files to the evidence folder for the GitHub repo.
      Redact tenant names / admin UPNs before committing.

.REQUIREMENTS
    Modules must not live in a OneDrive folder that is offline (see guide Appendix E).
    Install-Module ExchangeOnlineManagement -Scope CurrentUser   (v3.x)
    Role: Compliance Administrator (or Global Reader + Compliance Data Administrator)

.EXAMPLE
    .\Verify-PurviewPilotScope.ps1 -AdminUPN admin@<dev-tenant>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AdminUPN,
    [string] $OutputFolder = ".\evidence"
)

$ErrorActionPreference = 'Stop'

# ---- Pilot boundary definition (edit only if you changed names in the guide) ----
$Pilot = @{
    LabelPrefix     = 'KRU-LBL-'
    LabelPolicy     = 'LBL-PILOT-KRU-Sensitivity'
    DlpPolicy       = 'DLP-PILOT-KRU-PCI-EmployeeID'
    RetentionPolicy = 'RET-PILOT-KRU-Records-1Y'
    AutoLabelPolicy = 'ALP-PILOT-KRU-EmployeeID'     # optional phase
    AdminUnit       = 'AU-KRU-Pilot'                  # dynamic admin unit = the pilot domain
    PilotDomain     = 'm365.kingsruleusa.com'
    FallbackGroup   = 'PurviewPilot'                  # only if you used the mail-enabled group fallback
    SiteMatch       = '/sites/KRU-Purview-Pilot'
    SiteName        = 'KRU-Purview-Pilot'
}

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
Start-Transcript -Path (Join-Path $OutputFolder "scope-proof-$stamp.txt") | Out-Null

Connect-IPPSSession -UserPrincipalName $AdminUPN -ShowBanner:$false -DisableWAM

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Check, [string]$Expected, [string]$Actual, [bool]$Pass)
    $results.Add([pscustomobject]@{
        Check    = $Check
        Expected = $Expected
        Actual   = $Actual
        Result   = if ($Pass) { 'PASS' } else { 'FAIL' }
    })
}
function ConvertTo-Text($value) { (($value | ForEach-Object { "$_" }) -join '; ').Trim() }
function Test-IsEmpty($value)  { [string]::IsNullOrWhiteSpace((ConvertTo-Text $value)) }
function Test-HasAll($value)   { (ConvertTo-Text $value) -cmatch '(^|;\s*)All($|;)' }
# Location objects print their display name; the URL is in .Name. Collect both so either can match.
function Get-LocationText($value) {
    ConvertTo-Text ($value | ForEach-Object { "$_"; if ($_.PSObject.Properties['Name']) { $_.Name }; if ($_.PSObject.Properties['DisplayName']) { $_.DisplayName } } | Where-Object { $_ } | Select-Object -Unique)
}
function Test-PilotSiteOnly($value) {
    $items = @($value | Where-Object { $_ })
    $text  = Get-LocationText $value
    ($items.Count -eq 1) -and -not (Test-HasAll $value) -and
        (($text -match [regex]::Escape($Pilot.SiteMatch)) -or ($text -match "(^|;\s*)$([regex]::Escape($Pilot.SiteName))($|;)"))
}

# ---- 1. Labels ---------------------------------------------------------------
$labels = @(Get-Label | Where-Object { $_.Name -like "$($Pilot.LabelPrefix)*" })
Add-Result 'Pilot labels exist' '4 labels named KRU-LBL-*' "$($labels.Count) found: $(ConvertTo-Text $labels.DisplayName)" ($labels.Count -eq 4)
$labels | Select-Object DisplayName, Name, Priority |
    Export-Csv (Join-Path $OutputFolder "labels-$stamp.csv") -NoTypeInformation

# ---- 2. Admin unit (Microsoft Graph) -------------------------------------------
$au = $null
if (Get-Module -ListAvailable Microsoft.Graph.Identity.DirectoryManagement) {
    Set-MgGraphOption -DisableLoginByWAM $true   # avoids the Windows broker sign-in error seen during readiness
    Connect-MgGraph -Scopes 'AdministrativeUnit.Read.All', 'User.Read.All' -NoWelcome
    $au = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '$($Pilot.AdminUnit)'" -All | Select-Object -First 1
    if ($au) {
        $members = @(Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -All |
            ForEach-Object { $_.AdditionalProperties['userPrincipalName'] } | Where-Object { $_ })
        $outsiders = @($members | Where-Object { $_ -notlike "*@$($Pilot.PilotDomain)" })
        Add-Result 'AU members all on pilot domain' "Only @$($Pilot.PilotDomain)" "$($members.Count) members; outsiders: $(if ($outsiders) { $outsiders -join ', ' } else { 'none' })" ($members.Count -gt 0 -and -not $outsiders)
        Add-Result 'AU membership rule (informational)' 'Dynamic, UPN matches pilot domain' "$($au.MembershipType): $($au.MembershipRule)" $true
    } else {
        Add-Result 'Admin unit exists' $Pilot.AdminUnit 'Not found (fallback group design?)' $false
    }
    Disconnect-MgGraph | Out-Null
}

# ---- 3. Label publishing policy ---------------------------------------------
# Targeting must be the pilot admin unit (or the fallback group), never the whole directory.
# The property that holds the admin unit is not documented consistently, so every property
# of the policy is searched for the AU's object ID or name, and the matching property is reported.
$lp = Get-LabelPolicy -Identity $Pilot.LabelPolicy
# Match on the AU's object ID (stored in PolicyRBACScopes); fall back to the name only without Graph.
$auNeedles = if ($au) { @($au.Id) } else { @($Pilot.AdminUnit) }
$auHits = foreach ($prop in ($lp.PSObject.Properties | Where-Object { $_.Name -ne 'Comment' })) {
    $text = ConvertTo-Text $prop.Value
    foreach ($n in $auNeedles) { if ($text -and $text -match [regex]::Escape($n)) { "$($prop.Name)=$n"; break } }
}
$auText    = ConvertTo-Text ($auHits | Select-Object -Unique)
$lpTargets = ConvertTo-Text $lp.ExchangeLocation
$scopedByAU    = [bool]$auText
$scopedByGroup = ($lpTargets -match $Pilot.FallbackGroup) -and -not (Test-HasAll $lp.ExchangeLocation)
Add-Result 'Label policy scoped to pilot' "Admin unit $($Pilot.AdminUnit) (or fallback group)" `
    "AdminUnit found in: [$(if ($auText) { $auText } else { 'none' })]; Targets=[$lpTargets] (All = all users inside the AU)" ($scopedByAU -or $scopedByGroup)
if (-not $scopedByAU) {
    Write-Host "Admin unit not found in Get-LabelPolicy output. Properties that mention admin/unit/scope:" -ForegroundColor Yellow
    $lp.PSObject.Properties | Where-Object { $_.Name -match 'Admin|Unit|Scope' } | Format-Table Name, Value -AutoSize -Wrap
}

# ---- 4. DLP policy -------------------------------------------------------------
$dlp = Get-DlpCompliancePolicy -Identity $Pilot.DlpPolicy
Add-Result 'DLP SharePoint scope' "Only $($Pilot.SiteName) (1 site)" (Get-LocationText $dlp.SharePointLocation) (Test-PilotSiteOnly $dlp.SharePointLocation)
foreach ($loc in 'ExchangeLocation', 'OneDriveLocation', 'TeamsLocation', 'EndpointDlpLocation') {
    $val = $dlp.$loc
    Add-Result "DLP $loc" 'Empty (off)' $(if (Test-IsEmpty $val) { '(empty)' } else { ConvertTo-Text $val }) (Test-IsEmpty $val)
}
Add-Result 'DLP mode (informational)' 'TestWithNotifications before CHG-PV-002, Enable after' $dlp.Mode $true

Get-DlpComplianceRule -Policy $Pilot.DlpPolicy |
    Select-Object Name, Priority, Disabled, BlockAccess, BlockAccessScope, NotifyUser, GenerateAlert, ReportSeverityLevel |
    Export-Csv (Join-Path $OutputFolder "dlp-rules-$stamp.csv") -NoTypeInformation

# ---- 5. Retention policy -------------------------------------------------------
$ret = Get-RetentionCompliancePolicy -Identity $Pilot.RetentionPolicy -DistributionDetail
Add-Result 'Retention SharePoint scope' "Only $($Pilot.SiteName) (1 site)" (Get-LocationText $ret.SharePointLocation) (Test-PilotSiteOnly $ret.SharePointLocation)
foreach ($loc in 'ExchangeLocation', 'OneDriveLocation', 'ModernGroupLocation') {
    $val = $ret.$loc
    Add-Result "Retention $loc" 'Empty (off)' $(if (Test-IsEmpty $val) { '(empty)' } else { ConvertTo-Text $val }) (Test-IsEmpty $val)
}
Add-Result 'Retention Preservation Lock' 'Not locked' "RestrictiveRetention = $($ret.RestrictiveRetention)" ($ret.RestrictiveRetention -ne $true)
Add-Result 'Retention distribution (informational)' 'Success' $ret.DistributionStatus $true

# ---- 6. Auto-labeling policy (optional phase) ----------------------------------
# Remote cmdlet "not found" errors are non-terminating, so check for $null instead of try/catch.
$alp = Get-AutoSensitivityLabelPolicy -Identity $Pilot.AutoLabelPolicy -ErrorAction SilentlyContinue
if ($alp) {
    Add-Result 'Auto-label SharePoint scope' "Only $($Pilot.SiteName) (1 site)" (Get-LocationText $alp.SharePointLocation) (Test-PilotSiteOnly $alp.SharePointLocation)
    Add-Result 'Auto-label mode (informational)' 'Simulation' $alp.Mode $true
}
else {
    Add-Result 'Auto-label policy (optional)' 'Optional phase' 'Not created (Phase 7 skipped)' $true
}

# ---- Output ----------------------------------------------------------------------
$results | Format-Table Result, Check, Actual -AutoSize -Wrap
$results | Export-Csv (Join-Path $OutputFolder "scope-proof-$stamp.csv") -NoTypeInformation

$fails = @($results | Where-Object Result -eq 'FAIL').Count
if ($fails -eq 0) { Write-Host "`nALL SCOPE CHECKS PASSED - no tenant-wide impact detected." -ForegroundColor Green }
else              { Write-Host "`n$fails CHECK(S) FAILED - review before continuing." -ForegroundColor Red }

Stop-Transcript | Out-Null
Disconnect-ExchangeOnline -Confirm:$false
