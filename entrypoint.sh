#!/bin/sh
# entrypoint.sh — starts SeaweedFS mini server (Master, Volume, Filer, S3, WebDAV, Admin UI)
# with admin UI authentication wired from environment variables.
set -e

EXTRA_FLAGS=""
if [ -n "${S3_DOMAIN_NAME}" ]; then
  EXTRA_FLAGS="-s3.domainName=${S3_DOMAIN_NAME}"
fi

exec /usr/bin/weed mini \
  -dir=/data \
  -admin.user="${WEED_ADMIN_USER}" \
  -admin.password="${WEED_ADMIN_PASS}" \
  ${EXTRA_FLAGS}
