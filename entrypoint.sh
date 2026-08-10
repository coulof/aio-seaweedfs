#!/bin/sh
# entrypoint.sh — starts SeaweedFS server with admin UI auth wired from env
# (env vars are injected via Podman secrets, see seaweedfs.container)
set -e

exec /usr/bin/weed server \
  -dir=/data \
  -s3 -s3.port=8333 \
  -admin -admin.port=23646 \
  -adminUser="${WEED_ADMIN_USER}" \
  -adminPassword="${WEED_ADMIN_PASS}"
