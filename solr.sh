#!/usr/bin/env bash
# solr.sh — Helper script for deploying Sitecore Solr to Kubernetes.
#
# Usage:
#   ./solr.sh <command> [options]
#
# Commands:
#   install-operators     Install Solr + ZooKeeper operators (once per cluster)
#   deploy-dev            Deploy dev environment (1 Solr + 1 ZK)
#   deploy-prod           Deploy prod environment (3 Solr + 3 ZK)
#   upgrade-dev           Upgrade existing dev deployment
#   upgrade-prod          Upgrade existing prod deployment
#   teardown              Uninstall the Helm release and clean up
#   status                Show status of all Solr resources
#   logs                  Show setup Job logs
#   rerun-setup           Delete and re-run the setup Job
#   port-forward          Port-forward Solr dashboard to localhost:8983
#   connect-aks           Set kubectl context to an AKS cluster
#
# Options:
#   --env-file <path>     Path to .env file (default: .env)
#   --namespace <ns>      Override namespace
#   --release <name>      Override Helm release name
#   --dry-run             Render templates without deploying
#   -y                    Skip confirmation prompts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/.env"
NAMESPACE=""
RELEASE_NAME=""
DRY_RUN=false
SKIP_CONFIRM=false

SOLR_OPERATOR_VERSION="0.9.1"
SOLR_OPERATOR_CRDS_URL="https://solr.apache.org/operator/downloads/crds/v${SOLR_OPERATOR_VERSION}/all-with-dependencies.yaml"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log()   { echo -e "${CYAN}[solr]${NC} $*"; }
ok()    { echo -e "${GREEN}[solr]${NC} $*"; }
warn()  { echo -e "${YELLOW}[solr]${NC} $*"; }
err()   { echo -e "${RED}[solr]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

confirm() {
  if $SKIP_CONFIRM; then return 0; fi
  local msg="${1:-Continue?}"
  echo -en "${YELLOW}[solr]${NC} ${msg} [y/N] "
  read -r answer
  [[ "$answer" =~ ^[Yy] ]] || { log "Aborted."; exit 0; }
}

load_env() {
  if [ -f "$ENV_FILE" ]; then
    log "Loading env from ${ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
  # Apply defaults
  NAMESPACE="${NAMESPACE:-${NAMESPACE_FROM_ARG:-${NAMESPACE:-solr}}}"
  RELEASE_NAME="${RELEASE_NAME:-${RELEASE_NAME_FROM_ARG:-${RELEASE_NAME:-sitecore}}}"
}

check_prereqs() {
  local missing=()
  command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
  command -v helm >/dev/null 2>&1    || missing+=("helm")
  if [ ${#missing[@]} -gt 0 ]; then
    die "Missing required tools: ${missing[*]}. Install them first."
  fi
}

check_cluster() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    die "Cannot connect to Kubernetes cluster. Check your kubeconfig / context."
  fi
}

wait_for_pods() {
  local ns="$1"
  local timeout="${2:-300}"
  log "Waiting for pods in namespace ${ns} to be ready (timeout: ${timeout}s) ..."

  local deadline=$((SECONDS + timeout))
  while true; do
    local not_ready
    not_ready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -v "Completed\|Running" | grep -v "1/1\|2/2\|3/3" | wc -l | tr -d ' ')
    local running
    running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep "Running" | wc -l | tr -d ' ')

    if [ "$not_ready" -eq 0 ] && [ "$running" -gt 0 ]; then
      ok "All pods ready."
      return 0
    fi

    if [ $SECONDS -ge $deadline ]; then
      warn "Timed out waiting for pods. Current state:"
      kubectl get pods -n "$ns" 2>/dev/null
      return 1
    fi

    sleep 5
  done
}

wait_for_job() {
  local ns="$1"
  local job_name="$2"
  local timeout="${3:-300}"
  log "Waiting for job ${job_name} to complete (timeout: ${timeout}s) ..."

  if kubectl wait --for=condition=complete "job/${job_name}" -n "$ns" --timeout="${timeout}s" 2>/dev/null; then
    ok "Job ${job_name} completed."
    return 0
  else
    warn "Job ${job_name} did not complete within ${timeout}s."
    kubectl logs "job/${job_name}" -n "$ns" --tail=20 2>/dev/null || true
    return 1
  fi
}

