#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$ROOT_DIR/certs"
CERT_PATH="$CERT_DIR/extenddb-cert.pem"
ENV_PATH="$CERT_DIR/extenddb-aws-env.sh"

ENDPOINT_URL="${ENDPOINT_URL:-https://127.0.0.1:6688}"
AWS_REGION_VALUE="${AWS_REGION:-us-east-1}"

# Local ExtendDB IAM credentials generated during setup.
# Override them via environment variables if you rotate keys.
AWS_ACCESS_KEY_ID_VALUE="${AWS_ACCESS_KEY_ID:-AKIAEXTENDDB8QYQBN8S}"
AWS_SECRET_ACCESS_KEY_VALUE="${AWS_SECRET_ACCESS_KEY:-extenddbpDbPqX3/zFx2vo7LHtGbO+LlsAVj8gPY}"

cd "$ROOT_DIR"

echo "[1/4] Starting containers..."
docker compose up -d --build

echo "[2/4] Exporting TLS certificate from container..."
mkdir -p "$CERT_DIR"
docker cp extenddb:/root/.extenddb/tls/cert.pem "$CERT_PATH"

echo "[3/4] Writing local AWS env file..."
cat > "$ENV_PATH" <<EOF
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID_VALUE"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY_VALUE"
export AWS_REGION="$AWS_REGION_VALUE"
export AWS_CA_BUNDLE="$CERT_PATH"
EOF

# shellcheck disable=SC1090
source "$ENV_PATH"

echo "[4/4] Verifying access with ListTables..."
aws dynamodb list-tables --endpoint-url "$ENDPOINT_URL" --region "$AWS_REGION"

echo
echo "Done."
echo "Certificate: $CERT_PATH"
echo "Env file:    $ENV_PATH"
echo "To reuse in new shells, run: source $ENV_PATH"
