#Final Version 10/06/2025
# Authentification Entra ID (via App Registration)
$tenantId = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
$clientId = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
$clientSecret = "XXXXXXXXXXXXXXXXXXXXXXXXXXX"
$resource = "https://graph.microsoft.com/"
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

$localUser = whoami
$localUserName = $localUser.Split('\')[-1]
$localUserEmail = "$localUserName@DOMAIN.com"

$userResponse = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$localUserEmail" -Headers $headers -Method Get
$UserId = $userResponse.id

$groupsUri = "https://graph.microsoft.com/v1.0/users/$UserId/transitiveMemberOf/microsoft.graph.group?`$count=true&`$filter=startswith(displayName, 'AZURE/AD_GROUPS') or startswith(displayName, 'ASYOUWANT')&`$top=999"

$groups = Invoke-RestMethod -Uri $groupsUri -Headers $headers -Method Get
$groupNames = $groups.value | Where-Object { $_.displayName -like "AZURE/AD_GROUPS*" -or $_.displayName -eq "AZURE/AD_GROUPS*" } | ForEach-Object { $_.displayName }

$DriveMappings = @{
    "AZURE/AD_GROUPS*_R1"                  = "Names1"
    "AZURE/AD_GROUPS*_RW1"                 = "Names1"
    "AZURE/AD_GROUPS*_R2"                  = "Names2"
    "AZURE/AD_GROUPS*_RW2"                 = "Names2"
    "AZURE/AD_GROUPS*_RW_DIRECTION"        = "DIRECTION"
    "AZURE/AD_GROUPS*_R_DIRECTION"         = "DIRECTION"

}

$NetworkShares = @{
    "Names1"                        = "\\SERVEUR\PATH"
    "Names2" = @( 
	"\\SERVEUR\PATH2",
	"\\SERVEUR\PATH3"
	)
}

function Get-AvailableDriveLetter {
    $reservedForDevices = @("A", "B", "C", "D")


    $usedBySystem = (Get-CimInstance -ClassName Win32_LogicalDisk | Select-Object -ExpandProperty DeviceID) `
                    | ForEach-Object { $_.TrimEnd(":") }


    $usedInRegistry = @()
    try {
        $usedInRegistry = Get-ChildItem -Path "HKCU:\Network" | Select-Object -ExpandProperty PSChildName
    } catch {
        # Rien à faire si la clé n'existe pas encore
    }

    $usedLetters = $usedBySystem + $usedInRegistry + $reservedForDevices
    $usedLetters = $usedLetters | Select-Object -Unique

    $allLetters = [char[]](67..90 | ForEach-Object { [char]$_ }) # C à Z
    return $allLetters | Where-Object { $_ -notin $usedLetters } | Select-Object -First 1
}




$groupsToMount = @()

if ($groupNames -contains 'AZURE/AD_GROUPS*_R_DIRECTION' -or $groupNames -contains 'AZURE/AD_GROUPS*_RW_DIRECTION') {
    $groupsToMount += $NetworkShares.Keys | Where-Object { $_ -ne 'EXCLUDED_GROUPS' }
}
else {
    # Mapping standard
    $groupsToMount = $groupNames |
        ForEach-Object { $DriveMappings[$_] } |
        Where-Object { $_ } |
        Select-Object -Unique
}


if (-not ($groupNames -contains 'EXCLUDED_GROUPS') -and -not ($groupsToMount -contains 'PUBLIC')) {
    $groupsToMount += 'PUBLIC'
}


$allowedShares = @()
foreach ($group in $groupsToMount) {
    if ($NetworkShares.ContainsKey($group)) {
        $paths = $NetworkShares[$group]
        if ($paths -is [array]) {
            foreach ($p in $paths) {
                if ($p -notin $allowedShares) {
                    $allowedShares += $p
                }
            }
        }
        elseif ($paths -notin $allowedShares) {
            $allowedShares += $paths
        }
    }
}


$mountedDrivesReg = Get-ChildItem -Path 'HKCU:\Network' | ForEach-Object {
    $drive = $_.PSChildName
    $remotePath = (Get-ItemProperty -Path $_.PsPath).RemotePath
    [PSCustomObject]@{ DriveLetter = $drive; RemotePath = $remotePath }
}

$usedPaths = @{}
foreach ($entry in $mountedDrivesReg) {
    if ($allowedShares -notcontains $entry.RemotePath) {
        Remove-PSDrive -Name $entry.DriveLetter -Force -ErrorAction SilentlyContinue
    }
    else {
        $usedPaths[$entry.RemotePath] = $entry.DriveLetter
    }
}


function Get-AvailableDriveLetter {
    $reserved = @('A','B','C','D')
    $usedBySystem = Get-CimInstance Win32_LogicalDisk | Select-Object -Expand DeviceID | ForEach-Object { $_.TrimEnd(':') }
    $usedInReg = Get-ChildItem HKCU:\Network -ErrorAction SilentlyContinue | Select-Object -Expand PSChildName
    $used = $reserved + $usedBySystem + $usedInReg | Select-Object -Unique
    $all = [char[]](67..90 | ForEach-Object {[char]$_})
    return $all | Where-Object { $_ -notin $used } | Select-Object -First 1
}

$currentDrives = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 4 } | Select-Object -Expand ProviderName

foreach ($path in $allowedShares) {
    if ($currentDrives -contains $path) { continue }
    $letter = Get-AvailableDriveLetter
    if ($letter) {
        New-PSDrive -Name $letter -PSProvider FileSystem -Root $path -Persist -ErrorAction SilentlyContinue | Out-Null
    }
}
