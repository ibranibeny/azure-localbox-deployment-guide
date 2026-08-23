<#
.SYNOPSIS
    Watches Azure Local cluster deployment step by step and flags a stall.

.DESCRIPTION
    The cluster resource only ever reports "DeploymentInProgress", which cannot
    distinguish a healthy 45-minute step from an orchestrator that died hours ago.
    The per-step detail lives on the cluster resource under
    properties.reportedProperties.deploymentStatus, and that is what this reads.

    Microsoft documents 2.5 to 3 hours for a two-node system, with several
    individual steps taking 40 to 50 minutes, so elapsed time alone proves nothing.
    A stall is only credible when the same step has been InProgress far longer than
    the documented worst case, which is why StallMinutes defaults to 75.

.NOTES
    Read-only. Never writes to Azure.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId = '439cf6ec-8907-40ee-bae2-7efd9656cd09',
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$ClusterName = 'localboxcluster',
    [int]$IntervalSeconds = 300,
    [int]$MaxHours = 6,
    [int]$StallMinutes = 75,
    [string]$LogPath = (Join-Path $env:TEMP 'watch-cluster-deployment.log')
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Output $line
}

$clusterId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
             "/providers/Microsoft.AzureStackHCI/clusters/$ClusterName"

# Step detail lives on the child, not the cluster; the cluster only reports a bare status.
$settingsId = "$clusterId/deploymentSettings/default"

$deadline      = (Get-Date).AddHours($MaxHours)
$lastStepIndex = $null
$stepSince     = Get-Date

Write-Log "watch started  cluster=$ClusterName  rg=$ResourceGroup  interval=${IntervalSeconds}s  stall>${StallMinutes}m"

while ((Get-Date) -lt $deadline) {

    $rawCluster = az resource show --ids $clusterId --api-version 2024-04-01 -o json 2>$null
    $rawSteps   = az resource show --ids $settingsId --api-version 2024-04-01 -o json 2>$null

    if (-not $rawSteps) {
        Write-Log 'deploymentSettings not readable yet, retrying'
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }

    $status = if ($rawCluster) { ($rawCluster | ConvertFrom-Json).properties.status } else { 'unknown' }
    $ds     = ($rawSteps | ConvertFrom-Json).properties.reportedProperties.deploymentStatus

    if (-not $ds -or -not $ds.steps) {
        Write-Log "status=$status  (belum ada detail langkah)"
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }

    $steps = @($ds.steps[0].steps)

    # An empty collection would make .Count report 1 on a bare $null, so guard it.
    $total   = if ($null -eq $steps) { 0 } else { $steps.Count }
    $done    = @($steps | Where-Object { $_.status -eq 'Success' -or $_.status -eq 'Skipped' }).Count
    $current = $steps | Where-Object { $_.status -eq 'InProgress' } | Select-Object -First 1
    $failed  = @($steps | Where-Object { $_.status -eq 'Failed' -or $_.status -eq 'Error' })

    if ($failed.Count -gt 0) {
        foreach ($f in $failed) {
            Write-Log "FAILED  step $($f.fullStepIndex)  $($f.name)"
        }
        Write-Log 'stopping: a step reported failure'
        break
    }

    if ($ds.status -eq 'Success' -or $status -eq 'ConnectedRecently' -or $status -eq 'Connected') {
        Write-Log "SELESAI  status=$status  deploymentStatus=$($ds.status)  ($done/$total langkah)"
        break
    }

    if ($current) {
        if ($current.fullStepIndex -ne $lastStepIndex) {
            $lastStepIndex = $current.fullStepIndex
            $stepSince     = Get-Date
        }
        $onStep = [int]((Get-Date) - $stepSince).TotalMinutes
        $flag   = if ($onStep -ge $StallMinutes) { 'STALL?' } else { 'ok    ' }
        Write-Log ("$flag {0,2}/{1} langkah  |  {2} {3}  |  {4} menit di langkah ini" -f
                   $done, $total, $current.fullStepIndex, $current.name, $onStep)
    }
    else {
        Write-Log "ok     $done/$total langkah  |  tidak ada langkah InProgress  |  status=$status"
    }

    Start-Sleep -Seconds $IntervalSeconds
}

Write-Log 'watch ended'
