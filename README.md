# Nextcloud Auto-Hébergé (Dell Optiplex + Cloudflare Tunnel)

Infrastructure IaC pour héberger Nextcloud sur un serveur local (Dell Optiplex) avec Docker et Cloudflare Tunnel pour l'accès externe sécurisé.

## Stack Technique

| Composant | Technologie |
|-----------|-------------|
| OS | Debian 12 / Ubuntu 22.04 |
| Orchestration | Docker Compose |
| Accès externe | Cloudflare Tunnel (Zero Trust) |
| Reverse Proxy | Caddy (HTTP local) |
| Base de données | PostgreSQL 16 |
| Cache | Redis 7 |
| Stockage | SSD local |
| Backup | Rclone → Cloudflare R2 |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Internet                              │
└─────────────────────────┬───────────────────────────────────┘
                          │ HTTPS (géré par Cloudflare)
┌─────────────────────────▼───────────────────────────────────┐
│               Cloudflare Tunnel (cloudflared)                │
│               - Connexion sortante uniquement                │
│               - Pas de port ouvert sur le routeur            │
└─────────────────────────┬───────────────────────────────────┘
                          │ HTTP interne
┌─────────────────────────▼───────────────────────────────────┐
│                    Caddy (Reverse Proxy)                     │
│                    - HTTP local (port 80)                    │
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
│                     SSD Local (DATA_PATH)                    │
└──────────────────────────────────────────────────────────────┘
```

## Prérequis

- Serveur local (ex: Dell Optiplex, mini PC, ou autre)
- Stockage suffisant (SSD recommandé)
- Nom de domaine géré par Cloudflare
- Compte Cloudflare avec :
  - Zero Trust (gratuit) pour le tunnel
  - R2 activé (pour les backups)

---

## Guide de Déploiement

### 1. Préparation du Serveur

Installez les dépendances sur votre serveur :

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

### 2. Configuration du Cloudflare Tunnel

Le tunnel permet d'exposer Nextcloud sur internet sans ouvrir de port sur votre routeur.

#### Création du Tunnel

1. Connectez-vous à [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
2. Allez dans **Networks** → **Tunnels**
3. Cliquez sur **Create a tunnel**
4. Choisissez **Cloudflared** comme type
5. Donnez un nom au tunnel (ex: `nextcloud-home`)
6. Copiez le **token** affiché (il commence par `eyJ...`)

#### Configuration du DNS

Dans la configuration du tunnel, ajoutez un **Public Hostname** :
- **Subdomain** : `nextcloud` (ou autre)
- **Domain** : votre domaine Cloudflare
- **Service** : `http://caddy:80`

#### Préparation du Répertoire de Données

```bash
# Créer le répertoire pour les données Nextcloud
mkdir -p ~/nextcloud/data

# Définir les permissions
sudo chown -R 33:33 ~/nextcloud/data  # UID 33 = www-data dans le conteneur
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

# IMPORTANT: Restreindre les permissions du fichier .env
chmod 600 .env

nano .env

# Remplir les variables importantes :
# - CLOUDFLARE_TUNNEL_TOKEN : le token récupéré à l'étape 2
# - DATA_PATH : chemin vers les données (ex: /home/user/nextcloud/data)

# Générer des mots de passe sécurisés
echo "POSTGRES_PASSWORD=$(openssl rand -base64 32)"
echo "REDIS_PASSWORD=$(openssl rand -base64 32)"
echo "NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -base64 24)"
echo "BACKUP_ENCRYPTION_KEY=$(openssl rand -base64 32)"

# Installer age pour le chiffrement des backups
sudo apt install age -y
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

Une fois Nextcloud accessible, exécutez le script de configuration automatique :

```bash
./scripts/post-install.sh
```

Ce script configure automatiquement :
- Indices de base de données
- Cache Redis (APCu + Redis)
- Imaginary (traitement d'images accéléré)
- Preview Generator
- Paramètres régionaux (FR)
- Mode cron
- Sécurité (protection brute force)

Voir le script pour les détails ou pour une configuration manuelle.

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

### Disaster Recovery (Crash Total)

En cas de perte totale du serveur, voici la procédure pour tout reconstruire depuis zéro.

#### Prérequis à avoir sous la main

- Accès au compte Cloudflare (Zero Trust + R2)
- La clé `BACKUP_ENCRYPTION_KEY` (si chiffrement activé) - **à conserver dans un password manager**
- Les credentials R2 (Access Key ID + Secret)

#### Étape 1 : Préparer le nouveau serveur

```bash
# Installer les dépendances
sudo apt update && sudo apt upgrade -y
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
sudo apt install rclone git age -y

