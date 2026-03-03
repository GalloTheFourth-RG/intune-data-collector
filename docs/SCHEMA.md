# Schema Reference — Intune Data Collector

## Schema Version: 1.0

### metadata.json

| Field | Type | Description |
|-------|------|-------------|
| `SchemaVersion` | String | Schema version (e.g., "1.0") |
| `CollectorVersion` | String | Collector script version |
| `TenantId` | String | Entra ID tenant ID |
| `CollectedBy` | String | UPN of the authenticated user |
| `CollectionDate` | String | ISO 8601 timestamp |
| `CollectionDuration` | Number | Seconds elapsed |
| `DaysBack` | Number | Historical data lookback |
| `Parameters` | Object | Collection parameters used |
| `DataSources` | Object | Status and record count per data source |

### Data Source Files

Each file contains the raw JSON output from the corresponding Graph Export API report or REST API call. The field names match the Microsoft documentation exactly:
https://learn.microsoft.com/en-us/intune/intune-service/fundamentals/reports-export-graph-available-reports

| File | Graph Report Name | Description |
|------|-------------------|-------------|
| `devices.json` | DevicesWithInventory | All managed devices with hardware/software inventory |
| `device-health.json` | WindowsDeviceHealthAttestationReport | Secure Boot, TPM, BitLocker attestation |
| `tpm-attestation.json` | TpmAttestationStatus | TPM version and attestation status |
| `compliance-status.json` | DeviceCompliance | Per-device compliance state |
| `compliance-trends.json` | DeviceComplianceTrend | Compliance state over time |
| `compliance-policies.json` | NonCompliantCompliancePoliciesAggregate | Policy-level compliance summary |
| `devices-without-policy.json` | DevicesWithoutCompliancePolicy | Devices with no compliance policy |
| `noncompliant-settings.json` | NoncompliantDevicesAndSettings | Which settings are failing |
| `config-aggregate.json` | ConfigurationPolicyAggregate | Config profile deployment status |
| `config-non-compliant.json` | NonCompliantConfigurationPoliciesAggregateWithPF | Failing config profiles |
| `apps-list.json` | AllAppsList | All apps in the tenant |
| `apps-install-status.json` | AppInstallStatusAggregate | App install success/failure rates |
| `apps-discovered.json` | AppInvAggregate | Discovered (unmanaged) apps |
| `defender-agents.json` | DefenderAgents | Defender agent health status |
| `unhealthy-defender.json` | UnhealthyDefenderAgents | Devices with Defender issues |
| `malware.json` | ActiveMalware | Active malware detections |
| `firewall-status.json` | FirewallStatus | Windows firewall status |
| `epm-elevations.json` | EpmElevationReportElevationEvent | Privilege elevation events |
| `autopilot-status.json` | AutopilotV2DeploymentStatus | Autopilot deployment results |
| `enrollment-failures.json` | DeviceEnrollmentFailures | Enrollment failure details |
| `enrollment-activity.json` | EnrollmentActivity | Enrollment activity log |
| `update-driver-summary.json` | DriverUpdatePolicyStatusSummary | Driver update policy status |
| `update-feature-summary.json` | FeatureUpdatePolicyStatusSummary | Feature update policy status |
| `update-quality-summary.json` | QualityUpdatePolicyStatusSummary | Quality update policy status |
| `ea-startup-perf.json` | EAStartupPerfDevicePerformanceV2 | Boot/login times per device |
| `ea-startup-model.json` | EAStartupPerfModelPerformanceV2 | Boot/login times per model |
| `ea-app-perf.json` | EAAppPerformance | App crash/hang rates |
| `ea-resource-device.json` | EAResourcePerfAggByDevice | CPU/RAM spikes per device |
| `ea-resource-model.json` | EAResourcePerfAggByModel | CPU/RAM spikes per model |
| `ea-device-scores.json` | EADeviceScoresV2 | Endpoint Analytics scores per device |
| `ea-model-scores.json` | EAModelScoresV2 | Endpoint Analytics scores per model |
| `ea-work-anywhere.json` | EAWFADeviceList | Work From Anywhere readiness |
| `ea-anomalies.json` | EAAnomalyAssetV2 | Endpoint Analytics anomaly detections |
| `ea-battery-model.json` | BRBatteryByModel | Battery health by model |
| `conditional-access.json` | N/A (REST API) | Conditional Access policy definitions |
| `co-management.json` | ComanagedDeviceWorkloads | Co-management workload assignments |
| `co-management-eligibility.json` | ComanagementEligibilityTenantAttachedDevices | Co-mgmt eligible devices |
| `gp-migration-readiness.json` | GPAnalyticsSettingMigrationReadiness | GPO → Intune migration readiness |
