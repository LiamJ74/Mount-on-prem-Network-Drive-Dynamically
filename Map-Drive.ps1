<#
.SYNOPSIS
    Maps network drives based on Azure AD group membership, with optional Azure Key Vault integration.
.DESCRIPTION
    This script, intended for deployment via Intune, determines a user's Azure AD groups,
    maps corresponding network drives according to a defined configuration, removes old mappings,
    and creates a status file for the detection script.
    It can receive secrets directly as parameters or fetch them from an Azure Key Vault.
.PARAMETER TenantId
    The Azure AD Tenant ID. Mandatory.
.PARAMETER Domain
    The company domain used to construct the user's UPN (e.g., "yourdomain.com"). Mandatory.
.PARAMETER KeyVaultName
    Optional. The name of the Azure Key Vault to retrieve secrets from. If used, ClientId and ClientSecret are ignored.
.PARAMETER ClientId
    The Client ID of the registered Azure AD application. Mandatory if not using Key Vault.
.PARAMETER ClientSecret
    The client secret for the Azure AD application. Mandatory if not using Key Vault.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    [Parameter(Mandatory=$true)]
    [string]$Domain,
    [Parameter(Mandatory=$false)]
    [string]$KeyVaultName,
    [Parameter(Mandatory=$false)]
    [string]$ClientId,
    [Parameter(Mandatory=$false)]
    [string]$ClientSecret
)

# --- Configuration ---

# Secret names to look for in Azure Key Vault.
$ClientIdSecretName = 'IntuneDriveMapper-ClientId'
$ClientSecretSecretName = 'IntuneDriveMapper-ClientSecret'

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
    "PUBLIC"  = "\\SERVER\\PUBLIC"
}

# Status file configuration
$StatusFileDirectory = "$env:LOCALAPPDATA\IntuneDriveMapping"
$StatusFileName = "status.json"
$StatusFilePath = Join-Path -Path $StatusFileDirectory -ChildPath $StatusFileName

# --- Functions ---

function Install-AzModule {
    param($ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Output "PowerShell module '$ModuleName' not found. Attempting to install..."
        try {
            Install-Module -Name $ModuleName -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
            Write-Output "Module '$ModuleName' installed successfully."
        } catch {
            Write-Error "Failed to install module '$ModuleName'. Error: $($_.Exception.Message)"
            return $false
        }
    } else {
        Write-Output "PowerShell module '$ModuleName' is already installed."
    }
    return $true
}

function Get-SecretsFromKeyVault {
    Write-Output "Attempting to retrieve secrets from Azure Key Vault '$KeyVaultName'..."
    if (-not (Install-AzModule -ModuleName Az.Accounts)) { return $null }
    if (-not (Install-AzModule -ModuleName Az.KeyVault)) { return $null }

    try {
        Write-Output "Connecting to Azure with user's identity..."
        Connect-AzAccount -Identity -ErrorAction Stop
        Write-Output "Successfully connected to Azure."
    } catch {
        Write-Error "Failed to connect to Azure using Managed Identity. Ensure the user has an identity and permissions. Error: $($_.Exception.Message)"
        return $null
    }

    try {
        Write-Output "Retrieving secrets from Key Vault..."
        $kvClientId = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $ClientIdSecretName -AsPlainText -ErrorAction Stop)
        $kvClientSecret = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $ClientSecretSecretName -AsPlainText -ErrorAction Stop)
        Write-Output "Successfully retrieved secrets from Key Vault."
        return @{ ClientId = $kvClientId; ClientSecret = $kvClientSecret }
    } catch {
        Write-Error "Failed to retrieve secrets from Key Vault '$KeyVaultName'. Check secret names and permissions. Error: $($_.Exception.Message)"
        return $null
    }
}

function Get-GraphApiToken {
    param($GatClientId, $GatClientSecret)
    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Attempting to get Graph API token..."
    try {
        $response = Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType "application/x-www-form-urlencoded" -Body @{
            grant_type    = "client_credentials"
            client_id     = $GatClientId
            client_secret = $GatClientSecret
            scope         = "https://graph.microsoft.com/.default"
        }
        Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Successfully obtained access token."
        return $response.access_token
    } catch {
        Write-Error "Failed to get Graph API access token. Error: $($_.Exception.Message)"
        return $null
    }
}

