#!/bin/bash
# get-info.sh — displays all operational URLs, ports, service status, secrets, and certificate paths
#
# Usage: sudo ./get-info.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./get-info.sh" >&2
  exit 1
fi

DOMAIN="eati-hv-bk-sv.ati.gov.et"
CA_ROOT_PATH="/srv/caddy/data/caddy/pki/authorities/local/root.crt"

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

  # 3. Fallback: temporary podman run secret mount
  if [[ -z "${val}" ]]; then
    val="$(podman run --rm --entrypoint="" --secret "${name},type=env,target=SECRET_VAL" docker.io/chrislusf/seaweedfs:4.41 /bin/sh -c 'printf "%s" "$SECRET_VAL"' 2>/dev/null || true)"
  fi

  if [[ -n "${val}" ]]; then
    echo "${val}"
  else
    echo "(could not extract secret value)"
  fi
}

echo "========================================================================="
echo "               SeaweedFS & Caddy Deployment Summary"
echo "========================================================================="
echo ""
echo "==> Service Status:"
echo "    seaweedfs.service: $(systemctl is-active seaweedfs.service 2>/dev/null || echo 'unknown')"
echo "    caddy.service:     $(systemctl is-active caddy.service 2>/dev/null || echo 'unknown')"
echo ""
echo "==> Secrets & Credentials:"
echo "    Admin UI User:     $(get_secret_val "seaweedfs-admin-user")"
echo "    Admin UI Password: $(get_secret_val "seaweedfs-admin-pass")"
echo "    S3 Access Key:     $(get_secret_val "seaweedfs-s3-key")"
echo "    S3 Secret Key:     $(get_secret_val "seaweedfs-s3-secret")"
echo ""
echo "==> Active HTTPS Endpoints (via Caddy Reverse Proxy):"
echo "    S3 API & Buckets:  https://s3.${DOMAIN} (and *.s3.${DOMAIN})"
echo "    Admin UI:          https://admin.${DOMAIN}"
echo "    Filer UI:          https://filer.${DOMAIN}"
echo "    Master UI:         https://master.${DOMAIN}"
echo ""
echo "==> Direct HTTP Fallback Endpoints & Host Ports:"
echo "    Port 80:           HTTP (Caddy Auto-Redirect)"
echo "    Port 443:          HTTPS (Caddy Reverse Proxy)"
echo "    Port 8333:         S3 API (http://localhost:8333)"
echo "    Port 9333:         Master UI (http://localhost:9333)"
echo "    Port 9340:         Volume Server (gRPC/HTTP)"
echo "    Port 8888:         Filer UI (http://localhost:8888)"
echo "    Port 7333:         WebDAV (http://localhost:7333)"
echo "    Port 23646:        Admin UI (http://localhost:23646)"
echo ""
echo "==> Storage & Certificate Paths:"
echo "    SeaweedFS Data:    /srv/seaweedfs/data"
echo "    Caddy Caddyfile:   /srv/caddy/Caddyfile"
echo "    Caddy Root CA:     ${CA_ROOT_PATH}"
if [[ -f "${CA_ROOT_PATH}" ]]; then
  echo "                       [EXISTS]"
else
  echo "                       [NOT YET GENERATED - run test-s3.sh or make first HTTPS call]"
fi
echo "========================================================================="
