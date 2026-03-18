#!/bin/bash
# =============================================================================
# helm-deploy-local.sh — Deploy sitecore-solr to Docker Desktop Kubernetes
#
# Sources helm/.env for credentials and environment-specific settings,
# then runs helm upgrade --install with the local values file.
#
# Usage:
#   cp helm/.env.example helm/.env   # first time only — fill in your values
#   ./scripts/helm-deploy-local.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/helm/.env"

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found."
  echo "       Run: cp helm/.env.example helm/.env  then fill in your values."
  exit 1
fi
# shellcheck disable=SC1090
set -o allexport && source "${ENV_FILE}" && set +o allexport

# ---------------------------------------------------------------------------
# Defaults (can be overridden in .env)
# ---------------------------------------------------------------------------
HELM_RELEASE="${HELM_RELEASE:-sitecore-solr}"
K8S_NAMESPACE="${K8S_NAMESPACE:-sitecore-solr}"
LOCAL_STORAGE_CLASS="${LOCAL_STORAGE_CLASS:-hostpath}"
SOLR_ADMIN_USER="${SOLR_ADMIN_USER:-admin}"
SOLR_ADMIN_PASSWORD="${SOLR_ADMIN_PASSWORD:-admin}"
SITECORE_SOLR_USER="${SITECORE_SOLR_USER:-sitecore}"
SITECORE_SOLR_PASSWORD="${SITECORE_SOLR_PASSWORD:-SolrRocks}"
SOLR_CORE_PREFIX="${SOLR_CORE_PREFIX:-sitecore}"

echo "==> Deploying ${HELM_RELEASE} to local Kubernetes (namespace: ${K8S_NAMESPACE})"
echo "    StorageClass: ${LOCAL_STORAGE_CLASS}"
echo "    Admin user:   ${SOLR_ADMIN_USER}"

helm upgrade --install "${HELM_RELEASE}" "${REPO_ROOT}/helm/sitecore-solr" \
  --namespace "${K8S_NAMESPACE}" \
  --create-namespace \
  -f "${REPO_ROOT}/helm/values-local.yaml" \
  --set "auth.adminUser=${SOLR_ADMIN_USER}" \
  --set "auth.adminPassword=${SOLR_ADMIN_PASSWORD}" \
  --set "auth.sitecoreUser=${SITECORE_SOLR_USER}" \
  --set "auth.sitecorePassword=${SITECORE_SOLR_PASSWORD}" \
  --set "zookeeper.storage.storageClass=${LOCAL_STORAGE_CLASS}" \
  --set "solr.storage.storageClass=${LOCAL_STORAGE_CLASS}" \
  --set "solrInit.corePrefix=${SOLR_CORE_PREFIX}" \
  --wait \
  --timeout 10m

echo ""
echo "==> Done. Access the Solr dashboard:"
echo "    kubectl port-forward -n ${K8S_NAMESPACE} svc/${HELM_RELEASE}-solr 8983:8983"
echo "    http://localhost:8983/solr  (${SOLR_ADMIN_USER} / [password from .env])"
echo ""
echo "    Sitecore connection string:"
echo "    http://${HELM_RELEASE}-solr.${K8S_NAMESPACE}.svc.cluster.local:8983/solr;username=${SITECORE_SOLR_USER};password=[password from .env];solrCloud=true"
