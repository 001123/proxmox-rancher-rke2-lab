#!/usr/bin/env bash
# Idempotent: k3s (Traefik kept) + Helm + cert-manager + Rancher on rancher-mgmt.
# Usage: sudo /tmp/install-k3s-rancher.sh /tmp/rancher-install.json
set -euo pipefail

JSON_FILE="${1:-/tmp/rancher-install.json}"
if [[ ! -f "$JSON_FILE" ]]; then
  echo "Install config not found: $JSON_FILE" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait || true
fi
if ! command -v python3 >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq python3
fi

eval "$(python3 - "$JSON_FILE" <<'PY'
import json, shlex, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
mapping = {
    "k3s_version": "K3S_VERSION",
    "rancher_hostname": "RANCHER_HOSTNAME",
    "bootstrap_password": "BOOTSTRAP_PASSWORD",
    "rancher_chart_version": "RANCHER_CHART_VERSION",
}
for src, dst in mapping.items():
    print(f"export {dst}={shlex.quote(str(data.get(src) or ''))}")
PY
)"

: "${RANCHER_HOSTNAME:?RANCHER_HOSTNAME is required}"
: "${BOOTSTRAP_PASSWORD:?BOOTSTRAP_PASSWORD is required}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.12.1}"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH}"

# Guest DNS often prefers IPv6 (ULA) and drops sslip.io A records that point at
# RFC1918, so healthchecks must not depend on public DNS.
NODE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
if [[ -z "${NODE_IP}" ]]; then
  NODE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
: "${NODE_IP:?could not determine node IPv4}"
python3 - "$NODE_IP" "$RANCHER_HOSTNAME" <<'PY'
from pathlib import Path
import sys

ip, host = sys.argv[1], sys.argv[2]
path = Path("/etc/hosts")
lines = [ln for ln in path.read_text().splitlines() if host not in ln.split()]
lines.append(f"{ip} {host}")
path.write_text("\n".join(lines) + "\n")
PY
echo "==> node=$(hostname) ip=${NODE_IP} rancher=${RANCHER_HOSTNAME}"

for _ in $(seq 1 30); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

apt-get update -qq
apt-get install -y -qq curl ca-certificates python3

if ! command -v k3s >/dev/null 2>&1; then
  echo "==> installing k3s ${K3S_VERSION:-latest} (Traefik enabled, skip-start)"
  if [[ -n "${K3S_VERSION}" ]]; then
    export INSTALL_K3S_VERSION="$K3S_VERSION"
  fi
  # Starting k3s in this SSH session drops Terraform remote-exec (CNI/iptables).
  export INSTALL_K3S_SKIP_START=true
  curl -sfL https://get.k3s.io | sh -
fi
if ! systemctl is-active --quiet k3s; then
  echo "==> starting k3s (detached from SSH session)"
  systemctl enable k3s >/dev/null 2>&1 || true
  systemd-run --no-block --collect /bin/systemctl start k3s || systemctl start k3s
fi

# kubectl get nodes succeeds as soon as the API is up, often with an empty
# list. kubectl wait --all then exits immediately: "no matching resources found".
echo "==> waiting for k3s node"
ok=0
for _ in $(seq 1 60); do
  if [[ -r /etc/rancher/k3s/k3s.yaml ]] \
    && kubectl get nodes --no-headers 2>/dev/null \
      | awk '$2 == "Ready" { found = 1 } END { exit !found }'; then
    ok=1
    break
  fi
  sleep 5
done
if [[ "$ok" -ne 1 ]]; then
  echo "k3s node did not become Ready" >&2
  kubectl get nodes -o wide >&2 || true
  journalctl -u k3s -n 80 --no-pager >&2 || true
  exit 1
fi
kubectl wait --for=condition=Ready nodes --all --timeout=5m

if ! command -v helm >/dev/null 2>&1; then
  echo "==> installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update >/dev/null
helm repo update >/dev/null

echo "==> installing cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "$CERT_MANAGER_VERSION" \
  --set crds.enabled=true \
  --wait \
  --timeout 10m

echo "==> installing Rancher hostname=${RANCHER_HOSTNAME}"
rancher_args=(
  upgrade --install rancher rancher-latest/rancher
  --namespace cattle-system
  --create-namespace
  --set "hostname=${RANCHER_HOSTNAME}"
  --set replicas=1
  --set-string "bootstrapPassword=${BOOTSTRAP_PASSWORD}"
  --set ingress.ingressClassName=traefik
  --wait
  --timeout 15m
)
if [[ -n "${RANCHER_CHART_VERSION}" ]]; then
  rancher_args+=(--version "$RANCHER_CHART_VERSION")
