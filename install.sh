#!/bin/bash
# install.sh — sets up SeaweedFS and Caddy HTTPS reverse proxy via Podman & systemd
#
# Usage:
#   sudo ./install.sh          # Fresh installation / idempotent rerun
#   sudo ./install.sh --update # Update unit files, Caddyfile, and restart services without touching secrets
#
# Supports both Podman Quadlet (Podman >= 4.4.0) and standard systemd unit files (Podman 3.x / < 4.4.0).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./install.sh" >&2
  exit 1
fi

IS_UPDATE=false
for arg in "$@"; do
  case "$arg" in
    --update|--upgrade)
      IS_UPDATE=true
      ;;
  esac
done

if [[ "${IS_UPDATE}" == "true" ]]; then
  echo "==> Running in UPDATE mode (refreshing files and restarting services)"
else
  echo "==> Running in INSTALL mode"
fi

echo "==> Cleaning up any stale CNI network configurations"
rm -f /etc/cni/net.d/seaweedfs-net.conflist
rm -f /etc/containers/systemd/seaweedfs-net.network
if podman network exists seaweedfs-net 2>/dev/null; then
  podman network rm seaweedfs-net 2>/dev/null || true
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

PODMAN_VER="$(podman --version 2>/dev/null || echo 'unknown')"
USE_QUADLET=false

if [[ -n "${QUADLET_BIN}" ]]; then
  USE_QUADLET=true
  echo "    - Found Quadlet generator (${QUADLET_BIN}). Using Quadlet mode."
else
  echo "    - Quadlet not detected (${PODMAN_VER}). Falling back to standard systemd unit file mode."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="/srv/seaweedfs/data"
CADDY_DIR="/srv/caddy"
CADDY_DATA_DIR="/srv/caddy/data"
CADDY_CONFIG_DIR="/srv/caddy/config"
ENTRYPOINT_DEST="/srv/seaweedfs/entrypoint.sh"
QUADLET_DIR="/etc/containers/systemd"
SYSTEMD_DIR="/etc/systemd/system"

echo "==> Configuring firewall rules (if UFW is active)"
if [[ -f "${SCRIPT_DIR}/setup-ufw.sh" ]]; then
  "${SCRIPT_DIR}/setup-ufw.sh" || true
fi

echo "==> Creating directories"
mkdir -p "${DATA_DIR}" "${CADDY_DIR}" "${CADDY_DATA_DIR}" "${CADDY_CONFIG_DIR}"
chown 1000:1000 "${DATA_DIR}"   # seaweedfs container runs as uid 1000 by default

echo "==> Installing entrypoint script to ${ENTRYPOINT_DEST}"
install -m 0755 "${SCRIPT_DIR}/entrypoint.sh" "${ENTRYPOINT_DEST}"

echo "==> Installing Caddyfile to ${CADDY_DIR}/Caddyfile"
if [[ ! -f "${CADDY_DIR}/Caddyfile" ]] || [[ "${IS_UPDATE}" == "true" ]]; then
  install -m 0644 "${SCRIPT_DIR}/Caddyfile" "${CADDY_DIR}/Caddyfile"
else
  echo "    - ${CADDY_DIR}/Caddyfile already exists, leaving as-is (pass --update to overwrite)"
fi

echo "==> Creating Podman secrets (skipped if they already exist)"
create_secret_if_missing() {
  local name="$1" value="$2"
  if podman secret inspect "${name}" >/dev/null 2>&1 || podman secret exists "${name}" 2>/dev/null; then
    echo "    - ${name} already exists, leaving as-is"
  else
    echo -n "${value}" | podman secret create "${name}" - >/dev/null
    echo "    - created ${name}"
  fi
}

create_secret_if_missing "seaweedfs-admin-user" "admin"
create_secret_if_missing "seaweedfs-admin-pass" "$(openssl rand -base64 24)"
create_secret_if_missing "seaweedfs-s3-key" "admin"
create_secret_if_missing "seaweedfs-s3-secret" "$(openssl rand -base64 32)"

if [[ "${USE_QUADLET}" == "true" ]]; then
  echo "==> Installing Quadlet units to ${QUADLET_DIR}"
  mkdir -p "${QUADLET_DIR}"
  install -m 0644 "${SCRIPT_DIR}/seaweedfs.container" "${QUADLET_DIR}/seaweedfs.container"
  install -m 0644 "${SCRIPT_DIR}/caddy.container" "${QUADLET_DIR}/caddy.container"

  echo "==> Reloading systemd and restarting services"
  systemctl daemon-reload

  systemctl restart seaweedfs.service
  systemctl restart caddy.service

  # Warm up Caddy HTTPS endpoint to trigger PKI local root CA generation
  echo "==> Warming up Caddy HTTPS to initialize local PKI Root CA"
  curl -k -s -o /dev/null --resolve "s3.eati-hv-bk-sv.ati.gov.et:443:127.0.0.1" https://s3.eati-hv-bk-sv.ati.gov.et 2>/dev/null || true
