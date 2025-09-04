<#
.SYNOPSIS
    Maps network drives based on Azure AD group membership. Supports multiple authentication methods.
.DESCRIPTION
    This script, intended for deployment via Intune, determines a user's Azure AD groups,
    maps corresponding network drives according to a defined configuration, removes old mappings,
    and creates a status file for the detection script.
    It supports three authentication methods:
    1. Direct Parameters: Provide ClientId and ClientSecret as command-line arguments.
    2. Azure Key Vault: Provide a Key Vault name to fetch credentials securely.
    3. Hardcoded: Define credentials directly in the script (for testing/remediation).
.PARAMETER TenantId
    Optional. The Azure AD Tenant ID. Can be hardcoded in the script instead.
.PARAMETER Domain
    Optional. The company domain (e.g., "yourdomain.com"). Can be hardcoded in the script instead.
.PARAMETER KeyVaultName
    Optional. The name of the Azure Key Vault to retrieve secrets from. If used, ClientId and ClientSecret are ignored.
.PARAMETER ClientId
    The Client ID of the registered Azure AD application. Mandatory if not using Key Vault.
.PARAMETER ClientSecret
    The client secret for the Azure AD application. Mandatory if not using Key Vault.
#>
param(
    [Parameter(Mandatory=$false)]
    [string]$TenantId,
    [Parameter(Mandatory=$false)]
    [string]$Domain,
    [Parameter(Mandatory=$false)]
    [string]$KeyVaultName,
    [Parameter(Mandatory=$false)]
    [string]$ClientId,
    [Parameter(Mandatory=$false)]
    [string]$ClientSecret
)

# --- Configuration ---

# --- Hardcoded Configuration (Alternative Method) ---
# For a zero-parameter execution (e.g., for simple remediation), you can define all required values here.
# The script will use these values only if the corresponding parameters are not provided.
# For security, storing secrets here is not the recommended method for production deployment via Intune.
$HardcodedTenantId = "" # <-- Enter Tenant ID here
$HardcodedDomain = "" # <-- Enter domain (e.g., "yourdomain.com") here
$HardcodedClientId = "" # <-- Enter Client ID here
$HardcodedClientSecret = "" # <-- Enter Client Secret here
# --- End Hardcoded Configuration ---

# --- Drive Exclusion Configuration ---
# Add any UNC paths here that should NEVER be unmapped by this script.
# This is useful for shared mailboxes or other drives that users may map manually.
$ExcludedUncPaths = @(
    # "\\SERVER\SHARE1",
    # "\\ANOTHER-SERVER\SHARE2"
)
# --- End Drive Exclusion Configuration ---

# Secret names to look for in Azure Key Vault.
$ClientIdSecretName = 'IntuneDriveMapper-ClientId'
$ClientSecretSecretName = 'IntuneDriveMapper-ClientSecret'

