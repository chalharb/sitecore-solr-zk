# Sitecore SolrCloud on AKS

Operator-managed SolrCloud deployment for Sitecore XM on Azure Kubernetes Service. Uses the Apache Solr Operator with embedded ZooKeeper Operator, cert-manager for TLS, and Kustomize overlays for dev/prod environments.

## Architecture

Two SolrCloud deployments (dev and prod) in separate AKS clusters. The Solr Operator manages the full lifecycle of both Solr and ZooKeeper.

| | Dev | Prod |
|---|---|---|
| Solr replicas | 1 | 3 |
| ZooKeeper replicas | 1 | 3 |
| Availability zones | None | Spread across zones 1/2/3 |
| Data storage | 10Gi Premium SSD | 30Gi Premium SSD |
| JVM heap | `-Xms512m -Xmx1g` | `-Xms2g -Xmx4g` |

### Key design decisions

- **ZooKeeper** — Provisioned automatically via `zookeeperRef.provided`. The ZooKeeper Operator is installed as a separate Helm release so its CRD lifecycle is independent of the Solr Operator.
- **TLS** — cert-manager with a self-signed `ClusterIssuer`. Required by the Solr Operator for inter-pod and client TLS. Certificate rotation is automatic.
- **Configsets** — Zipped into the init container image at build time. Version-controlled and reproducible.
- **Collections** — Created by a Kubernetes Job driven by `collections.yml`. Idempotent and re-runnable.

## Repository Structure

```
├── helm/
│   ├── cert-manager/
│   │   └── values.yaml              # cert-manager Helm values
│   ├── zookeeper-operator/
│   │   └── values.yaml              # ZooKeeper Operator Helm values (standalone)
│   └── solr-operator/
│       └── values.yaml              # Solr Operator Helm values (ZK subchart disabled)
│
├── k8s/
│   ├── base/
│   │   ├── kustomization.yaml       # Kustomize base
│   │   ├── namespace.yaml           # solr namespace
│   │   ├── cluster-issuer.yaml      # Self-signed ClusterIssuer for TLS
│   │   └── solrcloud.yaml           # SolrCloud CRD (prod defaults)
│   ├── dev/
│   │   ├── kustomization.yaml       # Dev overlay
│   │   └── patch-solrcloud.yaml     # 1 replica, reduced resources, relaxed affinity
│   ├── prod/
│   │   ├── kustomization.yaml       # Prod overlay
│   │   └── patch-solrcloud.yaml     # Zone spread for Solr and ZK pods
│   └── local/
│       ├── kustomization.yaml       # Local overlay (Docker Desktop / minikube)
│       └── patch-solrcloud.yaml     # Minimal resources, hostpath storage, no affinity
│
├── solr-init/
│   ├── Dockerfile                   # Alpine image: zips configsets, runs init.sh
│   ├── init.sh                      # Waits for Solr, uploads configsets, creates collections
│   └── k8s/
│       ├── job.yaml                 # Kubernetes Job definition (AKS — pulls from ACR)
│       ├── job-local.yaml           # Kubernetes Job definition (local — uses local image)
│       └── configmap.yaml           # Reference ConfigMap (created by pipeline)
│
├── settings/
│   ├── configsets/
│   │   ├── sitecore/conf/           # Sitecore configset (schema.xml, solrconfig.xml, ...)
│   │   └── hut/conf/                # HUT configset (schema.xml, solrconfig.xml, ...)
│   └── collections.yml              # Collection-to-configset mapping
│
├── validate.sh                      # Post-deploy validation script
├── VARIABLES.md                     # Placeholder reference
└── README.md
```

## Running Locally

Since Docker Desktop (and Rancher Desktop / minikube) includes a single-node Kubernetes cluster, you can run the exact same Helm charts and Kustomize manifests locally. A `k8s/local` overlay is provided with minimal resource requests and `hostpath` storage.

This exercises the real deployment path — same operators, same CRDs, same init job — just scaled down for a laptop.

### Prerequisites

- Docker Desktop with Kubernetes enabled (or Rancher Desktop / minikube)
- `kubectl` pointing at your local cluster (`docker-desktop` context)
- `helm` v3
- Configset files in `settings/configsets/sitecore/conf/` and `settings/configsets/hut/conf/`

### 1. Install operators

Same Helm commands as AKS — they work identically on local Kubernetes:

