#Requires -Version 5.1
<#
.SYNOPSIS
    Reports the power state of a nested Azure Local lab, both layers at once.

.DESCRIPTION
    A nested lab has two layers, and checking only the first one is misleading.
    The outer Azure virtual machine can report "VM running" while the nested nodes
    inside it are still powered off, because those guests are configured with an
    automatic start action of Nothing. This script reports both, then states
    plainly whether the lab is usable.

    Read-only. It never starts, stops, or changes anything.

.PARAMETER SubscriptionId
    Subscription containing the lab.

.PARAMETER ResourceGroup
    Resource group containing the host virtual machine.

.PARAMETER HostVmName
    The Azure virtual machine that hosts the nested lab.

.PARAMETER SkipNested
    Report only the Azure layer and do not query inside the host.

.EXAMPLE
    .\Get-LabPowerState.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -HostVmName LocalBox-Client
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$HostVmName = 'LocalBox-Client',
    [switch]$SkipNested
)

$ErrorActionPreference = 'Stop'

function Write-Line {
    param([string]$Label, [string]$Value, [string]$Colour = 'Gray')
    Write-Host ('  {0,-22}' -f $Label) -NoNewline
    Write-Host $Value -ForegroundColor $Colour
}

function Get-StateColour {
    param([string]$State)
    switch -Regex ($State) {
        'running|Running'          { 'Green'; break }
        'deallocated|stopped|Off'  { 'Yellow'; break }
        default                    { 'Red' }
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is not on PATH.'
}

Write-Host ''
Write-Host "Lab power state  $ResourceGroup / $HostVmName" -ForegroundColor White
Write-Host ''

# ----- Layer 1: the Azure virtual machine ------------------------------------

Write-Host 'Azure host' -ForegroundColor Cyan

$power = az vm get-instance-view `
    --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName `
    --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" `
    -o tsv 2>$null

if (-not $power) {
    Write-Line 'state' 'not found' 'Red'
    Write-Host ''
    Write-Host 'The host virtual machine does not exist in this resource group.' -ForegroundColor Red
    return
}

$size = az vm show --subscription $SubscriptionId -g $ResourceGroup -n $HostVmName `
    --query 'hardwareProfile.vmSize' -o tsv 2>$null

Write-Line 'state' $power (Get-StateColour $power)
Write-Line 'size'  $size

$hostRunning = $power -match 'running'

if (-not $hostRunning) {
    Write-Host ''
    Write-Host 'Host is not running, so the lab is unavailable.' -ForegroundColor Yellow
    Write-Host 'Starting it is a two step operation: start the host, then start the nested nodes.' -ForegroundColor Yellow
    Write-Host "  az vm start -g $ResourceGroup -n $HostVmName" -ForegroundColor DarkGray
    return
}

if ($SkipNested) { return }

# ----- Layer 2: the nested guests --------------------------------------------

Write-Host ''
Write-Host 'Nested guests' -ForegroundColor Cyan

# Written to a file because a multi-line value passed inline to --scripts is
# flattened to one line and silently becomes a no-op.
$scriptFile = Join-Path $env:TEMP "lab-power-$([guid]::NewGuid().ToString('N')).ps1"
$body = @(
    '$ErrorActionPreference = "SilentlyContinue"'
    'if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { "NOHYPERV"; return }'
    '$vms = Get-VM'
    'if (-not $vms) { "NOVMS"; return }'
    'foreach ($v in $vms) { "{0}|{1}|{2}" -f $v.Name, $v.State, [math]::Round($v.MemoryAssigned/1GB,1) }'
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
    Write-Line 'result' 'no response from guest' 'Red'
    Write-Host ''
    Write-Host 'The host is running but did not answer. The guest agent may still be starting.' -ForegroundColor Yellow
    return
}

if ($raw -match 'NOHYPERV') {
    Write-Line 'result' 'Hyper-V not present on this host' 'Yellow'
    return
}

$nested = @()
foreach ($line in ($raw -split "`n")) {
    $parts = $line.Trim() -split '\|'
    if ($parts.Count -eq 3 -and $parts[0]) {
        $nested += [pscustomobject]@{
            Name     = $parts[0]
            State    = $parts[1]
            MemoryGB = $parts[2]
        }
    }
}

if ($nested.Count -eq 0) {
    Write-Line 'result' 'no nested virtual machines found' 'Yellow'
    return
}

foreach ($vm in $nested) {
    $detail = if ($vm.State -eq 'Running') { "$($vm.State)   $($vm.MemoryGB) GB" } else { $vm.State }
    Write-Line $vm.Name $detail (Get-StateColour $vm.State)
}

# ----- Verdict ----------------------------------------------------------------

# Count without wrapping in @(), because @($null).Count returns 1 and would
# report guests that do not exist.
$stopped = $nested | Where-Object { $_.State -ne 'Running' }
$stoppedCount = if ($null -eq $stopped) { 0 } else { ($stopped | Measure-Object).Count }

Write-Host ''

if ($stoppedCount -eq 0) {
    Write-Host 'Both layers are running.' -ForegroundColor Green
    Write-Host 'Note that running is not the same as ready. After a restart the cluster and the' -ForegroundColor DarkGray
    Write-Host 'resource bridge need time to reconnect before workload commands will succeed.' -ForegroundColor DarkGray
}
else {
    Write-Host "Host is running but $stoppedCount nested guest(s) are not." -ForegroundColor Yellow
    Write-Host 'This is the state that looks like a broken cluster and is not. Start them on the host:' -ForegroundColor Yellow
    $names = ($stopped | ForEach-Object { $_.Name }) -join ','
    Write-Host "  Start-VM -Name $names" -ForegroundColor DarkGray
}

Write-Host ''
