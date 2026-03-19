# Implementation Plan: Sitecore Solr 8.11.2 + ZooKeeper on Kubernetes

## Architecture Overview

```
charts/
  solr-base/              # Shared Helm library chart (named templates only)
  solr-dev/               # Dev wrapper: 1 Solr + 1 ZK
  solr-prod/              # Prod wrapper: 3 Solr + 3 ZK
settings/
  configsets/sitecore/    # (existing) Sitecore configset
  configsets/hut/         # (existing) HUT configset
  collections.yml         # (existing) Collection definitions
scripts/
  setup.sh                # Entrypoint for the K8s setup Job
.env.template             # All configurable environment variables
README.md                 # Full documentation
```

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| ZooKeeper management | Standalone `ZookeeperCluster` CR + `connectionInfo` | More control over ZK lifecycle, explicit wiring |
| Configsets & collections | K8s Job (post-deploy) | Uploads configsets via `solr zk upconfig`, creates collections via Collections API |
| Local K8s | Docker Desktop Kubernetes | Already available in user's environment |
| Chart structure | Shared library chart + wrapper charts | DRY templates, separate values per environment |
| Basic auth | Operator-managed bootstrap + password change via setup Job | Operator handles security.json lifecycle; setup Job changes admin password to desired value |
| Prod collection replicas | Override to `replicationFactor=2` | Better HA across 3 Solr nodes |
| Operator versions | Solr Operator v0.9.1, ZK Operator v0.2.15 (bundled) | Latest versions supporting Solr 8.11.x |
| Namespace strategy | Configurable, separate AKS clusters for dev/prod | User will manage cluster isolation externally |

## Operator Stack

| Component | Version | Helm Chart |
|---|---|---|
| Solr Operator | v0.9.1 | `apache-solr/solr-operator` from `https://solr.apache.org/charts` |
| ZooKeeper Operator | v0.2.15 | Bundled with Solr Operator chart as a dependency |
| Solr | 8.11.2 | Managed by SolrCloud CRD (`solr.apache.org/v1beta1`) |
| ZooKeeper | 3.7.1 (via pravega/zookeeper:0.2.15) | Managed by ZookeeperCluster CRD (`zookeeper.pravega.io/v1beta1`) |

## File Manifest

### `charts/solr-base/` (Library Chart)

| File | Purpose |
|---|---|
| `Chart.yaml` | `type: library`, no direct rendering |
| `templates/_helpers.tpl` | Common name/label/namespace helper templates |
| `templates/_zookeeper.tpl` | `ZookeeperCluster` CR named template |
| `templates/_solrcloud.tpl` | `SolrCloud` CR named template |
| `templates/_security.tpl` | `security.json` ConfigMap + basic-auth Secret for the operator |
| `templates/_configsets.tpl` | ConfigMap bundling all configset files from `settings/configsets/` |
| `templates/_setup-job.tpl` | K8s Job that uploads configsets and creates collections |

### `charts/solr-dev/` (Dev Wrapper)

| File | Purpose |
|---|---|
| `Chart.yaml` | Depends on `solr-base` library chart |
| `values.yaml` | 1 Solr, 1 ZK, small storage, modest resources |
| `templates/resources.yaml` | Calls all named templates from `solr-base` |

### `charts/solr-prod/` (Prod Wrapper)

| File | Purpose |
|---|---|
| `Chart.yaml` | Depends on `solr-base` library chart |
| `values.yaml` | 3 Solr, 3 ZK, large storage, production resources |
| `templates/resources.yaml` | Calls all named templates from `solr-base` |

### Root Files

| File | Purpose |
|---|---|
| `scripts/setup.sh` | Shell script: upload configsets to ZK, create collections via Solr API |
| `.env.template` | All configurable variables (K8s context, namespace, AKS details, etc.) |
| `README.md` | Complete documentation (local dev, AKS deploy, Sitecore connection, references) |

## Template Details

### ZookeeperCluster CR

