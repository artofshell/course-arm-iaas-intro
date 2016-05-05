### Stop the script immediately when an error occurs.
$ErrorActionPreference = 'Stop';

### Authenticate to Microsoft Azure
$AzureUsername = 'aos@artofshell.com';
$AzureCredential = Get-Credential -UserName $AzureUsername -Message 'Please enter your Microsoft Azure password.';
Add-AzureRmAccount -Credential $AzureCredential;
Write-Verbose -Message 'Finished authenticating to Microsoft Azure';


### Create an Azure Resource Manager (ARM) Resource Group
$ResourceGroup = @{
    Force = $true;
    Name = 'ArtofShell-VM';
    Location = 'West Europe';
}
New-AzureRmResourceGroup @ResourceGroup;
#endregion

#region Create an Availability Set for the Virtual Machine(s)
$AvailabilitySet = @{
    ResourceGroupName = $ResourceGroup.Name;
    Location = $ResourceGroup.Location;
    Name = 'VMAVSet';
    PlatformUpdateDomainCount = 3;
    PlatformFaultDomainCount = 3;
}
$AvailabilitySet = New-AzureRmAvailabilitySet @AvailabilitySet;
#endregion

### Deploy the Storage Account for Virtual Machine VHDs and custom images (optional)
$StorageAccount = @{
    ResourceGroupName = $ResourceGroup.Name;
    Name = 'artofshellvms';
    Type = 'Premium_LRS';
    Location = $ResourceGroup.Location;
}
if (!(Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroup.Name -Name $StorageAccount.Name -ErrorAction Ignore)) {
    New-AzureRmStorageAccount @StorageAccount;
}

### Define the subnets for the Virtual Network
$SubnetConfigList = @(
    @{
        Name = 'WebServers';
        AddressPrefix = '10.5.5.0/24';
    },
    @{
        Name = 'Database';
        AddressPrefix = '10.5.4.0/24';
    }
)
$SubnetObjectList = @();
foreach ($Subnet in $SubnetConfigList) {
    $SubnetObjectList += New-AzureRmVirtualNetworkSubnetConfig @Subnet;
} 

### Create a Virtual Network
$VirtualNetwork = @{
    ResourceGroupName = $ResourceGroup.Name;
    Name = 'ArtofShell';
    Location = $ResourceGroup.Location;
    Subnet = $SubnetObjectList;
    AddressPrefix = @('10.5.0.0/16');
    Tag = @( ### We can build an array of key-value pairs (Azure Resource Manager (ARM) tags) and apply it to a Resource Group or any Resource.
             ### To search for these objects later on, we can use Find-AzureRmResource or Find-AzureRmResourceGroup
        @{ Name = 'Company'; Value = 'ArtofShell'; };
        @{ Name = 'Department'; Value = 'Information Technology'; };
    )
    Force = $true;
}
$VirtualNetworkObject = New-AzureRmVirtualNetwork @VirtualNetwork;

#region Create Network Security Group
$NetworkSecurityRule = @{
    Name = 'InboundRdp';
    Protocol = 'TCP';
    SourcePortRange = '*';
    DestinationPortRange = '3389';
    Description = 'Enables RDP access to Virtual Machines';
    SourceAddressPrefix = '*';
    DestinationAddressPrefix = '10.5.0.0/16';
    Access = 'Allow';
    Priority = 200;
    Direction = 'Inbound';
    };
$NetworkSecurityRuleObject = New-AzureRmNetworkSecurityRuleConfig @NetworkSecurityRule

$NetworkSecurityGroup = @{
    ResourceGroupName = $ResourceGroup.Name;
    Name = 'aos-nsg';
    Location = $ResourceGroup.Location;
    Force = $true;
    SecurityRules = $NetworkSecurityRuleObject;
    }
$NetworkSecurityGroupObject = New-AzureRmNetworkSecurityGroup @NetworkSecurityGroup;

### Update the Virtual Network
Set-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $VirtualNetworkObject -Name WebServers -AddressPrefix 10.5.5.0/24 -NetworkSecurityGroup $NetworkSecurityGroupObject;
Set-AzureRmVirtualNetwork -VirtualNetwork $VirtualNetworkObject;
#endregion

