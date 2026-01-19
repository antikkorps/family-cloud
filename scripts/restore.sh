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
#
# Note: Si les backups sont chiffrés, BACKUP_ENCRYPTION_KEY doit être défini
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
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

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

# Déchiffrer un fichier avec age
decrypt_file() {
    local input_file="$1"

    # Vérifier si le fichier est chiffré (extension .age)
    if [[ "$input_file" == *.age ]]; then
        if [[ -z "$BACKUP_ENCRYPTION_KEY" ]]; then
            error "Fichier chiffré détecté mais BACKUP_ENCRYPTION_KEY n'est pas défini"
        fi

        local output_file="${input_file%.age}"
        log "Déchiffrement de $(basename "$input_file")..."
        echo "$BACKUP_ENCRYPTION_KEY" | age -d -o "$output_file" "$input_file" 2>/dev/null || error "Échec du déchiffrement"
        rm -f "$input_file"
        echo "$output_file"
    else
        echo "$input_file"
    fi
}

# Lister les backups disponibles
list_backups() {
    log "Backups de base de données disponibles:"
    rclone ls "r2:${R2_BUCKET_NAME}/database/" 2>/dev/null | sort -r | head -20

    echo ""
    log "Backups de configuration disponibles:"
    rclone ls "r2:${R2_BUCKET_NAME}/config/" 2>/dev/null | sort -r | head -20

    echo ""
    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        log "Note: Clé de déchiffrement configurée"
    else
        log "Note: Pas de clé de déchiffrement configurée (BACKUP_ENCRYPTION_KEY)"
    fi
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

    # Déchiffrer si nécessaire
    db_file=$(decrypt_file "$db_file")

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

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        log "Note: Les données seront déchiffrées automatiquement (rclone crypt)"
    fi

    read -p "Continuer? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Restauration annulée"
        exit 0
    fi

    # Activer le mode maintenance
    log "Activation du mode maintenance..."
    docker exec nextcloud-app php occ maintenance:mode --on || true

    local remote="r2:${R2_BUCKET_NAME}/data/"

    # Si chiffrement activé, utiliser rclone crypt
    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        log "Utilisation du déchiffrement rclone crypt..."
        remote="r2-crypt:data/"
    fi

    # Synchroniser depuis R2
    log "Synchronisation des données depuis R2..."
    rclone sync "$remote" "$DATA_PATH/" \
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

    local config_file="${BACKUP_PATH}/${timestamp}"

    # Déchiffrer si nécessaire
    config_file=$(decrypt_file "$config_file")

    # Restaurer dans le volume Docker
    log "Restauration de la configuration..."
    docker run --rm \
        -v nextcloud_www:/dest \
        -v "${BACKUP_PATH}:/backup:ro" \
        alpine sh -c "cd /dest && tar xzf /backup/$(basename "$config_file")" || error "Échec de la restauration"

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
    echo ""
    echo "Si les backups sont chiffrés, définissez BACKUP_ENCRYPTION_KEY dans .env"
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
