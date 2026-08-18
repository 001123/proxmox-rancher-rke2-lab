#!/usr/bin/env bash
# Run on a Proxmox node (not from Terraform). Stops and destroys guest VMs
# cloned from the Ubuntu cloud-init template. Never destroys the template.
#
# Full clones do not keep a "cloned from VMID" field, so matching is:
#   1. linked-clone disks that reference base-${TEMPLATE_ID}-
#   2. Proxmox tag TAG (default rancher-lab — this Terraform lab)
#   3. NAME_REGEX (default rancher-mgmt / rke2-cp-* / rke2-wk-*)
#
# Usage (on the Proxmox node):
#   sudo ./scripts/proxmox/destroy-clones-from-template.sh
#   sudo DRY_RUN=1 ./scripts/proxmox/destroy-clones-from-template.sh
#   sudo FORCE=1 TEMPLATE_ID=9000 ./scripts/proxmox/destroy-clones-from-template.sh
#
# After this, from the laptop: terraform destroy so state is not left pointing
# at missing VMs. Then rebuild the template if machine-id was baked in, apply.
set -euo pipefail

TEMPLATE_ID="${TEMPLATE_ID:-9000}"
TAG="${TAG:-rancher-lab}"
NAME_REGEX="${NAME_REGEX:-^(rancher-mgmt|rke2-cp-|rke2-wk-)}"
FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on a Proxmox node." >&2
  exit 1
fi

if [[ ! -d /etc/pve/nodes ]]; then
  echo "Not a Proxmox node (/etc/pve/nodes missing)." >&2
  exit 1
fi

conf_node() {
  # /etc/pve/nodes/<node>/qemu-server/<vmid>.conf
  basename "$(dirname "$(dirname "$1")")"
}

conf_vmid() {
  basename "$1" .conf
}

conf_field() {
  awk -F': ' -v key="$2" '$1 == key { print $2; exit }' "$1"
}

is_template() {
  grep -q '^template:' "$1"
}

is_linked_clone() {
  grep -qE "base-${TEMPLATE_ID}-" "$1"
}

has_tag() {
  local tags=";$(conf_field "$1" tags);"
  [[ -n "$TAG" && "$tags" == *";${TAG};"* ]]
}

name_matches() {
  local name
  name="$(conf_field "$1" name)"
  [[ -n "$NAME_REGEX" && "$name" =~ $NAME_REGEX ]]
}

match_reasons() {
  local conf="$1" reasons=()
  if is_linked_clone "$conf"; then
    reasons+=("linked-clone-of-${TEMPLATE_ID}")
  fi
  if has_tag "$conf"; then
    reasons+=("tag:${TAG}")
  fi
  if name_matches "$conf"; then
    reasons+=("name")
  fi
  (IFS=','; echo "${reasons[*]}")
}

# API path is /nodes/{node}/qemu/{vmid} (on-disk dir is qemu-server).
vm_status() {
  local node="$1" vmid="$2"
  pvesh get "/nodes/${node}/qemu/${vmid}/status/current" --output-format json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))'
}

stop_vm() {
  local node="$1" vmid="$2" i status
  status="$(vm_status "$node" "$vmid" || true)"
  if [[ -z "$status" || "$status" == "stopped" ]]; then
    return 0
  fi
  echo "    stop ${vmid} on ${node} (was ${status})"
  pvesh create "/nodes/${node}/qemu/${vmid}/status/stop" >/dev/null || true
  for ((i = 0; i < 60; i++)); do
    status="$(vm_status "$node" "$vmid" || true)"
    if [[ -z "$status" || "$status" == "stopped" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "    warning: ${vmid} still '${status}', destroying anyway" >&2
}

destroy_vm() {
  local node="$1" vmid="$2"
  stop_vm "$node" "$vmid"
  echo "    destroy ${vmid} on ${node}"
  pvesh delete "/nodes/${node}/qemu/${vmid}" \
    --purge 1 \
    --destroy-unreferenced-disks 1
}

targets=()

shopt -s nullglob
for conf in /etc/pve/nodes/*/qemu-server/*.conf; do
  vmid="$(conf_vmid "$conf")"
  if [[ "$vmid" == "$TEMPLATE_ID" ]]; then
    continue
  fi
  if is_template "$conf"; then
    continue
  fi
  why="$(match_reasons "$conf")"
  if [[ -z "$why" ]]; then
    continue
  fi
  node="$(conf_node "$conf")"
  name="$(conf_field "$conf" name)"
  status="$(vm_status "$node" "$vmid" || echo "?")"
  targets+=("${node}|${vmid}|${name:-?}|${status}|${why}")
done
shopt -u nullglob

echo "Template VMID ${TEMPLATE_ID} will be kept."
echo "Match: linked clone of ${TEMPLATE_ID}" \
  "${TAG:+, tag ${TAG}}" \
  "${NAME_REGEX:+, name ~ ${NAME_REGEX}}"
echo

if ((${#targets[@]} == 0)); then
  echo "No matching VMs."
  exit 0
fi

printf '%-12s %-8s %-20s %-10s %s\n' NODE VMID NAME STATUS REASON
printf '%-12s %-8s %-20s %-10s %s\n' ---- ---- ---- ------ ------
for row in "${targets[@]}"; do
  IFS='|' read -r node vmid name status why <<<"$row"
  printf '%-12s %-8s %-20s %-10s %s\n' "$node" "$vmid" "$name" "$status" "$why"
done
echo

if [[ "$DRY_RUN" != "0" ]]; then
  echo "DRY_RUN=1 — nothing destroyed."
  exit 0
fi

if [[ "$FORCE" == "0" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Refusing to destroy without a TTY. Re-run with FORCE=1." >&2
    exit 1
  fi
  read -r -p "Destroy ${#targets[@]} VM(s)? Type yes: " answer
  if [[ "$answer" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

for row in "${targets[@]}"; do
  IFS='|' read -r node vmid name status why <<<"$row"
  echo "==> ${name} (${vmid} on ${node})"
  destroy_vm "$node" "$vmid"
done

echo
echo "Done. Template ${TEMPLATE_ID} is unchanged."
echo "From the laptop, sync Terraform state (VMs are already gone):"
echo "  terraform destroy"
echo "Then rebuild the template if needed and apply:"
echo "  sudo VMID=${TEMPLATE_ID} STORAGE=rancher-data-thin BRIDGE=vmbr0 ./scripts/proxmox/create-ubuntu-24.04-template.sh"
echo "  terraform apply"
