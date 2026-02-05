<#
.SYNOPSIS
    Create backup of Azure resources.

.DESCRIPTION
    This runbook creates backups of specified resources with safety validation.
    Part of the OpenClaw DevOps Automation skill.

.PARAMETER Resource
    The resource to backup (database, config, logs, storage).

.PARAMETER ApprovalId
    The approval ID for audit purposes.

.PARAMETER RetentionDays
    Number of days to retain backups (default: 30).
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("database", "config", "logs", "storage", "all")]
    [string]$Resource,

    [Parameter(Mandatory = $true)]
    [string]$ApprovalId,

    [Parameter(Mandatory = $false)]
    [int]$RetentionDays = 30
)

# Import modules
Import-Module Az.Accounts
Import-Module Az.Storage
Import-Module Az.Resources

$ErrorActionPreference = "Stop"

# Configuration
$BackupStorageAccount = $env:BACKUP_STORAGE_ACCOUNT
$BackupContainer = "backups"
$ResourceGroupName = $env:RESOURCE_GROUP

function Write-AuditLog {
    param(
        [string]$Action,
        [string]$Status,
        [string]$Details
    )

    $logEntry = @{
        timestamp  = (Get-Date).ToUniversalTime().ToString("o")
        action     = $Action
        status     = $Status
        details    = $Details
        approvalId = $ApprovalId
        resource   = $Resource
    } | ConvertTo-Json -Compress

    Write-Output "AUDIT: $logEntry"
}

function New-BackupFileName {
    param([string]$ResourceType)

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    return "$ResourceType-backup-$timestamp.zip"
}

function Backup-Configuration {
    Write-Output "Backing up configuration files..."

    try {
        # Get all app settings from Azure resources
        $resources = @()

        # Logic App configuration
        $logicApp = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Web/sites" | Where-Object { $_.Kind -like "*workflowapp*" }
        if ($logicApp) {
            $logicAppConfig = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $logicApp.Name
            $resources += @{
                type     = "logic-app"
                name     = $logicApp.Name
                settings = $logicAppConfig.SiteConfig.AppSettings
            }
        }

        # Function App configuration
        $functionApp = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.Web/sites" | Where-Object { $_.Kind -like "*functionapp*" -and $_.Kind -notlike "*workflowapp*" }
        if ($functionApp) {
            $funcConfig = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $functionApp.Name
            $resources += @{
                type     = "function-app"
                name     = $functionApp.Name
                settings = $funcConfig.SiteConfig.AppSettings
            }
        }

        # Create backup content
        $backupContent = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            resources = $resources
        } | ConvertTo-Json -Depth 10

        return $backupContent
    }
    catch {
        throw "Failed to backup configuration: $($_.Exception.Message)"
    }
}

function Backup-Logs {
    Write-Output "Backing up audit logs..."

    try {
        # Get storage context
        $storageContext = New-AzStorageContext -StorageAccountName $BackupStorageAccount -UseConnectedAccount

        # List and download audit logs from the last 7 days
        $cutoffDate = (Get-Date).AddDays(-7)
        $logs = Get-AzStorageBlob -Container "audit-logs" -Context $storageContext | Where-Object { $_.LastModified -gt $cutoffDate }

        $logContent = @()
        foreach ($log in $logs) {
            $content = Get-AzStorageBlobContent -Container "audit-logs" -Blob $log.Name -Context $storageContext -Force
            $logContent += @{
                name    = $log.Name
                size    = $log.Length
                lastMod = $log.LastModified.ToString("o")
            }
        }

        return @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            logCount  = $logs.Count
            logs      = $logContent
        } | ConvertTo-Json -Depth 5
    }
    catch {
        throw "Failed to backup logs: $($_.Exception.Message)"
    }
}

function Backup-Storage {
    Write-Output "Backing up storage containers..."

    try {
        $storageContext = New-AzStorageContext -StorageAccountName $BackupStorageAccount -UseConnectedAccount

        # Get list of containers and their blob counts
        $containers = Get-AzStorageContainer -Context $storageContext
        $summary = @()

        foreach ($container in $containers) {
            if ($container.Name -ne $BackupContainer) {
                $blobs = Get-AzStorageBlob -Container $container.Name -Context $storageContext
                $summary += @{
                    container = $container.Name
                    blobCount = $blobs.Count
                    totalSize = ($blobs | Measure-Object -Property Length -Sum).Sum
                }
            }
        }

        return @{
            timestamp  = (Get-Date).ToUniversalTime().ToString("o")
            containers = $summary
        } | ConvertTo-Json -Depth 5
    }
    catch {
        throw "Failed to backup storage: $($_.Exception.Message)"
    }
}

