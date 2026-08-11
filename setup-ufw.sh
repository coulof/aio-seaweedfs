#!/bin/bash
# setup-ufw.sh — configures UFW firewall rules for SeaweedFS and Caddy HTTPS
#
# Usage: sudo ./setup-ufw.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./setup-ufw.sh" >&2
  exit 1
fi

echo "==> Configuring UFW firewall rules for SeaweedFS & Caddy"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "    - Allowing port 80/tcp (Caddy HTTP)"
  ufw allow 80/tcp comment 'Caddy HTTP' >/dev/null

  echo "    - Allowing port 443/tcp (Caddy HTTPS)"
  ufw allow 443/tcp comment 'Caddy HTTPS' >/dev/null

  echo "    - Allowing port 8333/tcp (SeaweedFS S3 Direct API)"
  ufw allow 8333/tcp comment 'SeaweedFS Direct S3' >/dev/null

  echo "    - Allowing port 23646/tcp (SeaweedFS Admin UI)"
  ufw allow 23646/tcp comment 'SeaweedFS Admin UI' >/dev/null

  echo "    - Reloading UFW rules"
  ufw reload >/dev/null
  echo "==> UFW rules updated successfully."
else
  echo "==> UFW is not installed or inactive; skipping firewall configuration."
fi