- API: `zookeeper.pravega.io/v1beta1`
- Configurable: replicas, storage class, volume size, resources
- Dev: 1 replica, 2Gi storage, ephemeral OK
- Prod: 3 replicas, 10Gi persistent storage, `Retain` reclaim policy
- Image: `zookeeper:3.8.4` (compatible with Solr 8.11.2's ZK client)

### SolrCloud CR

- API: `solr.apache.org/v1beta1`
- Image: `solr:8.11.2`
- `zookeeperRef.connectionInfo.externalConnectionString` pointing to standalone ZK client service
- `solrSecurity.authenticationType: Basic` with `basicAuthSecret` referencing our pre-created Secret
- Configurable: replicas, storage, Java memory, resources
- Dev: 1 replica, 5Gi storage
- Prod: 3 replicas, 50Gi storage

### security.json

Pre-configured with:
- `admin` user (password: `admin`, bcrypt hashed) with full admin role
- `solr` user (password: `SolrRocks`, bcrypt hashed) with read-only role
- `k8s-oper` user (password: `oper-secret`, bcrypt hashed) for operator communication
- `RuleBasedAuthorizationPlugin` granting appropriate permissions

The `k8s-oper` credentials are stored in a K8s Secret (`type: kubernetes.io/basic-auth`) referenced by the SolrCloud CR's `basicAuthSecret` field.

### Setup Job (`scripts/setup.sh`)

Execution flow:

1. **Wait for ZooKeeper** - Poll ZK until it responds
2. **Upload security.json** - Write `security.json` to ZK `/security.json` znode
3. **Upload configsets** - For each directory in `/configsets/`:
   ```
   solr zk upconfig -n <dirname> -d /configsets/<dirname>/conf -z $ZK_HOST
   ```
4. **Wait for Solr** - Poll Solr common service until it responds (with auth)
5. **Create collections** - Parse `collections.yml`, for each collection:
   - Check if it exists via `LIST` action
   - If not, `CREATE` with `numShards`, `replicationFactor` (from values override), and `collection.configName`
6. **Exit 0** on success

The Job uses the `solr:8.11.2` image (has `solr zk` CLI and `curl`).

### ConfigMap Strategy

**Configset files**: Each file under `settings/configsets/<name>/conf/` is stored as a key in a ConfigMap. The key format is `<configset>--<filename>` (e.g., `sitecore--managed-schema`). The setup script reconstructs the directory structure from these keys.

**collections.yml**: Stored in its own ConfigMap, mounted into the setup Job.

### .env.template Variables

```
KUBE_CONTEXT=docker-desktop
NAMESPACE=solr
SOLR_IMAGE_TAG=8.11.2
SOLR_ADMIN_PASSWORD=admin
SOLR_JAVA_MEM=-Xms512m -Xmx1g
ZK_IMAGE_TAG=3.8.4
STORAGE_CLASS=
AKS_RESOURCE_GROUP=
AKS_CLUSTER_NAME=
AKS_SUBSCRIPTION=
```

## Implementation Order

1. `charts/solr-base/Chart.yaml`
2. `charts/solr-base/templates/_helpers.tpl`
3. `charts/solr-base/templates/_security.tpl`
4. `charts/solr-base/templates/_zookeeper.tpl`
5. `charts/solr-base/templates/_solrcloud.tpl`
6. `charts/solr-base/templates/_configsets.tpl`
7. `scripts/setup.sh`
8. `charts/solr-base/templates/_setup-job.tpl`
9. `charts/solr-dev/Chart.yaml`
10. `charts/solr-dev/values.yaml`
11. `charts/solr-dev/templates/resources.yaml`
12. `charts/solr-prod/Chart.yaml`
13. `charts/solr-prod/values.yaml`
14. `charts/solr-prod/templates/resources.yaml`
15. `.env.template`
16. `README.md`
17. Local testing with Docker Desktop K8s
18. Validate with `helm template` dry-run
19. Deploy dev locally and verify Solr dashboard + collections

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| ConfigMap 1 MiB size limit | Current configsets are small (4 files each). If they grow, switch to a custom Docker image with baked-in configsets. |
| ZK not ready before Solr starts | SolrCloud CR will fail to reconcile until ZK service is reachable; operator retries automatically. Setup Job also waits. |
| security.json must exist in ZK before Solr reads it | Setup Job uploads security.json first. SolrCloud pods will restart once security is configured. The operator handles the bootstrapping sequence. |
| Helm library chart limitations | Library charts only support named templates. Wrapper charts must explicitly `include` each template. |
| ZK 3.8.4 with Solr 8.11.2 (ships with 3.6.2 client) | ZK servers are backward-compatible with older clients. 3.8.4 is widely tested with Solr 8.11.x. |
