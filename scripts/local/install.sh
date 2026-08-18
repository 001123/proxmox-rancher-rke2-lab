#!/usr/bin/env bash

set -euo pipefail

echo "==> Applying Terraform"

terraform apply -auto-approve \
  -target=module.mgmt \
  -target=module.rke2_control_plane \
  -target=module.rke2_workers && \
terraform apply -auto-approve

echo "==> Terraform applied"