function Normalize-UncPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return ($Path.TrimEnd('\')).ToLower()
}

function Get-AvailableDriveLetter {
    # This function finds the next available drive letter from D: to Z:
    $reserved = @('A','B','C')
    # Get all drive letters currently in use by any logical disk (local, network, etc.)
    $usedLetters = (Get-CimInstance -ClassName Win32_LogicalDisk).DeviceID | ForEach-Object { $_.TrimEnd(':') }
    $used = $reserved + $usedLetters | Select-Object -Unique
    $all = [char[]](68..90) # D to Z
    return $all | Where-Object { $_ -notin $used } | Select-Object -First 1
}

# --- Script Start ---

Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Script execution started."

# 1. Validate parameters and retrieve secrets

# If ClientSecret parameter is not provided, try to get it from the environment variable
if (-not $PSBoundParameters.ContainsKey('ClientSecret')) {
    if ($env:INTUNE_CLIENT_SECRET) {
        Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Using client secret from environment variable."
        $ClientSecret = $env:INTUNE_CLIENT_SECRET
    }
}

if ($PSBoundParameters.ContainsKey('KeyVaultName')) {
    $secrets = Get-SecretsFromKeyVault
    if (-not $secrets) {
        Write-Error "Could not retrieve secrets from Key Vault. Exiting."
        exit 1
    }
    $ClientId = $secrets.ClientId
    $ClientSecret = $secrets.ClientSecret
} elseif (-not ($PSBoundParameters.ContainsKey('ClientId') -and $ClientSecret)) {
    Write-Error "Invalid parameters. You must provide either -KeyVaultName, or both -ClientId and -ClientSecret (or set the INTUNE_CLIENT_SECRET environment variable). Exiting."
    exit 1
}

# 2. Get Graph API Token
$token = Get-GraphApiToken -GatClientId $ClientId -GatClientSecret $ClientSecret
if (-not $token) {
    exit 1
}

$headers = @{
    Authorization     = "Bearer $token"
    Consistencylevel  = "eventual"
}

# 3. Get user's groups
try {
    # Get current user and construct UPN
    $localUser = whoami
    $localUserName = $localUser.Split('\')[-1]
    # The domain is now provided by the -Domain parameter.
    $userPrincipalName = "$localUserName@$Domain"
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Constructed UPN: $userPrincipalName"

    # Get User ID from Graph API
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Getting user object ID from Graph API..."
    $userUri = "https://graph.microsoft.com/v1.0/users/$userPrincipalName"
    $userResponse = Invoke-RestMethod -Uri $userUri -Headers $headers -Method Get
    $userId = $userResponse.id
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Found User ID: $userId"

    # Get all user's group memberships using the User ID, with pagination
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Getting all groups for user ID: $userId..."
    $allGroups = [System.Collections.Generic.List[string]]::new()
    $groupsUri = "https://graph.microsoft.com/v1.0/users/$userId/transitiveMemberOf/microsoft.graph.group?`$select=displayName&`$top=999"

    do {
        $groupResponse = Invoke-RestMethod -Uri $groupsUri -Headers $headers -Method Get
        if ($null -ne $groupResponse.value) {
            $allGroups.AddRange([string[]]$groupResponse.value.displayName)
        }
        $groupsUri = $groupResponse.'@odata.nextLink'
    } while (-not [string]::IsNullOrEmpty($groupsUri))

    $userGroupNames = $allGroups
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Group retrieval complete."

    if ($userGroupNames) {
        Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Found $($userGroupNames.Count) groups in total."
    } else {
        Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: User is not a member of any groups."
    }
} catch {
    $errorMessage = $_.Exception.Message
    if ($errorMessage -like "*401*" -or $errorMessage -like "*Unauthorized*") {
        Write-Error "Failed to get groups for '$userPrincipalName'. The server returned a 401 Unauthorized error. This is likely due to incorrect API permissions on the Azure AD App Registration. Please ensure the application has the 'GroupMember.Read.All' and 'User.Read.All' APPLICATION permissions and that admin consent has been granted. Refer to the README.md for instructions."
    } else {
        Write-Error "Failed to get groups for '$userPrincipalName'. Error: $errorMessage"
    }
    exit 1
}

# 4. Calculate required shares
$requiredShareNames = @()
foreach ($groupName in $userGroupNames) {
    foreach ($mapping in $DriveMappings.GetEnumerator()) {
        if ($groupName -like $mapping.Name) {
            $requiredShareNames += $mapping.Value
        }
    }
}
$requiredShareNames += "PUBLIC"
$requiredShareNames = $requiredShareNames | Select-Object -Unique
$requiredUncPaths = @()
foreach ($shareName in $requiredShareNames) {
    if ($NetworkShares.ContainsKey($shareName)) {
        $paths = $NetworkShares[$shareName]
        if ($paths -is [array]) { $requiredUncPaths += $paths } else { $requiredUncPaths += $paths }
    }
}
$requiredUncPaths = $requiredUncPaths | ForEach-Object { Normalize-UncPath $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
Write-Output "Required UNC paths: $($requiredUncPaths -join ', ')"

# 5. Clean up existing drive mappings
Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Analyzing existing drive mappings..."
$currentMappings = Get-CimInstance -ClassName Win32_NetworkConnection

# 5a. Remove duplicate mappings (same UNC path mapped to multiple letters)
if ($null -ne $currentMappings) {
    $mappingsByUnc = $currentMappings | Group-Object -Property { Normalize-UncPath -Path $_.RemoteName }
    foreach ($group in $mappingsByUnc) {
        if ($group.Count -gt 1) {
            $mappingsToKeep = $group.Group | Select-Object -First 1
            $mappingsToRemove = $group.Group | Select-Object -Skip 1
            Write-Warning "Found duplicate mappings for UNC path '$($group.Name)'. Keeping drive '$($mappingsToKeep.LocalName)' and removing others."
            foreach ($mappingToRemove in $mappingsToRemove) {
                Write-Output "Removing duplicate drive '$($mappingToRemove.LocalName)' mapped to '$($mappingToRemove.RemoteName)'."
                try {
                    (New-Object -ComObject WScript.Network).RemoveNetworkDrive($mappingToRemove.LocalName, $true, $true)
                } catch {
                    Write-Error "Failed to remove duplicate drive '$($mappingToRemove.LocalName)'. Error: $($_.Exception.Message)"
                }
            }
        }
    }
}

# 5b. Get a fresh list of mappings and prepare for unmapping unnecessary drives
$currentMappings = Get-CimInstance -ClassName Win32_NetworkConnection
$currentlyMappedPaths = @()
if ($null -ne $currentMappings) {
    $currentlyMappedPaths = $currentMappings.RemoteName | ForEach-Object { Normalize-UncPath -Path $_ }
}

# 6. Unmap unnecessary drives
Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Checking for unnecessary drives to unmap..."
if ($null -ne $currentMappings) {
    foreach ($mapping in $currentMappings) {
        $normalizedRemotePath = Normalize-UncPath -Path $mapping.RemoteName
        if ($null -eq $normalizedRemotePath) { continue }

        if ($requiredUncPaths -notcontains $normalizedRemotePath) {
            Write-Output "Removing drive '$($mapping.LocalName)' mapped to '$($mapping.RemoteName)' as it is no longer required."
            try {
                (New-Object -ComObject WScript.Network).RemoveNetworkDrive($mapping.LocalName, $true, $true)
            } catch {
                Write-Error "Failed to remove drive '$($mapping.LocalName)'. Error: $($_.Exception.Message)"
            }
        }
    }
}

# 7. Map new drives
Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Checking for required drives to map..."
# Get a fresh list of mapped paths after any unmapping operations
$currentMappingsAfterUnmap = Get-CimInstance -ClassName Win32_NetworkConnection
$currentlyMappedPaths = @() # Initialize as an empty array
if ($null -ne $currentMappingsAfterUnmap) {
    $currentlyMappedPaths = $currentMappingsAfterUnmap.RemoteName | ForEach-Object { Normalize-UncPath -Path $_ }
}

foreach ($path in $requiredUncPaths) {
    if ($currentlyMappedPaths -contains $path) {
        Write-Output "Drive for '$path' is already mapped. Skipping."
        continue
    }

    # Check if the network path is accessible before attempting to map
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Testing path '$path'..."
    if (-not (Test-Path -Path $path)) {
        Write-Warning "Path '$path' is not accessible or does not exist. Skipping."
        continue
    }

    $letter = Get-AvailableDriveLetter
    if ($letter) {
        Write-Output "Mapping '$path' to drive letter '$letter'..."
        try {
            New-PSDrive -Name $letter -PSProvider FileSystem -Root $path -Persist -ErrorAction Stop | Out-Null
        } catch {
            Write-Error "Failed to map '$path'. Error: $($_.Exception.Message)"
        }
    } else {
        Write-Error "No available drive letter to map '$path'."
    }
}

# 8. Create the status file
Write-Output "Creating status file..."
if (-not (Test-Path -Path $StatusFileDirectory)) {
    New-Item -Path $StatusFileDirectory -ItemType Directory -Force | Out-Null
}
$status = @{ lastRunTimestamp = (Get-Date).ToString("o"); requiredDrives = $requiredUncPaths }
$status | ConvertTo-Json | Set-Content -Path $StatusFilePath -Encoding UTF8

Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Drive mapping script finished."
exit 0
