// OpenClaw Azure Infrastructure
// Deploys all resources for autonomous agent skills

targetScope = 'resourceGroup'

@description('Environment name')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'prod'

@description('Azure region for resources')
param location string = resourceGroup().location

@description('Telegram Bot Token')
@secure()
param telegramBotToken string

@description('Telegram Admin Chat ID')
param telegramAdminChatId string

@description('GitHub Personal Access Token')
@secure()
param githubToken string = ''

@description('GitHub Repository (owner/repo)')
param githubRepo string = ''

// Variables
var prefix = 'openclaw'
var uniqueSuffix = uniqueString(resourceGroup().id)
var tags = {
  Environment: environment
  Application: 'OpenClaw'
  ManagedBy: 'Bicep'
}

// ============================================
// Key Vault - Secrets Management
// ============================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${prefix}-kv-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 30
    enablePurgeProtection: true
  }
}

// Store secrets in Key Vault
resource telegramTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'telegram-bot-token'
  properties: {
    value: telegramBotToken
  }
}

resource githubTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(githubToken)) {
  parent: keyVault
  name: 'github-token'
  properties: {
    value: githubToken
  }
}

// ============================================
// Storage Account - State & Logs
// ============================================
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${prefix}st${uniqueSuffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'audit-logs'
  properties: {
    publicAccess: 'None'
  }
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'state'
  properties: {
    publicAccess: 'None'
  }
}

resource processedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'processed-data'
  properties: {
    publicAccess: 'None'
  }
}

resource backupsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'backups'
  properties: {
    publicAccess: 'None'
  }
}

// Table storage for rate limiting and state
resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource rateLimitTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  parent: tableService
  name: 'RateLimits'
}

resource pendingApprovalsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  parent: tableService
  name: 'PendingApprovals'
}

// ============================================
// Application Insights - Monitoring & Audit
// ============================================
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${prefix}-law-${uniqueSuffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-ai-${uniqueSuffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
  }
}

// ============================================
// Azure Functions - Data Processing
// ============================================
resource functionAppPlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${prefix}-asp-${uniqueSuffix}'
  location: location
  tags: tags
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
  }
  kind: 'elastic'
  properties: {
    maximumElasticWorkerCount: 20
    reserved: true // Linux
  }
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: '${prefix}-func-${uniqueSuffix}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: functionAppPlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${az.environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'KEY_VAULT_URI'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'TELEGRAM_ADMIN_CHAT_ID'
          value: telegramAdminChatId
        }
        {
          name: 'GITHUB_REPO'
          value: githubRepo
        }
      ]
    }
  }
}

// ============================================
// Logic Apps Standard - Workflow Engine
// ============================================
resource logicAppPlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${prefix}-la-asp-${uniqueSuffix}'
  location: location
  tags: tags
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  kind: 'elastic'
  properties: {
    maximumElasticWorkerCount: 20
    reserved: true
  }
}

resource logicApp 'Microsoft.Web/sites@2023-01-01' = {
  name: '${prefix}-la-${uniqueSuffix}'
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: logicAppPlan.id
    httpsOnly: true
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${az.environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__id'
          value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__version'
          value: '[1.*, 2.0.0)'
        }
        {
          name: 'APP_KIND'
          value: 'workflowapp'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'TELEGRAM_ADMIN_CHAT_ID'
          value: telegramAdminChatId
        }
      ]
    }
  }
}

// ============================================
// Automation Account - DevOps Runbooks
// ============================================
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: '${prefix}-auto-${uniqueSuffix}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
}

// ============================================
// API Connections for Logic Apps
// ============================================
resource telegramConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: '${prefix}-telegram-conn'
  location: location
  tags: tags
  properties: {
    displayName: 'Telegram Bot Connection'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'telegram')
    }
    parameterValues: {
      token: telegramBotToken
    }
  }
}

resource azureBlobConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: '${prefix}-blob-conn'
  location: location
  tags: tags
  properties: {
    displayName: 'Azure Blob Storage Connection'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azureblob')
    }
    parameterValues: {
      accountName: storageAccount.name
      accessKey: storageAccount.listKeys().keys[0].value
    }
  }
}

resource azureTableConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: '${prefix}-table-conn'
  location: location
  tags: tags
  properties: {
    displayName: 'Azure Table Storage Connection'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azuretables')
    }
    parameterValues: {
      storageaccount: storageAccount.name
      sharedkey: storageAccount.listKeys().keys[0].value
    }
  }
}

resource approvalConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: '${prefix}-approval-conn'
  location: location
  tags: tags
  properties: {
    displayName: 'Office 365 Approval Connection'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
    }
  }
}

// ============================================
// RBAC Assignments
// ============================================

// Function App -> Key Vault Secrets User
resource functionKvAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionApp.id, keyVault.id, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Logic App -> Key Vault Secrets User
resource logicAppKvAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logicApp.id, keyVault.id, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Logic App -> Storage Blob Data Contributor
resource logicAppStorageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logicApp.id, storageAccount.id, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Automation Account -> Contributor (for resource management)
resource automationContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, resourceGroup().id, 'Contributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================
// Outputs
// ============================================
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output storageAccountName string = storageAccount.name
output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output logicAppName string = logicApp.name
output logicAppUrl string = 'https://${logicApp.properties.defaultHostName}'
output automationAccountName string = automationAccount.name
output appInsightsName string = appInsights.name
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output telegramConnectionId string = telegramConnection.id
output blobConnectionId string = azureBlobConnection.id
output tableConnectionId string = azureTableConnection.id