print_status() {
  local ns="$1"
  echo ""
  echo -e "${BOLD}── ZooKeeper ──${NC}"
  kubectl get zk -n "$ns" 2>/dev/null || echo "  (none)"
  echo ""
  echo -e "${BOLD}── SolrCloud ──${NC}"
  kubectl get solrcloud -n "$ns" 2>/dev/null || echo "  (none)"
  echo ""
  echo -e "${BOLD}── Pods ──${NC}"
  kubectl get pods -n "$ns" 2>/dev/null || echo "  (none)"
  echo ""
  echo -e "${BOLD}── Jobs ──${NC}"
  kubectl get jobs -n "$ns" 2>/dev/null || echo "  (none)"
  echo ""
  echo -e "${BOLD}── Services ──${NC}"
  kubectl get svc -n "$ns" 2>/dev/null || echo "  (none)"
  echo ""
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_install_operators() {
  check_prereqs
  check_cluster

  log "Installing Solr Operator v${SOLR_OPERATOR_VERSION} CRDs ..."
  if kubectl get crd solrclouds.solr.apache.org >/dev/null 2>&1; then
    log "CRDs already exist. Updating ..."
    kubectl replace -f "$SOLR_OPERATOR_CRDS_URL" 2>/dev/null || \
      kubectl create -f "$SOLR_OPERATOR_CRDS_URL"
  else
    kubectl create -f "$SOLR_OPERATOR_CRDS_URL"
  fi

  log "Adding Helm repo ..."
  helm repo add apache-solr https://solr.apache.org/charts 2>/dev/null || true
  helm repo update

  log "Installing Solr Operator (includes ZK Operator) ..."
  if helm status solr-operator -n solr-operator >/dev/null 2>&1; then
    log "Operator already installed. Upgrading ..."
    helm upgrade solr-operator apache-solr/solr-operator \
      --version "$SOLR_OPERATOR_VERSION" \
      --namespace solr-operator
  else
    helm install solr-operator apache-solr/solr-operator \
      --version "$SOLR_OPERATOR_VERSION" \
      --namespace solr-operator \
      --create-namespace
  fi

  log "Waiting for operator pods ..."
  wait_for_pods "solr-operator" 120

  ok "Operators installed."
  kubectl get pods -n solr-operator
}

cmd_deploy() {
  local env="$1"  # "dev" or "prod"
  local chart_dir="${SCRIPT_DIR}/charts/solr-${env}"

  check_prereqs
  check_cluster

  if [ ! -d "$chart_dir" ]; then
    die "Chart directory not found: ${chart_dir}"
  fi

  # Verify operators are installed
  if ! kubectl get crd solrclouds.solr.apache.org >/dev/null 2>&1; then
    die "Solr Operator CRDs not found. Run './solr.sh install-operators' first."
  fi

  log "Building Helm dependencies for solr-${env} ..."
  helm dependency build "$chart_dir" 2>&1 | grep -v "^level=INFO"

  log "Creating namespace ${NAMESPACE} (if needed) ..."
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true

  local helm_args=()
  helm_args+=(install "$RELEASE_NAME" "$chart_dir")
  helm_args+=(--namespace "$NAMESPACE")

  if $DRY_RUN; then
    log "Dry-run mode — rendering templates only."
    helm template "$RELEASE_NAME" "$chart_dir" --namespace "$NAMESPACE" 2>/dev/null
    return 0
  fi

  # Check for existing release
  if helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    warn "Release '${RELEASE_NAME}' already exists in namespace '${NAMESPACE}'."
    confirm "Upgrade instead?"
    cmd_upgrade "$env"
    return $?
  fi

  log "Deploying solr-${env} (release: ${RELEASE_NAME}, namespace: ${NAMESPACE}) ..."
  helm "${helm_args[@]}" 2>&1 | grep -v "^level=INFO"

  ok "Helm release created. Waiting for resources ..."
  echo ""

  # Wait for ZK first, then Solr, then the setup Job
  wait_for_pods "$NAMESPACE" 300
  wait_for_job "$NAMESPACE" "${RELEASE_NAME}-setup" 300

  ok "Deployment complete."
  print_status "$NAMESPACE"

  echo -e "${BOLD}Next steps:${NC}"
  echo "  Port-forward:  ./solr.sh port-forward"
  echo "  Dashboard:     http://localhost:8983/solr/  (admin / admin)"
  echo "  Status:        ./solr.sh status"
  echo "  Logs:          ./solr.sh logs"
}

cmd_upgrade() {
  local env="$1"
  local chart_dir="${SCRIPT_DIR}/charts/solr-${env}"

  check_prereqs
  check_cluster

  if ! helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    die "No existing release '${RELEASE_NAME}' found. Use 'deploy-${env}' instead."
  fi

  log "Building Helm dependencies for solr-${env} ..."
  helm dependency build "$chart_dir" 2>&1 | grep -v "^level=INFO"

  if $DRY_RUN; then
    log "Dry-run mode — rendering templates only."
    helm template "$RELEASE_NAME" "$chart_dir" --namespace "$NAMESPACE" 2>/dev/null
    return 0
  fi

  log "Upgrading solr-${env} (release: ${RELEASE_NAME}, namespace: ${NAMESPACE}) ..."
  helm upgrade "$RELEASE_NAME" "$chart_dir" --namespace "$NAMESPACE" 2>&1 | grep -v "^level=INFO"

  ok "Upgrade complete."
  print_status "$NAMESPACE"
}

cmd_teardown() {
  check_prereqs
  check_cluster

  if ! helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    warn "No Helm release '${RELEASE_NAME}' found in namespace '${NAMESPACE}'."
  else
    confirm "This will delete the Solr release '${RELEASE_NAME}' in namespace '${NAMESPACE}'. All data will be lost."
    log "Uninstalling Helm release ..."
    helm uninstall "$RELEASE_NAME" --namespace "$NAMESPACE"
  fi

  # Clean up CRs that may not be removed by Helm uninstall
  log "Cleaning up remaining resources ..."
  kubectl delete solrcloud --all -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
  kubectl delete zk --all -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

  # Remove finalizers if CRs are stuck
  for sc in $(kubectl get solrcloud -n "$NAMESPACE" -o name 2>/dev/null); do
    kubectl patch "$sc" -n "$NAMESPACE" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done

  # Delete PVCs
  if kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
    confirm "Delete persistent volume claims (PVCs) in namespace '${NAMESPACE}'?"
    kubectl delete pvc --all -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
  fi

  confirm "Delete the namespace '${NAMESPACE}'?"
  kubectl delete namespace "$NAMESPACE" --timeout=120s 2>/dev/null || true

  ok "Teardown complete."
}

cmd_status() {
  check_prereqs
  check_cluster
  print_status "$NAMESPACE"
}

cmd_logs() {
  check_prereqs
  check_cluster
  log "Setup Job logs:"
  echo ""
  kubectl logs "job/${RELEASE_NAME}-setup" -n "$NAMESPACE" 2>&1 || \
    warn "No setup job found. Has the chart been deployed?"
}

cmd_rerun_setup() {
  check_prereqs
  check_cluster

  log "Deleting existing setup Job ..."
  kubectl delete "job/${RELEASE_NAME}-setup" -n "$NAMESPACE" 2>/dev/null || true

  # Determine which chart is deployed
  local chart
  chart=$(helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json 2>/dev/null | \
    sed -n 's/.*"chart":"\([^"]*\)".*/\1/p' | head -1) || ""

  local chart_dir=""
  if [[ "$chart" == *"solr-dev"* ]]; then
    chart_dir="${SCRIPT_DIR}/charts/solr-dev"
  elif [[ "$chart" == *"solr-prod"* ]]; then
    chart_dir="${SCRIPT_DIR}/charts/solr-prod"
  else
    die "Cannot determine chart type from release. Specify manually with 'upgrade-dev' or 'upgrade-prod'."
  fi

  log "Re-deploying to recreate the Job ..."
  helm upgrade "$RELEASE_NAME" "$chart_dir" --namespace "$NAMESPACE" 2>&1 | grep -v "^level=INFO"

  wait_for_job "$NAMESPACE" "${RELEASE_NAME}-setup" 300
  ok "Setup Job re-run complete."
  cmd_logs
}

cmd_port_forward() {
  check_prereqs
  check_cluster

  local svc="${RELEASE_NAME}-solr-solrcloud-common"
  log "Port-forwarding ${svc} to localhost:8983 ..."
  log "Solr dashboard: http://localhost:8983/solr/"
  log "Login: admin / admin"
  log "Press Ctrl+C to stop."
  echo ""
  kubectl port-forward "svc/${svc}" -n "$NAMESPACE" 8983:80
}

cmd_connect_aks() {
  command -v az >/dev/null 2>&1 || die "Azure CLI (az) not found. Install it first."

  local rg="${AKS_RESOURCE_GROUP:-}"
  local cluster="${AKS_CLUSTER_NAME:-}"
  local sub="${AKS_SUBSCRIPTION:-}"

  if [ -z "$rg" ] || [ -z "$cluster" ]; then
    die "AKS_RESOURCE_GROUP and AKS_CLUSTER_NAME must be set in .env or as environment variables."
  fi

  if [ -n "$sub" ]; then
    log "Setting Azure subscription: ${sub}"
    az account set --subscription "$sub"
  fi

  log "Getting AKS credentials for ${cluster} in ${rg} ..."
  az aks get-credentials --resource-group "$rg" --name "$cluster" --overwrite-existing

  ok "kubectl context set to AKS cluster ${cluster}."
  kubectl cluster-info | head -1
}

cmd_help() {
  echo -e "${BOLD}Sitecore Solr — Kubernetes Deployment Helper${NC}"
  echo ""
  echo "Usage: ./solr.sh <command> [options]"
  echo ""
  echo -e "${BOLD}Commands:${NC}"
  echo "  install-operators   Install Solr + ZooKeeper operators (once per cluster)"
  echo "  deploy-dev          Deploy dev environment (1 Solr + 1 ZK)"
  echo "  deploy-prod         Deploy prod environment (3 Solr + 3 ZK)"
  echo "  upgrade-dev         Upgrade existing dev deployment"
  echo "  upgrade-prod        Upgrade existing prod deployment"
  echo "  teardown            Uninstall the release and clean up namespace"
  echo "  status              Show status of all Solr resources"
  echo "  logs                Show setup Job logs"
  echo "  rerun-setup         Delete and re-run the setup Job"
  echo "  port-forward        Port-forward Solr dashboard to localhost:8983"
  echo "  connect-aks         Set kubectl context to an AKS cluster"
  echo ""
  echo -e "${BOLD}Options:${NC}"
  echo "  --env-file <path>   Path to .env file (default: .env)"
  echo "  --namespace <ns>    Override namespace (default: solr)"
  echo "  --release <name>    Override Helm release name (default: sitecore)"
  echo "  --dry-run           Render templates without deploying"
  echo "  -y                  Skip confirmation prompts"
  echo ""
  echo -e "${BOLD}Examples:${NC}"
  echo "  # Local development (first time)"
  echo "  ./solr.sh install-operators"
  echo "  ./solr.sh deploy-dev"
  echo "  ./solr.sh port-forward"
  echo ""
  echo "  # Deploy prod to AKS"
  echo "  ./solr.sh connect-aks"
  echo "  ./solr.sh install-operators"
  echo "  ./solr.sh deploy-prod"
  echo ""
  echo "  # Teardown"
  echo "  ./solr.sh teardown"
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
COMMAND=""
NAMESPACE_FROM_ARG=""
RELEASE_NAME_FROM_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"; shift 2 ;;
    --namespace)
      NAMESPACE_FROM_ARG="$2"; shift 2 ;;
    --release)
      RELEASE_NAME_FROM_ARG="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    -y|--yes)
      SKIP_CONFIRM=true; shift ;;
    -h|--help|help)
      cmd_help; exit 0 ;;
    -*)
      die "Unknown option: $1. Run './solr.sh --help' for usage." ;;
    *)
      if [ -z "$COMMAND" ]; then
        COMMAND="$1"
      else
        die "Unexpected argument: $1"
      fi
      shift ;;
  esac