# Se reconnecter pour appliquer le groupe docker
exit
```

#### Étape 2 : Configurer Rclone pour accéder à R2

```bash
rclone config

# Créer le remote "r2" avec vos credentials Cloudflare R2
# (voir section "Configuration de Rclone pour Cloudflare R2")

# Vérifier l'accès aux backups
rclone ls r2:nextcloud-backup/database/ | head -5
```

#### Étape 3 : Cloner le projet et configurer

```bash
cd ~
git clone https://github.com/votre-user/nextcloud.git
cd nextcloud

# Créer le .env avec les mêmes valeurs qu'avant
cp .env.example .env
chmod 600 .env
nano .env

# IMPORTANT: Utiliser la même BACKUP_ENCRYPTION_KEY qu'avant !
# Créer le répertoire de données
mkdir -p ~/nextcloud/data
sudo chown -R 33:33 ~/nextcloud/data
```

#### Étape 4 : Récupérer le token Cloudflare Tunnel

1. Aller sur [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
2. **Networks** → **Tunnels** → Sélectionner votre tunnel
3. **Configure** → Copier le token
4. Mettre à jour `CLOUDFLARE_TUNNEL_TOKEN` dans `.env`

#### Étape 5 : Lancer l'infrastructure

```bash
# Lancer les conteneurs (sans données)
docker compose up -d

# Attendre que PostgreSQL soit prêt
sleep 30
docker compose ps
```

#### Étape 6 : Restaurer les données

```bash
# Restaurer la base de données (prend le backup le plus récent)
./scripts/restore.sh --db

# Restaurer les fichiers utilisateurs (peut prendre du temps selon la taille)
./scripts/restore.sh --data

# Restaurer la configuration Nextcloud
./scripts/restore.sh --config

# Redémarrer pour appliquer la config
docker compose restart
```

#### Étape 7 : Vérifications post-restauration

```bash
# Vérifier que Nextcloud fonctionne
docker compose logs nextcloud | tail -20

# Scanner les fichiers pour s'assurer que tout est indexé
docker exec -u www-data nextcloud-app php occ files:scan --all

# Réparer les éventuels problèmes
docker exec -u www-data nextcloud-app php occ maintenance:repair
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
# Espace disque (adapter DATA_PATH selon votre configuration)
df -h ~/nextcloud/data

# Utilisation mémoire/CPU
htop

# Taille des données Nextcloud
sudo ncdu ~/nextcloud/data
```

---

## Structure du Projet

```
nextcloud/
├── docker-compose.yml      # Orchestration des services (inclut cloudflared)
├── .env.example            # Template des variables d'environnement
├── .env                    # Variables d'environnement (non versionné)
├── .gitignore
├── LICENSE                 # Licence MIT
├── README.md
├── caddy/
│   └── Caddyfile           # Configuration du reverse proxy
├── fail2ban/
│   ├── jail.local          # Configuration des jails
│   └── nextcloud.conf      # Filtre pour Nextcloud
├── nextcloud/
│   └── custom.ini          # Configuration PHP personnalisée
├── scripts/
│   ├── backup.sh           # Script de backup chiffré vers R2
│   ├── restore.sh          # Script de restauration
│   ├── post-install.sh     # Configuration post-installation
│   ├── setup-fail2ban.sh   # Installation de Fail2ban
│   └── health-check.sh     # Génère status.json pour monitoring
└── backups/                # Dumps locaux temporaires (non versionné)
```

---

## Déploiement

Le déploiement se fait manuellement sur le serveur local.

```bash
cd ~/nextcloud

# Récupérer les dernières modifications
git pull origin main

# Si docker-compose.yml a changé, recréer les conteneurs
docker compose up -d --force-recreate

