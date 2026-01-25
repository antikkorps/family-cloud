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
0 */6 * * * /srv/family_cloud/scripts/disk-alert.sh
```

---

## Procédure d'upgrade disque

### Étape 1 : Préparer le nouveau disque

```bash
# Identifier le nouveau disque
lsblk

# Formater (attention: remplacer sdX par le bon disque!)
sudo mkfs.ext4 /dev/sdX

# Créer le point de montage temporaire
sudo mkdir -p /mnt/nouveau_stockage
sudo mount /dev/sdX /mnt/nouveau_stockage
```

### Étape 2 : Arrêter les services

```bash
cd /srv/family_cloud
docker compose down
```

### Étape 3 : Copier les données

```bash
# Copier avec rsync (préserve permissions et liens)
sudo rsync -avhP --progress /mnt/stockage/ /mnt/nouveau_stockage/

# Vérifier l'intégrité
diff -r /mnt/stockage /mnt/nouveau_stockage
```

### Étape 4 : Basculer vers le nouveau disque

```bash
# Démonter l'ancien
sudo umount /mnt/stockage

# Monter le nouveau à la place
sudo umount /mnt/nouveau_stockage
sudo mount /dev/sdX /mnt/stockage

# Mettre à jour /etc/fstab pour le montage permanent
sudo blkid /dev/sdX  # Noter l'UUID
sudo nano /etc/fstab
# Ajouter/modifier la ligne :
# UUID=xxxxx /mnt/stockage ext4 defaults 0 2
```

### Étape 5 : Redémarrer les services

```bash
cd /srv/family_cloud
docker compose up -d

# Vérifier que tout fonctionne
./scripts/health-check.sh
```

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

## Checklist maintenance mensuelle

- [ ] Vérifier espace disque (`df -h`)
- [ ] Vérifier les backups (`./scripts/restore.sh --list`)
- [ ] Nettoyer Docker (`docker system prune`)
- [ ] Mettre à jour les images (`docker compose pull && docker compose up -d`)
- [ ] Vérifier les logs d'erreur (`docker compose logs --since 24h | grep -i error`)
