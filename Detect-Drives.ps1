# Liste des partages réseau à vérifier
$NetworkShares = @{
    "Names1" = "\\SERVEUR\PATH"
    "Names2" = @(
 "\\SERVEUR\PATH2",
 "\\SERVEUR\PATH3"
)
}

# Récupère les partages réseau actuellement mappés
try {
    $MappedShares = Get-WmiObject -Class Win32_NetworkConnection -ErrorAction Stop | Select-Object -ExpandProperty RemoteName
} catch {
    Write-Output "Erreur lors de la récupération des connexions réseau."
    exit 1
}

# Aplatissement de toutes les valeurs (simple ou tableau) dans une seule liste
$AllTargetShares = foreach ($entry in $NetworkShares.GetEnumerator()) {
    if ($entry.Value -is [Array]) {
        $entry.Value
    } else {
        $entry.Value
    }
}

# Comparaison avec les connexions actives
foreach ($share in $AllTargetShares) {
    if ($MappedShares -contains $share) {
        Write-Output "Détection réussie : $share est monté."
        exit 0
    }
}

Write-Output "Aucun lecteur réseau requis n'est monté."
exit 1
