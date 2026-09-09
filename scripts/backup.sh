#!/bin/bash
# ===========================================
# Script de Backup Family Cloud vers Cloudflare R2 (chiffre)
# ===========================================
# Usage: ./backup.sh [full|immich|seafile|vaultwarden|paperless|jellyfin]
#
# Chiffrement : rclone crypt (remote "r2-crypt" enveloppant "r2:family-backup").
#   -> les donnees ET les noms de fichiers sont chiffres cote client avant upload.
#   -> secret (password/password2) dans rclone.conf (obscurci) + Bitwarden.
#      Sans ces secrets, AUCUNE restauration possible.
#
# Ce script sauvegarde :
# - Immich      : dump PostgreSQL + sync incremental des originaux
# - Seafile     : dump MariaDB (VITAL) + archive des blocs de donnees
# - Vaultwarden : archive du volume
# - Paperless   : archive data + media
# - Jellyfin    : archive de la config (comptes, reglages, historique)
# ===========================================

set -euo pipefail

# Forcer le daemon systeme (indispensable sous systemd/cron : pas de contexte CLI)
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"

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

# Remote chiffre (crypt). Tout passe par la.
CRYPT_REMOTE="r2-crypt:"

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

    command -v rclone &>/dev/null || error "rclone n'est pas installe (sudo apt install rclone)"

    # Le remote chiffre doit exister
    if ! rclone listremotes 2>/dev/null | grep -qx "${CRYPT_REMOTE}"; then
        error "Remote rclone '${CRYPT_REMOTE}' introuvable. Configure-le (crypt enveloppant r2:${R2_BUCKET_NAME})."
    fi

    docker info &>/dev/null || error "Docker n'est pas joignable (DOCKER_HOST=${DOCKER_HOST})"

    mkdir -p "$BACKUP_PATH"
    log "Prerequis OK (chiffrement rclone crypt actif)"
}

upload_to_r2() {
    local file="$1"          # fichier local
    local destination="$2"   # sous-dossier logique (chiffre a l'arrivee)

    rclone copy "$file" "${CRYPT_REMOTE}${destination}/" \
        --log-file="$LOG_FILE" \
        --log-level INFO || error "Echec de l'upload chiffre vers R2: $file"

    log "Uploade (chiffre) vers R2: ${destination}/$(basename "$file")"
}

# ===========================================
# Backup Immich
# ===========================================

backup_immich() {
    log "=== Backup Immich ==="

    if ! docker ps --format '{{.Names}}' | grep -qx immich-postgres; then
        log "ATTENTION: Conteneur immich-postgres non trouve, skip"
        return 0
    fi

    # 1. Dump PostgreSQL
    log "Dump PostgreSQL Immich..."
    local db_backup_file="${BACKUP_PATH}/immich_db_${TIMESTAMP}.sql.gz"
    docker exec immich-postgres pg_dump \
        -U "${IMMICH_DB_USER}" \
        -d "${IMMICH_DB_NAME}" \
        --clean --if-exists \
        | gzip > "$db_backup_file" || error "Echec du dump PostgreSQL Immich"
    log "Base Immich sauvegardee: $(du -h "$db_backup_file" | cut -f1)"
    upload_to_r2 "$db_backup_file" "immich/database"

    # 2. Sync incremental des originaux (chiffres)
    log "Synchronisation des originaux Immich (incremental, chiffre)..."
    rclone sync "${UPLOAD_LOCATION}" "${CRYPT_REMOTE}immich/upload/" \
        --transfers=4 --checkers=8 \
        --log-file="$LOG_FILE" --log-level INFO \
        --exclude "*.tmp" --exclude "*.part" \
        || error "Echec de la synchronisation Immich"
    log "Originaux Immich synchronises"
}

# ===========================================
# Backup Seafile  (DB MariaDB = VITAL pour exploiter les blocs)
# ===========================================

backup_seafile() {
    log "=== Backup Seafile ==="

    if ! docker ps --format '{{.Names}}' | grep -qx seafile-mariadb; then
        log "ATTENTION: Conteneur seafile-mariadb non trouve, skip"
        return 0
    fi

    # 1. Dump MariaDB (toutes les bases : ccnet_db, seafile_db, seahub_db)
    log "Dump MariaDB Seafile (VITAL)..."
    local db_backup_file="${BACKUP_PATH}/seafile_db_${TIMESTAMP}.sql.gz"
    docker exec seafile-mariadb mysqldump \
        -u root -p"${SEAFILE_DB_ROOT_PASSWORD}" \
        --all-databases --single-transaction --routines --triggers \
        2>/dev/null \
        | gzip > "$db_backup_file" || error "Echec du dump MariaDB Seafile"
    log "Base Seafile sauvegardee: $(du -h "$db_backup_file" | cut -f1)"
    upload_to_r2 "$db_backup_file" "seafile/database"

    # 2. Archive des blocs de donnees (point-in-time, coherent avec le dump ci-dessus)
    log "Archive des donnees Seafile..."
    docker run --rm \
        -v seafile_data:/source:ro \
        -v "${BACKUP_PATH}:/backup" \
        alpine tar czf "/backup/seafile_data_${TIMESTAMP}.tar.gz" -C /source . \
        || error "Echec de la creation de l'archive Seafile"
    local seafile_archive="${BACKUP_PATH}/seafile_data_${TIMESTAMP}.tar.gz"
    log "Archive Seafile creee: $(du -h "$seafile_archive" | cut -f1)"
    upload_to_r2 "$seafile_archive" "seafile/data"
    rm -f "$seafile_archive"
    log "Donnees Seafile sauvegardees"
}