done

# Apply argument overrides
[ -n "$NAMESPACE_FROM_ARG" ] && NAMESPACE="$NAMESPACE_FROM_ARG"
[ -n "$RELEASE_NAME_FROM_ARG" ] && RELEASE_NAME="$RELEASE_NAME_FROM_ARG"

load_env

# Re-apply argument overrides after env load (args take priority)
[ -n "$NAMESPACE_FROM_ARG" ] && NAMESPACE="$NAMESPACE_FROM_ARG"
[ -n "$RELEASE_NAME_FROM_ARG" ] && RELEASE_NAME="$RELEASE_NAME_FROM_ARG"

case "${COMMAND}" in
  install-operators)  cmd_install_operators ;;
  deploy-dev)         cmd_deploy "dev" ;;
  deploy-prod)        cmd_deploy "prod" ;;
  upgrade-dev)        cmd_upgrade "dev" ;;
  upgrade-prod)       cmd_upgrade "prod" ;;
  teardown)           cmd_teardown ;;
  status)             cmd_status ;;
  logs)               cmd_logs ;;
  rerun-setup)        cmd_rerun_setup ;;
  port-forward)       cmd_port_forward ;;
  connect-aks)        cmd_connect_aks ;;
  "")                 cmd_help ;;
  *)                  die "Unknown command: ${COMMAND}. Run './solr.sh --help' for usage." ;;
esac
