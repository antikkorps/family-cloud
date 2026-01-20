#!/bin/bash
# ===========================================
# Script de Health Check Family Cloud
# ===========================================
# Usage: ./health-check.sh
#
# Genere un fichier status.json avec l'etat des services.
# A executer via cron toutes les 5 minutes :
# */5 * * * * /path/to/health-check.sh
# ===========================================

set -euo pipefail

# ===========================================
# Configuration
# ===========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATUS_FILE="/var/log/family-cloud-status.json"
BACKUP_LOG_DIR="${PROJECT_DIR}/backups"

# ===========================================
# Fonctions
# ===========================================

check_service() {
    local container_name="$1"
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
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

    # Verifier les services Immich
    local immich_server=$(check_service "immich-server")
    local immich_ml=$(check_service "immich-ml")
    local immich_postgres=$(check_service "immich-postgres")
    local immich_redis=$(check_service "immich-redis")

    # Verifier les services Seafile
    local seafile=$(check_service "seafile")
    local seafile_mariadb=$(check_service "seafile-mariadb")
    local seafile_memcached=$(check_service "seafile-memcached")

    # Verifier Stalwart
    local stalwart=$(check_service "stalwart")

    # Verifier l'infrastructure
    local caddy=$(check_service "family-caddy")
    local cloudflared=$(check_service "family-cloudflared")

    # Metriques systeme
    local disk_root=$(get_disk_usage "/")
    local memory_usage=$(get_memory_usage)
    local load_avg=$(get_load_average)

    # Dernier backup
    local last_backup=$(get_last_backup)

    # Statut global
    local overall="ok"
    if [[ "$immich_server" != "ok" ]] || \
       [[ "$seafile" != "ok" ]] || \
       [[ "$stalwart" != "ok" ]] || \
       [[ "$caddy" != "ok" ]]; then
        overall="degraded"
    fi

    # Alertes
    local alert_list=()

    if [[ "$immich_server" != "ok" ]]; then
        alert_list+=("\"Immich server is ${immich_server}\"")
    fi
    if [[ "$immich_postgres" != "ok" ]]; then
        alert_list+=("\"Immich PostgreSQL is ${immich_postgres}\"")
    fi
    if [[ "$seafile" != "ok" ]]; then
        alert_list+=("\"Seafile is ${seafile}\"")
    fi
    if [[ "$seafile_mariadb" != "ok" ]]; then
        alert_list+=("\"Seafile MariaDB is ${seafile_mariadb}\"")
    fi
    if [[ "$stalwart" != "ok" ]]; then
        alert_list+=("\"Stalwart is ${stalwart}\"")
    fi
    if [[ "$caddy" != "ok" ]]; then
        alert_list+=("\"Caddy is ${caddy}\"")
    fi
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

    # Generer le JSON
    cat > "$STATUS_FILE" << EOF
{
  "timestamp": "${timestamp}",
  "status": "${overall}",
  "services": {
    "immich": {
      "server": "${immich_server}",
      "ml": "${immich_ml}",
      "postgres": "${immich_postgres}",
      "redis": "${immich_redis}"
    },
    "seafile": {
      "app": "${seafile}",
      "mariadb": "${seafile_mariadb}",
      "memcached": "${seafile_memcached}"
    },
    "stalwart": "${stalwart}",
    "infrastructure": {
      "caddy": "${caddy}",
      "cloudflared": "${cloudflared}"
    }
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
