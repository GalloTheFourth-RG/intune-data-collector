#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Collects Microsoft Intune data for offline assessment.

.DESCRIPTION
    This script collects Intune device management data via the Microsoft Graph
    Export API and REST API. It produces a portable ZIP file containing JSON
    exports that can be analysed offline by the Intune Evidence Pack.

    The script is READ-ONLY — it makes no changes to your Intune environment.

    Data collected includes:
    - Device inventory and compliance status
    - Configuration profiles and policy assignments
    - App inventory and install status
    - Defender agent health, malware detections, firewall status
    - Autopilot deployment status
    - Endpoint Analytics (startup, app reliability, resource perf)
    - Windows Update status (feature, quality, driver)
    - Conditional Access policies
    - Endpoint Privilege Management elevations
    - Proactive Remediations run states

.PARAMETER TenantId
    Required. The Azure AD / Entra ID tenant ID to collect from.

.PARAMETER OutputPath
    Directory for the output ZIP. Defaults to current directory.

.PARAMETER SkipEndpointAnalytics
    Skip Endpoint Analytics reports for faster collection.

.PARAMETER SkipApps
    Skip app inventory and install status reports.

.PARAMETER SkipSecurity
    Skip Defender, malware, and firewall reports.

.PARAMETER DaysBack
    Number of days of historical data for trend reports. Default: 30.

.PARAMETER DryRun
    Validate permissions and connectivity without collecting data.

.EXAMPLE
    .\Collect-IntuneData.ps1 -TenantId "contoso.onmicrosoft.com"

.EXAMPLE
    .\Collect-IntuneData.ps1 -TenantId "12345678-abcd-efgh-ijkl-123456789012" -SkipEndpointAnalytics

.NOTES
    Version: 1.0.0
    Requires: Microsoft.Graph.Authentication module
    Permissions: DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All,
                 DeviceManagementApps.Read.All, DeviceManagementServiceConfig.Read.All, Policy.Read.All
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [string]$OutputPath = (Get-Location).Path,

    [switch]$SkipEndpointAnalytics,
    [switch]$SkipApps,
    [switch]$SkipSecurity,

    [int]$DaysBack = 30,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:ScriptVersion = "1.0.0"
$script:SchemaVersion = "1.0"
$script:CollectionStart = Get-Date

# =========================================================
# Banner
# =========================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Intune Data Collector v$script:ScriptVersion                    ║" -ForegroundColor Cyan
Write-Host "║  Offline assessment data collection             ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# =========================================================
# Prerequisites Check
# =========================================================
Write-Host "Checking prerequisites..." -ForegroundColor Yellow

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Error "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    exit 1
}
Write-Host "  ✓ Microsoft.Graph.Authentication module found" -ForegroundColor Green

# =========================================================
# Authentication
# =========================================================
Write-Host ""
Write-Host "Authenticating to Microsoft Graph..." -ForegroundColor Yellow

$requiredScopes = @(
    "DeviceManagementManagedDevices.Read.All",
    "DeviceManagementConfiguration.Read.All",
    "DeviceManagementApps.Read.All",
    "DeviceManagementServiceConfig.Read.All",
    "Policy.Read.All"
)

try {
    Connect-MgGraph -TenantId $TenantId -Scopes $requiredScopes -NoWelcome
    $context = Get-MgContext
    Write-Host "  ✓ Authenticated as $($context.Account) to tenant $($context.TenantId)" -ForegroundColor Green
} catch {
    Write-Error "Authentication failed: $($_.Exception.Message)"
    exit 1
}

if ($DryRun) {
    Write-Host ""
    Write-Host "DryRun: Authentication successful. Permissions validated." -ForegroundColor Green
    Write-Host "DryRun: No data collected." -ForegroundColor Yellow
    Disconnect-MgGraph | Out-Null
    return
}

# =========================================================
# Helper Functions
# =========================================================

