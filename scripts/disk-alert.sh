#!/bin/bash
# ===========================================
# Script d'alerte disque
# ===========================================
# Envoie une alerte si le disque dépasse le seuil
# Usage: ./disk-alert.sh [seuil_pourcentage]
#
# Pour recevoir par email, configurer msmtp ou ssmtp
# puis décommenter la ligne mail ci-dessous
# ===========================================

set -euo pipefail

THRESHOLD="${1:-80}"
DISK_PATH="/mnt/stockage"
LOG_FILE="/var/log/family-cloud-disk-alert.log"

# Obtenir le pourcentage d'utilisation
USAGE=$(df -h "$DISK_PATH" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')

if [[ -z "$USAGE" ]]; then
    echo "[$(date)] ERREUR: Impossible de lire l'utilisation de $DISK_PATH" >> "$LOG_FILE"
    exit 1
fi

TOTAL=$(df -h "$DISK_PATH" | awk 'NR==2 {print $2}')
USED=$(df -h "$DISK_PATH" | awk 'NR==2 {print $3}')
AVAIL=$(df -h "$DISK_PATH" | awk 'NR==2 {print $4}')

if [[ "$USAGE" -ge "$THRESHOLD" ]]; then
    MESSAGE="ALERTE DISQUE Family Cloud

Utilisation: ${USAGE}% (seuil: ${THRESHOLD}%)
Chemin: $DISK_PATH
Total: $TOTAL
Utilisé: $USED
Disponible: $AVAIL

Actions recommandées:
1. Nettoyer Docker: docker system prune -a
2. Vérifier les gros fichiers: du -sh /mnt/stockage/family_cloud/*
3. Consulter: /srv/family_cloud/docs/MAINTENANCE.md
"

    echo "[$(date)] ALERTE: Disque à ${USAGE}%" >> "$LOG_FILE"
    echo "$MESSAGE"

    # Décommenter pour envoyer par email (nécessite msmtp ou ssmtp configuré)
    # echo "$MESSAGE" | mail -s "ALERTE: Disque Family Cloud à ${USAGE}%" votre@email.com

    # Notification Gotify (décommenter et configurer si utilisé)
    # curl -X POST "https://gotify.example.com/message?token=TOKEN" \
    #     -F "title=Alerte Disque Family Cloud" \
    #     -F "message=$MESSAGE" \
    #     -F "priority=8"

    exit 1
else
    echo "[$(date)] OK: Disque à ${USAGE}%" >> "$LOG_FILE"
    exit 0
fi
