#!/usr/bin/env bash
# Idempotent join of a custom RKE2 node using Rancher insecure_node_command.
# Usage: sudo /tmp/join-rke2-node.sh /tmp/rke2-join-command
set -euo pipefail

CMD_FILE="${1:-/tmp/rke2-join-command}"
if [[ ! -f "$CMD_FILE" ]]; then
  echo "Join command file not found: $CMD_FILE" >&2
  exit 1
fi

if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait || true
fi

export DEBIAN_FRONTEND=noninteractive
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates python3
fi

# Self-signed Rancher cert on sslip.io.
export CATTLE_AGENT_STRICT_VERIFY=false

# Guest DNS often cannot resolve sslip.io to RFC1918 (IPv6 DNS / rebinding).
# /etc/hosts helps host-network agents; CoreDNS HelmChartConfig helps pods
# (cattle-cluster-agent uses cluster DNS and never sees /etc/hosts).
ENDPOINT_FILE="${ENDPOINT_FILE:-/tmp/rancher-endpoint.json}"
if [[ -f "$ENDPOINT_FILE" ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "$ENDPOINT_FILE" "$CMD_FILE" <<'PY'
from pathlib import Path
import json, sys

data = json.loads(Path(sys.argv[1]).read_text())
ip, host = data.get("rancher_ip") or "", data.get("rancher_hostname") or ""
if not ip or not host:
    raise SystemExit(0)

path = Path("/etc/hosts")
lines = [ln for ln in path.read_text().splitlines() if host not in ln.split()]
lines.append(f"{ip} {host}")
path.write_text("\n".join(lines) + "\n")

join = Path(sys.argv[2]).read_text()
if "--controlplane" not in join and "--etcd" not in join:
    raise SystemExit(0)

manifest_dir = Path("/var/lib/rancher/rke2/server/manifests")
manifest_dir.mkdir(parents=True, exist_ok=True)
(manifest_dir / "rke2-coredns-config.yaml").write_text(
    f"""apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-coredns
  namespace: kube-system
spec:
  valuesContent: |-
    servers:
    - zones:
      - zone: .
      port: 53
      plugins:
      - name: errors
      - name: health
        configBlock: |-
          lameduck 10s
      - name: ready
      - name: kubernetes
        parameters: cluster.local in-addr.arpa ip6.arpa
        configBlock: |-
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
          ttl 30
      - name: prometheus
        parameters: 0.0.0.0:9153
      - name: hosts
        configBlock: |-
          {ip} {host}
          fallthrough
      - name: forward
        parameters: . /etc/resolv.conf
      - name: cache
        parameters: 30
      - name: loop
      - name: reload
      - name: loadbalance
"""
)
PY
fi

if systemctl is-active --quiet rancher-system-agent 2>/dev/null \
  || systemctl is-active --quiet rke2-server 2>/dev/null \
  || systemctl is-active --quiet rke2-agent 2>/dev/null; then
  echo "Node already joined (rancher-system-agent / rke2 is active)."
  exit 0
fi

JOIN_COMMAND="$(tr -d '\r' < "$CMD_FILE" | sed '/^$/d')"
echo "==> joining cluster"
# The Rancher node command is a shell pipeline (curl | sh -s - ...).
eval "$JOIN_COMMAND"