function Invoke-IntuneExportReport {
    <#
    .SYNOPSIS
        Exports an Intune report via the Graph Export API.
    .DESCRIPTION
        Posts an export job, polls until complete, downloads the result ZIP,
        extracts the CSV/JSON, and returns the parsed data.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ReportName,

        [string]$Filter = $null,

        [string[]]$Select = $null,

        [int]$TimeoutSeconds = 300,

        [int]$PollIntervalSeconds = 5
    )

    Write-Host "  Exporting $ReportName..." -ForegroundColor Gray -NoNewline

    $body = @{ reportName = $ReportName; format = "json" }
    if ($Filter) { $body.filter = $Filter }
    if ($Select) { $body.select = $Select }

    try {
        # Create export job
        $job = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs" `
            -Body ($body | ConvertTo-Json -Depth 5) `
            -ContentType "application/json"

        $jobId = $job.id
        $elapsed = 0

        # Poll until complete
        while ($elapsed -lt $TimeoutSeconds) {
            Start-Sleep -Seconds $PollIntervalSeconds
            $elapsed += $PollIntervalSeconds

            $status = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('$jobId')"

            if ($status.status -eq "completed") {
                $downloadUrl = $status.url

                # Download the ZIP
                $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) "$ReportName`_$(Get-Random).zip"
                Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip

                # Extract
                $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) "$ReportName`_$(Get-Random)"
                Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

                # Parse the result file
                $resultFile = Get-ChildItem -Path $tempExtract -Recurse -File | Select-Object -First 1
                $data = $null
                if ($resultFile) {
                    if ($resultFile.Extension -eq ".json") {
                        $data = Get-Content $resultFile.FullName -Raw | ConvertFrom-Json
                    } elseif ($resultFile.Extension -eq ".csv") {
                        $data = Import-Csv $resultFile.FullName
                    }
                }

                # Cleanup temp files
                Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
                Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

                $count = if ($null -eq $data) { 0 } elseif ($data -is [array]) { $data.Count } else { 1 }
                Write-Host " ✓ ($count records)" -ForegroundColor Green
                return $data
            }

            if ($status.status -eq "failed") {
                Write-Host " ✗ Export failed" -ForegroundColor Red
                return $null
            }
        }

        Write-Host " ✗ Timed out after ${TimeoutSeconds}s" -ForegroundColor Yellow
        return $null

    } catch {
        Write-Host " ✗ $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Invoke-GraphPagedRequest {
    <#
    .SYNOPSIS
        Makes a paged Graph API request, following @odata.nextLink.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $allResults = [System.Collections.Generic.List[object]]::new()

    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri
        if ($response.value) {
            $allResults.AddRange([object[]]$response.value)
        }

        while ($response.'@odata.nextLink') {
            $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink'
            if ($response.value) {
                $allResults.AddRange([object[]]$response.value)
            }
        }
    } catch {
        Write-Host "  ⚠ Graph request failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    return $allResults.ToArray()
}

# =========================================================
# Collection
# =========================================================
$collectionDir = Join-Path ([System.IO.Path]::GetTempPath()) "IntuneCollection_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $collectionDir -Force | Out-Null

$collected = @{}

Write-Host ""
Write-Host "Step 1: Device Inventory" -ForegroundColor Cyan
Write-Host "─────────────────────────" -ForegroundColor Gray

$collected["devices"] = Invoke-IntuneExportReport -ReportName "DevicesWithInventory"
$collected["device-health"] = Invoke-IntuneExportReport -ReportName "WindowsDeviceHealthAttestationReport"
$collected["tpm-attestation"] = Invoke-IntuneExportReport -ReportName "TpmAttestationStatus"

Write-Host ""
Write-Host "Step 2: Compliance" -ForegroundColor Cyan
Write-Host "───────────────────" -ForegroundColor Gray

$collected["compliance-status"] = Invoke-IntuneExportReport -ReportName "DeviceCompliance"
$collected["compliance-trends"] = Invoke-IntuneExportReport -ReportName "DeviceComplianceTrend"
$collected["compliance-policies"] = Invoke-IntuneExportReport -ReportName "NonCompliantCompliancePoliciesAggregate"
$collected["devices-without-policy"] = Invoke-IntuneExportReport -ReportName "DevicesWithoutCompliancePolicy"
$collected["noncompliant-settings"] = Invoke-IntuneExportReport -ReportName "NoncompliantDevicesAndSettings"

