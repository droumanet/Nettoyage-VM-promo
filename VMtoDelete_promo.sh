#!/bin/bash
#===============================================================================
# proxmox_cleanup.sh
# Nettoyage complet et modulaire Proxmox VE + PBS (v4.1.6)
# - Sélection interactive des pools, exclusions, confirmation
# - Suppression VMs/CTs locales (stop + destroy --purge)
# - Suppression backups vzdump locaux
# - Suppression backups PBS (API officielle)
#===============================================================================

set -Eeuo pipefail

#------------------------------ 0. CONFIGURATION -------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/pbs.conf"

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "Configuration introuvable : $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

for variable in PBS_HOST PBS_USER PBS_TOKEN_ID PBS_TOKEN_SECRET PBS_NODE LOG; do
    if [[ -z "${!variable:-}" ]]; then
        echo "Variable obligatoire absente : $variable" >&2
        exit 1
    fi
done

# Gestion des tableaux
if [[ ${#PBS_DATASTORES[@]} -eq 0 ]]; then
    echo "PBS_DATASTORES est vide" >&2
    exit 1
fi
if [[ ${#PBS_NAMESPACES[@]} -eq 0 ]]; then
    echo "PBS_NAMESPACES est vide" >&2
    exit 1
fi

DRY_RUN=${DRY_RUN:-1}

# Liste des préfixes pour les pools
declare -A PREFIXES=(
  [1]="SIO-A"
  [2]="SIO-B"
  [3]="DEVOPS"
)

# fonctions d'enregistrement dans le fichier log
log() { echo -e "$1" | tee -a "$LOG"; }
log_exit() {
    # Usage : log_exit "message d'erreur" [code_sortie]
    log "🛑 $1"
    log "=== (ARRÊT DU SCRIPT — $(date '+%F %T')) ==="
    log ""
    exit "${2:-1}"   # code de sortie 1 par défaut, personnalisable
}

# fonction d'attente d'arrêt d'une VM avant suppression
wait_task() {
    local node="$1" upid="$2"
    for i in $(seq 1 60); do
        status=$(pvesh get /nodes/${node}/tasks/${upid}/status --output-format json 2>/dev/null | jq -r '.status // "unknown"')
        [[ "$status" == "stopped" ]] && return 0
        sleep 2
    done
    return 1
}

# fonction de validation du préfixe de pool
select_pool_prefix() {
    log "\n--- 1️⃣ Sélection du préfixe de pool ---"
    for i in "${!PREFIXES[@]}"; do
        echo "  $i) ${PREFIXES[$i]}"
    done
    read -rp "Choisissez le numéro du préfixe de pool : " choice
    PREFIX="${PREFIXES[$choice]}"
    if [[ -z "$PREFIX" ]]; then
        log_exit "Préfixe invalide. Abandon."
    fi
    log "Préfixe sélectionné : $PREFIX"
}

# fonction de recherche des VM et CT appartenant au pool
discover_targets() {
    log "\n--- 2️⃣ Découverte des pools Proxmox avec préfixe '$PREFIX' ---"
    POOLS=$(pvesh get /pools --output-format json | jq -r ".[] | select(.poolid | test(\"^${PREFIX}\")) | .poolid")
    if [[ -z "$POOLS" ]]; then
        log_exit "Aucun pool trouvé avec le préfixe '$PREFIX'."
    fi
    TARGETS=()
    for pool in $POOLS; do
        members=$(pvesh get /pools/$pool --output-format json | jq -r '.members[] | "\(.type):\(.vmid):\(.node)"')
        for m in $members; do
            TARGETS+=("$m")
        done
    done
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        log_exit "Aucune VM/CT trouvée dans les pools sélectionnés."
    fi
}

# fonction d'affichage sous forme de tableau aligné (écran + log)
display_targets() {
    local sym="${1:- }"          # symbole passé en argument, espace par défaut
    local i=0 k node type vmid
    for k in $(printf '%s\n' "${!TARGETS[@]}" | sort -t: -k3 -n); do
        IFS=: read -r node type vmid <<< "$k"
        ((i++))
        printf "  %s %3d) [%-4s] VMID=%-5s node=%-25s %s\n" \
               "$sym" "$i" "$type" "$vmid" "$node" "${TARGETS[$k]}" | tee -a "$LOG"
    done
}

# Fonction d'exclusion et confirmation de suppression des ressource
exclude_targets() {
    log "\n--- 3️⃣ Liste des VMs/CTs détectés ---"
    display_targets "❔️"
    read -rp "Entrez les numéros à exclure (séparés par des espaces, ou rien pour tout garder) : " excl

    # suppression des VMID de la table TARGETS
    if [[ -n "$excl" ]]; then
        for idx in $excl; do
            unset 'TARGETS[idx]'
        done
        TARGETS=("${TARGETS[@]}") # Réindexation
    fi
    log "\n--- Liste finale des cibles ---"
    display_targets "➕️"
    for t in "${TARGETS[@]}"; do
        IFS=':' read -r type vmid node <<< "$t"
        echo "  [$type] VMID=$vmid sur $node"
    done
    read -rp "Confirmez-vous la suppression de ces ressources ? (oui/non) : " confirm
    [[ "$confirm" =~ ^[Oo]ui$ ]] || { log "Abandon."; exit 1; }
}

# Fonction de demande d'arrêt et suppression des VM et CT
delete_local_vms() {
    log "\n--- 4️⃣ Suppression locale des VMs/CTs ---"
    for t in "${TARGETS[@]}"; do
        IFS=':' read -r type vmid node <<< "$t"
        if [[ "$type" != "qemu" && "$type" != "lxc" ]]; then
            log "Type inconnu : $type (VMID $vmid) -- ignoré."
            continue
        fi
        log "Traitement [$type] VMID=$vmid sur $node"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "  [DRY_RUN] Arrêt VM/CT : pvesh post /nodes/$node/$type/$vmid/status/stop"
            log "  [DRY_RUN] Suppression VM/CT : pvesh delete /nodes/$node/$type/$vmid --purge 1"
        else
            upid=$(pvesh post /nodes/$node/$type/$vmid/status/stop --output-format json | jq -r '.data')
            wait_task "$node" "$upid" || log "  ⚠️  Timeout à l'arrêt VMID $vmid"
            upid=$(pvesh delete /nodes/$node/$type/$vmid --purge 1 --output-format json | jq -r '.data')
            wait_task "$node" "$upid" || log "  ⚠️  Timeout à la suppression VMID $vmid"
            log "  ✅ VMID $vmid supprimé."
        fi
    done
}

#------------------------------ 5. SUPPRESSION BACKUPS LOCAUX -----------------
# Fonction de suppression des backups locaux (vzdump)
delete_local_backups() {
    log "\n--- 5️⃣ Suppression des backups vzdump locaux ---"
    for t in "${TARGETS[@]}"; do
        IFS=':' read -r type vmid node <<< "$t"
        for store in $(pvesh get /nodes/$node/storage --output-format json | jq -r '.[] | select(.content | test("backup")) | .storage'); do
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "  [DRY_RUN] Recherche et suppression des backups VMID $vmid sur $store"
            else
                # Suppression des fichiers vzdump pour VMID
                ssh "$node" "find /var/lib/vz/dump -name '*${vmid}*' -delete"
                log "  ✅ Backups locaux VMID $vmid supprimés sur $store"
            fi
        done
    done
}

# Fonction de suppression des backups sur le serveur PBS (en utilisant l'API)
delete_pbs_backups() {
    log "\n--- 6️⃣ Suppression des backups sur PBS ---"
    AUTH="Authorization: PBSAPIToken=${PBS_USER}!${PBS_TOKEN_ID}:${PBS_TOKEN_SECRET}"
    BASE="https://${PBS_HOST}/api2/json"
    DELETED=0
    ERRORS=0
    for PBS_DATASTORE in "${PBS_DATASTORES[@]}"; do
        for ns in "${PBS_NAMESPACES[@]}"; do
            log "Datastore $PBS_DATASTORE / namespace $ns"
            groups=$(curl -sk -H "$AUTH" \
                "${BASE}/admin/datastore/${PBS_DATASTORE}/groups?ns=${ns}" \
                | jq -r '.data[]? | "\(.["backup-type"] // ""):\(.["backup-id"] // "")"' \
                | grep -v '^:')
            for t in "${TARGETS[@]}"; do
                IFS=':' read -r type vmid node <<< "$t"
                for gtype in vm ct; do
                    group="${gtype}:${vmid}"
                    if echo "$groups" | grep -q "^${group}$"; then
                        if [[ "$DRY_RUN" -eq 1 ]]; then
                            log "  [DRY_RUN] Suppression PBS $gtype/$vmid dans $ns"
                        else
                            http=$(curl -sk -o /tmp/pbs_del_${ns}_${gtype}_${vmid}.json \
                                -w "%{http_code}" \
                                -X DELETE \
                                -H "$AUTH" \
                                "${BASE}/admin/datastore/${PBS_DATASTORE}/groups?backup-type=${gtype}&backup-id=${vmid}&ns=${ns}")
                            if [ "$http" = "200" ]; then
                                log "    ✅ Supprimé $gtype/$vmid dans $ns"
                                ((DELETED++))
                            else
                                log "    ❌ Erreur HTTP $http pour $gtype/$vmid dans $ns"
                                cat /tmp/pbs_del_${ns}_${gtype}_${vmid}.json
                                ((ERRORS++))
                            fi
                        fi
                    else
                        log "  ➖ Groupe $gtype/$vmid absent dans $ns"
                    fi
                done
            done
        done
    done
    log "\nRésultat PBS : Groupes supprimés : $DELETED | Erreurs : $ERRORS"
    log "Pour libérer l'espace disque, lancez : proxmox-backup-manager garbage-collection start <datastore>"
}

#------------------------------ 7. MAIN ----------------------------------------
main() {
    select_pool_prefix
    discover_targets
    exclude_targets
    delete_local_vms
    delete_local_backups
    delete_pbs_backups
    log "\n--- Nettoyage terminé ---"
}

main "$@"
