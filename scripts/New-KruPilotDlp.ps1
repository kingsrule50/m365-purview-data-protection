<#
.SYNOPSIS
    Phase 6 of the KRU Purview pilot: creates the tiered DLP policy
    DLP-PILOT-KRU-PCI-EmployeeID in SIMULATION mode (with policy tips), scoped to the
    pilot SharePoint site only, with four rules in priority order.

.DESCRIPTION
    Rule design (most restrictive first):
      R04-HighlyConfidential-External  label KRU Highly Confidential      -> block external access, no override  (High)
      R02-PCI-HighVolume               Credit Card Number x5+, high conf. -> block external access, no override  (High)
      R03-EmployeeID                   SIT-KRU-EmployeeID x1+, high conf. -> block external, override w/ justification (Medium)
      R01-PCI-LowVolume                Credit Card Number x1-4, high conf.-> policy tip + audit only               (Low)

    Scope: SharePoint location = the pilot site only. Exchange, OneDrive, Teams, Devices: not added.
    Mode : TestWithNotifications (simulation + policy tips). Enforcement is a separate, approved change (CHG-PV-002).

    - Idempotent: existing policy/rules are reported and skipped.
    - Supports -WhatIf. No stored credentials.
    - Requires SIT-KRU-EmployeeID (Phase 5) and the KRU labels (Phase 3) to exist.

.EXAMPLE
    $p = @{ AdminUPN = 'admin@<dev-tenant>'; SiteUrl = 'https://<dev-tenant>.sharepoint.com/sites/KRU-Purview-Pilot'; AlertRecipient = 'secops@<dev-tenant>' }
    .\New-KruPilotDlp.ps1 @p -WhatIf
    .\New-KruPilotDlp.ps1 @p
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $AdminUPN,
    [Parameter(Mandatory)] [string] $SiteUrl,          # e.g. https://<dev-tenant>.sharepoint.com/sites/KRU-Purview-Pilot
    [string] $PolicyName = 'DLP-PILOT-KRU-PCI-EmployeeID',
    [Parameter(Mandatory)] [string] $AlertRecipient    # incident alerts must go to a real SMTP address
)
$ErrorActionPreference = 'Stop'

Connect-IPPSSession -UserPrincipalName $AdminUPN -ShowBanner:$false -DisableWAM
$results = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
$sit = Get-DlpSensitiveInformationType -Identity 'SIT-KRU-EmployeeID' -ErrorAction SilentlyContinue
if (-not $sit) { throw "SIT-KRU-EmployeeID not found. Run New-KruEmployeeIdSit.ps1 (Phase 5) first." }
$hcLabel = Get-Label -Identity 'KRU-LBL-HighlyConfidential' -ErrorAction SilentlyContinue
if (-not $hcLabel) { throw "Label KRU-LBL-HighlyConfidential not found. Run New-KruPilotLabels.ps1 (Phase 3) first." }
$hcLabelId = if ($hcLabel.ImmutableId) { "$($hcLabel.ImmutableId)" } else { "$($hcLabel.Guid)" }

