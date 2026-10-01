#!/bin/bash
#===============================================================================
# proxmox_cleanup.sh        v2.0
# Nettoyage complet et modulaire Proxmox VE + PBS (v4.1.6)
# - Sélection interactive des pools, exclusions, confirmation
# - Suppression backups vzdump locaux
# - Suppression backups PBS (API officielle)
# - Suppression VMs/CTs locales (stop + destroy --purge)
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

# Variables construites pour appels API dans remove_pbs_backup et run_garbage_collection
AUTH="Authorization: PBSAPIToken=${PBS_USER}!${PBS_TOKEN_ID}:${PBS_TOKEN_SECRET}"
BASE="https://${PBS_HOST}/api2/json"

# fonctions d'enregistrement dans le fichier log
log() { echo -e "$1" | tee -a "$LOG"; }
log_exit() {
    # Usage : log_exit "message d'erreur" [code_sortie]
    log "💣️ $1"
    log "=== 🛑 (ARRÊT DU SCRIPT — $(date '+%F %T')) 🛑 ==="
    log ""
    exit "${2:-1}"   # code de sortie 1 par défaut, personnalisable
}

# fonction de validation du préfixe de pool
select_pool_prefix() {
    log "\n 1️⃣ Sélection du préfixe de pool ---"
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

# 2 : fonction de recherche des VM et CT appartenant au pool
discover_targets() {
    log " 2️⃣ Découverte des pools Proxmox avec préfixe '$PREFIX' ---"

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

# 3 : Fonction d'exclusion et confirmation de suppression des ressource
exclude_targets() {
    log "\n 3️⃣ Liste des VMs/CTs détectés ---"
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
    local raw u
    raw=$(cat)

    # Cas 1 : JSON ({"data":"UPID:..."} ou "UPID:..." nu)
    u=$(printf '%s' "$raw" | jq -r '
            if type=="object" then (.data // "")
            elif type=="string" then .
            else "" end' 2>/dev/null) || u=""

    # Cas 2 : texte brut ou JSON non parsable
    if [[ "$u" != UPID:* ]]; then
        u=$(printf '%s' "$raw" | tr -d '"' | grep -m1 -o 'UPID:[^ ,}]*') || u=""
    fi

    [[ "$u" == UPID:* ]] && printf '%s' "$u"
    return 0
}

wait_task() {
    local upid="$1" node status running exitstatus tries=0
    [[ -z "$upid" ]] && return 1 # cas upid vide

    node=$(printf '%s' "$upid" | cut -d: -f2)   # l'UPID contient le nœud

    while true; do
        status=$(pvesh get "/nodes/${node}/tasks/${upid}/status" \
                 --output-format json 2>/dev/null) || {
            sleep 2; tries=$((tries+1))
            (( tries > 30 )) && return 1
            continue
        }

        running=$(printf '%s' "$status"    | jq -r '.running    // .data.running    // ""' 2>/dev/null) || running=""
        exitstatus=$(printf '%s' "$status" | jq -r '.exitstatus // .data.exitstatus // ""' 2>/dev/null) || exitstatus=""

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

# 4 : Fonction d'arrêt forcé des VM sélectionnées
stop_local_vms() {
    log " 4️⃣ Arrêt forcé des VMs/CTs ---"

    local t type vmid node name status errfile upid tries
    local -a stop_args
    for t in "${TARGETS[@]}"; do
        IFS=: read -r type vmid node name <<< "$t"

        # --- État actuel de la ressource ---
        status=$(pvesh get "/nodes/${node}/${type}/${vmid}/status/current" \
                 --output-format json 2>/dev/null \
                 | jq -r '.status // .data.status // ""') || status=""

        if [[ "$status" != "running" ]]; then
            log "  ⏭️ $type/$vmid ($name) déjà à l'arrêt (état : ${status:-inconnu})"
            continue
        fi

        log "  🛑 Forçage de l'arrêt de $type/$vmid ($name) sur $node..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "     [DRY_RUN] pvesh create /nodes/${node}/${type}/${vmid}/status/stop --overrule-shutdown 1"
            continue
        fi

        # --- Construction des arguments selon le type ---
        stop_args=( --overrule-shutdown 1 --timeout 30 )
        if [[ "$type" == "qemu" ]]; then
            stop_args+=( --skiplock 1 )   # root@pam requis, QEMU seulement
        fi

        errfile=$(mktemp)
        upid=$(pvesh create "/nodes/${node}/${type}/${vmid}/status/stop" \
               "${stop_args[@]}" --output-format json 2>"$errfile" | extract_upid) || true

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
                     | jq -r '.status // .data.status // ""') || status=""
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

# 5 : Fonction d'effacement des backups locaux (vzdump)
remove_local_backups() {
    log "\n 5️⃣ Suppression des backups vzdump locaux ---"
    local t type vmid node name store path json

    for t in "${TARGETS[@]}"; do
        IFS=':' read -r type vmid node name <<< "$t"

        # Ne garder que les stockages RÉELLEMENT locaux (dir/nfs/cifs)
        json=$(pvesh get "/nodes/${node}/storage" --output-format json 2>/dev/null) || json="[]"
        while IFS=$'\t' read -r store path; do
            [[ -z "$store" ]] && continue
            path="${path:-/var/lib/vz}"

            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "  [DRY_RUN] find ${path}/dump -name 'vzdump-*-${vmid}-*' sur ${node} (store: ${store})"
                continue
            fi

            ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
                -o ConnectTimeout=5 "root@${node}" \
                "find '${path}/dump' -maxdepth 1 -name 'vzdump-*-${vmid}-*' -print -delete" \
                2>/dev/null \
                && log "  ✅ Backups VMID ${vmid} nettoyés sur ${store} (${path}/dump)" \
                || log "  ⚠️  Échec ou aucun backup VMID ${vmid} sur ${store}"
        done < <(printf '%s' "$json" | jq -r '
            .[] | select((.content // "") | test("backup"))
                | select((.type // "") | test("^(dir|nfs|cifs|glusterfs)$"))
                | "\(.storage)\t\(.path // "")"')
    done
}

# 6 : Fonction de suppression des backups sur le serveur PBS (en utilisant l'API)
remove_pbs_backups() {
    log "\n 6️⃣ Suppression des backups sur PBS ---"
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
                                DELETED=$((DELETED + 1))
                            else
                                log "    ❌ Erreur HTTP $http pour $gtype/$vmid dans $ns"
                                cat /tmp/pbs_del_${ns}_${gtype}_${vmid}.json
                                ERRORS=$((ERRORS + 1))
                            fi
                        fi
                    else
                        log "    ➖ Groupe $gtype/$vmid absent dans $ns"
                    fi
                done
            done
        done
    done
    log "\nRésultat PBS : Groupes supprimés : $DELETED | Erreurs : $ERRORS"
}

# Fonction de suppression des VM et CT (possible seulement si arrêtés)
delete_local_vms() {
    log " 7️⃣ Suppression locale des VMs/CTs ---"

    local t type vmid node name errfile raw upid rc lk lockfile
    for t in "${TARGETS[@]}"; do
        IFS=: read -r type vmid node name <<< "$t"
        log "  🗑️ Suppression de $type/$vmid ($name) sur $node..."

        # --- 0. Mode simulation ---
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "     [DRY_RUN] pvesh delete /nodes/${node}/${type}/${vmid} --purge 1"
            continue
        fi

        # --- 1. La ressource existe-t-elle encore ? ---
        if ! pvesh get "/nodes/${node}/${type}/${vmid}/status/current" \
             --output-format json >/dev/null 2>&1; then
            log "     ➖ Introuvable sur $node — probablement déjà supprimée"
            continue
        fi

        # --- 2. Verrou résiduel bloquant ? ---
        lk=$(pvesh get "/nodes/${node}/${type}/${vmid}/status/current" \
             --output-format json 2>/dev/null \
             | jq -r '.lock // .data.lock // ""' 2>/dev/null) || lk=""
        if [[ -n "$lk" ]]; then
            log "     🔒 Verrou actif (lock: $lk) — tentative de levée"
            lockfile="/var/lock/qemu-server/lock-${vmid}.conf"
            [[ "$type" == "lxc" ]] && lockfile="/run/lock/lxc/pve-config-${vmid}.lock"
            if ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
                   -o ConnectTimeout=5 "root@$node" "rm -f '$lockfile'" 2>/dev/null; then
                log "     🔓 Fichier de verrou retiré"
            else
                log "     ⚠️  Impossible de retirer le verrou (SSH ou permission)"
            fi
        fi

        # --- 3. Suppression via l'API ---
        errfile=$(mktemp)
        raw=$(pvesh delete "/nodes/${node}/${type}/${vmid}" \
              --purge 1 --destroy-unreferenced-disks 1 \
              --output-format json 2>"$errfile") && rc=0 || rc=$?
        upid=$(printf '%s' "$raw" | extract_upid)

        # --- 4. Diagnostic si aucun UPID ---
        if [[ -z "$upid" ]]; then
            log "     ❌ Pas d'UPID (code pvesh = $rc)"
            [[ -n "$raw" ]] && log "        Sortie : $(printf '%s' "$raw" | head -c 300)"
            if [[ -s "$errfile" ]]; then
                while IFS= read -r l; do log "        ⚠️  $l"; done < "$errfile"
            else
                log "        (stderr vide — sortie probablement mal parsée)"
            fi
            rm -f "$errfile"
            continue
        fi
        rm -f "$errfile"

        # --- 5. Attente de la fin de tâche ---
        if wait_task "$upid"; then
            log "     ✅ $type/$vmid ($name) supprimé."
        else
            log "     ❌ Tâche échouée — UPID : $upid"
            log "        Log : pvesh get /nodes/${node}/tasks/${upid}/log"
        fi
    done
}

# 8 : Fonction de lancement (manuel ou auto, au choix) du garbage collector (nettoyage des chunks) 
run_garbage_collection() {
    log "\n 8️⃣ Garbage Collection PBS ---"
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
               "${BASE}/nodes/${PBS_NODE}/datastore/${store}/gc")
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

#------------------------------ 9. MAIN ----------------------------------------
# Note : l'ordre des op. est important. Suppr. d'abord les backups avant les
#        VM pour éviter d'avoir des backups orphelins (plus de références)
main() {
    select_pool_prefix
    discover_targets
    exclude_targets
    stop_local_vms
    remove_local_backups
    remove_pbs_backups
    delete_local_vms
    run_garbage_collection
    log "\n--- Nettoyage terminé ---"
}

main "$@"
