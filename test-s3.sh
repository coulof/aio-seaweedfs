#!/bin/bash
# test-s3.sh — automated sanity test for SeaweedFS S3 API and Caddy HTTPS reverse proxy
#
# Usage: sudo ./test-s3.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./test-s3.sh" >&2
  exit 1
fi

DOMAIN="eati-hv-bk-sv.ati.gov.et"
BUCKET="rancher-backup"
HTTP_ENDPOINT="http://localhost:8333"
HTTPS_ENDPOINT="https://s3.${DOMAIN}"

echo "========================================================================="
echo "                    SeaweedFS S3 API Sanity Test"
echo "========================================================================="

echo "==> Retrieving S3 credentials from Podman secrets"

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

  echo "${val}"
}

S3_KEY="$(get_secret_val "seaweedfs-s3-key")"
S3_SECRET="$(get_secret_val "seaweedfs-s3-secret")"

if [[ -z "${S3_KEY}" || -z "${S3_SECRET}" ]]; then
  echo "Error: Could not retrieve S3 key or secret." >&2
  exit 1
fi

echo "    - Access Key: ${S3_KEY}"
echo "    - Secret Key: (retrieved)"

echo ""
echo "==> Test 1: Direct HTTP S3 Health Check (${HTTP_ENDPOINT})"
HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" "${HTTP_ENDPOINT}/" || echo "000")"
if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "403" ]]; then
  echo "    [PASS] Direct HTTP S3 responder returned HTTP ${HTTP_CODE}"
else
  echo "    [FAIL] Direct HTTP S3 endpoint returned HTTP ${HTTP_CODE} (expected 200/403)" >&2
  exit 1
fi

echo ""
echo "==> Test 2: Caddy HTTPS Health Check (https://localhost:443)"
HTTPS_CODE="$(curl -k -s -o /dev/null -w "%{http_code}" "https://localhost:443/" || echo "000")"
if [[ "${HTTPS_CODE}" == "200" || "${HTTPS_CODE}" == "403" ]]; then
  echo "    [PASS] Caddy HTTPS proxy returned HTTP ${HTTPS_CODE}"
else
  echo "    [WARN] Caddy HTTPS proxy returned HTTP ${HTTPS_CODE}"
fi

echo ""
echo "==> Test 3: S3 Lifecycle Test (Upload -> Download -> Verify -> Delete)"

TEST_FILE="/tmp/seaweedfs-s3-sanity-test.tmp"
DOWNLOAD_FILE="/tmp/seaweedfs-s3-downloaded.tmp"
TIMESTAMP="$(date +%s)"
TEST_CONTENT="SeaweedFS S3 Sanity Test Payload - Timestamp ${TIMESTAMP}"

echo "${TEST_CONTENT}" > "${TEST_FILE}"

python3 - <<EOF
import sys, os, datetime, hashlib, hmac, urllib.request

access_key = "${S3_KEY}"
secret_key = "${S3_SECRET}"
endpoint = "${HTTP_ENDPOINT}"
bucket = "${BUCKET}"
object_name = "test-${TIMESTAMP}.txt"
test_content = """${TEST_CONTENT}""".encode('utf-8')

# S3 v4 Signing Helper
def sign(key, msg):
    return hmac.new(key, msg.encode('utf-8'), hashlib.sha256).digest()

def get_signature_key(key, date_stamp, region_name, service_name):
    k_date = sign(('AWS4' + key).encode('utf-8'), date_stamp)
    k_region = sign(k_date, region_name)
    k_service = sign(k_region, service_name)
    k_signing = sign(k_service, 'aws4_request')
    return k_signing

def send_s3_request(method, path, body=b''):
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime('%Y%m%dT%H%M%SZ')
    date_stamp = now.strftime('%Y%m%d')
    region = 'us-east-1'
    service = 's3'
    
    payload_hash = hashlib.sha256(body).hexdigest()
    canonical_uri = '/' + path.lstrip('/')
    canonical_headers = f'host:localhost:8333\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n'
    signed_headers = 'host;x-amz-content-sha256;x-amz-date'
    
    canonical_request = f'{method}\n{canonical_uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}'
    
    credential_scope = f'{date_stamp}/{region}/{service}/aws4_request'
    string_to_sign = f'AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n' + hashlib.sha256(canonical_request.encode('utf-8')).hexdigest()
    
    signing_key = get_signature_key(secret_key, date_stamp, region, service)
    signature = hmac.new(signing_key, string_to_sign.encode('utf-8'), hashlib.sha256).hexdigest()
    
    authorization_header = f'AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope}, SignedHeaders={signed_headers}, Signature={signature}'
    
    url = f'{endpoint}{canonical_uri}'
    req = urllib.request.Request(url, data=body if method == 'PUT' else None, method=method)
    req.add_header('Host', 'localhost:8333')
    req.add_header('x-amz-date', amz_date)
    req.add_header('x-amz-content-sha256', payload_hash)
    req.add_header('Authorization', authorization_header)
    
    with urllib.request.urlopen(req) as resp:
        return resp.read()

try:
    print("    - Uploading object to s3://" + bucket + "/" + object_name + "...")
    send_s3_request('PUT', f'{bucket}/{object_name}', test_content)
    print("      [PASS] Upload completed successfully")

    print("    - Downloading object from s3://" + bucket + "/" + object_name + "...")
    downloaded = send_s3_request('GET', f'{bucket}/{object_name}')
    
    if downloaded.decode('utf-8').strip() == test_content.decode('utf-8').strip():
        print("      [PASS] Content integrity verified")
    else:
        print("      [FAIL] Downloaded content mismatch!")
        sys.exit(1)

    print("    - Cleaning up test object...")
    send_s3_request('DELETE', f'{bucket}/{object_name}')
    print("      [PASS] Object deleted")

except Exception as e:
    print(f"      [FAIL] S3 Lifecycle operation failed: {e}")
    sys.exit(1)
EOF

rm -f "${TEST_FILE}" "${DOWNLOAD_FILE}" 2>/dev/null || true

echo ""
echo "========================================================================="
echo "                  S3 SANITY TEST SUCCESSFUL!"
echo "========================================================================="
