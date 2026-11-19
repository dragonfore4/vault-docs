# External Secrets Operator (ESO) with Vault AppRole

This guide installs ESO in the cluster that **uses** the secrets (cluster B) and connects it to Vault with AppRole. Type each command yourself, in order.

Before you start:
- Vault is running and unsealed (`00_vault_install/vault-ha-3-nodes.md`).
- The `kgov-read` policy, `kgov-read-role` AppRole and the `vault-approle` Secret in cluster B exist (`10_vault_secret/vault-secret-approle.md`).
- `kubectl` points at cluster B: `kubectl config current-context`.

## Files in this folder

| Order | File | What it is |
|-------|------|------------|
| 1 | `00_eso-namespace.yaml` | Namespace `external-secrets` |
| 2 | `10_eso-crds.yaml` | The 25 ESO CRDs (`external-secrets.io`, `generators.external-secrets.io`), ESO v2.14.0 |
| 3 | `20_eso-operator-kcshbr83.yaml` | ESO itself, rendered from Helm chart `external-secrets` 2.14.0: controller, webhook, cert-controller, RBAC, Service, ValidatingWebhooks. Image changed to the internal registry `kcshbr83.kcs/docker-dhi/external-secrets:2.14.0`. |
| 4 | `30_clustersecretstore-vault-approle-kgov.yaml` | `ClusterSecretStore` named `vault-backend` that logs in to Vault with AppRole |
| 5 | `40_clusterexternalsecret-kafka.yaml` | `ClusterExternalSecret` example: copies `kgov/dev/kafka` from Vault into a Secret `kafka` in namespace `demo2` |

## Step 1: Namespace

```bash
kubectl apply -f 00_eso-namespace.yaml
```

## Step 2: CRDs

### 2.1 Get the CRD file (optional, skip)

> **Skip this step.** `10_eso-crds.yaml` is already provided. Run it only when you create the file for the first time or upgrade ESO. Use the **same version** as the operator (here `2.14.0`).

Download the upstream bundle:

```bash
curl -sSL -o 10_eso-crds.yaml \
  https://raw.githubusercontent.com/external-secrets/external-secrets/v2.14.0/deploy/crds/bundle.yaml
```

Change `v2.14.0` in the URL to the version you want. The tag has a `v` prefix.

### 2.2 Apply the CRDs

The CRD file is about 2 MB. A normal `kubectl apply` fails with `metadata.annotations: Too long`, so use **server-side apply**:

```bash
kubectl apply --server-side -f 10_eso-crds.yaml
```

## Step 3: ESO operator

`20_eso-operator-kcshbr83.yaml` is ESO from Helm chart `external-secrets` 2.14.0, with the image already changed to the internal registry (`kcshbr83.kcs/docker-dhi/external-secrets:2.14.0`).

### 3.1 Get the file (optional, skip)

> **Skip this step.** `20_eso-operator-kcshbr83.yaml` is already provided. Run it only if you need to regenerate the file.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm template external-secrets external-secrets/external-secrets \
  --version 2.14.0 --namespace external-secrets \
  --set installCRDs=false > 20_eso-operator-kcshbr83.yaml

