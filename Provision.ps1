<#
 .SYNOPSIS
    Provisions Azure RM virtual machines.

 .DESCRIPTION
    Provisions Azure RM virtual machines based on a simple json config file. A simplified alternative to using Azure RM templates.

 .PARAMETER MachineConfigFilePath
    The path of the configuration file for the virtual machines. If the file does not exist, it will be created.

 .PARAMETER Init
    Creates an empty configuration file. 
#>

param(
 [string]
 $MachineConfigFilePath = "MachineConfig.json",
 [string]
 $Init = $false
)

if ((Test-Path -Path "MachineConfig.json") -eq $false -or $Init -eq $true) {
    Get-Content -Path ".\MachineConfig.jsontemplate.json" | Out-File -FilePath "MachineConfig.json"
}

$vmConfigurations = (Get-Content $machineConfigFilePath) -Join "`n" | ConvertFrom-Json
$profilePath =  $env:TEMP + "\CurrentAzureProfile.json"

if ($vmConfigurations.subscriptionName -eq $null) {
    Write-Error "Missing subscription name in config file"
    Exit
}

Install-Module AzureRM
$azureContext = $null
$azureContext = Get-AzureRmContext -ErrorAction SilentlyContinue
if ($azureContext -eq $null) {
    Write-Host "Logging in...";
    Login-AzureRmAccount -ErrorAction Stop;
}
Save-AzureRmProfile -Path $profilePath -ErrorAction Stop -Force
Write-Warning "Exporting current Azure RM profile to " + $profilePath + ". This file contains subscription information and current tokens."
Get-AzureRmSubscription –subscriptionName $vmConfigurations.subscriptionName | Select-AzureRmSubscription -ErrorAction Stop

$credential = Get-Credential -UserName $administratorUsername -Message "Choose a password the local administrator account."