```bash
# Add Helm repos
helm repo add jetstack https://charts.jetstack.io
helm repo add pravega https://charts.pravega.io
helm repo add apache-solr https://solr.apache.org/charts
helm repo update

# cert-manager
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.4 \
  --values helm/cert-manager/values.yaml

# Wait for cert-manager, then apply ClusterIssuer
kubectl wait --for=condition=available deployment/cert-manager \
  -n cert-manager --timeout=120s
kubectl apply -f k8s/base/cluster-issuer.yaml

# ZooKeeper Operator (installed separately — provides the CRD)
helm upgrade --install zookeeper-operator pravega/zookeeper-operator \
  --namespace solr-operator \
  --create-namespace \
  --version 0.2.15 \
  --values helm/zookeeper-operator/values.yaml

# Solr Operator (ZK subchart disabled — uses the standalone ZK operator above)
helm upgrade --install solr-operator apache-solr/solr-operator \
  --namespace solr-operator \
  --version 0.9.1 \
  --values helm/solr-operator/values.yaml
```

### 2. Deploy SolrCloud

Apply the local overlay (1 Solr + 1 ZK, reduced memory/CPU, `hostpath` storage, no affinity):

```bash
kubectl apply -k k8s/local
```

Wait for the SolrCloud to become ready:

```bash
kubectl get solrcloud sitecore-solr -n solr -w
```

### 3. Run the init job

Build the init image locally and load it into the cluster:

```bash
# Build the image (no registry push needed)
docker build -f solr-init/Dockerfile -t solr-init:local .

# Create the collections ConfigMap
kubectl create configmap solr-collections-config \
  --from-file=collections.yml=settings/collections.yml \
  --namespace solr \
  --dry-run=client -o yaml | kubectl apply -f -

# Run the init job (uses imagePullPolicy: Never)
kubectl delete job solr-init -n solr --ignore-not-found
kubectl apply -f solr-init/k8s/job-local.yaml

# Wait and check logs
kubectl wait --for=condition=complete job/solr-init \
  -n solr --timeout=5m
kubectl logs -n solr -l job-name=solr-init
```

### 4. Access Solr UI

Port-forward to reach the Solr admin UI:

```bash
kubectl port-forward svc/sitecore-solr-solrcloud-common -n solr 8983:8983
```

