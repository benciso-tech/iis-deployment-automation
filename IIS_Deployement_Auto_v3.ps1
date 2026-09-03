#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    IIS Incremental Deployment Automation - Version 3.3

.DESCRIPTION
    Automates a controlled IIS application deployment workflow.

    The workflow includes:
      - Application selection
      - Prerequisite validation
      - Full pre-deployment backup
      - SHA-256 backup verification
      - Deployment manifest generation
      - Explicit deployment commit
      - IIS application pool management
      - Incremental file deployment
      - Post-deployment configuration
      - Local validation
      - External F5 traffic-switch checkpoint
      - External validation checkpoint
      - F5 failback checkpoint
      - Application rollback
      - Rollback verification
      - Final application-pool state verification

    IMPORTANT:
      F5 load-balancer management is intentionally NOT automated by this
      script. Production traffic changes are performed externally through
      the approved CyberArk process.

.NOTES
    Version: 3.3
    Platform: Windows PowerShell 5.1+
#>

$ErrorActionPreference = "Stop"

Import-Module WebAdministration -ErrorAction Stop


# ============================================================
# PARAMETERS
# ============================================================

param(
    [int[]]$Applications,

    [string]$WebRoot = "C:\Inetpub\WWW",

    [string]$DeploymentRoot = "C:\Deployment",

    [string]$BackupRoot = "C:\IIS-Deployment-Backups",

    [string]$LogRoot = "C:\IIS-Deployment-Logs",

    [string]$PostDeploymentConfigScript,

    [switch]$Unattended,

    [switch]$WhatIf
)


# ============================================================
# GLOBAL DEPLOYMENT STATE
# ============================================================

$DeploymentState = [ordered]@{
    DeploymentId          = $null
    StartTime             = Get-Date
    SelectedApplications  = @()
    BackupPath            = $null
    BackupVerified        = $false
    ManifestCreated       = $false
    DeploymentCommitted   = $false
    DeploymentCompleted   = $false
    ConfigurationVerified = $false
    LocalValidationPassed = $false
    F5TrafficSwitched     = $false
    ExternalValidation    = $false
    F5FailbackPerformed   = $false
    RollbackPerformed     = $false
    RollbackVerified      = $false
    FinalStateVerified    = $false
}


# ============================================================
# APPLICATION DEFINITIONS
# ============================================================

$ApplicationDefinitions = @(

    [pscustomobject]@{
        Id                    = 1
        Name                  = "Application01"
        AppPool               = "Application01"
        SourcePath            = Join-Path $DeploymentRoot "Application01"
        DestinationPath       = Join-Path $WebRoot "Application01"
        Critical               = $false
        ConfigurationRequired  = $false
        ConfigurationFile      = "web.config"
        ConfigurationNotes     = @()
    },

    [pscustomobject]@{
        Id                    = 2
        Name                  = "Application02"
        AppPool               = "Application02"
        SourcePath            = Join-Path $DeploymentRoot "Application02"
        DestinationPath       = Join-Path $WebRoot "Application02"
        Critical               = $false
        ConfigurationRequired  = $false
        ConfigurationFile      = "web.config"
        ConfigurationNotes     = @()
    },

    [pscustomobject]@{
        Id                    = 3
        Name                  = "Application03"
        AppPool               = "Application03"
        SourcePath            = Join-Path $DeploymentRoot "Application03"
        DestinationPath       = Join-Path $WebRoot "Application03"
        Critical               = $false
        ConfigurationRequired  = $false
        ConfigurationFile      = "web.config"
        ConfigurationNotes     = @()
    },

    [pscustomobject]@{
        Id                    = 4
        Name                  = "Application04"
        AppPool               = "Application04"
        SourcePath            = Join-Path $DeploymentRoot "Application04"
        DestinationPath       = Join-Path $WebRoot "Application04"
        Critical               = $false
        ConfigurationRequired  = $false
        ConfigurationFile      = "web.config"
        ConfigurationNotes     = @()
    },

    [pscustomobject]@{
        Id                    = 5
        Name                  = "Application05"
        AppPool               = "Application05"
        SourcePath            = Join-Path $DeploymentRoot "Application05"
        DestinationPath       = Join-Path $WebRoot "Application05"
        Critical               = $false
        ConfigurationRequired  = $false
        ConfigurationFile      = "web.config"
        ConfigurationNotes     = @()
    },

    [pscustomobject]@{
        Id                    = 6
        Name                  = "Application06"
        AppPool               = "Application06"
        SourcePath            = Join-Path $DeploymentRoot "Application06"
        DestinationPath       = Join-Path $WebRoot "Application06"
        Critical               = $false
        ConfigurationRequired  = $false
        ConfigurationFile      = "web.config"
        ConfigurationNotes     = @()
    },

    [pscustomobject]@{
        Id                    = 7
        Name                  = "CriticalApplication"
        AppPool               = "CriticalApplication"
        SourcePath            = Join-Path $DeploymentRoot "CriticalApplication"
        DestinationPath       = Join-Path $WebRoot "CriticalApplication"
        Critical               = $true
        ConfigurationRequired  = $true
        ConfigurationFile      = "web.config"

        ConfigurationNotes     = @(
            "Review application-specific configuration values.",
            "Verify required service endpoints.",
            "Verify required database/application settings.",
            "Confirm environment-specific values are correct.",
            "Do not remove unrelated configuration entries."
        )
    }
)


