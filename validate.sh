#!/usr/bin/env bash
set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
# ./validate.sh --context <kubectl-context> [--env dev|prod]
#
# Validates the full Solr on AKS deployment:
#   - cert-manager pods and ClusterIssuer
#   - Solr Operator pods and CRDs
#   - SolrCloud readiness, pod counts, PVCs, TLS
#   - solr-init Job, configsets, and collections
# ──────────────────────────────────────────────────────────────────────────────

CONTEXT=""
ENV=""
PASS=0
FAIL=0

usage() {
  echo "Usage: $0 --context <kubectl-context> [--env dev|prod]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    --env)     ENV="$2"; shift 2 ;;
    *)         usage ;;
  esac
done

if [ -z "$CONTEXT" ]; then
  usage
fi

KC="kubectl --context ${CONTEXT}"

# ── Helpers ───────────────────────────────────────────────────────────────────
check_pass() {
  echo "  [PASS] $1"
  PASS=$((PASS + 1))
}

check_fail() {
  echo "  [FAIL] $1"
  FAIL=$((FAIL + 1))
}

check_pods_running() {
  local ns="$1"
  local description="$2"
  not_running=$($KC get pods -n "$ns" --no-headers 2>/dev/null \
    | grep -v "Running" \
    | grep -v "Completed" || true)
  if [ -z "$not_running" ]; then
    check_pass "$description — all pods Running"
  else
    check_fail "$description — some pods not Running:"
    echo "$not_running"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Solr on AKS Validation ==="
echo "Context: ${CONTEXT}"
[ -n "$ENV" ] && echo "Environment: ${ENV}"
echo ""

# ── 1. Operators ──────────────────────────────────────────────────────────────
echo "── Operators ──"

# cert-manager pods
check_pods_running "cert-manager" "cert-manager pods"

# ClusterIssuer
issuer_ready=$($KC get clusterissuer solr-internal-ca -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "NotFound")
if [ "$issuer_ready" = "True" ]; then
  check_pass "ClusterIssuer solr-internal-ca — READY: True"
else
  check_fail "ClusterIssuer solr-internal-ca — status: ${issuer_ready}"
fi

# solr-operator pods
check_pods_running "solr-operator" "solr-operator pods"

# CRDs
if $KC get crd solrclouds.solr.apache.org > /dev/null 2>&1; then
  check_pass "CRD solrclouds.solr.apache.org — present"
else
  check_fail "CRD solrclouds.solr.apache.org — not found"
fi

if $KC get crd zookeeperclusters.zookeeper.pravega.io > /dev/null 2>&1; then
  check_pass "CRD zookeeperclusters.zookeeper.pravega.io — present"
else
  check_fail "CRD zookeeperclusters.zookeeper.pravega.io — not found"
fi

echo ""

# ── 2. SolrCloud ──────────────────────────────────────────────────────────────
echo "── SolrCloud ──"

# SolrCloud readiness
solr_ready=$($KC get solrcloud sitecore-solr -n solr -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
solr_target=$($KC get solrcloud sitecore-solr -n solr -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
if [ "$solr_ready" = "$solr_target" ] && [ "$solr_ready" != "0" ]; then
  check_pass "SolrCloud sitecore-solr — ${solr_ready}/${solr_target} ready"
else
  check_fail "SolrCloud sitecore-solr — ${solr_ready}/${solr_target} ready"
fi

# Pod counts per environment
if [ -n "$ENV" ]; then
  solr_pods=$($KC get pods -n solr -l technology=solr-cloud --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  zk_pods=$($KC get pods -n solr -l app=sitecore-solr-zookeeper --no-headers 2>/dev/null | grep -c "Running" || echo "0")

  if [ "$ENV" = "dev" ]; then
    expected_solr=1; expected_zk=1
  else
    expected_solr=3; expected_zk=3
  fi

  if [ "$solr_pods" -eq "$expected_solr" ]; then
    check_pass "${ENV}: ${solr_pods} Solr pod(s) Running (expected ${expected_solr})"
  else
    check_fail "${ENV}: ${solr_pods} Solr pod(s) Running (expected ${expected_solr})"
  fi

  if [ "$zk_pods" -eq "$expected_zk" ]; then
    check_pass "${ENV}: ${zk_pods} ZK pod(s) Running (expected ${expected_zk})"
  else
    check_fail "${ENV}: ${zk_pods} ZK pod(s) Running (expected ${expected_zk})"
  fi

  # Prod: check node and zone distribution
  if [ "$ENV" = "prod" ]; then
    echo ""
    echo "  Pod distribution (prod):"
    $KC get pods -n solr -o wide --no-headers 2>/dev/null | awk '{printf "    %-45s node=%s\n", $1, $7}'

    node_count=$($KC get pods -n solr -l technology=solr-cloud -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | wc -l | tr -d ' ')
    if [ "$node_count" -ge 3 ]; then
      check_pass "Prod Solr pods on ${node_count} distinct nodes"
    else
      check_fail "Prod Solr pods on only ${node_count} distinct node(s) (expected >= 3)"
    fi

    zone_count=$($KC get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' 2>/dev/null | sort -u | wc -l | tr -d ' ')
    if [ "$zone_count" -ge 3 ]; then
      check_pass "Cluster has ${zone_count} distinct availability zones"
    else
      check_fail "Cluster has only ${zone_count} zone(s) (expected >= 3)"
    fi
  fi
fi

# PVCs
echo ""
echo "  PVC status:"
pvcs_not_bound=$($KC get pvc -n solr --no-headers 2>/dev/null | grep -v "Bound" || true)
if [ -z "$pvcs_not_bound" ]; then
  check_pass "All PVCs in solr namespace — Bound"
else
  check_fail "Some PVCs not Bound:"
  echo "$pvcs_not_bound"
fi

# Check storageClass
sc_check=$($KC get pvc -n solr -o jsonpath='{range .items[*]}{.spec.storageClassName}{"\n"}{end}' 2>/dev/null | sort -u)
if echo "$sc_check" | grep -q "managed-premium"; then
  check_pass "PVCs use storageClass managed-premium"
else
  check_fail "PVC storageClass: ${sc_check} (expected managed-premium)"
fi

# TLS secret
tls_secret=$($KC get secrets -n solr --no-headers 2>/dev/null | grep -i "tls" || true)
if [ -n "$tls_secret" ]; then
  check_pass "TLS secret present in solr namespace"
else
  check_fail "No TLS secret found in solr namespace"
fi

echo ""

# ── 3. Configsets and Collections ─────────────────────────────────────────────
echo "── Configsets & Collections ──"

# solr-init Job
job_status=$($KC get job solr-init -n solr -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "NotFound")
if [ "$job_status" = "True" ]; then
  check_pass "solr-init Job — Completed"
else
  job_failed=$($KC get job solr-init -n solr -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
  if [ "$job_failed" = "True" ]; then
    check_fail "solr-init Job — Failed"
  else
    check_fail "solr-init Job — status: ${job_status}"
  fi
fi

# Configsets (requires port-forward or ingress — best-effort via job logs)
echo ""
echo "  Note: Configset and collection verification via Solr API requires"
echo "  network access to the Solr service. Check solr-init Job logs for details:"
echo "    $KC logs -n solr -l job-name=solr-init"

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "══════════════════════════════════════"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
