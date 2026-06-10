// ============================================================
// Azure Hub-Spoke Network Topology
// ============================================================
// Architecture:
//   Hub:    Hub01    (10.0.0.0/23)  — VPN GW, Firewall, Bastion
//   Spoke01 (10.0.2.0/24)
//   Spoke02 (10.0.3.0/24)
//   OnPrem: OnPrem01 (192.168.0.0/24) — simulated on-premises
//
// Deploys:
//   - 4 VNets with subnets and peerings
//   - Active/Active VPN Gateways with BGP (Hub ASN 65509, OnPrem ASN 65510)
//   - 4 Local Network Gateways + 4 Site-to-Site IPSec connections
//   - Azure Firewall Premium with allow-all rule (lab use)
//   - Azure Bastion (Standard)
//   - NSGs with SSH access on spoke/onprem subnets
//   - Route tables directing spoke traffic through the firewall
//   - Ubuntu 22.04 VMs in Spoke01, Spoke02, and OnPrem
// ============================================================

@description('Azure region for all resources.')
param location string = 'centralus'

@description('Admin username for all VMs.')
param adminUsername string = 'azureuser'

@description('Admin password for all VMs.')
@secure()
param adminPassword string

// ============================================================
// Variables
// ============================================================

var hubCidr             = '10.0.0.0/23'
var spoke01Cidr         = '10.0.2.0/24'
var spoke02Cidr         = '10.0.3.0/24'
var onpremCidr          = '192.168.0.0/24'

var hubDefaultSubnet    = '10.0.0.0/26'
var hubGwSubnet         = '10.0.0.64/26'
var hubFwSubnet         = '10.0.0.128/26'
var hubBastionSubnet    = '10.0.0.192/26'
var hubFwMgmtSubnet     = '10.0.1.0/26'
var spoke01Subnet       = '10.0.2.0/24'
var spoke02Subnet       = '10.0.3.0/24'
var onpremDefaultSubnet = '192.168.0.0/26'
var onpremGwSubnet      = '192.168.0.64/26'
var onpremVmSubnet      = '192.168.0.128/26'

var vpnSharedKey        = 'VerySecureSharedKey123!'

var ubuntuImage = {
  publisher: 'Canonical'
  offer: '0001-com-ubuntu-server-jammy'
  sku: '22_04-lts-gen2'
  version: 'latest'
}

// ============================================================
// Network Security Groups
// ============================================================

resource nsgSpoke01 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-spoke01'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource nsgSpoke02 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-spoke02'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource nsgOnprem 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-onprem'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

// ============================================================
// Route Tables (routes are added after the firewall is ready)
// ============================================================

resource rtSpoke01 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-spoke01'
  location: location
  properties: {
    disableBgpRoutePropagation: true
  }
}

resource rtSpoke02 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-spoke02'
  location: location
  properties: {
    disableBgpRoutePropagation: true
  }
}

// Required: management subnet must have an explicit 0.0.0.0/0 → Internet route
resource rtFwMgmt 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-fw-mgmt'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'mgmt-to-internet'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

// ============================================================
// Virtual Networks
// ============================================================

resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'Hub01'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [hubCidr]
    }
    subnets: [
      {
        name: 'default'
        properties: { addressPrefix: hubDefaultSubnet }
      }
      {
        name: 'GatewaySubnet'
        properties: { addressPrefix: hubGwSubnet }
      }
      {
        name: 'AzureFirewallSubnet'
        properties: { addressPrefix: hubFwSubnet }
      }
      {
        name: 'AzureBastionSubnet'
        properties: { addressPrefix: hubBastionSubnet }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: hubFwMgmtSubnet
          routeTable: { id: rtFwMgmt.id }
        }
      }
    ]
  }
}

resource spoke01Vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'Spoke01'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [spoke01Cidr]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: spoke01Subnet
          networkSecurityGroup: { id: nsgSpoke01.id }
          routeTable: { id: rtSpoke01.id }
        }
      }
    ]
  }
}

resource spoke02Vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'Spoke02'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [spoke02Cidr]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: spoke02Subnet
          networkSecurityGroup: { id: nsgSpoke02.id }
          routeTable: { id: rtSpoke02.id }
        }
      }
    ]
  }
}