foreach ($resourceGroup in $vmConfigurations.resourceGroups) {
    $azureResourceGroup = $null
    $azureResourceGroup = Get-AzureRmResourceGroup -Name $resourceGroup.groupName -Location $resourceGroup.location
    if ($azureResourceGroup -eq $null) {
        New-AzureRmResourceGroup -Name $resourceGroup.groupName -Location $resourceGroup.location
    }
    foreach ($storageAccount in $resourceGroup.storageAccounts) {
        $azureStorageAccount = Get-AzureRmStorageAccountNameAvailability $storageAccount.storageAccountName
        if ($azureStorageAccount.NameAvailable -eq $false) {
            $azureStorageAccount = Get-AzureRmStorageAccount -Name $storageAccount.storageAccountName -resourceGroupName $resourceGroup.groupName
        } else {
            $azureStorageAccount = New-AzureRmStorageAccount -resourceGroupName $resourceGroup.groupName -Name $storageAccount.storageAccountName -SkuName $storageAccount.sku -Kind $storageAccount.kind -Location $resourceGroup.location
        }
    }
    foreach ($availabilitySet in $resourceGroup.availabilitySets) {
        $azureAvailabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $resourceGroup.groupName -Name $availabilitySet.availabilitySetName -ErrorAction SilentlyContinue
        if ($azureAvailabilitySet -eq $null) {
            $azureAvailabilitySet = New-AzureRmAvailabilitySet -Name $availabilitySet.availabilitySetName -ResourceGroupName $resourceGroup.groupName -Location $resourceGroup.location
        }
    }
    foreach ($vm in $resourceGroup.vms) {
        foreach ($networkInterface in $vm.networkInterfaces) {
            $virtualNetwork = Get-AzureRmVirtualNetwork -Name $networkInterface.vNetName -resourceGroupName $resourceGroup.groupName -ErrorAction SilentlyContinue
            if ($virtualNetwork -eq $null) {
                $subnet = New-AzureRmVirtualNetworkSubnetConfig -Name $networkInterface.subNetName -addressPrefix $networkInterface.networkPrefix
                $virtualNetwork = New-AzureRmVirtualNetwork -Name $networkInterface.vNetName -resourceGroupName $resourceGroup.groupName -Location $resourceGroup.location -addressPrefix $networkInterface.networkPrefix -Subnet $subnet
            } else {
                $subnetExists = $false
                foreach ($subnet in $virtualNetwork.Subnets) {
                    if ($subnet.Name -eq $networkInterface.subNetName) {
                        $subnetExists = $true
                    }
                }
                if ($subnetExists -eq $false) {
                    Add-AzureRmVirtualNetworkSubnetConfig -Name $networkInterface.subNetName -VirtualNetwork $virtualNetwork -addressPrefix $networkInterface.networkPrefix
                    Set-AzureRmVirtualNetwork -VirtualNetwork $virtualNetwork
                }
            }
        }
    }
    foreach ($vm in $resourceGroup.vms) {
        continue
        $scriptBlock = {
            param($profilePath, $subscriptionName, $vm, $credential, $resourceGroupName, $azureLocation)
            Select-AzureRmProfile -Path $profilePath
            Get-AzureRmSubscription –subscriptionName $subscriptionName | Select-AzureRmSubscription -ErrorAction Stop
            $azureVm = Get-AzureRmVM -Name $serverName -resourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
            if ($azureVm -eq $null) {
                $nics = @()
                foreach ($networkInterface in $vm.networkInterfaces) {
                    $ipName = $networkInterface.publicIpAddressName
                    $publicIp = $null
                    $publicIp = Get-AzureRmPublicIpAddress -Name $ipName -resourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
                    if ($publicIp -eq $null) {
                        $publicIp = New-AzureRmPublicIpAddress -Name $ipName -resourceGroupName $resourceGroupName -Location $azureLocation -AllocationMethod Static
                    }
                    $nicName = $networkInterface.networkInterfaceName
                    $nic = $null
                    $nic = Get-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
                    if ($nic -eq $null) {
                        $nic = New-AzureRmNetworkInterface -Name $nicName -ResourceGroupName $resourceGroupName -Location $azureLocation -SubnetId $subnetId -PublicIpAddressId $publicIp.Id
                        $nics.Add($nic)
                    }    
                }
                $azureVm = New-AzureRmVMConfig -VMName $vm.serverName -VMSize $vm.size
                if ($vm.availabilitySet -ne "") {
                    $azureAvailabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $resourceGroupName -Name $vm.availabilitySet -ErrorAction SilentlyContinue
                    if ($azureAvailabilitySet -ne $null) {
                        $azureVm.AvailabilitySetReference = $azureAvailabilitySet.Id
                    }
                }
                foreach ($nic in $nics) {
                    $azureVm = Add-AzureRmVMNetworkInterface -VM $azureVm -Id $nic.Id
                }
                if ($vm.operatingSystemDisk -eq $null) {
                    Write-Error "Operating system disk info missing"
                    exit
                }
                $osDiskFileName = $vm.operatingSystemDisk.diskName + ".vhd"
                $osDiskRelativePath = $vm.operatingSystemDisk.containerName + "/" + $osDiskFileName
                $storageAccount = Get-AzureRmStorageAccount -Name $vm.operatingSystemDisk.storageAccountName -resourceGroupName $resourceGroupName
                $osDiskUri =($storageAccount.PrimaryEndpoints.Blob.ToString()) + $osDiskRelativePath
                $azureOSDisk = Get-AzureStorageBlob -Context $storageAccount.Context -Container $vm.operatingSystemDisk.containerName -ErrorAction SilentlyContinue | Where-Object {$_.Name -eq $osDiskFileName}
                if ($azureOSDisk -ne $null) {
                    $azureVm = Set-AzureRmVMOSDisk -VM $azureVm -Name $vm.operatingSystemDisk.diskName -VhdUri $osDiskUri -CreateOption Attach -Windows
                } else {
                    $azureVm = Set-AzureRmVMOperatingSystem -VM $azureVm -Windows -ComputerName $serverName -Credential $credential -ProvisionVMAgent -EnableAutoUpdate
                    $azureVm = Set-AzureRmVMSourceImage -VM $azureVm -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus $vm.sku -Version "latest"
                    $azureVm = Set-AzureRmVMOSDisk -VM $azureVm -Name $diskName -VhdUri $osDiskUri -CreateOption fromImage
                }
                $LUNNumber = 0
                foreach ($dataDisk in $vm.dataDisks) {
                    $dataDiskFileName = $dataDisk.diskName + ".vhd"
                    $dataDiskRelativePath = $dataDisk.containerName + "/" + $dataDiskFileName
                    $storageAccount = Get-AzureRmStorageAccount -Name $dataDisk.storageAccountName -resourceGroupName $resourceGroupName
                    $dataDiskUri =($storageAccount.PrimaryEndpoints.Blob.ToString()) + $dataDiskRelativePath
                    $azureDataDisk = Get-AzureStorageBlob -Context $storageAccount.Context -Container $dataDisk.containerName -ErrorAction SilentlyContinue | Where-Object {$_.Name -eq $dataDiskFileName}
                    if ($azureDataDisk -ne $null) {
                        $azureVm = Add-AzureRmVMDataDisk -VM $azureVm -Name $dataDisk.diskName -SourceImageUri $dataDiskUri -LUN $LUNNumber -Caching None -CreateOption FromImage
                    } else {
                        $azureVm = Add-AzureRmVMDataDisk -VM $azureVm -Name $dataDisk.diskName -VhdUri $dataDiskUri -LUN $LUNNumber -Caching None -DiskSizeinGB $dataDisk.size -CreateOption Empty
                    }
                    $LUNNumber++
                }
                New-AzureRmVM -ResourceGroupName $resourceGroupName -Location $azureLocation -VM $azureVm
            }
        }
        Write-Host -BackgroundColor Green "Creating parallel jobs for vm provisioning."
        Start-Job -ScriptBlock $sb -ArgumentList $profilePath, $subscriptionName, $vmConfig.serverName, $credential, $vmConfig.size, $vmConfig.sku, $vmConfig.availabilitySet, $resourceGroupName, $azureLocation, $virtualNetwork.Subnets[0].Id, $standardStorageAccountName, $premiumStorageAccountName
        Write-Host -BackgroundColor Green "Running jobs..."
        Get-Job | Wait-Job
        Write-Host -BackgroundColor Green "Removing the current Azure profile file: " $profilePath
        Remove-Item -Path $profilePath -Force
        Write-Host -BackgroundColor Green "Done."
    }
}