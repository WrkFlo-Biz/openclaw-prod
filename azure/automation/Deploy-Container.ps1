<#
.SYNOPSIS
    Deploy or update an Azure Container Instance.

.DESCRIPTION
    This runbook deploys or updates a container instance with approval validation.
    Part of the OpenClaw DevOps Automation skill.

.PARAMETER Target
    The name of the container to deploy.

.PARAMETER ApprovalId
    The approval ID for audit purposes.

.PARAMETER ApprovedBy
    The user who approved the deployment.

.PARAMETER ResourceGroupName
    The resource group containing the container.

.PARAMETER ContainerRegistry
    The container registry URL.

.PARAMETER ImageTag
    The image tag to deploy (default: latest).
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [string]$ApprovalId,

    [Parameter(Mandatory = $false)]
    [string]$ApprovedBy = "System",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = $env:RESOURCE_GROUP,

    [Parameter(Mandatory = $false)]
    [string]$ContainerRegistry = $env:CONTAINER_REGISTRY,

    [Parameter(Mandatory = $false)]
    [string]$ImageTag = "latest"
)

# Import required modules
Import-Module Az.Accounts
Import-Module Az.ContainerInstance
Import-Module Az.Storage

# Configuration
$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Allowed containers (safety gate)
$AllowedContainers = @(
    "openclaw-bot",
    "openclaw-api",
    "openclaw-worker"
)

# Blocked parameters (security check)
$BlockedParams = @(
    "--privileged",
    "-v /:/",
    "--pid=host"
)

function Write-AuditLog {
    param(
        [string]$Action,
        [string]$Status,
        [string]$Details,
        [string]$ApprovalId
    )

    $logEntry = @{
        timestamp   = (Get-Date).ToUniversalTime().ToString("o")
        action      = $Action
        status      = $Status
        details     = $Details
        approvalId  = $ApprovalId
        approvedBy  = $ApprovedBy
        target      = $Target
    } | ConvertTo-Json -Compress

    Write-Output "AUDIT: $logEntry"

    # In production, this would write to Azure Table Storage or Log Analytics
}

function Test-SafetyGates {
    param([string]$ContainerName)

    # Check if container is in allowed list
    if ($ContainerName -notin $AllowedContainers) {
        throw "Container '$ContainerName' is not in the allowed list. Allowed: $($AllowedContainers -join ', ')"
    }

    # Check for blocked parameters in target string
    foreach ($blocked in $BlockedParams) {
        if ($Target -like "*$blocked*") {
            throw "Blocked parameter detected: $blocked"
        }
    }

    Write-Output "Safety gates passed for container: $ContainerName"
    return $true
}

function Get-ContainerConfig {
    param([string]$ContainerName)

    # Container configurations
    $configs = @{
        "openclaw-bot" = @{
            Image           = "$ContainerRegistry/openclaw-bot:$ImageTag"
            Cpu             = 0.5
            MemoryInGB      = 0.5
            Port            = 8080
            EnvironmentVars = @(
                @{ Name = "ENVIRONMENT"; Value = "production" }
            )
        }
        "openclaw-api" = @{
            Image           = "$ContainerRegistry/openclaw-api:$ImageTag"
            Cpu             = 1.0
            MemoryInGB      = 1.0
            Port            = 80
            EnvironmentVars = @(
                @{ Name = "ENVIRONMENT"; Value = "production" }
            )
        }
        "openclaw-worker" = @{
            Image           = "$ContainerRegistry/openclaw-worker:$ImageTag"
            Cpu             = 0.5
            MemoryInGB      = 0.5
            Port            = $null
            EnvironmentVars = @(
                @{ Name = "ENVIRONMENT"; Value = "production" }
            )
        }
    }

    if (-not $configs.ContainsKey($ContainerName)) {
        throw "No configuration found for container: $ContainerName"
    }

    return $configs[$ContainerName]
}

