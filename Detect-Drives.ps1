# Paramètres d’authentification Graph API
$tenantId = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
$clientId = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
$clientSecret = "XXXXXXXXXXXXXXXXXXXXXXXXXXX"
$tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

$response = Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType "application/x-www-form-urlencoded" -Body @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = "https://graph.microsoft.com/.default"
}
$token = $response.access_token

$headers = @{
    Authorization     = "Bearer $token"
    Consistencylevel  = "eventual"
}

# Identité de l'utilisateur connecté
$localUser = whoami
$localUserName = $localUser.Split('\')[-1]
$localUserEmail = "$localUserName@DOMAIN.com"

# Récupération de l'ID utilisateur
$userResponse = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$localUserEmail" -Headers $headers -Method Get
$UserId = $userResponse.id

# Récupération des groupes
$groupsUri = "https://graph.microsoft.com/v1.0/users/$UserId/transitiveMemberOf/microsoft.graph.group?`$count=true&`$filter=startswith(displayName, 'AZURE/AD_GROUPS*') or startswith(displayName, 'ASYOUWANT')&`$top=999"
$groups = Invoke-RestMethod -Uri $groupsUri -Headers $headers -Method Get
$groupNames = $groups.value | ForEach-Object { $_.displayName }

# Dictionnaires de mappage
$DriveMappings = @{
    "AZURE/AD_GROUPS*_R1"                  = "Names1"
    "AZURE/AD_GROUPS*_RW1"                 = "Names1"
    "AZURE/AD_GROUPS*_R2"                  = "Names2"
    "AZURE/AD_GROUPS*_RW2"                 = "Names2"
    "AZURE/AD_GROUPS*_RW_DIRECTION"        = "DIRECTION"
    "AZURE/AD_GROUPS*_R_DIRECTION"         = "DIRECTION"
}
$NetworkShares = @{
    "Names1" = "\\SERVEUR\PATH"
    "Names2" = @(
 "\\SERVEUR\PATH2",
 "\\SERVEUR\PATH3"
)
}

# Détermination des lecteurs à monter
$groupsToMount = @()

if ($groupNames -contains 'AZURE/AD_GROUPS*_R_DIRECTION' -or $groupNames -contains 'AZURE/AD_GROUPS*_RW_DIRECTION') {
    $groupsToMount += $NetworkShares.Keys | Where-Object { $_ -ne 'EXCLUDED_GROUPS' }
} else {
    $groupsToMount = $groupNames |
        ForEach-Object { $DriveMappings[$_] } |
        Where-Object { $_ } |
        Select-Object -Unique
}
if (-not ($groupNames -contains 'EXCLUDED_GROUPS') -and -not ($groupsToMount -contains 'PUBLIC')) {
    $groupsToMount += 'PUBLIC'
}

# Récupération des chemins réseau attendus
$expectedShares = @()
foreach ($group in $groupsToMount) {
    if ($NetworkShares.ContainsKey($group)) {
        $paths = $NetworkShares[$group]
        if ($paths -is [array]) {
            $expectedShares += $paths
        } else {
            $expectedShares += $paths
        }
    }
}

# Vérification des lecteurs réseau montés
$currentDrives = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 4 } | Select-Object -ExpandProperty ProviderName

$missingShare = $false
foreach ($share in $expectedShares) {
    if ($currentDrives -notcontains $share) {
        $missingShare = $true
        break
    }
}

if ($missingShare) {
    exit 1  # Non conforme
} else {
    exit 0  # Conforme
}
