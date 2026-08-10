#!/bin/bash
# install.sh — sets up SeaweedFS as a root-level, boot-persistent Podman quadlet service
#
# Usage: sudo ./install.sh
#
# Idempotent: safe to re-run. Existing secrets are left untouched (use
# `sudo ./rotate-credentials.sh` if you want to rotate them).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./install.sh" >&2
  exit 1
fi

echo "==> Checking system prerequisites"

if ! command -v podman >/dev/null 2>&1; then
  echo "Error: 'podman' is not installed or not in PATH." >&2
  echo "Please install Podman (e.g., 'sudo zypper install podman' on openSUSE)." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "Error: 'openssl' is not installed or not in PATH." >&2
  echo "Please install OpenSSL (e.g., 'sudo zypper install openssl')." >&2
  exit 1
fi

QUADLET_BIN=""
for path in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet /usr/lib/systemd/system-generators/podman-system-generator; do
  if [[ -x "$path" ]]; then
    QUADLET_BIN="$path"
    break
  fi
done

if [[ -z "${QUADLET_BIN}" ]]; then
  PODMAN_VER="$(podman --version 2>/dev/null || echo 'unknown')"
  echo "Warning: Quadlet generator binary not found at standard system paths." >&2
  echo "Installed Podman version: ${PODMAN_VER}" >&2
  echo "Podman Quadlet requires Podman >= 4.4.0." >&2
else
  echo "    - Found Quadlet generator at ${QUADLET_BIN}"
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
  if podman secret inspect "${name}" >/dev/null 2>&1; then
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

echo "==> Reloading systemd and starting seaweedfs.service"
systemctl daemon-reload

if ! systemctl list-unit-files seaweedfs.service >/dev/null 2>&1 && ! systemctl status seaweedfs.service >/dev/null 2>&1; then
  echo "Error: systemd generator failed to create 'seaweedfs.service' from '${QUADLET_DIR}/seaweedfs.container'." >&2
  echo "Ensure Podman Quadlet is supported on this host (Podman >= 4.4.0)." >&2
  exit 1
fi

systemctl restart seaweedfs.service

echo ""
echo "==> Done. Service status:"
systemctl status seaweedfs.service --no-pager || true

get_secret_val() {
  local name="$1"
  local val
  val="$(podman secret inspect "${name}" --showsecret --format '{{.SecretData}}' 2>/dev/null || true)"
  if [[ -n "${val}" ]]; then
    echo "${val}"
  else
    echo "(see: podman secret inspect ${name} --showsecret)"
  fi
}

echo ""
echo "==> Save these credentials somewhere safe (e.g. your password manager):"
echo "    Admin UI user:     $(get_secret_val "seaweedfs-admin-user")"
echo "    Admin UI password: $(get_secret_val "seaweedfs-admin-pass")"
echo "    S3 access key:     $(get_secret_val "seaweedfs-s3-key")"
echo "    S3 secret key:     $(get_secret_val "seaweedfs-s3-secret")"
echo ""
echo "Endpoints:"
echo "    S3 API     http://localhost:8333"
echo "    Master UI  http://localhost:9333"
echo "    Filer UI   http://localhost:8888"
echo "    WebDAV     http://localhost:7333"
echo "    Admin UI   http://localhost:23646"
