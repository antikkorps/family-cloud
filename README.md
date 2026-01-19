# Nextcloud sur Hetzner VPS avec Docker

Infrastructure IaC pour héberger Nextcloud sur un VPS Hetzner (CX23) avec Docker et Caddy.

## Stack Technique

| Composant | Technologie |
|-----------|-------------|
| OS | Debian 12 / Ubuntu 22.04 |
| Orchestration | Docker Compose |
| Reverse Proxy | Caddy (HTTPS automatique) |
| Base de données | PostgreSQL 16 |
| Cache | Redis 7 |
| Stockage | Volume Hetzner 100 Go |
| Backup | Rclone → Cloudflare R2 |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet                              │
└─────────────────────────┬───────────────────────────────────┘
                          │ :80/:443
┌─────────────────────────▼───────────────────────────────────┐
│                    Caddy (Reverse Proxy)                     │
│                    - HTTPS automatique                       │
│                    - Headers sécurité                        │
└─────────────────────────┬───────────────────────────────────┘
                          │ :9000 (FastCGI)
┌─────────────────────────▼───────────────────────────────────┐
│               Réseau Docker Backend (interne)                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   Nextcloud  │  │  PostgreSQL  │  │    Redis     │       │
│  │     FPM      │  │      16      │  │      7       │       │
│  └──────┬───────┘  └──────────────┘  └──────────────┘       │
│         │                                                    │
└─────────┼────────────────────────────────────────────────────┘
          │
┌─────────▼────────────────────────────────────────────────────┐
│              Volume Hetzner (/mnt/nextcloud_data)            │
│                        100 Go                                 │
└──────────────────────────────────────────────────────────────┘
```

## Prérequis

- VPS Hetzner CX23 (2 vCPU, 4 Go RAM)
- Volume Hetzner 100 Go attaché au VPS
- Nom de domaine pointant vers l'IP du VPS
- Compte Cloudflare avec R2 activé (pour les backups)

---

## Guide de Déploiement

### 1. Préparation du VPS

Connectez-vous en SSH à votre VPS et installez les dépendances :

```bash
# Mise à jour du système
sudo apt update && sudo apt upgrade -y

# Installation de Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Installation de Rclone
sudo apt install rclone -y

# Installation d'outils utiles
sudo apt install git htop ncdu -y

# Déconnexion/Reconnexion pour appliquer le groupe docker
exit
```

### 2. Formatage et Montage du Volume Hetzner

Le volume doit être attaché via le panneau Hetzner Cloud avant ces étapes.

```bash
# Identifier le volume (généralement /dev/sdb ou /dev/disk/by-id/scsi-0HC_Volume_*)
lsblk

# Formater le volume (ATTENTION: efface toutes les données!)
sudo mkfs.ext4 -L nextcloud_data /dev/sdb

# Créer le point de montage
sudo mkdir -p /mnt/nextcloud_data

# Monter le volume
sudo mount /dev/sdb /mnt/nextcloud_data

# Ajouter au fstab pour le montage automatique
echo '/dev/disk/by-label/nextcloud_data /mnt/nextcloud_data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab

# Vérifier le montage
df -h /mnt/nextcloud_data

# Définir les permissions
sudo chown -R 33:33 /mnt/nextcloud_data  # UID 33 = www-data dans le conteneur
```

### 3. Configuration de Rclone pour Cloudflare R2

```bash
# Configurer Rclone
rclone config

# Suivre les étapes:
# n) New remote
# name> r2
# Storage> s3
# provider> Cloudflare
# access_key_id> [Votre R2 Access Key ID]
# secret_access_key> [Votre R2 Secret Access Key]
# endpoint> https://[ACCOUNT_ID].r2.cloudflarestorage.com
# Laisser les autres options par défaut

# Tester la connexion
rclone lsd r2:

# Créer le bucket de backup
rclone mkdir r2:nextcloud-backup
```

### 4. Cloner et Configurer le Projet

```bash
# Cloner le dépôt
cd ~
git clone https://github.com/votre-user/nextcloud.git
cd nextcloud

# Copier et éditer la configuration
cp .env.example .env
nano .env