#region Create a Public IP Address
$PublicIP = @{
    ResourceGroupName = $ResourceGroup.Name;
    Name = 'LB-ArtofShell-PublicIP';
    DomainNameLabel = 'artofshell-vm';
    AllocationMethod = 'Dynamic';
    Location = $ResourceGroup.Location;
    Force = $true;
}
$LBPublicIP = New-AzureRmPublicIpAddress @PublicIP;
#endregion

#region Deploy a Microsoft Azure Load Balancer

### Create a "front-end configuration" for the Load Balancer. This is where external endpoints will hit the Load Balancer to 
### access the services that are hosted in the Load Balancer's backend address pool.
$LBFrontEnd = New-AzureRmLoadBalancerFrontendIpConfig -Name FrontEndConfig -PublicIpAddress $LBPublicIP;

### If we need the ability to access individual services on specific Virtual Machines, we can set up Network Address Translation (NAT) rules
### that forward traffic to the specific Network Interface on a specific port. The NAT Rules are added to the Load Balancer when it's created,
### but the NAT rules must also be added to the Network Interfaces that they're destined for.
$NATRuleList = @(
    @{
        Name = 'RDP-VM1';
        FrontEndIpConfiguration = $LBFrontEnd;
        Protocol = 'TCP';
        FrontEndPort = '40000';
        BackendPort = 3389;
    }
)
$NATRuleObjectList = @();
foreach ($NATRule in $NATRuleList) {
  $NATRuleObjectList = New-AzureRmLoadBalancerInboundNatRuleConfig @NATRule;
}

### Create a backend address pool for the Load Balancer. The backend address pool itself only has a Name. 
### When Azure Network Interface resources are provisioned, they must be assocated to the backend address pool, in order for them to be load balanced.
$LBBackEndPool = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name LBBackendWeb;

### Define a Load Balancer Health Probe
$LBHealthProbe = @{
    Name = 'HealthProbe';
    RequestPath = 'HealthProbe.aspx';
    Protocol = 'http';
    Port = 80;
    IntervalInSeconds = 15;
    ProbeCount = 2;
}
$LBHealthProbe = New-AzureRmLoadBalancerProbeConfig @LBHealthProbe;

$LBRuleList = @(
  @{
    Name = 'HTTP';
    FrontEndIpConfiguration = $LBFrontEnd;
    BackendAddressPool = $LBBackEndPool;
    Probe = $LBHealthProbe;
    Protocol = 'TCP';
    FrontEndPort = 80;
    BackendPort = 80;
  }
)
$LBRuleObjectList = @();
foreach ($LBRule in $LBRuleList) {
  $LBRuleObjectList += New-AzureRmLoadBalancerRuleConfig @LBRule;
}

$LoadBalancer = @{
  ResourceGroupName = $ResourceGroup.Name;
  Name = 'ArtofShellLoadBalancer';
  Location = $ResourceGroup.Location;
  FrontEndIpConfiguration = $LBFrontEnd;
  InboundNatRule = $NATRuleObjectList;
  LoadBalancingRule = $LBRuleObjectList;
  BackendAddressPool = $LBBackEndPool;
  Probe = $LBHealthProbe;
  Force = $true;
}
$LoadBalancerObject = New-AzureRmLoadBalancer @LoadBalancer;
#endregion

#region Create Microsoft Azure Network Interface
$NetworkInterfaceList = @(
    @{
        ResourceGroupName = $ResourceGroup.Name;
        Name = 'nic-web01';
        Subnet = $VirtualNetworkObject.Subnets[0];
        Location = $ResourceGroup.Location;
        LoadBalancerInboundNatRule = $LoadBalancerObject.InboundNatRules.Where({ $PSItem.Name -eq 'RDP-VM1'; });
        LoadBalancerBackendAddressPool = $LoadBalancerObject.BackendAddressPools.Where({ $PSItem.Name -eq 'LBBackendWeb'; });
        Force = $true;
    }
)
$NICObjectList = @();
foreach ($NetworkInterface in $NetworkInterfaceList) {
    $NICObjectList += New-AzureRmNetworkInterface @NetworkInterface;
}
#endregion

