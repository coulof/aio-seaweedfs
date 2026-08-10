#!/bin/bash
# uninstall.sh — uninstalls SeaweedFS Podman quadlet service
#
# Usage: sudo ./uninstall.sh [--purge]
#
# Removes systemd service, quadlet file, Podman secrets, and entrypoint script.
# Retains data in /srv/seaweedfs/data unless --purge is passed.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./uninstall.sh" >&2
  exit 1
fi

PURGE_DATA=false
if [[ "${1:-}" == "--purge" || "${1:-}" == "--purge-data" ]]; then
  PURGE_DATA=true
fi

QUADLET_FILE="/etc/containers/systemd/seaweedfs.container"
ENTRYPOINT_FILE="/srv/seaweedfs/entrypoint.sh"
DATA_DIR="/srv/seaweedfs/data"
SRV_DIR="/srv/seaweedfs"

echo "==> Stopping and disabling seaweedfs.service"
if systemctl is-active --quiet seaweedfs.service 2>/dev/null || systemctl is-enabled --quiet seaweedfs.service 2>/dev/null; then
  systemctl disable --now seaweedfs.service || true
fi

echo "==> Removing systemd quadlet file"
if [[ -f "${QUADLET_FILE}" ]]; then
  rm -f "${QUADLET_FILE}"
  echo "    - Removed ${QUADLET_FILE}"
fi

echo "==> Reloading systemd daemon"
systemctl daemon-reload
systemctl reset-failed seaweedfs.service 2>/dev/null || true

echo "==> Stopping/removing lingering container if present"
if podman container exists seaweedfs 2>/dev/null; then
  podman rm -f seaweedfs || true
  echo "    - Removed container seaweedfs"
fi

echo "==> Removing Podman secrets"
remove_secret_if_exists() {
  local name="$1"
  if podman secret exists "${name}" 2>/dev/null; then
    podman secret rm "${name}"
    echo "    - Removed secret ${name}"
  fi
}

remove_secret_if_exists "seaweedfs-admin-user"
remove_secret_if_exists "seaweedfs-admin-pass"
remove_secret_if_exists "seaweedfs-s3-key"
remove_secret_if_exists "seaweedfs-s3-secret"

echo "==> Removing entrypoint script"
if [[ -f "${ENTRYPOINT_FILE}" ]]; then
  rm -f "${ENTRYPOINT_FILE}"
  echo "    - Removed ${ENTRYPOINT_FILE}"
fi

if [[ "${PURGE_DATA}" == "true" ]]; then
  echo "==> Purging data directory (${SRV_DIR})"
  rm -rf "${SRV_DIR}"
  echo "    - Deleted ${SRV_DIR}"
else
  echo ""
  echo "==> Data preserved at ${DATA_DIR}."
  echo "    To delete data as well, run: sudo ./uninstall.sh --purge"
fi

echo ""
echo "==> Uninstall complete."