# Générer des mots de passe sécurisés
echo "POSTGRES_PASSWORD=$(openssl rand -base64 32)"
echo "REDIS_PASSWORD=$(openssl rand -base64 32)"
echo "NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -base64 24)"
```

### 5. Lancer le Projet

```bash
# Rendre les scripts exécutables
chmod +x scripts/*.sh

# Lancer les conteneurs
docker compose up -d

# Suivre les logs
docker compose logs -f

# Vérifier que tout fonctionne
docker compose ps
```

### 6. Configuration Post-Installation

Une fois Nextcloud accessible, exécutez ces commandes :

```bash
# Configurer les indices de la base de données
docker exec -u www-data nextcloud-app php occ db:add-missing-indices

# Configurer la région téléphone (pour la validation)
docker exec -u www-data nextcloud-app php occ config:system:set default_phone_region --value="FR"

# Configurer le cache Redis
docker exec -u www-data nextcloud-app php occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu"
docker exec -u www-data nextcloud-app php occ config:system:set memcache.distributed --value="\\OC\\Memcache\\Redis"
docker exec -u www-data nextcloud-app php occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis"
docker exec -u www-data nextcloud-app php occ config:system:set redis host --value="redis"
docker exec -u www-data nextcloud-app php occ config:system:set redis port --value="6379"
docker exec -u www-data nextcloud-app php occ config:system:set redis password --value="VOTRE_REDIS_PASSWORD"

# Configurer le cron en mode background
docker exec -u www-data nextcloud-app php occ background:cron
```

---

## Optimisation Photos avec Memories

### Installation de l'Application Memories

1. Connectez-vous à Nextcloud en tant qu'admin
2. Allez dans **Apps** → **Multimédia**
3. Installez **Memories** et **Preview Generator**

### Configuration du Preview Generator

```bash
# Configurer les tailles de miniatures
docker exec -u www-data nextcloud-app php occ config:app:set previewgenerator squareSizes --value="32 256"
docker exec -u www-data nextcloud-app php occ config:app:set previewgenerator widthSizes --value="256 384"
docker exec -u www-data nextcloud-app php occ config:app:set previewgenerator heightSizes --value="256"

# Configurer les formats de preview
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 0 --value="OC\\Preview\\PNG"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 1 --value="OC\\Preview\\JPEG"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 2 --value="OC\\Preview\\GIF"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 3 --value="OC\\Preview\\HEIC"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 4 --value="OC\\Preview\\MP4"
docker exec -u www-data nextcloud-app php occ config:system:set enabledPreviewProviders 5 --value="OC\\Preview\\Movie"

# Générer les previews existantes (peut prendre du temps)
docker exec -u www-data nextcloud-app php occ preview:generate-all -vvv
```

### Tâche Cron pour la Génération Automatique

Ajoutez cette tâche cron sur le serveur hôte :

```bash
# Éditer le crontab
crontab -e

# Ajouter ces lignes :
# Génération des miniatures toutes les 10 minutes
*/10 * * * * docker exec -u www-data nextcloud-app php occ preview:pre-generate >> /var/log/nextcloud-preview.log 2>&1

# Indexation Memories une fois par heure
0 * * * * docker exec -u www-data nextcloud-app php occ memories:index >> /var/log/nextcloud-memories.log 2>&1
```

---

## Backups

### Backup Manuel

```bash
# Backup complet
./scripts/backup.sh

# Backup uniquement la base de données
./scripts/backup.sh --db-only

# Backup uniquement les données
./scripts/backup.sh --data-only
```

### Backup Automatique (Cron)

```bash
# Éditer le crontab
crontab -e

# Ajouter :
# Backup complet tous les jours à 3h du matin
0 3 * * * /home/user/nextcloud/scripts/backup.sh >> /var/log/nextcloud-backup.log 2>&1
```

### Restauration

```bash
# Lister les backups disponibles
./scripts/restore.sh --list

# Restaurer la base de données
./scripts/restore.sh --db 20240115

# Restaurer les données
./scripts/restore.sh --data

# Restaurer la configuration
./scripts/restore.sh --config
```

---

## Commandes Utiles

### Docker

```bash
# Voir les logs
docker compose logs -f [service]

# Redémarrer un service
docker compose restart nextcloud

# Recréer les conteneurs
docker compose up -d --force-recreate

# Mettre à jour les images
docker compose pull && docker compose up -d
```

### Nextcloud OCC

```bash
# Mode maintenance
docker exec -u www-data nextcloud-app php occ maintenance:mode --on
docker exec -u www-data nextcloud-app php occ maintenance:mode --off

