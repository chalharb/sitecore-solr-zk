# Entra ID Authentication for Solr (AKS)

This guide covers migrating the Solr cluster from BasicAuth (`admin:admin`) to
Microsoft Entra ID (formerly Azure AD) authentication before going to production
on AKS.

## Overview

Solr supports JWT-based authentication via `JWTAuthPlugin`. The plugin validates
Bearer tokens issued by Entra ID, making it possible to enforce Entra ID SSO for
the Solr Admin UI and protect the Solr API.

**Important limitation:** The Solr Admin UI has incomplete support for JWT-only
auth — it shows an "Unauthorized / unsupported scheme" message on the login page
when JWT is the sole authentication provider. The recommended AKS approach is:

- **Admin UI access:** Put [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/)
  in front of the Solr service (as an NGINX Ingress auth annotation or sidecar).
  oauth2-proxy handles the Entra ID OIDC flow and proxies authenticated requests
  to Solr. Solr itself stays on BasicAuth internally.

- **Sitecore CM/CD API access:** Keep using BasicAuth with the `sitecore` service
  account on the internal cluster network (not exposed externally). The Sitecore
  pods never go through the ingress — they talk directly to the `solr` ClusterIP
  service. There is no benefit to JWT here.

- **Solr API access for custom tooling:** Use the JWT plugin if your tooling can
  acquire Entra ID tokens; otherwise BasicAuth with a service principal secret is
  equally secure on an internal cluster network.

---

## Option A: oauth2-proxy in front of Solr (Recommended for Admin UI)

This is the simplest path and does not require changes to Solr's own auth config.

### 1. Create an Entra ID App Registration

In the Azure Portal → Entra ID → App Registrations → New Registration:

| Field | Value |
|---|---|
| Name | `solr-admin` |
| Supported account types | Accounts in this organizational directory only |
| Redirect URI | Web — `https://solr.example.com/oauth2/callback` |

After registering:
- Copy the **Application (client) ID** and **Directory (tenant) ID**.
- Under **Certificates & secrets** → **New client secret** → copy the secret value.
- Under **Authentication** → enable **ID tokens**.

### 2. Deploy oauth2-proxy

```bash
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests
helm repo update

helm install oauth2-proxy oauth2-proxy/oauth2-proxy \
  --namespace sitecore-solr \
  --set config.clientID="<APP_CLIENT_ID>" \
  --set config.clientSecret="<APP_CLIENT_SECRET>" \
  --set config.cookieSecret="$(openssl rand -base64 32)" \
  --set extraArgs.provider="oidc" \
  --set extraArgs.oidc-issuer-url="https://login.microsoftonline.com/<TENANT_ID>/v2.0" \
  --set extraArgs.email-domain="*" \
  --set extraArgs.upstream="http://solr.sitecore-solr.svc.cluster.local:8983" \
  --set extraArgs.redirect-url="https://solr.example.com/oauth2/callback" \
  --set service.type=ClusterIP
```

### 3. Update the NGINX Ingress to route through oauth2-proxy

Replace the ingress in `k8s/overlays/aks/patches/ingress.yaml` with:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "https://solr.example.com/oauth2/auth"
    nginx.ingress.kubernetes.io/auth-signin: "https://solr.example.com/oauth2/start?rd=$escaped_request_uri"
```

Add a second Ingress rule for the `/oauth2` path pointing at the oauth2-proxy service.

---

## Option B: Native Solr JWT Plugin (API access)

Use this if you want Solr's own API endpoints (not the Admin UI) protected by
Entra ID JWTs — for example, for custom tooling or CI pipelines.

### 1. Create the App Registration (same as Option A above)

Additionally, expose an API scope:

- **Expose an API** → Set Application ID URI (e.g. `api://<CLIENT_ID>`) → Add a scope
  named `solr.access` with **Admins and users** consent.

### 2. Enable the JWT module

The `SOLR_OPTS` env var in `k8s/base/solr/configmap.yaml` already includes
`-Dsolr.modules=jwt-auth` so no redeployment is needed.

### 3. Replace security.json

Create a new `security.json` and update the Kubernetes Secret:

