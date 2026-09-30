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
PREFIXES=(
    "SIO-A"
    "SIO-B"
    "DEVOPS"
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

# fonction de validation du préfixe de pool
select_pool_prefix() {
    log "\n--- 1️⃣ Sélection du préfixe de pool ---"
    for i in "${!PREFIXES[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${PREFIXES[$i]}"
    done
    read -rp "Choisissez le numéro du préfixe de pool : " choice
    PREFIX="${PREFIXES[$((choice - 1))]}"
    if [[ -z "$PREFIX" ]]; then
        log_exit "Préfixe invalide. Abandon."
    fi
    log "Préfixe sélectionné : $PREFIX"
}

# fonction de recherche des VM et CT appartenant au pool
discover_targets() {
    log "--- 2️⃣ Découverte des pools Proxmox avec préfixe '$PREFIX' ---"

    POOLS=$(pvesh get /pools --output-format json \
            | jq -r --arg p "$PREFIX" '.[] | select(.poolid | startswith($p)) | .poolid')

    if [[ -z "$POOLS" ]]; then
        log_exit "Aucun pool trouvé avec le préfixe '$PREFIX'."
    fi
    log "Pools trouvés : $(echo "$POOLS" | tr '\n' ' ')"
	echo -n "  Scan des pools en cours, patientez"
    TARGETS=()
    for pool in $POOLS; do
        members=$(pvesh get "/pools/$pool" --output-format json \
                  | jq -r '.members[]?
                           | select(.vmid != null)
                           | select(.type == "qemu" or .type == "lxc")
                           | "\(.type):\(.vmid):\(.node):\(.name // "?")"')

        while IFS=: read -r type vmid node name; do
            [[ -z "$type" ]] && continue
            TARGETS+=("$type:$vmid:$node:$name")
            echo -n "."
        done <<< "$members"
    done
	echo ""

    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        log_exit "Aucune VM/CT trouvée dans les pools '$PREFIX*'."
    fi

    # Tri par VMID une fois pour toutes (utile pour l'affichage numéroté)
    mapfile -t TARGETS < <(printf '%s\n' "${TARGETS[@]}" | sort -t: -k2,2n)
}

# fonction d'affichage sous forme de tableau aligné (écran + log)
display_targets() {
    local sym="${1:- }"
    local t type vmid node name
    for t in "${TARGETS[@]}"; do
        IFS=: read -r type vmid node name <<< "$t"
        printf "  %s [%-4s] VMID=%-5s node=%-12s %-25s\n" \
               "$sym" "$type" "$vmid" "$node" "$name" | tee -a "$LOG"
    done
}

# Fonction d'exclusion et confirmation de suppression des ressource
exclude_targets() {
    log "\n--- 3️⃣ Liste des VMs/CTs détectés ---"
    display_targets "❔️"
    read -rp "Entrez les VMID à exclure ou [entrée] pour valider la sélection : " excl
	echo ""
	
    if [[ -n "$excl" ]]; then
        local NEW=() t type vmid node name keep ex
        for t in "${TARGETS[@]}"; do
            IFS=: read -r type vmid node name <<< "$t"
            keep=1
            for ex in $excl; do
                if [[ "$vmid" == "$ex" ]]; then
                	printf "  %s [%-4s] VMID=%-5s node=%-12s %-25s\n" \
                	               "➖️" "$type" "$vmid" "$node" "$name" | tee -a "$LOG"
                    #log "➖️ [$type] VMID=$vmid ($name)"
                    keep=""
                    break
                fi
            done
            [[ -n "$keep" ]] && NEW+=("$t")
        done
        TARGETS=("${NEW[@]}")
    fi

    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        log_exit "Toutes les VMs ont été exclues. Rien à supprimer."
    fi

    log "\n--- Liste finale des cibles ---"
    display_targets "➕️"

    read -rp "Confirmez-vous la suppression de ces ressources ? (oui/non) : " confirm
    [[ "$confirm" =~ ^[Oo]ui$ ]] || log_exit "Abandon demandé par l'utilisateur."
}

# Extraction de l'UPID depuis la sortie JSON de pvesh ("UPID:..." quoté)
extract_upid() {
    tr -d '"' | grep -m1 -o '^UPID:.*' || true
}

wait_task() {
    local upid="$1" node status running exitstatus tries=0
    node=$(printf '%s' "$upid" | cut -d: -f2)   # l'UPID contient le nœud

    while true; do
        status=$(pvesh get "/nodes/${node}/tasks/${upid}/status" \
                 --output-format json 2>/dev/null) || {
            sleep 2; tries=$((tries+1))
            (( tries > 30 )) && return 1
            continue
        }

        running=$(printf '%s' "$status" | jq -r '.data.running // ""')    || running=""
        exitstatus=$(printf '%s' "$status" | jq -r '.data.exitstatus // ""') || exitstatus=""

        if [[ "$running" == "1" ]]; then
            sleep 2; tries=$((tries+1))
            (( tries > 150 )) && return 1      # timeout ~5 min
            continue
        fi

        # Tâche terminée : on ne tranche QUE si exitstatus est réellement présent
        if [[ -n "$exitstatus" ]]; then
            [[ "$exitstatus" == "OK" ]] && return 0 || return 1
        fi

        # Statut pas encore disponible (tâche en cours d'enregistrement) → on patiente
        sleep 2; tries=$((tries+1))
        (( tries > 150 )) && return 1
    done
}

#Fonction d'arrêt forcé des VM sélectionnées

stop_local_vms() {
    log "--- 4️⃣ Arrêt forcé des VMs/CTs ---"

    local t type vmid node name status errfile upid tries
    for t in "${TARGETS[@]}"; do
        IFS=: read -r type vmid node name <<< "$t"

        # --- État actuel de la ressource ---
        status=$(pvesh get "/nodes/${node}/${type}/${vmid}/status/current" \
                 --output-format json 2>/dev/null \
                 | jq -r '.data.status // ""') || status=""

        if [[ "$status" != "running" ]]; then
            log "  ⏭️ $type/$vmid ($name) déjà à l'arrêt (état : ${status:-inconnu})"
            continue
        fi

        log "  🛑 Forçage de l'arrêt de $type/$vmid ($name) sur $node..."

        errfile=$(mktemp)
        upid=$(pvesh create "/nodes/${node}/${type}/${vmid}/status/stop" \
               --output-format json 2>"$errfile" | extract_upid) || true

        # Avertissements non fatals (ex : lock de backup en cours)
        if [[ -s "$errfile" ]]; then
            while IFS= read -r line; do
                log "  ⚠️  $line"
            done < "$errfile"
        fi
        rm -f "$errfile"

        if [[ -z "$upid" ]]; then
            log "  ❌ $type/$vmid ($name) : pas d'UPID — arrêt non lancé"
            continue
        fi

        if ! wait_task "$upid"; then
            log "  ❌ Tâche d'arrêt de $type/$vmid échouée — voir le log de tâche dans l'UI"
            continue
        fi

        # --- Validation de l'état 'stopped' (la tâche OK ne suffit pas toujours) ---
        tries=0
        while true; do
            status=$(pvesh get "/nodes/${node}/${type}/${vmid}/status/current" \
                     --output-format json 2>/dev/null \
                     | jq -r '.data.status // ""') || status=""
            [[ "$status" == "stopped" ]] && break
            sleep 2
            tries=$((tries+1))
            (( tries > 15 )) && break   # ~30 s max
        done

        if [[ "$status" == "stopped" ]]; then
            log "  ✅ $type/$vmid ($name) arrêté."
        else
            log "  ⚠️ $type/$vmid ($name) : état '${status:-inconnu}' après arrêt — suppression tentée quand même"
        fi
    done
}

# Fonction de suppression des VM et CT (possible seulement si arrêtés)
delete_local_vms() {
    log "--- 5️⃣ Suppression locale des VMs/CTs ---"

    local t type vmid node name st errfile upid
    for t in "${TARGETS[@]}"; do
        IFS=: read -r type vmid node name <<< "$t"
        log "  🗑️ Suppression de $type/$vmid ($name) sur $node..."

        # --- DÉBUT DU BLOC CORRIGÉ ---
        errfile=$(mktemp)
        upid=$(pvesh delete "/nodes/${node}/${type}/${vmid}" --purge 1 \
               --output-format json 2>"$errfile" | extract_upid) || true

        # Avertissements non fatals (ex : disques LVM déjà absents)
        if [[ -s "$errfile" ]]; then
            while IFS= read -r line; do
                log "  ⚠️  $line"
            done < "$errfile"
        fi
        rm -f "$errfile"

        if [[ -n "$upid" ]]; then
            if wait_task "$upid"; then
                log "  ✅ $type/$vmid ($name) supprimé."
            else
                log "  ❌ Tâche de suppression de $type/$vmid échouée — voir le log de tâche dans l'UI"
            fi
        else
            log "  ❌ $type/$vmid ($name) : pas d'UPID — suppression non lancée"
        fi
        # --- FIN DU BLOC CORRIGÉ ---

    done
}

#------------------------------ 5. SUPPRESSION BACKUPS LOCAUX -----------------
# Fonction de suppression des backups locaux (vzdump)
delete_local_backups() {
    log "\n--- 6️⃣ Suppression des backups vzdump locaux (option) ---"
    for t in "${TARGETS[@]}"; do
        IFS=':' read -r type vmid node name <<< "$t"
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
    log "\n--- 7️⃣ Suppression des backups sur PBS ---"
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
                IFS=':' read -r type vmid node name <<< "$t"
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

# Fonction de lancement (manuel ou auto, au choix) du garbage collector (nettoyage des chunks) 
run_garbage_collection() {
    log "\n--- 8️⃣ Garbage Collection PBS ---"
    log "ℹ️  La GC libère l'espace des chunks orphelins après suppression des backups."
    log "ℹ️  ⏱️  Selon la taille du datastore, elle peut durer de quelques minutes à plusieurs HEURES."
    log "ℹ️  Elle tourne en arrière-plan sur le serveur PBS : le script n'a pas besoin d'attendre."

    read -rp "Souhaitez-vous lancer maintenant la Garbage Collection ? (oui/non) : " rep
    if ! [[ "$rep" =~ ^[Oo]ui$ ]]; then
        log "↩️  GC non lancée."
        log "   Rappel manuel : proxmox-backup-manager garbage-collection start <datastore>"
        return 0
    fi

    local store http upid
    for store in "${PBS_DATASTORES[@]}"; do
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "  [DRY_RUN] POST ${BASE}/admin/datastore/${store}/garbage-collection"
            continue
        fi

        http=$(curl -sk -o /tmp/pbs_gc_${store}.json -w "%{http_code}" \
               -X POST -H "$AUTH" \
               "${BASE}/admin/datastore/${store}/garbage-collection")
        if [ "$http" != "200" ]; then
            log "  ❌ Impossible de lancer la GC sur '$store' (HTTP $http) :"
            log "     $(head -c 200 /tmp/pbs_gc_${store}.json)"
            continue
        fi

        upid=$(jq -r '.data' /tmp/pbs_gc_${store}.json)
        log "  🚀 GC lancée sur '$store' en arrière-plan."
        log "     Task UPID : $upid"
        log "     Suivi : interface PBS (Dashboard → Tasks) ou :"
        log "       curl -sk -H \"\$AUTH\" \"\${BASE}/nodes/${PBS_NODE}/tasks/${upid}/status\" | jq .data.status"
    done

    log "ℹ️  L'espace disque sera libéré progressivement pendant la GC."
    log "ℹ️  Vous pouvez fermer cette session sans risque : la tâche continue côté PBS."
}


#------------------------------ 7. MAIN ----------------------------------------
main() {
    select_pool_prefix
    discover_targets
    exclude_targets
    stop_local_vms
    delete_local_vms
    delete_local_backups
    delete_pbs_backups
    run_garbage_collection
    log "\n--- Nettoyage terminé ---"
}

main "$@"
