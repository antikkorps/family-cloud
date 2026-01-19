#!/bin/bash
# ===========================================
# Script de Restauration Nextcloud depuis R2
# ===========================================
# Usage: ./restore.sh [--list|--db|--data|--config] [timestamp]
#
# Exemples:
#   ./restore.sh --list              # Lister les backups disponibles
#   ./restore.sh --db 20240115       # Restaurer la DB du 15 janvier 2024
#   ./restore.sh --data              # Restaurer les données (dernier backup)
# ===========================================

set -euo pipefail

# ===========================================
# Configuration
# ===========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Charger les variables d'environnement
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    source "${PROJECT_DIR}/.env"
    set +a
else
    echo "ERREUR: Fichier .env non trouvé"
    exit 1
fi

BACKUP_PATH="${BACKUP_PATH:-${PROJECT_DIR}/backups}"
R2_BUCKET_NAME="${R2_BUCKET_NAME:-nextcloud-backup}"
DATA_PATH="${DATA_PATH:-/mnt/nextcloud_data}"

# ===========================================
# Fonctions
# ===========================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    log "ERREUR: $1"
    exit 1
}

# Lister les backups disponibles
list_backups() {
    log "Backups de base de données disponibles:"
    rclone ls "r2:${R2_BUCKET_NAME}/database/" 2>/dev/null | sort -r | head -20

    echo ""
    log "Backups de configuration disponibles:"
    rclone ls "r2:${R2_BUCKET_NAME}/config/" 2>/dev/null | sort -r | head -20
}

# Restaurer la base de données
restore_database() {
    local timestamp="${1:-}"

    log "Recherche du backup de base de données..."

    # Si pas de timestamp, prendre le plus récent
    if [[ -z "$timestamp" ]]; then
        local latest=$(rclone ls "r2:${R2_BUCKET_NAME}/database/" 2>/dev/null | sort -r | head -1 | awk '{print $2}')
        if [[ -z "$latest" ]]; then
            error "Aucun backup trouvé sur R2"
        fi
        timestamp="$latest"
    else
        # Chercher un backup correspondant au timestamp partiel
        local matching=$(rclone ls "r2:${R2_BUCKET_NAME}/database/" 2>/dev/null | grep "$timestamp" | head -1 | awk '{print $2}')
        if [[ -z "$matching" ]]; then
            error "Aucun backup trouvé pour le timestamp: $timestamp"
        fi
        timestamp="$matching"
    fi

    log "Restauration de: $timestamp"

    # Télécharger le backup
    mkdir -p "$BACKUP_PATH"
    rclone copy "r2:${R2_BUCKET_NAME}/database/${timestamp}" "$BACKUP_PATH/" || error "Échec du téléchargement"

    local db_file="${BACKUP_PATH}/${timestamp}"

    # Activer le mode maintenance
    log "Activation du mode maintenance..."
    docker exec nextcloud-app php occ maintenance:mode --on || true

    # Restaurer la base de données
    log "Restauration de la base de données..."
    gunzip -c "$db_file" | docker exec -i nextcloud-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" || error "Échec de la restauration"

    # Désactiver le mode maintenance
    log "Désactivation du mode maintenance..."
    docker exec nextcloud-app php occ maintenance:mode --off || true

    log "Base de données restaurée avec succès!"
}

# Restaurer les données
restore_data() {
    log "ATTENTION: Cette opération va synchroniser les données depuis R2"
    log "Les fichiers locaux non présents sur R2 seront supprimés!"
    read -p "Continuer? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Restauration annulée"
        exit 0
    fi

    # Activer le mode maintenance
    log "Activation du mode maintenance..."
    docker exec nextcloud-app php occ maintenance:mode --on || true

    # Synchroniser depuis R2
    log "Synchronisation des données depuis R2..."
    rclone sync "r2:${R2_BUCKET_NAME}/data/" "$DATA_PATH/" \
        --transfers=4 \
        --checkers=8 \
        --progress || error "Échec de la synchronisation"

    # Corriger les permissions
    log "Correction des permissions..."
    docker exec nextcloud-app chown -R www-data:www-data /var/www/html/data || true

    # Scanner les fichiers
    log "Scan des fichiers Nextcloud..."
    docker exec -u www-data nextcloud-app php occ files:scan --all || true

    # Désactiver le mode maintenance
    log "Désactivation du mode maintenance..."
    docker exec nextcloud-app php occ maintenance:mode --off || true

    log "Données restaurées avec succès!"
}

# Restaurer la configuration
restore_config() {
    local timestamp="${1:-}"

    log "Recherche du backup de configuration..."

    if [[ -z "$timestamp" ]]; then
        local latest=$(rclone ls "r2:${R2_BUCKET_NAME}/config/" 2>/dev/null | sort -r | head -1 | awk '{print $2}')
        if [[ -z "$latest" ]]; then
            error "Aucun backup de configuration trouvé"
        fi
        timestamp="$latest"
    else
        local matching=$(rclone ls "r2:${R2_BUCKET_NAME}/config/" 2>/dev/null | grep "$timestamp" | head -1 | awk '{print $2}')
        if [[ -z "$matching" ]]; then
            error "Aucun backup trouvé pour le timestamp: $timestamp"
        fi
        timestamp="$matching"
    fi

    log "Restauration de: $timestamp"

    # Télécharger
    mkdir -p "$BACKUP_PATH"
    rclone copy "r2:${R2_BUCKET_NAME}/config/${timestamp}" "$BACKUP_PATH/" || error "Échec du téléchargement"

    # Restaurer dans le volume Docker
    log "Restauration de la configuration..."
    docker run --rm \
        -v nextcloud_www:/dest \
        -v "${BACKUP_PATH}:/backup:ro" \
        alpine sh -c "cd /dest && tar xzf /backup/${timestamp}" || error "Échec de la restauration"

    log "Configuration restaurée avec succès!"
    log "Redémarrez les conteneurs: docker compose restart"
}

# ===========================================
# Script principal
# ===========================================

show_help() {
    echo "Usage: $0 [option] [timestamp]"
    echo ""
    echo "Options:"
    echo "  --list          Lister les backups disponibles"
    echo "  --db            Restaurer la base de données"
    echo "  --data          Restaurer les données"
    echo "  --config        Restaurer la configuration"
    echo "  --help          Afficher cette aide"
    echo ""
    echo "Le timestamp est optionnel. Sans timestamp, le backup le plus récent est utilisé."
}

case "${1:-}" in
    "--list"|"-l")
        list_backups
        ;;
    "--db"|"-d")
        restore_database "${2:-}"
        ;;
    "--data")
        restore_data
        ;;
    "--config"|"-c")
        restore_config "${2:-}"
        ;;
    "--help"|"-h"|"")
        show_help
        ;;
    *)
        error "Option non reconnue: $1"
        ;;
esac
