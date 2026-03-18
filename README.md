# sitecore-solr

SolrCloud + ZooKeeper cluster configuration for **Sitecore 10.4.0 XM1**, deployable to:

- **Docker Desktop** (plain Compose — no Kubernetes required)
- **Docker Desktop with Kubernetes enabled** (single-node, lightweight)
- **AKS** (3-node HA cluster with NGINX Ingress)

Includes the default Sitecore configset, BasicAuth (admin/admin for local, change before AKS), and all 10 XM1 collections created on first boot.

---

## Versions

| Component | Version |
|---|---|
| Sitecore XM1 | 10.4.0 |
| Solr | 8.11.2 |
| ZooKeeper | 3.8 |

---

## Repository structure

```
sitecore-solr/
├── .gitignore
├── configsets/
│   └── Sitecore/conf/          Sitecore managed-schema + solrconfig.xml
├── docker/
│   ├── docker-compose.yml      Single-node dev (no K8s)
│   ├── security.json           BasicAuth bootstrap config
│   ├── .env.example            Template — copy to .env and fill in values
│   └── .env                    Local credentials/settings (gitignored)
├── helm/
│   ├── sitecore-solr/          Helm chart
│   │   ├── Chart.yaml
│   │   ├── values.yaml         Default values (local single-node)
│   │   ├── templates/          All Kubernetes resource templates
│   │   └── files/              Configset files + init script (bundled into chart)
│   ├── values-local.yaml       Local Docker Desktop overrides (no secrets)
│   ├── values-aks.yaml         AKS 3-node HA overrides (no secrets)
│   ├── values-aks-single.yaml  AKS single-node overrides (no secrets)
│   ├── .env.example            Template — copy to .env and fill in values
│   └── .env                    Cluster info + credentials (gitignored)
├── k8s/
│   ├── base/                   Kustomize base manifests (3-replica defaults)
│   └── overlays/
│       ├── local/              Docker Desktop K8s patches
│       └── aks/                AKS production patches
├── scripts/
│   ├── init-solr.sh            Standalone init script
│   ├── helm-deploy-local.sh    Local Helm deploy (sources helm/.env)
│   └── helm-deploy-aks.sh      AKS Helm deploy (sources helm/.env)
└── docs/
    └── entra-id-auth.md        Entra ID / JWT migration guide for AKS
```

---

## Environment files

Credentials and environment-specific settings are kept out of version control
using `.env` files. The `.env.example` files are committed and serve as templates.

```bash
# Docker Compose
cp docker/.env.example docker/.env
# Edit docker/.env — set SOLR_ADMIN_PASSWORD, SITECORE_SOLR_PASSWORD, etc.

# Helm / Kubernetes
cp helm/.env.example helm/.env
# Edit helm/.env — set passwords, AKS cluster name, ingress host, etc.
```

Both `.env` files are excluded by `.gitignore`. Never commit them.

---

## Helm (recommended)

Helm manages the full lifecycle — install, upgrade, rollback, uninstall — and
handles differences between environments via values files.

### Prerequisites

```bash
# Install Helm if not already installed
brew install helm   # macOS
# or: https://helm.sh/docs/intro/install/
```

### Local (Docker Desktop with Kubernetes)

```bash
# First time only
cp helm/.env.example helm/.env
# Edit helm/.env — set LOCAL_STORAGE_CLASS, passwords, etc.

./scripts/helm-deploy-local.sh
```

Watch pods:

```bash
kubectl get pods -n sitecore-solr -w
```

Access the dashboard once `solr-init` is `Completed`:

```bash
kubectl port-forward -n sitecore-solr svc/sitecore-solr-solr 8983:8983
```

Then open http://localhost:8983/solr — login with credentials from `helm/.env`.

### AKS