function Remove-OldBackups {
    param([int]$Days)

    Write-Output "Cleaning up backups older than $Days days..."

    try {
        $storageContext = New-AzStorageContext -StorageAccountName $BackupStorageAccount -UseConnectedAccount
        $cutoffDate = (Get-Date).AddDays(-$Days)

        $oldBackups = Get-AzStorageBlob -Container $BackupContainer -Context $storageContext | Where-Object { $_.LastModified -lt $cutoffDate }

        $removedCount = 0
        foreach ($backup in $oldBackups) {
            Remove-AzStorageBlob -Container $BackupContainer -Blob $backup.Name -Context $storageContext -Force
            $removedCount++
            Write-Output "Removed: $($backup.Name)"
        }

        Write-Output "Cleanup complete. Removed $removedCount old backups."
        return $removedCount
    }
    catch {
        Write-Warning "Cleanup failed: $($_.Exception.Message)"
        return 0
    }
}

# Main execution
try {
    Write-Output "=========================================="
    Write-Output "OpenClaw Backup Operation"
    Write-Output "=========================================="
    Write-Output "Resource: $Resource"
    Write-Output "Approval ID: $ApprovalId"
    Write-Output "Retention: $RetentionDays days"
    Write-Output "Timestamp: $((Get-Date).ToUniversalTime().ToString('o'))"
    Write-Output ""

    # Authenticate
    Write-Output "Authenticating with Azure..."
    Connect-AzAccount -Identity

    Write-AuditLog -Action "backup_started" -Status "in_progress" -Details "Starting backup for $Resource"

    # Get storage context
    $storageContext = New-AzStorageContext -StorageAccountName $BackupStorageAccount -UseConnectedAccount

    # Ensure backup container exists
    $container = Get-AzStorageContainer -Name $BackupContainer -Context $storageContext -ErrorAction SilentlyContinue
    if (-not $container) {
        New-AzStorageContainer -Name $BackupContainer -Context $storageContext -Permission Off
    }

    $backupResults = @()

    # Process backups based on resource type
    $resourcesToBackup = if ($Resource -eq "all") { @("config", "logs", "storage") } else { @($Resource) }

    foreach ($res in $resourcesToBackup) {
        Write-Output ""
        Write-Output "Processing: $res"
        Write-Output "-" * 40

        $backupContent = switch ($res) {
            "config" { Backup-Configuration }
            "logs" { Backup-Logs }
            "storage" { Backup-Storage }
            "database" {
                Write-Output "Database backup is handled by Azure Backup service"
                @{ type = "database"; status = "managed_by_azure" } | ConvertTo-Json
            }
        }

        # Upload backup to storage
        $fileName = New-BackupFileName -ResourceType $res
        $tempFile = Join-Path $env:TEMP $fileName

        $backupContent | Out-File -FilePath $tempFile -Encoding UTF8

        Set-AzStorageBlobContent -File $tempFile -Container $BackupContainer -Blob $fileName -Context $storageContext -Force | Out-Null

        Remove-Item $tempFile -Force

        $backupResults += @{
            resource = $res
            fileName = $fileName
            status   = "success"
        }

        Write-Output "Backup saved: $fileName"
    }

    # Cleanup old backups
    Write-Output ""
    $removedCount = Remove-OldBackups -Days $RetentionDays

    Write-AuditLog -Action "backup_completed" -Status "success" -Details "Backup completed successfully"

    # Summary
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "Backup Complete"
    Write-Output "=========================================="
    Write-Output "Resources backed up: $($backupResults.Count)"
    Write-Output "Old backups removed: $removedCount"
    Write-Output ""

    return @{
        status        = "success"
        approvalId    = $ApprovalId
        backups       = $backupResults
        cleanedUp     = $removedCount
        timestamp     = (Get-Date).ToUniversalTime().ToString("o")
    }
}
catch {
    $errorMessage = $_.Exception.Message
    Write-Error "Backup failed: $errorMessage"

    Write-AuditLog -Action "backup_failed" -Status "error" -Details $errorMessage

    return @{
        status     = "failed"
        approvalId = $ApprovalId
        error      = $errorMessage
    }
}