# Scanner les fichiers
docker exec -u www-data nextcloud-app php occ files:scan --all

# Réparer la base de données
docker exec -u www-data nextcloud-app php occ maintenance:repair

# Mettre à jour
docker exec -u www-data nextcloud-app php occ upgrade
```

### Surveillance

```bash
# Espace disque
df -h /mnt/nextcloud_data

# Utilisation mémoire/CPU
htop

# Taille des données Nextcloud
sudo ncdu /mnt/nextcloud_data
```

---

## Structure du Projet

```
nextcloud/
├── .github/
│   └── workflows/
│       └── deploy.yml      # GitHub Action pour déploiement auto
├── docker-compose.yml      # Orchestration des services
├── .env.example            # Template des variables d'environnement
├── .env                    # Variables d'environnement (non versionné)
├── .gitignore
├── README.md
├── caddy/
│   └── Caddyfile           # Configuration du reverse proxy
├── nextcloud/
│   └── custom.ini          # Configuration PHP personnalisée
├── scripts/
│   ├── backup.sh           # Script de backup vers R2
│   └── restore.sh          # Script de restauration
└── backups/                # Dumps locaux temporaires (non versionné)
```

---

## CI/CD - Déploiement Automatique

Le projet inclut une GitHub Action qui déploie automatiquement sur le VPS à chaque PR mergée sur `main`.

### Configuration des Secrets GitHub

**Settings** → **Secrets and variables** → **Actions** → **New repository secret**

| Secret | Description | Exemple |
|--------|-------------|---------|
| `VPS_HOST` | IP ou hostname du VPS | `123.45.67.89` |
| `VPS_USER` | Utilisateur SSH | `deploy` |
| `VPS_SSH_KEY` | Clé privée SSH (contenu complet) | `-----BEGIN OPENSSH...` |
| `VPS_PORT` | Port SSH (optionnel, défaut: 22) | `22` |
| `PROJECT_PATH` | Chemin du projet sur le VPS (optionnel) | `~/nextcloud` |

### Préparation du VPS

```bash
# Créer un utilisateur dédié au déploiement
sudo adduser --disabled-password deploy
sudo usermod -aG docker deploy

# Générer une clé SSH pour GitHub Actions
sudo -u deploy ssh-keygen -t ed25519 -C "github-actions" -f /home/deploy/.ssh/github_actions -N ""

# Autoriser la clé
sudo -u deploy bash -c 'cat ~/.ssh/github_actions.pub >> ~/.ssh/authorized_keys'

# Afficher la clé privée (à copier dans VPS_SSH_KEY)
sudo cat /home/deploy/.ssh/github_actions

# Cloner le projet
sudo -u deploy git clone https://github.com/votre-user/nextcloud.git /home/deploy/nextcloud
```

### Fonctionnement

Déclenchement :
- **Automatique** : à chaque PR mergée sur `main`
- **Manuel** : via l'onglet Actions de GitHub

Actions effectuées :
1. Connexion SSH au VPS
2. Pull des derniers changements
3. Redémarrage intelligent (uniquement si docker-compose.yml ou configs modifiés)

---

## Sécurité

- Réseau backend Docker **isolé** (internal: true)
- HTTPS automatique via Let's Encrypt
- Headers de sécurité (HSTS, CSP, etc.)
- Mots de passe générés aléatoirement
- Pas d'exposition directe de PostgreSQL/Redis

### Durcissement Supplémentaire

```bash
# Configurer le pare-feu UFW
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable

# Désactiver l'accès root SSH
sudo sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

---

## Dépannage

### Nextcloud inaccessible

```bash
# Vérifier les conteneurs
docker compose ps

# Vérifier les logs Caddy
docker compose logs caddy

# Vérifier les logs Nextcloud
docker compose logs nextcloud
```

### Problèmes de permissions

```bash
# Corriger les permissions des données
sudo chown -R 33:33 /mnt/nextcloud_data
docker exec nextcloud-app chown -R www-data:www-data /var/www/html
```

### Base de données corrompue

```bash
# Réparer les indices
docker exec -u www-data nextcloud-app php occ db:add-missing-indices
docker exec -u www-data nextcloud-app php occ db:convert-filecache-bigint
```

---

## Licence

MIT