resource onpremVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'OnPrem01'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [onpremCidr]
    }
    subnets: [
      {
        name: 'default'
        properties: { addressPrefix: onpremDefaultSubnet }
      }
      {
        name: 'GatewaySubnet'
        properties: { addressPrefix: onpremGwSubnet }
      }
      {
        name: 'vm-subnet'
        properties: {
          addressPrefix: onpremVmSubnet
          networkSecurityGroup: { id: nsgOnprem.id }
        }
      }
    ]
  }
}

// ============================================================
// VNet Peerings (Hub <-> Spoke01, Hub <-> Spoke02)
// ============================================================

resource hubToSpoke01 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: hubVnet
  name: 'hub-to-spoke01'
  properties: {
    remoteVirtualNetwork: { id: spoke01Vnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource spoke01ToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: spoke01Vnet
  name: 'spoke01-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource hubToSpoke02 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: hubVnet
  name: 'hub-to-spoke02'
  properties: {
    remoteVirtualNetwork: { id: spoke02Vnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource spoke02ToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: spoke02Vnet
  name: 'spoke02-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ============================================================
// Public IP Addresses
// ============================================================

resource hubPip1 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-vng-hub01-1'
  location: location
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: { publicIPAllocationMethod: 'Static' }
}

resource hubPip2 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-vng-hub01-2'
  location: location
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: { publicIPAllocationMethod: 'Static' }
}

resource firewallPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-azure-firewall'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource firewallMgmtPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-azure-firewall-mgmt'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-azure-bastion'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource onpremPip1 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-vng-onprem01-1'
  location: location
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: { publicIPAllocationMethod: 'Static' }
}

resource onpremPip2 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-vng-onprem01-2'
  location: location
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: { publicIPAllocationMethod: 'Static' }
}

// ============================================================
// VPN Gateways — Active/Active with BGP
// ARM deploys these in parallel; each takes ~30 minutes.
// ============================================================

resource hubVpnGw 'Microsoft.Network/virtualNetworkGateways@2023-09-01' = {
  name: 'vng-hub01'
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1AZ'
      tier: 'VpnGw1AZ'
    }
    activeActive: true
    enableBgp: true
    bgpSettings: {
      asn: 65509
    }
    ipConfigurations: [
      {
        name: 'gwIpConfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${hubVnet.id}/subnets/GatewaySubnet' }
          publicIPAddress: { id: hubPip1.id }
        }
      }
      {
        name: 'gwIpConfig2'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${hubVnet.id}/subnets/GatewaySubnet' }
          publicIPAddress: { id: hubPip2.id }
        }
      }
    ]
  }
}

resource onpremVpnGw 'Microsoft.Network/virtualNetworkGateways@2023-09-01' = {
  name: 'vng-onprem01'
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1AZ'
      tier: 'VpnGw1AZ'
    }
    activeActive: true
    enableBgp: true
    bgpSettings: {
      asn: 65510
    }
    ipConfigurations: [
      {
        name: 'gwIpConfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${onpremVnet.id}/subnets/GatewaySubnet' }
          publicIPAddress: { id: onpremPip1.id }
        }
      }
      {
        name: 'gwIpConfig2'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${onpremVnet.id}/subnets/GatewaySubnet' }
          publicIPAddress: { id: onpremPip2.id }
        }
      }
    ]
  }
}

// ============================================================
// Azure Firewall Policy (Premium) + Rule Collection
// ============================================================

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'fw-policy-hub01'
  location: location
  properties: {
    sku: { tier: 'Premium' }
  }
}

