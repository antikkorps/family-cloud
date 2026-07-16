#!/bin/bash
# Installe le service + timer de backup et active le timer. A lancer avec sudo.
set -e
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 0644 "$SRC/family-backup.service" /etc/systemd/system/family-backup.service
install -m 0644 "$SRC/family-backup.timer"   /etc/systemd/system/family-backup.timer

systemctl daemon-reload
systemctl enable --now family-backup.timer

echo "--- Timer installe et active ---"
systemctl list-timers family-backup.timer --no-pager
