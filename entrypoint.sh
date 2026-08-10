#!/bin/sh
# entrypoint.sh — starts SeaweedFS mini server (Master, Volume, Filer, S3, WebDAV, Admin UI)
# with admin UI authentication wired from environment variables.
set -e

exec /usr/bin/weed mini \
  -dir=/data \
  -admin.user="${WEED_ADMIN_USER}" \
  -admin.password="${WEED_ADMIN_PASS}"