resource firewallPolicyRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'DefaultRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [

      // --------------------------------------------------------
      // Network Rules – priority 100
      // --------------------------------------------------------
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'NetworkRules'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-DNS'
            description: 'Allow DNS from spokes and onprem to Azure DNS'
            sourceAddresses: ['10.0.2.0/24', '10.0.3.0/24', '192.168.0.0/24']
            destinationAddresses: ['168.63.129.16']
            destinationPorts: ['53']
            ipProtocols: ['UDP', 'TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-NTP'
            description: 'Allow NTP outbound from all internal networks'
            sourceAddresses: ['10.0.0.0/23', '10.0.2.0/24', '10.0.3.0/24', '192.168.0.0/24']
            destinationAddresses: ['*']
            destinationPorts: ['123']
            ipProtocols: ['UDP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-Spoke-to-Spoke'
            description: 'Allow traffic between Spoke01 and Spoke02 via firewall'
            sourceAddresses: ['10.0.2.0/24', '10.0.3.0/24']
            destinationAddresses: ['10.0.2.0/24', '10.0.3.0/24']
            destinationPorts: ['*']
            ipProtocols: ['Any']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-OnPrem-RDP'
            description: 'Allow RDP from onprem to spoke VMs'
            sourceAddresses: ['192.168.0.0/24']
            destinationAddresses: ['10.0.2.0/24', '10.0.3.0/24']
            destinationPorts: ['3389']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-OnPrem-SSH'
            description: 'Allow SSH from onprem to spoke VMs'
            sourceAddresses: ['192.168.0.0/24']
            destinationAddresses: ['10.0.2.0/24', '10.0.3.0/24']
            destinationPorts: ['22']
            ipProtocols: ['TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-Spoke-to-OnPrem'
            description: 'Allow traffic from spokes to onprem network'
            sourceAddresses: ['10.0.2.0/24', '10.0.3.0/24']
            destinationAddresses: ['192.168.0.0/24']
            destinationPorts: ['*']
            ipProtocols: ['Any']
          }
        ]
      }

      // --------------------------------------------------------
      // Application Rules – priority 200
      // --------------------------------------------------------
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'ApplicationRules'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-WindowsUpdate'
            description: 'Allow Windows Update endpoints'
            sourceAddresses: ['10.0.2.0/24', '10.0.3.0/24', '192.168.0.0/24']
            protocols: [
              { protocolType: 'Https', port: 443 }
              { protocolType: 'Http', port: 80 }
            ]
            fqdnTags: ['WindowsUpdate']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-MicrosoftServices'
            description: 'Allow Microsoft update and telemetry FQDNs'
            sourceAddresses: ['10.0.2.0/24', '10.0.3.0/24', '192.168.0.0/24']
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: [
              '*.microsoft.com'
              '*.azure.com'
              '*.windowsazure.com'
              '*.msftncsi.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-UbuntuAptRepos'
            description: 'Allow Ubuntu package manager repositories'
            sourceAddresses: ['10.0.2.0/24', '10.0.3.0/24', '192.168.0.0/24']
            protocols: [
              { protocolType: 'Https', port: 443 }
              { protocolType: 'Http', port: 80 }
            ]
            targetFqdns: [
              '*.ubuntu.com'
              '*.launchpad.net'
              'security.ubuntu.com'
              'archive.ubuntu.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-AzurePortal'
            description: 'Allow Azure portal and management plane access'
            sourceAddresses: ['10.0.2.0/24', '10.0.3.0/24', '192.168.0.0/24']
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: [
              'portal.azure.com'
              'management.azure.com'
              'login.microsoftonline.com'
            ]
          }
        ]
      }
    ]
  }
}

// ============================================================
// Azure Firewall Premium
// ============================================================

resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: 'fw-hub01'
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Premium'
    }
    firewallPolicy: { id: firewallPolicy.id }
    ipConfigurations: [
      {
        name: 'FW-config'
        properties: {
          subnet: { id: '${hubVnet.id}/subnets/AzureFirewallSubnet' }
          publicIPAddress: { id: firewallPip.id }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'FW-mgmt-config'
      properties: {
        subnet: { id: '${hubVnet.id}/subnets/AzureFirewallManagementSubnet' }
        publicIPAddress: { id: firewallMgmtPip.id }
      }
    }
  }
  dependsOn: [firewallPolicyRules]
}

// ============================================================
// Azure Bastion (Standard)
// ============================================================

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'bastion-hub01'
  location: location
  sku: { name: 'Standard' }
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${hubVnet.id}/subnets/AzureBastionSubnet' }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

// ============================================================
// Route Table Routes — reference firewall private IP at runtime
// Bicep creates an implicit dependency on the firewall resource.
// ============================================================

resource rtSpoke01DefaultRoute 'Microsoft.Network/routeTables/routes@2023-09-01' = {
  parent: rtSpoke01
  name: 'default-to-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
  }
}