# ============================================================
# INITIALIZATION
# ============================================================

function Initialize-Deployment {

    $DeploymentState.DeploymentId =
        "DEP-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss")

    $script:DeploymentLogFile = Join-Path `
        $LogRoot `
        "$($DeploymentState.DeploymentId).log"

    New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null

    Write-DeploymentLog "=============================================="
    Write-DeploymentLog "IIS DEPLOYMENT AUTOMATION V3.3"
    Write-DeploymentLog "=============================================="
    Write-DeploymentLog "Deployment ID: $($DeploymentState.DeploymentId)"
    Write-DeploymentLog "Start Time: $($DeploymentState.StartTime)"
    Write-DeploymentLog "Web Root: $WebRoot"
    Write-DeploymentLog "Deployment Root: $DeploymentRoot"
    Write-DeploymentLog "Backup Root: $BackupRoot"
    Write-DeploymentLog "Log File: $script:DeploymentLogFile"

    if ($Unattended) {
        Write-DeploymentLog "Execution Mode: UNATTENDED"
    }
    else {
        Write-DeploymentLog "Execution Mode: INTERACTIVE"
    }

    if ($WhatIf) {
        Write-DeploymentLog "Execution Mode: WHATIF - NO CHANGES WILL BE MADE" "WARNING"
    }
}


# ============================================================
# LOGGING
# ============================================================

function Write-DeploymentLog {

    param(
        [string]$Message,
        [ValidateSet("INFO","SUCCESS","WARNING","ERROR")]
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $LogEntry = "[{0}] [{1}] {2}" -f `
        $Timestamp,
        $Level,
        $Message

    Add-Content `
        -Path $script:DeploymentLogFile `
        -Value $LogEntry

    switch ($Level) {

        "SUCCESS" {
            Write-Host $LogEntry
        }

        "WARNING" {
            Write-Host $LogEntry
        }

        "ERROR" {
            Write-Host $LogEntry
        }

        default {
            Write-Host $LogEntry
        }
    }
}


# ============================================================
# APPLICATION SELECTION
# ============================================================

function Get-DeploymentSelection {

    if ($Applications) {

        $Selected = foreach ($Id in $Applications) {

            $Application = $ApplicationDefinitions |
                Where-Object { $_.Id -eq $Id }

            if (-not $Application) {
                throw "Application ID $Id does not exist."
            }

            $Application
        }
    }
    else {

        if ($Unattended) {
            throw "Unattended mode requires -Applications."
        }

        Write-Host ""
        Write-Host "Available Applications"
        Write-Host "======================"

        foreach ($Application in $ApplicationDefinitions) {

            $CriticalText = ""

            if ($Application.Critical) {
                $CriticalText = " [CRITICAL]"
            }

            Write-Host (
                "{0}. {1}{2}" -f `
                $Application.Id,
                $Application.Name,
                $CriticalText
            )
        }

        Write-Host ""
        Write-Host "Enter application numbers separated by commas."
        Write-Host "Enter A to deploy all applications."
        Write-Host ""

        $Selection = Read-Host "Selection"

        if ($Selection -eq "A") {
            $Selected = $ApplicationDefinitions
        }
        else {

            $Ids = $Selection -split "," |
                ForEach-Object {
                    [int]$_.Trim()
                }

            $Selected = foreach ($Id in $Ids) {

                $Application = $ApplicationDefinitions |
                    Where-Object { $_.Id -eq $Id }

                if (-not $Application) {
                    throw "Application ID $Id does not exist."
                }

                $Application
            }
        }
    }

    if (-not $Selected) {
        throw "No applications were selected."
    }

    $DeploymentState.SelectedApplications = @($Selected)

    Write-DeploymentLog "Applications selected:"

    foreach ($Application in $Selected) {
        Write-DeploymentLog (
            "  {0} - AppPool: {1}" -f `
            $Application.Name,
            $Application.AppPool
        )
    }

    $CriticalApplications = @(
        $Selected |
        Where-Object { $_.Critical }
    )

    if ($CriticalApplications.Count -gt 0) {

        Write-DeploymentLog `
            "One or more CRITICAL applications are selected." `
            "WARNING"
    }

    return $Selected
}


# ============================================================
# PREREQUISITE VALIDATION
# ============================================================

function Test-DeploymentPrerequisites {

    param(
        [array]$SelectedApplications
    )

    Write-DeploymentLog "Validating deployment prerequisites..."

    if (-not (Test-Path $WebRoot)) {
        throw "Web root does not exist: $WebRoot"
    }

    if (-not (Test-Path $DeploymentRoot)) {
        throw "Deployment root does not exist: $DeploymentRoot"
    }

    foreach ($Application in $SelectedApplications) {

        if (-not (Test-Path $Application.SourcePath)) {

            throw (
                "Deployment source does not exist: {0}" -f
                $Application.SourcePath
            )
        }

        if (-not (Test-Path "IIS:\AppPools\$($Application.AppPool)")) {

            throw (
                "IIS application pool does not exist: {0}" -f
                $Application.AppPool
            )
        }

        if (-not (Test-Path $Application.DestinationPath)) {

            throw (
                "Application destination does not exist: {0}" -f
                $Application.DestinationPath
            )
        }

        $BuildFiles = Get-ChildItem `
            -Path $Application.SourcePath `
            -Recurse `
            -File `
            -Force

        if ($BuildFiles.Count -eq 0) {

            throw (
                "Deployment source contains no files: {0}" -f
                $Application.SourcePath
            )
        }
    }

    Write-DeploymentLog `
        "Prerequisite validation completed successfully." `
        "SUCCESS"
}


# ============================================================
# FILE HASH MAP
# ============================================================

function Get-FileHashMap {

    param(
        [string]$Path
    )

    $HashMap = @{}

    if (-not (Test-Path $Path)) {
        return $HashMap
    }

    $RootPath = (Resolve-Path $Path).Path

    $Files = Get-ChildItem `
        -Path $RootPath `
        -Recurse `
        -File `
        -Force

    foreach ($File in $Files) {

        $RelativePath =
            $File.FullName.Substring(
                $RootPath.Length
            ).TrimStart("\","/")

        $Hash = Get-FileHash `
            -Path $File.FullName `
            -Algorithm SHA256

        $HashMap[$RelativePath] = $Hash.Hash
    }

    return $HashMap
}


# ============================================================
# DIRECTORY HASH COMPARISON
# ============================================================

function Compare-DirectoryHashes {

    param(
        [string]$OriginalPath,
        [string]$BackupPath
    )

    Write-DeploymentLog `
        "Comparing SHA-256 hashes for backup verification..."

    $OriginalHashes = Get-FileHashMap `
        -Path $OriginalPath

    $BackupHashes = Get-FileHashMap `
        -Path $BackupPath

    if ($OriginalHashes.Count -ne $BackupHashes.Count) {

        Write-DeploymentLog `
            "Backup file count mismatch." `
            "ERROR"

        return $false
    }

    foreach ($FilePath in $OriginalHashes.Keys) {

        if (-not $BackupHashes.ContainsKey($FilePath)) {

            Write-DeploymentLog `
                "Backup is missing: $FilePath" `
                "ERROR"

            return $false
        }

        if ($OriginalHashes[$FilePath] -ne $BackupHashes[$FilePath]) {

            Write-DeploymentLog `
                "Hash mismatch: $FilePath" `
                "ERROR"

            return $false
        }
    }

    return $true
}


# ============================================================
# FULL BACKUP
# ============================================================

function New-DeploymentBackup {

    param(
        [array]$SelectedApplications
    )

    $BackupPath = Join-Path `
        $BackupRoot `
        $DeploymentState.DeploymentId

    New-Item `
        -Path $BackupPath `
        -ItemType Directory `
        -Force | Out-Null

    $DeploymentState.BackupPath = $BackupPath

    Write-DeploymentLog "Creating full pre-deployment backup."
    Write-DeploymentLog "Backup location: $BackupPath"

    foreach ($Application in $SelectedApplications) {

        $ApplicationBackupPath = Join-Path `
            $BackupPath `
            $Application.Name

        New-Item `
            -Path $ApplicationBackupPath `
            -ItemType Directory `
            -Force | Out-Null

        Write-DeploymentLog (
            "Backing up {0}..." -f
            $Application.Name
        )

        if (-not $WhatIf) {

            $Items = Get-ChildItem `
                -Path $Application.DestinationPath `
                -Force

            foreach ($Item in $Items) {

                Copy-Item `
                    -Path $Item.FullName `
                    -Destination $ApplicationBackupPath `
                    -Recurse `
                    -Force
            }
        }
    }

    Write-DeploymentLog `
        "Full backup completed." `
        "SUCCESS"
}


