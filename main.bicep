// ============================================================
// Minimal lab environment for testing Backup/Rollback scripts
// Deploys: VNet, Azure Firewall Premium + Policy with nine RCGs
// ============================================================

@description('Azure region for all resources.')
param location string = 'centralus'

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-fw-lab'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/24']
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: { addressPrefix: '10.0.0.0/26' }
      }
    ]
  }
}

resource firewallPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-fw-lab'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'fw-policy-hub01'
  location: location
  properties: {
    sku: { tier: 'Premium' }
  }
}

// Empty RCG placeholders are intentional to establish a durable policy layout.
resource rcgPlatform 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'RCG-Platform'
  properties: {
    priority: 500
    ruleCollections: []
  }
}

resource rcgIdentity 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'RCG-Identity'
  dependsOn: [rcgPlatform]
  properties: {
    priority: 600
    ruleCollections: []
  }
}

resource rcgManagement 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'RCG-Management'
  dependsOn: [rcgIdentity]
  properties: {
    priority: 700
    ruleCollections: []
  }
}

resource rcgSharedServices 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'RCG-SharedServices'
  dependsOn: [rcgManagement]
  properties: {
    priority: 800
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'sharedservices-net-allow'
        priority: 801
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-DNS'
            description: 'Allow DNS to Azure DNS resolver'
            sourceAddresses: ['10.0.0.0/24']
            destinationAddresses: ['168.63.129.16']
            destinationPorts: ['53']
            ipProtocols: ['UDP', 'TCP']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-NTP'
            description: 'Allow NTP outbound'
            sourceAddresses: ['10.0.0.0/24']
            destinationAddresses: ['*']
            destinationPorts: ['123']
            ipProtocols: ['UDP']
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'sharedservices-app-allow'
        priority: 802
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-WindowsUpdate'
            description: 'Allow Windows Update endpoints'
            sourceAddresses: ['10.0.0.0/24']
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
            sourceAddresses: ['10.0.0.0/24']
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: [
              '*.microsoft.com'
              '*.azure.com'
              '*.windowsazure.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'Allow-UbuntuAptRepos'
            description: 'Allow Ubuntu package manager repositories'
            sourceAddresses: ['10.0.0.0/24']
            protocols: [
              { protocolType: 'Https', port: 443 }
              { protocolType: 'Http', port: 80 }
            ]
            targetFqdns: [
              '*.ubuntu.com'
              'security.ubuntu.com'
              'archive.ubuntu.com'
            ]
          }
        ]
      }
    ]
  }
}

resource rcgAvd 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'RCG-AVD'
  dependsOn: [rcgSharedServices]
  properties: {
    priority: 900
    ruleCollections: []
  }
}

resource rcgAks 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'RCG-AKS'
  dependsOn: [rcgAvd]
  properties: {
    priority: 1000
    ruleCollections: []
  }
}

resource rcgApp1 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'RCG-App1'
  dependsOn: [rcgAks]
  properties: {
    priority: 1100
    ruleCollections: []
  }
}

resource rcgApp2 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'RCG-App2'
  dependsOn: [rcgApp1]
  properties: {
    priority: 1200
    ruleCollections: []
  }
}

resource rcgTemporary 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'RCG-Temporary'
  dependsOn: [rcgApp2]
  properties: {
    priority: 60000
    ruleCollections: []
  }
}

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
        name: 'fw-ipconfig'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureFirewallSubnet' }
          publicIPAddress: { id: firewallPip.id }
        }
      }
    ]
  }
  dependsOn: [rcgTemporary]
}

output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output firewallPublicIp string = firewallPip.properties.ipAddress
output policyName string = firewallPolicy.name
