#!/bin/bash
# ===========================================
# Script d'installation et configuration de Fail2ban
# ===========================================
# Usage: sudo ./setup-fail2ban.sh
# ===========================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FAIL2BAN_DIR="${PROJECT_DIR}/fail2ban"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[✓]${NC} $1"
}

error() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

# Vérifier les droits root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en root (sudo)"
fi

echo "=== Installation de Fail2ban ==="

# Installer fail2ban
if ! command -v fail2ban-client &> /dev/null; then
    log "Installation de fail2ban..."
    apt update
    apt install -y fail2ban
else
    log "Fail2ban déjà installé"
fi

# Copier les fichiers de configuration
log "Copie de la configuration jail.local..."
cp "${FAIL2BAN_DIR}/jail.local" /etc/fail2ban/jail.local

log "Copie du filtre Nextcloud..."
cp "${FAIL2BAN_DIR}/nextcloud.conf" /etc/fail2ban/filter.d/nextcloud.conf

# Vérifier que le fichier de log Nextcloud existe
NC_LOG="/var/lib/docker/volumes/nextcloud_www/_data/data/nextcloud.log"
if [[ ! -f "$NC_LOG" ]]; then
    log "Création du fichier de log Nextcloud..."
    mkdir -p "$(dirname "$NC_LOG")"
    touch "$NC_LOG"
    chown 33:33 "$NC_LOG"  # www-data
fi

# Redémarrer fail2ban
log "Redémarrage de fail2ban..."
systemctl restart fail2ban
systemctl enable fail2ban

# Vérifier le statut
log "Vérification du statut..."
fail2ban-client status

echo ""
echo "=== Fail2ban configuré avec succès ==="
echo ""
echo "Commandes utiles :"
echo "  fail2ban-client status              # Voir les jails actives"
echo "  fail2ban-client status nextcloud    # Détails de la jail Nextcloud"
echo "  fail2ban-client status sshd         # Détails de la jail SSH"
echo "  fail2ban-client set nextcloud unbanip <IP>  # Débannir une IP"
echo ""
