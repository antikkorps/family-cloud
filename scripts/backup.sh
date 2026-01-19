#!/bin/bash
# ===========================================
# Script de Backup Nextcloud vers Cloudflare R2
# ===========================================
# Usage: ./backup.sh [--full|--db-only|--data-only]
#
# Ce script :
# 1. Active le mode maintenance
# 2. Dump la base de données PostgreSQL
# 3. Chiffre les backups (si BACKUP_ENCRYPTION_KEY est défini)
# 4. Synchronise vers Cloudflare R2 avec Rclone
# 5. Désactive le mode maintenance
# ===========================================

set -euo pipefail

# ===========================================
# Configuration
# ===========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${PROJECT_DIR}/backups/backup_${TIMESTAMP}.log"

# Charger les variables d'environnement
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    source "${PROJECT_DIR}/.env"
    set +a
else
    echo "ERREUR: Fichier .env non trouvé dans ${PROJECT_DIR}"
    exit 1
fi

# Valeurs par défaut
BACKUP_PATH="${BACKUP_PATH:-${PROJECT_DIR}/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
R2_BUCKET_NAME="${R2_BUCKET_NAME:-nextcloud-backup}"
DATA_PATH="${DATA_PATH:-/mnt/nextcloud_data}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

# Mode de backup (full par défaut)
BACKUP_MODE="${1:-full}"

# ===========================================
# Fonctions
# ===========================================

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
}

error() {
    log "ERREUR: $1"
    # Désactiver le mode maintenance en cas d'erreur
    maintenance_off || true
    exit 1
}

# Vérifier les prérequis
check_prerequisites() {
    log "Vérification des prérequis..."

    # Vérifier que rclone est installé
    if ! command -v rclone &> /dev/null; then
        error "rclone n'est pas installé. Installez-le avec: sudo apt install rclone"
    fi

    # Vérifier age si chiffrement activé
    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        if ! command -v age &> /dev/null; then
            error "age n'est pas installé mais BACKUP_ENCRYPTION_KEY est défini. Installez-le avec: sudo apt install age"
        fi
        log "Chiffrement activé (age)"
    else
        log "ATTENTION: Chiffrement désactivé (BACKUP_ENCRYPTION_KEY non défini)"
    fi

    # Vérifier que Docker est en cours d'exécution
    if ! docker info &> /dev/null; then
        error "Docker n'est pas en cours d'exécution"
    fi

    # Vérifier que le conteneur Nextcloud existe
    if ! docker ps -q -f name=nextcloud-app &> /dev/null; then
        error "Conteneur nextcloud-app non trouvé"
    fi

    # Créer le répertoire de backup si nécessaire
    mkdir -p "$BACKUP_PATH"

    log "Prérequis OK"
}

# Chiffrer un fichier avec age
encrypt_file() {
    local input_file="$1"
    local output_file="${input_file}.age"

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        log "Chiffrement de $(basename "$input_file")..."
        echo "$BACKUP_ENCRYPTION_KEY" | age -p -o "$output_file" "$input_file" 2>/dev/null
        # Supprimer le fichier non chiffré
        rm -f "$input_file"
        echo "$output_file"
    else
        echo "$input_file"
    fi
}

# Activer le mode maintenance
maintenance_on() {
    log "Activation du mode maintenance..."
    docker exec nextcloud-app php occ maintenance:mode --on || error "Impossible d'activer le mode maintenance"
    log "Mode maintenance activé"
}

# Désactiver le mode maintenance
maintenance_off() {
    log "Désactivation du mode maintenance..."
    docker exec nextcloud-app php occ maintenance:mode --off || log "ATTENTION: Impossible de désactiver le mode maintenance"
    log "Mode maintenance désactivé"
}

# Dump de la base de données
backup_database() {
    log "Backup de la base de données PostgreSQL..."

    local db_backup_file="${BACKUP_PATH}/db_${TIMESTAMP}.sql.gz"

    docker exec nextcloud-postgres pg_dump \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        --no-owner \
        --no-acl \
        | gzip > "$db_backup_file" || error "Échec du dump PostgreSQL"

    log "Base de données sauvegardée: $db_backup_file ($(du -h "$db_backup_file" | cut -f1))"

    # Chiffrer si activé
    db_backup_file=$(encrypt_file "$db_backup_file")

    # Upload vers R2
    log "Upload du dump vers R2..."
    rclone copy "$db_backup_file" "r2:${R2_BUCKET_NAME}/database/" \
        --progress \
        --log-file="$LOG_FILE" \
        --log-level INFO || error "Échec de l'upload du dump vers R2"

    log "Dump uploadé vers R2"
}

