<#
.SYNOPSIS
    Detection script for Intune.
.DESCRIPTION
    This script checks if the required network drives, as defined by the main mapping script,
    are correctly configured. It reads a status file left by the mapping script
    to get the list of drives that should be present.
#>

# --- Configuration ---
$StatusFileDirectory = "$env:LOCALAPPDATA\IntuneDriveMapping"
$StatusFileName = "status.json"
$StatusFilePath = Join-Path -Path $StatusFileDirectory -ChildPath $StatusFileName
$MaxAgeHours = 24 # Number of hours before the status is considered outdated

# --- Script Start ---

# Check if the status file exists
if (-not (Test-Path -Path $StatusFilePath)) {
    Write-Output "Status file not found at '$StatusFilePath'. Remediation required."
    exit 1
}

# Read and parse the status file
$status = Get-Content -Path $StatusFilePath | ConvertFrom-Json
if (-not $status) {
    Write-Output "Could not read or parse the status file. Remediation required."
    exit 1
}

# Check the age of the status file
$lastRunTimestamp = [datetime]$status.lastRunTimestamp
$age = (Get-Date) - $lastRunTimestamp
if ($age.TotalHours -gt $MaxAgeHours) {
    Write-Output "Status file is outdated (older than $MaxAgeHours hours). Remediation required."
    exit 1
}

# Get currently mapped drives
try {
    $mappedDrives = Get-WmiObject -Class Win32_MappedLogicalDisk | Select-Object -ExpandProperty ProviderName
} catch {
    Write-Error "Error retrieving mapped drives."
    exit 1 # Exit with error, Intune will retry later
}

# Get the list of required drives from the status file
$requiredUncPaths = $status.requiredDrives

# If no drives are required for this user, detection is successful
if ($null -eq $requiredUncPaths -or $requiredUncPaths.Count -eq 0) {
     Write-Output "No network drives are required for this user. Detection successful."
     exit 0
}

# Check if all required drives are mapped
$allDrivesMapped = $true
foreach ($path in $requiredUncPaths) {
    if ($mappedDrives -notcontains $path) {
        Write-Output "Detection: Required drive missing - '$path'"
        $allDrivesMapped = $false
        break
    }
}

if ($allDrivesMapped) {
    Write-Output "Detection: All required drives are mapped."
    exit 0
} else {
    Write-Output "Detection: At least one required drive is missing. Remediation required."
    exit 1
}
