<#
.SYNOPSIS
    Phase 1 of the KRU Purview pilot: creates the pilot users, the control user, assigns
    Microsoft 365 E5, and creates the dynamic administrative unit AU-KRU-Pilot.

.DESCRIPTION
    - Idempotent: anything that already exists is reported and skipped, so it is safe to re-run.
    - Supports -WhatIf: run it with -WhatIf first to see exactly what it would change.
    - Zero stored credentials: interactive sign-in; user passwords are generated at run time,
      shown once on screen and never written to disk. Copy them to a password manager.

.REQUIREMENTS
    Modules (install outside OneDrive, see guide Appendix E):
        Microsoft.Graph.Authentication, Microsoft.Graph.Users,
        Microsoft.Graph.Users.Actions, Microsoft.Graph.Identity.DirectoryManagement
    Role: Global Administrator (or User Administrator + License Administrator + Privileged Role Administrator)

.EXAMPLE
    .\New-KruPilotIdentities.ps1 -ControlDomain <dev-tenant> -WhatIf     # preview, changes nothing
    .\New-KruPilotIdentities.ps1 -ControlDomain <dev-tenant>             # create
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $PilotDomain   = 'm365.kingsruleusa.com',
    [Parameter(Mandatory)] [string] $ControlDomain,   # a verified domain OUTSIDE the pilot, for the control user
    [string] $UsageLocation = 'US',
    [string] $SkuPattern    = 'SPE_E5*',          # Microsoft 365 E5 SKU part number(s)
    [string] $AdminUnitName = 'AU-KRU-Pilot'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Lab identities (edit here only if you change the design)
# ---------------------------------------------------------------------------
$Users = @(
    @{ Nick = 'purview.hr';      Domain = $PilotDomain;   Given = 'Purview'; Surname = 'HR';      Display = 'Purview HR Manager';   Dept = 'HR';      Role = 'Pilot' }
    @{ Nick = 'purview.finance'; Domain = $PilotDomain;   Given = 'Purview'; Surname = 'Finance'; Display = 'Purview Finance User'; Dept = 'Finance'; Role = 'Pilot' }
    @{ Nick = 'purview.control'; Domain = $ControlDomain; Given = 'Purview'; Surname = 'Control'; Display = 'Purview Control User'; Dept = 'Lab';     Role = 'Control' }
)
$EscapedDomain = [regex]::Escape($PilotDomain)
$AuRule        = "(user.userPrincipalName -match `"@$EscapedDomain`$`")"

function New-LabPassword {
    # 20 chars, guaranteed upper, lower, digit and symbol; generated in memory only
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#$%^&*-_=+?')
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = { param($s) $b = [byte[]]::new(4); $rng.GetBytes($b); $s[[BitConverter]::ToUInt32($b, 0) % $s.Length] }
    $chars = foreach ($s in $sets) { & $pick $s }
    $all   = -join $sets
    $chars += 1..16 | ForEach-Object { & $pick $all }
    -join ($chars | Sort-Object { Get-Random })
}

# ---------------------------------------------------------------------------
# Connect (browser sign-in, avoids the Windows broker error seen in readiness)
# ---------------------------------------------------------------------------
Set-MgGraphOption -DisableLoginByWAM $true
Connect-MgGraph -NoWelcome -Scopes 'User.ReadWrite.All', 'Organization.Read.All', 'AdministrativeUnit.ReadWrite.All', 'Domain.Read.All'

$results = [System.Collections.Generic.List[object]]::new()
$secrets = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
foreach ($d in @($PilotDomain, $ControlDomain) | Select-Object -Unique) {
    $dom = Get-MgDomain -DomainId $d -ErrorAction SilentlyContinue
    if (-not $dom -or -not $dom.IsVerified) { throw "Domain '$d' is not a verified domain in this tenant. Stopping." }
}