Then open [https://localhost:8983/solr/](https://localhost:8983/solr/) (note: HTTPS with a self-signed cert — accept the browser warning).

### Re-run init after changes

The init job is idempotent. To pick up changes to `collections.yml`:

```bash
kubectl create configmap solr-collections-config \
  --from-file=collections.yml=settings/collections.yml \
  --namespace solr \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl delete job solr-init -n solr --ignore-not-found
kubectl apply -f solr-init/k8s/job-local.yaml
```

To pick up configset changes, rebuild the image first:

```bash
docker build -f solr-init/Dockerfile -t solr-init:local .
kubectl delete job solr-init -n solr --ignore-not-found
kubectl apply -f solr-init/k8s/job-local.yaml
```

### Tear down

```bash
# Remove SolrCloud (PVCs are retained)
kubectl delete -k k8s/local

# Remove PVCs if you want a clean slate
kubectl delete pvc --all -n solr

# Uninstall operators
helm uninstall solr-operator -n solr-operator
helm uninstall zookeeper-operator -n solr-operator
helm uninstall cert-manager -n cert-manager
```

## AKS Prerequisites

- An AKS cluster (one per environment)
- `kubectl` configured with cluster contexts
- `helm` v3
- `docker` (for building the solr-init image)
- Azure Container Registry (ACR) access

## AKS Deployment

### Before you begin

1. **Add your configset files** to `settings/configsets/sitecore/conf/` and `settings/configsets/hut/conf/`. At minimum each needs `schema.xml` and `solrconfig.xml`. Ensure both `solrconfig.xml` files contain:

   ```xml
   <updateRequestProcessorChain
     name="add-unknown-fields-to-the-schema"
     default="${update.autoCreateFields:false}"
     ...>
   ```

2. **Edit `settings/collections.yml`** if you need to add, remove, or rename collections from the defaults.

3. **Replace placeholders** in `solr-init/k8s/job.yaml`:
   - `<ACR_NAME>` — your Azure Container Registry name
   - `<TAG>` — image tag (recommend Git SHA)

   See [VARIABLES.md](VARIABLES.md) for the full list.

### Phase 1 — cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.4 \
  --values helm/cert-manager/values.yaml
```

Wait for pods to be ready, then apply the ClusterIssuer:

```bash
kubectl apply -f k8s/base/cluster-issuer.yaml
```

Verify:

```bash
kubectl get pods -n cert-manager              # All Running
kubectl get clusterissuer solr-internal-ca    # READY: True
```

### Phase 2 — ZooKeeper Operator + Solr Operator

The ZooKeeper Operator is installed as a separate Helm release so that its CRD lifecycle is independent of the Solr Operator. The Solr Operator's embedded ZK subchart is disabled — it uses the standalone ZK operator instead.

```bash
helm repo add pravega https://charts.pravega.io
helm repo add apache-solr https://solr.apache.org/charts
helm repo update

# ZooKeeper Operator (provides the ZookeeperCluster CRD)
helm upgrade --install zookeeper-operator pravega/zookeeper-operator \
  --namespace solr-operator \
  --create-namespace \
  --version 0.2.15 \
  --values helm/zookeeper-operator/values.yaml

# Solr Operator (ZK subchart disabled)
helm upgrade --install solr-operator apache-solr/solr-operator \
  --namespace solr-operator \
  --version 0.9.1 \
  --values helm/solr-operator/values.yaml
```

Verify:

```bash
kubectl get pods -n solr-operator                      # All Running
kubectl get crd | grep solrclouds.solr.apache.org      # Present
kubectl get crd | grep zookeeperclusters.zookeeper     # Present
```

### Phase 3 — SolrCloud

Apply the environment-specific overlay:

```bash
# Dev
kubectl apply -k k8s/dev

# Prod
kubectl apply -k k8s/prod
```

The operator automatically provisions:
- ZooKeeper StatefulSet + services
- Solr StatefulSet + headless service
- `sitecore-solr-solrcloud-common` ClusterIP service
- PersistentVolumeClaims (Retain policy)
- TLS certificates via cert-manager

Verify:

```bash
kubectl get solrcloud sitecore-solr -n solr    # READY: True
kubectl get pods -n solr                        # All Running
kubectl get pvc -n solr                         # All Bound
```

### Phase 4 — Configsets and Collections

Build and push the init image:

```bash
# Build from repo root
docker build -f solr-init/Dockerfile \
  -t <ACR_NAME>.azurecr.io/solr-init:<TAG> .

# Push to ACR
az acr login --name <ACR_NAME>
docker push <ACR_NAME>.azurecr.io/solr-init:<TAG>
```

Create the ConfigMap and run the Job:

```bash
# Inject collections.yml as a ConfigMap
kubectl create configmap solr-collections-config \
  --from-file=collections.yml=settings/collections.yml \
  --namespace solr \
  --dry-run=client -o yaml | kubectl apply -f -

# Clean up any previous run, then apply
kubectl delete job solr-init -n solr --ignore-not-found
kubectl apply -f solr-init/k8s/job.yaml

# Wait for completion
kubectl wait --for=condition=complete job/solr-init \
  -n solr --timeout=10m

# Check logs
kubectl logs -n solr -l job-name=solr-init
```

The init job is idempotent — it skips configsets and collections that already exist.

## Validation

Run the automated validation script after deployment:

```bash
# Dev
./validate.sh --context <dev-context> --env dev

# Prod
./validate.sh --context <prod-context> --env prod
```

The script checks:
- cert-manager pods and ClusterIssuer readiness
- Solr Operator pods and CRDs
- SolrCloud readiness and correct pod counts
- Pod distribution across nodes/zones (prod)
- PVC status, storage class, and reclaim policy
- TLS secret presence
- solr-init Job completion

## Updating Collections

To add or modify collections without rebuilding the image:

1. Edit `settings/collections.yml`
2. Re-apply the ConfigMap:
   ```bash
   kubectl create configmap solr-collections-config \
     --from-file=collections.yml=settings/collections.yml \
     --namespace solr \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Re-run the Job:
   ```bash
   kubectl delete job solr-init -n solr --ignore-not-found
   kubectl apply -f solr-init/k8s/job.yaml
   ```

Existing collections are not modified or deleted — the job only creates missing ones.

## Updating Configsets

Configsets are baked into the Docker image at build time. To update:

1. Modify files under `settings/configsets/<name>/conf/`
2. Rebuild and push the image with a new tag
3. Update `<TAG>` in `solr-init/k8s/job.yaml`
4. Delete the existing configset in Solr if you need to replace it (the job skips existing configsets)
5. Re-run the Job

## Component Versions

| Component | Version |
|---|---|
| Solr | 8.11.2 |
| Solr Operator | 0.9.1 |
| cert-manager | v1.14.4 |
| ZooKeeper (Pravega) | 0.2.15 |
