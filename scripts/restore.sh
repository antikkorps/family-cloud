#!/bin/bash
# ===========================================
# Script de Restore Family Cloud depuis R2
# ===========================================
# Usage: ./restore.sh [--list|--immich|--seafile|--stalwart] [timestamp]
#
# Exemples:
#   ./restore.sh --list              # Lister les backups disponibles
#   ./restore.sh --immich 20240115   # Restaurer Immich depuis un backup
# ===========================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Charger les variables d'environnement
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    source "${PROJECT_DIR}/.env"
    set +a
else
    echo "ERREUR: Fichier .env non trouve"
    exit 1
fi

BACKUP_PATH="${BACKUP_PATH:-${PROJECT_DIR}/backups}"
R2_BUCKET_NAME="${R2_BUCKET_NAME:-family-backup}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

decrypt_file() {
    local input_file="$1"

    if [[ "$input_file" == *.age ]] && [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        local output_file="${input_file%.age}"
        log "Dechiffrement de $(basename "$input_file")..."
        echo "$BACKUP_ENCRYPTION_KEY" | age -d -o "$output_file" "$input_file"
        rm -f "$input_file"
        echo "$output_file"
    else
        echo "$input_file"
    fi
}

list_backups() {
    log "=== Backups Immich ==="
    rclone ls "r2:${R2_BUCKET_NAME}/immich/database/" 2>/dev/null || echo "Aucun backup"

    log ""
    log "=== Backups Seafile ==="
    rclone ls "r2:${R2_BUCKET_NAME}/seafile/database/" 2>/dev/null || echo "Aucun backup"

    log ""
    log "=== Backups Stalwart ==="
    rclone ls "r2:${R2_BUCKET_NAME}/stalwart/" 2>/dev/null || echo "Aucun backup"
}

restore_immich() {
    local timestamp="$1"
    log "=== Restauration Immich ==="

    # Trouver le backup
    local db_file=$(rclone ls "r2:${R2_BUCKET_NAME}/immich/database/" 2>/dev/null | grep "$timestamp" | awk '{print $2}' | head -1)

    if [[ -z "$db_file" ]]; then
        log "ERREUR: Aucun backup trouve pour le timestamp: $timestamp"
        exit 1
    fi

    log "Backup trouve: $db_file"
    log "ATTENTION: Cela va ecraser les donnees actuelles!"
    read -p "Continuer? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Annule."
        exit 0
    fi

    # Telecharger le backup
    mkdir -p "$BACKUP_PATH"
    rclone copy "r2:${R2_BUCKET_NAME}/immich/database/${db_file}" "$BACKUP_PATH/"

    local local_file="${BACKUP_PATH}/${db_file}"
    local_file=$(decrypt_file "$local_file")

    # Arreter Immich
    log "Arret d'Immich..."
    docker stop immich-server immich-ml 2>/dev/null || true

    # Restaurer la base
    log "Restauration de la base PostgreSQL..."
    gunzip -c "$local_file" | docker exec -i immich-postgres psql -U "${IMMICH_DB_USER}" -d "${IMMICH_DB_NAME}"

    # Redemarrer
    log "Redemarrage d'Immich..."
    docker start immich-server immich-ml

    # Nettoyer
    rm -f "$local_file"

    log "Restauration Immich terminee!"
}

restore_seafile() {
    local timestamp="$1"
    log "=== Restauration Seafile ==="

    local db_file=$(rclone ls "r2:${R2_BUCKET_NAME}/seafile/database/" 2>/dev/null | grep "$timestamp" | awk '{print $2}' | head -1)

    if [[ -z "$db_file" ]]; then
        log "ERREUR: Aucun backup trouve pour le timestamp: $timestamp"
        exit 1
    fi

    log "Backup trouve: $db_file"
    log "ATTENTION: Cela va ecraser les donnees actuelles!"
    read -p "Continuer? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Annule."
        exit 0
    fi

    mkdir -p "$BACKUP_PATH"
    rclone copy "r2:${R2_BUCKET_NAME}/seafile/database/${db_file}" "$BACKUP_PATH/"

    local local_file="${BACKUP_PATH}/${db_file}"
    local_file=$(decrypt_file "$local_file")

    log "Arret de Seafile..."
    docker stop seafile 2>/dev/null || true

    log "Restauration de la base MariaDB..."
    gunzip -c "$local_file" | docker exec -i seafile-mariadb mysql -u root -p"${SEAFILE_DB_ROOT_PASSWORD}"

    log "Redemarrage de Seafile..."
    docker start seafile

    rm -f "$local_file"

    log "Restauration Seafile terminee!"
}

restore_stalwart() {
    local timestamp="$1"
    log "=== Restauration Stalwart ==="

    local archive_file=$(rclone ls "r2:${R2_BUCKET_NAME}/stalwart/" 2>/dev/null | grep "$timestamp" | awk '{print $2}' | head -1)

    if [[ -z "$archive_file" ]]; then
        log "ERREUR: Aucun backup trouve pour le timestamp: $timestamp"
        exit 1
    fi

    log "Backup trouve: $archive_file"
    log "ATTENTION: Cela va ecraser les donnees actuelles!"
    read -p "Continuer? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Annule."
        exit 0
    fi

    mkdir -p "$BACKUP_PATH"
    rclone copy "r2:${R2_BUCKET_NAME}/stalwart/${archive_file}" "$BACKUP_PATH/"

    local local_file="${BACKUP_PATH}/${archive_file}"
    local_file=$(decrypt_file "$local_file")

    log "Arret de Stalwart..."
    docker stop stalwart 2>/dev/null || true

    log "Restauration des donnees..."
    docker run --rm \
        -v stalwart_data:/target \
        -v "${BACKUP_PATH}:/backup:ro" \
        alpine sh -c "rm -rf /target/* && tar xzf /backup/$(basename "$local_file") -C /target"

    log "Redemarrage de Stalwart..."
    docker start stalwart

    rm -f "$local_file"

    log "Restauration Stalwart terminee!"
}

# Main
case "${1:-}" in
    "--list"|"list")
        list_backups
        ;;
    "--immich"|"immich")
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 --immich <timestamp>"
            exit 1
        fi
        restore_immich "$2"
        ;;
    "--seafile"|"seafile")
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 --seafile <timestamp>"
            exit 1
        fi
        restore_seafile "$2"
        ;;
    "--stalwart"|"stalwart")
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 --stalwart <timestamp>"
            exit 1
        fi
        restore_stalwart "$2"
        ;;
    *)
        echo "Usage: $0 [--list|--immich|--seafile|--stalwart] [timestamp]"
        echo ""
        echo "Options:"
        echo "  --list              Lister les backups disponibles"
        echo "  --immich <ts>       Restaurer Immich"
        echo "  --seafile <ts>      Restaurer Seafile"
        echo "  --stalwart <ts>     Restaurer Stalwart"
        exit 1
        ;;
esac
