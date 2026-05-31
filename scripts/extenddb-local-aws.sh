#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$ROOT_DIR/certs"
CERT_PATH="$CERT_DIR/extenddb-cert.pem"
ENV_PATH="$CERT_DIR/extenddb-aws-env.sh"

ENDPOINT_URL="${ENDPOINT_URL:-https://127.0.0.1:6688}"
AWS_REGION_VALUE="${AWS_REGION:-us-east-1}"

# Provide credentials via environment or existing env file.
AWS_ACCESS_KEY_ID_VALUE="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY_VALUE="${AWS_SECRET_ACCESS_KEY:-}"

detect_local_ip() {
  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i+1); exit}}'
    return
  fi

  if command -v route >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
    local iface
    iface="$(route get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [ -n "$iface" ]; then
      ipconfig getifaddr "$iface" 2>/dev/null || true
    fi
    return
  fi

  hostname -I 2>/dev/null | awk '{print $1}'
}

cd "$ROOT_DIR"

EXTENDB_CERT_IP_VALUE="${EXTENDB_CERT_IP:-$(detect_local_ip)}"
if [ -z "$EXTENDB_CERT_IP_VALUE" ]; then
  EXTENDB_CERT_IP_VALUE="127.0.0.1"
fi

echo "[1/4] Starting containers..."
echo "Using EXTENDB_CERT_IP=$EXTENDB_CERT_IP_VALUE"
EXTENDB_CERT_IP="$EXTENDB_CERT_IP_VALUE" docker compose up -d --build

echo "[2/4] Exporting TLS certificate from container..."
mkdir -p "$CERT_DIR"
docker cp extenddb:/root/.extenddb/tls/cert.pem "$CERT_PATH"

if [ -z "$AWS_ACCESS_KEY_ID_VALUE" ] || [ -z "$AWS_SECRET_ACCESS_KEY_VALUE" ]; then
  if [ -f "$ENV_PATH" ]; then
    # shellcheck disable=SC1090
    source "$ENV_PATH"
    AWS_ACCESS_KEY_ID_VALUE="${AWS_ACCESS_KEY_ID:-}"
    AWS_SECRET_ACCESS_KEY_VALUE="${AWS_SECRET_ACCESS_KEY:-}"
  fi
fi

if [ -z "$AWS_ACCESS_KEY_ID_VALUE" ] || [ -z "$AWS_SECRET_ACCESS_KEY_VALUE" ]; then
  echo "Error: missing ExtendDB AWS credentials." >&2
  echo "Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, then rerun." >&2
  exit 1
fi

echo "[3/4] Writing local AWS env file..."
cat > "$ENV_PATH" <<EOT
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID_VALUE"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY_VALUE"
export AWS_REGION="$AWS_REGION_VALUE"
export AWS_CA_BUNDLE="$CERT_PATH"
EOT

# shellcheck disable=SC1090
source "$ENV_PATH"

echo "[4/4] Verifying access with ListTables..."
set +e
VERIFY_OUTPUT="$(aws dynamodb list-tables --endpoint-url "$ENDPOINT_URL" --region "$AWS_REGION" 2>&1)"
VERIFY_EXIT=$?
set -e

if [ $VERIFY_EXIT -ne 0 ]; then
  echo "$VERIFY_OUTPUT" >&2
  if printf '%s' "$VERIFY_OUTPUT" | grep -q 'UnrecognizedClientException'; then
    echo >&2
    echo "Credentials are invalid or outdated." >&2
    echo "Generate a new ExtendDB access key and export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY." >&2
  fi
  exit $VERIFY_EXIT
fi

echo "$VERIFY_OUTPUT"

echo
echo "Done."
echo "Certificate: $CERT_PATH"
echo "Env file:    $ENV_PATH"
echo "To reuse in new shells, run: source $ENV_PATH"
