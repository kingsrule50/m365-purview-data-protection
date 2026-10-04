<#
.SYNOPSIS
    Read-only readiness check for the KRU Purview pilot (m365.kingsruleusa.com) in a SHARED Microsoft 365 tenant.

.DESCRIPTION
    Answers four questions before you build anything:
      1. Is the pilot domain present and verified?
      2. Does the tenant have the licences this design needs (Entra ID P1/P2 for dynamic admin units, Purview features)?
      3. Is audit logging on?
      4. What have OTHER tenant users already deployed that could reach your pilot users or site
         (tenant-wide label, DLP, retention and auto-labeling policies), and do any of the lab's names already exist?

    - Makes NO changes. Only Get-* cmdlets are used.
    - Stores NO credentials. Interactive modern authentication (MFA supported).
    - Writes a transcript and CSV files to the evidence folder. Redact tenant names before committing.

.REQUIREMENTS
    Install-Module ExchangeOnlineManagement -Scope CurrentUser            (required)
    Install-Module Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users -Scope CurrentUser   (recommended)

.EXAMPLE
    .\Invoke-PurviewReadiness.ps1 -AdminUPN admin@<dev-tenant>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AdminUPN,
    [string] $PilotDomain  = 'm365.kingsruleusa.com',
    [string] $OutputFolder = '.\evidence'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
Start-Transcript -Path (Join-Path $OutputFolder "readiness-$stamp.txt") | Out-Null

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Area, [string]$Check, [ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail })
}
function ConvertTo-Text($value) { (($value | ForEach-Object { "$_" }) -join '; ').Trim() }
function Test-HasAll($value)   { (ConvertTo-Text $value) -cmatch '(^|;\s*)All($|;)' }

$LabPrefixes = 'KRU-LBL-', 'LBL-PILOT-KRU', 'DLP-PILOT-KRU', 'RET-PILOT-KRU', 'ALP-PILOT-KRU', 'SIT-KRU'
function Test-LabName($name) { foreach ($p in $LabPrefixes) { if ($name -like "$p*") { return $true } }; return $false }