# ---------------------------------------------------------------------------
# Policy (simulation, pilot site only)
# ---------------------------------------------------------------------------
$policy = Get-DlpCompliancePolicy -Identity $PolicyName -ErrorAction SilentlyContinue
if ($policy) {
    $results.Add([pscustomobject]@{ Object = $PolicyName; Action = 'Policy exists'; Result = "Skipped (mode $($policy.Mode))" })
}
elseif ($PSCmdlet.ShouldProcess($PolicyName, "Create DLP policy in simulation, SharePoint location = $SiteUrl only")) {
    New-DlpCompliancePolicy -Name $PolicyName `
        -Comment 'KRU pilot: card data and employee IDs in the KRU-Purview-Pilot site. Simulation first; enforcement via CHG-PV-002.' `
        -SharePointLocation $SiteUrl `
        -Mode TestWithNotifications | Out-Null
    $results.Add([pscustomobject]@{ Object = $PolicyName; Action = 'Create policy (TestWithNotifications, 1 site)'; Result = 'Done' })
}

# ---------------------------------------------------------------------------
# Rules, created in priority order
# ---------------------------------------------------------------------------
$notifyCommon = @{
    NotifyUser          = @('LastModifier', 'Owner')
    GenerateAlert       = @($AlertRecipient)
}

$rules = @(
    [ordered]@{
        Name     = 'R04-HighlyConfidential-External'
        Desc     = 'Label KRU Highly Confidential -> block external access, no override'
        Params   = @{
            ContentContainsSensitiveInformation = @{
                operator = 'And'
                groups   = @( @{ operator = 'Or'; name = 'Default'; labels = @( @{ name = $hcLabelId; type = 'Sensitivity' } ) } )
            }
            AccessScope              = 'NotInOrganization'
            BlockAccess              = $true
            BlockAccessScope         = 'PerUser'
            NotifyPolicyTipCustomText = 'This document is labelled KRU Highly Confidential and cannot be shared outside KRU.'
            ReportSeverityLevel      = 'High'
        }
    }
    [ordered]@{
        Name     = 'R02-PCI-HighVolume'
        Desc     = 'Credit Card Number x5+ (high) -> block external access, no override'
        Params   = @{
            ContentContainsSensitiveInformation = @( @{ Name = 'Credit Card Number'; minCount = '5'; maxCount = '-1'; confidencelevel = 'High' } )
            AccessScope              = 'NotInOrganization'
            BlockAccess              = $true
            BlockAccessScope         = 'PerUser'
            NotifyPolicyTipCustomText = 'This file contains 5 or more payment card numbers and cannot be shared outside KRU.'
            ReportSeverityLevel      = 'High'
        }
    }
    [ordered]@{
        Name     = 'R03-EmployeeID'
        Desc     = 'SIT-KRU-EmployeeID x1+ (high) -> block external, override with justification'
        Params   = @{
            ContentContainsSensitiveInformation = @( @{ Name = 'SIT-KRU-EmployeeID'; minCount = '1'; maxCount = '-1'; confidencelevel = 'High' } )
            AccessScope              = 'NotInOrganization'
            BlockAccess              = $true
            BlockAccessScope         = 'PerUser'
            NotifyAllowOverride      = 'WithJustification'
            NotifyPolicyTipCustomText = 'This file contains KRU employee IDs. External sharing needs a business justification.'
            ReportSeverityLevel      = 'Medium'
        }
    }
    [ordered]@{
        Name     = 'R01-PCI-LowVolume'
        Desc     = 'Credit Card Number x1-4 (high) -> policy tip + audit only'
        Params   = @{
            ContentContainsSensitiveInformation = @( @{ Name = 'Credit Card Number'; minCount = '1'; maxCount = '4'; confidencelevel = 'High' } )
            NotifyPolicyTipCustomText = 'This file contains payment card numbers. Handle according to KRU data policy.'
            ReportSeverityLevel      = 'Low'
        }
    }
)

$existingRules = @(Get-DlpComplianceRule -Policy $PolicyName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
$priority = 0
foreach ($r in $rules) {
    if ($existingRules -contains $r.Name) {
        $results.Add([pscustomobject]@{ Object = $r.Name; Action = 'Rule exists'; Result = 'Skipped' })
        $priority++; continue
    }
    if (-not $PSCmdlet.ShouldProcess($r.Name, "Create rule (priority $priority): $($r.Desc)")) { $priority++; continue }
    try {
        $p = $r.Params + $notifyCommon
        New-DlpComplianceRule -Policy $PolicyName -Name $r.Name -Priority $priority @p -ErrorAction Stop | Out-Null
        $results.Add([pscustomobject]@{ Object = $r.Name; Action = "Create rule P$priority - $($r.Desc)"; Result = 'Done' })
    }
    catch {
        $results.Add([pscustomobject]@{ Object = $r.Name; Action = "Create rule P$priority"; Result = "FAILED: $($_.Exception.Message)" })
    }
    $priority++
}

# ---------------------------------------------------------------------------
# Output + verification
# ---------------------------------------------------------------------------
Write-Host "`nSUMMARY" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap

if (-not $WhatIfPreference) {
    Write-Host "Policy scope and mode:" -ForegroundColor Cyan
    Get-DlpCompliancePolicy -Identity $PolicyName |
        Format-List Name, Mode, SharePointLocation, ExchangeLocation, OneDriveLocation, TeamsLocation, EndpointDlpLocation
    Write-Host "Rules:" -ForegroundColor Cyan
    Get-DlpComplianceRule -Policy $PolicyName | Sort-Object Priority |
        Format-Table Priority, Name, BlockAccess, BlockAccessScope, NotifyAllowOverride, ReportSeverityLevel -AutoSize
}

if ($results.Result -match 'FAILED') {
    Write-Host "One or more rules failed. Create the failed rule(s) in the portal using the table in guide Phase 6.2, then re-run this script to verify." -ForegroundColor Yellow
}
Disconnect-ExchangeOnline -Confirm:$false
