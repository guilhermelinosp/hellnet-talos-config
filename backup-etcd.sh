#!/bin/bash
# Backup do etcd do cluster Hellnet
# Roda no PVE. O talosctl esta em /usr/local/bin/
# Uso: bash backup-etcd.sh
set -euo pipefail

BACKUP_DIR="/rpool/backup/etcd"
DATE=$(date +%Y%m%d)
FILE="etcd-snapshot-${DATE}.db"
KEEP=7
TALOSCONFIG="/root/.talos/config"

mkdir -p "$BACKUP_DIR"

echo "=== Backup etcd ==="
export TALOSCONFIG="$TALOSCONFIG"
talosctl --endpoints 192.168.1.201 --nodes 192.168.1.201 \
  etcd snapshot "$BACKUP_DIR/$FILE"

SIZE=$(ls -lh "$BACKUP_DIR/$FILE" | awk '{print $5}')
echo "Snapshot: $SIZE"

# Limpar backups antigos
cd "$BACKUP_DIR"
total=$(ls -1 | wc -l)
if [ "$total" -gt "$KEEP" ]; then
  to_remove=$((total - KEEP))
  ls -t | tail -$to_remove | xargs rm -f
  echo "Removidos $to_remove backups antigos"
fi

echo ""
echo "=== Concluido ==="
echo "Local: $BACKUP_DIR/$FILE"
echo "Total: $(ls -1 | wc -l) backups"
echo "Restore: talosctl bootstrap --recover-from=$BACKUP_DIR/$FILE"
