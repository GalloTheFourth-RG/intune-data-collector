# Copilot Instructions — Intune Data Collector

## Quick Context for Copilot

This is a **public**, customer-facing PowerShell script that collects Microsoft Intune device management data via the Microsoft Graph Export API and REST API. It produces a portable ZIP of JSON files consumed by the private **intune-evidence-pack** repo.

**Two-repo architecture:**
- **intune-data-collector** (public, this repo) — Customer runs this. Read-only data collection from Graph API.
- **intune-evidence-pack** (private) — Ingests the collection ZIP offline. Performs all analysis, scoring, and HTML report generation.

**Single script**: `Collect-IntuneData.ps1` (~600 lines). No build system — runs directly.

---

## Architecture

1. **Authentication** — `Microsoft.Graph.Authentication` module, `Connect-MgGraph` with device management and policy read scopes
2. **Batch 1** (10 reports) — Device inventory, compliance, config profiles, compliance trend
3. **Batch 2** (up to 14 reports) — Apps, security (Defender/malware/firewall), Autopilot, enrollment, Windows Updates
4. **Batch 3** (up to 13 reports) — Endpoint Analytics (startup, app, resource, battery, anomalies), co-management, GP migration
5. **Direct API** — Conditional Access policies (not an export report)
6. **Package** — JSON files + `metadata.json` → ZIP

### Graph Export API Pattern

All Intune reports use the export jobs API:
- `POST /beta/deviceManagement/reports/exportJobs` to create a job
- `GET .../exportJobs('id')` to poll for completion
- Download the resulting ZIP → extract CSV → parse to objects

### Batch Parallel System

Reports are submitted in 3 batches with:
- **Intra-batch pacing**: 500ms between job submissions, 2s cooldown every 5 jobs
- **Concurrent polling**: All jobs in a batch polled simultaneously
- **Inter-batch cooldown**: 5s between batches to avoid cascading 429s
- **Throttling limits**: 100 req/tenant/min, 8/user/min, 48/app/min

---

## Critical Coding Patterns

### Strict Mode
`Set-StrictMode -Version Latest` — all variables must be initialized, property access on `$null` throws.

### Read-Only
The script **never creates, modifies, or deletes** any Intune resources.

### Graph Response Duality
`Invoke-MgGraphRequest` returns either `IDictionary` (Hashtable) or `PSCustomObject` depending on context. The `Get-ResponseValue` helper handles both:
```powershell
function Get-ResponseValue {
    param($Response, [string]$Name)
    if ($Response -is [System.Collections.IDictionary]) {
        if ($Response.ContainsKey($Name)) { return $Response[$Name] }
    }
    if ($Response.PSObject.Properties.Match($Name).Count -gt 0) {
        return $Response.$Name
    }
    return $null
}
```

### Rate Limiting
- `Submit-ExportJob`: Retries on 429 with exponential backoff (2s, 4s, 8s)
- `Invoke-GraphPagedRequest`: Handles `@odata.nextLink` pagination with retry
- Inter-batch cooldowns prevent cascading throttle across endpoint categories

### PS 5.1 Compatibility
- No Unicode chars in double-quoted strings (use `[OK]`, `[WARN]`, `[WAIT]`)
- No `??` or `?.` operators
- Use `if ($null -ne $x)` for explicit null checks

### Error Resilience
Each report/endpoint is independently try/caught. Missing permissions (403), unavailable endpoints (404), or throttling (429) produce warnings — never crashes.

---

## Data Keys (output JSON filenames)

| Key | Report/API | Batch |
|-----|-----------|-------|
| `devices` | DevicesWithInventory | 1 |
| `device-health` | WindowsDeviceHealthAttestationReport | 1 |
| `tpm-attestation` | TpmAttestationStatus | 1 |
| `compliance-status` | DeviceCompliance | 1 |
| `compliance-policies` | NonCompliantCompliancePoliciesAggregate | 1 |
| `devices-without-policy` | DevicesWithoutCompliancePolicy | 1 |
| `noncompliant-settings` | NoncompliantDevicesAndSettings | 1 |
| `config-aggregate` | ConfigurationPolicyAggregate | 1 |
| `config-non-compliant` | NonCompliantConfigurationPoliciesAggregateWithPF | 1 |
| `compliance-trend` | DeviceComplianceTrend | 1 |
| `apps-list` | AllAppsList | 2 |
| `apps-install-status` | AppInstallStatusAggregate | 2 |
| `apps-discovered` | AppInvAggregate | 2 |
| `defender-agents` | DefenderAgents | 2 |
| `unhealthy-defender` | UnhealthyDefenderAgents | 2 |
| `malware` | ActiveMalware | 2 |
| `firewall-status` | FirewallStatus | 2 |
| `epm-elevations` | EpmElevationReportElevationEvent | 2 |
| `autopilot-status` | AutopilotV2DeploymentStatus | 2 |
| `enrollment-activity` | EnrollmentActivity | 2 |
| `update-*-summary` | Driver/Feature/QualityUpdatePolicyStatusSummary | 2 |
| `ea-*` | EAStartupPerf*, EAAppPerformance, etc. | 3 |
| `co-management` | ComanagedDeviceWorkloads | 3 |
| `gp-migration-readiness` | GPAnalyticsSettingMigrationReadiness | 3 |
| `conditional-access` | Direct API (v1.0) | Direct |

---

## Common Tasks

### Adding a new report
1. Add to the appropriate batch list with `Key` and `ReportName`
2. Handle it potentially failing (429, 404)
3. Update README.md collection steps
4. Update the evidence pack to consume the new data key

### Version bumping
Update `$script:ScriptVersion` and `$script:SchemaVersion` at the top of the script, and README.md.

---

## Key Constraints

- **Customer-facing**: Keep output clear and professional
- **Read-only**: Never create, modify, or delete any resources
- **Graceful failures**: Missing permissions or unavailable endpoints warn, don't crash
- **DryRun mode**: Validates connectivity and permissions without collecting data
- **Throttle-aware**: Must respect Intune's stricter rate limits with proper pacing
