#!/usr/bin/env bash
set -euo pipefail

ACCOUNT=$(terraform output -raw account_name)
CONTAINER=$(terraform output -raw container_name)
ENDPOINT=$(terraform output -raw endpoint)
CONNECTION=$(terraform output -raw connection_string)

declare -A SAS_TOKENS
while IFS="=" read -r key val; do
  if [[ $key == sas_tokens.* ]]; then
    ident=$(echo "$key" | sed -E 's/sas_tokens\.([^.]+)\..*/\1/')
    SAS_TOKENS[$ident]=$val
  fi
done < <(terraform output -json sas_tokens | jq -r 'to_entries[] | "sas_tokens.\(.key).sas=\(.value)"')

DATE=$(date +%Y%m%d)

mkdir -p tokens
for ident in "${!SAS_TOKENS[@]}"; do
  cat > "tokens/${ident}_${DATE}.json" <<EOF
{
    "account": "${ACCOUNT}",
    "container": "${CONTAINER}",
    "endpoint": "${ENDPOINT}",
    "sasToken": "${SAS_TOKENS[$ident]}",
    "connectionString": "${CONNECTION}"
}
EOF
done