# Sinon, simple redémarrage si besoin
docker compose restart
```

---

## Sécurité

- **Aucun port ouvert** sur le routeur (tunnel sortant uniquement)
- HTTPS géré par Cloudflare (certificat automatique)
- Réseau backend Docker **isolé** (internal: true)
- Headers de sécurité (HSTS, CSP, etc.)
- IP réelle transmise via header `CF-Connecting-IP`
- Mots de passe générés aléatoirement
- Pas d'exposition directe de PostgreSQL/Redis
- Fail2ban pour la protection brute force

### Fail2ban (Protection Brute Force)

Le projet inclut une configuration Fail2ban pour protéger SSH et Nextcloud.

```bash
# Installation automatique
sudo ./scripts/setup-fail2ban.sh

# Ou installation manuelle
sudo apt install fail2ban
sudo cp fail2ban/jail.local /etc/fail2ban/jail.local
sudo cp fail2ban/nextcloud.conf /etc/fail2ban/filter.d/nextcloud.conf
sudo systemctl restart fail2ban
```

**Commandes utiles :**
```bash
# Voir les jails actives
fail2ban-client status

# Détails d'une jail
fail2ban-client status nextcloud

# Débannir une IP
fail2ban-client set nextcloud unbanip 1.2.3.4
```

### Authentification à Deux Facteurs (2FA)

Fortement recommandé pour sécuriser les comptes utilisateurs :

1. Connectez-vous en tant qu'admin
2. **Apps** → **Sécurité** → Installer **Two-Factor TOTP Provider**
3. Chaque utilisateur peut activer le 2FA dans **Paramètres** → **Sécurité**

Apps 2FA recommandées : Aegis (Android), Raivo OTP (iOS), Bitwarden.

### Chiffrement des Backups (optionnel)

Cloudflare R2 chiffre déjà les données au repos. Le chiffrement côté client est une couche supplémentaire, utile si :
- Vous ne faites pas confiance à Cloudflare
- Vous voulez une protection si vos credentials R2 fuitent

**Sans chiffrement côté client** (par défaut) : laisser `BACKUP_ENCRYPTION_KEY=` vide.

**Avec chiffrement** :
```bash
# Générer et stocker dans un password manager
openssl rand -base64 32

# Ajouter dans .env
BACKUP_ENCRYPTION_KEY=votre_cle
```

---

## Monitoring

### Endpoint /health

Caddy expose un endpoint `/health` qui retourne `OK` si le service est accessible :

```bash
curl https://nextcloud.mondomaine.com/health
```

### Script de Health Check

Le script `health-check.sh` génère un fichier JSON avec l'état complet :

```bash
# Exécution manuelle
./scripts/health-check.sh

# Configurer en cron (toutes les 5 minutes)
*/5 * * * * /path/to/scripts/health-check.sh
```

Exemple de sortie (`/var/log/nextcloud-status.json`) :
```json
{
  "timestamp": "2024-01-15T10:30:00Z",
  "status": "ok",
  "services": {
    "nextcloud": "ok",
    "postgres": "ok",
    "redis": "ok",
    "caddy": "ok"
  },
  "metrics": {
    "disk_data_percent": 45,
    "memory_percent": 62,
    "load_average": 0.5
  },
  "backup": {
    "last": "20240115_030000"
  },
  "alerts": []
}
```

### Monitoring depuis un serveur distant

Sur votre serveur de monitoring :

```bash
#!/bin/bash
# Script simple de monitoring
RESPONSE=$(curl -sf https://nextcloud.mondomaine.com/health)
if [[ $? -ne 0 ]]; then
    echo "ALERTE: Nextcloud inaccessible" | mail -s "Nextcloud DOWN" admin@example.com
fi
```

---

### Durcissement Supplémentaire

```bash
# Configurer le pare-feu UFW
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
# Pas besoin d'ouvrir 80/443 : le tunnel Cloudflare utilise des connexions sortantes
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

# Vérifier le tunnel Cloudflare
docker compose logs cloudflared

# Vérifier les logs Caddy
docker compose logs caddy

# Vérifier les logs Nextcloud
docker compose logs nextcloud
```

### Problèmes de permissions

```bash
# Corriger les permissions des données (adapter le chemin)
sudo chown -R 33:33 ~/nextcloud/data
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
