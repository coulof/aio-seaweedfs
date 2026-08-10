#!/bin/bash
# uninstall.sh — uninstalls SeaweedFS Podman quadlet service
#
# Usage: sudo ./uninstall.sh [--purge] [-y|--yes]
#
# Removes systemd service, quadlet file, Podman secrets, and entrypoint script.
# Retains data in /srv/seaweedfs/data unless --purge is passed.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./uninstall.sh" >&2
  exit 1
fi

PURGE_DATA=false
SKIP_PROMPT=false

for arg in "$@"; do
  case "$arg" in
    --purge|--purge-data)
      PURGE_DATA=true
      ;;
    -y|--yes)
      SKIP_PROMPT=true
      ;;
  esac
done

QUADLET_FILE="/etc/containers/systemd/seaweedfs.container"
ENTRYPOINT_FILE="/srv/seaweedfs/entrypoint.sh"
DATA_DIR="/srv/seaweedfs/data"
SRV_DIR="/srv/seaweedfs"

if [[ "${PURGE_DATA}" == "true" ]]; then
  echo ""
  echo "========================================================================="
  echo "                     !!! CRITICAL DATA LOSS WARNING !!!"
  echo "========================================================================="
  echo " You are about to UNINSTALL SeaweedFS AND PURGE ALL PERSISTENT DATA."
  echo " Path to be PERMANENTLY DELETED: ${SRV_DIR}"
  echo ""
  echo " This includes:"
  echo "   - All Master metadata"
  echo "   - All Filer metadata"
  echo "   - ALL STORED VOLUMES AND FILE DATA"
  echo "   - All Podman secrets and Quadlet unit files"
  echo ""
  echo " THIS ACTION CANNOT BE UNDONE!"
  echo "========================================================================="
  echo ""

  if [[ "${SKIP_PROMPT}" == "false" ]]; then
    read -rp "Type 'YES' (all caps) to confirm permanent deletion of all data: " CONFIRM
    if [[ "${CONFIRM}" != "YES" ]]; then
      echo "Aborted. No changes were made."
      exit 1
    fi
  fi
else
  echo ""
  echo "========================================================================="
  echo "                           WARNING"
  echo "========================================================================="
  echo " You are about to uninstall the SeaweedFS systemd Quadlet service."
  echo " This will stop the service and delete Podman secrets and unit files."
  echo ""
  echo " Note: Data in ${DATA_DIR} WILL BE PRESERVED."
  echo "========================================================================="
  echo ""

  if [[ "${SKIP_PROMPT}" == "false" ]]; then
    read -rp "Are you sure you want to proceed with uninstallation? [y/N]: " CONFIRM
    if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
      echo "Aborted. No changes were made."
      exit 1
    fi
  fi
fi

echo ""
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
  if podman secret inspect "${name}" >/dev/null 2>&1 || podman secret exists "${name}" 2>/dev/null; then
    podman secret rm "${name}" 2>/dev/null || true
    echo "    - Removed secret ${name}"
  else
    echo "    - Secret ${name} not found, skipping"
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
