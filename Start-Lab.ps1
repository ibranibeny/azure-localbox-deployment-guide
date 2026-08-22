#Requires -Version 5.1
<#
.SYNOPSIS
    Brings a nested Azure Local lab back up, both layers, and protects it from
    being deallocated again.

.DESCRIPTION
    Starting the outer Azure virtual machine is not enough. The nested nodes are
    configured with an automatic start action of Nothing, so they stay powered
    off after the host boots. Only the management guest returns by itself, which
    makes the result look like a partial recovery.

    This script does three things in order:

      1. Restores the cost governance tags. Deployment automation writes a
         progress tag by replacing the tag set rather than merging into it, which
         silently removes CostControl. In subscriptions with cost automation, a
         host without that tag gets deallocated, including mid-deployment.
      2. Starts the host and waits for it to report running.
      3. Starts every nested guest that is powered off.

    It does not wait for the cluster to reconnect. That takes longer and is
    reported separately by Get-LabPowerState.ps1.

.PARAMETER SubscriptionId
    Subscription containing the lab.

.PARAMETER ResourceGroup
    Resource group containing the host virtual machine.

.PARAMETER HostVmName
    The Azure virtual machine that hosts the nested lab.

.PARAMETER SkipTags
    Do not touch tags. Use when your subscription has no cost automation, or
    when tag writes are denied by policy.

.EXAMPLE
    .\Start-Lab.ps1 -SubscriptionId <sub> -ResourceGroup <rg>

.EXAMPLE
    .\Start-Lab.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -SkipTags
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$HostVmName = 'LocalBox-Client',
    [switch]$SkipTags
)

$ErrorActionPreference = 'Stop'

function Write-Stage { param([string]$m) Write-Host ''; Write-Host $m -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "  OK    $m" -ForegroundColor Green }
function Write-Skip  { param([string]$m) Write-Host "  SKIP  $m" -ForegroundColor DarkGray }
function Write-Info  { param([string]$m) Write-Host "        $m" -ForegroundColor Gray }
function Write-Warn2 { param([string]$m) Write-Host "  WARN  $m" -ForegroundColor Yellow }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is not on PATH.'
}

Write-Host ''
Write-Host "Start lab  $ResourceGroup / $HostVmName" -ForegroundColor White

# ----- Stage 1: protect against another deallocation -------------------------

Write-Stage 'Cost governance tags'

if ($SkipTags) {
    Write-Skip 'SkipTags was specified'
}
else {
    $existing = az resource show `
        --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName `
        --resource-type Microsoft.Compute/virtualMachines `
        --query tags -o json 2>$null | ConvertFrom-Json

    $hasCostControl = $existing -and $existing.PSObject.Properties.Name -contains 'CostControl'

    if ($hasCostControl) {
        Write-Skip 'CostControl already present'
    }
    else {
        # Rebuild the full tag set, because the tag command replaces rather than merges.
        $pairs = @('CostControl=Ignore', 'SecurityControl=Ignore')
        if ($existing) {
            foreach ($p in $existing.PSObject.Properties) {
                if ($p.Name -notin 'CostControl', 'SecurityControl') {
                    $pairs += "$($p.Name)=$($p.Value)"
                }
            }
        }

        & az resource tag `
            --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName `
            --resource-type Microsoft.Compute/virtualMachines `
            --tags $pairs -o none 2>$null

        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'CostControl and SecurityControl restored on the host'
        }
        else {
            Write-Warn2 'Could not write tags. The host may be deallocated again by cost automation.'
        }

        & az group update --subscription $SubscriptionId -n $ResourceGroup `
            --set tags.CostControl=Ignore tags.SecurityControl=Ignore -o none 2>$null

        if ($LASTEXITCODE -eq 0) { Write-Ok 'Tags restored on the resource group' }
    }
}

# ----- Stage 2: the Azure virtual machine ------------------------------------

Write-Stage 'Azure host'

$power = az vm get-instance-view `
    --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName `
    --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" `
    -o tsv 2>$null

if (-not $power) { throw "Host virtual machine '$HostVmName' not found in '$ResourceGroup'." }

if ($power -match 'running') {
    Write-Skip "already $power"
}
else {
    Write-Info "current state: $power"
    Write-Info 'starting, this usually takes a minute or two'

    & az vm start --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName -o none

    $power = az vm get-instance-view `
        --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName `
        --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" `
        -o tsv 2>$null

    if ($power -match 'running') { Write-Ok "host is $power" }
    else { throw "Host did not reach a running state. It reports: $power" }
}

# ----- Stage 3: the nested guests --------------------------------------------

Write-Stage 'Nested guests'

# A multi-line value passed inline to --scripts is flattened to a single line and
# silently does nothing, so the payload goes through a file.
$scriptFile = Join-Path $env:TEMP "start-lab-$([guid]::NewGuid().ToString('N')).ps1"
$body = @(
    '$ErrorActionPreference = "SilentlyContinue"'
    'if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { "NOHYPERV"; return }'
    '$vms = Get-VM'
    'if (-not $vms) { "NOVMS"; return }'
    '$off = $vms | Where-Object { $_.State -ne "Running" }'
    'if ($off) { Start-VM -Name $off.Name -ErrorAction SilentlyContinue; Start-Sleep -Seconds 10 }'
    'foreach ($v in (Get-VM)) { "{0}|{1}" -f $v.Name, $v.State }'
) -join "`r`n"

Set-Content -Path $scriptFile -Value $body -Encoding ascii

try {
    $raw = az vm run-command invoke `
        --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName `
        --command-id RunPowerShellScript `
        --scripts "@$scriptFile" `
        --query 'value[0].message' -o tsv 2>$null
}
finally {
    Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue
}

if (-not $raw) {
    Write-Warn2 'The host is running but did not answer. Its guest agent may still be starting.'
    Write-Info  'Run the script again in a few minutes.'
    return
}

if ($raw -match 'NOHYPERV') { Write-Warn2 'Hyper-V is not present on this host'; return }
if ($raw -match 'NOVMS')    { Write-Warn2 'No nested virtual machines found';    return }

$nested = @()
foreach ($line in ($raw -split "`n")) {
    $parts = $line.Trim() -split '\|'
    if ($parts.Count -eq 2 -and $parts[0]) {
        $nested += [pscustomobject]@{ Name = $parts[0]; State = $parts[1] }
    }
}

foreach ($vm in $nested) {
    if ($vm.State -eq 'Running') { Write-Ok "$($vm.Name) running" }
    else { Write-Warn2 "$($vm.Name) is $($vm.State)" }
}

# Counted without wrapping in @(), because @($null).Count returns 1 and would
# invent a stopped guest that does not exist.
$stillOff = $nested | Where-Object { $_.State -ne 'Running' }
$offCount = if ($null -eq $stillOff) { 0 } else { ($stillOff | Measure-Object).Count }

Write-Host ''

if ($offCount -eq 0) {
    Write-Host 'Both layers are up.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Running is not ready. The cluster and the resource bridge reconnect on their own,' -ForegroundColor DarkGray
    Write-Host 'which took about twenty minutes on a two node lab. Workload commands will fail'    -ForegroundColor DarkGray
    Write-Host 'until the bridge status reads Running.'                                            -ForegroundColor DarkGray
}
else {
    Write-Warn2 "$offCount guest(s) did not start. Check memory pressure on the host."
}

Write-Host ''