#region Create Microsoft Azure Virtual Machine
$VirtualMachine = @{
    VMName = 'aos-web01';
    VMSize = 'Standard_DS1';
    AvailabilitySetId = $AvailabilitySet.Id;
    };
$VMObject = New-AzureRmVmConfig @VirtualMachine;

### Set up the configuration for the target operating system on the Virtual Machine
$VMOSConfig = @{
    VM = $VMObject;
    ComputerName = $VirtualMachine.VMName;
    Windows = $true;
    ProvisionVMAgent = $true;
    EnableAutoUpdate = $true;
    Credential = Get-Credential -UserName artofshell -Message 'Please enter a password for the Microsoft Azure Virtual Machine.';
    };
Set-AzureRmVMOperatingSystem @VMOSConfig;

### Configure the source image for the Virtual Machine
function Select-AzureRmVMImage {
    [OutputType('System.Collections.HashTable')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine] $VM
    )

    $ImagePublisher = Get-AzureRmVMImagePublisher -Location 'West US' | Out-GridView -Title 'Please select an image publisher' -OutputMode Single;
    $ImageOffer = Get-AzureRmVMImageOffer -Location 'West US' -PublisherName $ImagePublisher.PublisherName | Out-GridView -Title 'Please select an image offer' -OutputMode Single;
    $ImageSku = Get-AzureRmVMImageSku -Location 'West US' -PublisherName $ImagePublisher.PublisherName -Offer $ImageOffer.Offer | Out-GridView -Title 'Please select an image SKU' -OutputMode Single;
    $Image = Get-AzureRmVMImage -Location 'West US' -PublisherName $ImagePublisher.PublisherName -Offer $ImageOffer.Offer -Skus $ImageSku.Skus | Out-GridView -Title 'Please select an image version' -OutputMode Single;

    Write-Output -InputObject @{
        Publisher = $ImagePublisher.PublisherName;
        Offer = $ImageOffer.Offer;
        Sku = $ImageSku.Skus
        Version = $Image.Version;
        VM = $VMObject;
    }
}
<#
$VMImage = @{
    Publisher = 'Microsoft';           ### Find publishers using Get-AzureRmVMImagePublisher -Location westus
    Offer = 'microsoftwindowsserver';  ### Find offers using Get-AzureRmVMImageOffer -Location westus -PublisherName <PublisherName>
    Sku = 'windowsserver';             ### Find SKUs using Get-AzureRmVMImageSku -Location westus -PublisherName <PublisherName> -Offer <OfferName>
    Version = '';                      ### Find Versions using Get-AzureRmVMImage -Location westus -PublisherName <PublisherName> -Offer <OfferName> -Sku <SkuName>
    VM = $VMObject;
    };
#>
$VMImage = Select-AzureRmVMImage -VM $VMObject;
Set-AzureRmVMSourceImage @VMImage;

### Configure the Operating System disk for the Virtual Machine
$VMOSDisk = @{
    VM = $VMObject;
    Name = '{0}-os' -f $VirtualMachine.VMName;
    VhdUri = 'https://{0}.blob.core.windows.net/vhds/{1}-osdisk.vhd' -f $StorageAccount.Name, $VirtualMachine.Name;
    CreateOption = 'FromImage';
    #Windows = $true;
    };
Set-AzureRmVMOSDisk @VMOSDisk;

### Add the Network Interface (created earlier) to the Virtual Machine
$VMNetworkInterface = @{
    VM = $VMObject;
    Id = $NICObjectList[0].Id;
    };
$null = Add-AzureRmVMNetworkInterface @VMNetworkInterface;

### Create the Virtual Machine in the specified Resource Group
$NewVM = @{
    ResourceGroupName = $ResourceGroup.Name;
    Location = $ResourceGroup.Location;
    VM = $VMObject;
    };
New-AzureRmVm @NewVm;
#endregion

