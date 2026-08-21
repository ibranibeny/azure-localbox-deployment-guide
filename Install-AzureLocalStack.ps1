<#
.SYNOPSIS
    End-to-end setup for Azure Local VM management: resource providers, logical network,
    VM images (Windows and Linux), virtual machines, and optionally an AKS Arc cluster.

.DESCRIPTION
    This script automates the full path from a freshly deployed Azure Local instance to a
    running virtual machine. It is idempotent: every stage checks for existing resources and
    skips work that is already complete, so it is safe to re-run after a failure.

    Every step follows the official Microsoft Learn procedures referenced in NOTES.

.PARAMETER SubscriptionId
    Azure subscription that contains the Azure Local instance.

.PARAMETER ResourceGroup
    Resource group that contains the Azure Local instance.

.PARAMETER ClusterName
    Name of the Microsoft.AzureStackHCI/clusters resource.

.PARAMETER Location
    Azure region of the Azure Local instance, for example australiaeast.

.PARAMETER CustomLocationName
    Custom location created during Azure Local deployment.

.PARAMETER VmSwitchName
    Hyper-V external switch used by the logical network.

.PARAMETER LogicalNetworkName
    Name of the logical network to create for workload VMs and AKS nodes.

.PARAMETER AddressPrefix
    CIDR of the workload network.

.PARAMETER Gateway
    Default gateway inside AddressPrefix.

.PARAMETER DnsServers
    One or more DNS servers that can resolve the Azure Local cluster FQDN.

.PARAMETER Vlan
    VLAN ID for the workload network. Use 0 when untagged.

.PARAMETER IpPoolStart
    First address of the static IP pool. Required for AKS Arc.

.PARAMETER IpPoolEnd
    Last address of the static IP pool.

.PARAMETER WindowsImageSku
    Marketplace SKU for the Windows image. Not every SKU is downloadable in every
    subscription or region; the script reports clearly if the SKU cannot be served.

.PARAMETER IncludeLinuxImage
    Build a Linux image. Linux is not downloadable by URN, so the script provisions a
    temporary Azure VM, generalizes it, exports the OS disk, and imports the VHD.

.PARAMETER CreateVm
    Create a test virtual machine from one of the images.

.PARAMETER CreateAks
    Create an AKS Arc cluster on the logical network.

.PARAMETER SkipPrereqs
    Skip resource provider registration.

.EXAMPLE
    .\Install-AzureLocalStack.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
        -ClusterName <cluster> -Location australiaeast -CustomLocationName jumpstart

