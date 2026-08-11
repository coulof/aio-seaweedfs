#!/bin/bash
# rotate-credentials.sh — rotates SeaweedFS Podman secrets and restarts the service
#
# Usage:
#   sudo ./rotate-credentials.sh [--all | --admin-pass | --s3-secret]
#
# Defaults to rotating all randomly generated credentials (--all) if no flags are passed.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./rotate-credentials.sh" >&2
  exit 1
fi

ROTATE_ADMIN_PASS=false
ROTATE_S3_SECRET=false

if [[ $# -eq 0 || "${1:-}" == "--all" ]]; then
  ROTATE_ADMIN_PASS=true
  ROTATE_S3_SECRET=true
else
  for arg in "$@"; do
    case "$arg" in
      --admin-pass)
        ROTATE_ADMIN_PASS=true
        ;;
      --s3-secret)
        ROTATE_S3_SECRET=true
        ;;
      --all)
        ROTATE_ADMIN_PASS=true
        ROTATE_S3_SECRET=true
        ;;
      *)
        echo "Unknown flag: $arg" >&2
        echo "Usage: sudo ./rotate-credentials.sh [--all | --admin-pass | --s3-secret]" >&2
        exit 1
        ;;
    esac
  done
fi

rotate_secret() {
  local secret_name="$1"
  local new_value="$2"

  if podman secret inspect "${secret_name}" >/dev/null 2>&1 || podman secret exists "${secret_name}" 2>/dev/null; then
    podman secret rm "${secret_name}" >/dev/null 2>&1 || true
  fi
  echo -n "${new_value}" | podman secret create "${secret_name}" - >/dev/null
  echo "    - Rotated ${secret_name}"
}

echo "==> Rotating SeaweedFS credentials"

if [[ "${ROTATE_ADMIN_PASS}" == "true" ]]; then
  NEW_ADMIN_PASS="$(openssl rand -base64 24)"
  rotate_secret "seaweedfs-admin-pass" "${NEW_ADMIN_PASS}"
fi

if [[ "${ROTATE_S3_SECRET}" == "true" ]]; then
  NEW_S3_SECRET="$(openssl rand -base64 32)"
  rotate_secret "seaweedfs-s3-secret" "${NEW_S3_SECRET}"
fi

echo "==> Restarting seaweedfs.service to apply new credentials"
if systemctl is-active --quiet seaweedfs.service 2>/dev/null || systemctl is-enabled --quiet seaweedfs.service 2>/dev/null; then
  systemctl restart seaweedfs.service
  echo "    - Restarted seaweedfs.service"
else
  echo "    - Service not running/enabled; new secrets will take effect on next start."
fi

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
    val="$(podman run --rm --entrypoint="" --secret "${name},type=env,target=SECRET_VAL" docker.io/chrislusf/seaweedfs:latest /bin/sh -c 'printf "%s" "$SECRET_VAL"' 2>/dev/null || true)"
  fi

  if [[ -n "${val}" ]]; then
    echo "${val}"
  else
    echo "(could not extract secret value)"
  fi
}

echo ""
echo "==> Credential rotation complete."
echo "==> Current active credentials:"
echo "    Admin UI user:     $(get_secret_val "seaweedfs-admin-user")"
echo "    Admin UI password: $(get_secret_val "seaweedfs-admin-pass")"
echo "    S3 access key:     $(get_secret_val "seaweedfs-s3-key")"
echo "    S3 secret key:     $(get_secret_val "seaweedfs-s3-secret")"
