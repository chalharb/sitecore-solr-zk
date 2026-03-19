#!/usr/bin/env bash
# setup.sh — Upload configsets to ZooKeeper and create Solr collections.
#
# Expected environment variables:
#   ZK_HOST                — ZooKeeper connection string (e.g. my-zk-client:2181)
#   SOLR_HOST              — Solr common service URL (e.g. http://my-solr-solrcloud-common)
#   SOLR_ADMIN_USER        — Solr admin username (default: admin)
#   SOLR_BOOTSTRAP_SECRET  — K8s secret name with bootstrap passwords
#   DESIRED_ADMIN_PASSWORD — The admin password we want (e.g. "admin")
#   REPLICA_OVERRIDE       — Override replicationFactor for all collections (optional)
#   CONFIGSETS_DIR         — Path to mounted configset directories (default: /configsets)
#   COLLECTIONS_FILE       — Path to collections.yml (default: /collections/collections.yml)
#
# This script is designed to run as a Kubernetes Job after ZooKeeper and SolrCloud
# are deployed. It is idempotent — safe to re-run.

set -euo pipefail

SOLR_ADMIN_USER="${SOLR_ADMIN_USER:-admin}"
CONFIGSETS_DIR="${CONFIGSETS_DIR:-/configsets}"
COLLECTIONS_FILE="${COLLECTIONS_FILE:-/collections/collections.yml}"
REPLICA_OVERRIDE="${REPLICA_OVERRIDE:-}"
DESIRED_ADMIN_PASSWORD="${DESIRED_ADMIN_PASSWORD:-admin}"

ZK_CHROOT="/solr"

log() { echo "[setup] $(date '+%H:%M:%S') $*"; }

# ---------------------------------------------------------------------------
# Helper: Read K8s secret via the in-cluster API
# ---------------------------------------------------------------------------
read_k8s_secret_key() {
  local secret_name="$1"
  local key="$2"
  local namespace
  namespace=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
  local token
  token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  local ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  local api="https://kubernetes.default.svc"

  local response
  response=$(curl -sf --cacert "$ca" \
    -H "Authorization: Bearer ${token}" \
    "${api}/api/v1/namespaces/${namespace}/secrets/${secret_name}" 2>&1) || {
    log "ERROR: Failed to read secret ${secret_name}: ${response}"
    return 1
  }
  # Extract the base64-encoded value for the given key using simple parsing
  # The secret data is JSON: {"data":{"key":"base64value",...}}
  echo "$response" | \
    sed -n 's/.*"'"${key}"'": *"\([^"]*\)".*/\1/p' | \
    base64 -d 2>/dev/null || \
  echo "$response" | \
    sed -n 's/.*"'"${key}"'": *"\([^"]*\)".*/\1/p' | \
    base64 --decode
}

# ---------------------------------------------------------------------------
# 1. Wait for ZooKeeper
# ---------------------------------------------------------------------------
log "Waiting for ZooKeeper at ${ZK_HOST} ..."
retries=0
until solr zk ls / -z "${ZK_HOST}" >/dev/null 2>&1; do
  retries=$((retries + 1))
  if [ "$retries" -ge 60 ]; then
    log "ERROR: ZooKeeper not reachable after 60 attempts. Exiting."
    exit 1
  fi
  sleep 5
done
log "ZooKeeper is ready."

# ---------------------------------------------------------------------------
# 2. Upload configsets
# ---------------------------------------------------------------------------
log "Uploading configsets from ${CONFIGSETS_DIR} ..."

# Ensure the chroot exists first
solr zk mkroot "${ZK_CHROOT}" -z "${ZK_HOST}" 2>/dev/null || true

