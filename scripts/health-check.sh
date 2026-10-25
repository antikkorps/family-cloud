#!/bin/bash
# ===========================================
# Script de Health Check Family Cloud
# ===========================================
# Usage: ./health-check.sh
#
# Genere logs/status.json avec l'etat des services
# (chemin surchargeable via la variable STATUS_FILE).
# A executer via cron toutes les 5 minutes :
# */5 * * * * /path/to/health-check.sh
# ===========================================

set -euo pipefail

# ===========================================
# Configuration
# ===========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATUS_FILE="${STATUS_FILE:-${PROJECT_DIR}/logs/status.json}"
BACKUP_LOG_DIR="${PROJECT_DIR}/backups"

# Services surveilles, format "conteneur|Libelle|critique"
# critique = oui : le statut global passe en "degraded" si le service tombe
SERVICES=(
    "immich-server|Immich server|oui"
    "immich-ml|Immich ML|non"
    "immich-postgres|Immich PostgreSQL|oui"
    "immich-redis|Immich Redis|non"
    "seafile|Seafile|oui"
    "seafile-mariadb|Seafile MariaDB|oui"
    "seafile-memcached|Seafile Memcached|non"
    "vaultwarden|Vaultwarden|oui"
    "paperless|Paperless|oui"
    "paperless-redis|Paperless Redis|non"
    "homepage|Homepage|oui"
    "jellyfin|Jellyfin|oui"
    "audiobookshelf|Audiobookshelf|oui"
    "memos|Memos|oui"
    "linkwarden|Linkwarden|oui"
    "linkwarden-postgres|Linkwarden PostgreSQL|oui"
    "linkwarden-meilisearch|Linkwarden Meilisearch|non"
    "family-caddy|Caddy|oui"
    "family-cloudflared|Cloudflared|oui"
)

# ===========================================
# Fonctions
# ===========================================

check_service() {
    local container_name="$1"
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        local health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || echo "none")
        if [[ "$health" == "healthy" ]] || [[ "$health" == "none" ]]; then
            echo "ok"
        else
            echo "unhealthy"
        fi
    else
        echo "down"
    fi
}

get_disk_usage() {
    local path="${1:-/}"
    df -h "$path" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "0"
}

get_last_backup() {
    local latest_log=$(ls -t "${BACKUP_LOG_DIR}"/backup_*.log 2>/dev/null | head -1)
    if [[ -n "$latest_log" && -f "$latest_log" ]]; then
        local timestamp=$(basename "$latest_log" | sed 's/backup_\(.*\)\.log/\1/')
        if grep -q "Backup termine avec succes" "$latest_log" 2>/dev/null; then
            echo "$timestamp"
        else
            echo "failed:$timestamp"
        fi
    else
        echo "never"
    fi
}

get_memory_usage() {
    free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}'
}

get_load_average() {
    cat /proc/loadavg | awk '{print $1}'
}

# ===========================================
# Script principal
# ===========================================

main() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local overall="ok"
    local alert_list=()
    local service_list=()

    # Verifier les services
    local entry name label critical state
    for entry in "${SERVICES[@]}"; do
        IFS='|' read -r name label critical <<< "$entry"
        state=$(check_service "$name")
        service_list+=("    \"${name}\": \"${state}\"")
        if [[ "$state" != "ok" ]]; then
            alert_list+=("\"${label} is ${state}\"")
            if [[ "$critical" == "oui" ]]; then
                overall="degraded"
            fi
        fi
    done

    # Metriques systeme
    local disk_root=$(get_disk_usage "/")
    local memory_usage=$(get_memory_usage)
    local load_avg=$(get_load_average)

    # Dernier backup
    local last_backup=$(get_last_backup)

    # Alertes
    if [[ "$disk_root" -gt 90 ]]; then
        alert_list+=("\"Disk usage critical: ${disk_root}%\"")
        overall="critical"
    elif [[ "$disk_root" -gt 80 ]]; then
        alert_list+=("\"Disk usage warning: ${disk_root}%\"")
    fi
    if [[ "$last_backup" == "never" ]]; then
        alert_list+=("\"No backup found\"")
    elif [[ "$last_backup" == failed:* ]]; then
        alert_list+=("\"Last backup failed\"")
    fi

    local alerts="[]"
    if [[ ${#alert_list[@]} -gt 0 ]]; then
        alerts=$(printf '%s\n' "${alert_list[@]}" | paste -sd ',' -)
        alerts="[${alerts}]"
    fi
    local services=$(printf '%s,\n' "${service_list[@]}")
    services="${services%,}"

    # Generer le JSON
    mkdir -p "$(dirname "$STATUS_FILE")"
    cat > "$STATUS_FILE" << EOF
{
  "timestamp": "${timestamp}",
  "status": "${overall}",
  "services": {
${services}
  },
  "metrics": {
    "disk_root_percent": ${disk_root},
    "memory_percent": ${memory_usage},
    "load_average": ${load_avg}
  },
  "backup": {
    "last": "${last_backup}"
  },
  "alerts": ${alerts}
}
EOF

    cat "$STATUS_FILE"

    case "$overall" in
        "ok") exit 0 ;;
        "degraded") exit 1 ;;
        "critical") exit 2 ;;
        *) exit 3 ;;
    esac
}

main "$@"
