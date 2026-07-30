# hellnet-talos-config

Configuração como-código do cluster **hellnet** (Talos Linux + Kubernetes on-premise).

## Topologia
- 3 control-planes: cp1 (192.168.1.201), cp2 (192.168.1.202), cp3 (192.168.1.203)
- 3 workers: wk1 (192.168.1.211), wk2 (192.168.1.212), wk3 (192.168.1.213)
- VIP Talos: 192.168.1.100 (endpoint do cluster)
- VIP Cilium GW: 192.168.1.200
- Stack: Talos 1.13.6 / K8s 1.36.2 / Cilium 1.19.6 / Longhorn 1.12.0
- Hypervisor: Proxmox VE 9.2.3 (192.168.1.254), storage ZFS (rpool/data)

## Arquivos
| Arquivo | Uso |
|---------|-----|
| `cp1-install-vip.yaml`, `cp2-install.yaml`, `cp3-install.yaml` | Machine configs dos CPs (controlplane + VIP .100) |
| `wk1-install.yaml`, `wk2-install.yaml`, `wk3-install.yaml` | Machine configs dos workers |
| `pve-layout.yaml` | Definição das 6 VMs no PVE (MACs, discos ZFS, recursos) |
| `dnsmasq-talos.conf` | Reservas DHCP fixas — copiar p/ `/etc/dnsmasq.d/talos.conf` no PVE |
| `cilium.yml` + `*-cilium-patch.yaml` | CNI Cilium |
| `bootstrap.sh` | Runbook original de bootstrap |
| `RECOVERY.md` | Disaster recovery (rebuild total a partir deste repo) |

> ⚠️ **Não versionado (segurança):** `talosconfig`, `config`, certs de etcd. O `talosconfig`
> contém CA/crt/key do cluster. Recupere de backup local ou do PVE.

## Rebuild a partir deste repo
Ver `RECOVERY.md` → seção "Rebuild total a partir do .talos".

## Notas
- Este repo é **público e sem segredos**. O `talosconfig` deve ser restaurado de backup local.
- Geração antiga (`*-merged.yaml`, `*.obsolete`) é lixo — ignorar.