# ============================================================
# BACKUP INTEGRITY
# ============================================================

function Confirm-BackupIntegrity {

    param(
        [array]$SelectedApplications
    )

    if ($WhatIf) {

        Write-DeploymentLog `
            "WHATIF: Backup integrity verification skipped."

        return
    }

    Write-DeploymentLog "Verifying backup integrity..."

    foreach ($Application in $SelectedApplications) {

        $BackupApplicationPath = Join-Path `
            $DeploymentState.BackupPath `
            $Application.Name

        $Verified = Compare-DirectoryHashes `
            -OriginalPath $Application.DestinationPath `
            -BackupPath $BackupApplicationPath

        if (-not $Verified) {

            throw (
                "Backup verification failed for {0}." -f
                $Application.Name
            )
        }

        Write-DeploymentLog (
            "Backup verified: {0}" -f
            $Application.Name
        ) "SUCCESS"
    }

    $DeploymentState.BackupVerified = $true

    Write-DeploymentLog `
        "All backups passed SHA-256 verification." `
        "SUCCESS"
}


# ============================================================
# DEPLOYMENT MANIFEST
# ============================================================

function New-DeploymentManifest {

    param(
        [array]$SelectedApplications
    )

    $Manifest = @()

    foreach ($Application in $SelectedApplications) {

        $SourceRoot = (
            Resolve-Path $Application.SourcePath
        ).Path

        $BuildFiles = Get-ChildItem `
            -Path $Application.SourcePath `
            -Recurse `
            -File `
            -Force

        foreach ($File in $BuildFiles) {

            $RelativePath =
                $File.FullName.Substring(
                    $SourceRoot.Length
                ).TrimStart("\","/")

            $DestinationFile = Join-Path `
                $Application.DestinationPath `
                $RelativePath

            $Action = "ADD"

            if (Test-Path $DestinationFile) {
                $Action = "UPDATE"
            }

            $Manifest += [pscustomobject]@{
                Application = $Application.Name
                File        = $RelativePath
                Action      = $Action
                Source      = $File.FullName
                Destination = $DestinationFile
            }
        }
    }

    $ManifestPath = Join-Path `
        $DeploymentState.BackupPath `
        "DeploymentManifest.csv"

    if (-not $WhatIf) {

        $Manifest |
            Export-Csv `
                -Path $ManifestPath `
                -NoTypeInformation
    }

    $DeploymentState.ManifestCreated = $true

    Write-DeploymentLog (
        "Deployment manifest created with {0} files." -f
        $Manifest.Count
    ) "SUCCESS"

    return $Manifest
}


# ============================================================
# DEPLOYMENT CONFIRMATION
# ============================================================

function Confirm-Deployment {

    param(
        [array]$SelectedApplications
    )

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "DEPLOYMENT PLAN"
    Write-Host "=============================================="
    Write-Host ""

    foreach ($Application in $SelectedApplications) {

        $CriticalText = ""

        if ($Application.Critical) {
            $CriticalText = " [CRITICAL]"
        }

        Write-Host (
            "{0}{1}" -f
            $Application.Name,
            $CriticalText
        )
    }

    Write-Host ""
    Write-Host "A FULL BACKUP has been created and verified."
    Write-Host ""
    Write-Host "The deployment is INCREMENTAL."
    Write-Host "Files not included in the build will remain untouched."
    Write-Host ""

    if ($WhatIf) {

        Write-DeploymentLog `
            "WHATIF mode: deployment commit skipped."

        return
    }

    if ($Unattended) {

        Write-DeploymentLog `
            "Unattended mode: deployment automatically committed." `
            "WARNING"

        $DeploymentState.DeploymentCommitted = $true

        return
    }

    $Confirmation = Read-Host `
        "Type DEPLOY to commit this deployment"

    if ($Confirmation -ne "DEPLOY") {

        throw "Deployment was not committed."
    }

    $CriticalSelected = $SelectedApplications |
        Where-Object { $_.Critical }

    if ($CriticalSelected.Count -gt 0) {

        $CriticalConfirmation = Read-Host `
            "Critical application selected. Type DEPLOY-CRITICAL to continue"

        if ($CriticalConfirmation -ne "DEPLOY-CRITICAL") {

            throw `
                "Critical deployment was not confirmed."
        }
    }

    $DeploymentState.DeploymentCommitted = $true

    Write-DeploymentLog `
        "Deployment explicitly committed by operator." `
        "SUCCESS"
}


# ============================================================
# STOP APPLICATION POOLS
# ============================================================

function Stop-DeploymentApplicationPools {

    param(
        [array]$SelectedApplications
    )

    foreach ($Application in $SelectedApplications) {

        Write-DeploymentLog (
            "Stopping application pool: {0}" -f
            $Application.AppPool
        )

        if (-not $WhatIf) {

            Stop-WebAppPool `
                -Name $Application.AppPool
        }

        Write-DeploymentLog (
            "Application pool stopped: {0}" -f
            $Application.AppPool
        ) "SUCCESS"
    }
}


