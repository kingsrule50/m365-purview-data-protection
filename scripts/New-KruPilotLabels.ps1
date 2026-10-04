<#
.SYNOPSIS
    Phase 3 of the KRU Purview pilot: creates the four KRU sensitivity labels with their
    content markings, in priority order (Public lowest -> Highly Confidential highest).

.DESCRIPTION
    - Idempotent: labels that already exist are reported and skipped.
    - Supports -WhatIf.
    - Labels only. Publishing them to AU-KRU-Pilot is done in the portal (guide step 3.3),
      where the admin-unit picker can be checked visually; the scope-proof script verifies it.
    - No stored credentials (interactive sign-in, browser instead of the Windows broker).

.EXAMPLE
    .\New-KruPilotLabels.ps1 -AdminUPN admin@<dev-tenant> -WhatIf
    .\New-KruPilotLabels.ps1 -AdminUPN admin@<dev-tenant>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $AdminUPN
)
$ErrorActionPreference = 'Stop'

# Created in this order so priority ascends with sensitivity.
$Labels = @(
    @{ Name = 'KRU-LBL-Public';              Display = 'KRU Public';              Tip = 'Approved for public release.'
       Comment = 'Pilot: non-sensitive public content.' }
    @{ Name = 'KRU-LBL-Internal';            Display = 'KRU Internal';            Tip = 'For KRU staff only.'
       Comment = 'Pilot: default label for documents and email.'
       Footer = 'KRU Internal Use Only' }
    @{ Name = 'KRU-LBL-Confidential';        Display = 'KRU Confidential';        Tip = 'Sensitive. Do not share externally without approval.'
       Comment = 'Pilot: HR, finance and other sensitive business data.'
       Header = 'KRU Confidential'; Footer = 'Do Not Share Externally' }
    @{ Name = 'KRU-LBL-HighlyConfidential';  Display = 'KRU Highly Confidential'; Tip = 'Restricted. Never share externally.'
       Comment = 'Pilot: board, M&A and regulated data. DLP rule R04 blocks external sharing.'
       Header = 'KRU Highly Confidential'; Footer = 'Restricted'; Watermark = 'HIGHLY CONFIDENTIAL' }
)

Connect-IPPSSession -UserPrincipalName $AdminUPN -ShowBanner:$false -DisableWAM

$results = [System.Collections.Generic.List[object]]::new()
$existing = @(Get-Label | Select-Object -ExpandProperty Name)

foreach ($l in $Labels) {
    if ($existing -contains $l.Name) {
        $results.Add([pscustomobject]@{ Label = $l.Display; Name = $l.Name; Result = 'Exists - skipped' })
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($l.Name, "Create sensitivity label '$($l.Display)'")) { continue }

    $p = @{
        Name        = $l.Name
        DisplayName = $l.Display
        Tooltip     = $l.Tip
        Comment     = $l.Comment
        ContentType = 'File, Email'
    }
    if ($l.Header)    { $p.ApplyContentMarkingHeaderEnabled = $true; $p.ApplyContentMarkingHeaderText = $l.Header }
    if ($l.Footer)    { $p.ApplyContentMarkingFooterEnabled = $true; $p.ApplyContentMarkingFooterText = $l.Footer }
    if ($l.Watermark) { $p.ApplyWaterMarkingEnabled = $true;         $p.ApplyWaterMarkingText = $l.Watermark }

    New-Label @p | Out-Null
    $markings = @($l.Header, $l.Footer, $l.Watermark | Where-Object { $_ }) -join ' | '
    $results.Add([pscustomobject]@{ Label = $l.Display; Name = $l.Name; Result = "Created  [$markings]" })
}

Write-Host "`nSUMMARY" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap

Write-Host "Current KRU labels by priority:" -ForegroundColor Cyan
Get-Label | Where-Object Name -like 'KRU-LBL-*' | Sort-Object Priority |
    Format-Table DisplayName, Name, Priority -AutoSize

Write-Host "Next: publish them to AU-KRU-Pilot in the portal (guide step 3.3)." -ForegroundColor Cyan
Disconnect-ExchangeOnline -Confirm:$false
