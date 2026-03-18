#!/bin/bash
# =============================================================================
# init-solr.sh
#
# Initialises a SolrCloud cluster for Sitecore 10.4.0 XM1.
#
# Steps performed:
#   1. Wait for ZooKeeper quorum to be reachable
#   2. Wait for at least one Solr node to be ready
#   3. Upload security.json to ZooKeeper (enables BasicAuth on all nodes)
#   4. Upload the "Sitecore" configset to ZooKeeper
#   5. Create the 10 XM1 Solr collections (skips any that already exist)
#
# Required environment variables:
#   ZK_HOST            ZooKeeper connection string, e.g. zookeeper:2181
#                      For a 3-node cluster:
#                        zk-0.zookeeper:2181,zk-1.zookeeper:2181,zk-2.zookeeper:2181
#   SOLR_ENDPOINT      Base Solr URL, e.g. http://solr:8983/solr
#   SOLR_CORE_PREFIX   Prefix for all collection names (default: sitecore)
#   SOLR_REPLICAS      replicationFactor for each collection (default: 1)
#   SOLR_SHARDS        numShards per collection (default: 1)
#   SOLR_ADMIN_USER    Solr admin username for API calls (default: admin)
#   SOLR_ADMIN_PASSWORD Solr admin password
#   SECURITY_JSON_PATH  Path to security.json to upload (default: /tmp/security.json)
#   CONFIGSET_DIR       Path to the Sitecore configset conf/ dir
#                       (default: /configsets/Sitecore/conf)
#
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ZK_HOST="${ZK_HOST:-zookeeper:2181}"
SOLR_ENDPOINT="${SOLR_ENDPOINT:-http://solr:8983/solr}"
SOLR_CORE_PREFIX="${SOLR_CORE_PREFIX:-sitecore}"
SOLR_REPLICAS="${SOLR_REPLICAS:-1}"
SOLR_SHARDS="${SOLR_SHARDS:-1}"
SOLR_ADMIN_USER="${SOLR_ADMIN_USER:-admin}"
SOLR_ADMIN_PASSWORD="${SOLR_ADMIN_PASSWORD:-admin}"
SECURITY_JSON_PATH="${SECURITY_JSON_PATH:-/tmp/security.json}"
CONFIGSET_DIR="${CONFIGSET_DIR:-/configsets/Sitecore/conf}"
CONFIGSET_NAME="Sitecore"

# Retry settings
MAX_RETRIES=60
RETRY_INTERVAL=5

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# Extracts the first ZK host:port pair for commands that only accept one node
zk_first() { echo "${ZK_HOST%%,*}"; }

wait_for_zookeeper() {
  log "Waiting for ZooKeeper at ${ZK_HOST} ..."
  local zk_host
  zk_host="$(zk_first)"
  local host="${zk_host%%:*}"
  local port="${zk_host##*:}"
  local attempt=0
  until echo "ruok" | nc -w 2 "${host}" "${port}" 2>/dev/null | grep -q "imok"; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $MAX_RETRIES ]]; then
      log "ERROR: ZooKeeper did not become ready after ${MAX_RETRIES} attempts. Aborting."
      exit 1
    fi
    log "  ZooKeeper not ready (attempt ${attempt}/${MAX_RETRIES}), retrying in ${RETRY_INTERVAL}s ..."
    sleep "${RETRY_INTERVAL}"
  done
  log "ZooKeeper is ready."
}

wait_for_solr() {
  log "Waiting for Solr at ${SOLR_ENDPOINT} ..."
  local attempt=0
  local http_code
  until http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        "${SOLR_ENDPOINT}/admin/info/system" 2>/dev/null) && \
        [[ "${http_code}" =~ ^(200|401)$ ]]; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $MAX_RETRIES ]]; then
      log "ERROR: Solr did not become ready after ${MAX_RETRIES} attempts. Aborting."
      exit 1
    fi
    log "  Solr not ready (attempt ${attempt}/${MAX_RETRIES}, http=${http_code:-none}), retrying in ${RETRY_INTERVAL}s ..."
    sleep "${RETRY_INTERVAL}"
  done
  log "Solr is ready (http=${http_code})."
}