$sku = Get-MgSubscribedSku -All | Where-Object SkuPartNumber -like $SkuPattern | Select-Object -First 1
if (-not $sku) { throw "No SKU matching '$SkuPattern' found. Run Get-MgSubscribedSku | Select SkuPartNumber to see what the tenant has." }
$free = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
Write-Host "Licence: $($sku.SkuPartNumber)  free seats: $free" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 2. Users + licences
# ---------------------------------------------------------------------------
foreach ($u in $Users) {
    $upn      = "$($u.Nick)@$($u.Domain)"
    $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property Id, UserPrincipalName, AssignedLicenses, UsageLocation -ErrorAction SilentlyContinue

    if ($existing) {
        $results.Add([pscustomobject]@{ Object = $upn; Action = 'User exists'; Result = 'Skipped' })
        $userId = $existing.Id
    }
    elseif ($PSCmdlet.ShouldProcess($upn, 'Create user')) {
        $pwd = New-LabPassword
        $new = New-MgUser -AccountEnabled -UserPrincipalName $upn -MailNickname $u.Nick `
            -DisplayName $u.Display -GivenName $u.Given -Surname $u.Surname -Department $u.Dept `
            -UsageLocation $UsageLocation `
            -PasswordProfile @{ Password = $pwd; ForceChangePasswordNextSignIn = $false }
        $userId = $new.Id
        $secrets.Add([pscustomobject]@{ UserPrincipalName = $upn; TemporaryPassword = $pwd })
        $results.Add([pscustomobject]@{ Object = $upn; Action = "Create user ($($u.Role))"; Result = 'Done' })
    }
    else { continue }

    if (-not $userId) { continue }
    $hasSku = (Get-MgUser -UserId $userId -Property AssignedLicenses).AssignedLicenses.SkuId -contains $sku.SkuId
    if ($hasSku) {
        $results.Add([pscustomobject]@{ Object = $upn; Action = "Licence $($sku.SkuPartNumber)"; Result = 'Already assigned' })
    }
    elseif ($free -le 0) {
        $results.Add([pscustomobject]@{ Object = $upn; Action = "Licence $($sku.SkuPartNumber)"; Result = 'NO FREE SEAT - assign later' })
    }
    elseif ($PSCmdlet.ShouldProcess($upn, "Assign $($sku.SkuPartNumber)")) {
        Set-MgUserLicense -UserId $userId -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() | Out-Null
        $free--
        $results.Add([pscustomobject]@{ Object = $upn; Action = "Licence $($sku.SkuPartNumber)"; Result = 'Done' })
    }
}

# ---------------------------------------------------------------------------
# 3. Dynamic administrative unit
# ---------------------------------------------------------------------------
$au = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '$AdminUnitName'" -All | Select-Object -First 1
if ($au) {
    $results.Add([pscustomobject]@{ Object = $AdminUnitName; Action = 'Admin unit exists'; Result = 'Skipped (check its rule manually)' })
}
elseif ($PSCmdlet.ShouldProcess($AdminUnitName, "Create dynamic admin unit with rule $AuRule")) {
    $au = New-MgDirectoryAdministrativeUnit -BodyParameter @{
        displayName                   = $AdminUnitName
        description                   = "Purview pilot boundary: all users on @$PilotDomain"
        membershipType                = 'Dynamic'
        membershipRule                = $AuRule
        membershipRuleProcessingState = 'On'
    }
    $results.Add([pscustomobject]@{ Object = $AdminUnitName; Action = "Create dynamic AU: $AuRule"; Result = 'Done' })
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
Write-Host "`nSUMMARY" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap

if ($secrets.Count) {
    Write-Host "TEMPORARY PASSWORDS - copy into your password manager now. They are not saved anywhere." -ForegroundColor Yellow
    $secrets | Format-Table -AutoSize
    Read-Host 'Press Enter once you have saved them (the screen will be cleared)'
    Clear-Host
    $secrets.Clear()
}

Write-Host "Next: dynamic membership can take a few minutes. Check with:" -ForegroundColor Cyan
Write-Host "  Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId '$($au.Id)' -All | ForEach-Object { `$_.AdditionalProperties.userPrincipalName }"
