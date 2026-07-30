# Hellnet Talos — Recovery Runbook (caos)

## TOPOLOGIA ATUAL (2026-07-29: 3 control-planes + 3 workers)
- **cp1**: 192.168.1.201 (talos node: talos-fd00be2411fffef88968) — VM 201
- **cp2**: 192.168.1.202 — VM 202 (NOVO, criado nesta sessão)
- **cp3**: 192.168.1.203 — VM 203 (NOVO, criado nesta sessão)
- **wk1**: 192.168.1.211 | **wk2**: 192.168.1.212 | **wk3**: 192.168.1.213
- **VIP**: 192.168.1.100 (Talos managed, nos 3 CPs) — endpoint do cluster
- **etcd**: 3 voters (quorum=2, tolera 1 morte de CP)
- **talosconfig**: endpoints/nodes = 192.168.1.100 (VIP)

## REBUILD TOTAL A PARTIR DO .TALOS (self-contained)
Se perder PVE + disco das VMs mas ainda tiver `/root/.talos/` + ISO Talos + storage ZFS intacto:
1. Restaurar dnsmasq: `cp /root/.talos/dnsmasq-talos.conf /etc/dnsmasq.d/talos.conf && systemctl restart dnsmasq`
   (reservas ANTES do range são críticas — gateway 192.168.1.1 também faz DHCP e compete)
2. Recriar VMs conforme `/root/.talos/pve-layout.yaml` (q35+ovmf+virtio-scsi-pci+cpu host, efidisk0 raw 528K, scsi0 ZFS zvol, boot scsi0).
   Exemplo CP: ver comentário no fim do pve-layout.yaml.
3. Boot ISO talos-v1.13.6, `talosctl apply-config --insecure` no IP que a 50000 abrir
   (o gateway pode dar .5/.6/.7 em vez do .20X reservado — usar esse IP).
4. `talosctl reset --nodes <ip> --wipe-mode=all` (abre 50000, exige cert depois) →
   `talosctl apply-config --endpoints <ip> --nodes <ip> --file <cpX-install.yaml>` (com talosconfig, NÃO --insecure).
5. Ordem: cp1 primeiro (bootstrap original), depois cp2/cp3 (join via endpoint .201). Workers por último.
6. Validar com skill talos-k8s-validate.

Arquivos essenciais em /root/.talos:
- `talosconfig` + `config` — credenciais (endpoints=192.168.1.100)
- `cp1-install-vip.yaml`, `cp2-install.yaml`, `cp3-install.yaml` — CPs (controlplane + VIP .100)
- `wk1/2/3-install.yaml` — workers
- `pve-layout.yaml` — defs das 6 VMs (MACs, ZFS, recursos)
- `dnsmasq-talos.conf` — reservas DHCP (copiar p/ /etc/dnsmasq.d/)
- `cilium.yml` + `*-cilium-patch.yaml` — CNI
- `bootstrap.sh` — runbook original
- `RECOVERY.md` — este arquivo
- IGNORAR: nenhum arquivo obsoleto deve existir em /root/.talos (merged/obsolete foram removidos)
- `/root/.talos/cp1-install.yaml` + `cp1-install-vip.yaml` (com VIP .100) → cp1
- `/root/.talos/cp2-install.yaml` + `cp3-install.yaml` → novos CPs (controlplane, VIP .100)
- `/root/.talos/wk1/2/3-install.yaml` → workers

Se tudo cair, USE OS `*-install.yaml` + `talosconfig`. Estes são a fonte de verdade.

## BACKUPS (já existem em /root/backups/)
- `/root/backups/etcd/<TS>/snapshot.db`   → snapshot do etcd (estado do k8s). Regenere após cada mudança importante.
- `/root/backups/hellnet-config-<TS>.tgz` → tar de /root/.talos + /root/.kube + /root/.cluster.

Backup manual (do PVE):
```bash
export TALOSCONFIG=/root/.talos/config
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p /root/backups/etcd/$TS
talosctl -n 192.168.1.201 etcd snapshot /root/backups/etcd/$TS/snapshot.db
tar czf /root/backups/hellnet-config-$TS.tgz -C /root .talos .kube .cluster
```

## CENÁRIO 1 — PVE cai mas discos das VMs intactos
1. Subir PVE, garantir vmbr0 + dnsmasq (DHCP p/ .201/.211/.212/.213).
2. `qm start 201 211 212 213` (ordem: cp1 primeiro).
3. Aguardar Talos boot. `talosctl health` (TALOSCONFIG=/root/.talos/config).
4. Se nodes voltarem Ready → k8s self-heal. Validar com skill talos-k8s-validate.

## CENÁRIO 2 — 1 control-plane morre (cp1/cp2/cp3)
Com 3 CPs, cluster tolera 1 morte (quorum=2). Se 1 CP cai:
1. Outros 2 CPs mantêm o cluster vivo (VIP .100 segue respondendo).
2. Recriar VM do CP morto (mesma MAC do bootstrap) com disco + ISO talos-v1.13.6.
3. `talosctl apply-config --insecure --endpoints 192.168.1.X --nodes 192.168.1.X --file /root/.talos/cpN-install.yaml`
   (NÃO usar `talosctl bootstrap` — o cluster já existe, o novo CP entra como learner e é promovido)
4. Após boot do disco: aguardar etcd promover learner→voter (talosctl etcd members).
5. Se perdeu 2 CPs: cluster para. Restaurar etcd de snapshot em 1 CP vivo + recriar os outros.
6. Validar com talos-k8s-validate.

## CENÁRIO 3 — Perder /root/.talos inteiro (PVE wipe)
1. Restaurar de `/root/backups/hellnet-config-<TS>.tgz`:
   `tar xzf hellnet-config-<TS>.tgz -C /root`
2. `cp /root/.talos/talosconfig /root/.talos/config`
3. Se os discos das VMs intactos → só subir VMs (Cenário 1).
4. Se discos perdidos → recriar tudo via bootstrap.sh (usando install.yaml + talosconfig do backup).

## CENÁRIO 4 — Mac não alcança cluster (i/o timeout)
Cluster Green do PVE = rede Mac→LAN. Fix via Tailscale subnet router:
- PVE: `sysctl -w net.ipv4.ip_forward=1; tailscale up --accept-routes --advertise-routes=192.168.1.0/24 --hostname=pve`
- Console Tailscale: aprovar rota 192.168.1.0/24 no node pve.
- Mac: `tailscale up --accept-routes`
- Se `k` dá "FUNCNEST": alias recursivo no shell → use `command kubectl`.

## VALIDAÇÃO PÓS-RECOVERY
Rodar skill `talos-k8s-validate`:
- talosctl get members (4 nodes)
- services sem degraded
- kubectl get nodes (4 Ready)
- kubectl get pods -A (0 não-Running)
- etcd members healthy

## NOTAS
- Talos imutável: NÃO dá pra ler machine config aplicado nem secrets via talosctl read.
  A fonte autoritativa é o que gerou o cluster (install.yaml + talosconfig).
- Sempre que mudar machine config: regerar merged correto e refazer backup do tar.
- etcd snapshot é o ÚNICO backup do estado das aplicações. Agende (cron) se quiser.
