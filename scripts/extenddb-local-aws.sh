#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$ROOT_DIR/certs"
CERT_PATH="$CERT_DIR/extenddb-cert.pem"
ENV_PATH="$CERT_DIR/extenddb-aws-env.sh"

ENDPOINT_URL="${ENDPOINT_URL:-https://127.0.0.1:6688}"
AWS_REGION_VALUE="${AWS_REGION:-us-east-1}"
EXTENDB_ADMIN_USER="${EXTENDB_ADMIN_USER:-admin}"
EXTENDB_IAM_USER="${EXTENDB_IAM_USER:-myuser}"

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

# ExtendDB IAM credentials are environment-specific and may rotate.
# Prefer values from current shell; if missing, fall back to existing env file.
AWS_ACCESS_KEY_ID_VALUE="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY_VALUE="${AWS_SECRET_ACCESS_KEY:-}"

refresh_extenddb_access_key() {
        local admin_password account_id key_json
        local access_key_id secret_access_key

        admin_password="${EXTENDB_ADMIN_PASSWORD:-}"
        account_id="${EXTENDB_ACCOUNT_ID:-}"

        if [ -z "$admin_password" ] || [ -z "$account_id" ]; then
                local recent_logs
                recent_logs="$(docker logs --tail 300 extenddb 2>&1 || true)"
                if [ -z "$account_id" ]; then
                        account_id="$(printf '%s\n' "$recent_logs" | sed -n 's/.*Account ID: \([0-9][0-9]*\).*/\1/p' | tail -n 1)"
                fi
                if [ -z "$admin_password" ]; then
                        admin_password="$(printf '%s\n' "$recent_logs" | sed -n 's/.*Password: \([^[:space:]]*\).*/\1/p' | tail -n 1)"
                fi
        fi

        if [ -z "$admin_password" ] || [ -z "$account_id" ]; then
                return 1
        fi

        docker exec -e EXTENDDB_PASSWORD="$admin_password" extenddb sh -lc \
                "extenddb manage --config /app/extenddb.toml --endpoint https://127.0.0.1:8000 --user $EXTENDB_ADMIN_USER create-user --account-id $account_id --user-name $EXTENDB_IAM_USER || true" >/dev/null 2>&1 || true

        docker exec -e EXTENDDB_PASSWORD="$admin_password" extenddb sh -lc \
                "extenddb manage --config /app/extenddb.toml --endpoint https://127.0.0.1:8000 --user $EXTENDB_ADMIN_USER put-user-policy --account-id $account_id --user-name $EXTENDB_IAM_USER --policy-name full-access --policy-document '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"dynamodb:*\",\"Resource\":\"*\"}]}'" >/dev/null 2>&1 || true

        key_json="$(docker exec -e EXTENDDB_PASSWORD="$admin_password" extenddb sh -lc \
                "extenddb manage --config /app/extenddb.toml --endpoint https://127.0.0.1:8000 --user $EXTENDB_ADMIN_USER create-access-key --account-id $account_id --user-name $EXTENDB_IAM_USER" 2>/dev/null || true)"

        access_key_id="$(printf '%s\n' "$key_json" | sed -n 's/.*"access_key_id": "\([^"]*\)".*/\1/p' | head -n 1)"
        secret_access_key="$(printf '%s\n' "$key_json" | sed -n 's/.*"secret_access_key": "\([^"]*\)".*/\1/p' | head -n 1)"

        if [ -z "$access_key_id" ] || [ -z "$secret_access_key" ]; then
                return 1
        fi

        AWS_ACCESS_KEY_ID_VALUE="$access_key_id"
        AWS_SECRET_ACCESS_KEY_VALUE="$secret_access_key"
        return 0
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
        echo "Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in your shell and rerun." >&2
        exit 1
fi

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
set +e
VERIFY_OUTPUT="$(aws dynamodb list-tables --endpoint-url "$ENDPOINT_URL" --region "$AWS_REGION" 2>&1)"
VERIFY_EXIT=$?
set -e

if [ $VERIFY_EXIT -ne 0 ]; then
        echo "$VERIFY_OUTPUT" >&2
        if printf '%s' "$VERIFY_OUTPUT" | grep -q 'UnrecognizedClientException'; then
                echo "Detected invalid/stale credentials. Attempting to generate a fresh access key..."
                if refresh_extenddb_access_key; then
                        cat > "$ENV_PATH" <<EOF
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID_VALUE"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY_VALUE"
export AWS_REGION="$AWS_REGION_VALUE"
export AWS_CA_BUNDLE="$CERT_PATH"
EOF

                        # shellcheck disable=SC1090
                        source "$ENV_PATH"

                        VERIFY_OUTPUT="$(aws dynamodb list-tables --endpoint-url "$ENDPOINT_URL" --region "$AWS_REGION" 2>&1)"
                        VERIFY_EXIT=$?
                        if [ $VERIFY_EXIT -eq 0 ]; then
                                echo "$VERIFY_OUTPUT"
                                echo
                                echo "Refreshed credentials and verified access successfully."
                                echo "Env file updated: $ENV_PATH"
                                exit 0
                        fi
                        echo "$VERIFY_OUTPUT" >&2
                fi

                echo >&2
                echo "Unable to auto-refresh credentials." >&2
                echo "Set EXTENDB_ADMIN_PASSWORD and EXTENDB_ACCOUNT_ID, then rerun this script," >&2
                echo "or manually generate keys with 'extenddb manage create-access-key'." >&2
        fi
        exit $VERIFY_EXIT
fi

echo "$VERIFY_OUTPUT"

echo
echo "Done."
echo "Certificate: $CERT_PATH"
echo "Env file:    $ENV_PATH"
echo "To reuse in new shells, run: source $ENV_PATH"