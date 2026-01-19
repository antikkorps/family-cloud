#!/bin/bash
# ===========================================
# Script de Health Check Nextcloud
# ===========================================
# Usage: ./health-check.sh
#
# Génère un fichier status.json avec l'état des services.
# À exécuter via cron toutes les 5 minutes :
# */5 * * * * /path/to/health-check.sh
#
# Le fichier peut être lu par un serveur distant pour monitoring.
# ===========================================

set -euo pipefail

# ===========================================
# Configuration
# ===========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATUS_FILE="/var/log/nextcloud-status.json"
BACKUP_LOG_DIR="${PROJECT_DIR}/backups"

# ===========================================
# Fonctions
# ===========================================

# Vérifier un service Docker
check_service() {
    local container_name="$1"
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        # Vérifier le healthcheck si disponible
        local health=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")
        if [[ "$health" == "healthy" ]] || [[ "$health" == "none" ]]; then
            echo "ok"
        else
            echo "unhealthy"
        fi
    else
        echo "down"
    fi
}

# Obtenir l'utilisation disque
get_disk_usage() {
    local path="${1:-/}"
    df -h "$path" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "0"
}

# Obtenir le dernier backup
get_last_backup() {
    local latest_log=$(ls -t "${BACKUP_LOG_DIR}"/backup_*.log 2>/dev/null | head -1)
    if [[ -n "$latest_log" && -f "$latest_log" ]]; then
        # Extraire le timestamp du nom de fichier
        local timestamp=$(basename "$latest_log" | sed 's/backup_\(.*\)\.log/\1/')
        # Vérifier si le backup a réussi
        if grep -q "Backup terminé avec succès" "$latest_log" 2>/dev/null; then
            echo "$timestamp"
        else
            echo "failed:$timestamp"
        fi
    else
        echo "never"
    fi
}

# Obtenir l'utilisation mémoire
get_memory_usage() {
    free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}'
}

# Obtenir le load average
get_load_average() {
    cat /proc/loadavg | awk '{print $1}'
}

# ===========================================
# Script principal
# ===========================================

main() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Vérifier les services
    local nextcloud_status=$(check_service "nextcloud-app")
    local postgres_status=$(check_service "nextcloud-postgres")
    local redis_status=$(check_service "nextcloud-redis")
    local caddy_status=$(check_service "nextcloud-caddy")
    local imaginary_status=$(check_service "nextcloud-imaginary")

    # Métriques système
    local disk_usage=$(get_disk_usage "/mnt/nextcloud_data")
    local disk_root=$(get_disk_usage "/")
    local memory_usage=$(get_memory_usage)
    local load_avg=$(get_load_average)

    # Dernier backup
    local last_backup=$(get_last_backup)

    # Statut global
    local overall="ok"
    if [[ "$nextcloud_status" != "ok" ]] || \
       [[ "$postgres_status" != "ok" ]] || \
       [[ "$redis_status" != "ok" ]] || \
       [[ "$caddy_status" != "ok" ]]; then
        overall="degraded"
    fi

    # Alertes
    local alerts="[]"
    local alert_list=()

    if [[ "$nextcloud_status" != "ok" ]]; then
        alert_list+=("\"Nextcloud is ${nextcloud_status}\"")
    fi
    if [[ "$postgres_status" != "ok" ]]; then
        alert_list+=("\"PostgreSQL is ${postgres_status}\"")
    fi
    if [[ "$redis_status" != "ok" ]]; then
        alert_list+=("\"Redis is ${redis_status}\"")
    fi
    if [[ "$caddy_status" != "ok" ]]; then
        alert_list+=("\"Caddy is ${caddy_status}\"")
    fi
    if [[ "$disk_usage" -gt 90 ]]; then
        alert_list+=("\"Disk usage critical: ${disk_usage}%\"")
        overall="critical"
    elif [[ "$disk_usage" -gt 80 ]]; then
        alert_list+=("\"Disk usage warning: ${disk_usage}%\"")
    fi
    if [[ "$last_backup" == "never" ]]; then
        alert_list+=("\"No backup found\"")
    elif [[ "$last_backup" == failed:* ]]; then
        alert_list+=("\"Last backup failed\"")
    fi

    if [[ ${#alert_list[@]} -gt 0 ]]; then
        alerts=$(printf '%s\n' "${alert_list[@]}" | paste -sd ',' -)
        alerts="[${alerts}]"
    fi

    # Générer le JSON
    cat > "$STATUS_FILE" << EOF
{
  "timestamp": "${timestamp}",
  "status": "${overall}",
  "services": {
    "nextcloud": "${nextcloud_status}",
    "postgres": "${postgres_status}",
    "redis": "${redis_status}",
    "caddy": "${caddy_status}",
    "imaginary": "${imaginary_status}"
  },
  "metrics": {
    "disk_data_percent": ${disk_usage},
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

    # Afficher le résultat
    cat "$STATUS_FILE"

    # Code de sortie basé sur le statut
    case "$overall" in
        "ok") exit 0 ;;
        "degraded") exit 1 ;;
        "critical") exit 2 ;;
        *) exit 3 ;;
    esac
}

main "$@"
