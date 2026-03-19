# Conversation Log: Sitecore Solr K8s Setup

## Date: 2026-03-19

---

## Initial Request

Set up Solr 8.11.2 and ZooKeeper using Helm and Kubernetes for deployment to an existing AKS cluster.

### Requirements Given

- Two versions: Prod (3 Solr + 3 ZK) and Dev (1 Solr + 1 ZK)
- Must use Solr Operator and ZooKeeper Operator
- Must support multiple configsets via `./settings/configsets/*`
- Must define collections and configsets via `./settings/collections.yml`
- Must be compatible with Sitecore XM 10.4.0 via connection strings (networking handled separately)
- Must be runnable locally via kubectl (dev version)
- Solr dashboard must be password protected (admin/admin)
- Create `.env.template` with all variables defined
- Documentation for: local dev, deploying dev to AKS, deploying prod to AKS, Sitecore connection strings with VNet peering notes, reference docs links
- Barebones setup using out-of-the-box Solr/ZK operator features as much as possible
- Helm required, no Terraform

---

## Existing Repo State

The repo already contained:

- `settings/collections.yml` - 12 collections defined (11 Sitecore + 1 HUT), all using `shards: 1, replicas: 1`
- `settings/configsets/sitecore/conf/` - managed-schema, solrconfig.xml, synonyms.txt, stopwords.txt
- `settings/configsets/hut/conf/` - managed-schema, solrconfig.xml, synonyms.txt, stopwords.txt

---

## Research Conducted

### 1. Apache Solr Operator

- Latest chart version: **0.9.1** from `https://solr.apache.org/charts`
- Solr 8.11.2 is supported by v0.8.x and v0.9.x (minimum Solr version is 8.11 for these operator versions)
- Primary CRD: `SolrCloud` at `solr.apache.org/v1beta1`
- `SolrCollection` and `SolrCollectionAlias` CRDs were **removed in v0.3.0** (Oct 2021) -- no declarative collection management
- No CRD for configsets either (open feature request, never implemented)
- Basic auth configured via `spec.solrSecurity.authenticationType: Basic`
- Operator bootstraps random passwords by default; custom security.json supported via `basicAuthSecret`
- ZK Operator (Pravega v0.2.15) is bundled as a chart dependency

### 2. Pravega ZooKeeper Operator

- Helm repo: `https://charts.pravega.io`
- CRD: `ZookeeperCluster` at `zookeeper.pravega.io/v1beta1`
- Creates StatefulSet, headless Service, client Service, ConfigMap, PDB
- Client service pattern: `<name>-client.<namespace>.svc.cluster.local:2181`
- Default ZK image runs 3.9.3; can be overridden to any version

### 3. ZooKeeper Compatibility with Solr 8.11.2

- Solr 8.11.2 ships with ZK client 3.6.2
- ZK servers 3.7.x, 3.8.x, 3.9.x are all backward-compatible with 3.6.x clients
- Recommended: ZK 3.8.4 as a balance between compatibility and support

### 4. Sitecore XM 10.4.0 Solr Requirements

- Sitecore XM mode needs 3 collections: `sitecore_core_index`, `sitecore_master_index`, `sitecore_web_index`
- Sitecore XP mode (what the existing collections.yml has) needs 11 collections total
- Uses managed schemas -- starts from `_default` configset, Sitecore populates fields via Schema API at runtime
- Connection string format: `http://<solr-host>:<port>/solr;solrCloud=true`
- With basic auth: `http://<username>:<password>@<solr-host>:<port>/solr;solrCloud=true`
- Sitecore connects to Solr via HTTP, not directly to ZooKeeper

---

## Decisions Made

### Q1: ZooKeeper Management

**Options presented:**
1. Provided (Solr Operator manages ZK via `spec.zookeeperRef.provided`) -- Recommended
2. Standalone ZK + connection string (deploy ZookeeperCluster CR separately)

**Decision: Standalone ZK + connection string**

Rationale: More control over ZK lifecycle, independent scaling, explicit wiring.

### Q2: Configset & Collection Setup Mechanism

**Options presented:**
1. K8s Job -- Recommended
2. Init container on Solr pods
3. Manual script

**Decision: K8s Job**

A Kubernetes Job runs after SolrCloud is ready. It uploads configsets via `solr zk upconfig` and creates collections via the Solr Collections API.

### Q3: Local K8s Environment

**Options presented:**
1. Docker Desktop Kubernetes
2. kind
3. minikube
4. Rancher Desktop

**Decision: Docker Desktop Kubernetes**

### Q4: Helm Chart Structure

**Options presented:**
1. Single chart + values files (values-dev.yaml, values-prod.yaml) -- Recommended
2. Separate charts per environment

**Decision: Separate charts per environment**

Follow-up clarification:
- **Shared library chart + wrapper charts** (not fully duplicated charts)
- `charts/solr-base/` as a Helm library chart with all templates
- `charts/solr-dev/` and `charts/solr-prod/` as thin wrappers with just values

### Q5: Basic Auth Approach

**Options presented:**
1. Custom security.json with pre-hashed admin/admin -- Recommended
2. Operator bootstrap + change password post-deploy

**Decision: Custom security.json**

Pre-configure `security.json` with bcrypt-hashed admin/admin. Deterministic, same credentials everywhere.

### Q6: Prod Collection Replicas

**Options presented:**
1. Override to 2 for prod
2. Keep as defined in collections.yml
3. Make it configurable

**Decision: Override to 2 for prod**

Dev stays at `replicationFactor=1`, prod gets `replicationFactor=2` for HA across 3 Solr nodes.

### Q7: Namespace Strategy

**Options presented:**
1. Separate namespaces, same AKS cluster
2. Separate AKS clusters
3. TBD / configurable

**Decision: Separate AKS clusters**

Dev and prod will be on entirely separate AKS clusters. Namespace is still configurable in the charts.

---

## Final Architecture Summary

```
Solr Operator v0.9.1 (includes ZK Operator v0.2.15)
         |
         v
  ZookeeperCluster CR -----> ZK StatefulSet (1 or 3 pods)
         |
         v
  SolrCloud CR (connectionInfo) -----> Solr StatefulSet (1 or 3 pods)
         |
         v
  Setup Job -----> uploads configsets to ZK, creates collections via Solr API
```

- Dev: 1 ZK + 1 Solr, replicationFactor=1, small storage
- Prod: 3 ZK + 3 Solr, replicationFactor=2, large persistent storage
- Auth: admin/admin via custom security.json
- Local testing: Docker Desktop Kubernetes
- AKS: Separate clusters for dev and prod
