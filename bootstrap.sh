#!/bin/bash
# Bootstrap completo do cluster Hellnet (Talos + Cilium)
# Uso: bash bootstrap.sh
# Pré-requisitos: chaves SSH configuradas para root@192.168.1.254 (PVE)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PVE="root@192.168.1.254"
ISO="talos-v1.13.5.iso"
SCHEMATIC="factory.talos.dev/installer/dc7b152cb3ea99b821fcb7340ce7168313ce393d663740b791c36f6e95fc8586:v1.13.6"

echo "=== 1. Preparar DHCP no PVE ==="
ssh $PVE "pkill dnsmasq 2>/dev/null; sleep 1
dnsmasq --interface=vmbr0 --bind-interfaces \
  --dhcp-range=192.168.1.2,192.168.1.239,12h \
  --dhcp-host=bc:24:11:f8:89:68,192.168.1.201 \
  --dhcp-host=bc:24:11:d0:68:87,192.168.1.211 \
  --dhcp-host=bc:24:11:e7:c4:96,192.168.1.212 \
  --dhcp-host=bc:24:11:80:ea:dd,192.168.1.213 \
  --dhcp-option=3,192.168.1.1 --dhcp-option=6,192.168.1.1 \
  --dhcp-authoritative --no-daemon --log-dhcp > /tmp/dnsmasq-dhcp.log 2>&1 &"

echo "=== 2. Destruir VMs e recriar discos ==="
ssh $PVE '
for vmid in 201 211 212 213; do
  qm stop $vmid --skiplock 2>/dev/null; sleep 2
  qm set $vmid --delete scsi0 --delete efidisk0 --delete ide2 2>/dev/null
  rm -f /var/lib/vz/images/$vmid/vm-${vmid}-disk-0.raw
  rm -f /var/lib/vz/images/$vmid/vm-${vmid}-disk-1.raw
  size=60; [ $vmid -ne 201 ] && size=100
  qemu-img create -f raw /var/lib/vz/images/$vmid/vm-${vmid}-disk-0.raw 540672
  qemu-img create -f raw /var/lib/vz/images/$vmid/vm-${vmid}-disk-1.raw "${size}G"
  qm set $vmid --efidisk0 "local:${vmid}/vm-${vmid}-disk-0.raw,efitype=2m,size=528K"
  qm set $vmid --scsi0 "local:${vmid}/vm-${vmid}-disk-1.raw,cache=writethrough,discard=on,size=${size}G,ssd=1"
  qm set $vmid --ide2 "local:iso/'"${ISO}"',media=cdrom"
  qm set $vmid --boot order=ide2
  qm start $vmid
done
'

echo "=== 3. Aguardar boot ISO (90s) ==="
sleep 90

echo "=== 4. Aplicar config em todos os nodes ==="
# Copiar configs para PVE
scp "$DIR/cp1-install.yaml" "$DIR/wk1-install.yaml" \
    "$DIR/wk2-install.yaml" "$DIR/wk3-install.yaml" \
    "$DIR/talosconfig" $PVE:/root/ 2>/dev/null

ssh $PVE '
for entry in "201 cp1-install.yaml" "211 wk1-install.yaml" "212 wk2-install.yaml" "213 wk3-install.yaml"; do
  ip=$(echo $entry | cut -d" " -f1)
  file=$(echo $entry | cut -d" " -f2)
  timeout 120 talosctl apply-config --insecure --endpoints $ip --nodes $ip --file /root/$file
done
'

echo "=== 5. Aguardar instalação (60s) ==="
sleep 60

echo "=== 6. Remover ISO e boot do disco ==="
ssh $PVE '
for vmid in 201 211 212 213; do
  qm set $vmid --delete ide2
  qm set $vmid --boot order=scsi0
  qm reset $vmid --skiplock
done
'

echo "=== 7. Aguardar boot do disco (3min) ==="
sleep 180

echo "=== 8. Bootstrap etcd ==="
export TALOSCONFIG="$DIR/talosconfig"
timeout 30 talosctl bootstrap --endpoints 192.168.1.201 --nodes 192.168.1.201

echo "=== 9. Aguardar cluster (30s) ==="
sleep 30

echo "=== 10. Verificar nodes ==="
timeout 30 talosctl --endpoints 192.168.1.201 --nodes 192.168.1.201 get members

echo ""
echo "=== 11. Upgrade nodes com schematic (iscsi-tools + qemu-guest-agent) ==="
for ip in 192.168.1.201 192.168.1.211 192.168.1.212 192.168.1.213; do
  talosctl upgrade --endpoints $ip --nodes $ip --image "$SCHEMATIC"
done

echo "Aguardando 90s..."
sleep 90

echo ""
echo "=== 12. Instalar Cilium ==="
CILIUM_VALUES="$DIR/../.cluster/cilium.yml"
if [ -f "$CILIUM_VALUES" ]; then
  helm upgrade --install cilium cilium/cilium --version 1.19.6 \
    --namespace kube-system --values "$CILIUM_VALUES"
else
  echo "Aviso: $CILIUM_VALUES nao encontrado. Instalando Cilium com valores padrão."
  helm upgrade --install cilium cilium/cilium --version 1.19.6 \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set devices=ens18 \
    --set routingMode=native \
    --set autoDirectNodeRoutes=true \
    --set directRoutingDevice=ens18 \
    --set ipv4NativeRoutingCIDR=10.244.0.0/16 \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445
fi

echo ""
echo "=== 13. Label workers ==="
kubectl label node --all node-role.kubernetes.io/worker="" --overwrite 2>/dev/null || true

echo ""
echo "=== Bootstrap concluído ==="
echo "kubectl get nodes"
kubectl get nodes
