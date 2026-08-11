#!/bin/bash
# uninstall.sh — uninstalls SeaweedFS and Caddy Podman services
#
# Usage:
#   sudo ./uninstall.sh          # Uninstalls services; retains secrets, data, and Caddy root CA cert
#   sudo ./uninstall.sh --purge  # Uninstalls services AND purges all data, secrets, and Caddy root CA cert

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./uninstall.sh" >&2
  exit 1
fi

PURGE_ALL=false
SKIP_PROMPT=false

for arg in "$@"; do
  case "$arg" in
    --purge|--purge-data)
      PURGE_ALL=true
      ;;
    -y|--yes)
      SKIP_PROMPT=true
      ;;
  esac
done

QUADLET_SEAWEEDFS="/etc/containers/systemd/seaweedfs.container"
QUADLET_CADDY="/etc/containers/systemd/caddy.container"
QUADLET_NET="/etc/containers/systemd/seaweedfs-net.network"
SYSTEMD_SEAWEEDFS="/etc/systemd/system/seaweedfs.service"
SYSTEMD_CADDY="/etc/systemd/system/caddy.service"
ENTRYPOINT_FILE="/srv/seaweedfs/entrypoint.sh"
SEAWEEDFS_SRV="/srv/seaweedfs"
CADDY_SRV="/srv/caddy"

if [[ "${PURGE_ALL}" == "true" ]]; then
  echo ""
  echo "========================================================================="
  echo "                     !!! CRITICAL DATA LOSS WARNING !!!"
  echo "========================================================================="
  echo " You are about to UNINSTALL SeaweedFS & Caddy AND PURGE ALL DATA & SECRETS."
  echo ""
  echo " Permanently DELETED paths & resources:"
  echo "   - SeaweedFS storage directory: ${SEAWEEDFS_SRV}"
  echo "   - Caddy directory & Root CA cert: ${CADDY_SRV}"
  echo "   - All Podman secrets (seaweedfs-admin-*, seaweedfs-s3-*)"
  echo "   - All systemd / Quadlet unit files"
  echo ""
  echo " THIS ACTION CANNOT BE UNDONE!"
  echo "========================================================================="
  echo ""

  if [[ "${SKIP_PROMPT}" == "false" ]]; then
    read -rp "Type 'YES' (all caps) to confirm permanent deletion: " CONFIRM
    if [[ "${CONFIRM}" != "YES" ]]; then
      echo "Aborted. No changes were made."
      exit 1
    fi
  fi
else
  echo ""
  echo "========================================================================="
  echo "                           UNINSTALL NOTICE"
  echo "========================================================================="
  echo " You are about to uninstall the SeaweedFS and Caddy systemd services."
  echo ""
  echo " Preserved resources:"
  echo "   - SeaweedFS data in ${SEAWEEDFS_SRV}/data WILL BE PRESERVED."
  echo "   - Caddy data & Root CA certs in ${CADDY_SRV} WILL BE PRESERVED."
  echo "   - Podman secrets WILL BE PRESERVED."
  echo ""
  echo " To purge all data, secrets, and root CA as well, run: sudo ./uninstall.sh --purge"
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
echo "==> Stopping and disabling caddy.service and seaweedfs.service"
systemctl disable --now caddy.service 2>/dev/null || systemctl stop caddy.service 2>/dev/null || true
systemctl disable --now seaweedfs.service 2>/dev/null || systemctl stop seaweedfs.service 2>/dev/null || true

echo "==> Removing systemd unit files"
for file in "${QUADLET_SEAWEEDFS}" "${QUADLET_CADDY}" "${QUADLET_NET}" "${SYSTEMD_SEAWEEDFS}" "${SYSTEMD_CADDY}"; do
  if [[ -f "${file}" ]]; then
    rm -f "${file}"
    echo "    - Removed ${file}"
  fi
done

echo "==> Reloading systemd daemon"
systemctl daemon-reload
systemctl reset-failed seaweedfs.service caddy.service 2>/dev/null || true

echo "==> Stopping/removing lingering containers if present"
for ctr in seaweedfs caddy; do
  if podman container exists "${ctr}" 2>/dev/null; then
    podman rm -f "${ctr}" || true
    echo "    - Removed container ${ctr}"
  fi
done

echo "==> Removing entrypoint script"
if [[ -f "${ENTRYPOINT_FILE}" ]]; then
  rm -f "${ENTRYPOINT_FILE}"
  echo "    - Removed ${ENTRYPOINT_FILE}"
fi

if [[ "${PURGE_ALL}" == "true" ]]; then
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

  echo "==> Purging storage and Caddy directories"
  rm -rf "${SEAWEEDFS_SRV}" "${CADDY_SRV}"
  echo "    - Deleted ${SEAWEEDFS_SRV}"
  echo "    - Deleted ${CADDY_SRV}"

  if podman network exists seaweedfs-net 2>/dev/null; then
    podman network rm seaweedfs-net 2>/dev/null || true
    echo "    - Removed network seaweedfs-net"
  fi
else
  echo ""
  echo "==> Preserved data directories and Podman secrets."
  echo "    - Storage data: ${SEAWEEDFS_SRV}/data"
  echo "    - Caddy CA certs: ${CADDY_SRV}/data"
  echo "    To delete data and secrets as well, run: sudo ./uninstall.sh --purge"
fi

echo ""
echo "==> Uninstall complete."
