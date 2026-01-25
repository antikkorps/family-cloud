#!/bin/bash
# ===========================================
# Configuration automatique de rclone pour R2
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
    echo "ERREUR: Fichier .env non trouve dans ${PROJECT_DIR}"
    exit 1
fi

# Verifier que rclone est installe
if ! command -v rclone &> /dev/null; then
    echo "ERREUR: rclone n'est pas installe"
    echo "Installez-le avec: sudo apt install rclone"
    echo "Ou: curl https://rclone.org/install.sh | sudo bash"
    exit 1
fi

# Verifier les variables R2
if [[ -z "${R2_ACCESS_KEY_ID:-}" ]] || [[ -z "${R2_SECRET_ACCESS_KEY:-}" ]] || [[ -z "${R2_ENDPOINT:-}" ]]; then
    echo "ERREUR: Variables R2 manquantes dans .env"
    echo "Requis: R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT"
    exit 1
fi

RCLONE_CONFIG="${HOME}/.config/rclone/rclone.conf"
mkdir -p "$(dirname "$RCLONE_CONFIG")"

# Creer ou mettre a jour la configuration rclone
echo "Configuration de rclone pour Cloudflare R2..."

# Supprimer l'ancienne config r2 si elle existe
if grep -q "^\[r2\]" "$RCLONE_CONFIG" 2>/dev/null; then
    echo "Mise a jour de la configuration existante..."
    # Utiliser sed pour supprimer la section [r2] existante
    sed -i '/^\[r2\]/,/^\[/{ /^\[r2\]/d; /^\[/!d; }' "$RCLONE_CONFIG"
fi

# Ajouter la nouvelle configuration
cat >> "$RCLONE_CONFIG" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = ${R2_ENDPOINT}
acl = private

EOF

echo "Configuration rclone creee dans: $RCLONE_CONFIG"

# Test de connexion
echo ""
echo "Test de connexion a R2..."
if rclone lsd r2: 2>/dev/null; then
    echo "Connexion R2 OK!"
    echo ""
    echo "Buckets disponibles:"
    rclone lsd r2:
else
    echo "ERREUR: Impossible de se connecter a R2"
    echo "Verifiez vos credentials dans .env"
    exit 1
fi

# Verifier/creer le bucket
echo ""
echo "Verification du bucket ${R2_BUCKET_NAME}..."
if rclone lsd "r2:${R2_BUCKET_NAME}" 2>/dev/null; then
    echo "Bucket ${R2_BUCKET_NAME} accessible!"
else
    echo "Bucket ${R2_BUCKET_NAME} non trouve ou inaccessible"
    echo "Creez-le dans la console Cloudflare R2 si necessaire"
fi

echo ""
echo "=== Configuration terminee ==="
echo "Vous pouvez maintenant executer: ./scripts/backup.sh"
