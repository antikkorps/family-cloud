#!/bin/bash
# ===========================================
# Script de Backup Family Cloud vers Cloudflare R2
# ===========================================
# Usage: ./backup.sh [--full|--immich|--seafile|--baikal|--vaultwarden|--paperless]
#
# Ce script sauvegarde :
# - Immich : PostgreSQL + photos/videos
# - Seafile : MariaDB + fichiers
# - Baikal : donnees CalDAV/CardDAV
# - Vaultwarden : donnees mots de passe
# - Paperless : donnees documents
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
    echo "ERREUR: Fichier .env non trouve dans ${PROJECT_DIR}"
    exit 1
fi

# Valeurs par defaut
BACKUP_PATH="${BACKUP_PATH:-${PROJECT_DIR}/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
R2_BUCKET_NAME="${R2_BUCKET_NAME:-family-backup}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

# Mode de backup (full par defaut)
BACKUP_MODE="${1:-full}"

# ===========================================
# Fonctions utilitaires
# ===========================================

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
}

error() {
    log "ERREUR: $1"
    exit 1
}

check_prerequisites() {
    log "Verification des prerequis..."

    if ! command -v rclone &> /dev/null; then
        error "rclone n'est pas installe. Installez-le avec: sudo apt install rclone"
    fi

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        if ! command -v age &> /dev/null; then
            error "age n'est pas installe mais BACKUP_ENCRYPTION_KEY est defini"
        fi
        log "Chiffrement cote client active (age)"
    else
        log "Chiffrement cote client desactive (R2 chiffre au repos)"
    fi

    if ! docker info &> /dev/null; then
        error "Docker n'est pas en cours d'execution"
    fi

    mkdir -p "$BACKUP_PATH"
    log "Prerequis OK"
}

encrypt_file() {
    local input_file="$1"
    local output_file="${input_file}.age"

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        log "Chiffrement de $(basename "$input_file")..."
        echo "$BACKUP_ENCRYPTION_KEY" | age -p -o "$output_file" "$input_file" 2>/dev/null
        rm -f "$input_file"
        echo "$output_file"
    else
        echo "$input_file"
    fi
}

upload_to_r2() {
    local file="$1"
    local destination="$2"

    rclone copy "$file" "r2:${R2_BUCKET_NAME}/${destination}/" \
        --progress \
        --log-file="$LOG_FILE" \
        --log-level INFO || error "Echec de l'upload vers R2: $file"

    log "Uploade vers R2: ${destination}/$(basename "$file")"
}

# ===========================================
# Backup Immich
# ===========================================

backup_immich() {
    log "=== Backup Immich ==="

    # Verifier que les conteneurs existent
    if ! docker ps -q -f name=immich-postgres &> /dev/null; then
        log "ATTENTION: Conteneur immich-postgres non trouve, skip"
        return 0
    fi

    # 1. Dump PostgreSQL
    log "Dump PostgreSQL Immich..."
    local db_backup_file="${BACKUP_PATH}/immich_db_${TIMESTAMP}.sql.gz"

    docker exec immich-postgres pg_dump \
        -U "${IMMICH_DB_USER}" \
        -d "${IMMICH_DB_NAME}" \
        --clean \
        --if-exists \
        | gzip > "$db_backup_file" || error "Echec du dump PostgreSQL Immich"

    log "Base Immich sauvegardee: $(du -h "$db_backup_file" | cut -f1)"

    db_backup_file=$(encrypt_file "$db_backup_file")
    upload_to_r2 "$db_backup_file" "immich/database"

    # 2. Sync des photos/videos vers R2
    log "Synchronisation des photos/videos Immich..."
    local remote="r2:${R2_BUCKET_NAME}/immich/upload/"

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        remote="r2-crypt:immich/upload/"
    fi

    rclone sync "${UPLOAD_LOCATION}" "$remote" \
        --transfers=4 \
        --checkers=8 \
        --progress \
        --log-file="$LOG_FILE" \
        --log-level INFO \
        --exclude "*.tmp" \
        --exclude "*.part" || error "Echec de la synchronisation Immich"

    log "Photos/videos Immich synchronisees"
}

# ===========================================
# Backup Seafile
# ===========================================

