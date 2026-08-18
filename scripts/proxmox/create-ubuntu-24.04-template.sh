#!/usr/bin/env bash
# Run on the Proxmox node (not from Terraform). Builds an Ubuntu 24.04 cloud-init
# template with qemu-guest-agent so bpg/proxmox can read DHCP IPv4 after clone.
#
# Do NOT install libguestfs-tools/qemu-utils on the Proxmox host: those Debian
# packages conflict with pve-qemu-kvm and apt will try to remove proxmox-ve.
# Guest packages are baked in via a one-shot cloud-init boot instead.
set -euo pipefail

VMID="${VMID:-9000}"
VM_NAME="${VM_NAME:-ubuntu-24.04-cloud}"
STORAGE="${STORAGE:-local-lvm}"
ISO_STORAGE="${ISO_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_SIZE="${DISK_SIZE:-40G}"
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"
IMAGE="${IMAGE:-/var/tmp/ubuntu-24.04-server-cloudimg-amd64.img}"
BAKE_TIMEOUT_SEC="${BAKE_TIMEOUT_SEC:-600}"
CIDATA_ISO_NAME="${CIDATA_ISO_NAME:-ubuntu-24.04-template-cidata.iso}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on a Proxmox node." >&2
  exit 1
fi

iso_dir="$(pvesm path "${ISO_STORAGE}:iso/${CIDATA_ISO_NAME}" 2>/dev/null || true)"
if [[ -z "$iso_dir" ]]; then
  iso_dir="/var/lib/vz/template/iso/${CIDATA_ISO_NAME}"
fi
iso_dir="$(dirname "$iso_dir")"
mkdir -p "$iso_dir"
CIDATA_ISO="${iso_dir}/${CIDATA_ISO_NAME}"

need_pkgs=()
command -v wget >/dev/null || need_pkgs+=(wget)
command -v ca-certificates >/dev/null || true
dpkg -s ca-certificates >/dev/null 2>&1 || need_pkgs+=(ca-certificates)
if ! command -v genisoimage >/dev/null && ! command -v mkisofs >/dev/null && ! command -v xorriso >/dev/null; then
  need_pkgs+=(genisoimage)
fi

if ((${#need_pkgs[@]})); then
  echo "==> installing host tools: ${need_pkgs[*]}"
  apt-get update -qq
  apt-get install -y --no-install-recommends "${need_pkgs[@]}"
else
  echo "==> host tools already present (skipping apt)"
fi

make_cidata_iso() {
  local workdir="$1" outfile="$2"
  (
    cd "$workdir"
    if command -v genisoimage >/dev/null; then
      genisoimage -quiet -output "$outfile" -volid cidata -joliet -rock user-data meta-data
    elif command -v mkisofs >/dev/null; then
      mkisofs -quiet -o "$outfile" -V cidata -J -R user-data meta-data
    else
      xorriso -as mkisofs -quiet -o "$outfile" -V cidata -J -R user-data meta-data
    fi
  )
}

echo "==> downloading Ubuntu 24.04 cloud image"
wget -q --show-progress -O "$IMAGE" "$IMAGE_URL"

echo "==> writing one-shot cloud-init seed (installs qemu-guest-agent, then poweroff)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cat >"$workdir/meta-data" <<EOF
instance-id: ${VM_NAME}-bake
local-hostname: ${VM_NAME}
EOF
cat >"$workdir/user-data" <<'EOF'
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
# systemd-networkd DHCPv4 DUID is derived from /etc/machine-id. A baked
# machine-id makes every clone request the same lease (this lab: all VMs
# got 192.168.100.42). Also pin dhcp-identifier to MAC as a second unique key.
write_files:
  - path: /etc/netplan/99-dhcp-mac.yaml
    permissions: "0600"
    content: |
      network:
        version: 2
        ethernets:
          all-en:
            match:
              name: "e*"
            dhcp4: true
            dhcp-identifier: mac
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - mkdir -p /etc/sudoers.d
  - echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ubuntu-nopasswd
  - chmod 440 /etc/sudoers.d/90-ubuntu-nopasswd
  - rm -f /etc/ssh/ssh_host_*
  - cloud-init clean --logs --seed --machine-id
  - truncate -s 0 /etc/machine-id
  - rm -f /var/lib/dbus/machine-id /var/lib/systemd/random-seed
  - poweroff
EOF
make_cidata_iso "$workdir" "$CIDATA_ISO"

if qm status "$VMID" >/dev/null 2>&1; then
  echo "==> destroying existing VMID $VMID"
  qm stop "$VMID" --timeout 30 >/dev/null 2>&1 || true
  qm destroy "$VMID" --purge || qm destroy "$VMID"
fi

echo "==> creating VM $VMID ($VM_NAME)"
qm create "$VMID" \
  --name "$VM_NAME" \
  --memory 2048 \
  --cores 2 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --ostype l26 \
  --cpu host \
  --scsihw virtio-scsi-pci \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0

echo "==> importing disk to $STORAGE"
if qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${IMAGE},discard=on"; then
  true
else
  echo "import-from failed; falling back to qm importdisk"
  qm importdisk "$VMID" "$IMAGE" "$STORAGE"
  imported="$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2; exit}')"
  if [[ -z "$imported" ]]; then
    echo "Could not find unused0 after importdisk." >&2
    exit 1
  fi
  qm set "$VMID" --scsi0 "${imported},discard=on"
fi

qm set "$VMID" --ide2 "${ISO_STORAGE}:iso/${CIDATA_ISO_NAME},media=cdrom"
qm set "$VMID" --boot order=scsi0
qm resize "$VMID" scsi0 "$DISK_SIZE"

echo "==> first boot to bake qemu-guest-agent (needs DHCP + internet on ${BRIDGE})"
qm start "$VMID"
deadline=$((SECONDS + BAKE_TIMEOUT_SEC))
while ((SECONDS < deadline)); do
  status="$(qm status "$VMID" | awk '{print $2}')"
  if [[ "$status" == "stopped" ]]; then
    break
  fi
  sleep 5
done
if [[ "$(qm status "$VMID" | awk '{print $2}')" != "stopped" ]]; then
  echo "Bake did not power off within ${BAKE_TIMEOUT_SEC}s (status: $(qm status "$VMID"))." >&2
  echo "Debug with: qm terminal $VMID" >&2
  echo "Guest needs DHCP and outbound HTTPS on ${BRIDGE}." >&2
  exit 1
fi

echo "==> attaching Proxmox cloud-init drive for later clones"
qm set "$VMID" --delete ide2
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --ipconfig0 ip=dhcp
rm -f "$CIDATA_ISO"
qm template "$VMID"

echo
echo "Template ready: VMID=${VMID} name=${VM_NAME}"
echo "Set template_id = ${VMID} in terraform.tfvars"
echo
qm config "$VMID"