# ============================================================
# INCREMENTAL DEPLOYMENT
# ============================================================

function Invoke-IncrementalDeployment {

    param(
        [array]$SelectedApplications
    )

    Write-DeploymentLog `
        "Beginning incremental deployment."

    foreach ($Application in $SelectedApplications) {

        Write-DeploymentLog (
            "Deploying {0}" -f
            $Application.Name
        )

        $SourceRoot = (
            Resolve-Path $Application.SourcePath
        ).Path

        $BuildFiles = Get-ChildItem `
            -Path $Application.SourcePath `
            -Recurse `
            -File `
            -Force

        $TotalFiles = $BuildFiles.Count
        $CurrentFile = 0

        foreach ($File in $BuildFiles) {

            $CurrentFile++

            $RelativePath =
                $File.FullName.Substring(
                    $SourceRoot.Length
                ).TrimStart("\","/")

            $DestinationFile = Join-Path `
                $Application.DestinationPath `
                $RelativePath

            $DestinationDirectory =
                Split-Path `
                    $DestinationFile `
                    -Parent

            $PercentComplete =
                [math]::Round(
                    ($CurrentFile / $TotalFiles) * 100,
                    0
                )

            Write-Progress `
                -Activity "Deploying $($Application.Name)" `
                -Status $RelativePath `
                -PercentComplete $PercentComplete

            if (-not $WhatIf) {

                if (-not (Test-Path $DestinationDirectory)) {

                    New-Item `
                        -Path $DestinationDirectory `
                        -ItemType Directory `
                        -Force | Out-Null
                }

                Copy-Item `
                    -Path $File.FullName `
                    -Destination $DestinationFile `
                    -Force
            }
        }

        Write-Progress `
            -Activity "Deploying $($Application.Name)" `
            -Completed

        Write-DeploymentLog (
            "Incremental deployment completed: {0}" -f
            $Application.Name
        ) "SUCCESS"
    }

    $DeploymentState.DeploymentCompleted = $true
}