resource rtSpoke02DefaultRoute 'Microsoft.Network/routeTables/routes@2023-09-01' = {
  parent: rtSpoke02
  name: 'default-to-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
  }
}

// ============================================================
// Local Network Gateways
// BGP peering addresses are read from the gateway after it deploys.
// ============================================================

// --- Hub's view of OnPrem (for Hub → OnPrem connections) ---

resource lngOnpremInstance1 'Microsoft.Network/localNetworkGateways@2023-09-01' = {
  name: 'lng-onprem-instance1'
  location: location
  properties: {
    gatewayIpAddress: onpremPip1.properties.ipAddress
    localNetworkAddressSpace: { addressPrefixes: ['192.168.0.0/24'] }
    bgpSettings: {
      asn: 65510
      bgpPeeringAddress: onpremVpnGw.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
    }
  }
}

resource lngOnpremInstance2 'Microsoft.Network/localNetworkGateways@2023-09-01' = {
  name: 'lng-onprem-instance2'
  location: location
  properties: {
    gatewayIpAddress: onpremPip2.properties.ipAddress
    localNetworkAddressSpace: { addressPrefixes: ['192.168.0.0/24'] }
    bgpSettings: {
      asn: 65510
      bgpPeeringAddress: onpremVpnGw.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
    }
  }
}

// --- OnPrem's view of Hub (for OnPrem → Hub connections) ---

resource lngHubInstance1 'Microsoft.Network/localNetworkGateways@2023-09-01' = {
  name: 'lng-hub-instance1'
  location: location
  properties: {
    gatewayIpAddress: hubPip1.properties.ipAddress
    localNetworkAddressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    bgpSettings: {
      asn: 65509
      bgpPeeringAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
    }
  }
}

resource lngHubInstance2 'Microsoft.Network/localNetworkGateways@2023-09-01' = {
  name: 'lng-hub-instance2'
  location: location
  properties: {
    gatewayIpAddress: hubPip2.properties.ipAddress
    localNetworkAddressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    bgpSettings: {
      asn: 65509
      bgpPeeringAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
    }
  }
}

// ============================================================
// VPN Connections — full Active/Active mesh (4 connections)
// ============================================================

resource connHubToOnprem1 'Microsoft.Network/connections@2023-09-01' = {
  name: 'hub-to-onprem-instance1'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: { id: hubVpnGw.id, properties: {} }
    localNetworkGateway2: { id: lngOnpremInstance1.id, properties: {} }
    enableBgp: true
    sharedKey: vpnSharedKey
  }
}

resource connHubToOnprem2 'Microsoft.Network/connections@2023-09-01' = {
  name: 'hub-to-onprem-instance2'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: { id: hubVpnGw.id, properties: {} }
    localNetworkGateway2: { id: lngOnpremInstance2.id, properties: {} }
    enableBgp: true
    sharedKey: vpnSharedKey
  }
}

resource connOnpremToHub1 'Microsoft.Network/connections@2023-09-01' = {
  name: 'onprem-to-hub-instance1'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: { id: onpremVpnGw.id, properties: {} }
    localNetworkGateway2: { id: lngHubInstance1.id, properties: {} }
    enableBgp: true
    sharedKey: vpnSharedKey
  }
}

resource connOnpremToHub2 'Microsoft.Network/connections@2023-09-01' = {
  name: 'onprem-to-hub-instance2'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: { id: onpremVpnGw.id, properties: {} }
    localNetworkGateway2: { id: lngHubInstance2.id, properties: {} }
    enableBgp: true
    sharedKey: vpnSharedKey
  }
}

// ============================================================
// Network Interfaces
// ============================================================

resource nicSpk01 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-spk01-01'
  location: location
  properties: {
    networkSecurityGroup: { id: nsgSpoke01.id }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${spoke01Vnet.id}/subnets/default' }
        }
      }
    ]
  }
  dependsOn: [rtSpoke01DefaultRoute]
}

resource nicSpk02 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-spk02-01'
  location: location
  properties: {
    networkSecurityGroup: { id: nsgSpoke02.id }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${spoke02Vnet.id}/subnets/default' }
        }
      }
    ]
  }
  dependsOn: [rtSpoke02DefaultRoute]
}