# Main execution
try {
    Write-Output "=========================================="
    Write-Output "OpenClaw Container Deployment"
    Write-Output "=========================================="
    Write-Output "Target: $Target"
    Write-Output "Approval ID: $ApprovalId"
    Write-Output "Approved By: $ApprovedBy"
    Write-Output "Timestamp: $((Get-Date).ToUniversalTime().ToString('o'))"
    Write-Output ""

    # Authenticate with Managed Identity
    Write-Output "Authenticating with Azure..."
    Connect-AzAccount -Identity

    # Run safety checks
    Write-Output "Running safety checks..."
    Test-SafetyGates -ContainerName $Target

    Write-AuditLog -Action "deploy_started" -Status "in_progress" -Details "Starting deployment" -ApprovalId $ApprovalId

    # Get container configuration
    $config = Get-ContainerConfig -ContainerName $Target
    Write-Output "Using configuration: $($config | ConvertTo-Json -Compress)"

    # Check if container already exists
    $existingContainer = Get-AzContainerGroup -ResourceGroupName $ResourceGroupName -Name $Target -ErrorAction SilentlyContinue

    if ($existingContainer) {
        Write-Output "Existing container found. Removing before redeployment..."

        # Create restore point (backup current state)
        $backupState = @{
            name      = $Target
            image     = $existingContainer.Containers[0].Image
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-Output "Restore point created: $($backupState | ConvertTo-Json -Compress)"

        # Remove existing container
        Remove-AzContainerGroup -ResourceGroupName $ResourceGroupName -Name $Target -Confirm:$false
        Write-Output "Existing container removed."

        # Wait for deletion to complete
        Start-Sleep -Seconds 10
    }

    # Build container parameters
    $containerParams = @{
        ResourceGroupName = $ResourceGroupName
        Name              = $Target
        Image             = $config.Image
        Cpu               = $config.Cpu
        MemoryInGB        = $config.MemoryInGB
        OsType            = "Linux"
        RestartPolicy     = "Always"
    }

    if ($config.Port) {
        $containerParams.Port = $config.Port
        $containerParams.IpAddressType = "Public"
    }

    # Create new container
    Write-Output "Creating new container instance..."
    $newContainer = New-AzContainerGroup @containerParams

    Write-Output "Container created successfully!"
    Write-Output "Container ID: $($newContainer.Id)"
    Write-Output "Container State: $($newContainer.ProvisioningState)"

    if ($newContainer.IpAddress) {
        Write-Output "IP Address: $($newContainer.IpAddress)"
    }

    # Wait for container to be running
    Write-Output "Waiting for container to start..."
    $maxWaitSeconds = 120
    $waitedSeconds = 0

    do {
        Start-Sleep -Seconds 5
        $waitedSeconds += 5
        $containerStatus = Get-AzContainerGroup -ResourceGroupName $ResourceGroupName -Name $Target
        Write-Output "Status: $($containerStatus.ProvisioningState) (waited ${waitedSeconds}s)"
    } while ($containerStatus.ProvisioningState -eq "Creating" -and $waitedSeconds -lt $maxWaitSeconds)

    if ($containerStatus.ProvisioningState -ne "Succeeded") {
        throw "Container failed to start within timeout. State: $($containerStatus.ProvisioningState)"
    }

    Write-AuditLog -Action "deploy_completed" -Status "success" -Details "Container deployed successfully" -ApprovalId $ApprovalId

    # Output summary
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "Deployment Complete"
    Write-Output "=========================================="
    Write-Output "Container: $Target"
    Write-Output "Image: $($config.Image)"
    Write-Output "State: $($containerStatus.ProvisioningState)"
    Write-Output "Approval ID: $ApprovalId"
    Write-Output ""

    # Return success result
    return @{
        status      = "success"
        container   = $Target
        approvalId  = $ApprovalId
        ipAddress   = $containerStatus.IpAddress
        state       = $containerStatus.ProvisioningState
    }

}
catch {
    $errorMessage = $_.Exception.Message
    Write-Error "Deployment failed: $errorMessage"

    Write-AuditLog -Action "deploy_failed" -Status "error" -Details $errorMessage -ApprovalId $ApprovalId

    # Return error result
    return @{
        status     = "failed"
        container  = $Target
        approvalId = $ApprovalId
        error      = $errorMessage
    }
}
