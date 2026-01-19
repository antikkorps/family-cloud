#!/bin/bash
# ===========================================
# Script de Configuration Post-Installation Nextcloud
# ===========================================
# Usage: ./post-install.sh
#
# À exécuter une fois après le premier démarrage de Nextcloud.
# Configure automatiquement :
# - Indices de base de données
# - Cache Redis
# - Preview Generator
# - Imaginary
# - Paramètres régionaux
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

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ===========================================
# Fonctions
# ===========================================

log() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

occ() {
    docker exec -u www-data nextcloud-app php occ "$@"
}

wait_for_nextcloud() {
    echo "Attente du démarrage de Nextcloud..."
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if docker exec nextcloud-app php -v &>/dev/null; then
            # Vérifier que Nextcloud est installé
            if occ status 2>/dev/null | grep -q "installed: true"; then
                log "Nextcloud est prêt"
                return 0
            fi
        fi
        echo "  Tentative $attempt/$max_attempts..."
        sleep 10
        ((attempt++))
    done

    error "Nextcloud n'a pas démarré dans le temps imparti"
}

# ===========================================
# Configuration de la base de données
# ===========================================
configure_database() {
    echo ""
    echo "=== Configuration de la base de données ==="

    log "Ajout des indices manquants..."
    occ db:add-missing-indices

    log "Conversion des colonnes bigint..."
    occ db:convert-filecache-bigint --no-interaction || warn "Conversion bigint déjà effectuée"
}

# ===========================================
# Configuration du cache Redis
# ===========================================
configure_redis() {
    echo ""
    echo "=== Configuration du cache Redis ==="

    log "Configuration du cache local (APCu)..."
    occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu"

    log "Configuration du cache distribué (Redis)..."
    occ config:system:set memcache.distributed --value="\\OC\\Memcache\\Redis"

    log "Configuration du cache de verrouillage (Redis)..."
    occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis"

    log "Configuration de la connexion Redis..."
    occ config:system:set redis host --value="redis"
    occ config:system:set redis port --value="6379" --type=integer
    occ config:system:set redis password --value="${REDIS_PASSWORD}"

    log "Cache Redis configuré"
}

# ===========================================
# Configuration d'Imaginary
# ===========================================
configure_imaginary() {
    echo ""
    echo "=== Configuration d'Imaginary ==="

    log "Activation du provider Imaginary pour les previews..."
    occ config:system:set enabledPreviewProviders 0 --value="OC\\Preview\\Imaginary"
    occ config:system:set enabledPreviewProviders 1 --value="OC\\Preview\\PNG"
    occ config:system:set enabledPreviewProviders 2 --value="OC\\Preview\\JPEG"
    occ config:system:set enabledPreviewProviders 3 --value="OC\\Preview\\GIF"
    occ config:system:set enabledPreviewProviders 4 --value="OC\\Preview\\BMP"
    occ config:system:set enabledPreviewProviders 5 --value="OC\\Preview\\HEIC"
    occ config:system:set enabledPreviewProviders 6 --value="OC\\Preview\\Movie"
    occ config:system:set enabledPreviewProviders 7 --value="OC\\Preview\\MP4"

    log "Configuration de l'URL Imaginary..."
    occ config:system:set preview_imaginary_url --value="http://imaginary:9000"

    log "Imaginary configuré"
}

# ===========================================
# Configuration du Preview Generator
# ===========================================
configure_preview_generator() {
    echo ""
    echo "=== Configuration du Preview Generator ==="

    # Vérifier si l'app est installée
    if occ app:list | grep -q "previewgenerator"; then
        log "Preview Generator détecté"

        log "Configuration des tailles de miniatures..."
        occ config:app:set previewgenerator squareSizes --value="32 256"
        occ config:app:set previewgenerator widthSizes --value="256 384"
        occ config:app:set previewgenerator heightSizes --value="256"

        log "Preview Generator configuré"
        warn "Pensez à exécuter: docker exec -u www-data nextcloud-app php occ preview:generate-all"
    else
        warn "Preview Generator n'est pas installé"
        warn "Installez-le via l'interface admin puis relancez ce script"
    fi
}

# ===========================================
# Configuration des paramètres régionaux
# ===========================================
configure_regional() {
    echo ""
    echo "=== Configuration des paramètres régionaux ==="

    log "Configuration de la région téléphone (FR)..."
    occ config:system:set default_phone_region --value="FR"

    log "Configuration du fuseau horaire..."
    occ config:system:set logtimezone --value="${TZ:-Europe/Paris}"

    log "Paramètres régionaux configurés"
}

# ===========================================
# Configuration du mode de tâches cron
# ===========================================
configure_cron() {
    echo ""
    echo "=== Configuration du mode Cron ==="

    log "Activation du mode cron pour les tâches de fond..."
    occ background:cron

    log "Mode cron activé"
}

# ===========================================
# Configuration de sécurité
# ===========================================
configure_security() {
    echo ""
    echo "=== Configuration de sécurité ==="

    log "Désactivation des hints de mot de passe..."
    occ config:system:set lost_password_link --value="disabled"

    log "Configuration du nombre max de tentatives de login..."
    occ config:system:set auth.bruteforce.protection.enabled --value="true" --type=boolean

    log "Sécurité configurée"
}

# ===========================================
# Affichage du résumé
# ===========================================
show_summary() {
    echo ""
    echo "==========================================="
    echo -e "${GREEN}Configuration terminée avec succès!${NC}"
    echo "==========================================="
    echo ""
    echo "Prochaines étapes recommandées :"
    echo "  1. Installer les apps via l'interface admin :"
    echo "     - Memories"
    echo "     - Preview Generator"
    echo "     - Calendar / Contacts (si besoin)"
    echo ""
    echo "  2. Configurer les tâches cron sur l'hôte :"
    echo "     crontab -e"
    echo "     # Ajouter :"
    echo "     */10 * * * * docker exec -u www-data nextcloud-app php occ preview:pre-generate"
    echo "     0 * * * * docker exec -u www-data nextcloud-app php occ memories:index"
    echo ""
    echo "  3. Générer les previews existantes (si des fichiers sont déjà présents) :"
    echo "     docker exec -u www-data nextcloud-app php occ preview:generate-all -vvv"
    echo ""
}

# ===========================================
# Script principal
# ===========================================

main() {
    echo "==========================================="
    echo "  Configuration Post-Installation Nextcloud"
    echo "==========================================="

    wait_for_nextcloud
    configure_database
    configure_redis
    configure_imaginary
    configure_preview_generator
    configure_regional
    configure_cron
    configure_security
    show_summary
}

# Exécuter
main "$@"