# Backup des données Nextcloud (avec rclone crypt si chiffrement activé)
backup_data() {
    log "Synchronisation des données vers R2..."
    log "Chemin des données: $DATA_PATH"

    local remote="r2:${R2_BUCKET_NAME}/data/"

    # Si chiffrement activé, utiliser rclone crypt
    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        log "Utilisation du chiffrement rclone crypt..."
        remote="r2-crypt:data/"
    fi

    # Synchroniser les données vers R2
    rclone sync "$DATA_PATH" "$remote" \
        --transfers=4 \
        --checkers=8 \
        --progress \
        --log-file="$LOG_FILE" \
        --log-level INFO \
        --exclude "appdata_*/preview/**" \
        --exclude "*.part" \
        --exclude "*.tmp" || error "Échec de la synchronisation des données"

    log "Données synchronisées vers R2"
}

# Backup de la configuration
backup_config() {
    log "Backup de la configuration Nextcloud..."

    local config_backup_file="${BACKUP_PATH}/config_${TIMESTAMP}.tar.gz"

    # Extraire la config depuis le volume Docker
    docker run --rm \
        -v nextcloud_www:/source:ro \
        -v "${BACKUP_PATH}:/backup" \
        alpine tar czf "/backup/config_${TIMESTAMP}.tar.gz" \
        -C /source config || error "Échec du backup de la configuration"

    log "Configuration sauvegardée: $config_backup_file"

    # Chiffrer si activé
    config_backup_file=$(encrypt_file "$config_backup_file")

    # Upload vers R2
    rclone copy "$config_backup_file" "r2:${R2_BUCKET_NAME}/config/" \
        --progress \
        --log-file="$LOG_FILE" \
        --log-level INFO || error "Échec de l'upload de la config vers R2"

    log "Configuration uploadée vers R2"
}

# Nettoyage des anciens backups locaux
cleanup_local() {
    log "Nettoyage des backups locaux de plus de ${BACKUP_RETENTION_DAYS} jours..."

    find "$BACKUP_PATH" -type f -name "*.sql.gz*" -mtime +${BACKUP_RETENTION_DAYS} -delete 2>/dev/null || true
    find "$BACKUP_PATH" -type f -name "*.tar.gz*" -mtime +${BACKUP_RETENTION_DAYS} -delete 2>/dev/null || true
    find "$BACKUP_PATH" -type f -name "*.log" -mtime +${BACKUP_RETENTION_DAYS} -delete 2>/dev/null || true

    log "Nettoyage local terminé"
}

# Nettoyage des anciens backups sur R2
cleanup_r2() {
    log "Nettoyage des backups R2 de plus de ${BACKUP_RETENTION_DAYS} jours..."

    rclone delete "r2:${R2_BUCKET_NAME}/database/" \
        --min-age "${BACKUP_RETENTION_DAYS}d" \
        --log-file="$LOG_FILE" \
        --log-level INFO 2>/dev/null || true

    rclone delete "r2:${R2_BUCKET_NAME}/config/" \
        --min-age "${BACKUP_RETENTION_DAYS}d" \
        --log-file="$LOG_FILE" \
        --log-level INFO 2>/dev/null || true

    log "Nettoyage R2 terminé"
}

# ===========================================
# Script principal
# ===========================================

main() {
    log "=========================================="
    log "Démarrage du backup Nextcloud"
    log "Mode: $BACKUP_MODE"
    log "Chiffrement: $([ -n "$BACKUP_ENCRYPTION_KEY" ] && echo "activé" || echo "désactivé")"
    log "=========================================="

    check_prerequisites

    # Activer le mode maintenance
    maintenance_on

    case "$BACKUP_MODE" in
        "full")
            backup_database
            backup_data
            backup_config
            ;;
        "--db-only"|"db-only")
            backup_database
            ;;
        "--data-only"|"data-only")
            backup_data
            ;;
        "--config-only"|"config-only")
            backup_config
            ;;
        *)
            log "Mode non reconnu: $BACKUP_MODE"
            log "Modes disponibles: full, db-only, data-only, config-only"
            maintenance_off
            exit 1
            ;;
    esac

    # Désactiver le mode maintenance
    maintenance_off

    # Nettoyage
    cleanup_local
    cleanup_r2

    log "=========================================="
    log "Backup terminé avec succès!"
    log "=========================================="
}

# Exécuter le script principal
main "$@"