# Maps a group name (with wildcard *) to a logical share name.
$DriveMappings = @{
    "ALPESCN_ORDONNANCEMENT_R"              = "ORDONNANCEMENT"
    "ALPESCN_ORDONNANCEMENT_RW"             = "ORDONNANCEMENT"
    "ALPESCN_LOGISTIQUE_R"                  = "LOGISTIQUE"
    "ALPESCN_LOGISTIQUE_RW"                 = "LOGISTIQUE"
    "ALPESCN_INDUSTRIALISATION_R"           = "INDUSTRIALISATION"
    "ALPESCN_INDUSTRIALISATION_RW"          = "INDUSTRIALISATION"
    "ALPESCN_PRODUCTION_USINAGE_R"          = "PRODUCTION_USINAGE"
    "ALPESCN_PRODUCTION_USINAGE_RW"         = "PRODUCTION_USINAGE"
    "ALPESCN_PRODUCTION_FINITION_R"         = "PRODUCTION_FINITION"
    "ALPESCN_PRODUCTION_FINITION_RW"        = "PRODUCTION_FINITION"
    "ALPESCN_PRODUCTION_CONDITIONNEMENT_R"  = "PRODUCTION_CONDITIONNEMENT"
    "ALPESCN_PRODUCTION_CONDITIONNEMENT_RW" = "PRODUCTION_CONDITIONNEMENT"
    "ALPESCN_PRODUCTION_3D_R"               = "PRODUCTION_3D"
    "ALPESCN_PRODUCTION_3D_RW"              = "PRODUCTION_3D"
    "ALPESCN_DIRECTION_R"                   = "DIRECTION"
    "ALPESCN_DIRECTION_RW"                  = "DIRECTION"
    "ALPESCN_FACILITIES_R"                  = "FACILITIES"
    "ALPESCN_FACILITIES_RW"                 = "FACILITIES"
    "ALPESCN_FINANCE_R"                     = "FINANCE"
    "ALPESCN_FINANCE_RW"                    = "FINANCE"
    "ALPESCN_HR_R"                          = "HR"
    "ALPESCN_HR_RW"                         = "HR"
    "ALPESCN_HSE_R"                         = "HSE"
    "ALPESCN_HSE_RW"                        = "HSE"
    "ALPESCN_MAINTENANCE_R"                 = "MAINTENANCE"
    "ALPESCN_MAINTENANCE_RW"                = "MAINTENANCE"
    "ALPESCN_OFFICE_MANAGEMENT_R"           = "OFFICE_MANAGEMENT"
    "ALPESCN_OFFICE_MANAGEMENT_RW"          = "OFFICE_MANAGEMENT"
    "ALPESCN_PUBLIC_R"                      = "PUBLIC"
    "ALPESCN_PUBLIC_RW"                     = "PUBLIC"
    "ALPESCN_QUALITE_RW"                    = "QUALITE"
    "ALPESCN_QUALITE_R"                     = "QUALITE"
    "R&D"                                   = "R&D"
    "INTUNE_Scientific"			    = "SCIENTIFIC"
    "INTUNE_MaterioVigilance"               = "VIGILANCE"
}

$NetworkShares = @{
    "ORDONNANCEMENT"                        = "\\10.80.2.20\ORDONNANCEMENT"
    "LOGISTIQUE"                            = "\\10.80.2.20\LOGISTIQUE"
    "INDUSTRIALISATION"                     = "\\10.80.2.20\INDUSTRIALISATION"
    "PRODUCTION_USINAGE"                    = "\\10.80.2.20\PRODUCTION_USINAGE"
    "PRODUCTION_FINITION"                   = "\\10.80.2.20\PRODUCTION_FINITION"
    "PRODUCTION_CONDITIONNEMENT" = @(
	"\\10.80.2.20\PRODUCTION_CONDITIONNEMENT",
	"\\192.168.100.20\Ordrefabrication"
	)
    "PRODUCTION_3D"                         = "\\10.80.2.20\PRODUCTION_3D"
    "PUBLIC"                                = "\\10.80.2.20\PUBLIC"
    "DIRECTION"                             = "\\10.80.2.20\DIRECTION"
    "FACILITIES"                            = "\\10.80.2.20\FACILITIES"
    "FINANCE"                               = "\\10.80.2.20\FINANCE"
    "HR"                                    = "\\10.80.2.20\HR"
    "HSE"                                   = "\\10.80.2.20\HSE"
    "MAINTENANCE"                           = "\\10.80.2.20\MAINTENANCE"
    "OFFICE_MANAGEMENT"                     = "\\10.80.2.20\OFFICE_MANAGEMENT"
    "QUALITE"                               = "\\10.80.2.20\QUALITE"
    "R&D" = @(
        "\\vm-data\RDM",
        "\\vm-data\TLC",
        "\\srv-rd\3D",
        "\\srv-rd\R&D",
        "\\vm-data\PlansDeFabrication",
        "\\vm-data\M&S",
        "\\vm-data\IBD",
        "\\vm-data\Competitors"
    )
    "SCIENTIFIC" = @(
		"\\vm-data\ClinicalActivities",
		"\\vm-data\AffairesScientifiques",
		"\\vm-data\M&S",
		"\\vm-data\QMS"
	)
    "VIGILANCE" = @(
		"\\srv-rd\conception$",
		"\\vm-data\DHR",
		"\\vm-data\PlansDeFabrication"
	)
}