```json
{
  "authentication": {
    "class": "solr.JWTAuthPlugin",
    "blockUnknown": true,
    "wellKnownUrl": "https://login.microsoftonline.com/<TENANT_ID>/v2.0/.well-known/openid-configuration",
    "clientId": "<APP_CLIENT_ID>",
    "scope": "api://<APP_CLIENT_ID>/solr.access",
    "realm": "Sitecore Solr"
  },
  "authorization": {
    "class": "solr.RuleBasedAuthorizationPlugin",
    "permissions": [
      { "name": "all", "role": "admin" }
    ],
    "user-role": {}
  }
}
```

Update the AKS Secret and re-upload to ZooKeeper:

```bash
# Update the Kubernetes Secret
kubectl create secret generic solr-security-json \
  --from-file=security.json=./new-security.json \
  --namespace sitecore-solr \
  --dry-run=client -o yaml | kubectl apply -f -

# Re-run the init job to upload the new security.json to ZooKeeper
kubectl delete job solr-init -n sitecore-solr
kubectl apply -k k8s/overlays/aks/

# Or upload directly without re-running the full init job:
kubectl exec -n sitecore-solr \
  $(kubectl get pod -n sitecore-solr -l app=solr -o jsonpath='{.items[0].metadata.name}') \
  -- /opt/solr/bin/solr zk cp file:/var/solr/security.json \
     zk:/security.json \
     -z zookeeper-client.sitecore-solr.svc.cluster.local:2181
```

### 4. Sitecore connection string (keep BasicAuth)

Sitecore CM/CD pods communicate with Solr on the internal cluster network via
`http://solr.sitecore-solr.svc.cluster.local:8983/solr` — never through the
public ingress. Keep the `sitecore` BasicAuth user in `security.json` alongside
the JWT config by using `solr.MultiAuthPlugin`:

```json
{
  "authentication": {
    "class": "solr.MultiAuthPlugin",
    "schemes": [
      {
        "scheme": "bearer",
        "class": "solr.JWTAuthPlugin",
        "blockUnknown": true,
        "wellKnownUrl": "https://login.microsoftonline.com/<TENANT_ID>/v2.0/.well-known/openid-configuration",
        "clientId": "<APP_CLIENT_ID>"
      },
      {
        "scheme": "basic",
        "class": "solr.BasicAuthPlugin",
        "blockUnknown": false,
        "credentials": {
          "sitecore": "<PBKDF2 hash>"
        },
        "forwardCredentials": false
      }
    ]
  }
}
```

With `MultiAuthPlugin`, requests with a `Bearer` token are validated by JWT, and
requests with `Basic` credentials (Sitecore) are validated by BasicAuth.

---

## Generating new PBKDF2 password hashes

When changing passwords, generate a new hash inside any running Solr container:

```bash
kubectl exec -n sitecore-solr \
  $(kubectl get pod -n sitecore-solr -l app=solr -o jsonpath='{.items[0].metadata.name}') \
  -- /opt/solr/bin/solr auth add-user \
     -credentials admin:<NEW_PASSWORD> \
     -type basicAuth
```

This prints the hash line to copy into `security.json`.

Alternatively, use the Solr BasicAuth API (while still on BasicAuth):

```bash
curl -u admin:admin \
  "http://localhost:8983/solr/admin/authentication" \
  -H "Content-Type: application/json" \
  -d '{"set-user": {"admin": "<NEW_PASSWORD>"}}'
```

---

## Security checklist before going to AKS production

- [ ] Change `admin` password from `admin` to a strong random value
- [ ] Change `sitecore` service account password from `SolrRocks`
- [ ] Update both `secrets/solr-auth.yaml` and `secrets/security-json.yaml`
- [ ] Replace the self-signed TLS cert placeholder in `patches/ingress.yaml`
- [ ] Configure cert-manager + Let's Encrypt (or bring your own cert)
- [ ] Restrict the Solr `solr` ClusterIP service to internal cluster traffic only (it already is — confirm no `type: LoadBalancer` or NodePort in AKS)
- [ ] Enable AKS Network Policy or Calico to restrict which pods can reach port 8983
- [ ] Consider moving secrets to Azure Key Vault + CSI Secrets Store driver
