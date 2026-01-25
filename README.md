# Family Cloud

Infrastructure self-hosted pour une famille : photos, fichiers, documents, medias et plus.

## Stack Technique

| Service | Usage | URL |
|---------|-------|-----|
| **Immich** | Photos/Videos | `photos.*` |
| **Seafile** | Sync de fichiers | `files.*` |
| **Baikal** | CalDAV/CardDAV | `dav.*` |
| **Vaultwarden** | Mots de passe | `vault.*` |
| **Paperless-ngx** | GED / Documents | `docs.*` |
| **Jellyfin** | Films & Series | `media.*` |
| **Audiobookshelf** | Audiobooks & Podcasts | `books.*` |
| **Homepage** | Dashboard | `home.*` |
| **Stirling PDF** | Outils PDF | `pdf.*` |

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
│   photos.* → Immich       files.* → Seafile                 │
│   dav.* → Baikal          vault.* → Vaultwarden             │
│   docs.* → Paperless      media.* → Jellyfin                │
│   books.* → Audiobookshelf  home.* → Homepage               │
│   pdf.* → Stirling PDF                                      │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│               Reseau Docker Backend (interne)               │
│                                                             │
│  IMMICH: Server + ML + PostgreSQL + Redis                   │
│  SEAFILE: Seafile + MariaDB + Memcached                     │
│  PAPERLESS: Paperless + Redis                               │
│  JELLYFIN, AUDIOBOOKSHELF, VAULTWARDEN, BAIKAL, etc.        │
└─────────────────────────────────────────────────────────────┘
```

## Prerequis

- Serveur local (Dell Optiplex, mini PC, etc.)
- Stockage suffisant (SSD recommande, ~500GB minimum)
- Compte Cloudflare avec :
  - Zero Trust (gratuit) pour le tunnel
  - R2 active (pour les backups)
- 8GB+ RAM (recommande pour Immich ML + Jellyfin)

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
sudo apt install rclone git -y

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
| `dav.votredomaine.com` | `http://caddy:80` |
| `vault.votredomaine.com` | `http://caddy:80` |
| `docs.votredomaine.com` | `http://caddy:80` |
| `media.votredomaine.com` | `http://caddy:80` |
| `books.votredomaine.com` | `http://caddy:80` |
| `home.votredomaine.com` | `http://caddy:80` |
| `pdf.votredomaine.com` | `http://caddy:80` |

### 3. Cloner et Configurer

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
echo "VAULTWARDEN_ADMIN_TOKEN=$(openssl rand -base64 32)"
echo "PAPERLESS_SECRET_KEY=$(openssl rand -base64 32)"
```

### 4. Configuration Rclone (Backups R2)

```bash
# Utiliser le script fourni
./scripts/setup-rclone.sh

# Ou manuellement
rclone config
# n) New remote → name: r2 → Storage: s3 → provider: Cloudflare
# Puis entrer les credentials R2
```

### 5. Lancer

```bash
chmod +x scripts/*.sh
docker compose up -d
docker compose logs -f
```

### 6. Configuration Initiale

| Service | URL | Configuration |
|---------|-----|---------------|
| **Immich** | `photos.*` | Creer compte admin au premier acces |
| **Seafile** | `files.*` | Login avec credentials du `.env` |
| **Baikal** | `dav.*` | Assistant de configuration |
| **Vaultwarden** | `vault.*` | Creer compte, admin sur `/admin` |
| **Paperless** | `docs.*` | Login avec credentials du `.env` |
| **Jellyfin** | `media.*` | Assistant de configuration |
| **Audiobookshelf** | `books.*` | Creer compte admin |
| **Homepage** | `home.*` | Dashboard pre-configure |
| **Stirling PDF** | `pdf.*` | Pret a l'emploi |

---

## Configuration des Clients

### Immich (Photos)

**Mobile** : App Immich (Android/iOS)
- Server URL: `https://photos.votredomaine.com`
- Activer le backup automatique

### Seafile (Fichiers)

**Mobile** : Seadrive (Android/iOS)
**Desktop** : Seafile Client
- Server: `https://files.votredomaine.com`

### Baikal (CalDAV/CardDAV)

**Android** : DAVx5 (gratuit sur F-Droid)
**iOS** : Reglages → Calendrier/Contacts → Ajouter compte
- URL: `https://dav.votredomaine.com`

### Vaultwarden (Mots de passe)

**Tous** : App Bitwarden officielle
- Server: `https://vault.votredomaine.com`

### Jellyfin (Films/Series)

**Mobile** : App Jellyfin (Android/iOS)
**TV** : App Jellyfin (Android TV, Fire TV, etc.)
- Server: `https://media.votredomaine.com`

### Audiobookshelf (Audiobooks)

**Mobile** : App Audiobookshelf (Android/iOS)
- Server: `https://books.votredomaine.com`

---

## Structure des Donnees

```
/mnt/stockage/family_cloud/
├── immich/upload/          # Photos et videos
├── backups/                # Dumps temporaires
└── media/
    ├── films/              # Jellyfin
    ├── series/             # Jellyfin
    ├── livres/             # Audiobookshelf (ebooks)
    └── audiobooks/         # Audiobookshelf
```

---

## Backups

### Backup Manuel

```bash
# Backup complet
./scripts/backup.sh

# Backup specifique
./scripts/backup.sh --immich
./scripts/backup.sh --seafile
./scripts/backup.sh --baikal
./scripts/backup.sh --vaultwarden
./scripts/backup.sh --paperless
```

### Backup Automatique (Cron)

```bash
crontab -e

# Backup complet tous les jours a 3h
0 3 * * * /srv/family_cloud/scripts/backup.sh >> /var/log/family-backup.log 2>&1

# Alerte disque toutes les 6h
0 */6 * * * /srv/family_cloud/scripts/disk-alert.sh
```

### Restauration

```bash
# Lister les backups
./scripts/restore.sh --list

# Restaurer un service
./scripts/restore.sh --immich 20240115
./scripts/restore.sh --seafile 20240115
./scripts/restore.sh --vaultwarden 20240115
```

---

## Maintenance

Voir [docs/MAINTENANCE.md](docs/MAINTENANCE.md) pour :
- Surveillance du stockage
- Procedure d'upgrade disque
- Nettoyage d'urgence
- Checklist mensuelle

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
├── caddy/
│   └── Caddyfile           # Reverse proxy config
├── homepage/               # Config Homepage dashboard
├── scripts/
│   ├── backup.sh           # Backup vers R2
│   ├── restore.sh          # Restauration
│   ├── health-check.sh     # Monitoring
│   ├── disk-alert.sh       # Alerte stockage
│   └── setup-rclone.sh     # Config rclone R2
├── docs/
│   └── MAINTENANCE.md      # Guide maintenance
└── backups/                # Dumps locaux temporaires
```

---

## Securite

- **Aucun port ouvert** sur le routeur (tunnel sortant)
- HTTPS gere par Cloudflare
- Reseau backend Docker isole
- Headers de securite (HSTS, CSP, etc.)
- Backups chiffres (optionnel avec age)
- Geo-blocking recommande via Cloudflare WAF

### Geo-blocking (Cloudflare)

Pour bloquer les acces hors France :
1. Cloudflare Dashboard → Security → WAF → Custom rules
2. Expression: `(ip.geoip.country ne "FR")`
3. Action: Block

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

Normal, le premier demarrage telecharge les modeles ML (~2-4GB).

### Jellyfin transcodage lent

Verifier l'acceleration materielle dans les parametres Jellyfin.

---

## Licence

MIT
