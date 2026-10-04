<#
.SYNOPSIS
    Phase 5 of the KRU Purview pilot: creates the custom sensitive information type
    SIT-KRU-EmployeeID from an XML rule package, then tests it against positive and
    negative (near-miss) samples with Test-DataClassification.

.DESCRIPTION
    Detection design:
      Primary element : regex  \bEMP-\d{6}\b      (EMP- followed by exactly 6 digits)
      Supporting      : keywords within 300 characters: employee id, employee number, staff id, personnel number
      Confidence      : 85 (High)  = regex + keyword
                        65 (Medium)= regex alone
    - Idempotent: updates the rule package if it already exists (same RulePack id).
    - Supports -WhatIf.  Use -TestOnly to re-run just the tests.
    - No stored credentials.

.EXAMPLE
    .\New-KruEmployeeIdSit.ps1 -AdminUPN admin@<dev-tenant> -WhatIf
    .\New-KruEmployeeIdSit.ps1 -AdminUPN admin@<dev-tenant>
    .\New-KruEmployeeIdSit.ps1 -AdminUPN admin@<dev-tenant> -TestOnly     # after a few minutes, if the first test ran too early
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $AdminUPN,
    [switch] $TestOnly
)
$ErrorActionPreference = 'Stop'

# Fixed GUIDs so re-runs update the same package instead of creating duplicates.
$RulePackId = 'b6f2a0c4-6e1d-4f3a-9c2b-7d4e1a9f3c51'
$PublisherId = '0c7e5d21-3a8b-4b9e-8f12-5a6d9e2c4b70'
$EntityId    = 'e3a9c7f1-2b4d-4c6e-9a8f-1d2e3f4a5b6c'
$SitName     = 'SIT-KRU-EmployeeID'

$xml = @"
<?xml version="1.0" encoding="utf-16"?>
<RulePackage xmlns="http://schemas.microsoft.com/office/2011/mce">
  <RulePack id="$RulePackId">
    <Version major="1" minor="0" build="0" revision="0"/>
    <Publisher id="$PublisherId"/>
    <Details defaultLangCode="en-us">
      <LocalizedDetails langcode="en-us">
        <PublisherName>KRU Purview Pilot</PublisherName>
        <Name>KRU Pilot Rule Package</Name>
        <Description>Custom sensitive information types for the KRU Purview pilot.</Description>
      </LocalizedDetails>
    </Details>
  </RulePack>
  <Rules>
    <Entity id="$EntityId" patternsProximity="300" recommendedConfidence="85">
      <Pattern confidenceLevel="85">
        <IdMatch idRef="Regex_kru_employee_id"/>
        <Match idRef="Keyword_kru_employee_id"/>
      </Pattern>
      <Pattern confidenceLevel="65">
        <IdMatch idRef="Regex_kru_employee_id"/>
      </Pattern>
    </Entity>
    <Regex id="Regex_kru_employee_id">\bEMP-\d{6}\b</Regex>
    <Keyword id="Keyword_kru_employee_id">
      <Group matchStyle="word">
        <Term>employee id</Term>
        <Term>employee number</Term>
        <Term>staff id</Term>
        <Term>personnel number</Term>
      </Group>
    </Keyword>
    <LocalizedStrings>
      <Resource idRef="$EntityId">
        <Name default="true" langcode="en-us">$SitName</Name>
        <Description default="true" langcode="en-us">KRU employee ID: EMP- followed by 6 digits. High confidence when an employee-ID keyword is within 300 characters.</Description>
      </Resource>
    </LocalizedStrings>
  </Rules>
</RulePackage>
"@

Connect-IPPSSession -UserPrincipalName $AdminUPN -ShowBanner:$false -DisableWAM

# ---------------------------------------------------------------------------
# 1. Create or update the rule package
# ---------------------------------------------------------------------------
if (-not $TestOnly) {
    $bytes    = [System.Text.Encoding]::Unicode.GetBytes($xml)
    $existing = Get-DlpSensitiveInformationTypeRulePackage -ErrorAction SilentlyContinue |
                Where-Object { $_.Identity -match $RulePackId -or $_.RuleCollectionName -eq 'KRU Pilot Rule Package' }

    if ($existing) {
        if ($PSCmdlet.ShouldProcess('KRU Pilot Rule Package', 'Update rule package (SIT-KRU-EmployeeID)')) {
            Set-DlpSensitiveInformationTypeRulePackage -FileData $bytes -Confirm:$false
            Write-Host "Rule package updated." -ForegroundColor Green
        }
    }
    elseif ($PSCmdlet.ShouldProcess('KRU Pilot Rule Package', 'Create rule package with SIT-KRU-EmployeeID')) {
        New-DlpSensitiveInformationTypeRulePackage -FileData $bytes | Out-Null
        Write-Host "Rule package created." -ForegroundColor Green
    }

    if ($WhatIfPreference) { Disconnect-ExchangeOnline -Confirm:$false; return }

    Get-DlpSensitiveInformationType -Identity $SitName |
        Format-List Name, Publisher, RecommendedConfidence, Description
}

# ---------------------------------------------------------------------------
# 2. Test: positive, near-miss and over-long samples (TC-06)
# ---------------------------------------------------------------------------
$tests = @(
    @{ Case = 'Positive: ID + keyword';      Expect = 'Match (85)';  Text = 'Employee ID: EMP-104233 assigned to the Operations team.' }
    @{ Case = 'Positive: ID without keyword'; Expect = 'Match (65)';  Text = 'Reference EMP-118790 in the attached file.' }
    @{ Case = 'Near-miss: 5 digits';          Expect = 'No match';    Text = 'Campaign code EMP-12345 for the press release.' }
    @{ Case = 'Near-miss: 7 digits';          Expect = 'No match';    Text = 'Employee ID: EMP-1042339 (invalid length).' }
)

Write-Host "`nTC-06 detection tests (new SITs can take a few minutes to become testable)" -ForegroundColor Cyan
$rows = foreach ($t in $tests) {
    try {
        $r    = Test-DataClassification -TextToClassify $t.Text
        $hits = @($r.ClassificationResults | Where-Object { "$_" -match 'KRU-EmployeeID' -or $_.ClassificationName -eq $SitName })
        $conf = ($hits | ForEach-Object { $_.ConfidenceLevel }) -join ','
        [pscustomobject]@{ Case = $t.Case; Expected = $t.Expect; Actual = $(if ($hits) { "Match ($conf)" } else { 'No match' }) }
    }
    catch {
        [pscustomobject]@{ Case = $t.Case; Expected = $t.Expect; Actual = "Test error: $($_.Exception.Message)" }
    }
}
$rows | Format-Table -AutoSize -Wrap

# Raw engine output for the first positive sample, so the result is visible even if
# Microsoft changes the shape of Test-DataClassification's output.
Write-Host "Raw classification results for: '$($tests[0].Text)'" -ForegroundColor DarkCyan
(Test-DataClassification -TextToClassify $tests[0].Text).ClassificationResults | Format-List

Write-Host "If every row says 'No match' straight after creation, wait 5-10 minutes and run with -TestOnly." -ForegroundColor Yellow
Disconnect-ExchangeOnline -Confirm:$false
