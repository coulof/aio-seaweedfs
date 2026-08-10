#!/bin/bash
# install.sh — sets up SeaweedFS as a root-level, boot-persistent Podman quadlet service
#
# Usage: sudo ./install.sh
#
# Idempotent: safe to re-run. Existing secrets are left untouched (use
# `podman secret rm <name>` first if you want to rotate one).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./install.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="/srv/seaweedfs/data"
ENTRYPOINT_DEST="/srv/seaweedfs/entrypoint.sh"
QUADLET_DIR="/etc/containers/systemd"

echo "==> Creating data directory: ${DATA_DIR}"
mkdir -p "${DATA_DIR}"
chown 1000:1000 "${DATA_DIR}"   # seaweedfs container runs as uid 1000 by default

echo "==> Installing entrypoint script to ${ENTRYPOINT_DEST}"
install -m 0755 "${SCRIPT_DIR}/entrypoint.sh" "${ENTRYPOINT_DEST}"

echo "==> Creating Podman secrets (skipped if they already exist)"
create_secret_if_missing() {
  local name="$1" value="$2"
  if podman secret exists "${name}" 2>/dev/null; then
    echo "    - ${name} already exists, leaving as-is"
  else
    echo -n "${value}" | podman secret create "${name}" -
    echo "    - created ${name}"
  fi
}

create_secret_if_missing "seaweedfs-admin-user" "admin"
create_secret_if_missing "seaweedfs-admin-pass" "$(openssl rand -base64 24)"
create_secret_if_missing "seaweedfs-s3-key" "admin"
create_secret_if_missing "seaweedfs-s3-secret" "$(openssl rand -base64 32)"

echo "==> Installing quadlet unit to ${QUADLET_DIR}"
mkdir -p "${QUADLET_DIR}"
install -m 0644 "${SCRIPT_DIR}/seaweedfs.container" "${QUADLET_DIR}/seaweedfs.container"

echo "==> Reloading systemd and enabling the service"
systemctl daemon-reload
systemctl enable --now seaweedfs.service

echo ""
echo "==> Done. Service status:"
systemctl status seaweedfs.service --no-pager || true

echo ""
echo "==> Save these credentials somewhere safe (e.g. your password manager):"
echo "    Admin UI user:     $(podman secret inspect seaweedfs-admin-user --showsecret --format '{{.SecretData}}' 2>/dev/null || echo '(see: podman secret inspect seaweedfs-admin-user --showsecret)')"
echo "    Admin UI password: (see: podman secret inspect seaweedfs-admin-pass --showsecret)"
echo "    S3 access key:     (see: podman secret inspect seaweedfs-s3-key --showsecret)"
echo "    S3 secret key:     (see: podman secret inspect seaweedfs-s3-secret --showsecret)"
echo ""
echo "Endpoints:"
echo "    S3 API     http://localhost:8333"
echo "    Master UI  http://localhost:9333"
echo "    Filer UI   http://localhost:8888"
echo "    WebDAV     http://localhost:7333"
echo "    Admin UI   http://localhost:23646"