backup_seafile() {
    log "=== Backup Seafile ==="

    if ! docker ps -q -f name=seafile-mariadb &> /dev/null; then
        log "ATTENTION: Conteneur seafile-mariadb non trouve, skip"
        return 0
    fi

    # 1. Dump MariaDB (toutes les bases Seafile)
    log "Dump MariaDB Seafile..."
    local db_backup_file="${BACKUP_PATH}/seafile_db_${TIMESTAMP}.sql.gz"

    docker exec seafile-mariadb mysqldump \
        -u root \
        -p"${SEAFILE_DB_ROOT_PASSWORD}" \
        --all-databases \
        --single-transaction \
        --routines \
        --triggers \
        | gzip > "$db_backup_file" || error "Echec du dump MariaDB Seafile"

    log "Base Seafile sauvegardee: $(du -h "$db_backup_file" | cut -f1)"

    db_backup_file=$(encrypt_file "$db_backup_file")
    upload_to_r2 "$db_backup_file" "seafile/database"

    # 2. Backup des donnees Seafile
    log "Synchronisation des donnees Seafile..."
    local remote="r2:${R2_BUCKET_NAME}/seafile/data/"

    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        remote="r2-crypt:seafile/data/"
    fi

    # Utiliser le volume Docker
    docker run --rm \
        -v seafile_data:/source:ro \
        -v "${BACKUP_PATH}:/backup" \
        alpine tar czf "/backup/seafile_data_${TIMESTAMP}.tar.gz" \
        -C /source . || error "Echec de la creation de l'archive Seafile"

    local seafile_archive="${BACKUP_PATH}/seafile_data_${TIMESTAMP}.tar.gz"
    log "Archive Seafile creee: $(du -h "$seafile_archive" | cut -f1)"

    seafile_archive=$(encrypt_file "$seafile_archive")
    upload_to_r2 "$seafile_archive" "seafile/data"

    # Nettoyer l'archive locale
    rm -f "${BACKUP_PATH}/seafile_data_${TIMESTAMP}.tar.gz"*

    log "Donnees Seafile sauvegardees"
}

# ===========================================
# Backup Baikal (CalDAV/CardDAV)
# ===========================================

backup_baikal() {
    log "=== Backup Baikal ==="

    if ! docker ps -q -f name=baikal &> /dev/null; then
        log "ATTENTION: Conteneur baikal non trouve, skip"
        return 0
    fi

    log "Backup des donnees Baikal..."

    # Creer une archive des donnees Baikal (config + data)
    docker run --rm \
        -v baikal_config:/config:ro \
        -v baikal_data:/data:ro \
        -v "${BACKUP_PATH}:/backup" \
        alpine sh -c "tar czf /backup/baikal_${TIMESTAMP}.tar.gz -C / config data" \
        || error "Echec du backup Baikal"

    local baikal_archive="${BACKUP_PATH}/baikal_${TIMESTAMP}.tar.gz"
    log "Archive Baikal creee: $(du -h "$baikal_archive" | cut -f1)"

    baikal_archive=$(encrypt_file "$baikal_archive")
    upload_to_r2 "$baikal_archive" "baikal"

    # Nettoyer l'archive locale
    rm -f "${BACKUP_PATH}/baikal_${TIMESTAMP}.tar.gz"*

    log "Donnees Baikal sauvegardees"
}

# ===========================================
# Backup Vaultwarden
# ===========================================

backup_vaultwarden() {
    log "=== Backup Vaultwarden ==="

    if ! docker ps -q -f name=vaultwarden &> /dev/null; then
        log "ATTENTION: Conteneur vaultwarden non trouve, skip"
        return 0
    fi

    log "Backup des donnees Vaultwarden..."

    # Creer une archive des donnees Vaultwarden
    docker run --rm \
        -v vaultwarden_data:/source:ro \
        -v "${BACKUP_PATH}:/backup" \
        alpine tar czf "/backup/vaultwarden_${TIMESTAMP}.tar.gz" \
        -C /source . || error "Echec du backup Vaultwarden"

    local vaultwarden_archive="${BACKUP_PATH}/vaultwarden_${TIMESTAMP}.tar.gz"
    log "Archive Vaultwarden creee: $(du -h "$vaultwarden_archive" | cut -f1)"

    vaultwarden_archive=$(encrypt_file "$vaultwarden_archive")
    upload_to_r2 "$vaultwarden_archive" "vaultwarden"

    # Nettoyer l'archive locale
    rm -f "${BACKUP_PATH}/vaultwarden_${TIMESTAMP}.tar.gz"*

    log "Donnees Vaultwarden sauvegardees"
}

