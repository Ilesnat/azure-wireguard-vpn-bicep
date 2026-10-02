targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the WireGuard virtual machine.')
param vmName string = 'wg-vpn'

@description('Azure VM size. Standard_B1s is the cheapest practical default for a few personal VPN clients.')
param vmSize string = 'Standard_B1s'

@description('Linux administrator username.')
param adminUsername string = 'azureuser'

@secure()
@description('SSH public key, for example the contents of ~/.ssh/id_ed25519.pub.')
param adminPublicKey string

@description('Public IPv4 address allowed to use SSH. A bare address or /32 is accepted; the template always restricts it to one host.')
param adminSourceIp string

var vnetName = '${vmName}-vnet'
var subnetName = 'default'
var nsgName = '${vmName}-nsg'
var publicIpName = '${vmName}-pip'
var nicName = '${vmName}-nic'
var adminSourceCidr = '${split(adminSourceIp, '/')[0]}/32'

// Restricts inbound traffic to WireGuard and SSH from the specified administrator IP.
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-WireGuard-UDP-51820'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '51820'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-SSH-From-Admin'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: adminSourceCidr
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Provides one private subnet; the NSG applies to every NIC placed in the subnet.
resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.10.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.10.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// Uses a static Standard SKU IPv4 address for a stable WireGuard endpoint.
resource publicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

// Enables Azure IP forwarding so the VM can route traffic for WireGuard clients.
resource nic 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: nicName
  location: location
  properties: {
    enableAcceleratedNetworking: false
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetName)
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// Runs Ubuntu 22.04 LTS and bootstraps WireGuard through cloud-init.
resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 30
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: loadFileAsBase64('cloud-init.yaml')
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: false
      }
    }
  }
}

output publicIpAddress string = publicIp.properties.ipAddress
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'
output clientRetrievalInstructions string = 'SSH to the VM, wait with "sudo cloud-init status --wait", then display the phone QR with "sudo wg-show-client phone" or export files with "sudo wg-export-client laptop".'