# Wait until Solr responds with 200 (unauthenticated, used right after BasicAuth
# is bootstrapped with blockUnknown:false and no credentials yet)
wait_for_solr_open() {
  log "Waiting for Solr to accept unauthenticated requests ..."
  local attempt=0
  local http_code
  until http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        "${SOLR_ENDPOINT}/admin/info/system" 2>/dev/null) && \
        [[ "${http_code}" == "200" ]]; do
    attempt=$(( attempt + 1 ))
    if [[ $attempt -ge $MAX_RETRIES ]]; then
      log "ERROR: Solr not open after ${MAX_RETRIES} attempts (last http=${http_code})."
      exit 1
    fi
    log "  Not open yet (attempt ${attempt}/${MAX_RETRIES}, http=${http_code:-none}), retrying in ${RETRY_INTERVAL}s ..."
    sleep "${RETRY_INTERVAL}"
  done
  log "Solr is open (http=200)."
}

# ---------------------------------------------------------------------------
# Step 1 & 2: Wait for dependencies
# ---------------------------------------------------------------------------
wait_for_zookeeper
wait_for_solr

# ---------------------------------------------------------------------------
# Step 3: Bootstrap BasicAuth via the Solr Security API
#
# Strategy (avoids pre-hashing passwords):
#   a) Upload a minimal security.json with blockUnknown:false and no users.
#      Solr reloads it hot from ZooKeeper.
#   b) Wait for unauthenticated access to return 200.
#   c) Use the Authentication API (no creds needed yet) to set users.
#      Solr hashes the passwords internally using its own algorithm.
#   d) Set blockUnknown:true to require auth for all requests.
# ---------------------------------------------------------------------------
if [[ -f "${SECURITY_JSON_PATH}" ]]; then
  # Check if auth is already configured (idempotent re-runs)
  existing_http=$(curl -s -o /dev/null -w '%{http_code}' \
    -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    "${SOLR_ENDPOINT}/admin/info/system" 2>/dev/null)

  if [[ "${existing_http}" == "200" ]]; then
    log "Solr auth already configured and credentials valid — skipping auth bootstrap."
  else
    log "Bootstrapping Solr BasicAuth ..."

    log "  Uploading minimal security.json (blockUnknown:false) to ZooKeeper ..."
    /opt/solr/bin/solr zk cp \
      "file:${SECURITY_JSON_PATH}" \
      "zk:/security.json" \
      -z "${ZK_HOST}"
    log "  security.json uploaded."

    # Wait for Solr to reload the security config (becomes open/unauthenticated)
    wait_for_solr_open

    log "  Setting users via Solr Authentication API ..."
    set_user_response=$(curl -s \
      "${SOLR_ENDPOINT}/admin/authentication" \
      -H 'Content-type:application/json' \
      -d "{\"set-user\": {\"${SOLR_ADMIN_USER}\": \"${SOLR_ADMIN_PASSWORD}\", \"${SITECORE_SOLR_USER:-sitecore}\": \"${SITECORE_SOLR_PASSWORD:-SolrRocks}\"}}")
    set_status=$(echo "${set_user_response}" | grep -o '"status":[0-9]*' | head -1 | cut -d: -f2 || true)
    if [[ "${set_status}" != "0" ]]; then
      log "  ERROR: set-user failed. Response: ${set_user_response}"
      exit 1
    fi
    log "  Users set."

    log "  Setting blockUnknown:true to require authentication ..."
    curl -s \
      "${SOLR_ENDPOINT}/admin/authentication" \
      -H 'Content-type:application/json' \
      -d '{"set-property": {"blockUnknown": true}}' > /dev/null
    log "  Solr BasicAuth fully configured."

    # Update the authorization plugin with correct user-role mappings
    log "  Updating user-role mappings ..."
    curl -s \
      -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
      "${SOLR_ENDPOINT}/admin/authorization" \
      -H 'Content-type:application/json' \
      -d "{\"set-user-role\": {\"${SOLR_ADMIN_USER}\": \"admin\", \"${SITECORE_SOLR_USER:-sitecore}\": \"sitecore\"}}" > /dev/null
    log "  Authorization configured."
  fi
