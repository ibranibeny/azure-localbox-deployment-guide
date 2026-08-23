#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps cost governance tags in place while a long deployment runs.

.DESCRIPTION
    Deployment automation writes its progress into a tag by replacing the tag set
    rather than merging into it. Any governance tag applied beforehand is removed
    as a side effect, and in a subscription with cost automation a host without a
    cost exemption becomes a candidate for deallocation. Losing the host part-way
    through does not pause the deployment, it ends it, because the orchestrator
    does not resume when the machine comes back.

    This watches the host and the resource group, restores the tags whenever they
    go missing, and records every restore so you can tell afterwards whether the
    protection was actually needed.

    This is a workaround for the tag write being destructive. It is not a
    supported setting.

.PARAMETER SubscriptionId
    Subscription containing the lab.

.PARAMETER ResourceGroup
    Resource group being deployed into.

.PARAMETER HostVmName
    The Azure virtual machine that hosts the deployment.

.PARAMETER IntervalSeconds
    Seconds between checks.

.PARAMETER MaxHours
    Stop watching after this long.

.PARAMETER LogPath
    Where to append the audit trail.

.EXAMPLE
    .\Protect-LabTags.ps1 -SubscriptionId <sub> -ResourceGroup <rg>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$HostVmName = 'LocalBox-Client',
    [int]$IntervalSeconds = 300,
    [int]$MaxHours = 8,
    [string]$LogPath = "$env:TEMP\protect-lab-tags.log"
)

$ErrorActionPreference = 'Continue'

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
}

$deadline    = (Get-Date).AddHours($MaxHours)
$restores    = 0
$checks      = 0
$vmType      = 'Microsoft.Compute/virtualMachines'

Write-Log "watch started  rg=$ResourceGroup  vm=$HostVmName  interval=${IntervalSeconds}s  maxHours=$MaxHours"

while ((Get-Date) -lt $deadline) {
    $checks++

    $tagsJson = az resource show `
        --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName `
        --resource-type $vmType --query tags -o json 2>$null

    if (-not $tagsJson) {
        Write-Log 'host not readable yet, will retry'
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }

    $tags = $tagsJson | ConvertFrom-Json
    $names = if ($tags) { $tags.PSObject.Properties.Name } else { @() }

    if ($names -contains 'CostControl') {
        # Report progress too, so one log answers both questions.
        $progress = if ($names -contains 'DeploymentProgress') { $tags.DeploymentProgress } else { 'n/a' }
        Write-Log "ok    CostControl present   progress: $progress"
    }
    else {
        $restores++
        Write-Log "GONE  CostControl missing, restoring (restore #$restores)"

        # Rebuild the whole set, because the tag command replaces rather than merges.
        $pairs = @('CostControl=Ignore', 'SecurityControl=Ignore')
        foreach ($p in $tags.PSObject.Properties) {
            if ($p.Name -notin 'CostControl', 'SecurityControl') {
                $pairs += "$($p.Name)=$($p.Value)"
            }
        }

        & az resource tag `
            --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName `
            --resource-type $vmType --tags $pairs -o none 2>$null

        if ($LASTEXITCODE -eq 0) { Write-Log '      restored on host' }
        else { Write-Log '      RESTORE FAILED on host' }

        & az group update --subscription $SubscriptionId -n $ResourceGroup `
            --set tags.CostControl=Ignore tags.SecurityControl=Ignore -o none 2>$null
    }

    # Stop early once the instance is registered, since the risk window has closed.
    $status = az resource show `
        --subscription $SubscriptionId -g $ResourceGroup -n localboxcluster `
        --resource-type Microsoft.AzureStackHCI/clusters --api-version 2024-04-01 `
        --query 'properties.connectivityStatus' -o tsv 2>$null

    if ($status -eq 'Connected') {
        Write-Log "instance is Connected, deployment window over"
        break
    }

    Start-Sleep -Seconds $IntervalSeconds
}

Write-Log "watch ended   checks=$checks  restores=$restores"

if ($restores -eq 0) {
    Write-Log 'the tags were never removed during this run, so the guard was not needed here'
}
else {
    Write-Log "the tags were removed $restores time(s), so the guard prevented a deallocation window"
}