# ===========================================
# Backup Vaultwarden
# ===========================================

backup_vaultwarden() {
    log "=== Backup Vaultwarden ==="

    if ! docker ps --format '{{.Names}}' | grep -qx vaultwarden; then
        log "ATTENTION: Conteneur vaultwarden non trouve, skip"
        return 0
    fi

    log "Archive des donnees Vaultwarden..."
    docker run --rm \
        -v vaultwarden_data:/source:ro \
        -v "${BACKUP_PATH}:/backup" \
        alpine tar czf "/backup/vaultwarden_${TIMESTAMP}.tar.gz" -C /source . \
        || error "Echec du backup Vaultwarden"
    local vw_archive="${BACKUP_PATH}/vaultwarden_${TIMESTAMP}.tar.gz"
    log "Archive Vaultwarden creee: $(du -h "$vw_archive" | cut -f1)"
    upload_to_r2 "$vw_archive" "vaultwarden"
    rm -f "$vw_archive"
    log "Donnees Vaultwarden sauvegardees"
}

# ===========================================
# Backup Paperless-ngx
# ===========================================

backup_paperless() {
    log "=== Backup Paperless-ngx ==="

    if ! docker ps --format '{{.Names}}' | grep -qx paperless; then
        log "ATTENTION: Conteneur paperless non trouve, skip"
        return 0
    fi

    log "Archive des donnees Paperless (data + media)..."
    docker run --rm \
        -v paperless_data:/data:ro \
        -v paperless_media:/media:ro \
        -v "${BACKUP_PATH}:/backup" \
        alpine sh -c "tar czf /backup/paperless_${TIMESTAMP}.tar.gz -C / data media" \
        || error "Echec du backup Paperless"
    local pl_archive="${BACKUP_PATH}/paperless_${TIMESTAMP}.tar.gz"
    log "Archive Paperless creee: $(du -h "$pl_archive" | cut -f1)"
    upload_to_r2 "$pl_archive" "paperless"
    rm -f "$pl_archive"
    log "Donnees Paperless sauvegardees"
}

# ===========================================
# Backup Jellyfin  (config + base : reglages, comptes, historique de lecture)
# ===========================================

backup_jellyfin() {
    log "=== Backup Jellyfin ==="

    if ! docker ps --format '{{.Names}}' | grep -qx jellyfin; then
        log "ATTENTION: Conteneur jellyfin non trouve, skip"
        return 0
    fi

    # Le volume jellyfin_cache n'est pas sauvegarde (regenerable).
    # On exclut aussi les logs et les transcodages en cours.
    log "Archive de la configuration Jellyfin..."
    docker run --rm \
        -v jellyfin_config:/source:ro \
        -v "${BACKUP_PATH}:/backup" \
        alpine tar czf "/backup/jellyfin_${TIMESTAMP}.tar.gz" \
        --exclude='./log' --exclude='./transcodes' \
        -C /source . \
        || error "Echec du backup Jellyfin"
    local jf_archive="${BACKUP_PATH}/jellyfin_${TIMESTAMP}.tar.gz"
    log "Archive Jellyfin creee: $(du -h "$jf_archive" | cut -f1)"
    upload_to_r2 "$jf_archive" "jellyfin"
    rm -f "$jf_archive"
    log "Configuration Jellyfin sauvegardee"
}

# ===========================================
# Nettoyage
# ===========================================

cleanup_local() {
    log "Nettoyage des backups locaux de plus de ${BACKUP_RETENTION_DAYS} jours..."
    find "$BACKUP_PATH" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" -o -name "*.log" \) \
        -mtime +"${BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
    log "Nettoyage local termine"
}

cleanup_r2() {
    log "Nettoyage des backups R2 de plus de ${BACKUP_RETENTION_DAYS} jours..."
    for path in "immich/database" "seafile/database" "seafile/data" "vaultwarden" "paperless" "jellyfin"; do
        rclone delete "${CRYPT_REMOTE}${path}/" \
            --min-age "${BACKUP_RETENTION_DAYS}d" \
            --log-file="$LOG_FILE" --log-level INFO 2>/dev/null || true
    done
    log "Nettoyage R2 termine"
}

# ===========================================
# Script principal
# ===========================================

main() {
    log "=========================================="
    log "Demarrage du backup Family Cloud"
    log "Mode: $BACKUP_MODE | Chiffrement: rclone crypt (${CRYPT_REMOTE})"
    log "=========================================="

    check_prerequisites

    case "$BACKUP_MODE" in
        full|--full)
            backup_immich
            backup_seafile
            backup_vaultwarden
            backup_paperless
            backup_jellyfin
            ;;
        immich|--immich)         backup_immich ;;
        seafile|--seafile)       backup_seafile ;;
        vaultwarden|--vaultwarden) backup_vaultwarden ;;
        paperless|--paperless)   backup_paperless ;;
        jellyfin|--jellyfin)     backup_jellyfin ;;
        *)
            log "Mode non reconnu: $BACKUP_MODE"
            log "Modes disponibles: full, immich, seafile, vaultwarden, paperless, jellyfin"
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