# ============================================================
# POST-DEPLOYMENT CONFIGURATION
# ============================================================

function Invoke-PostDeploymentConfiguration {

    param(
        [array]$SelectedApplications
    )

    Write-DeploymentLog `
        "Beginning post-deployment configuration."

    foreach ($Application in $SelectedApplications) {

        if (-not $Application.ConfigurationRequired) {

            Write-DeploymentLog (
                "No additional configuration required for {0}." -f
                $Application.Name
            )

            continue
        }

        $ConfigurationPath = Join-Path `
            $Application.DestinationPath `
            $Application.ConfigurationFile

        if (-not (Test-Path $ConfigurationPath)) {

            throw (
                "Required configuration file does not exist: {0}" -f
                $ConfigurationPath
            )
        }

        Write-DeploymentLog (
            "Configuration file: {0}" -f
            $ConfigurationPath
        )

        $BeforeHash = (
            Get-FileHash `
                -Path $ConfigurationPath `
                -Algorithm SHA256
        ).Hash

        if ($PostDeploymentConfigScript) {

            Write-DeploymentLog `
                "Executing post-deployment configuration script."

            & $PostDeploymentConfigScript

            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {

                throw `
                    "Post-deployment configuration script failed."
            }
        }
        elseif (-not $Unattended -and -not $WhatIf) {

            Write-Host ""
            Write-Host "=============================================="
            Write-Host "MANUAL CONFIGURATION REQUIRED"
            Write-Host "=============================================="
            Write-Host ""
            Write-Host "Application: $($Application.Name)"
            Write-Host "Configuration: $ConfigurationPath"
            Write-Host ""

            foreach ($Note in $Application.ConfigurationNotes) {
                Write-Host "- $Note"
            }

            Write-Host ""
            Read-Host `
                "Make the required configuration changes, then press ENTER"
        }
        elseif ($Unattended -and -not $PostDeploymentConfigScript) {

            throw (
                "Configuration is required for {0}, but no configuration " +
                "script was supplied for unattended execution." -f
                $Application.Name
            )
        }

        if (-not $WhatIf) {

            $AfterHash = (
                Get-FileHash `
                    -Path $ConfigurationPath `
                    -Algorithm SHA256
            ).Hash

            if ($BeforeHash -eq $AfterHash) {

                Write-DeploymentLog `
                    "Configuration file was not changed." `
                    "WARNING"

                if (-not $Unattended) {

                    $Confirmation = Read-Host `
                        "Type CONFIG-OK if no configuration change was required"

                    if ($Confirmation -ne "CONFIG-OK") {

                        throw `
                            "Configuration change was not confirmed."
                    }
                }
            }
            else {

                Write-DeploymentLog (
                    "Configuration changed: {0}" -f
                    $Application.Name
                ) "SUCCESS"
            }
        }
    }

    $DeploymentState.ConfigurationVerified = $true

    Write-DeploymentLog `
        "Post-deployment configuration completed." `
        "SUCCESS"
}


# ============================================================
# START APPLICATION POOLS
# ============================================================

