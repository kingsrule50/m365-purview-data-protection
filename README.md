# Microsoft Purview Data Protection Pilot: Scoped Labels, DLP and Retention in a Shared Tenant

A hands-on Microsoft Purview pilot that protects HR and payment-card data for a fictional organisation, **KRU**, inside a **shared Microsoft 365 development tenant**. The main constraint was that nothing could affect any other user, mailbox, OneDrive or site in that tenant.

All of the configuration that could be scripted was done in **PowerShell**. Every phase was tested with written test cases, and the result is proven with a **read-only scope-verification script**.

> All data in this lab is fictional. Card numbers are public test numbers that pass the Luhn check. No real people or accounts are involved. Credentials are never stored in code.

---

## Contents
- [Scenario and requirements](#scenario-and-requirements)
- [Architecture](#architecture)
- [Key design decisions](#key-design-decisions)
- [What was built](#what-was-built)
- [Automation (PowerShell)](#automation-powershell)
- [Test results](#test-results)
- [Evidence](#evidence)
- [Findings and lessons learned](#findings-and-lessons-learned)
- [Change control and safety](#change-control-and-safety)
- [Teardown](#teardown)
- [Skills demonstrated](#skills-demonstrated)

---

## Scenario and requirements

KRU is the pilot organisation (users on `@m365.kingsruleusa.com`). It shares a development tenant with other administrators' work. Its HR and Finance teams store employee records and card-payment documents in SharePoint.

| ID | Requirement |
|---|---|
| R1 | Classify content in four tiers. Every new document must carry a label, and lowering a label requires a written justification. |
| R2 | Detect payment card data. Warn on small amounts (1–4 cards) and block external sharing of bulk card data (5 or more). |
| R3 | Detect KRU employee IDs (`EMP-` + 6 digits). Warn users, and allow external sharing only with a business justification. |
| R4 | Documents labelled **KRU Highly Confidential** are never shared externally, whatever they contain. |
| R5 | Keep HR and finance records for 1 year. Deleted items stay recoverable. |
| R6 | All labelling and DLP activity is auditable and investigable. |
| R7 | **Blast radius:** nothing outside the pilot domain and the pilot site is affected. |

---

## Architecture

![Architecture](architecture.png)

| Component | Name | Scope |
|---|---|---|
| Dynamic administrative unit | `AU-KRU-Pilot` | Rule: `(user.userPrincipalName -match "@m365\.kingsruleusa\.com$")` |
| Pilot users | `purview.hr`, `purview.finance` @m365.kingsruleusa.com | Members of the AU (Microsoft 365 E5) |
| Control user | `purview.control@<dev-tenant>` | **Outside** the AU, used for negative tests |
| SharePoint site | `KRU-Purview-Pilot` (HR-Records, Finance-Records, Public-Content) | Least-privilege membership |
| Sensitivity labels | KRU Public / Internal / Confidential / Highly Confidential | Published only to `AU-KRU-Pilot` |
| Custom SIT | `SIT-KRU-EmployeeID` | XML rule package |
| DLP policy | `DLP-PILOT-KRU-PCI-EmployeeID` | SharePoint: pilot site only. Exchange, OneDrive, Teams and Devices all **off** |
| Retention policy | `RET-PILOT-KRU-Records-1Y` | Pilot site only. Retain 1 year, then do nothing. **No Preservation Lock** |

---

## Key design decisions

**1. Two different scoping methods, each chosen on purpose.**
- **Labels are scoped by *who*:** the label policy targets a **dynamic administrative unit** built from the pilot domain. Any new user on `@m365.kingsruleusa.com` joins the pilot automatically, and nobody else can.
- **DLP and retention are scoped by *where*:** both policies target exactly **one SharePoint site**, with every other location turned off. Because the protection belongs to the data location, a user's OneDrive stays out of scope even when that user is in the pilot (proven by TC-12).

**2. A control user for negative testing.** It isn't enough to show that pilot users get the labels; you also have to show that everyone else doesn't. `purview.control` sits outside the AU and must see no KRU labels (TC-02).

**3. Tiered DLP rules with priority order.** The most restrictive rule is evaluated first:

| Priority | Rule | Condition | Action | Severity |
|---|---|---|---|---|
| 0 | R04-HighlyConfidential-External | Label = KRU Highly Confidential | Block external access, no override | High |
| 1 | R02-PCI-HighVolume | Credit Card Number ×5+, high confidence | Block external access, no override | High |
| 2 | R03-EmployeeID | SIT-KRU-EmployeeID ×1+, high confidence | Block external access, **override with justification** | Medium |
| 3 | R01-PCI-LowVolume | Credit Card Number ×1–4, high confidence | Policy tip and audit only | Low |

R04 is driven by the **label**, not the content: the board memo deliberately contains no sensitive information types.

**4. Simulation before enforcement.** The DLP policy ran in `TestWithNotifications` mode first. The switch to `Enable` was a separate, recorded change (CHG-PV-002), made only after the simulation results and the scope proof were reviewed.

**5. Custom SIT with confidence levels.**
- Primary element: regex `\bEMP-\d{6}\b`
- Supporting keywords within 300 characters: *employee id, employee number, staff id, personnel number*
- Regex with a keyword → **85 (High)**. Regex alone → **65 (Medium)**. DLP rules require **High**, which reduces false positives.

---

## What was built

| Phase | Work | Method |
|---|---|---|
| 0 | Readiness check (roles, domain, licences, audit, existing policies) | `Invoke-PurviewReadiness.ps1` |
| 0 | Tenant baseline cleanup (CHG-PV-000, approved by the tenant owner) | Portal |
| 1 | Pilot and control users, E5 licences, dynamic AU | `New-KruPilotIdentities.ps1` |
| 2 | Pilot SharePoint site, libraries, least-privilege membership | Portal |
| 3 | Four sensitivity labels with content markings | `New-KruPilotLabels.ps1` |
| 3 | Label policy scoped to AU-KRU-Pilot (mandatory, default KRU Internal, downgrade justification) | Portal |
| 4 | Retention policy (1 site, 1 year, no lock) | Portal |
| 5 | Custom SIT from an XML rule package, plus detection tests | `New-KruEmployeeIdSit.ps1` |
| 6 | Tiered DLP policy in simulation | `New-KruPilotDlp.ps1` |
| 8 | Test uploads and simulation review | Portal / Activity explorer |
| 9 | Enforcement (CHG-PV-002) | `Set-DlpCompliancePolicy -Mode Enable` |
| 11 | Read-only scope proof | `Verify-PurviewPilotScope.ps1` |

---

## Automation (PowerShell)

All scripts are **idempotent** (safe to re-run: existing objects are reported and skipped), support **`-WhatIf`**, use **interactive sign-in only**, and store **no credentials**.

| Script | Purpose |
|---|---|
| [`Enable-LabModules.ps1`](scripts/Enable-LabModules.ps1) | Loads the modules from `C:\PSModules` and strips OneDrive-synced module paths, which fixes *"The cloud file provider is not running"* |
| [`Invoke-PurviewReadiness.ps1`](scripts/Invoke-PurviewReadiness.ps1) | Read-only pre-flight checks |
| [`New-KruPilotIdentities.ps1`](scripts/New-KruPilotIdentities.ps1) | Users, licences and the dynamic AU. Passwords are generated in memory, shown once, then cleared |
| [`New-KruPilotLabels.ps1`](scripts/New-KruPilotLabels.ps1) | Four labels with headers, footers and a watermark, in priority order |
| [`New-KruEmployeeIdSit.ps1`](scripts/New-KruEmployeeIdSit.ps1) | XML rule package plus `Test-DataClassification` positive and near-miss tests |
| [`New-KruPilotDlp.ps1`](scripts/New-KruPilotDlp.ps1) | Tiered DLP policy and rules, simulation only, pilot site only |
| [`Verify-PurviewPilotScope.ps1`](scripts/Verify-PurviewPilotScope.ps1) | **Read-only** proof of scope for labels, AU, DLP, retention and auto-labelling. Exports a CSV and a transcript to `evidence/` |

Tenant-specific values (admin account, site URL, alert mailbox, control domain) are **required parameters**, never defaults, so a script can't run against the wrong tenant by accident. In each new PowerShell 7 window:
```powershell
Set-Location "$HOME\Downloads\purview-lab"
.\scripts\Enable-LabModules.ps1

$admin = 'admin@<dev-tenant>'
.\scripts\Invoke-PurviewReadiness.ps1  -AdminUPN $admin
.\scripts\New-KruPilotIdentities.ps1   -ControlDomain '<dev-tenant>' -WhatIf   # preview first, then run without -WhatIf
.\scripts\New-KruPilotLabels.ps1       -AdminUPN $admin
.\scripts\New-KruEmployeeIdSit.ps1     -AdminUPN $admin
.\scripts\New-KruPilotDlp.ps1          -AdminUPN $admin -SiteUrl 'https://<dev-tenant>.sharepoint.com/sites/KRU-Purview-Pilot' -AlertRecipient 'secops@<dev-tenant>'
.\scripts\Verify-PurviewPilotScope.ps1 -AdminUPN $admin
```

---

## Test results

| TC | Req | Test | Expected | Result |
|---|---|---|---|---|
| TC-01 | R1 | Pilot user opens Word → Sensitivity | Four KRU labels | ✅ Pass |
| TC-02 | R7 | Control user opens Word → Sensitivity | **No** KRU labels (no shield shown) | ✅ Pass |
| TC-03 | R1 | New document as pilot user | KRU Internal by default, label mandatory | ✅ Pass |
| TC-04 | R1 | Apply KRU Confidential | Header and footer markings | ✅ Pass |
| TC-05 | R1/R6 | Lower Confidential → Public | Justification prompt | ✅ Pass |
| TC-06 | R3 | `Test-DataClassification`: ID + keyword / ID only / 5 digits / 7 digits | 85 / 65 / no match / no match | ✅ Pass |
| TC-07 | R2 | Single-card refund (1 card) | R01 match, tip only; external guest **can** open it | ✅ Pass (simulation + enforced) |
| TC-08 | R2 | Chargeback batch (6 cards) | R02 match; external guest **blocked**; alert raised | ✅ Pass (enforced) |
| TC-09 | R3 | Employee roster (5 IDs) | Share blocked; override with justification offered and used; guest can then open it | ✅ Pass (enforced) |
| TC-10 | R4 | Board memo labelled Highly Confidential, with no SITs | Share blocked by the label, **no override** offered | ✅ Pass (enforced) |
| TC-11 | R7 | Press release with near-miss `EMP-12345` | **No match**; shares and opens externally (false-positive check) | ✅ Pass (simulation + enforced) |
| TC-12 | R7 | Same chargeback file in a pilot user's **OneDrive** | **No match** (OneDrive out of scope) | ✅ Pass |
| TC-13 | R5 | Delete a file from the pilot site | Copy kept in Preservation Hold Library | ✅ Pass |
| TC-14 | R6 | Activity explorer / audit | DLP matches and the label downgrade traceable, including the justification text | ✅ Pass |
| TC-15 | R7 | `Verify-PurviewPilotScope.ps1` | All checks PASS | ✅ Pass (17/17) |

**Simulation summary:** 4 of 4 expected rule matches (R01–R04) on the correct files. **0 false positives** (TC-11). **0 out-of-scope matches** (TC-12).

**Enforcement summary**, with an external Gmail guest as the outsider:

| File | Rule | Outcome |
|---|---|---|
| Finance-Refund-Single-Card | R01 | ✅ Guest can open it (warning only) |
| Finance-Chargeback-Batch | R02 | ⛔ Guest blocked, alert raised |
| HR-Employee-Roster | R03 | ⛔ Blocked → override with justification → guest can open it |
| Board-Acquisition-Memo | R04 | ⛔ Blocked, no override offered |
| Public-Press-Release | none | ✅ Guest can open it |

**Result: 15 of 15 test cases passed.**

---

## Evidence

Screenshots are in [`screenshots/`](screenshots/). Each one proves a test case or a design decision.

| # | Test | Shows |
|---|---|---|
| [01](screenshots/01-au-kru-pilot-dynamic-members.png) | Setup | AU-KRU-Pilot dynamic members: only pilot-domain users |
| [02](screenshots/02-site-membership-least-privilege.png) | Setup | Pilot site membership: owner plus 2 members with Edit, no visitors |
| [03](screenshots/03-label-policy-scoped-to-au.png) | Setup | Label policy scoped to **AU-KRU-Pilot**: mandatory, default KRU Internal, downgrade justification |
| [04](screenshots/04-retention-policy-one-site.png) | Setup | Retention policy: 1 year, no Preservation Lock (site scope proven in 22) |
| [05](screenshots/05-tc01-pilot-user-sees-kru-labels.png) | TC-01 | Pilot user sees the four KRU labels |
| [06](screenshots/06-tc02-control-user-no-labels.png) | TC-02 | Control user outside the AU: **no** sensitivity labels |
| [07](screenshots/07-tc04-confidential-header.png) | TC-04 | KRU Confidential applies its header marking |
| [08](screenshots/08-tc05-downgrade-justification.png) | TC-05 | Lowering a label requires a justification |
| [09](screenshots/09-tc06-custom-sit-tests.png) | TC-06 | Custom SIT tests: 85 / 65 / no match / no match |
| [10](screenshots/10-dlp-policy-created-simulation.png) | Setup | Tiered DLP policy and rules created by script, simulation mode, 1 site only |
| [11a](screenshots/11a-policy-tips-hr-records.png) | Simulation | Policy tips: roster and board memo flagged, performance review clean |
| [11b](screenshots/11b-policy-tips-finance-records.png) | Simulation | Policy tips on both finance files |
| [11c](screenshots/11c-tc12-onedrive-out-of-scope-no-tip.png) | TC-12 | Same chargeback file in OneDrive an hour later: **no tip** (out of scope) |
| [12](screenshots/12-dlp-simulation-matches-by-rule.png) | TC-07/08/09/10 | Activity explorer: DLP matches by rule (R01–R04, plus the stray zip finding) |
| [13](screenshots/13-tc13-preservation-hold-library.png) | TC-13 | Deleted file kept in the Preservation Hold Library |
| [14a](screenshots/14a-tc14-activity-explorer-downgrade.png) | TC-14 | Downgrade record: `LabelDowngraded`, Confidential → Public, justification captured |
| [14b](screenshots/14b-tc14-unified-audit-justification.png) | TC-14 | Same event in the unified audit log (`SensitivityLabelJustificationText`) |
| [15](screenshots/15-tc07-guest-can-open-single-card.png) | TC-07 | External guest **can** open the single-card file (R01 is a warning only) |
| [16a](screenshots/16a-tc08-guest-blocked.png) | TC-08 | External guest **blocked** from the chargeback batch |
| [16b](screenshots/16b-tc08-dlp-enforced-match.png) | TC-08 | Enforced match: mode `Enable`, `SPAccessTimeControl`, NotifyUser, GenerateAlert |
| [17](screenshots/17-dlp-alert-triage-benign-positive.png) | Response | DLP alert triaged: assigned, **Benign positive**, resolved |
| [18](screenshots/18-tc09-share-blocked-in-dialog.png) | TC-09 | Share dialog blocks external sharing of the roster |
| [19](screenshots/19-tc09-override-submitted.png) | TC-09 | Override submitted with justification `TC-09 Vendor Payroll` |
| [20](screenshots/20-tc10-r04-policy-tip-in-word.png) | TC-10 | R04 policy tip in Word: Highly Confidential can't be shared outside KRU |
| [21](screenshots/21-tc10-no-override-label-driven.png) | TC-10 | Board memo: label-driven block, **no override** option |
| [22](screenshots/22-tc15-scope-proof-all-pass.png) | TC-15 | Scope proof: **17/17 PASS**, no tenant-wide impact |

Script output (CSV and transcript) is in [`evidence/`](evidence/).

---

## Findings and lessons learned

1. **DLP inspects inside archives.** A `.zip` of the lab kit was uploaded to the pilot site by mistake. DLP opened it and matched **R02** and **R03** on the documents inside, within the short time before the file was deleted. Zipping a file doesn't get it past the policy, and deleting it quickly doesn't erase the audit record.
2. **Where Purview stores admin-unit scoping.** `Get-LabelPolicy` holds the AU's object ID in **`PolicyRBACScopes`** (and `PolicyConstraints`), not in a property called "AdminUnits". `ExchangeLocation = All` on an AU-scoped policy means *all users inside the AU*. The scope-proof script was rewritten to search every property for the AU's object ID.
3. **Location objects print their display name.** `SharePointLocation` displays `KRU-Purview-Pilot`, while the URL is in `.Name`. The verification logic checks both and also requires **exactly one** site.
4. **A cmdlet can report success when a rule failed.** `New-DlpComplianceRule` rejected `GenerateAlert = SiteAdmin` (it must be an SMTP address), but the script still reported "Done". Fixed by adding `-ErrorAction Stop` per rule and a FAILED status in the summary.
5. **Remote "not found" errors don't trigger `try/catch`** in Exchange Online PowerShell sessions. Use `-ErrorAction SilentlyContinue` and check for `$null`.
6. **Separation of duties in Purview.** Even a Global Admin can't view the content of a matched file without the **Data Classification Content Viewer** role. Admins see metadata, and content access is a separate, auditable assignment.
7. **Timing matters:** new accounts took about a day to resolve in SharePoint, DLP distribution took about an hour, and a label applied after upload took several minutes to show a policy tip. Test plans need to allow for these delays.
8. **Tooling:** the WAM broker sign-in failed → used `-DisableWAM` / `Set-MgGraphOption -DisableLoginByWAM $true`. Modules in a OneDrive-synced Documents folder failed → moved them to `C:\PSModules`.
9. **Retention outlives the Recycle bin.** The stray zip was deleted and then removed from the Recycle bin, but two copies remain in the Preservation Hold Library. Content under retention can't be destroyed by end users or site admins, so it's removed only by taking the site out of the retention policy.
10. **Switching to enforce isn't retroactive right away.** Files scanned under simulation weren't blocked straight after the policy reached `Enable` + `Success`. The external guest could still open the chargeback batch. After a small edit forced DLP to re-evaluate the file, the guest was blocked. Plan re-evaluation, or allow time, for existing content at go-live.
11. **Audit records carry the admin unit.** The label-change event is tagged `Admin Units: AU-KRU-Pilot`, so a delegated admin scoped to the AU could investigate KRU activity only.
12. **Audit search ObjectId needs the full URL.** A partial file name returned 0 results. Leaving it blank (user and date only) returned 178. Activity explorer was the faster place to investigate.
13. **Alert triage:** a correct detection of an approved test is a **Benign positive**, not a True positive (a real incident) and not a False positive (a wrong detection). That keeps the incident metrics accurate.
14. **Portal defaults are risky in a shared tenant.** The retention wizard defaulted to *All sites, 7 years, Delete automatically*. Each was changed to *1 site, 1 year, Do nothing* before saving.

---

## Design note: override isn't approval

R03 lets a user override the block by typing a justification. **Nobody approves it**, so an insider could type a plausible reason. That's accepted on purpose for medium-risk data, and controlled like this:

1. **Overrides are allowed by data risk.** Employee IDs (medium) can be overridden for legitimate business needs, such as a payroll vendor. Bulk card data and Highly Confidential documents (high) **can't be overridden at all**.
2. **Every override is recorded and alerted on.** The user, file, time and justification text go into the audit log and Activity explorer, and the rule raises an alert for review.
3. **Insider Risk Management and Adaptive Protection** (production recommendation): DLP matches and overrides feed users' risk scores, and Adaptive Protection automatically applies a stricter, no-override DLP rule to users at elevated risk.
4. **Where real approval is needed:** block without override and handle exceptions through a data-owner-approved process, a dedicated external-sharing site, or an allowed partner-domain list.
5. **Protection that travels with the file:** labels with encryption keep access control after the file leaves the organisation, and access can be revoked.

> In short, an override with justification adds friction and accountability, not approval. Risk tiering decides where it's acceptable, and monitoring and Insider Risk Management cover the insider case.

## Change control and safety

| Change | Description | Approval |
|---|---|---|
| CHG-PV-000 | Remove leftover labels and policies from the shared tenant | Tenant owner |
| CHG-PV-001 | Build the pilot in simulation (Phases 1–8) | Lab owner |
| CHG-PV-002 | Switch DLP from simulation to enforcement | After the simulation review and a passing scope proof |

Guardrails followed throughout:
- **All users** or **All sites** was never selected for any policy.
- No Preservation Lock, so the retention policy can be removed.
- No tenant-wide setting was changed.
- Every script supports `-WhatIf`.
- Rollback for enforcement: `Set-DlpCompliancePolicy -Identity DLP-PILOT-KRU-PCI-EmployeeID -Mode TestWithNotifications`

---

## Teardown

1. Return the DLP policy to simulation, then delete it.
2. Delete the retention policy (possible because it isn't locked). Until it's removed, items in the Preservation Hold Library, including the stray zip, can't be deleted.
3. Delete the label publishing policy, then the four labels.
4. Delete the custom SIT rule package.
5. Delete the pilot site.
6. Remove licences from the three users and delete the users and AU-KRU-Pilot.

---

## Skills demonstrated

- **Microsoft Purview:** sensitivity labels and publishing policies, custom sensitive information types (XML, confidence levels, proximity), tiered DLP with simulation and enforcement, retention, Activity explorer, audit
- **Microsoft Entra ID:** dynamic administrative units, licence assignment, Microsoft Graph PowerShell
- **SharePoint Online:** site design, least-privilege membership, sharing controls
- **PowerShell automation:** idempotent scripts, `-WhatIf`, no stored credentials, read-only verification and evidence export
- **Security engineering practice:** requirement → control → test case traceability, negative testing, blast-radius control in a shared tenant, change management