.EXAMPLE
    .\Install-AzureLocalStack.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
        -ClusterName <cluster> -Location australiaeast -CustomLocationName jumpstart `
        -IncludeLinuxImage -CreateVm -CreateAks

.NOTES
    Reference documentation:
      Prerequisites            https://learn.microsoft.com/azure/azure-local/manage/azure-arc-vm-management-prerequisites
      Logical networks         https://learn.microsoft.com/azure/azure-local/manage/create-logical-networks
      Marketplace VM image     https://learn.microsoft.com/azure/azure-local/manage/virtual-machine-image-azure-marketplace
      Ubuntu image preparation https://learn.microsoft.com/azure/azure-local/manage/virtual-machine-azure-marketplace-ubuntu
      Create VMs               https://learn.microsoft.com/azure/azure-local/manage/create-arc-virtual-machines
      AKS network requirements https://learn.microsoft.com/azure/aks/aksarc/aks-hci-network-system-requirements
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$ClusterName,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$CustomLocationName,

    [string]$VmSwitchName        = 'ConvergedSwitch(compute_management)',
    [string]$LogicalNetworkName  = 'azlocal-vm-lnet',
    [string]$AddressPrefix       = '192.168.200.0/24',
    [string]$Gateway             = '192.168.200.1',
    [string[]]$DnsServers        = @('192.168.1.254'),
    [int]$Vlan                   = 200,
    [string]$IpPoolStart         = '192.168.200.11',
    [string]$IpPoolEnd           = '192.168.200.60',

    [string]$WindowsImageName    = 'ws2022',
    [string]$WindowsImagePublisher = 'microsoftwindowsserver',
    [string]$WindowsImageOffer   = 'windowsserver',
    [string]$WindowsImageSku     = '2022-datacenter-azure-edition',

    [switch]$IncludeLinuxImage,
    [string]$LinuxImageName      = 'ubuntu2404',
    [string]$LinuxPrepResourceGroup = 'rg-linux-image-prep',
    [string]$LinuxPrepVmSize     = 'Standard_D2s_v5',

    [switch]$CreateVm,
    [string]$VmName              = 'vm01',
    [string]$VmAdminUsername     = 'azureuser',
    [int]$VmMemoryMb             = 4096,
    [int]$VmProcessors           = 2,

    [switch]$CreateAks,
    [string]$AksClusterName      = 'azlocal-aks',
    [int]$AksControlPlaneCount   = 1,
    [int]$AksNodeCount           = 1,

    [switch]$SkipPrereqs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --------------------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------------------

$script:StageNumber = 0

function Write-Stage {
    param([string]$Message)
    $script:StageNumber++
    Write-Host ''
    Write-Host ("[{0}] {1}" -f $script:StageNumber, $Message) -ForegroundColor Cyan
    Write-Host ('-' * 78) -ForegroundColor DarkGray
}

function Write-Step   { param([string]$Message) Write-Host "    $Message" }
function Write-Ok     { param([string]$Message) Write-Host "    OK    $Message" -ForegroundColor Green }
function Write-Skip   { param([string]$Message) Write-Host "    SKIP  $Message" -ForegroundColor DarkGray }
function Write-Warn   { param([string]$Message) Write-Host "    WARN  $Message" -ForegroundColor Yellow }
function Write-Fail   { param([string]$Message) Write-Host "    FAIL  $Message" -ForegroundColor Red }

# Azure CLI on Windows is a batch wrapper. Values are captured through Out-String and
# trimmed so a trailing carriage return never leaks into comparisons or resource IDs.
function Invoke-AzValue {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = (& az @Arguments 2>$null | Out-String)
    return $raw.Trim()
}

function Test-AzResource {
    param([Parameter(Mandatory)][string]$ResourceId, [string]$ApiVersion = '2025-04-01-preview')
    $out = (& az resource show --ids $ResourceId --api-version $ApiVersion -o none 2>&1)
    return $LASTEXITCODE -eq 0
}

# --------------------------------------------------------------------------------------
# Stage 1 - Tooling
# --------------------------------------------------------------------------------------

function Initialize-Tooling {
    Write-Stage 'Verifying tooling'

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is not installed. See https://learn.microsoft.com/cli/azure/install-azure-cli-windows'
    }
    Write-Ok "Azure CLI $(Invoke-AzValue @('version','--query','\"azure-cli\"','-o','tsv'))"

    foreach ($extension in 'stack-hci-vm', 'customlocation', 'aksarc') {
        $installed = Invoke-AzValue @('extension', 'show', '--name', $extension, '--query', 'version', '-o', 'tsv')
        if ([string]::IsNullOrWhiteSpace($installed)) {
            Write-Step "Installing extension $extension"
            & az extension add --name $extension --allow-preview true -o none
            Write-Ok "Installed $extension"
        }
        else {
            Write-Skip "$extension already installed ($installed)"
        }
    }

    & az account set --subscription $SubscriptionId
    $account = Invoke-AzValue @('account', 'show', '--query', 'name', '-o', 'tsv')
    Write-Ok "Subscription context: $account"
}

# --------------------------------------------------------------------------------------
# Stage 2 - Resource providers
# --------------------------------------------------------------------------------------

function Register-RequiredProviders {
    Write-Stage 'Registering resource providers'

    if ($SkipPrereqs) {
        Write-Skip 'SkipPrereqs was specified'
        return
    }

    # Microsoft.EdgeMarketplace is only exercised when downloading a Marketplace VM image,
    # so a missing registration surfaces late and looks unrelated to the real cause.
    $providers = @(
        'Microsoft.AzureStackHCI'
        'Microsoft.HybridCompute'
        'Microsoft.HybridConnectivity'
        'Microsoft.ExtendedLocation'
        'Microsoft.ResourceConnector'
        'Microsoft.KubernetesConfiguration'
        'Microsoft.Kubernetes'
        'Microsoft.HybridContainerService'
        'Microsoft.EdgeMarketplace'
    )

    foreach ($provider in $providers) {
        $state = Invoke-AzValue @('provider', 'show', '-n', $provider, '--query', 'registrationState', '-o', 'tsv')
        if ($state -eq 'Registered') {
            Write-Skip "$provider already registered"
        }
        else {
            Write-Step "Registering $provider (current: $state)"
            & az provider register --namespace $provider -o none
            Write-Ok "$provider registration requested"
        }
    }
}

# --------------------------------------------------------------------------------------
# Stage 3 - Control plane readiness
# --------------------------------------------------------------------------------------

function Test-ControlPlane {
    Write-Stage 'Checking Azure Local control plane'

    $clusterId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/clusters/$ClusterName"
    $clusterStatus = Invoke-AzValue @('resource', 'show', '--ids', $clusterId, '--api-version', '2024-04-01', '--query', 'properties.status', '-o', 'tsv')

    if ([string]::IsNullOrWhiteSpace($clusterStatus)) {
        throw "Cluster $ClusterName not found in $ResourceGroup."
    }
    if ($clusterStatus -eq 'DeploymentInProgress') {
        throw "Cluster deployment is still running. Wait for it to finish before creating VM resources."
    }
    Write-Ok "Cluster status: $clusterStatus"

    # provisioningState can report Succeeded while the appliance has not yet sent a
    # heartbeat, so the runtime status is the value that actually gates VM creation.
    $bridgeId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ResourceConnector/appliances/$ClusterName-arcbridge"
    $bridgeStatus = Invoke-AzValue @('resource', 'show', '--ids', $bridgeId, '--api-version', '2022-10-27', '--query', 'properties.status', '-o', 'tsv')

    if ($bridgeStatus -ne 'Running') {
        throw "Arc resource bridge status is '$bridgeStatus'. It must be 'Running' before VM resources can be created."
    }
    Write-Ok "Arc resource bridge: $bridgeStatus"

    $customLocationId = Invoke-AzValue @('customlocation', 'show', '-g', $ResourceGroup, '-n', $CustomLocationName, '--query', 'id', '-o', 'tsv')
    if ([string]::IsNullOrWhiteSpace($customLocationId)) {
        throw "Custom location '$CustomLocationName' not found."
    }
    Write-Ok "Custom location: $CustomLocationName"

    return $customLocationId
}

function Get-StoragePathId {
    Write-Stage 'Selecting storage path'

    $all = & az resource list -g $ResourceGroup --resource-type 'Microsoft.AzureStackHCI/storageContainers' -o json | ConvertFrom-Json
    if (-not $all -or $all.Count -eq 0) {
        throw 'No storage containers found. Create one with: az stack-hci-vm storagepath create'
    }

    $selected = $all[0]
    Write-Ok "Storage path: $($selected.name)"
    return $selected.id
}

# --------------------------------------------------------------------------------------
# Stage 4 - Logical network
# --------------------------------------------------------------------------------------

function New-WorkloadLogicalNetwork {
    param([Parameter(Mandatory)][string]$CustomLocationId)

    Write-Stage 'Creating logical network'

    $lnetId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/logicalNetworks/$LogicalNetworkName"

    if (Test-AzResource -ResourceId $lnetId) {
        $existing = & az resource show --ids $lnetId --api-version 2025-04-01-preview -o json | ConvertFrom-Json
        $pools = @($existing.properties.subnets[0].properties.ipPools)

        if ($pools.Count -eq 0) {
            # AKS Arc admission control rejects a logical network without an IP pool, and the
            # pool cannot be added afterwards because lnet update does not expose it.
            Write-Warn "Logical network exists but has no IP pool. AKS Arc will reject it."
            Write-Warn "Delete and re-run: az stack-hci-vm network lnet delete -g $ResourceGroup --name $LogicalNetworkName --yes"
        }
        else {
            Write-Skip "Logical network already exists with $($pools.Count) IP pool(s)"
        }
        return $lnetId
    }

    Write-Step "Creating $LogicalNetworkName ($AddressPrefix, VLAN $Vlan, pool $IpPoolStart-$IpPoolEnd)"

    # The switch name contains parentheses. On Windows az is a batch wrapper, so the value is
    # wrapped in embedded double quotes to stop cmd from splitting on the parentheses.
    $quotedSwitch = '"' + $VmSwitchName + '"'

    & az stack-hci-vm network lnet create `
        --resource-group $ResourceGroup `
        --custom-location $CustomLocationId `
        --location $Location `
        --name $LogicalNetworkName `
        --vm-switch-name $quotedSwitch `
        --ip-allocation-method 'static' `
        --address-prefixes $AddressPrefix `
        --gateway $Gateway `
        --dns-servers @DnsServers `
        --vlan $Vlan `
        --ip-pool-start $IpPoolStart `
        --ip-pool-end $IpPoolEnd `
        -o none

    Write-Ok "Logical network created"
    return $lnetId
}