else
  echo "==> Installing standard systemd units to ${SYSTEMD_DIR}"
  install -m 0644 "${SCRIPT_DIR}/seaweedfs.service" "${SYSTEMD_DIR}/seaweedfs.service"
  install -m 0644 "${SCRIPT_DIR}/caddy.service" "${SYSTEMD_DIR}/caddy.service"

  echo "==> Reloading systemd and enabling services"
  systemctl daemon-reload
  systemctl enable --now seaweedfs.service
  systemctl enable --now caddy.service

  # Warm up Caddy HTTPS endpoint to trigger PKI local root CA generation
  echo "==> Warming up Caddy HTTPS to initialize local PKI Root CA"
  curl -k -s -o /dev/null --resolve "s3.eati-hv-bk-sv.ati.gov.et:443:127.0.0.1" https://s3.eati-hv-bk-sv.ati.gov.et 2>/dev/null || true
fi

echo ""
echo "==> Done. Service status:"
systemctl status seaweedfs.service --no-pager || true
systemctl status caddy.service --no-pager || true

get_secret_val() {
  local name="$1"
  local val=""

  # 1. Try Podman 4.2+ --showsecret
  val="$(podman secret inspect "${name}" --showsecret --format '{{.SecretData}}' 2>/dev/null || true)"

  # 2. Try reading and decoding directly from host storage (Podman 3.4 / legacy)
  if [[ -z "${val}" ]] && command -v jq >/dev/null 2>&1 && [[ -f "/var/lib/containers/storage/secrets/filedriver/secretsdata.json" ]]; then
    local sec_id
    sec_id="$(podman secret ls --format '{{.ID}} {{.Name}}' 2>/dev/null | awk -v n="${name}" '$2 == n {print $1}')"
    if [[ -n "${sec_id}" ]]; then
      val="$(jq -r --arg id "${sec_id}" '.[$id] // empty | @base64d' /var/lib/containers/storage/secrets/filedriver/secretsdata.json 2>/dev/null || true)"
    fi
  fi

  # 3. Fallback: temporary podman run secret mount (works on any Podman version with image present)
  if [[ -z "${val}" ]]; then
    val="$(podman run --rm --entrypoint="" --secret "${name},type=env,target=SECRET_VAL" docker.io/chrislusf/seaweedfs:4.41 /bin/sh -c 'printf "%s" "$SECRET_VAL"' 2>/dev/null || true)"
  fi

  if [[ -n "${val}" ]]; then
    echo "${val}"
  else
    echo "(could not extract secret value)"
  fi
}

CA_ROOT_PATH="/srv/caddy/data/caddy/pki/authorities/local/root.crt"

echo ""
echo "========================================================================="
if [[ "${IS_UPDATE}" == "true" ]]; then
  echo "                  SeaweedFS & Caddy Update Complete"
else
  echo "                  SeaweedFS & Caddy Installation Complete"
fi
echo "========================================================================="
echo " Save these credentials somewhere safe (e.g. in your password manager):"
echo ""
echo "    Admin UI User:     $(get_secret_val "seaweedfs-admin-user")"
echo "    Admin UI Password: $(get_secret_val "seaweedfs-admin-pass")"
echo "    S3 Access Key:     $(get_secret_val "seaweedfs-s3-key")"
echo "    S3 Secret Key:     $(get_secret_val "seaweedfs-s3-secret")"
echo ""
echo " Active HTTPS Endpoints (via Caddy Reverse Proxy):"
echo "    S3 API & Buckets:  https://s3.eati-hv-bk-sv.ati.gov.et (and *.s3.eati-hv-bk-sv.ati.gov.et)"
echo "    Admin UI:          https://admin.eati-hv-bk-sv.ati.gov.et"
echo "    Filer UI:          https://filer.eati-hv-bk-sv.ati.gov.et"
echo "    Master UI:         https://master.eati-hv-bk-sv.ati.gov.et"
echo ""
echo " Direct HTTP Fallback Endpoints:"
echo "    S3 API:            http://localhost:8333"
echo "    Admin UI:          http://localhost:23646"
echo ""
echo " Caddy Local Root CA Certificate (install on clients if trusting HTTPS):"
echo "    Path: ${CA_ROOT_PATH}"
echo "========================================================================="