# =====================================================================
# 1. Microsoft Graph: domain, licences, existing pilot-domain users, AU name
# =====================================================================
$graphModules = 'Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Users'
if (@($graphModules | Where-Object { Get-Module -ListAvailable $_ }).Count -eq $graphModules.Count) {
    Set-MgGraphOption -DisableLoginByWAM $true   # avoids the Windows broker sign-in error seen during readiness
    Connect-MgGraph -Scopes 'Domain.Read.All', 'Organization.Read.All', 'User.Read.All', 'AdministrativeUnit.Read.All' -NoWelcome

    # Domain
    $domain = Get-MgDomain -All | Where-Object Id -eq $PilotDomain
    if ($domain) {
        Add-Result 'Domain' "Pilot domain $PilotDomain present" $(if ($domain.IsVerified) { 'PASS' } else { 'FAIL' }) `
            "IsVerified=$($domain.IsVerified); Services=$($domain.SupportedServices -join ',')"
    } else {
        $similar = (Get-MgDomain -All | Where-Object Id -like '*rule*').Id -join ', '
        Add-Result 'Domain' "Pilot domain $PilotDomain present" 'FAIL' "Not found. Check spelling. Similar domains in tenant: $similar"
    }

    # Licences / service plans
    $skus  = Get-MgSubscribedSku -All
    $skus | Select-Object SkuPartNumber, CapabilityStatus, ConsumedUnits, @{ n = 'Enabled'; e = { $_.PrepaidUnits.Enabled } } |
        Export-Csv (Join-Path $OutputFolder "licences-$stamp.csv") -NoTypeInformation
    $plans = $skus.ServicePlans | Where-Object ProvisioningStatus -eq 'Success' | Select-Object -ExpandProperty ServicePlanName -Unique
    Add-Result 'Licences' 'SKUs in tenant' 'INFO' (($skus.SkuPartNumber) -join ', ')

    $p1 = @($plans | Where-Object { $_ -like 'AAD_PREMIUM*' })
    Add-Result 'Licences' 'Entra ID P1/P2 (dynamic admin units)' $(if ($p1) { 'PASS' } else { 'FAIL' }) `
        $(if ($p1) { $p1 -join ', ' } else { 'Not found: use the mail-enabled group fallback in Phase 1' })

    $mip = @($plans | Where-Object { $_ -like 'MIP_S_*' })
    Add-Result 'Licences' 'Information Protection service plans' $(if ($mip) { 'PASS' } else { 'WARN' }) `
        $(if ($mip) { $mip -join ', ' } else { 'None found: labels may still work; confirm in portal' })

    $e5ish = @($skus.SkuPartNumber | Where-Object { $_ -match 'E5|COMPLIANCE|DEVELOPERPACK' })
    Add-Result 'Licences' 'E5-class SKU (Purview admin units, auto-labeling)' $(if ($e5ish) { 'PASS' } else { 'WARN' }) `
        $(if ($e5ish) { $e5ish -join ', ' } else { 'No E5-class SKU detected: admin units / auto-labeling may be unavailable' })

    # Existing users on the pilot domain
    $domUsers = @(Get-MgUser -Filter "endsWith(userPrincipalName,'@$PilotDomain')" -ConsistencyLevel eventual -CountVariable cnt -All -Property UserPrincipalName, AccountEnabled)
    Add-Result 'Identity' "Existing users on @$PilotDomain" 'INFO' $(if ($domUsers.Count) { ($domUsers.UserPrincipalName -join ', ') } else { 'None yet' })

    # Admin unit name collision
    $au = @(Get-MgDirectoryAdministrativeUnit -Filter "displayName eq 'AU-KRU-Pilot'" -All)
    Add-Result 'Identity' 'Admin unit name AU-KRU-Pilot free' $(if ($au.Count) { 'WARN' } else { 'PASS' }) `
        $(if ($au.Count) { 'Already exists: reuse it only if you created it' } else { 'Available' })

    Disconnect-MgGraph | Out-Null
} else {
    Add-Result 'Graph' 'Microsoft Graph modules' 'WARN' 'Not installed: domain and licence checks skipped. Check them in the portal instead.'
}

# =====================================================================
# 2. Exchange Online: audit + accepted domain
# =====================================================================
Connect-ExchangeOnline -UserPrincipalName $AdminUPN -ShowBanner:$false -DisableWAM
$audit = (Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled
Add-Result 'Audit' 'Unified audit log enabled' $(if ($audit) { 'PASS' } else { 'FAIL' }) "UnifiedAuditLogIngestionEnabled=$audit"

$accepted = Get-AcceptedDomain | Where-Object DomainName -eq $PilotDomain
Add-Result 'Domain' 'Pilot domain is an accepted domain (mailboxes / policy tip emails)' $(if ($accepted) { 'PASS' } else { 'WARN' }) `
    $(if ($accepted) { "Type=$($accepted.DomainType)" } else { 'Not an accepted domain: user mailboxes will use onmicrosoft.com addresses' })

# =====================================================================
# 3. Security & Compliance: inventory of what OTHER people have deployed
# =====================================================================
Connect-IPPSSession -UserPrincipalName $AdminUPN -ShowBanner:$false -DisableWAM
$inventory = [System.Collections.Generic.List[object]]::new()

foreach ($p in Get-LabelPolicy) {
    $wide = Test-HasAll $p.ExchangeLocation
    $inventory.Add([pscustomobject]@{ Type = 'Label policy'; Name = $p.Name; Mode = 'n/a'; TenantWide = $wide; Detail = "Labels: $(ConvertTo-Text $p.Labels)" })
    if (Test-LabName $p.Name) { Add-Result 'Collisions' "Label policy $($p.Name)" 'FAIL' 'Lab name already in use' }
    elseif ($wide) { Add-Result 'Overlap' "Label policy $($p.Name) targets All users" 'WARN' 'Its labels and settings (default/mandatory label) will ALSO apply to pilot users. Note for TC-01..05.' }
}

foreach ($p in Get-DlpCompliancePolicy) {
    $wideSpo = Test-HasAll $p.SharePointLocation
    $wideOd  = Test-HasAll $p.OneDriveLocation
    $inventory.Add([pscustomobject]@{ Type = 'DLP policy'; Name = $p.Name; Mode = $p.Mode; TenantWide = ($wideSpo -or $wideOd); Detail = "SPO=$(ConvertTo-Text $p.SharePointLocation) | OD=$(ConvertTo-Text $p.OneDriveLocation)" })
    if (Test-LabName $p.Name) { Add-Result 'Collisions' "DLP policy $($p.Name)" 'FAIL' 'Lab name already in use' }
    elseif (($wideSpo -or $wideOd) -and $p.Mode -eq 'Enable') {
        Add-Result 'Overlap' "DLP policy $($p.Name) is ENFORCED on all sites/OneDrive" 'WARN' 'May also match or block your test files. TC-11/TC-12 results must exclude its matches.'
    }
}

foreach ($p in Get-RetentionCompliancePolicy) {
    $wideSpo = Test-HasAll $p.SharePointLocation
    $inventory.Add([pscustomobject]@{ Type = 'Retention policy'; Name = $p.Name; Mode = "Enabled=$($p.Enabled)"; TenantWide = $wideSpo; Detail = "SPO=$(ConvertTo-Text $p.SharePointLocation); Locked=$($p.RestrictiveRetention)" })
    if (Test-LabName $p.Name) { Add-Result 'Collisions' "Retention policy $($p.Name)" 'FAIL' 'Lab name already in use' }
    elseif ($wideSpo) {
        Add-Result 'Overlap' "Retention policy $($p.Name) covers ALL SharePoint sites" 'WARN' 'Your pilot site will be under it too: teardown cannot delete the site while it applies. Plan to keep or empty the site instead.'
    }
}

try {
    foreach ($p in Get-AutoSensitivityLabelPolicy) {
        $wide = (Test-HasAll $p.SharePointLocation) -or (Test-HasAll $p.OneDriveLocation)
        $inventory.Add([pscustomobject]@{ Type = 'Auto-label policy'; Name = $p.Name; Mode = $p.Mode; TenantWide = $wide; Detail = "SPO=$(ConvertTo-Text $p.SharePointLocation)" })
        if (Test-LabName $p.Name) { Add-Result 'Collisions' "Auto-label policy $($p.Name)" 'FAIL' 'Lab name already in use' }
        elseif ($wide -and $p.Mode -eq 'Enable') { Add-Result 'Overlap' "Auto-label policy $($p.Name) is ON for all sites" 'WARN' 'Could label your test files before you do.' }
    }
} catch { Add-Result 'Auto-labeling' 'Auto-labeling cmdlets' 'WARN' 'Not available: auto-labeling likely not licensed (Phase 7 is optional).' }

$labels = @(Get-Label)
Add-Result 'Labels' 'Existing sensitivity labels in tenant' 'INFO' "$($labels.Count) labels: $(ConvertTo-Text $labels.DisplayName)"
foreach ($l in $labels | Where-Object { Test-LabName $_.Name }) { Add-Result 'Collisions' "Label $($l.Name)" 'FAIL' 'Lab label name already in use' }
$dupDisplay = @($labels | Where-Object { $_.DisplayName -in 'Public', 'Internal', 'Confidential', 'Highly Confidential' })
if ($dupDisplay.Count) {
    Add-Result 'Labels' 'Display-name overlap' 'INFO' "Existing: $(ConvertTo-Text $dupDisplay.DisplayName). The lab uses 'KRU ...' display names, so tests stay unambiguous."
}

try {
    $sit = Get-DlpSensitiveInformationType -Identity 'SIT-KRU-EmployeeID' -ErrorAction Stop
    Add-Result 'Collisions' 'SIT-KRU-EmployeeID' 'FAIL' 'Already exists'
} catch { Add-Result 'Collisions' 'SIT-KRU-EmployeeID name free' 'PASS' 'Available' }

$overlapCount = @($results | Where-Object Area -eq 'Overlap').Count
if (-not $overlapCount) { Add-Result 'Overlap' 'Tenant-wide policies from other admins' 'PASS' 'None found that reach the pilot domain or site' }

# =====================================================================
# Output
# =====================================================================
$inventory | Export-Csv (Join-Path $OutputFolder "tenant-policy-inventory-$stamp.csv") -NoTypeInformation
$results   | Export-Csv (Join-Path $OutputFolder "readiness-$stamp.csv") -NoTypeInformation

$results | Sort-Object { @{ FAIL = 0; WARN = 1; PASS = 2; INFO = 3 }[$_.Status] }, Area | Format-Table Status, Area, Check, Detail -AutoSize -Wrap

$f = @($results | Where-Object Status -eq 'FAIL').Count
$w = @($results | Where-Object Status -eq 'WARN').Count
Write-Host ("`nREADINESS: {0} FAIL, {1} WARN. Share this table (redacted) before starting Phase 1." -f $f, $w) -ForegroundColor $(if ($f) { 'Red' } elseif ($w) { 'Yellow' } else { 'Green' })

Stop-Transcript | Out-Null
Disconnect-ExchangeOnline -Confirm:$false
