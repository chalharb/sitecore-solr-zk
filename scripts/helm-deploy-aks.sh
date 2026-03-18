#!/bin/bash
# =============================================================================
# helm-deploy-aks.sh — Deploy sitecore-solr to AKS
#
# Sources helm/.env for credentials, cluster info, and ingress settings,
# then runs helm upgrade --install with the appropriate AKS values file.
#
# Usage:
#   cp helm/.env.example helm/.env   # first time only — fill in your values
#   ./scripts/helm-deploy-aks.sh
#
# To deploy the full 3-node HA cluster (after quota increase):
#   VALUES_FILE=helm/values-aks.yaml ./scripts/helm-deploy-aks.sh
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
# Defaults
# ---------------------------------------------------------------------------
HELM_RELEASE="${HELM_RELEASE:-sitecore-solr}"
K8S_NAMESPACE="${K8S_NAMESPACE:-sitecore-solr}"
AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:?AKS_RESOURCE_GROUP must be set in helm/.env}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:?AKS_CLUSTER_NAME must be set in helm/.env}"
AKS_STORAGE_CLASS="${AKS_STORAGE_CLASS:-managed-csi}"
SOLR_ADMIN_USER="${SOLR_ADMIN_USER:-admin}"
SOLR_ADMIN_PASSWORD="${SOLR_ADMIN_PASSWORD:?SOLR_ADMIN_PASSWORD must be set in helm/.env}"
SITECORE_SOLR_USER="${SITECORE_SOLR_USER:-sitecore}"
SITECORE_SOLR_PASSWORD="${SITECORE_SOLR_PASSWORD:?SITECORE_SOLR_PASSWORD must be set in helm/.env}"
SOLR_CORE_PREFIX="${SOLR_CORE_PREFIX:-sitecore}"
SOLR_INGRESS_HOST="${SOLR_INGRESS_HOST:?SOLR_INGRESS_HOST must be set in helm/.env}"
SOLR_TLS_SECRET="${SOLR_TLS_SECRET:-}"

# Default to the single-node values file (safe for quota-constrained subscriptions)
# Override with VALUES_FILE=helm/values-aks.yaml for the full 3-node HA setup
VALUES_FILE="${VALUES_FILE:-${REPO_ROOT}/helm/values-aks-single.yaml}"

# ---------------------------------------------------------------------------
# Get AKS credentials
# ---------------------------------------------------------------------------
echo "==> Getting AKS credentials for ${AKS_CLUSTER_NAME} ..."
az aks get-credentials \
  --resource-group "${AKS_RESOURCE_GROUP}" \
  --name "${AKS_CLUSTER_NAME}" \
  --overwrite-existing

echo "==> Deploying ${HELM_RELEASE} to AKS (namespace: ${K8S_NAMESPACE})"
echo "    Values file:  ${VALUES_FILE}"
echo "    StorageClass: ${AKS_STORAGE_CLASS}"
echo "    Ingress host: ${SOLR_INGRESS_HOST}"
echo "    Admin user:   ${SOLR_ADMIN_USER}"

# ---------------------------------------------------------------------------
# Helm deploy
# ---------------------------------------------------------------------------
helm upgrade --install "${HELM_RELEASE}" "${REPO_ROOT}/helm/sitecore-solr" \
  --namespace "${K8S_NAMESPACE}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  --set "auth.adminUser=${SOLR_ADMIN_USER}" \
  --set "auth.adminPassword=${SOLR_ADMIN_PASSWORD}" \
  --set "auth.sitecoreUser=${SITECORE_SOLR_USER}" \
  --set "auth.sitecorePassword=${SITECORE_SOLR_PASSWORD}" \
  --set "zookeeper.storage.storageClass=${AKS_STORAGE_CLASS}" \
  --set "solr.storage.storageClass=${AKS_STORAGE_CLASS}" \
  --set "solrInit.corePrefix=${SOLR_CORE_PREFIX}" \
  --set "ingress.host=${SOLR_INGRESS_HOST}" \
  --set "ingress.tlsSecretName=${SOLR_TLS_SECRET}" \
  --wait \
  --timeout 15m

echo ""
echo "==> Done."
echo ""
echo "    Dashboard (port-forward):"
echo "    kubectl port-forward -n ${K8S_NAMESPACE} svc/${HELM_RELEASE}-solr 8983:8983"
echo "    http://localhost:8983/solr  (${SOLR_ADMIN_USER} / [password from .env])"
echo ""
if [[ -n "${SOLR_TLS_SECRET}" ]]; then
  echo "    Dashboard (ingress):"
  echo "    https://${SOLR_INGRESS_HOST}/solr"
else
  echo "    Dashboard (ingress — HTTP only, no TLS configured):"
  echo "    http://${SOLR_INGRESS_HOST}/solr"
fi
echo ""
echo "    Sitecore connection string:"
echo "    http://${HELM_RELEASE}-solr.${K8S_NAMESPACE}.svc.cluster.local:8983/solr;username=${SITECORE_SOLR_USER};password=[password from .env];solrCloud=true"