# Access control for the "Public" share based on other assigned logical shares.
# Use this to include or exclude the Public share if a user has access to specific other shares.
# For example, you can deny "Public" to users who have access to the "R&D" share.
$allowedSharesForPublic = @(
	"ORDONNANCEMENT",
	"LOGISTIQUE",
	"INDUSTRIALISATION",
	"PRODUCTION_USINAGE",
	"PRODUCTION_FINITION",
	"PRODUCTION_CONDITIONNEMENT",
	"PRODUCTION_3D",
	"DIRECTION",
	"FACILITIES",
	"FINANCE",
	"HR",
    "HSE",
    "MAINTENANCE",
    "OFFICE_MANAGEMENT",
    "QUALITE"

)

$deniedSharesForPublic  = @(
	"R&D",
	"SCIENTIFIC",
	"VIGILANCE"
)

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

function Get-AvailableDriveLetter {
    $reserved = @('A','B','C','D')
    $usedBySystem = (Get-CimInstance Win32_LogicalDisk).DeviceID | ForEach-Object { $_.TrimEnd(':') }
    $usedInReg = (Get-ChildItem HKCU:\Network -ErrorAction SilentlyContinue).PSChildName
    $used = $reserved + $usedBySystem + $usedInReg | Select-Object -Unique
    $all = [char[]](67..90) # C to Z
    return $all | Where-Object { $_ -notin $used } | Select-Object -First 1
}

# --- Script Start ---

Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Script execution started."

# 1. Validate and assign TenantId and Domain
if (-not $PSBoundParameters.ContainsKey('TenantId') -and $HardcodedTenantId) {
    $TenantId = $HardcodedTenantId
}
if (-not $PSBoundParameters.ContainsKey('Domain') -and $HardcodedDomain) {
    $Domain = $HardcodedDomain
}
if (-not $TenantId -or -not $Domain) {
    Write-Error "TenantId and Domain must be provided either as parameters or in the hardcoded configuration section. Exiting."
    exit 1
}

# 2. Validate parameters and retrieve secrets

# If ClientSecret parameter is not provided, try to get it from the environment variable
if (-not $PSBoundParameters.ContainsKey('ClientSecret')) {
    if ($env:INTUNE_CLIENT_SECRET) {
        Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Using client secret from environment variable."
        $ClientSecret = $env:INTUNE_CLIENT_SECRET
    }
}

if ($PSBoundParameters.ContainsKey('KeyVaultName')) {
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Auth method: Key Vault."
    $secrets = Get-SecretsFromKeyVault
    if (-not $secrets) {
        Write-Error "Could not retrieve secrets from Key Vault. Exiting."
        exit 1
    }
    $ClientId = $secrets.ClientId
    $ClientSecret = $secrets.ClientSecret
} elseif ($PSBoundParameters.ContainsKey('ClientId')) {
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Auth method: Parameters."
    # This block is for when -ClientId is passed. The $ClientSecret is either from the param or env var.
    # The check for its existence will happen in the final 'if' statement below.
} elseif ($HardcodedClientId -and $HardcodedClientSecret) {
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Auth method: Hardcoded in script."
    $ClientId = $HardcodedClientId
    $ClientSecret = $HardcodedClientSecret
}

# Final validation: After attempting all methods, do we have the credentials we need?
if (-not ($ClientId -and $ClientSecret)) {
    Write-Error @"
Credential information could not be determined. You must use one of the following methods:
1. Provide the -KeyVaultName parameter.
2. Provide the -ClientId and -ClientSecret parameters (or set the INTUNE_CLIENT_SECRET environment variable).
3. Fill in the HardcodedClientId and HardcodedClientSecret variables at the top of the script.
Exiting.
"@
    exit 1
}

# 3. Get Graph API Token
$token = Get-GraphApiToken -GatClientId $ClientId -GatClientSecret $ClientSecret
if (-not $token) {
    exit 1
}

$headers = @{
    Authorization     = "Bearer $token"
    Consistencylevel  = "eventual"
}

# 4. Get user's groups
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

    # Get all user's group memberships using the User ID
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Getting all groups for user ID: $userId..."
    $groupsUri = "https://graph.microsoft.com/v1.0/users/$userId/transitiveMemberOf/microsoft.graph.group?`$select=displayName&`$top=999"
    $groupResponse = Invoke-RestMethod -Uri $groupsUri -Headers $headers -Method Get
    $userGroupNames = $groupResponse.value.displayName
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

