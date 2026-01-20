# Family Cloud (Immich + Seafile + Stalwart)

Infrastructure self-hosted pour une famille : photos, fichiers et calendriers/contacts.

## Stack Technique

| Service | Usage | Technologie |
|---------|-------|-------------|
| **Immich** | Photos/Videos | Alternative Google Photos |
| **Seafile CE** | Fichiers | Sync/partage de fichiers |
| **Stalwart** | CalDAV/CardDAV | Calendriers et contacts |

| Infrastructure | Technologie |
|----------------|-------------|
| Orchestration | Docker Compose |
| Acces externe | Cloudflare Tunnel |
| Reverse Proxy | Caddy |
| Backup | Rclone → Cloudflare R2 |

## Architecture

```
Internet
    │ HTTPS (Cloudflare)
    ▼
┌─────────────────────────────────────────────────────────────┐
│            Cloudflare Tunnel (cloudflared)                  │
│            - Connexion sortante uniquement                  │
│            - Pas de port ouvert sur le routeur              │
└─────────────────────────┬───────────────────────────────────┘
                          │ HTTP interne
┌─────────────────────────▼───────────────────────────────────┐
│                    Caddy (Reverse Proxy)                    │
│         photos.* → Immich    files.* → Seafile              │
│                    mail.* → Stalwart                        │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│               Reseau Docker Backend (interne)               │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ IMMICH                                                │  │
│  │ ┌────────────┐  ┌──────────┐  ┌───────┐  ┌───────┐   │  │
│  │ │   Server   │  │    ML    │  │ Postgres│ │ Redis │   │  │
│  │ └────────────┘  └──────────┘  └─────────┘ └───────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ SEAFILE                                               │  │
│  │ ┌────────────┐  ┌──────────┐  ┌───────────┐          │  │
│  │ │   Seafile  │  │ MariaDB  │  │ Memcached │          │  │
│  │ └────────────┘  └──────────┘  └───────────┘          │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ STALWART                                              │  │
│  │ ┌────────────────────────────────────────────────┐   │  │
│  │ │   Mail Server (CalDAV/CardDAV/JMAP)            │   │  │
│  │ └────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Prerequis

- Serveur local (Dell Optiplex, mini PC, etc.)
- Stockage suffisant (SSD recommande, ~500GB minimum)
- Compte Cloudflare avec :
  - Zero Trust (gratuit) pour le tunnel
  - R2 active (pour les backups)
- 4GB+ RAM (8GB recommande pour le ML d'Immich)

---

## Deploiement

### 1. Preparation du Serveur

```bash
# Mise a jour
sudo apt update && sudo apt upgrade -y

# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Outils
sudo apt install rclone git age -y

# Reconnecter pour appliquer le groupe docker
exit
```

### 2. Configuration Cloudflare Tunnel

1. [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → **Networks** → **Tunnels**
2. **Create a tunnel** → Type: **Cloudflared**
3. Nom: `family-cloud`
4. Copier le **token** (`eyJ...`)

Configurer les **Public Hostnames** :

| Hostname | Service |
|----------|---------|
| `photos.votredomaine.com` | `http://caddy:80` |
| `files.votredomaine.com` | `http://caddy:80` |
| `mail.votredomaine.com` | `http://caddy:80` |

### 3. Configuration Rclone (Backups R2)

```bash
rclone config

# n) New remote
# name> r2
# Storage> s3
# provider> Cloudflare
# access_key_id> [Votre R2 Access Key]
# secret_access_key> [Votre R2 Secret Key]
# endpoint> https://[ACCOUNT_ID].r2.cloudflarestorage.com

# Tester
rclone lsd r2:

# Creer le bucket
rclone mkdir r2:family-backup
```

### 4. Cloner et Configurer

```bash
cd ~
git clone https://github.com/votre-user/family-cloud.git
cd family-cloud

cp .env.example .env
chmod 600 .env
nano .env
```

Generer les mots de passe :

```bash
echo "IMMICH_DB_PASSWORD=$(openssl rand -base64 32)"
echo "SEAFILE_ADMIN_PASSWORD=$(openssl rand -base64 24)"
echo "SEAFILE_DB_ROOT_PASSWORD=$(openssl rand -base64 32)"
```