# --------------------------------------------------------------------------------------
# Stage 5 - Windows image
# --------------------------------------------------------------------------------------

function New-WindowsImage {
    param(
        [Parameter(Mandatory)][string]$CustomLocationId,
        [Parameter(Mandatory)][string]$StoragePathId
    )

    Write-Stage 'Creating Windows VM image from Azure Marketplace'

    $imageId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/marketplaceGalleryImages/$WindowsImageName"

    if (Test-AzResource -ResourceId $imageId) {
        $existing = & az resource show --ids $imageId --api-version 2025-04-01-preview -o json | ConvertFrom-Json
        if ($existing.properties.provisioningState -eq 'Failed') {
            Write-Warn "Existing image is in Failed state. Deleting so it can be retried."
            & az stack-hci-vm image delete -g $ResourceGroup --name $WindowsImageName --yes -o none
        }
        else {
            Write-Skip "Image $WindowsImageName already exists ($($existing.properties.provisioningState), $($existing.properties.status.progressPercentage)%)"
            return $WindowsImageName
        }
    }

    Write-Step "Downloading $WindowsImagePublisher/$WindowsImageOffer/$WindowsImageSku"
    Write-Step 'This transfers roughly 30 GB and can take a long time.'

    $output = & az stack-hci-vm image create `
        --resource-group $ResourceGroup `
        --custom-location $CustomLocationId `
        --location $Location `
        --name $WindowsImageName `
        --os-type Windows `
        --publisher $WindowsImagePublisher `
        --offer $WindowsImageOffer `
        --sku $WindowsImageSku `
        --storage-path-id $StoragePathId 2>&1

    if ($LASTEXITCODE -ne 0) {
        $text = ($output | Out-String)

        if ($text -match 'SubscriptionNotRegistered') {
            Write-Fail 'Microsoft.EdgeMarketplace is not registered on this subscription.'
            Write-Step 'Fix: az provider register --namespace Microsoft.EdgeMarketplace'
        }
        elseif ($text -match 'GenerateTokenFromEdgeMarketplaceServiceFailed') {
            # The catalog resolves the version but refuses to issue a download SAS, which
            # means this specific SKU is not servable rather than misconfigured access.
            Write-Fail "This SKU cannot be served to your subscription or region."
            Write-Step 'Try a different SKU, for example 2022-datacenter-azure-edition.'
        }
        else {
            Write-Fail ($text.Trim())
        }
        return $null
    }

    Write-Ok "Windows image created"
    return $WindowsImageName
}

# --------------------------------------------------------------------------------------
# Stage 6 - Linux image
# --------------------------------------------------------------------------------------

function New-LinuxImage {
    param(
        [Parameter(Mandatory)][string]$CustomLocationId,
        [Parameter(Mandatory)][string]$StoragePathId
    )

    Write-Stage 'Creating Linux VM image by exporting a prepared Azure VM disk'

    $imageId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/galleryImages/$LinuxImageName"
    if (Test-AzResource -ResourceId $imageId) {
        Write-Skip "Image $LinuxImageName already exists"
        return $LinuxImageName
    }

    $prepVm = 'linux-imgprep'
    Write-Step "Creating temporary preparation VM in $LinuxPrepResourceGroup"

    & az group create -n $LinuxPrepResourceGroup -l $Location -o none

    # No inbound rules: preparation runs through Run Command, so SSH is never exposed.
    & az vm create `
        -g $LinuxPrepResourceGroup -n $prepVm `
        --image Ubuntu2404 --size $LinuxPrepVmSize `
        --admin-username imgprep --generate-ssh-keys `
        --nsg-rule NONE -o none

    Write-Ok 'Preparation VM created'

    $prepScript = Join-Path ([IO.Path]::GetTempPath()) 'prep-linux-image.sh'
    $scriptBody = @'
set -eu
cloud-init clean
rm -rf /var/lib/cloud/ || true
rm -rf /tmp/* || true
rm -rf /var/log/* || true
rm -f /etc/ssh/ssh_host*
echo 'datasource_list: [ NoCloud ]' > /etc/cloud/cloud.cfg.d/90_dpkg.cfg
cat /etc/cloud/cloud.cfg.d/90_dpkg.cfg
echo PREP_DONE
'@

    # Written with explicit LF bytes: a CRLF script fails inside Linux with a $'\r' error.
    [IO.File]::WriteAllText($prepScript, ($scriptBody -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))

    Write-Step 'Generalizing the image (cloud-init datasource set to NoCloud)'
    $result = Invoke-AzValue @('vm', 'run-command', 'invoke', '-g', $LinuxPrepResourceGroup, '-n', $prepVm,
        '--command-id', 'RunShellScript', '--scripts', "@$prepScript", '--query', 'value[0].message', '-o', 'tsv')

    Remove-Item $prepScript -Force -ErrorAction SilentlyContinue

    if ($result -notmatch 'PREP_DONE') {
        Write-Fail 'Image preparation did not complete.'
        Write-Step $result
        return $null
    }
    Write-Ok 'Image generalized'

    Write-Step 'Stopping VM and exporting the OS disk'
    & az vm deallocate -g $LinuxPrepResourceGroup -n $prepVm -o none

    $diskId = Invoke-AzValue @('vm', 'show', '-g', $LinuxPrepResourceGroup, '-n', $prepVm,
        '--query', 'storageProfile.osDisk.managedDisk.id', '-o', 'tsv')

    # The response property is accessSAS. Using accessSas returns an empty string silently,
    # and the failure then appears much later as an incomplete image specification.
    $sas = Invoke-AzValue @('disk', 'grant-access', '--ids', $diskId,
        '--duration-in-seconds', '86400', '--access-level', 'Read', '--query', 'accessSAS', '-o', 'tsv')

    if ([string]::IsNullOrWhiteSpace($sas)) {
        Write-Fail 'Could not obtain a SAS URL for the OS disk.'
        return $null
    }
    Write-Ok "Disk export URL acquired (length $($sas.Length))"

    Write-Step 'Importing the VHD into Azure Local'
    & az stack-hci-vm image create `
        --resource-group $ResourceGroup `
        --custom-location $CustomLocationId `
        --location $Location `
        --name $LinuxImageName `
        --os-type Linux `
        --image-path ('"' + $sas + '"') `
        --storage-path-id $StoragePathId -o none

    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Linux image import failed.'
        return $null
    }

    Write-Ok "Linux image created"
    Write-Step "Revoke access and remove the temporary resources when the image reports 100%:"
    Write-Step "  az disk revoke-access --ids $diskId"
    Write-Step "  az group delete -n $LinuxPrepResourceGroup --yes"

    return $LinuxImageName
}