# replace the upstream image with the internal registry image
sed -i '' 's#ghcr.io/external-secrets/external-secrets:v2.14.0#kcshbr83.kcs/docker-dhi/external-secrets:2.14.0#g' 20_eso-operator-kcshbr83.yaml
```

### 3.2 Apply

```bash
kubectl apply --server-side -f 20_eso-operator-kcshbr83.yaml
```

Check that the 3 pods are `Running`:

```bash
kubectl -n external-secrets get pods
```

Wait for the webhook to be ready before Step 4. Otherwise you get `failed calling webhook "validate.clustersecretstore.external-secrets.io"`.

## Step 4: ClusterSecretStore (connect to Vault)

`30_clustersecretstore-vault-approle-kgov.yaml` creates `ClusterSecretStore/vault-backend`:

| Field | Value | Meaning |
|-------|-------|---------|
| `server` | Vault URL (HTTPS) | Must be reachable from cluster B |
| `path` | `secret` | The KV mount from `10_vault_secret` 1.1 |
| `version` | `v2` | KV v2 |
| `auth.appRole.path` | `approle` | Where AppRole is enabled |
| `auth.appRole.roleId` | role-id | See 4.1. Not secret. |
| `auth.appRole.secretRef` | `external-secrets/vault-approle`, key `secret-id` | See 4.2 |
| `caProvider` | ConfigMap `external-secrets/vault-ca`, key `ca.crt` | CA that signed the Vault HTTPS certificate. See 4.3 |

The store needs 3 inputs. Get them in order: 4.1 role-id, 4.2 secret-id, 4.3 CA.

| Input | Where it comes from | Where it goes | Secret? |
|-------|---------------------|---------------|---------|
| role-id | Vault (4.1) | `roleId` in the YAML file | No |
| secret-id | Vault (4.2) | Secret `external-secrets/vault-approle`, key `secret-id` | **Yes** |
| CA certificate | Vault HTTPS endpoint (4.3) | ConfigMap `external-secrets/vault-ca`, key `ca.crt` | No |

Steps 4.1 and 4.2 run `vault` on the Vault **leader** after `vault login` (see `10_vault_secret/vault-secret-approle.md` Step 0). The `kubectl` commands run against cluster B.

### 4.1 Get the role-id

On the Vault leader:

```bash
docker exec vault vault read -field=role_id auth/approle/role/kgov-read-role/role-id
```

The output is a UUID, for example `f3807113-515d-c6fa-aa60-549fc8a761d6`. (Without `-field=role_id` it prints a table. The value is in the `role_id` row.)

Put it in `30_clustersecretstore-vault-approle-kgov.yaml`:

```yaml
      auth:
        appRole:
          path: "approle"
          roleId: "<role_id>"
```

The role-id does not change unless the role is deleted and created again, so you only do this once. It is not secret, so it can be in Git.

### 4.2 Create the secret-id and store it in cluster B

On the Vault leader, create a new secret-id:

```bash
docker exec vault vault write -f auth/approle/role/kgov-read-role/secret-id
```

Output:

```
Key                   Value
---                   -----
secret_id             8b1e...        <- copy this
secret_id_accessor    3c2a...
secret_id_num_uses    0
secret_id_ttl         0s
```

- Copy `secret_id`. Vault shows it **only once**. If you lose it, create a new one.
- `secret_id_accessor` is a reference you can use later to look up or revoke this secret-id. It cannot be used to log in.
- `secret_id_ttl 0s` means it never expires (lab setting, see `10_vault_secret`).

Optional: test the pair before you store it:

```bash
docker exec vault vault write auth/approle/login role_id=<role_id> secret_id=<secret_id>
```

It should return a `token` with policy `kgov-read`.

On cluster B, store the secret-id as a Kubernetes Secret:

```bash
kubectl -n external-secrets create secret generic vault-approle \
  --from-literal=secret-id='<secret_id>'
```

The name `vault-approle` and the key `secret-id` must match `secretRef` in the YAML file. Never put the secret-id in a YAML file or Git.

Check:

```bash
kubectl -n external-secrets get secret vault-approle
```

To replace the secret-id later (for example after rotation), delete the Secret and create it again with the new value:

```bash
kubectl -n external-secrets delete secret vault-approle
kubectl -n external-secrets create secret generic vault-approle \
  --from-literal=secret-id='<new_secret_id>'
```

### 4.3 Get the CA certificate and create the ConfigMap

ESO connects over HTTPS, so it must trust the certificate of the `server` URL.

**Best:** ask the ingress or PKI team for the root CA (and intermediate CA) in PEM format.

**Or** get it with `openssl` (host name only, no `https://`):