else
  log "WARNING: ${SECURITY_JSON_PATH} not found - skipping auth setup."
  log "         Solr will run without authentication."
fi

# ---------------------------------------------------------------------------
# Step 4: Upload the Sitecore configset to ZooKeeper
# ---------------------------------------------------------------------------
log "Uploading configset '${CONFIGSET_NAME}' from ${CONFIGSET_DIR} ..."

# Check whether the configset already exists in ZK
if /opt/solr/bin/solr zk ls /configs -z "${ZK_HOST}" 2>/dev/null | grep -q "${CONFIGSET_NAME}"; then
  log "Configset '${CONFIGSET_NAME}' already exists in ZooKeeper - skipping upload."
else
  /opt/solr/bin/solr zk upconfig \
    -n "${CONFIGSET_NAME}" \
    -d "${CONFIGSET_DIR}" \
    -z "${ZK_HOST}"
  log "Configset '${CONFIGSET_NAME}' uploaded."
fi

# ---------------------------------------------------------------------------
# Step 5: Create XM1 collections
#
# All 10 collections required for Sitecore 10.4.0 XM1 (no xConnect/xDB).
# Each collection uses the "Sitecore" configset uploaded above.
# Existing collections are detected and skipped (idempotent).
# ---------------------------------------------------------------------------

# Full list of XM1 collection suffixes (prefix is prepended at creation time)
XM1_COLLECTIONS=(
  "core_index"
  "master_index"
  "web_index"
  "marketingdefinitions_master"
  "marketingdefinitions_web"
  "marketing_asset_index_master"
  "marketing_asset_index_web"
  "suggested_test_index"
  "fxm_master_index"
  "fxm_web_index"
)

log "Creating XM1 collections with prefix '${SOLR_CORE_PREFIX}_' ..."
log "  replicationFactor=${SOLR_REPLICAS}  numShards=${SOLR_SHARDS}"

for suffix in "${XM1_COLLECTIONS[@]}"; do
  collection="${SOLR_CORE_PREFIX}_${suffix}"

  # Check if collection already exists (curl -s: don't fail on HTTP errors)
  list_response=$(curl -s \
    -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    "${SOLR_ENDPOINT}/admin/collections?action=LIST&wt=json")
  if echo "${list_response}" | grep -q "\"${collection}\""; then
    log "  [SKIP]   ${collection} already exists."
    continue
  fi

  log "  [CREATE] ${collection} ..."
  response=$(curl -s \
    -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
    "${SOLR_ENDPOINT}/admin/collections" \
    --data-urlencode "action=CREATE" \
    --data-urlencode "name=${collection}" \
    --data-urlencode "collection.configName=${CONFIGSET_NAME}" \
    --data-urlencode "numShards=${SOLR_SHARDS}" \
    --data-urlencode "replicationFactor=${SOLR_REPLICAS}" \
    --data-urlencode "maxShardsPerNode=10" \
    --data-urlencode "property.update.autoCreateFields=false" \
    --data-urlencode "wt=json")

  status=$(echo "${response}" | grep -o '"status":[0-9]*' | head -1 | cut -d: -f2 || true)
  if [[ "${status}" == "0" ]]; then
    log "  [OK]     ${collection} created."
  else
    log "  [ERROR]  Failed to create ${collection}. Response: ${response}"
    exit 1
  fi
done

log "================================================================"
log "Sitecore 10.4.0 XM1 Solr initialisation complete."
log "Collections created with prefix: ${SOLR_CORE_PREFIX}_"
log "Configset in ZooKeeper:          ${CONFIGSET_NAME}"
log "Solr endpoint:                   ${SOLR_ENDPOINT}"
log "================================================================"