```bash
# First time only
cp helm/.env.example helm/.env
# Edit helm/.env — set AKS_RESOURCE_GROUP, AKS_CLUSTER_NAME,
#   AKS_STORAGE_CLASS, SOLR_INGRESS_HOST, SOLR_ADMIN_PASSWORD,
#   SITECORE_SOLR_PASSWORD

./scripts/helm-deploy-aks.sh

# For the full 3-node HA cluster (after quota increase):
VALUES_FILE=helm/values-aks.yaml ./scripts/helm-deploy-aks.sh
```

### Upgrade

```bash
# Local
./scripts/helm-deploy-local.sh

# AKS
./scripts/helm-deploy-aks.sh
```

### Uninstall

```bash
helm uninstall sitecore-solr -n sitecore-solr

# Also remove PVCs (wipes all index data):
kubectl delete pvc -n sitecore-solr --all
```

### Re-run the init job

The init job runs automatically on `helm install` and `helm upgrade`. To trigger
it manually (e.g. to add a new collection):

```bash
kubectl delete job sitecore-solr-solr-init -n sitecore-solr
./scripts/helm-deploy-local.sh   # or helm-deploy-aks.sh
```

---

## Quick start: Docker Compose

No Kubernetes required. Starts ZooKeeper + Solr + an init container.

```bash
# First time only
cp docker/.env.example docker/.env
# Edit docker/.env — change passwords if desired

cd docker
docker compose up -d
```

Wait ~60 seconds for the init container to complete, then open:

```
http://localhost:8983/solr
```

Login with the credentials from `docker/.env` (defaults: `admin` / `admin`).

To tear down (preserves volumes):

```bash
docker compose down
```

To tear down and wipe all data:

```bash
docker compose down -v
```

---

## Quick start: Docker Desktop with Kubernetes

Requires Docker Desktop with Kubernetes enabled (Settings > Kubernetes > Enable Kubernetes).

### Deploy

```bash
kubectl apply -k k8s/overlays/local/
```

### Watch pods come up

```bash
kubectl get pods -n sitecore-solr -w
```

Wait until `solr-0` and `zookeeper-0` are `Running` and `solr-init-*` shows `Completed` (~2–3 minutes on first image pull):

```
NAME              READY   STATUS      RESTARTS   AGE
solr-0            1/1     Running     0          2m
solr-init-xxxxx   0/1     Completed   0          2m
zookeeper-0       1/1     Running     0          2m
```

### Access the Solr dashboard

Docker Desktop on Mac/Windows does not forward NodePort traffic to localhost.
Use `kubectl port-forward` instead:

```bash
kubectl port-forward -n sitecore-solr svc/solr 8983:8983
```

Then open http://localhost:8983/solr — login **admin / admin**

Keep the port-forward running in a terminal while you need dashboard access.
To run it in the background:

```bash
kubectl port-forward -n sitecore-solr svc/solr 8983:8983 &
```

> On Linux with minikube or a bare-metal cluster, NodePort `30983` is accessible
> directly at `http://<node-ip>:30983/solr` without port-forwarding.

### Verify collections

```bash
curl -s -u admin:admin \
  "http://localhost:8983/solr/admin/collections?action=LIST&wt=json"
```

### Tear down

```bash
kubectl delete -k k8s/overlays/local/

# To also delete PersistentVolumeClaims (wipes all Solr index data):
kubectl delete pvc -n sitecore-solr --all
```

### Re-running the init job

If you need to re-create collections (e.g. after adding a custom index):

```bash
kubectl delete job solr-init -n sitecore-solr
kubectl apply -k k8s/overlays/local/
```

### Changing the replica count

To run a full 3-node cluster locally, edit
`k8s/overlays/local/patches/replicas.yaml` and set both values to `3`, then
remove the `zk-standalone.yaml` patch entry from
`k8s/overlays/local/kustomization.yaml` (standalone mode is only for 1 replica),
then re-apply.

---

## AKS deployment

### Prerequisites