Creer le repertoire pour les photos Immich :

```bash
mkdir -p ~/family-cloud/immich-upload
# Mettre ce chemin dans UPLOAD_LOCATION du .env
```

### 5. Lancer

```bash
chmod +x scripts/*.sh
docker compose up -d
docker compose logs -f
```

### 6. Configuration Initiale

#### Immich
- Acceder a `https://photos.votredomaine.com`
- Creer le compte admin au premier acces

#### Seafile
- Acceder a `https://files.votredomaine.com`
- Se connecter avec les credentials du `.env`

#### Stalwart
- Acceder a `https://mail.votredomaine.com`
- Suivre l'assistant de configuration
- Creer les utilisateurs pour la famille

---

## Configuration des Clients

### Immich (Photos)

**Mobile** : Installer l'app Immich (Android/iOS)
- Server URL: `https://photos.votredomaine.com`
- Activer le backup automatique

**Desktop** : Interface web ou CLI

### Seafile (Fichiers)

**Mobile** : Seadrive (Android/iOS)
**Desktop** : Seafile Client (Windows/Mac/Linux)
- Server: `https://files.votredomaine.com`

### Stalwart (CalDAV/CardDAV)

**iOS/macOS** :
- Reglages → Calendrier/Contacts → Ajouter compte → Autre
- CalDAV/CardDAV: `https://mail.votredomaine.com`

**Android** :
- Installer DAVx5
- Ajouter compte avec l'URL du serveur

**Thunderbird** :
- Ajouter calendrier distant CardDAV/CalDAV

---

## Backups

### Backup Manuel

```bash
# Backup complet
./scripts/backup.sh

# Backup specifique
./scripts/backup.sh --immich
./scripts/backup.sh --seafile
./scripts/backup.sh --stalwart
```

### Backup Automatique (Cron)

```bash
crontab -e

# Backup complet tous les jours a 3h
0 3 * * * /home/user/family-cloud/scripts/backup.sh >> /var/log/family-backup.log 2>&1
```

### Restauration

```bash
# Lister les backups
./scripts/restore.sh --list

# Restaurer un service
./scripts/restore.sh --immich 20240115
./scripts/restore.sh --seafile 20240115
./scripts/restore.sh --stalwart 20240115
```

---

## Commandes Utiles

```bash
# Logs
docker compose logs -f [service]

# Redemarrer
docker compose restart

# Mise a jour
docker compose pull && docker compose up -d

# Status
./scripts/health-check.sh
```

---

## Structure du Projet

```
family-cloud/
├── docker-compose.yml      # Orchestration
├── .env.example            # Template configuration
├── .env                    # Configuration (non versionne)
├── README.md
├── LICENSE
├── caddy/
│   └── Caddyfile           # Reverse proxy config
├── scripts/
│   ├── backup.sh           # Backup vers R2
│   ├── restore.sh          # Restauration
│   └── health-check.sh     # Monitoring
└── backups/                # Dumps locaux temporaires
```

---

## Securite

- **Aucun port ouvert** sur le routeur (tunnel sortant)
- HTTPS gere par Cloudflare
- Reseau backend Docker isole
- Headers de securite (HSTS, CSP, etc.)
- Backups chiffres (optionnel avec age)

### Durcissement

```bash
# Pare-feu UFW
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw enable

# Desactiver root SSH
sudo sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

---

## Depannage

### Service inaccessible

```bash
docker compose ps
docker compose logs cloudflared
docker compose logs caddy
docker compose logs [service]
```

### Immich ML lent au demarrage

C'est normal, le premier demarrage telecharge les modeles ML (~2-4GB).

### Seafile erreur de login

Verifier que `SEAFILE_SERVER_HOSTNAME` correspond au domaine configure.

---

## Renommer le Repository

Si vous avez clone ce repo sous un autre nom (ex: `nextcloud`), vous pouvez le renommer :

1. **Sur GitHub** : Settings → General → Repository name → `family-cloud` → Rename
2. **En local** :
```bash
git remote set-url origin git@github.com:VOTRE_USER/family-cloud.git
```

---

## Licence

MIT