```bash
# Save every CA certificate (all blocks except the server certificate, number 0)
openssl s_client -connect <vault-host>:443 -servername <vault-host> -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/{n++} n>1 && /BEGIN CERTIFICATE/,/END CERTIFICATE/' > ca.crt

# Check: expect "Verify return code: 0 (ok)"
openssl s_client -connect <vault-host>:443 -servername <vault-host> -CAfile ca.crt </dev/null 2>/dev/null \
  | grep "Verify return code"
```

If `ca.crt` is empty, the server sends only its own certificate. Get the CA from the PKI team instead.

Create the ConfigMap (the key must be `ca.crt`):

```bash
kubectl -n external-secrets create configmap vault-ca --from-file=ca.crt=ca.crt
```

> If Vault runs with `tls_disable = 1`, HTTPS is done by the ingress or load balancer in front. You need the CA of **that** endpoint.

### 4.4 Apply the store

```bash
kubectl apply -f 30_clustersecretstore-vault-approle-kgov.yaml
kubectl get clustersecretstore vault-backend    # STATUS Valid, READY True
```

## Step 5: ClusterExternalSecret (example: kafka)

`40_clusterexternalsecret-kafka.yaml` reads the Vault secret `kgov/dev/kafka` and creates a Kubernetes Secret `kafka` in each namespace that matches the selector. Fields to know:

| Field | Value | Meaning |
|-------|-------|---------|
| `namespaceSelectors` | `demo2` | Which namespaces get the Secret. Add names under `values` for more. |
| `secretStoreRef` | `vault-backend` | The store from Step 4 |
| `refreshInterval` | `15s` | How often it re-reads Vault. Use about `1h` in production. |
| `target.name` | `kafka` | Name of the Kubernetes Secret |
| `dataFrom.extract.key` | `kgov/dev/kafka` | Vault path **under the `secret` mount, without `data/`**. Every key becomes a key in the Secret. |

Paths outside `kgov/` give `permission denied` (policy `kgov-read`).

### 5.1 Apply

```bash
kubectl create namespace demo2
kubectl apply -f 40_clusterexternalsecret-kafka.yaml
```

### 5.2 Check

```bash
kubectl -n demo2 get externalsecret kafka      # expect SecretSynced, READY True
kubectl -n demo2 get secret kafka -o jsonpath='{.data.KGOV_KAFKA_HOST}' | base64 -d; echo
kubectl -n demo2 describe externalsecret kafka # events if not synced
```

### 5.3 Test that it follows Vault

```bash
# On the Vault leader
docker exec vault vault kv put secret/kgov/dev/kafka \
  KGOV_KAFKA_HOST="kafka.example.local:9092" \
  KGOV_KAFKA_USERNAME="demo-user" \
  KGOV_KAFKA_PASSWORD="new-password"

# After one refreshInterval (15s)
kubectl -n demo2 get secret kafka -o jsonpath='{.data.KGOV_KAFKA_PASSWORD}' | base64 -d; echo
```

Pods that use the Secret as environment variables must restart to see the change. Mounted files update by themselves.

### 5.4 Clean up

```bash
kubectl delete -f 40_clusterexternalsecret-kafka.yaml
```

This also deletes the `ExternalSecret` and the Secret `kafka`. Stop pods that use it first.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `metadata.annotations: Too long` | CRDs applied without `--server-side` |
| `failed calling webhook ...` | Webhook pod not ready. Wait and apply again. |
| `x509: certificate signed by unknown authority` | Wrong or missing `vault-ca` ConfigMap |
| `invalid role or secret ID` | Wrong `roleId`, or `vault-approle` has an old secret-id |
| ExternalSecret `permission denied` | Path outside `kgov/`, or `key` includes `data/` |
| `ClusterExternalSecret` provisions nothing | Namespace missing, or not in `namespaceSelectors` |
| `ImagePullBackOff` | Cannot pull from `kcshbr83.kcs`. Check registry access. |

## Upgrading ESO

1. Download the new CRD file (Step 2.1) for the new version.
2. Apply the CRDs (Step 2.2), then the operator file (Step 3).