resource nicOnprem 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-onprem-01'
  location: location
  properties: {
    networkSecurityGroup: { id: nsgOnprem.id }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${onpremVnet.id}/subnets/vm-subnet' }
        }
      }
    ]
  }
}

// ============================================================
// Virtual Machines — Ubuntu 22.04, Standard_B1s
// ============================================================

resource vmSpk01 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-spk01-01'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1s' }
    osProfile: {
      computerName: 'vm-spk01-01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: { disablePasswordAuthentication: false }
    }
    storageProfile: {
      imageReference: ubuntuImage
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nicSpk01.id }]
    }
  }
}

resource vmSpk02 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-spk02-01'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1s' }
    osProfile: {
      computerName: 'vm-spk02-01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: { disablePasswordAuthentication: false }
    }
    storageProfile: {
      imageReference: ubuntuImage
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nicSpk02.id }]
    }
  }
}

resource vmOnprem 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-onprem-01'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1s' }
    osProfile: {
      computerName: 'vm-onprem-01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: { disablePasswordAuthentication: false }
    }
    storageProfile: {
      imageReference: ubuntuImage
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nicOnprem.id }]
    }
  }
}

// ============================================================
// Log Analytics Workspace
// ============================================================

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-hub-spoke-fw-mgmt'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ============================================================
// Diagnostic Settings — logAnalyticsDestinationType: Dedicated
// uses resource-specific tables instead of AzureDiagnostics
// ============================================================

resource diagFirewall 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-fw-hub01'
  scope: firewall
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'AZFWApplicationRule'
        enabled: true
      }
      {
        category: 'AZFWNetworkRule'
        enabled: true
      }
      {
        category: 'AZFWNatRule'
        enabled: true
      }
      {
        category: 'AZFWThreatIntel'
        enabled: true
      }
      {
        category: 'AZFWIdpsSignature'
        enabled: true
      }
      {
        category: 'AZFWDnsQuery'
        enabled: true
      }
      {
        category: 'AZFWFqdnResolveFailure'
        enabled: true
      }
      {
        category: 'AZFWApplicationRuleAggregation'
        enabled: true
      }
      {
        category: 'AZFWNetworkRuleAggregation'
        enabled: true
      }
      {
        category: 'AZFWNatRuleAggregation'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource diagHubVpnGw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-vng-hub01'
  scope: hubVpnGw
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'GatewayDiagnosticLog', enabled: true }
      { category: 'TunnelDiagnosticLog',  enabled: true }
      { category: 'RouteDiagnosticLog',   enabled: true }
      { category: 'IKEDiagnosticLog',     enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

resource diagOnpremVpnGw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-vng-onprem01'
  scope: onpremVpnGw
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'GatewayDiagnosticLog', enabled: true }
      { category: 'TunnelDiagnosticLog',  enabled: true }
      { category: 'RouteDiagnosticLog',   enabled: true }
      { category: 'IKEDiagnosticLog',     enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

resource diagBastion 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-bastion-hub01'
  scope: bastion
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'BastionAuditLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

resource diagNsgSpoke01 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-nsg-spoke01'
  scope: nsgSpoke01
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'NetworkSecurityGroupEvent',       enabled: true }
      { category: 'NetworkSecurityGroupRuleCounter', enabled: true }
    ]
  }
}

resource diagNsgSpoke02 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-nsg-spoke02'
  scope: nsgSpoke02
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'NetworkSecurityGroupEvent',       enabled: true }
      { category: 'NetworkSecurityGroupRuleCounter', enabled: true }
    ]
  }
}

resource diagNsgOnprem 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-nsg-onprem'
  scope: nsgOnprem
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'NetworkSecurityGroupEvent',       enabled: true }
      { category: 'NetworkSecurityGroupRuleCounter', enabled: true }
    ]
  }
}

// ============================================================
// Outputs
// ============================================================

output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output firewallMgmtPublicIp string = firewallMgmtPip.properties.ipAddress
output hubGwPip1 string = hubPip1.properties.ipAddress
output hubGwPip2 string = hubPip2.properties.ipAddress
output onpremGwPip1 string = onpremPip1.properties.ipAddress
output onpremGwPip2 string = onpremPip2.properties.ipAddress
output bastionPublicIp string = bastionPip.properties.ipAddress
output logAnalyticsWorkspaceId string = law.id