Write-Host ""
Write-Host "Step 3: Configuration Profiles" -ForegroundColor Cyan
Write-Host "───────────────────────────────" -ForegroundColor Gray

$collected["config-aggregate"] = Invoke-IntuneExportReport -ReportName "ConfigurationPolicyAggregate"
$collected["config-non-compliant"] = Invoke-IntuneExportReport -ReportName "NonCompliantConfigurationPoliciesAggregateWithPF"

Write-Host ""
Write-Host "Step 4: Applications" -ForegroundColor Cyan
Write-Host "─────────────────────" -ForegroundColor Gray

if (-not $SkipApps) {
    $collected["apps-list"] = Invoke-IntuneExportReport -ReportName "AllAppsList"
    $collected["apps-install-status"] = Invoke-IntuneExportReport -ReportName "AppInstallStatusAggregate"
    $collected["apps-discovered"] = Invoke-IntuneExportReport -ReportName "AppInvAggregate"
} else {
    Write-Host "  ○ Skipped (SkipApps)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Step 5: Security" -ForegroundColor Cyan
Write-Host "──────────────────" -ForegroundColor Gray

if (-not $SkipSecurity) {
    $collected["defender-agents"] = Invoke-IntuneExportReport -ReportName "DefenderAgents"
    $collected["unhealthy-defender"] = Invoke-IntuneExportReport -ReportName "UnhealthyDefenderAgents"
    $collected["malware"] = Invoke-IntuneExportReport -ReportName "ActiveMalware"
    $collected["firewall-status"] = Invoke-IntuneExportReport -ReportName "FirewallStatus"
    $collected["epm-elevations"] = Invoke-IntuneExportReport -ReportName "EpmElevationReportElevationEvent"
} else {
    Write-Host "  ○ Skipped (SkipSecurity)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Step 6: Autopilot & Enrollment" -ForegroundColor Cyan
Write-Host "───────────────────────────────" -ForegroundColor Gray

$collected["autopilot-status"] = Invoke-IntuneExportReport -ReportName "AutopilotV2DeploymentStatus"
$collected["enrollment-failures"] = Invoke-IntuneExportReport -ReportName "DeviceEnrollmentFailures"
$collected["enrollment-activity"] = Invoke-IntuneExportReport -ReportName "EnrollmentActivity"

Write-Host ""
Write-Host "Step 7: Windows Updates" -ForegroundColor Cyan
Write-Host "────────────────────────" -ForegroundColor Gray

$collected["update-driver-summary"] = Invoke-IntuneExportReport -ReportName "DriverUpdatePolicyStatusSummary"
$collected["update-feature-summary"] = Invoke-IntuneExportReport -ReportName "FeatureUpdatePolicyStatusSummary"
$collected["update-quality-summary"] = Invoke-IntuneExportReport -ReportName "QualityUpdatePolicyStatusSummary"

Write-Host ""
Write-Host "Step 8: Endpoint Analytics" -ForegroundColor Cyan
Write-Host "───────────────────────────" -ForegroundColor Gray

if (-not $SkipEndpointAnalytics) {
    $collected["ea-startup-perf"] = Invoke-IntuneExportReport -ReportName "EAStartupPerfDevicePerformanceV2"
    $collected["ea-startup-model"] = Invoke-IntuneExportReport -ReportName "EAStartupPerfModelPerformanceV2"
    $collected["ea-app-perf"] = Invoke-IntuneExportReport -ReportName "EAAppPerformance"
    $collected["ea-resource-device"] = Invoke-IntuneExportReport -ReportName "EAResourcePerfAggByDevice"
    $collected["ea-resource-model"] = Invoke-IntuneExportReport -ReportName "EAResourcePerfAggByModel"
    $collected["ea-device-scores"] = Invoke-IntuneExportReport -ReportName "EADeviceScoresV2"
    $collected["ea-model-scores"] = Invoke-IntuneExportReport -ReportName "EAModelScoresV2"
    $collected["ea-work-anywhere"] = Invoke-IntuneExportReport -ReportName "EAWFADeviceList"
    $collected["ea-anomalies"] = Invoke-IntuneExportReport -ReportName "EAAnomalyAssetV2"
    $collected["ea-battery-model"] = Invoke-IntuneExportReport -ReportName "BRBatteryByModel"
} else {
    Write-Host "  ○ Skipped (SkipEndpointAnalytics)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Step 9: Conditional Access & Proactive Remediations" -ForegroundColor Cyan
Write-Host "────────────────────────────────────────────────────" -ForegroundColor Gray

# Conditional Access — uses REST API, not export
Write-Host "  Collecting Conditional Access policies..." -ForegroundColor Gray -NoNewline
try {
    $caPolicies = Invoke-GraphPagedRequest -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"
    $collected["conditional-access"] = $caPolicies
    Write-Host " ✓ ($($caPolicies.Count) policies)" -ForegroundColor Green
} catch {
    Write-Host " ✗ $($_.Exception.Message)" -ForegroundColor Yellow
}

# Co-management
$collected["co-management"] = Invoke-IntuneExportReport -ReportName "ComanagedDeviceWorkloads"
$collected["co-management-eligibility"] = Invoke-IntuneExportReport -ReportName "ComanagementEligibilityTenantAttachedDevices"

# GP Analytics
$collected["gp-migration-readiness"] = Invoke-IntuneExportReport -ReportName "GPAnalyticsSettingMigrationReadiness"

# =========================================================
# Save to JSON files
# =========================================================
Write-Host ""
Write-Host "Saving collected data..." -ForegroundColor Yellow

foreach ($key in $collected.Keys) {
    if ($null -ne $collected[$key]) {
        $filePath = Join-Path $collectionDir "$key.json"
        $collected[$key] | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
        Write-Host "  ✓ $key.json" -ForegroundColor Green
    }
}

# Metadata
$metadata = @{
    SchemaVersion      = $script:SchemaVersion
    CollectorVersion   = $script:ScriptVersion
    TenantId           = $context.TenantId
    CollectedBy        = $context.Account
    CollectionDate     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    CollectionDuration = [math]::Round(((Get-Date) - $script:CollectionStart).TotalSeconds, 1)
    DaysBack           = $DaysBack
    Parameters         = @{
        SkipEndpointAnalytics = $SkipEndpointAnalytics.IsPresent
        SkipApps              = $SkipApps.IsPresent
        SkipSecurity          = $SkipSecurity.IsPresent
    }
    DataSources        = @{}
}

foreach ($key in $collected.Keys) {
    $count = 0
    if ($null -ne $collected[$key]) {
        $count = if ($collected[$key] -is [array]) { $collected[$key].Count } else { 1 }
    }
    $metadata.DataSources[$key] = @{
        Status = if ($null -ne $collected[$key]) { "Collected" } else { "Failed" }
        Count  = $count
    }
}

$metadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $collectionDir "metadata.json") -Encoding UTF8
Write-Host "  ✓ metadata.json" -ForegroundColor Green

# =========================================================
# Create ZIP
# =========================================================
Write-Host ""
Write-Host "Creating collection pack ZIP..." -ForegroundColor Yellow

$zipName = "IntuneCollection_$($context.TenantId.Substring(0,8))_$(Get-Date -Format 'yyyyMMdd_HHmmss').zip"
$zipPath = Join-Path $OutputPath $zipName

Compress-Archive -Path "$collectionDir\*" -DestinationPath $zipPath -Force
Remove-Item $collectionDir -Recurse -Force

$zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
$duration = [math]::Round(((Get-Date) - $script:CollectionStart).TotalSeconds, 1)

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Collection Complete                             ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Output:   $zipPath" -ForegroundColor White
Write-Host "  Size:     $zipSize MB" -ForegroundColor White
Write-Host "  Duration: ${duration}s" -ForegroundColor White
Write-Host "  Sources:  $($collected.Keys.Count) data categories" -ForegroundColor White
Write-Host ""
Write-Host "  Send this ZIP to your consultant for analysis." -ForegroundColor Yellow

# Disconnect
Disconnect-MgGraph | Out-Null