# ===========================================
# Backup Paperless-ngx
# ===========================================

backup_paperless() {
    log "=== Backup Paperless-ngx ==="

    if ! docker ps -q -f name=paperless &> /dev/null; then
        log "ATTENTION: Conteneur paperless non trouve, skip"
        return 0
    fi

    log "Backup des donnees Paperless..."

    # Creer une archive des donnees Paperless (data + media)
    docker run --rm \
        -v paperless_data:/data:ro \
        -v paperless_media:/media:ro \
        -v "${BACKUP_PATH}:/backup" \
        alpine sh -c "tar czf /backup/paperless_${TIMESTAMP}.tar.gz -C / data media" \
        || error "Echec du backup Paperless"

    local paperless_archive="${BACKUP_PATH}/paperless_${TIMESTAMP}.tar.gz"
    log "Archive Paperless creee: $(du -h "$paperless_archive" | cut -f1)"

    paperless_archive=$(encrypt_file "$paperless_archive")
    upload_to_r2 "$paperless_archive" "paperless"

    # Nettoyer l'archive locale
    rm -f "${BACKUP_PATH}/paperless_${TIMESTAMP}.tar.gz"*

    log "Donnees Paperless sauvegardees"
}

# ===========================================
# Nettoyage
# ===========================================

cleanup_local() {
    log "Nettoyage des backups locaux de plus de ${BACKUP_RETENTION_DAYS} jours..."
    find "$BACKUP_PATH" -type f -name "*.sql.gz*" -mtime +${BACKUP_RETENTION_DAYS} -delete 2>/dev/null || true
    find "$BACKUP_PATH" -type f -name "*.tar.gz*" -mtime +${BACKUP_RETENTION_DAYS} -delete 2>/dev/null || true
    find "$BACKUP_PATH" -type f -name "*.log" -mtime +${BACKUP_RETENTION_DAYS} -delete 2>/dev/null || true
    log "Nettoyage local termine"
}

cleanup_r2() {
    log "Nettoyage des backups R2 de plus de ${BACKUP_RETENTION_DAYS} jours..."

    for path in "immich/database" "seafile/database" "seafile/data" "baikal" "vaultwarden" "paperless"; do
        rclone delete "r2:${R2_BUCKET_NAME}/${path}/" \
            --min-age "${BACKUP_RETENTION_DAYS}d" \
            --log-file="$LOG_FILE" \
            --log-level INFO 2>/dev/null || true
    done

    log "Nettoyage R2 termine"
}

# ===========================================
# Script principal
# ===========================================

main() {
    log "=========================================="
    log "Demarrage du backup Family Cloud"
    log "Mode: $BACKUP_MODE"
    log "Chiffrement: $([ -n "$BACKUP_ENCRYPTION_KEY" ] && echo "active" || echo "desactive")"
    log "=========================================="

    check_prerequisites

    case "$BACKUP_MODE" in
        "full"|"--full")
            backup_immich
            backup_seafile
            backup_baikal
            backup_vaultwarden
            backup_paperless
            ;;
        "--immich"|"immich")
            backup_immich
            ;;
        "--seafile"|"seafile")
            backup_seafile
            ;;
        "--baikal"|"baikal")
            backup_baikal
            ;;
        "--vaultwarden"|"vaultwarden")
            backup_vaultwarden
            ;;
        "--paperless"|"paperless")
            backup_paperless
            ;;
        *)
            log "Mode non reconnu: $BACKUP_MODE"
            log "Modes disponibles: full, immich, seafile, baikal, vaultwarden, paperless"
            exit 1
            ;;
    esac

    cleanup_local
    cleanup_r2

    log "=========================================="
    log "Backup termine avec succes!"
    log "=========================================="
}

main "$@"