# 5. Calculate required shares
$requiredShareNames = @()
foreach ($groupName in $userGroupNames) {
    foreach ($mapping in $DriveMappings.GetEnumerator()) {
        if ($groupName -like $mapping.Name) {
            $requiredShareNames += $mapping.Value
        }
    }
}
# Get a unique list of the logical shares assigned to the user so far.
$uniqueUserShares = $requiredShareNames | Select-Object -Unique

# Conditionally add the "Public" share based on the user's assigned logical shares.
$includePublic = $false # Start with no access by default, and grant it based on rules.

# Case 1: No lists are defined. Everyone gets access for backward compatibility.
if ($allowedSharesForPublic.Count -eq 0 -and $deniedSharesForPublic.Count -eq 0) {
    $includePublic = $true
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: Public share access lists are empty, granting default access."
} else {
    # Case 2: Allow list logic.
    # If the allow list is defined, user must have an assigned share that is on the list.
    # If the allow list is empty, access is allowed by default (and will be checked against the deny list).
    $isAllowed = $false
    if ($allowedSharesForPublic.Count -gt 0) {
        if ($uniqueUserShares | Where-Object { $allowedSharesForPublic -contains $_ } | Select-Object -First 1) {
            $isAllowed = $true
        }
    } else {
        $isAllowed = $true
    }

    # Case 3: Deny list logic.
    # If the deny list is defined, user must not have any assigned share that is on the list.
    $isDenied = $false
    if ($deniedSharesForPublic.Count -gt 0) {
        if ($uniqueUserShares | Where-Object { $deniedSharesForPublic -contains $_ } | Select-Object -First 1) {
            $isDenied = $true
        }
    }

    if ($isAllowed -and -not $isDenied) {
        $includePublic = $true
    }
}

if ($includePublic) {
    $requiredShareNames += "Public"
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: 'Public' share will be added for this user based on logical share rules."
} else {
    Write-Host "($(Get-Date -Format 'HH:mm:ss')) - DEBUG: 'Public' share will not be added for this user due to logical share restrictions."
}
$requiredShareNames = $requiredShareNames | Select-Object -Unique
$requiredUncPaths = @()
foreach ($shareName in $requiredShareNames) {
    if ($NetworkShares.ContainsKey($shareName)) {
        $paths = $NetworkShares[$shareName]
        if ($paths -is [array]) { $requiredUncPaths += $paths } else { $requiredUncPaths += $paths }
    }
}
$requiredUncPaths = $requiredUncPaths | Select-Object -Unique
Write-Output "Required UNC paths: $($requiredUncPaths -join ', ')"

# 6. Manage existing drives (unmapping)
# This section ensures that the user has the correct set of drives based on the required list,
# but ONLY for the drives this script is configured to manage. It will not touch other mapped drives.

# First, get a flat list of all UNC paths this script is configured to manage.
$allManageableUncPaths = @()
foreach($share in $NetworkShares.Values) {
    if ($share -is [array]) { $allManageableUncPaths += $share } else { $allManageableUncPaths += $share }
}
$allManageableUncPaths = $allManageableUncPaths | Select-Object -Unique

# Then, get all currently mapped drives.
$mappedDrives = Get-ChildItem -Path 'HKCU:\Network' -ErrorAction SilentlyContinue | ForEach-Object {
    [PSCustomObject]@{ DriveLetter = $_.PSChildName; RemotePath  = (Get-ItemProperty -Path $_.PSPath).RemotePath }
}

foreach ($drive in $mappedDrives) {
    # First, check if this drive is one that the script should manage.
    if ($allManageableUncPaths -contains $drive.RemotePath) {
        # This is a managed drive. Now check if the user should still have it, and that it's not excluded.
        if (($requiredUncPaths -notcontains $drive.RemotePath) -and ($ExcludedUncPaths -notcontains $drive.RemotePath)) {
            Write-Output "Removing managed drive '$($drive.DriveLetter)' mapped to '$($drive.RemotePath)' as it is no longer required for this user."
            Remove-PSDrive -Name $drive.DriveLetter -Force -ErrorAction SilentlyContinue
        }
    }
}

# 7. Map new drives
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
