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

function Submit-ExportJob {
    <#
    .SYNOPSIS
        Submits an Intune export job and returns the job ID (does not wait).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ReportName,
        [string]$Filter = $null,
        [string[]]$Select = $null,
        [int]$MaxRetries = 2
    )

    $body = @{ reportName = $ReportName; format = "json" }
    if ($Filter) { $body.filter = $Filter }
    if ($Select) { $body.select = $Select }

    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            $job = Invoke-MgGraphRequest -Method POST `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs" `
                -Body ($body | ConvertTo-Json -Depth 5) `
                -ContentType "application/json"
            return $job.id
        } catch {
            $statusCode = $null
            try { if ($null -ne $_.Exception -and $null -ne $_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode } } catch { }
            if ($statusCode -eq 429 -and $attempt -lt $MaxRetries) {
                $retryAfter = 5 * ($attempt + 1)
                Write-Host "    [throttled on $ReportName, retry in ${retryAfter}s]" -ForegroundColor Yellow
                Start-Sleep -Seconds $retryAfter
            } else {
                Write-Host "    [FAIL] Submit $ReportName - $($_.Exception.Message)" -ForegroundColor Red
                return $null
            }
        }
    }
    return $null
}

function Get-ExportResult {
    <#
    .SYNOPSIS
        Downloads and parses a completed export job result.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$DownloadUrl,
        [Parameter(Mandatory)]
        [string]$ReportName
    )

    $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) "$ReportName`_$(Get-Random).zip"
    $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) "$ReportName`_$(Get-Random)"

    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempZip -UseBasicParsing
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

        $resultFile = Get-ChildItem -Path $tempExtract -Recurse -File | Select-Object -First 1
        $data = $null
        if ($resultFile) {
            if ($resultFile.Extension -eq ".json") {
                $data = Get-Content $resultFile.FullName -Raw | ConvertFrom-Json
            } elseif ($resultFile.Extension -eq ".csv") {
                $data = Import-Csv $resultFile.FullName
            }
        }
        return $data
    } finally {
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ExportBatch {
    <#
    .SYNOPSIS
        Submits multiple export jobs at once and polls them all concurrently.
        Returns a hashtable of Key -> Data.
    .DESCRIPTION
        Instead of waiting for each report sequentially, this submits all jobs
        up front and polls them in a round-robin loop. The server processes
        them concurrently, so total time = max(individual) instead of sum.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Reports,

        [int]$TimeoutSeconds = 180
    )

    $results = @{}
    $pending = [System.Collections.Generic.List[object]]::new()

    # Submit all jobs with staggered timing to avoid 429 cascading
    $submitIndex = 0
    foreach ($report in $Reports) {
        # Stagger submissions: pause 1s every 5 jobs to stay under rate limits
        if ($submitIndex -gt 0 -and ($submitIndex % 5) -eq 0) {
            Write-Host "    (pacing: 2s cooldown)" -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
        } elseif ($submitIndex -gt 0) {
            Start-Sleep -Milliseconds 500
        }
        $rFilter = if ($report.ContainsKey('Filter')) { $report.Filter } else { $null }
        $rSelect = if ($report.ContainsKey('Select')) { $report.Select } else { $null }
        $jobId = Submit-ExportJob -ReportName $report.ReportName `
            -Filter $rFilter -Select $rSelect
        if ($null -ne $jobId) {
            $pending.Add(@{
                Key        = $report.Key
                ReportName = $report.ReportName
                JobId      = $jobId
            })
            Write-Host "    Submitted $($report.ReportName)" -ForegroundColor DarkGray
        } else {
            $results[$report.Key] = $null
        }
        $submitIndex++
    }

    if ($pending.Count -eq 0) { return $results }

    $submitCount = $pending.Count
    Write-Host "  Waiting for $submitCount reports..." -ForegroundColor Gray -NoNewline

    # Poll all pending jobs in a loop
    $elapsed = 0
    $pollInterval = 3     # check every 3s
    $completedCount = 0

    while ($pending.Count -gt 0 -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval

        $justCompleted = [System.Collections.Generic.List[object]]::new()

        foreach ($job in $pending) {
            try {
                $status = Invoke-MgGraphRequest -Method GET `
                    -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('$($job.JobId)')"

                if ($status.status -eq "completed") {
                    $data = Get-ExportResult -DownloadUrl $status.url -ReportName $job.ReportName
                    $results[$job.Key] = $data
                    $count = if ($null -eq $data) { 0 } elseif ($data -is [array]) { $data.Count } else { 1 }
                    $completedCount++
                    Write-Host "" # newline after dots
                    Write-Host "    [OK] $($job.ReportName) ($count records)" -ForegroundColor Green
                    if ($pending.Count -gt 1) {
                        $remaining = $pending.Count - $justCompleted.Count - 1
                        if ($remaining -gt 0) {
                            Write-Host "  Waiting for $remaining more..." -ForegroundColor Gray -NoNewline
                        }
                    }
                    $justCompleted.Add($job)
                }
                elseif ($status.status -eq "failed") {
                    $results[$job.Key] = $null
                    $completedCount++
                    Write-Host "" # newline after dots
                    Write-Host "    [FAIL] $($job.ReportName) - export failed" -ForegroundColor Red
                    $justCompleted.Add($job)
                }
            } catch {
                # Throttled on status check — skip this cycle, try next round
                $sc = $null
                try { if ($null -ne $_.Exception -and $null -ne $_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
                if ($sc -eq 429) {
                    Write-Host "t" -ForegroundColor Yellow -NoNewline  # throttle indicator
                }
            }
        }

        foreach ($done in $justCompleted) {
            $pending.Remove($done) | Out-Null
        }

        # Progress dot
        if ($pending.Count -gt 0) {
            Write-Host "." -ForegroundColor DarkGray -NoNewline
        }
    }

    # Handle timeouts
    foreach ($job in $pending) {
        Write-Host ""
        Write-Host "    [WARN] $($job.ReportName) - timed out after ${TimeoutSeconds}s" -ForegroundColor Yellow
        $results[$job.Key] = $null
    }

    if ($pending.Count -eq 0 -and $completedCount -gt 0) {
        Write-Host ""
    }
    Write-Host "  Batch complete: $completedCount/$submitCount in ${elapsed}s" -ForegroundColor Cyan

    return $results
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
    $maxRetries = 3

    # Helper to safely extract a property from Graph response (may be Hashtable or PSCustomObject)
    function Get-ResponseValue {
        param($Response, [string]$Name)
        if ($null -eq $Response) { return $null }
        if ($Response -is [System.Collections.IDictionary]) {
            if ($Response.ContainsKey($Name)) { return $Response[$Name] }
            return $null
        }
        if ($Response.PSObject.Properties.Match($Name).Count -gt 0) {
            return $Response.$Name
        }
        return $null
    }

    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri
        $pageValue = Get-ResponseValue $response 'value'
        if ($null -ne $pageValue) {
            $allResults.AddRange([object[]]$pageValue)
        }

        $nextLink = Get-ResponseValue $response '@odata.nextLink'
        while ($null -ne $nextLink) {
            $pageRetry = 0
            $pageSuccess = $false
            while (-not $pageSuccess -and $pageRetry -lt $maxRetries) {
                try {
                    $response = Invoke-MgGraphRequest -Method GET -Uri $nextLink
                    $pageValue = Get-ResponseValue $response 'value'
                    if ($null -ne $pageValue) {
                        $allResults.AddRange([object[]]$pageValue)
                    }
                    $pageSuccess = $true
                } catch {
                    $pageRetry++
                    $sc = $null
                    try { if ($null -ne $_.Exception -and $null -ne $_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
                    if ($sc -eq 429 -and $pageRetry -lt $maxRetries) {
                        Start-Sleep -Seconds (3 * $pageRetry)
                    } else {
                        throw
                    }
                }
            }
            $nextLink = Get-ResponseValue $response '@odata.nextLink'
        }
    } catch {
        Write-Host "  [WARN] Graph request failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    return $allResults.ToArray()
}

# =========================================================
# Collection
# =========================================================
$collectionDir = Join-Path ([System.IO.Path]::GetTempPath()) "IntuneCollection_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $collectionDir -Force | Out-Null

$collected = @{}

# ─────────────────────────────────────────────────────────
# Batch 1: Device Inventory + Compliance + Config (10 reports)
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Batch 1: Device Inventory, Compliance, Configuration" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────────" -ForegroundColor Gray

$batch1 = @(
    @{ Key = "devices";               ReportName = "DevicesWithInventory" }
    @{ Key = "device-health";         ReportName = "WindowsDeviceHealthAttestationReport" }
    @{ Key = "tpm-attestation";       ReportName = "TpmAttestationStatus" }
    @{ Key = "compliance-status";     ReportName = "DeviceCompliance" }
    @{ Key = "compliance-policies";   ReportName = "NonCompliantCompliancePoliciesAggregate" }
    @{ Key = "devices-without-policy"; ReportName = "DevicesWithoutCompliancePolicy" }
    @{ Key = "noncompliant-settings"; ReportName = "NoncompliantDevicesAndSettings" }
    @{ Key = "config-aggregate";      ReportName = "ConfigurationPolicyAggregate" }
    @{ Key = "config-non-compliant";  ReportName = "NonCompliantConfigurationPoliciesAggregateWithPF" }
    @{ Key = "compliance-trend";      ReportName = "DeviceComplianceTrend" }
)
$batch1Results = Invoke-ExportBatch -Reports $batch1
foreach ($key in $batch1Results.Keys) { $collected[$key] = $batch1Results[$key] }

# Inter-batch cooldown — Intune rate limits cascade across export endpoints
Write-Host "  (inter-batch cooldown: 5s)" -ForegroundColor DarkGray
Start-Sleep -Seconds 5

# ─────────────────────────────────────────────────────────
# Batch 2: Apps + Security + Autopilot + Updates (up to 14 reports)
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Batch 2: Apps, Security, Autopilot, Updates" -ForegroundColor Cyan
Write-Host "────────────────────────────────────────────" -ForegroundColor Gray

$batch2 = [System.Collections.Generic.List[object]]::new()

if (-not $SkipApps) {
    $batch2.Add(@{ Key = "apps-list";           ReportName = "AllAppsList" })
    $batch2.Add(@{ Key = "apps-install-status"; ReportName = "AppInstallStatusAggregate" })
    $batch2.Add(@{ Key = "apps-discovered";     ReportName = "AppInvAggregate" })
} else {
    Write-Host "  [SKIP] Apps (SkipApps)" -ForegroundColor Gray
}

if (-not $SkipSecurity) {
    $batch2.Add(@{ Key = "defender-agents";    ReportName = "DefenderAgents" })
    $batch2.Add(@{ Key = "unhealthy-defender"; ReportName = "UnhealthyDefenderAgents" })
    $batch2.Add(@{ Key = "malware";            ReportName = "ActiveMalware" })
    $batch2.Add(@{ Key = "firewall-status";    ReportName = "FirewallStatus" })
    $batch2.Add(@{ Key = "epm-elevations";     ReportName = "EpmElevationReportElevationEvent" })
} else {
    Write-Host "  [SKIP] Security (SkipSecurity)" -ForegroundColor Gray
}

$batch2.Add(@{ Key = "autopilot-status";       ReportName = "AutopilotV2DeploymentStatus" })
$batch2.Add(@{ Key = "enrollment-activity";    ReportName = "EnrollmentActivity" })
$batch2.Add(@{ Key = "update-driver-summary";  ReportName = "DriverUpdatePolicyStatusSummary" })
$batch2.Add(@{ Key = "update-feature-summary"; ReportName = "FeatureUpdatePolicyStatusSummary" })
$batch2.Add(@{ Key = "update-quality-summary"; ReportName = "QualityUpdatePolicyStatusSummary" })

if ($batch2.Count -gt 0) {
    $batch2Results = Invoke-ExportBatch -Reports $batch2.ToArray()
    foreach ($key in $batch2Results.Keys) { $collected[$key] = $batch2Results[$key] }
}

# Inter-batch cooldown
Write-Host "  (inter-batch cooldown: 5s)" -ForegroundColor DarkGray
Start-Sleep -Seconds 5

# ─────────────────────────────────────────────────────────
# Batch 3: Endpoint Analytics (10 reports) + Co-management
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Batch 3: Endpoint Analytics, Co-management, GP Migration" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────────────" -ForegroundColor Gray

$batch3 = [System.Collections.Generic.List[object]]::new()

if (-not $SkipEndpointAnalytics) {
    $batch3.Add(@{ Key = "ea-startup-perf";    ReportName = "EAStartupPerfDevicePerformanceV2" })
    $batch3.Add(@{ Key = "ea-startup-model";   ReportName = "EAStartupPerfModelPerformanceV2" })
    $batch3.Add(@{ Key = "ea-app-perf";        ReportName = "EAAppPerformance" })
    $batch3.Add(@{ Key = "ea-resource-device"; ReportName = "EAResourcePerfAggByDevice" })
    $batch3.Add(@{ Key = "ea-resource-model";  ReportName = "EAResourcePerfAggByModel" })
    $batch3.Add(@{ Key = "ea-device-scores";   ReportName = "EADeviceScoresV2" })
    $batch3.Add(@{ Key = "ea-model-scores";    ReportName = "EAModelScoresV2" })
    $batch3.Add(@{ Key = "ea-work-anywhere";   ReportName = "EAWFADeviceList" })
    $batch3.Add(@{ Key = "ea-anomalies";       ReportName = "EAAnomalyAssetV2" })
    $batch3.Add(@{ Key = "ea-battery-model";   ReportName = "BRBatteryByModel" })
} else {
    Write-Host "  [SKIP] Endpoint Analytics (SkipEndpointAnalytics)" -ForegroundColor Gray
}

$batch3.Add(@{ Key = "co-management";             ReportName = "ComanagedDeviceWorkloads" })
$batch3.Add(@{ Key = "co-management-eligibility";  ReportName = "ComanagementEligibilityTenantAttachedDevices" })
$batch3.Add(@{ Key = "gp-migration-readiness";     ReportName = "GPAnalyticsSettingMigrationReadiness" })

if ($batch3.Count -gt 0) {
    $batch3Results = Invoke-ExportBatch -Reports $batch3.ToArray()
    foreach ($key in $batch3Results.Keys) { $collected[$key] = $batch3Results[$key] }
}

# ─────────────────────────────────────────────────────────
# Direct API: Conditional Access (not an export report)
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Conditional Access (direct API)" -ForegroundColor Cyan
Write-Host "────────────────────────────────" -ForegroundColor Gray

Write-Host "  Collecting Conditional Access policies..." -ForegroundColor Gray -NoNewline
try {
    $caPolicies = Invoke-GraphPagedRequest -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies"
    $collected["conditional-access"] = $caPolicies
    $caCount = if ($null -ne $caPolicies) { $caPolicies.Count } else { 0 }
    Write-Host " [OK] ($caCount policies)" -ForegroundColor Green
} catch {
    Write-Host " [FAIL] $($_.Exception.Message)" -ForegroundColor Yellow
}

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