function Start-DeploymentApplicationPools {

    param(
        [array]$SelectedApplications
    )

    foreach ($Application in $SelectedApplications) {

        Write-DeploymentLog (
            "Starting application pool: {0}" -f
            $Application.AppPool
        )

        if (-not $WhatIf) {

            Start-WebAppPool `
                -Name $Application.AppPool
        }

        Write-DeploymentLog (
            "Application pool started: {0}" -f
            $Application.AppPool
        ) "SUCCESS"
    }
}


# ============================================================
# LOCAL APPLICATION VALIDATION
# ============================================================

function Invoke-ApplicationValidation {

    param(
        [array]$SelectedApplications
    )

    Write-DeploymentLog `
        "Beginning local application validation."

    $ValidationFailures = @()

    foreach ($Application in $SelectedApplications) {

        Write-DeploymentLog (
            "Validating application: {0}" -f
            $Application.Name
        )

        if ($WhatIf) {
            continue
        }

        $AppPoolState = (
            Get-WebAppPoolState `
                -Name $Application.AppPool
        ).Value

        if ($AppPoolState -ne "Started") {

            $ValidationFailures +=
                "$($Application.Name): App pool is $AppPoolState"

            continue
        }

        if (-not (Test-Path $Application.DestinationPath)) {

            $ValidationFailures +=
                "$($Application.Name): Application directory missing"

            continue
        }

        $Files = Get-ChildItem `
            -Path $Application.DestinationPath `
            -Recurse `
            -File `
            -Force

        if ($Files.Count -eq 0) {

            $ValidationFailures +=
                "$($Application.Name): No application files found"

            continue
        }

        Write-DeploymentLog (
            "Local validation passed: {0}" -f
            $Application.Name
        ) "SUCCESS"
    }

    if ($ValidationFailures.Count -gt 0) {

        foreach ($Failure in $ValidationFailures) {

            Write-DeploymentLog `
                $Failure `
                "ERROR"
        }

        throw "Local application validation failed."
    }

    $DeploymentState.LocalValidationPassed = $true

    Write-DeploymentLog `
        "All local validation checks passed." `
        "SUCCESS"
}


# ============================================================
# F5 TRAFFIC SWITCH CHECKPOINT
# ============================================================

function Confirm-F5TrafficSwitch {

    Write-DeploymentLog `
        "Server passed local validation and is ready for production traffic."

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "READY FOR F5 TRAFFIC SWITCH"
    Write-Host "=============================================="
    Write-Host ""
    Write-Host "The deployment server has passed local validation."
    Write-Host ""
    Write-Host "Use the approved CyberArk process to access"
    Write-Host "and manage the F5 load balancer."
    Write-Host ""
    Write-Host "Switch production traffic to this server."
    Write-Host ""
    Write-Host "IMPORTANT:"
    Write-Host "This PowerShell script does NOT manage the F5."
    Write-Host "F5 management remains an external operational step."
    Write-Host ""

    if ($Unattended) {

        Write-DeploymentLog `
            "F5 traffic switch remains an external/manual operation." `
            "WARNING"

        throw `
            "Unattended execution cannot independently confirm the F5 traffic switch."
    }

    $Confirmation = Read-Host `
        "Type F5-SWITCHED after the F5 traffic change is complete"

    if ($Confirmation -ne "F5-SWITCHED") {

        throw `
            "F5 traffic switch was not confirmed."
    }

    $DeploymentState.F5TrafficSwitched = $true

    Write-DeploymentLog `
        "Operator confirmed F5 traffic switch." `
        "SUCCESS"
}


# ============================================================
# EXTERNAL VALIDATION
# ============================================================

function Invoke-ExternalValidation {

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "EXTERNAL VALIDATION"
    Write-Host "=============================================="
    Write-Host ""
    Write-Host "Production traffic has been switched."
    Write-Host ""
    Write-Host "Perform the required external validation."
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  - Application functionality"
    Write-Host "  - Production transaction test"
    Write-Host "  - Monitoring verification"
    Write-Host "  - Error/HTTP status validation"
    Write-Host "  - Application health verification"
    Write-Host ""

    if ($Unattended) {

        throw `
            "External validation requires operator or external monitoring confirmation."
    }

    $Result = Read-Host `
        "Did external validation pass? Enter PASS or FAIL"

    switch ($Result.ToUpper()) {

        "PASS" {

            $DeploymentState.ExternalValidation = $true

            Write-DeploymentLog `
                "External validation passed." `
                "SUCCESS"

            return $true
        }

        "FAIL" {

            $DeploymentState.ExternalValidation = $false

            Write-DeploymentLog `
                "External validation failed." `
                "ERROR"

            return $false
        }

        default {

            throw `
                "Invalid external validation response."
        }
    }
}


# ============================================================
# F5 FAILBACK CHECKPOINT
# ============================================================

function Confirm-F5Failback {

    Write-DeploymentLog `
        "External validation failed. F5 failback is required." `
        "WARNING"

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "F5 FAILBACK REQUIRED"
    Write-Host "=============================================="
    Write-Host ""
    Write-Host "External validation has failed."
    Write-Host ""
    Write-Host "Production traffic must be moved back"
    Write-Host "to the known-good server BEFORE application rollback."
    Write-Host ""
    Write-Host "Use the approved CyberArk process to access"
    Write-Host "and manage the F5 load balancer."
    Write-Host ""
    Write-Host "The PowerShell script does NOT manage the F5."
    Write-Host ""

    if ($Unattended) {

        throw `
            "Unattended execution cannot independently confirm F5 failback."
    }

    $Confirmation = Read-Host `
        "Type F5-FAILED-BACK after F5 traffic has been restored"

    if ($Confirmation -ne "F5-FAILED-BACK") {

        throw `
            "F5 failback was not confirmed."
    }

    $DeploymentState.F5FailbackPerformed = $true

    Write-DeploymentLog `
        "Operator confirmed F5 failback." `
        "SUCCESS"
}


# ============================================================
# APPLICATION ROLLBACK
# ============================================================

function Restore-DeploymentBackup {

    param(
        [array]$ApplicationsToRollback
    )

    if (-not $DeploymentState.BackupPath) {

        throw `
            "No deployment backup is available for rollback."
    }

    Write-DeploymentLog `
        "Beginning application rollback." `
        "WARNING"

    foreach ($Application in $ApplicationsToRollback) {

        Write-DeploymentLog (
            "Rolling back: {0}" -f
            $Application.Name
        ) "WARNING"

        $BackupApplicationPath = Join-Path `
            $DeploymentState.BackupPath `
            $Application.Name

        if (-not (Test-Path $BackupApplicationPath)) {

            throw (
                "Backup does not exist for {0}." -f
                $Application.Name
            )
        }

        if (-not $WhatIf) {

            if (Test-Path $Application.DestinationPath) {

                $CurrentItems = Get-ChildItem `
                    -Path $Application.DestinationPath `
                    -Force

                foreach ($Item in $CurrentItems) {

                    Remove-Item `
                        -Path $Item.FullName `
                        -Recurse `
                        -Force
                }
            }
            else {

                New-Item `
                    -Path $Application.DestinationPath `
                    -ItemType Directory `
                    -Force | Out-Null
            }

            $BackupItems = Get-ChildItem `
                -Path $BackupApplicationPath `
                -Force

            foreach ($Item in $BackupItems) {

                Copy-Item `
                    -Path $Item.FullName `
                    -Destination $Application.DestinationPath `
                    -Recurse `
                    -Force
            }
        }

        Write-DeploymentLog (
            "Rollback completed: {0}" -f
            $Application.Name
        ) "SUCCESS"
    }

    $DeploymentState.RollbackPerformed = $true
}


# ============================================================
# ROLLBACK VERIFICATION
# ============================================================

function Confirm-RollbackIntegrity {

    param(
        [array]$ApplicationsToRollback
    )

    if ($WhatIf) {

        Write-DeploymentLog `
            "WHATIF: Rollback verification skipped."

        return
    }

    Write-DeploymentLog `
        "Verifying rollback integrity."

    foreach ($Application in $ApplicationsToRollback) {

        $BackupApplicationPath = Join-Path `
            $DeploymentState.BackupPath `
            $Application.Name

        $Verified = Compare-DirectoryHashes `
            -OriginalPath $BackupApplicationPath `
            -BackupPath $Application.DestinationPath

        if (-not $Verified) {

            throw (
                "Rollback verification failed for {0}." -f
                $Application.Name
            )
        }

        Write-DeploymentLog (
            "Rollback verified: {0}" -f
            $Application.Name
        ) "SUCCESS"
    }

    $DeploymentState.RollbackVerified = $true

    Write-DeploymentLog `
        "Rollback integrity verification passed." `
        "SUCCESS"
}


# ============================================================
# ROLLBACK SELECTION
# ============================================================

function Get-RollbackSelection {

    param(
        [array]$SelectedApplications
    )

    if ($SelectedApplications.Count -eq 1) {

        return $SelectedApplications
    }

    Write-Host ""
    Write-Host "=============================================="
    Write-Host "ROLLBACK SELECTION"
    Write-Host "=============================================="
    Write-Host ""

    foreach ($Application in $SelectedApplications) {

        Write-Host (
            "{0}. {1}" -f
            $Application.Id,
            $Application.Name
        )
    }

    Write-Host ""
    Write-Host "Enter application IDs separated by commas."
    Write-Host "Enter ALL to rollback every selected application."
    Write-Host ""

    if ($Unattended) {

        return $SelectedApplications
    }

    $Selection = Read-Host "Rollback selection"

    if ($Selection.ToUpper() -eq "ALL") {

        return $SelectedApplications
    }

    $Ids = $Selection -split "," |
        ForEach-Object {
            [int]$_.Trim()
        }

    $RollbackApplications = foreach ($Id in $Ids) {

        $Application = $SelectedApplications |
            Where-Object { $_.Id -eq $Id }

        if (-not $Application) {

            throw (
                "Application ID {0} was not part of this deployment." -f
                $Id
            )
        }

        $Application
    }

    return $RollbackApplications
}


# ============================================================
# FINAL APPLICATION POOL STATE
# ============================================================

function Test-FinalApplicationPoolState {

    param(
        [array]$SelectedApplications
    )

    Write-DeploymentLog `
        "Verifying final application pool state."

    foreach ($Application in $SelectedApplications) {

        if ($WhatIf) {
            continue
        }

        $State = (
            Get-WebAppPoolState `
                -Name $Application.AppPool
        ).Value

        if ($State -ne "Started") {

            Write-DeploymentLog (
                "Application pool is not running: {0} [{1}]" -f
                $Application.AppPool,
                $State
            ) "WARNING"
        }
        else {

            Write-DeploymentLog (
                "Application pool state verified: {0} [Started]" -f
                $Application.AppPool
            ) "SUCCESS"
        }
    }

    $DeploymentState.FinalStateVerified = $true
}


# ============================================================
# DEPLOYMENT SUMMARY
# ============================================================

function Write-DeploymentSummary {

    $EndTime = Get-Date

    $Duration =
        $EndTime - $DeploymentState.StartTime

    Write-DeploymentLog ""
    Write-DeploymentLog "=============================================="
    Write-DeploymentLog "DEPLOYMENT SUMMARY"
    Write-DeploymentLog "=============================================="

    Write-DeploymentLog `
        "Deployment ID: $($DeploymentState.DeploymentId)"

    Write-DeploymentLog `
        "Applications: $($DeploymentState.SelectedApplications.Count)"

    Write-DeploymentLog `
        "Backup Verified: $($DeploymentState.BackupVerified)"

    Write-DeploymentLog `
        "Deployment Committed: $($DeploymentState.DeploymentCommitted)"

    Write-DeploymentLog `
        "Deployment Completed: $($DeploymentState.DeploymentCompleted)"

    Write-DeploymentLog `
        "Configuration Verified: $($DeploymentState.ConfigurationVerified)"

    Write-DeploymentLog `
        "Local Validation Passed: $($DeploymentState.LocalValidationPassed)"

    Write-DeploymentLog `
        "F5 Traffic Switched: $($DeploymentState.F5TrafficSwitched)"

    Write-DeploymentLog `
        "External Validation: $($DeploymentState.ExternalValidation)"

    Write-DeploymentLog `
        "F5 Failback Performed: $($DeploymentState.F5FailbackPerformed)"

    Write-DeploymentLog `
        "Rollback Performed: $($DeploymentState.RollbackPerformed)"

    Write-DeploymentLog `
        "Rollback Verified: $($DeploymentState.RollbackVerified)"

    Write-DeploymentLog `
        "Final State Verified: $($DeploymentState.FinalStateVerified)"

    Write-DeploymentLog `
        "Duration: $($Duration.ToString())"

    Write-DeploymentLog "=============================================="
}


# ============================================================
# MAIN DEPLOYMENT WORKFLOW
# ============================================================

try {

    Initialize-Deployment

    $SelectedApplications =
        Get-DeploymentSelection

    Test-DeploymentPrerequisites `
        -SelectedApplications $SelectedApplications

    if ($WhatIf) {

        Write-DeploymentLog `
            "WHATIF mode enabled. No production changes will be made." `
            "WARNING"
    }

    # --------------------------------------------------------
    # BACKUP
    # --------------------------------------------------------

    New-DeploymentBackup `
        -SelectedApplications $SelectedApplications

    Confirm-BackupIntegrity `
        -SelectedApplications $SelectedApplications

    # --------------------------------------------------------
    # MANIFEST
    # --------------------------------------------------------

    $Manifest =
        New-DeploymentManifest `
            -SelectedApplications $SelectedApplications

    # --------------------------------------------------------
    # COMMIT
    # --------------------------------------------------------

    Confirm-Deployment `
        -SelectedApplications $SelectedApplications

    if (-not $DeploymentState.DeploymentCommitted) {

        throw "Deployment was not committed."
    }

    # --------------------------------------------------------
    # STOP APP POOLS
    # --------------------------------------------------------

    Stop-DeploymentApplicationPools `
        -SelectedApplications $SelectedApplications

    try {

        # ----------------------------------------------------
        # INCREMENTAL DEPLOYMENT
        # ----------------------------------------------------

        Invoke-IncrementalDeployment `
            -SelectedApplications $SelectedApplications

        # ----------------------------------------------------
        # CONFIGURATION
        # ----------------------------------------------------

        Invoke-PostDeploymentConfiguration `
            -SelectedApplications $SelectedApplications

        # ----------------------------------------------------
        # START APP POOLS
        # ----------------------------------------------------

        Start-DeploymentApplicationPools `
            -SelectedApplications $SelectedApplications

        # ----------------------------------------------------
        # LOCAL VALIDATION
        # ----------------------------------------------------

        Invoke-ApplicationValidation `
            -SelectedApplications $SelectedApplications

    }
    catch {

        Write-DeploymentLog `
            "Server-side deployment failed before F5 traffic switch." `
            "ERROR"

        Write-DeploymentLog `
            "Beginning automatic application rollback." `
            "WARNING"

        # Ensure pools are stopped before restoring files.
        foreach ($Application in $SelectedApplications) {

            try {

                Stop-WebAppPool `
                    -Name $Application.AppPool `
                    -ErrorAction SilentlyContinue
            }
            catch {
                # Continue rollback attempt.
            }
        }

        Restore-DeploymentBackup `
            -ApplicationsToRollback $SelectedApplications

        Confirm-RollbackIntegrity `
            -ApplicationsToRollback $SelectedApplications

        Start-DeploymentApplicationPools `
            -SelectedApplications $SelectedApplications

        throw
    }

    # --------------------------------------------------------
    # F5 TRAFFIC SWITCH
    # --------------------------------------------------------

    if (-not $WhatIf) {

        Confirm-F5TrafficSwitch

        # ----------------------------------------------------
        # EXTERNAL VALIDATION
        # ----------------------------------------------------

        $ExternalValidationPassed =
            Invoke-ExternalValidation

        if (-not $ExternalValidationPassed) {

            # ------------------------------------------------
            # F5 FAILBACK MUST HAPPEN FIRST
            # ------------------------------------------------

            Confirm-F5Failback

            # ------------------------------------------------
            # APPLICATION ROLLBACK
            # ------------------------------------------------

            $RollbackApplications =
                Get-RollbackSelection `
                    -SelectedApplications $SelectedApplications

            foreach ($Application in $RollbackApplications) {

                try {

                    Stop-WebAppPool `
                        -Name $Application.AppPool `
                        -ErrorAction SilentlyContinue
                }
                catch {
                    # Continue rollback attempt.
                }
            }

            Restore-DeploymentBackup `
                -ApplicationsToRollback $RollbackApplications

            Confirm-RollbackIntegrity `
                -ApplicationsToRollback $RollbackApplications

            Start-DeploymentApplicationPools `
                -SelectedApplications $RollbackApplications

            Write-DeploymentLog `
                "Rollback completed after F5 failback." `
                "WARNING"

            Write-DeploymentLog `
                "Deployment server should remain passive." `
                "WARNING"
        }
        else {

            Write-DeploymentLog `
                "Deployment successfully passed external validation." `
                "SUCCESS"
        }
    }

    # --------------------------------------------------------
    # FINAL STATE
    # --------------------------------------------------------

    Test-FinalApplicationPoolState `
        -SelectedApplications $SelectedApplications

    Write-DeploymentSummary

    Write-DeploymentLog `
        "Deployment workflow completed." `
        "SUCCESS"
}
catch {

    Write-DeploymentLog `
        "DEPLOYMENT FAILED: $($_.Exception.Message)" `
        "ERROR"

    Write-DeploymentSummary

    exit 1
}