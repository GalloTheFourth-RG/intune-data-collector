# Intune Data Collector

> Version 1.0.0 | March 2026

Collects Microsoft Intune configuration, compliance, security, and device data for offline assessment. Produces a portable ZIP of JSON files that can be shared with your consultant for analysis — **no ongoing access to your tenant required**.

## What It Collects

| Category | Data Source | API |
|----------|------------|-----|
| **Devices** | All managed devices with inventory | Graph Export API |
| **Compliance** | Compliance policies, device status, trends | Graph Export API |
| **Configuration** | Configuration profiles, assignment status | Graph Export API |
| **Apps** | App inventory, install status, discovered apps | Graph Export API |
| **Security** | Defender agents, malware, firewall status | Graph Export API |
| **Autopilot** | Deployment status, profiles | Graph Export API |
| **Endpoint Analytics** | Startup perf, app reliability, resource perf | Graph Export API |
| **Updates** | Feature/quality/driver update status | Graph Export API |
| **Conditional Access** | Policies (read-only) | Graph REST API |
| **Enrollment** | Enrollment failures, activity | Graph Export API |
| **Proactive Remediations** | Script run states, results | Graph Export API |
| **EPM** | Endpoint Privilege Management elevations | Graph Export API |

## Prerequisites

- **PowerShell 5.1+** (or PowerShell 7+)
- **Microsoft.Graph.Authentication** module (`Install-Module Microsoft.Graph.Authentication`)
- **Permissions** — the collecting account needs (read-only):
  - `DeviceManagementManagedDevices.Read.All`
  - `DeviceManagementConfiguration.Read.All`
  - `DeviceManagementApps.Read.All`
  - `DeviceManagementServiceConfig.Read.All`
  - `Policy.Read.All` (for Conditional Access)

## Quick Start

```powershell
# Install prerequisites
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

# Run collection
.\Collect-IntuneData.ps1 -TenantId "your-tenant-id"

# Output: IntuneCollection_<tenant>_<date>.zip
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-TenantId` | String | **Required.** Azure AD / Entra ID tenant ID |
| `-OutputPath` | String | Output directory (default: current directory) |
| `-SkipEndpointAnalytics` | Switch | Skip Endpoint Analytics reports (faster) |
| `-SkipApps` | Switch | Skip app inventory collection |
| `-SkipSecurity` | Switch | Skip Defender/firewall/malware reports |
| `-DaysBack` | Int | Days of historical data for trends (default: 30) |
| `-DryRun` | Switch | Validate permissions without collecting data |

## Output Schema

The ZIP contains JSON files following schema version 1.0:

```
IntuneCollection_<tenant>_<date>/
├── metadata.json              # Collection metadata, schema version, parameters
├── devices.json               # DevicesWithInventory report
├── compliance-policies.json   # Compliance policy definitions
├── compliance-status.json     # Device compliance states
├── compliance-trends.json     # DeviceComplianceTrend report
├── config-profiles.json       # Configuration profile definitions
├── config-status.json         # ConfigurationPolicyAggregate report
├── apps-list.json             # AllAppsList report
├── apps-install-status.json   # AppInstallStatusAggregate report
├── apps-discovered.json       # AppInvAggregate report
├── defender-agents.json       # DefenderAgents report
├── malware.json               # ActiveMalware report
├── firewall-status.json       # FirewallStatus report
├── autopilot-status.json      # AutopilotV2DeploymentStatus report
├── enrollment-failures.json   # DeviceEnrollmentFailures report
├── update-feature.json        # FeatureUpdateDeviceState report
├── update-quality.json        # QualityUpdateDeviceStatusByPolicy report
├── update-driver.json         # DriverUpdatePolicyStatusSummary report
├── ea-startup-perf.json       # EAStartupPerfDevicePerformance report
├── ea-app-perf.json           # EAAppPerformance report
├── ea-resource-perf.json      # EAResourcePerfAggByDevice report
├── ea-device-scores.json      # EADeviceScoresV2 report
├── ea-work-anywhere.json      # EAWFADeviceList report
├── conditional-access.json    # Conditional Access policies
├── epm-elevations.json        # EpmElevationReportElevationEvent report
├── proactive-remediations.json # PolicyRunStatesByProactiveRemediation
├── device-health.json         # WindowsDeviceHealthAttestationReport
├── tpm-attestation.json       # TpmAttestationStatus report
└── co-management.json         # ComanagedDeviceWorkloads report
```

## How the Export API Works

Most data is collected via the [Intune Graph Export API](https://learn.microsoft.com/en-us/intune/intune-service/fundamentals/reports-export-graph-apis):

1. **POST** to `https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs` with report name
2. **Poll** the export job until status = `completed`
3. **Download** the ZIP from the returned URL
4. **Extract** and save as JSON in the collection pack

This is the same mechanism used by the Intune admin center's "Export" buttons — we just automate it.

## Security & Privacy

- **Read-only** — the collector makes no changes to your Intune environment
- **No data leaves your machine** — output stays in the local ZIP file
- **Share selectively** — send only the ZIP to your consultant
- **PII note** — device names, UPNs, and serial numbers are included in the raw data. The analysis tool has a `-ScrubPII` option that anonymises all identifiable data in the output report.

## License

MIT License — see [LICENSE](LICENSE) for details.
