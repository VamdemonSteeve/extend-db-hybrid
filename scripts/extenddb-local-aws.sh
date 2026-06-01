#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$ROOT_DIR/certs"
CERT_PATH="$CERT_DIR/extenddb-cert.pem"
ENV_PATH="$CERT_DIR/extenddb-aws-env.sh"
CREDENTIALS_PATH="$CERT_DIR/extenddb-credentials"

ENDPOINT_URL="${ENDPOINT_URL:-https://127.0.0.1:6688}"
AWS_REGION_VALUE="${AWS_REGION:-us-east-1}"
AWS_PROFILE_VALUE="${AWS_PROFILE:-extenddb-local}"
EXTENDB_ADMIN_USER="${EXTENDB_ADMIN_USER:-admin}"
EXTENDB_IAM_USER="${EXTENDB_IAM_USER:-local-user}"

create_extenddb_access_key() {
  local account_id="$1"
  local admin_password="$2"
  local key_json access_key_id secret_access_key

  docker exec -e EXTENDDB_PASSWORD="$admin_password" extenddb sh -lc \
    "extenddb manage --config /app/extenddb.toml --endpoint https://127.0.0.1:8000 --user $EXTENDB_ADMIN_USER create-user --account-id $account_id --user-name $EXTENDB_IAM_USER || true" >/dev/null 2>&1 || true

  docker exec -e EXTENDDB_PASSWORD="$admin_password" extenddb sh -lc \
    "extenddb manage --config /app/extenddb.toml --endpoint https://127.0.0.1:8000 --user $EXTENDB_ADMIN_USER put-user-policy --account-id $account_id --user-name $EXTENDB_IAM_USER --policy-name full-access --policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"dynamodb:*\",\"Resource\":\"*\"}]}'" >/dev/null 2>&1 || true

  key_json="$(docker exec -e EXTENDDB_PASSWORD="$admin_password" extenddb sh -lc \
    "extenddb manage --config /app/extenddb.toml --endpoint https://127.0.0.1:8000 --user $EXTENDB_ADMIN_USER create-access-key --account-id $account_id --user-name $EXTENDB_IAM_USER" 2>&1 || true)"

  access_key_id="$(printf '%s\n' "$key_json" | sed -n 's/.*"access_key_id": "\([^"]*\)".*/\1/p' | head -n 1)"
  secret_access_key="$(printf '%s\n' "$key_json" | sed -n 's/.*"secret_access_key": "\([^"]*\)".*/\1/p' | head -n 1)"

  if [ -z "$access_key_id" ] || [ -z "$secret_access_key" ]; then
    echo "Failed to parse create-access-key output:" >&2
    echo "$key_json" >&2
    return 1
  fi

  AWS_ACCESS_KEY_ID_VALUE="$access_key_id"
  AWS_SECRET_ACCESS_KEY_VALUE="$secret_access_key"
  return 0
}

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
docker compose down -v --remove-orphans
EXTENDB_CERT_IP="$EXTENDB_CERT_IP_VALUE" docker compose up -d --build

echo "[2/4] Exporting TLS certificate from container..."
mkdir -p "$CERT_DIR"

# Wait for extenddb to generate TLS cert before copying it to host.
for i in $(seq 1 30); do
  if docker exec extenddb sh -lc '[ -f /root/.extenddb/tls/cert.pem ]' >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Error: /root/.extenddb/tls/cert.pem was not created in time." >&2
    echo "Recent logs:" >&2
    docker logs --tail 120 extenddb >&2 || true
    exit 1
  fi
  sleep 2
done

docker cp extenddb:/root/.extenddb/tls/cert.pem "$CERT_PATH"

EXTENDB_LOGS="$(docker logs --tail 400 extenddb 2>&1 || true)"
EXTENDB_ACCOUNT_ID_VALUE="$(printf '%s\n' "$EXTENDB_LOGS" | sed -n 's/.*Account ID: \([0-9][0-9]*\).*/\1/p' | tail -n 1)"
EXTENDB_ADMIN_PASSWORD_VALUE="$(printf '%s\n' "$EXTENDB_LOGS" | sed -n 's/.*Password: \([^[:space:]]*\).*/\1/p' | tail -n 1)"

if [ -z "$EXTENDB_ACCOUNT_ID_VALUE" ] || [ -z "$EXTENDB_ADMIN_PASSWORD_VALUE" ]; then
  echo "Error: unable to extract EXTENDB_ACCOUNT_ID or EXTENDB_ADMIN_PASSWORD from extenddb logs." >&2
  echo "Run 'docker logs extenddb --tail 200' and ensure initialization completed." >&2
  exit 1
fi

echo "[3/4] Generating local AWS credentials from ExtendDB..."
if ! create_extenddb_access_key "$EXTENDB_ACCOUNT_ID_VALUE" "$EXTENDB_ADMIN_PASSWORD_VALUE"; then
  echo "Error: unable to generate access key from ExtendDB." >&2
  echo "Check ExtendDB logs and admin credentials, then rerun." >&2
  exit 1
fi

mkdir -p "$CERT_DIR"
cat > "$CREDENTIALS_PATH" <<EOT
[$AWS_PROFILE_VALUE]
aws_access_key_id = $AWS_ACCESS_KEY_ID_VALUE
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY_VALUE
EOT

echo "[3/4] Writing local AWS env file..."
cat > "$ENV_PATH" <<EOT
export AWS_PROFILE="$AWS_PROFILE_VALUE"
export AWS_SHARED_CREDENTIALS_FILE="$CREDENTIALS_PATH"
export AWS_REGION="$AWS_REGION_VALUE"
export AWS_CA_BUNDLE="$CERT_PATH"
export EXTENDB_ACCOUNT_ID="$EXTENDB_ACCOUNT_ID_VALUE"
export EXTENDB_ADMIN_PASSWORD="$EXTENDB_ADMIN_PASSWORD_VALUE"
EOT

# shellcheck disable=SC1090
source "$ENV_PATH"

echo "[4/4] Verifying access with ListTables..."
set +e
VERIFY_OUTPUT="$(env \
  AWS_PROFILE="$AWS_PROFILE" \
  AWS_SHARED_CREDENTIALS_FILE="$AWS_SHARED_CREDENTIALS_FILE" \
  AWS_REGION="$AWS_REGION" \
  AWS_DEFAULT_REGION="$AWS_REGION" \
  AWS_CA_BUNDLE="$AWS_CA_BUNDLE" \
  AWS_DEFAULT_PROFILE= \
  AWS_SESSION_TOKEN= \
  AWS_EC2_METADATA_DISABLED=true \
  AWS_SDK_LOAD_CONFIG=0 \
  aws dynamodb list-tables --profile "$AWS_PROFILE" --endpoint-url "$ENDPOINT_URL" --region "$AWS_REGION" 2>&1)"
VERIFY_EXIT=$?
set -e

if [ $VERIFY_EXIT -ne 0 ]; then
  echo "$VERIFY_OUTPUT" >&2
  if printf '%s' "$VERIFY_OUTPUT" | grep -q 'UnrecognizedClientException'; then
    echo >&2
    echo "Credentials are invalid or outdated." >&2
    echo "Rerun this script to regenerate the local ExtendDB profile credentials." >&2
  fi
  exit $VERIFY_EXIT
fi

echo "$VERIFY_OUTPUT"

echo
echo "Done."
echo "Certificate: $CERT_PATH"
echo "Profile:     $AWS_PROFILE_VALUE"
echo "Creds file:  $CREDENTIALS_PATH"
echo "Env file:    $ENV_PATH"
echo "To reuse in new shells, run: source $ENV_PATH"
