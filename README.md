# Sitecore Solr on Kubernetes

Solr 8.11.2 + ZooKeeper deployed via the Apache Solr Operator and Pravega ZooKeeper Operator on Kubernetes. Compatible with Sitecore XM 10.4.0.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Kubernetes Cluster (Docker Desktop / AKS)          │
│                                                     │
│  ┌─────────────────┐    ┌────────────────────────┐  │
│  │ ZooKeeper        │    │ SolrCloud              │  │
│  │ Operator         │    │ Operator               │  │
│  │ (Pravega v0.2.15)│    │ (Apache v0.9.1)        │  │
│  └────────┬─────────┘    └──────────┬─────────────┘  │
│           │                         │                │
│  ┌────────▼─────────┐    ┌─────────▼──────────────┐  │
│  │ ZookeeperCluster  │◄──│ SolrCloud CR           │  │
│  │ CR (1 or 3 nodes) │    │ (1 or 3 nodes)        │  │
│  └──────────────────┘    └────────────────────────┘  │
│                                     │                │
│                          ┌──────────▼─────────────┐  │
│                          │ Setup Job              │  │
│                          │ • uploads configsets   │  │
│                          │ • creates collections  │  │
│                          └────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

| Environment | Solr Nodes | ZK Nodes | Replica Factor |
|---|---|---|---|
| Dev | 1 | 1 | 1 |
| Prod | 3 | 3 | 2 |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) with Kubernetes enabled (for local dev)
- [Helm](https://helm.sh/docs/intro/install/) v3+
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- Azure CLI (`az`) — only for AKS deployments

## Quick Start — Local Development

### 1. Install the Operators

The Solr Operator must be installed cluster-wide before deploying any SolrCloud resources. It bundles the ZooKeeper Operator as a dependency.

```bash
# Install CRDs (Solr + ZooKeeper)
kubectl create -f "https://solr.apache.org/operator/downloads/crds/v0.9.1/all-with-dependencies.yaml"

# Add the Solr Helm repo
helm repo add apache-solr https://solr.apache.org/charts
helm repo update

# Install the Solr Operator (includes ZK Operator)
helm install solr-operator apache-solr/solr-operator \
  --version 0.9.1 \
  --namespace solr-operator \
  --create-namespace

# Verify operators are running
kubectl get pods -n solr-operator
```

You should see two pods running: `solr-operator-*` and `zookeeper-operator-*`.

### 2. Build Helm Dependencies

```bash
helm dependency build charts/solr-dev
```

### 3. Deploy Dev Environment

```bash
# Create the namespace
kubectl create namespace solr

# Install the dev chart
helm install sitecore charts/solr-dev --namespace solr

# Watch resources come up
kubectl get pods -n solr -w
```

### 4. Verify

```bash
# Check ZooKeeper is ready
kubectl get zk -n solr

# Check SolrCloud is ready
kubectl get solrcloud -n solr

# Check the setup Job completed
kubectl get jobs -n solr

# View setup Job logs
kubectl logs job/sitecore-setup -n solr

# Port-forward to the Solr dashboard
kubectl port-forward svc/sitecore-solr-solrcloud-common -n solr 8983:80
```

Open http://localhost:8983/solr/ and log in with `admin` / `admin`.

### 5. Tear Down

```bash
helm uninstall sitecore --namespace solr
kubectl delete namespace solr
```

## Deploying Dev to AKS

```bash
# Set your Azure context
az account set --subscription "$AKS_SUBSCRIPTION"
az aks get-credentials --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME"

# Install operators (same as local — once per cluster)
kubectl create -f "https://solr.apache.org/operator/downloads/crds/v0.9.1/all-with-dependencies.yaml"
helm repo add apache-solr https://solr.apache.org/charts
helm repo update
helm install solr-operator apache-solr/solr-operator \
  --version 0.9.1 \
  --namespace solr-operator \
  --create-namespace

# Build dependencies and deploy
helm dependency build charts/solr-dev
kubectl create namespace solr
helm install sitecore charts/solr-dev --namespace solr
```

## Deploying Prod to AKS

```bash
# Set your Azure context
az account set --subscription "$AKS_SUBSCRIPTION"
az aks get-credentials --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME"

# Install operators (same as above — once per cluster)
kubectl create -f "https://solr.apache.org/operator/downloads/crds/v0.9.1/all-with-dependencies.yaml"
helm repo add apache-solr https://solr.apache.org/charts
helm repo update
helm install solr-operator apache-solr/solr-operator \
  --version 0.9.1 \
  --namespace solr-operator \
  --create-namespace

# Build dependencies and deploy
helm dependency build charts/solr-prod
kubectl create namespace solr
helm install sitecore charts/solr-prod --namespace solr
```

The prod chart uses:
- `storageClass: managed-premium` — Azure Premium SSD. Change to `managed-csi-premium` for CSI driver, or remove to use the cluster default.
- `reclaimPolicy: Retain` — PVs are kept after pod deletion. Important for production data.
- `replicaOverride: 2` — Each collection gets 2 replicas across 3 Solr nodes.

## Connecting Sitecore XM 10.4.0

### Connection String Format

Sitecore connects to Solr via HTTP (not directly to ZooKeeper). The connection string goes in `App_Config/ConnectionStrings.config`:

```xml
<add name="solr.search"
     connectionString="http://<solr-service>:<port>/solr;solrCloud=true" />
```

### Same Kubernetes Cluster

If Sitecore runs in the same cluster (different namespace):

```xml
<add name="solr.search"
     connectionString="http://admin:admin@sitecore-solr-solrcloud-common.solr.svc.cluster.local/solr;solrCloud=true" />
```

The service DNS pattern is: `<release>-solr-solrcloud-common.<namespace>.svc.cluster.local`

### Cross-VNet (VNet Peering)

If Sitecore is in a separate VNet peered with the AKS VNet:

1. **Expose Solr externally** — Create a Kubernetes `LoadBalancer` service or use an Ingress Controller to expose the Solr common service with a private IP from the AKS VNet:

   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: solr-internal-lb
     namespace: solr
     annotations:
       service.beta.kubernetes.io/azure-load-balancer-internal: "true"
   spec:
     type: LoadBalancer
     selector:
       solr-cloud: sitecore-solr
     ports:
       - port: 80
         targetPort: 8983
   ```

2. **Set up VNet peering** between the Sitecore VNet and the AKS VNet.

3. **Configure the connection string** using the internal load balancer IP:

   ```xml
   <add name="solr.search"
        connectionString="http://admin:admin@<internal-lb-ip>/solr;solrCloud=true" />
   ```

4. Optionally, create a **Private DNS Zone** (e.g., `solr.internal`) linked to both VNets so you can use a hostname instead of an IP.

### With Basic Auth

All connection strings should include credentials when basic auth is enabled:

```
http://admin:admin@<host>:<port>/solr;solrCloud=true
```

### Sitecore web.config

Ensure the search provider is set to Solr:

```xml
<appSettings>
  <add key="search:define" value="Solr" />
</appSettings>
```

After deployment, populate the managed schema from the Sitecore Control Panel:
**Control Panel > Indexing > Populate Solr Managed Schema > Select All > Populate**

Then rebuild indexes:
**Control Panel > Indexing > Indexing Manager > Select All > Rebuild**

## Authentication

The Solr Operator bootstraps basic auth automatically when `authenticationType: Basic` is set on the SolrCloud CR. It:

1. Generates random passwords for `admin`, `solr`, and `k8s-oper` users
2. Stores them in a K8s secret: `sitecore-solr-solrcloud-security-bootstrap`
3. Writes `security.json` to ZooKeeper with proper auth/authz rules
4. Exempts probe endpoints (`/admin/info/system`, `/admin/info/health`) from auth

The setup Job then:

1. Reads the bootstrap password from the K8s secret via the in-cluster API
2. Uses it to upload configsets and create collections
3. Changes the admin password to the desired value (`admin` by default, configurable via `solr.auth.adminPassword` in values.yaml)

To retrieve the current admin password if you've lost it:

```bash
kubectl get secret sitecore-solr-solrcloud-security-bootstrap -n solr \
  -o jsonpath='{.data.admin}' | base64 --decode
```

Note: After the setup Job changes the password, the value in the bootstrap secret will be stale. The actual password is whatever was set in `solr.auth.adminPassword`.

## Managing Configsets and Collections

### Adding a New Configset

1. Create a directory under `settings/configsets/<name>/conf/` with at least `managed-schema` and `solrconfig.xml`.
2. Add the configset name to `configsetNames` in the wrapper chart's `values.yaml`.
3. Run `helm upgrade` to re-deploy.
4. Re-run the setup Job:
   ```bash
   kubectl delete job sitecore-setup -n solr
   helm upgrade sitecore charts/solr-dev --namespace solr
   ```

### Adding a New Collection

1. Add the collection entry to `settings/collections.yml`.
2. Re-run the setup Job (same as above).

### Re-running the Setup Job

The setup Job is idempotent. It skips configsets that already exist in ZK and collections that already exist in Solr. To force a clean re-run:

```bash
kubectl delete job sitecore-setup -n solr
helm upgrade sitecore charts/solr-dev --namespace solr
```

## Configuration

All configurable values are in the wrapper chart `values.yaml` files:

| Value | Dev Default | Prod Default | Description |
|---|---|---|---|
| `zookeeper.replicas` | 1 | 3 | Number of ZK nodes |
| `solr.replicas` | 1 | 3 | Number of Solr nodes |
| `solr.javaMem` | `-Xms512m -Xmx1g` | `-Xms1g -Xmx2g` | JVM memory |
| `solr.storage.size` | 5Gi | 50Gi | Solr PVC size |
| `solr.storage.storageClass` | (default) | managed-premium | K8s storage class |
| `solr.storage.reclaimPolicy` | Delete | Retain | PV reclaim policy |
| `zookeeper.storage.size` | 2Gi | 10Gi | ZK PVC size |
| `collections.replicaOverride` | 1 | 2 | Replication factor for all collections |
| `solr.auth.adminPassword` | admin | admin | Solr admin password |

See `.env.template` for a list of environment-level variables.

## Project Structure

```
├── charts/
│   ├── solr-base/              # Shared library chart (named templates)
│   │   ├── Chart.yaml
│   │   ├── values.yaml         # Default values
│   │   └── templates/
│   │       ├── _helpers.tpl    # Name/label helpers
│   │       ├── _zookeeper.tpl  # ZookeeperCluster CR
│   │       ├── _solrcloud.tpl  # SolrCloud CR
│   │       ├── _configsets.tpl # Configset + collections ConfigMaps
│   │       └── _setup-job.tpl  # Setup Job + RBAC + script ConfigMap
│   ├── solr-dev/               # Dev wrapper chart
│   │   ├── Chart.yaml
│   │   ├── values.yaml         # 1 Solr + 1 ZK
│   │   ├── settings -> ../../settings  (symlink)
│   │   ├── scripts -> ../../scripts    (symlink)
│   │   └── templates/
│   │       └── resources.yaml  # Includes all base templates
│   └── solr-prod/              # Prod wrapper chart
│       ├── Chart.yaml
│       ├── values.yaml         # 3 Solr + 3 ZK
│       ├── settings -> ../../settings  (symlink)
│       ├── scripts -> ../../scripts    (symlink)
│       └── templates/
│           └── resources.yaml  # Includes all base templates
├── settings/
│   ├── collections.yml         # Collection definitions
│   └── configsets/
│       ├── sitecore/conf/      # Sitecore configset
│       └── hut/conf/           # HUT configset
├── scripts/
│   └── setup.sh                # Configset upload + collection creation
├── .env.template               # Environment variable template
├── PLAN.md                     # Implementation plan
└── CONVERSATION_LOG.md         # Decision log
```

## Reference Documentation

- **Apache Solr Operator**
  - GitHub: https://github.com/apache/solr-operator
  - Docs: https://solr.apache.org/operator/
  - Helm Chart: https://artifacthub.io/packages/helm/apache-solr/solr-operator
  - SolrCloud CRD Reference: https://apache.github.io/solr-operator/docs/solr-cloud/solr-cloud-crd.html

- **Pravega ZooKeeper Operator**
  - GitHub: https://github.com/pravega/zookeeper-operator
  - Helm Chart: https://charts.pravega.io

- **Sitecore Solr Configuration**
  - Managed Schemas: https://doc.sitecore.com/xp/en/developers/latest/platform-administration-and-architecture/solr-managed-schemas.html
  - Solr Search Provider: https://doc.sitecore.com/xp/en/developers/latest/platform-administration-and-architecture/configure-the-solr-search-provider.html

- **Solr 8.11**
  - Reference Guide: https://solr.apache.org/guide/8_11/
  - SolrCloud: https://solr.apache.org/guide/8_11/solrcloud.html
  - Basic Auth: https://solr.apache.org/guide/8_11/basic-authentication-plugin.html
