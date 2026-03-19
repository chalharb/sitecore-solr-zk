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
#
# Uses perl for JSON parsing — available in the solr:8.11.2 image.
# Avoids brittle sed regex that breaks with different JSON formatting.
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

  local json
  json=$(curl -sf --cacert "$ca" \
    -H "Authorization: Bearer ${token}" \
    "${api}/api/v1/namespaces/${namespace}/secrets/${secret_name}") || {
    log "ERROR: Failed to read secret ${secret_name}"
    return 1
  }

  # Parse the base64-encoded value from the K8s secret JSON using perl.
  # This handles any JSON formatting (minified, pretty-printed, etc.)
  # by first collapsing the JSON to a single line, then extracting the
  # top-level "data" object's target key.
  local b64_value
  b64_value=$(echo "$json" | perl -0777 -ne '
    # Extract the "data" block
    if (/"data"\s*:\s*\{([^}]+)\}/s) {
      my $data = $1;
      # Extract the specific key value
      if ($data =~ /"'"$key"'"\s*:\s*"([^"]+)"/) {
        print $1;
      }
    }
  ') || {
    log "ERROR: Failed to parse key '${key}' from secret JSON"
    return 1
  }

  if [ -z "$b64_value" ]; then
    log "ERROR: Key '${key}' not found in secret ${secret_name}"
    return 1
  fi

  # Decode — use base64 -d (GNU coreutils, available in Debian-based Solr image)
  echo "$b64_value" | base64 -d
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
  ADMIN_PASSWORD=$(read_k8s_secret_key "$SOLR_BOOTSTRAP_SECRET" "admin" 2>&1) || true

  # Validate: password should be non-empty and not contain error messages
  if [ -z "$ADMIN_PASSWORD" ] || [[ "$ADMIN_PASSWORD" == *"ERROR"* ]]; then
    ADMIN_PASSWORD=""
    retries=$((retries + 1))
    if [ "$retries" -ge 60 ]; then
      log "ERROR: Could not read bootstrap secret after 60 attempts."
      exit 1
    fi
    log "  Secret not ready yet, retrying... (attempt ${retries}/60)"
    sleep 5
  fi
done
log "Bootstrap password retrieved (length: ${#ADMIN_PASSWORD})."

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
    log "  Debug: trying without auth ..."
    curl -s "${SOLR_HOST}/solr/admin/info/system" 2>&1 | head -5 || true
    log "  Debug: trying with auth ..."
    curl -s -u "${SOLR_ADMIN_USER}:${ADMIN_PASSWORD}" \
      "${SOLR_HOST}/solr/admin/info/system" 2>&1 | head -5 || true
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

create_errors=0
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
  response=$(curl -s -w "\n%{http_code}" -u "${SOLR_ADMIN_USER}:${ADMIN_PASSWORD}" \
    "${SOLR_HOST}/solr/admin/collections?action=CREATE&name=${name}&numShards=${shards}&replicationFactor=${replicas}&collection.configName=${configset}" 2>&1)
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "200" ]; then
    log "  Collection '${name}' created."
  else
    log "  ERROR creating collection '${name}' (HTTP ${http_code}): ${body}"
    create_errors=$((create_errors + 1))
  fi
done

# ---------------------------------------------------------------------------
# 6. Change admin password to desired value (if different from bootstrap)
# ---------------------------------------------------------------------------
if [ "$ADMIN_PASSWORD" != "$DESIRED_ADMIN_PASSWORD" ]; then
  log "Changing admin password to desired value ..."
  response=$(curl -s -w "\n%{http_code}" -u "${SOLR_ADMIN_USER}:${ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{\"set-user\": {\"admin\": \"${DESIRED_ADMIN_PASSWORD}\"}}" \
    "${SOLR_HOST}/solr/admin/authentication" 2>&1)
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" = "200" ]; then
    # Verify the new password works
    sleep 2
    if curl -sf -u "${SOLR_ADMIN_USER}:${DESIRED_ADMIN_PASSWORD}" \
      "${SOLR_HOST}/solr/admin/info/system" >/dev/null 2>&1; then
      log "Admin password changed and verified successfully."
    else
      log "WARNING: Password change returned 200 but verification failed."
      log "  The bootstrap password may still work. Check Solr logs."
    fi
  else
    log "WARNING: Failed to change admin password (HTTP ${http_code}): ${body}"
    log "  Current admin password is the bootstrap value from the K8s secret:"
    log "  kubectl get secret ${SOLR_BOOTSTRAP_SECRET} -n \$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace) -o jsonpath='{.data.admin}' | base64 -d"
  fi
else
  log "Bootstrap password matches desired password, no change needed."
fi

log "Setup complete."
