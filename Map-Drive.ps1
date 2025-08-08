<#
.SYNOPSIS
    Maps network drives based on Azure AD group membership.
.DESCRIPTION
    This script, intended for deployment via Intune, determines a user's Azure AD groups,
    maps corresponding network drives according to a defined configuration, removes old mappings,
    and creates a status file for the detection script.
.PARAMETER TenantId
    The Azure AD Tenant ID.
.PARAMETER ClientId
    The Client ID of the registered Azure AD application.
.PARAMETER ClientSecret
    The client secret for the Azure AD application.
.PARAMETER Domain
    The company domain used to construct the user's UPN (e.g., "yourdomain.com").
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    [Parameter(Mandatory=$true)]
    [string]$ClientId,
    [Parameter(Mandatory=$true)]
    [string]$ClientSecret,
    [Parameter(Mandatory=$true)]
    [string]$Domain
)

# --- Configuration ---

# Filter for searching groups in Graph API. Modify as needed.
$GroupFilter = "startswith(displayName, 'AZURE/AD_GROUPS')"

# Maps a group name (with wildcard *) to a logical share name.
$DriveMappings = @{
    "AZURE/AD_GROUPS*_R1"  = "Finance"
    "AZURE/AD_GROUPS*_RW1" = "Finance"
    "AZURE/AD_GROUPS*_R2"  = "HR"
    "AZURE/AD_GROUPS*_RW2" = "HR"
}

# Maps a logical share name to one or more actual UNC paths.
$NetworkShares = @{
    "Finance" = "\\SERVER\\FINANCE"
    "HR"      = @(
        "\\SERVER\\HR-DOCS",
        "\\SERVER\\HR-ARCHIVES"
    )
    "Public"  = "\\SERVER\\PUBLIC"
}

# Status file configuration
$StatusFileDirectory = "$env:ProgramData\IntuneDriveMapping"
$StatusFileName = "status.json"
$StatusFilePath = Join-Path -Path $StatusFileDirectory -ChildPath $StatusFileName

# --- Functions ---

function Get-GraphApiToken {
    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    Write-Output "Getting access token from $tokenUri..."
    try {
        $response = Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType "application/x-www-form-urlencoded" -Body @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "https://graph.microsoft.com/.default"
        }
        Write-Output "Successfully obtained access token."
        return $response.access_token
    } catch {
        Write-Error "Failed to get Graph API access token. Error: $($_.Exception.Message)"
        return $null
    }
}

function Get-AvailableDriveLetter {
    $reserved = @('A','B','C','D')
    $usedBySystem = (Get-CimInstance Win32_LogicalDisk).DeviceID | ForEach-Object { $_.TrimEnd(':') }
    $usedInReg = (Get-ChildItem HKCU:\Network -ErrorAction SilentlyContinue).PSChildName
    $used = $reserved + $usedBySystem + $usedInReg | Select-Object -Unique
    $all = [char[]](67..90) # C to Z
    return $all | Where-Object { $_ -notin $used } | Select-Object -First 1
}

# --- Script Start ---

Write-Output "Starting drive mapping script."

$token = Get-GraphApiToken
if (-not $token) {
    exit 1 # Stop the script if authentication fails
}

$headers = @{
    Authorization     = "Bearer $token"
    Consistencylevel  = "eventual"
}

# 1. Get user's groups
try {
    $localUser = $env:USERNAME
    $userPrincipalName = "$localUser@$Domain"
    Write-Output "Getting groups for user: $userPrincipalName"

    $groupsUri = "https://graph.microsoft.com/v1.0/users/$userPrincipalName/transitiveMemberOf/microsoft.graph.group?`$filter=$GroupFilter&`$select=displayName"
    $groupResponse = Invoke-RestMethod -Uri $groupsUri -Headers $headers -Method Get
    $userGroupNames = $groupResponse.value.displayName

    Write-Output "Found groups: $($userGroupNames -join ', ')"
} catch {
    Write-Error "Failed to get groups for '$userPrincipalName'. Error: $($_.Exception.Message)"
    exit 1
}

# 2. Calculate required shares based on groups (Bug fix with -like)
$requiredShareNames = @()
foreach ($groupName in $userGroupNames) {
    foreach ($mapping in $DriveMappings.GetEnumerator()) {
        if ($groupName -like $mapping.Name) {
            Write-Output "Match found: Group '$groupName' -> Mapping '$($mapping.Value)'"
            $requiredShareNames += $mapping.Value
        }
    }
}

# Add the "Public" drive by default
$requiredShareNames += "Public"
$requiredShareNames = $requiredShareNames | Select-Object -Unique
Write-Output "Required logical share names: $($requiredShareNames -join ', ')"

# Convert logical share names to UNC paths
$requiredUncPaths = @()
foreach ($shareName in $requiredShareNames) {
    if ($NetworkShares.ContainsKey($shareName)) {
        $paths = $NetworkShares[$shareName]
        if ($paths -is [array]) {
            $requiredUncPaths += $paths
        } else {
            $requiredUncPaths += $paths
        }
    }
}
$requiredUncPaths = $requiredUncPaths | Select-Object -Unique
Write-Output "Required UNC paths: $($requiredUncPaths -join ', ')"

# 3. Manage existing drives (unmapping)
Write-Output "Analyzing existing network drives for removal..."
$mappedDrives = Get-ChildItem -Path 'HKCU:\Network' -ErrorAction SilentlyContinue | ForEach-Object {
    [PSCustomObject]@{
        DriveLetter = $_.PSChildName
        RemotePath  = (Get-ItemProperty -Path $_.PSPath).RemotePath
    }
}

foreach ($drive in $mappedDrives) {
    if ($requiredUncPaths -notcontains $drive.RemotePath) {
        Write-Output "Removing drive '$($drive.DriveLetter)' mapped to '$($drive.RemotePath)' as it is no longer required."
        Remove-PSDrive -Name $drive.DriveLetter -Force -ErrorAction SilentlyContinue
    }
}

# 4. Map new drives
Write-Output "Mapping required drives..."
$currentlyMappedPaths = (Get-WmiObject -Class Win32_MappedLogicalDisk -ErrorAction SilentlyContinue).ProviderName

foreach ($path in $requiredUncPaths) {
    if ($currentlyMappedPaths -contains $path) {
        Write-Output "Drive for '$path' is already mapped. Skipping."
        continue
    }

    $letter = Get-AvailableDriveLetter
    if ($letter) {
        Write-Output "Mapping '$path' to drive letter '$letter'..."
        try {
            New-PSDrive -Name $letter -PSProvider FileSystem -Root $path -Persist -ErrorAction Stop | Out-Null
            Write-Output "Success: '$path' mapped to '$letter'."
        } catch {
            Write-Error "Failed to map '$path'. Error: $($_.Exception.Message)"
        }
    } else {
        Write-Error "No available drive letter to map '$path'."
    }
}

# 5. Create the status file for detection
Write-Output "Creating status file..."
if (-not (Test-Path -Path $StatusFileDirectory)) {
    New-Item -Path $StatusFileDirectory -ItemType Directory -Force | Out-Null
}

$status = @{
    lastRunTimestamp = (Get-Date).ToString("o") # ISO 8601 format
    requiredDrives   = $requiredUncPaths
}
$status | ConvertTo-Json | Set-Content -Path $StatusFilePath -Encoding UTF8

Write-Output "Drive mapping script finished."
exit 0
