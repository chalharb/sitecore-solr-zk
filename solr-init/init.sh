#!/usr/bin/env bash
set -euo pipefail

SOLR_URL="${SOLR_URL:?SOLR_URL env var required}"
COLLECTIONS_FILE="/init/collections.yml"
MAX_WAIT=300
INTERVAL=10

# Accept self-signed TLS certs (internal cluster CA)
CURL="curl -sfk"

# ── 1. Wait for Solr ──────────────────────────────────────────────────────────
echo "Waiting for Solr at ${SOLR_URL}..."
elapsed=0
until $CURL "${SOLR_URL}/solr/admin/info/system" > /dev/null; do
  if [ $elapsed -ge $MAX_WAIT ]; then
    echo "ERROR: Solr not ready after ${MAX_WAIT}s"
    exit 1
  fi
  echo "  Not ready, retrying in ${INTERVAL}s..."
  sleep $INTERVAL
  elapsed=$((elapsed + INTERVAL))
done
echo "Solr is ready."

# ── 2. Upload configsets (idempotent) ─────────────────────────────────────────
upload_configset() {
  local name="$1"
  local zip="/init/${name}.zip"

  existing=$($CURL "${SOLR_URL}/solr/admin/configs?action=LIST" \
    | grep -o "\"${name}\"" || true)

  if [ -n "$existing" ]; then
    echo "Configset '${name}' already exists — skipping."
  else
    echo "Uploading configset '${name}'..."
    $CURL -X POST \
      "${SOLR_URL}/solr/admin/configs?action=UPLOAD&name=${name}" \
      --header "Content-Type: application/octet-stream" \
      --data-binary @"${zip}"
    echo "Configset '${name}' uploaded."
  fi
}

upload_configset "sitecore"
upload_configset "hut"

# ── 3. Create collections (idempotent) ────────────────────────────────────────
count=$(yq '.collections | length' "${COLLECTIONS_FILE}")

for i in $(seq 0 $((count - 1))); do
  NAME=$(yq ".collections[${i}].name"     "${COLLECTIONS_FILE}")
  CONFIGSET=$(yq ".collections[${i}].configset"  "${COLLECTIONS_FILE}")
  SHARDS=$(yq ".collections[${i}].shards"   "${COLLECTIONS_FILE}")
  REPLICAS=$(yq ".collections[${i}].replicas" "${COLLECTIONS_FILE}")

  existing=$($CURL "${SOLR_URL}/solr/admin/collections?action=LIST" \
    | grep -o "\"${NAME}\"" || true)

  if [ -n "$existing" ]; then
    echo "Collection '${NAME}' already exists — skipping."
  else
    echo "Creating collection '${NAME}' (configset=${CONFIGSET}, shards=${SHARDS}, replicas=${REPLICAS})..."
    $CURL \
      "${SOLR_URL}/solr/admin/collections?action=CREATE\
&name=${NAME}\
&collection.configName=${CONFIGSET}\
&numShards=${SHARDS}\
&replicationFactor=${REPLICAS}"
    echo "Collection '${NAME}' created."
  fi
done

echo "solr-init complete."