fi
helm "${rancher_args[@]}"

echo "==> waiting for https://${RANCHER_HOSTNAME}/ping"
ok=0
for _ in $(seq 1 90); do
  if curl -4 -skf --resolve "${RANCHER_HOSTNAME}:443:${NODE_IP}" \
    "https://${RANCHER_HOSTNAME}/ping" | grep -q pong; then
    ok=1
    break
  fi
  sleep 5
done

if [[ "$ok" -ne 1 ]]; then
  echo "Rancher ping did not return pong." >&2
  curl -4 -skS -m 10 --resolve "${RANCHER_HOSTNAME}:443:${NODE_IP}" \
    -w "http=%{http_code} err=%{errormsg}\n" "https://${RANCHER_HOSTNAME}/ping" >&2 || true
  kubectl -n cattle-system get pods,ingress,certificate 2>/dev/null || \
    kubectl -n cattle-system get pods,ingress || true
  exit 1
fi

# /ping returns pong before the local cluster is imported. rancher2_bootstrap then
# waits for condition type Updated (clusterActiveCondition) with a 120s default
# timeout. Rancher 2.15 local (imported k3s) never sets Updated, so Terraform
# always errors: "Timeout waiting for cluster ID local".
echo "==> waiting for local cluster Connected and rancher-webhook"
ok=0
for _ in $(seq 1 120); do
  connected="$(kubectl get clusters.management.cattle.io local \
    -o jsonpath='{.status.conditions[?(@.type=="Connected")].status}' 2>/dev/null || true)"
  webhook_ready="$(kubectl -n cattle-system get deploy rancher-webhook \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${connected}" == "True" && "${webhook_ready:-0}" =~ ^[0-9]+$ && "${webhook_ready:-0}" -ge 1 ]]; then
    ok=1
    break
  fi
  sleep 5
done
if [[ "$ok" -ne 1 ]]; then
  echo "local cluster / rancher-webhook did not become ready." >&2
  kubectl get clusters.management.cattle.io local -o yaml >&2 || true
  kubectl -n cattle-system get deploy,pods >&2 || true
  exit 1
fi

install -d -m 0755 /usr/local/sbin
cat >/usr/local/sbin/rancher-ensure-updated-condition <<'EOS'
#!/usr/bin/env python3
"""Keep clusters.management.cattle.io/local condition Updated=True.

rancher2_bootstrap (terraform-provider-rancher2 v14) waits for that condition.
Rancher 2.15 does not set it on the imported local cluster, and status
reconciles can drop a one-shot patch, so this is reapplied until RuntimeMaxSec.
"""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone


def kubectl(*args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["kubectl", *args],
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


got = kubectl("get", "clusters.management.cattle.io", "local", "-o", "json")
if got.returncode != 0:
    sys.exit(0)
obj = json.loads(got.stdout)
conds = obj.setdefault("status", {}).setdefault("conditions", [])
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for cond in conds:
    if cond.get("type") == "Updated":
        if cond.get("status") == "True":
            sys.exit(0)
        cond["status"] = "True"
        cond["lastUpdateTime"] = now
        break
else:
    conds.append({"lastUpdateTime": now, "status": "True", "type": "Updated"})
rep = kubectl("replace", "--subresource=status", "-f", "-", stdin=json.dumps(obj).encode())
sys.exit(0 if rep.returncode == 0 else 1)
EOS
chmod 0755 /usr/local/sbin/rancher-ensure-updated-condition

echo "==> keeping local cluster condition Updated=True for rancher2_bootstrap"
systemctl stop rancher-tf-updated.service 2>/dev/null || true
systemctl reset-failed rancher-tf-updated.service 2>/dev/null || true
systemd-run --unit=rancher-tf-updated --collect \
  --property=RuntimeMaxSec=20min \
  /bin/bash -c 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml PATH=/usr/local/bin:/usr/bin:/bin
    while /usr/local/sbin/rancher-ensure-updated-condition; do sleep 5; done'
/usr/local/sbin/rancher-ensure-updated-condition || true

echo "Rancher is up at https://${RANCHER_HOSTNAME}"
