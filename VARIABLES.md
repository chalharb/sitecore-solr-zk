# Variables Reference

Placeholders that must be replaced before deployment.

| Placeholder | File(s) | Description |
|---|---|---|
| `<ACR_NAME>` | `solr-init/k8s/job.yaml` | Azure Container Registry name (e.g. `myregistry`) — used in the image field as `<ACR_NAME>.azurecr.io/solr-init:<TAG>` |
| `<TAG>` | `solr-init/k8s/job.yaml` | Docker image tag — recommend using the Git SHA (e.g. `abc1234`) |

## Files requiring user content

| File | Description |
|---|---|
| `settings/configsets/sitecore/conf/` | Sitecore configset files (`schema.xml`, `solrconfig.xml`, etc.) — must be provided before building the solr-init image |
| `settings/configsets/hut/conf/` | HUT configset files (`schema.xml`, `solrconfig.xml`, etc.) — must be provided before building the solr-init image |
| `settings/collections.yml` | Collection definitions — pre-filled with Sitecore XM 10.4 defaults; edit to match your environment |
