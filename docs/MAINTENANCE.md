# Guide de Maintenance - Family Cloud

## Surveillance du stockage

### Alertes automatiques

Le script `health-check.sh` surveille l'espace disque :
- **80%** : Warning
- **90%** : Critical

```bash
# Vérifier l'état actuel
./scripts/health-check.sh

# Voir l'utilisation disque
df -h /mnt/stockage
```

### Configurer une alerte par email (optionnel)

Ajouter dans crontab (`crontab -e`) :

```bash
# Alerte si disque > 80%
0 */6 * * * /srv/family_cloud/scripts/disk-alert.sh >> /srv/family_cloud/logs/disk-alert.log 2>&1
```

---

## Procédure d'upgrade disque

### Prérequis

- Nouveau disque connecté (interne SATA ou externe USB pour la migration)
- Espace suffisant pour contenir toutes les données actuelles

### Étape 1 : Identifier les disques

```bash
# Lister les disques et leur état
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL

# Vérifier l'espace utilisé sur le disque actuel
df -h /mnt/stockage
du -sh /mnt/stockage/*
```

### Étape 2 : Formater le nouveau disque

```bash
# ATTENTION: vérifier que sdX est bien le nouveau disque !
# Formater avec un label explicite
sudo mkfs.ext4 -L stockage_cloud /dev/sdX

# Créer un point de montage temporaire
sudo mkdir -p /mnt/stockage_new
sudo mount /dev/sdX /mnt/stockage_new
```

### Étape 3 : Arrêter les services

```bash
cd /srv/family_cloud
docker compose down
```

### Étape 4 : Copier les données

```bash
# Copier avec rsync (préserve permissions, affiche la progression)
sudo rsync -avhP --info=progress2 /mnt/stockage/ /mnt/stockage_new/

# Vérifier que la copie est complète
ls -la /mnt/stockage_new/
```

### Étape 5 : Configurer le montage permanent

```bash
# Récupérer l'UUID du nouveau disque
sudo blkid /dev/sdX
# Exemple de sortie : UUID="3555e887-37d7-4ed6-ab60-716ddeb4c247"

# Voir l'UUID actuel dans fstab
grep stockage /etc/fstab

# Remplacer l'ancien UUID par le nouveau dans /etc/fstab
sudo sed -i 's/ANCIEN_UUID/NOUVEL_UUID/' /etc/fstab

# Vérifier la modification
grep stockage /etc/fstab
```

### Étape 6 : Basculer vers le nouveau disque

```bash
# Démonter les deux disques
sudo umount /mnt/stockage_new
sudo umount /mnt/stockage

# Recharger systemd pour prendre en compte le nouveau fstab
sudo systemctl daemon-reload

# Monter le nouveau disque sur /mnt/stockage
sudo mount /mnt/stockage

# Vérifier que c'est le bon disque (taille attendue)
df -h /mnt/stockage
```

### Étape 7 : Redémarrer les services

```bash
cd /srv/family_cloud
docker compose up -d

# Vérifier le status de tous les services
docker compose ps

# Vérifier les logs si besoin
docker compose logs --tail 20
```

### Étape 8 : Finaliser (si disque externe)

Si le nouveau disque était connecté en externe pour la migration :

1. Éteindre le serveur : `sudo shutdown now`
2. Monter le nouveau disque en interne (SATA)
3. Retirer l'ancien disque
4. Redémarrer - le système trouvera le disque par son UUID automatiquement

> **Note** : L'avantage d'utiliser l'UUID dans fstab est que le disque sera reconnu
> peu importe son nom de device (`/dev/sda`, `/dev/sdb`, etc.)

---

## Nettoyage d'urgence (si disque plein)

### Libérer de l'espace rapidement

