#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$ROOT_DIR/certs"
CERT_PATH="$CERT_DIR/extenddb-cert.pem"
CONTAINER="${CONTAINER:-extenddb}"

echo "Waiting for container '$CONTAINER' to be running..."
for i in $(seq 1 20); do
  STATUS="$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)"
  if [ "$STATUS" = "true" ]; then break; fi
  echo "  attempt $i/20 — not running yet, retrying in 2s..."
  sleep 2
done

if [ "$STATUS" != "true" ]; then
  echo "Error: container '$CONTAINER' is not running." >&2
  exit 1
fi

mkdir -p "$CERT_DIR"
echo "Copying certificate from $CONTAINER:/root/.extenddb/tls/cert.pem ..."
docker cp "$CONTAINER":/root/.extenddb/tls/cert.pem "$CERT_PATH"

echo "Certificate written to: $CERT_PATH"
echo
echo "To use with AWS CLI, export:"
echo "  export AWS_CA_BUNDLE=\"$CERT_PATH\""