for cs_dir in "${CONFIGSETS_DIR}"/*/; do
  cs_name=$(basename "$cs_dir")
  if [ -d "${cs_dir}conf" ]; then
    conf_path="${cs_dir}conf"
  else
    conf_path="${cs_dir}"
  fi
  log "  Uploading configset '${cs_name}' from ${conf_path} ..."
  solr zk upconfig -n "${cs_name}" -d "${conf_path}" -z "${ZK_HOST}${ZK_CHROOT}"
  log "  Configset '${cs_name}' uploaded."
done
log "All configsets uploaded."

# ---------------------------------------------------------------------------
# 3. Read the bootstrap admin password from the K8s secret
# ---------------------------------------------------------------------------
log "Reading bootstrap admin password from secret ${SOLR_BOOTSTRAP_SECRET} ..."
ADMIN_PASSWORD=""
retries=0
while [ -z "$ADMIN_PASSWORD" ]; do
  ADMIN_PASSWORD=$(read_k8s_secret_key "$SOLR_BOOTSTRAP_SECRET" "admin" 2>/dev/null) || true
  if [ -z "$ADMIN_PASSWORD" ]; then
    retries=$((retries + 1))
    if [ "$retries" -ge 60 ]; then
      log "ERROR: Could not read bootstrap secret after 60 attempts."
      exit 1
    fi
    log "  Secret not ready yet, waiting..."
    sleep 5
  fi
done
log "Bootstrap password retrieved."

# ---------------------------------------------------------------------------
# 4. Wait for Solr
# ---------------------------------------------------------------------------
log "Waiting for Solr at ${SOLR_HOST} ..."
retries=0
until curl -sf -u "${SOLR_ADMIN_USER}:${ADMIN_PASSWORD}" \
  "${SOLR_HOST}/solr/admin/info/system" >/dev/null 2>&1; do
  retries=$((retries + 1))
  if [ "$retries" -ge 120 ]; then
    log "ERROR: Solr not reachable after 120 attempts. Exiting."
    exit 1
  fi
  sleep 5
done
log "Solr is ready."

# ---------------------------------------------------------------------------
# 5. Create collections
# ---------------------------------------------------------------------------
log "Reading collections from ${COLLECTIONS_FILE} ..."

# Simple YAML parser for our known format — no yq dependency.
parse_collections() {
  local name="" configset="" shards="" replicas=""
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.+) ]]; then
      if [ -n "$name" ]; then
        echo "${name}|${configset}|${shards}|${replicas}"
      fi
      name="${BASH_REMATCH[1]}"
      configset="" shards="" replicas=""
    elif [[ "$line" =~ ^[[:space:]]*configset:[[:space:]]*(.+) ]]; then
      configset="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*shards:[[:space:]]*(.+) ]]; then
      shards="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*replicas:[[:space:]]*(.+) ]]; then
      replicas="${BASH_REMATCH[1]}"
    fi
  done < "$COLLECTIONS_FILE"
  if [ -n "$name" ]; then
    echo "${name}|${configset}|${shards}|${replicas}"
  fi
}

# Get list of existing collections
existing=$(curl -sf -u "${SOLR_ADMIN_USER}:${ADMIN_PASSWORD}" \
  "${SOLR_HOST}/solr/admin/collections?action=LIST" 2>/dev/null || echo "")

parse_collections | while IFS='|' read -r name configset shards replicas; do
  if [ -n "$REPLICA_OVERRIDE" ]; then
    replicas="$REPLICA_OVERRIDE"
  fi
  shards="${shards:-1}"
  replicas="${replicas:-1}"

  if echo "$existing" | grep -q "\"${name}\""; then
    log "  Collection '${name}' already exists, skipping."
    continue
  fi

  log "  Creating collection '${name}' (configset=${configset}, shards=${shards}, replicas=${replicas}) ..."
  response=$(curl -sf -u "${SOLR_ADMIN_USER}:${ADMIN_PASSWORD}" \
    "${SOLR_HOST}/solr/admin/collections?action=CREATE&name=${name}&numShards=${shards}&replicationFactor=${replicas}&collection.configName=${configset}" 2>&1) || {
    log "  ERROR creating collection '${name}': ${response}"
    continue
  }
  log "  Collection '${name}' created."
done

# ---------------------------------------------------------------------------
# 6. Change admin password to desired value (if different from bootstrap)
# ---------------------------------------------------------------------------
if [ "$ADMIN_PASSWORD" != "$DESIRED_ADMIN_PASSWORD" ]; then
  log "Changing admin password to desired value ..."
  response=$(curl -sf -u "${SOLR_ADMIN_USER}:${ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{\"set-user\": {\"admin\": \"${DESIRED_ADMIN_PASSWORD}\"}}" \
    "${SOLR_HOST}/solr/admin/authentication" 2>&1) || {
    log "WARNING: Failed to change admin password: ${response}"
    log "You can change it manually via the Solr Security API."
  }
  log "Admin password changed."
else
  log "Bootstrap password matches desired password, no change needed."
fi

log "Setup complete."
