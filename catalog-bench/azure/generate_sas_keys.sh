#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./generate_sas_keys.sh <storage_account> <container> <num_tokens>
# or set via environment variables:
#   STORAGE_ACCOUNT, CONTAINER, NUM_TOKENS

STORAGE_ACCOUNT="${1:-${STORAGE_ACCOUNT:-}}"
CONTAINER="${2:-${CONTAINER:-}}"
NUM_TOKENS="${3:-${NUM_TOKENS:-5}}" # Default to 5 if not specified

if [[ -z "$STORAGE_ACCOUNT" || -z "$CONTAINER" ]]; then
  echo "Usage: $0 <storage_account> <container> [num_tokens]"
  exit 1
fi

# Try to obtain the connection string from Terraform first, then fall back to az cli
get_connection_string() {
    # if command -v terraform &>/dev/null; then
    #     # Try to get from terraform output
    #     if terraform output -raw connection_string &>/dev/null; then
    #         terraform output -raw connection_string
    #         return
    #     fi
    # fi
    # Fallback: use az cli
    az storage account show-connection-string --name "$STORAGE_ACCOUNT" --query connectionString --output tsv
}

CONNECTION_STRING=$(get_connection_string)

# Check if the container exists before proceeding
exists=$(az storage container exists \
    --name "$CONTAINER" \
    --connection-string "$CONNECTION_STRING" \
    --output tsv --query exists)

if [[ "$exists" != "true" ]]; then
    echo "ERROR: Container '$CONTAINER' does not exist in storage account '$STORAGE_ACCOUNT'."
    exit 2
fi

PERMS="racwdl"
EXPIRY=$(date -u -d "+7 days" +"%Y-%m-%dT%H:%MZ")

mkdir -p tokens
DATE=$(date +%Y%m%d)

ENDPOINT="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}"

for i in $(seq 1 "$NUM_TOKENS"); do
  SAS=$(az storage container generate-sas \
    --name "$CONTAINER" \
    --permissions "$PERMS" \
    --expiry "$EXPIRY" \
    --https-only \
    --connection-string "$CONNECTION_STRING" \
    --output tsv)

  cat > "tokens/${STORAGE_ACCOUNT}_${CONTAINER}_sas${i}_${DATE}.json" <<EOF
{
  "account": "${STORAGE_ACCOUNT}",
  "container": "${CONTAINER}",
  "endpoint": "${ENDPOINT}",
  "sasToken": "${SAS}",
  "connectionString": "${CONNECTION_STRING}"
}
EOF
done

echo "Generated $NUM_TOKENS SAS key(s) in ./tokens"
