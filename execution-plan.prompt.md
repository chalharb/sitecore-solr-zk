# Solr 8.11.2 on AKS — Execution Plan (v3)
## Operator-native SolrCloud + Configset/Collection Management

---

## Table of Contents

1. [Overview](#1-overview)
2. [Repository Structure](#2-repository-structure)
3. [Phase 1 — Helm: Cert-Manager](#3-phase-1--helm-cert-manager)
4. [Phase 2 — Helm: Solr Operator](#4-phase-2--helm-solr-operator)
5. [Phase 3 — SolrCloud Manifests (Dev + Prod)](#5-phase-3--solrcloud-manifests-dev--prod)
6. [Phase 4 — Configsets & Collection Init Job](#6-phase-4--configsets--collection-init-job)
7. [Validation Checklist](#7-validation-checklist)
8. [Key Variables Reference](#8-key-variables-reference)

---

## 1. Overview

### What is being built

Two SolrCloud deployments (dev and prod) in separate AKS clusters, managed entirely by the Apache Solr Operator. The operator provisions and manages ZooKeeper automatically via its embedded ZooKeeper Operator subchart. A one-shot Kubernetes Job handles uploading configsets and creating Sitecore collections after the cluster is ready.

### Topology

| | Dev | Prod |
|---|---|---|
| Solr replicas | 1 | 3 |
| ZooKeeper replicas | 1 | 3 |
| Availability zones | None | Spread across zones 1/2/3 |
| Storage | 10Gi Premium SSD | 30Gi Premium SSD |
| JVM heap | `-Xms512m -Xmx1g` | `-Xms2g -Xmx4g` |

### Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| ZooKeeper | Operator-embedded (`zookeeperRef.provided`) | Operator owns full ZK lifecycle — no separate manifests or operator install needed |
| TLS | cert-manager + self-signed ClusterIssuer | Required by the Solr Operator for inter-pod and client TLS; cert rotation is automatic |
| Configset delivery | Zipped into init container image at build time | Reproducible, version-controlled, no runtime downloads |
| Collection init | Kubernetes Job driven by `collections.yml` | Idempotent; re-runnable; decoupled from the image build |

---

## 2. Repository Structure

```
./
├── helm/
│   ├── cert-manager/
│   │   └── values.yaml
│   └── solr-operator/
│       └── values.yaml
│
├── k8s/
│   ├── base/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── cluster-issuer.yaml
│   │   └── solrcloud.yaml
│   ├── dev/
│   │   ├── kustomization.yaml
│   │   └── patch-solrcloud.yaml
│   └── prod/
│       ├── kustomization.yaml
│       └── patch-solrcloud.yaml
│
├── solr-init/
│   ├── Dockerfile
│   ├── init.sh
│   └── k8s/
│       ├── job.yaml
│       └── configmap.yaml
│
└── settings/
    ├── configsets/
    │   ├── sitecore/
    │   │   └── conf/
    │   │       ├── schema.xml
    │   │       ├── solrconfig.xml
    │   │       └── ...
    │   └── hut/
    │       └── conf/
    │           ├── schema.xml
    │           ├── solrconfig.xml
    │           └── ...
    └── collections.yml
```

---

## 3. Phase 1 — Helm: Cert-Manager

### Goal
Install cert-manager and create a self-signed `ClusterIssuer`. The Solr Operator requires cert-manager to issue and rotate TLS certificates for SolrCloud pods.

### Install

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.4 \
  --values helm/cert-manager/values.yaml
```

### `helm/cert-manager/values.yaml`

```yaml
installCRDs: true
replicaCount: 2
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

### `k8s/base/cluster-issuer.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: solr-internal-ca
spec:
  selfSigned: {}
```

Apply after cert-manager is ready:

```bash
kubectl apply -f k8s/base/cluster-issuer.yaml
```

### Acceptance criteria
- `kubectl get pods -n cert-manager` — all pods `Running`
- `kubectl get clusterissuer solr-internal-ca` — `READY: True`

---

## 4. Phase 2 — Helm: Solr Operator

### Goal
Install the Apache Solr Operator with its embedded ZooKeeper Operator subchart enabled. This single Helm install is all that is needed to manage both Solr and ZooKeeper via CRDs.

### Install

```bash
helm repo add apache-solr https://solr.apache.org/charts
helm repo update

helm upgrade --install solr-operator apache-solr/solr-operator \
  --namespace solr-operator \
  --create-namespace \
  --version 0.9.1 \
  --values helm/solr-operator/values.yaml
```

### `helm/solr-operator/values.yaml`

```yaml
# Enable the embedded ZooKeeper Operator subchart.
# This is what makes zookeeperRef.provided work in SolrCloud resources.
zookeeper-operator:
  install: true

replicaCount: 1

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

### Acceptance criteria
- `kubectl get pods -n solr-operator` — all pods `Running`
- `kubectl get crd | grep solr` — `solrclouds.solr.apache.org` present
- `kubectl get crd | grep zookeeper` — `zookeeperclusters.zookeeper.pravega.io` present

---

## 5. Phase 3 — SolrCloud Manifests (Dev + Prod)

### Goal
Deploy environment-specific SolrCloud instances using a Kustomize base + overlay pattern. The `zookeeperRef.provided` block in the CRD instructs the operator to provision and manage the ZooKeeper ensemble automatically — no separate ZK manifests are needed.

### `k8s/base/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: solr
```

### `k8s/base/solrcloud.yaml`

```yaml
apiVersion: solr.apache.org/v1beta1
kind: SolrCloud
metadata:
  name: sitecore-solr
  namespace: solr
spec:
  replicas: 3   # Patched per environment

  solrImage:
    repository: solr
    tag: "8.11.2"

  # The operator provisions and manages ZooKeeper automatically.
  # No separate ZK StatefulSet or operator install required.
  zookeeperRef:
    provided:
      replicas: 3   # Patched per environment
      image:
        repository: pravega/zookeeper
        tag: "0.2.15"
      persistence:
        reclaimPolicy: Retain
        spec:
          storageClassName: managed-premium
          resources:
            requests:
              storage: 5Gi   # Patched per environment
      zookeeperPod:
        affinity:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector:
                  matchLabels:
                    app: sitecore-solr-zookeeper
                topologyKey: kubernetes.io/hostname

  # Sitecore requirement: disable dynamic field creation
  solrOpts: "-Dupdate.autoCreateFields=false"

  solrJavaMem: "-Xms2g -Xmx4g"   # Patched per environment

  customSolrKubeOptions:
    podOptions:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  technology: solr-cloud
              topologyKey: kubernetes.io/hostname
      resources:
        requests:
          cpu: "1"
          memory: "5Gi"   # Patched per environment
        limits:
          cpu: "2"
          memory: "6Gi"   # Patched per environment

  dataStorage:
    persistent:
      reclaimPolicy: Retain
      pvcTemplate:
        spec:
          storageClassName: managed-premium
          resources:
            requests:
              storage: 30Gi   # Patched per environment

  solrTLS:
    restartOnTLSSecretUpdate: true
    issuerRef:
      name: solr-internal-ca
      kind: ClusterIssuer
```

### `k8s/base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - cluster-issuer.yaml
  - solrcloud.yaml
```

### `k8s/dev/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches:
  - path: patch-solrcloud.yaml
    target:
      kind: SolrCloud
      name: sitecore-solr
```

### `k8s/dev/patch-solrcloud.yaml`

```yaml
# 1 Solr + 1 ZooKeeper, reduced resources
- op: replace
  path: /spec/replicas
  value: 1

- op: replace
  path: /spec/zookeeperRef/provided/replicas
  value: 1

- op: replace
  path: /spec/zookeeperRef/provided/persistence/spec/resources/requests/storage
  value: "2Gi"

- op: replace
  path: /spec/solrJavaMem
  value: "-Xms512m -Xmx1g"

- op: replace
  path: /spec/customSolrKubeOptions/podOptions/resources/requests/memory
  value: "1.5Gi"

- op: replace
  path: /spec/customSolrKubeOptions/podOptions/resources/limits/memory
  value: "2Gi"

- op: replace
  path: /spec/dataStorage/persistent/pvcTemplate/spec/resources/requests/storage
  value: "10Gi"

# Relax anti-affinity to preferred — dev clusters may not have 3 separate nodes
- op: replace
  path: /spec/customSolrKubeOptions/podOptions/affinity/podAntiAffinity
  value:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              technology: solr-cloud
          topologyKey: kubernetes.io/hostname
```

### `k8s/prod/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches:
  - path: patch-solrcloud.yaml
    target:
      kind: SolrCloud
      name: sitecore-solr
```

### `k8s/prod/patch-solrcloud.yaml`

```yaml
# Prod uses base defaults (3+3) — add zone spread on top of hostname spread

# Zone spread for Solr pods
- op: add
  path: /spec/customSolrKubeOptions/podOptions/affinity/podAntiAffinity/requiredDuringSchedulingIgnoredDuringExecution/-
  value:
    labelSelector:
      matchLabels:
        technology: solr-cloud
    topologyKey: topology.kubernetes.io/zone

# Zone spread for ZooKeeper pods
- op: add
  path: /spec/zookeeperRef/provided/zookeeperPod/affinity/podAntiAffinity/requiredDuringSchedulingIgnoredDuringExecution/-
  value:
    labelSelector:
      matchLabels:
        app: sitecore-solr-zookeeper
    topologyKey: topology.kubernetes.io/zone
```

### Apply

```bash
# Dev cluster context
kubectl apply -k k8s/dev

# Prod cluster context
kubectl apply -k k8s/prod
```

### What the operator provisions automatically

Once the `SolrCloud` resource is applied, no further action is needed. The operator creates and manages:

- ZookeeperCluster StatefulSet + services
- Solr StatefulSet + headless service
- `sitecore-solr-solrcloud-common` ClusterIP service (used by the init job)
- PersistentVolumeClaims (Retain policy — survives pod deletion)
- TLS certificate via cert-manager

### Acceptance criteria
- `kubectl get solrcloud sitecore-solr -n solr` — `READY: True`
- `kubectl get pods -n solr` — all pods `Running`
- Dev: 1 Solr pod, 1 ZK pod
- Prod: 3 Solr pods across 3 nodes/zones, 3 ZK pods across 3 nodes/zones
- `kubectl get pvc -n solr` — all PVCs `Bound`, `managed-premium`, `Retain` policy

---

## 6. Phase 4 — Configsets & Collection Init Job

### Goal
Upload the two configsets (`sitecore` and `hut`) to SolrCloud and create all required Sitecore collections as defined in `collections.yml`. Runs as a Kubernetes Job after SolrCloud is ready. The job is fully idempotent — safe to re-run.

### 6a — Configset verification

Before building the Docker image, verify both configsets satisfy the Sitecore `autoCreateFields` requirement. In **both** `settings/configsets/sitecore/conf/solrconfig.xml` and `settings/configsets/hut/conf/solrconfig.xml`, confirm the update processor chain has:

```xml
<updateRequestProcessorChain
  name="add-unknown-fields-to-the-schema"
  default="${update.autoCreateFields:false}"
  ...>
```

The `false` default here pairs with the `-Dupdate.autoCreateFields=false` JVM flag in the SolrCloud spec. Both should be set.

### 6b — `settings/collections.yml`

Populated by the user. Pre-filled with standard Sitecore XM 10.4 index names. Add, remove, or rename entries to match the actual environment. HUT collection names are placeholders.

```yaml
# settings/collections.yml
# configset must match a directory name under settings/configsets/

collections:
  # Sitecore indexes
  - name: sitecore_master_index
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_web_index
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_core_index
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_marketingdefinitions_master
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_marketingdefinitions_web
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_marketing_asset_index_master
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_marketing_asset_index_web
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_testing_index
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_suggested_test_index
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_fxm_master_index
    configset: sitecore
    shards: 1
    replicas: 1

  - name: sitecore_fxm_web_index
    configset: sitecore
    shards: 1
    replicas: 1

  # HUT indexes — replace with actual names
  - name: hut_index
    configset: hut
    shards: 1
    replicas: 1
```

### 6c — `solr-init/Dockerfile`

Build context is the repo root so the Dockerfile can reach `settings/configsets/`.

```dockerfile
FROM alpine:3.19

RUN apk add --no-cache curl bash zip yq

WORKDIR /init

# Copy configset source (stays unzipped in repo for readability/diffs)
COPY settings/configsets/sitecore ./configsets/sitecore
COPY settings/configsets/hut      ./configsets/hut

# Zip at build time — Solr Config Sets API requires a zip
RUN zip -r /init/sitecore.zip ./configsets/sitecore/conf \
 && zip -r /init/hut.zip      ./configsets/hut/conf

COPY solr-init/init.sh /init/init.sh
RUN chmod +x /init/init.sh

ENTRYPOINT ["/init/init.sh"]
```

### 6d — `solr-init/init.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SOLR_URL="${SOLR_URL:?SOLR_URL env var required}"
COLLECTIONS_FILE="/init/collections.yml"
MAX_WAIT=300
INTERVAL=10

# ── 1. Wait for Solr ──────────────────────────────────────────────────────────
echo "Waiting for Solr at ${SOLR_URL}..."
elapsed=0
until curl -sf "${SOLR_URL}/solr/admin/info/system" > /dev/null; do
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

  existing=$(curl -sf "${SOLR_URL}/solr/admin/configs?action=LIST" \
    | grep -o "\"${name}\"" || true)

  if [ -n "$existing" ]; then
    echo "Configset '${name}' already exists — skipping."
  else
    echo "Uploading configset '${name}'..."
    curl -sf -X POST \
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

  existing=$(curl -sf "${SOLR_URL}/solr/admin/collections?action=LIST" \
    | grep -o "\"${NAME}\"" || true)

  if [ -n "$existing" ]; then
    echo "Collection '${NAME}' already exists — skipping."
  else
    echo "Creating collection '${NAME}' (configset=${CONFIGSET}, shards=${SHARDS}, replicas=${REPLICAS})..."
    curl -sf \
      "${SOLR_URL}/solr/admin/collections?action=CREATE\
&name=${NAME}\
&collection.configName=${CONFIGSET}\
&numShards=${SHARDS}\
&replicationFactor=${REPLICAS}"
    echo "Collection '${NAME}' created."
  fi
done

echo "solr-init complete."
```

### 6e — `solr-init/k8s/configmap.yaml`

`collections.yml` is mounted into the Job pod at runtime so it can be updated without rebuilding the image. The pipeline injects the actual file content when applying this ConfigMap.

The pipeline step to apply it:

```bash
kubectl create configmap solr-collections-config \
  --from-file=collections.yml=settings/collections.yml \
  --namespace solr \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 6f — `solr-init/k8s/job.yaml`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: solr-init
  namespace: solr
spec:
  backoffLimit: 5
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: solr-init
          image: <ACR_NAME>.azurecr.io/solr-init:<TAG>
          env:
            - name: SOLR_URL
              # The Solr Operator automatically creates this service.
              # Name pattern: <solrcloud-name>-solrcloud-common.<namespace>
              value: "https://sitecore-solr-solrcloud-common.solr:8983"
          volumeMounts:
            - name: collections-config
              mountPath: /init/collections.yml
              subPath: collections.yml
      volumes:
        - name: collections-config
          configMap:
            name: solr-collections-config
```

### Build, push, and run

```bash
# Build from repo root
docker build -f solr-init/Dockerfile \
  -t <ACR_NAME>.azurecr.io/solr-init:<TAG> .

# Push to ACR
az acr login --name <ACR_NAME>
docker push <ACR_NAME>.azurecr.io/solr-init:<TAG>

# Apply ConfigMap with live collections.yml
kubectl create configmap solr-collections-config \
  --from-file=collections.yml=settings/collections.yml \
  --namespace solr \
  --dry-run=client -o yaml | kubectl apply -f -

# Clean up any previous run, then apply
kubectl delete job solr-init -n solr --ignore-not-found
kubectl apply -f solr-init/k8s/job.yaml

# Watch for completion
kubectl wait --for=condition=complete job/solr-init \
  -n solr --timeout=10m

kubectl logs -n solr -l job-name=solr-init
```

### Acceptance criteria
- Job status: `Completed`
- `curl "${SOLR_URL}/solr/admin/configs?action=LIST"` — returns `sitecore` and `hut`
- `curl "${SOLR_URL}/solr/admin/collections?action=LIST"` — returns all collection names from `collections.yml`
- Solr admin UI (`/solr/#/~collections`) — each collection shows the correct `configName`

---

## 7. Validation Checklist

The AI agent should generate a `validate.sh` script that accepts a `--context <kubectl-context>` flag and automates all checks below.

### Operators
- [ ] `kubectl get pods -n cert-manager` — all Running
- [ ] `kubectl get clusterissuer solr-internal-ca` — READY: True
- [ ] `kubectl get pods -n solr-operator` — all Running
- [ ] `kubectl get crd | grep solrclouds` — present
- [ ] `kubectl get crd | grep zookeeperclusters` — present

### SolrCloud
- [ ] `kubectl get solrcloud sitecore-solr -n solr` — READY: True
- [ ] Dev: exactly 1 Solr pod + 1 ZK pod Running
- [ ] Prod: exactly 3 Solr pods + 3 ZK pods Running
- [ ] Prod: pods distributed across 3 nodes (`kubectl get pods -n solr -o wide`)
- [ ] Prod: pods on 3 distinct `topology.kubernetes.io/zone` values
- [ ] All PVCs Bound, storageClass `managed-premium`, reclaimPolicy `Retain`
- [ ] TLS secret present in `solr` namespace

### Configsets and collections
- [ ] `solr-init` Job status is `Completed` (not `Failed`)
- [ ] Configsets `sitecore` and `hut` listed in Solr admin
- [ ] All collections from `collections.yml` listed in Solr admin
- [ ] Each collection shows correct `configName` in Solr admin

---

## 8. Key Variables Reference

The AI agent should scan all files and produce a `VARIABLES.md` at the repo root listing every placeholder before execution begins.

| Placeholder | File | Description |
|---|---|---|
| `<ACR_NAME>` | `solr-init/k8s/job.yaml`, build commands | Azure Container Registry name |
| `<TAG>` | `solr-init/k8s/job.yaml`, build commands | Image tag — recommend Git SHA |
| `settings/collections.yml` | `solr-init/k8s/configmap.yaml` | User-populated index-to-configset mapping |

---

*Plan version 3.0 — Solr 8.11.2 | Solr Operator 0.9.1 | cert-manager v1.14.4 | Helm + Kustomize*