# --------------------------------------------------------------------------------------
# Stage 7 - Virtual machine
# --------------------------------------------------------------------------------------

function New-WorkloadVm {
    param(
        [Parameter(Mandatory)][string]$CustomLocationId,
        [Parameter(Mandatory)][string]$StoragePathId,
        [Parameter(Mandatory)][string]$ImageName,
        [Parameter(Mandatory)][string]$OsType
    )

    Write-Stage "Creating virtual machine $VmName"

    $vmId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/virtualMachineInstances/$VmName"
    if (Test-AzResource -ResourceId $vmId) {
        Write-Skip "VM $VmName already exists"
        return
    }

    $nicName = "$VmName-nic"
    $nicId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/networkInterfaces/$nicName"

    if (-not (Test-AzResource -ResourceId $nicId)) {
        Write-Step "Creating network interface $nicName"
        & az stack-hci-vm network nic create `
            --resource-group $ResourceGroup `
            --custom-location $CustomLocationId `
            --location $Location `
            --name $nicName `
            --subnet-id $LogicalNetworkName -o none
        Write-Ok 'Network interface created'
    }
    else {
        Write-Skip "Network interface $nicName already exists"
    }

    # A password is mandatory even for key based Linux logins, so a random one is generated
    # here and never persisted. Interactive login is expected to use the SSH key.
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $generatedPassword = 'Az' + [Convert]::ToHexString($bytes) + '!9'

    $arguments = @(
        'stack-hci-vm', 'create',
        '--resource-group', $ResourceGroup,
        '--custom-location', $CustomLocationId,
        '--location', $Location,
        '--name', $VmName,
        '--image', $ImageName,
        '--admin-username', $VmAdminUsername,
        '--nics', $nicName,
        '--hardware-profile', "memory-mb=$VmMemoryMb", "processors=$VmProcessors",
        '--storage-path-id', $StoragePathId
    )

    if ($OsType -eq 'Linux') {
        $publicKey = Join-Path $env:USERPROFILE '.ssh\id_rsa.pub'
        if (-not (Test-Path $publicKey)) {
            throw "SSH public key not found at $publicKey. Generate one with ssh-keygen."
        }
        $arguments += @(
            '--authentication-type', 'ssh',
            '--ssh-key-values', $publicKey,
            '--ssh-dest-key-path', "/home/$VmAdminUsername/.ssh/authorized_keys",
            '--admin-password', $generatedPassword
        )
        Write-Step 'Linux VM: authentication uses your SSH public key'
    }
    else {
        $secure = Read-Host "Enter the Windows administrator password for $VmName" -AsSecureString
        $plain = [Net.NetworkCredential]::new('', $secure).Password
        $arguments += @('--admin-password', $plain)
        Write-Step 'Windows VM: password captured from prompt, not stored'
    }

    Write-Step 'Provisioning (this usually takes several minutes)'
    & az @arguments -o none

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "VM creation failed"
        return
    }

    Write-Ok "VM $VmName created"
}

# --------------------------------------------------------------------------------------
# Stage 8 - AKS Arc
# --------------------------------------------------------------------------------------

function New-AksArcCluster {
    param(
        [Parameter(Mandatory)][string]$CustomLocationId,
        [Parameter(Mandatory)][string]$LogicalNetworkId
    )

    Write-Stage "Creating AKS Arc cluster $AksClusterName"

    $existing = Invoke-AzValue @('aksarc', 'show', '-g', $ResourceGroup, '-n', $AksClusterName, '--query', 'name', '-o', 'tsv')
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Skip "AKS cluster $AksClusterName already exists"
        return
    }

    # AKS Arc validates the logical network before provisioning and refuses one without an
    # IP pool, so this is checked here to fail with a clear message instead of a webhook error.
    $lnet = & az resource show --ids $LogicalNetworkId --api-version 2025-04-01-preview -o json | ConvertFrom-Json
    $pools = @($lnet.properties.subnets[0].properties.ipPools)
    if ($pools.Count -eq 0) {
        Write-Fail "Logical network has no IP pool. AKS Arc admission control will reject it."
        Write-Step 'Recreate the logical network with -IpPoolStart and -IpPoolEnd.'
        return
    }
    Write-Ok "Logical network has an IP pool ($($pools[0].start) - $($pools[0].end))"

    Write-Step "Creating cluster with $AksControlPlaneCount control plane node(s) and $AksNodeCount worker node(s)"
    & az aksarc create `
        --resource-group $ResourceGroup `
        --name $AksClusterName `
        --custom-location $CustomLocationId `
        --vnet-ids $LogicalNetworkId `
        --generate-ssh-keys `
        --control-plane-count $AksControlPlaneCount `
        --node-count $AksNodeCount -o none

    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'AKS cluster creation failed.'
        return
    }

    Write-Ok "AKS cluster $AksClusterName created"
    Write-Step "Get credentials: az aksarc get-credentials -g $ResourceGroup -n $AksClusterName"
}

# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------

$startedAt = Get-Date

Write-Host ''
Write-Host 'Azure Local end-to-end setup' -ForegroundColor White
Write-Host "Cluster $ClusterName in $ResourceGroup ($Location)" -ForegroundColor DarkGray

try {
    Initialize-Tooling
    Register-RequiredProviders

    $customLocationId = Test-ControlPlane
    $storagePathId    = Get-StoragePathId
    $logicalNetworkId = New-WorkloadLogicalNetwork -CustomLocationId $customLocationId

    $windowsImage = New-WindowsImage -CustomLocationId $customLocationId -StoragePathId $storagePathId

    $linuxImage = $null
    if ($IncludeLinuxImage) {
        $linuxImage = New-LinuxImage -CustomLocationId $customLocationId -StoragePathId $storagePathId
    }

    if ($CreateVm) {
        if ($linuxImage) {
            New-WorkloadVm -CustomLocationId $customLocationId -StoragePathId $storagePathId -ImageName $linuxImage -OsType 'Linux'
        }
        elseif ($windowsImage) {
            New-WorkloadVm -CustomLocationId $customLocationId -StoragePathId $storagePathId -ImageName $windowsImage -OsType 'Windows'
        }
        else {
            Write-Warn 'No image is available, skipping VM creation.'
        }
    }

    if ($CreateAks) {
        New-AksArcCluster -CustomLocationId $customLocationId -LogicalNetworkId $logicalNetworkId
    }

    Write-Stage 'Summary'
    Write-Ok "Completed in $([int]((Get-Date) - $startedAt).TotalMinutes) minute(s)"
    Write-Step 'Images can still be downloading. Check progress with:'
    Write-Step "  az stack-hci-vm image list -g $ResourceGroup -o table"
}
catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    exit 1
}