- AKS cluster with at least 3 nodes (Standard_D4s_v3 or larger recommended)
- `kubectl` context pointing at your AKS cluster
- NGINX Ingress Controller installed:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

### Before deploying — change credentials

Edit `k8s/base/secrets/solr-auth.yaml` and update:
- `SOLR_ADMIN_PASSWORD` — change from `admin`
- `SITECORE_SOLR_PASSWORD` — change from `SolrRocks`
- `SITECORE_SOLR_CONNECTION_STRING` — update the password in the connection string

No password hashing is needed — the init job sets passwords via the Solr
Authentication API, which handles hashing internally.

Edit `k8s/overlays/aks/patches/ingress.yaml` and replace `solr.example.com` with
your actual domain.

### Deploy

```bash
kubectl apply -k k8s/overlays/aks/

# Watch pods (~3-5 minutes on first pull across 3 nodes)
kubectl get pods -n sitecore-solr -w
```

Once all pods are `Running` and `solr-init` is `Completed`, the Solr dashboard
is available at `https://solr.example.com/solr` (replace with your actual domain).

To access the dashboard directly without ingress (e.g. during initial setup):

```bash
kubectl port-forward -n sitecore-solr svc/solr 8983:8983
# http://localhost:8983/solr
```

---

## Sitecore connection strings

Add these to your Sitecore CM/CD deployments (or their corresponding K8s Secrets):

**`ConnectionStrings.config` / `Sitecore_ConnectionStrings_Solr.Search`:**

```
http://solr.sitecore-solr.svc.cluster.local:8983/solr;username=sitecore;password=SolrRocks;solrCloud=true
```

Change `SolrRocks` to your actual password before deploying to AKS.

### Sitecore BasicAuth patch

Sitecore must be configured to send credentials with every Solr request.
Add this patch file to your CM/CD custom image or config volume:

**`App_Config/Patches/Sitecore.ContentSearch.Solr.BasicAuth.config`:**

```xml
<configuration xmlns:patch="http://www.sitecore.net/xmlconfig/">
  <sitecore>
    <contentSearch>
      <solrHttpWebRequestFactory
        patch:instead="*[@type='SolrNet.Impl.HttpWebRequestFactory, SolrNet']"
        type="SolrNet.Impl.BasicAuthHttpWebRequestFactory, SolrNet">
        <param desc="login">sitecore</param>
        <param desc="password">SolrRocks</param>
      </solrHttpWebRequestFactory>
    </contentSearch>
  </sitecore>
</configuration>
```

After Sitecore CM is running, populate the Solr managed schema:

```
http://<cm-host>/sitecore/admin/PopulateManagedSchema.aspx?indexes=all
```

---

## XM1 collections

The following 10 collections are created automatically by the init job,
all using the `Sitecore` configset:

| Collection | Used by |
|---|---|
| `sitecore_core_index` | CM |
| `sitecore_master_index` | CM |
| `sitecore_web_index` | CD |
| `sitecore_marketingdefinitions_master` | CM |
| `sitecore_marketingdefinitions_web` | CD |
| `sitecore_marketing_asset_index_master` | CM |
| `sitecore_marketing_asset_index_web` | CD |
| `sitecore_suggested_test_index` | CM |
| `sitecore_fxm_master_index` | CM |
| `sitecore_fxm_web_index` | CD |

The collection prefix (`sitecore_`) is controlled by `SOLR_CORE_PREFIX` in the
init job. It can be changed in `k8s/base/solr-init/job.yaml`.

---

## Entra ID authentication (AKS)

See [docs/entra-id-auth.md](docs/entra-id-auth.md) for the full guide covering:

- oauth2-proxy in front of the Solr dashboard (recommended for Admin UI)
- Native Solr JWT plugin with Entra ID OIDC
- MultiAuthPlugin (JWT for tooling + BasicAuth for Sitecore service account)
- Regenerating password hashes for manual `security.json` edits
- Pre-production security checklist