```bash
# 1. Nettoyer Docker (images/conteneurs non utilisés)
docker system prune -a

# 2. Supprimer les vieux logs de backup
find /srv/family_cloud/backups -name "*.log" -mtime +7 -delete

# 3. Vérifier les gros fichiers
du -sh /mnt/stockage/family_cloud/*

# 4. Immich : vérifier les fichiers temporaires
du -sh /mnt/stockage/family_cloud/immich/upload/thumbs
du -sh /mnt/stockage/family_cloud/immich/upload/encoded-video

# 5. Paperless : vérifier les fichiers en attente
docker exec paperless document_exporter --delete
```

### Identifier ce qui prend de la place

```bash
# Top 20 des plus gros dossiers
du -h /mnt/stockage | sort -rh | head -20

# Espace par service
du -sh /mnt/stockage/family_cloud/*/
```

---

## Volumes Docker

### Lister les volumes et leur taille

```bash
docker system df -v
```

### Localisation des volumes

| Service | Volume | Données |
|---------|--------|---------|
| Immich | /mnt/stockage/family_cloud/immich/upload | Photos/vidéos |
| Seafile | seafile_data | Fichiers sync |
| Paperless | paperless_media | Documents PDF |
| Vaultwarden | vaultwarden_data | Base mots de passe |

### Migrer un volume vers un autre disque

```bash
# Exemple pour Seafile
docker compose stop seafile

# Copier le volume
docker run --rm -v seafile_data:/source -v /mnt/nouveau/seafile:/dest alpine cp -av /source/. /dest/

# Modifier docker-compose.yml pour pointer vers le nouveau chemin
# Puis relancer
docker compose up -d seafile
```

---

## Backups et Restauration

### Vérifier les backups R2

```bash
# Lister les backups disponibles
./scripts/restore.sh --list

# Taille totale sur R2
rclone size r2:family-backup
```

### Restaurer après upgrade disque

Si les données sont perdues mais les backups R2 sont intacts :

```bash
# Restaurer Immich
./scripts/restore.sh --immich YYYYMMDD

# Restaurer Seafile
./scripts/restore.sh --seafile YYYYMMDD

# Etc.
```

---

## Mise à jour des images Docker

### Vérifier et télécharger les mises à jour

```bash
cd /srv/family_cloud

# Télécharger les nouvelles versions de toutes les images
docker compose pull
```

Le résultat indique quelles images ont été mises à jour (téléchargement de layers) vs celles déjà à jour.

### Appliquer les mises à jour

```bash
# Méthode 1 : Redémarrer tous les services avec les nouvelles images
docker compose up -d

# Méthode 2 : Redémarrer uniquement les services mis à jour
docker compose up -d --force-recreate service1 service2
```

### Vérifier que tout fonctionne

```bash
# Status des containers
docker compose ps

# Vérifier les logs des services redémarrés
docker compose logs --tail 20 service1 service2
```

### Nettoyer les anciennes images

```bash
# Supprimer les images obsolètes (non utilisées)
docker image prune -f

# Nettoyage plus agressif (images, containers, volumes non utilisés)
docker system prune -a
```

### Services avec précautions particulières

| Service | Précaution |
| ------- | ---------- |
| **immich-postgres** | Vérifier compatibilité avant upgrade majeur de PostgreSQL |
| **seafile** | Lire les release notes avant upgrade majeur |
| **paperless** | Peut nécessiter des migrations de DB |

### Rollback en cas de problème

```bash
# Si un service ne fonctionne plus après mise à jour :

# 1. Voir les images disponibles localement
docker images | grep nom_service

# 2. Modifier docker-compose.yml pour fixer une version
# Exemple : image: immich-server:v1.94.0 au lieu de :release

# 3. Redémarrer
docker compose up -d service_concerné
```

---

## Checklist maintenance mensuelle

- [ ] Vérifier espace disque (`df -h`)
- [ ] Vérifier les backups (`./scripts/restore.sh --list`)
- [ ] Nettoyer Docker (`docker system prune`)
- [ ] Mettre à jour les images (`docker compose pull && docker compose up -d`)
- [ ] Vérifier les logs d'erreur (`docker compose logs --since 24h | grep -i error`)
