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

### 2.1 Generate the CRD file

You only need this when you create `10_eso-crds.yaml` for the first time or upgrade ESO. Use the **same version** as the operator (here `2.14.0`).

**Option A: Helm chart (recommended, needs `helm`)**

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# list available versions
helm search repo external-secrets/external-secrets --versions | head

# render only the CRD templates of the chart
helm template external-secrets external-secrets/external-secrets \
  --version 2.14.0 \
  --namespace external-secrets \
  --show-only 'templates/crds/*' \
  > 10_eso-crds.yaml
```

- `helm template` only writes YAML to a file. It does not install anything in the cluster.
- `--show-only 'templates/crds/*'` keeps only the CRDs and drops the Deployments, RBAC and so on.
- The chart renders CRDs by default (`installCRDs=true`). With `--set installCRDs=false` the output has no CRDs.

**Option B: Download the upstream bundle (no Helm)**

```bash
curl -sSL -o 10_eso-crds.yaml \
  https://raw.githubusercontent.com/external-secrets/external-secrets/v2.14.0/deploy/crds/bundle.yaml
```

Change `v2.14.0` in the URL to the version you want. The tag has a `v` prefix.

Both options give the same 25 CRDs. Only a few description texts differ.

Check the result:

```bash
grep -c "^kind: CustomResourceDefinition" 10_eso-crds.yaml   # expect 25
grep -E "^  name: .*external-secrets.io" 10_eso-crds.yaml      # list CRD names
```

### 2.2 Apply the CRDs

The CRD file is about 2 MB. A normal `kubectl apply` stores the whole object in an annotation and fails with `metadata.annotations: Too long`. Use **server-side apply**:

```bash
kubectl apply --server-side -f 10_eso-crds.yaml
```

Check:

```bash
kubectl get crd | grep external-secrets.io
kubectl wait --for=condition=Established crd/clustersecretstores.external-secrets.io --timeout=60s
```

## Step 3: ESO operator

### 3.1 How `20_eso-operator-kcshbr83.yaml` was made

It is `helm template` output for chart 2.14.0, with the image changed to the internal registry:

```bash
helm template external-secrets external-secrets/external-secrets \
  --version 2.14.0 \
  --namespace external-secrets \
  --set installCRDs=false \
  > 20_eso-operator-kcshbr83.yaml
```

Then replace the 3 image lines (controller, webhook, cert-controller):

```yaml
# image: ghcr.io/external-secrets/external-secrets:v2.14.0
image: kcshbr83.kcs/docker-dhi/external-secrets:2.14.0
```

> The current `20_eso-operator-kcshbr83.yaml` was rendered **with** CRDs (it still contains the same 25 CRDs as `10_eso-crds.yaml`). Applying it works, but the CRDs are applied twice. Render it again with `--set installCRDs=false` to keep CRDs only in `10_eso-crds.yaml`.

### 3.2 Apply

```bash
kubectl apply --server-side -f 20_eso-operator-kcshbr83.yaml
```

(`--server-side` is needed while the file still contains the CRDs.)

Check that the 3 pods are `Running`:

```bash
kubectl -n external-secrets get pods
kubectl -n external-secrets rollout status deploy/external-secrets
kubectl -n external-secrets rollout status deploy/external-secrets-webhook
kubectl -n external-secrets rollout status deploy/external-secrets-cert-controller
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

ESO connects to Vault over HTTPS (`server: "https://..."`), so it must trust the certificate of that endpoint. `caProvider` tells ESO which CA to trust.

**Best: get the CA from the team that owns the certificate** (the ingress or PKI team). Ask for the **root CA** (and intermediate CA, if any) in PEM format.

**Or: get it from the server with `openssl`.** Run this from a machine that can reach Vault. Replace `<vault-host>` with the host name only, without `https://` (for example `dev-ingress-channel.kgov.gtbnonprd.vayuktbcs`):

1. Show the certificate chain the server sends:
   ```bash
   openssl s_client -connect <vault-host>:443 -servername <vault-host> -showcerts </dev/null
   ```
   Each certificate is a block from `-----BEGIN CERTIFICATE-----` to `-----END CERTIFICATE-----`. Above each block:
   - `s:` is the subject (who the certificate is for)
   - `i:` is the issuer (who signed it)

   Certificate `0` is the server certificate. The next ones are the CA certificates.

2. Save **all CA certificates** (every block except number `0`) into one file:
   ```bash
   openssl s_client -connect <vault-host>:443 -servername <vault-host> -showcerts </dev/null 2>/dev/null \
     | awk '/BEGIN CERTIFICATE/{n++} n>1 && /BEGIN CERTIFICATE/,/END CERTIFICATE/' > ca.crt
   ```

3. Check the file:
   ```bash
   grep -c "BEGIN CERTIFICATE" ca.crt                      # number of CA certificates
   openssl x509 -in ca.crt -noout -subject -issuer -enddate
   ```
   If `ca.crt` is empty, the server sends only its own certificate and not the CA. Then you must get the CA from the PKI team (or from your OS / browser trust store).

4. Check that the CA really validates the server. The result must be `Verify return code: 0 (ok)`:
   ```bash
   openssl s_client -connect <vault-host>:443 -servername <vault-host> -CAfile ca.crt </dev/null 2>/dev/null \
     | grep "Verify return code"
   ```
   Also with curl (should print Vault health JSON, no certificate error):
   ```bash
   curl --cacert ca.crt https://<vault-host>/v1/sys/health
   ```

On cluster B, create the ConfigMap. The key must be `ca.crt` to match `caProvider.key`:

```bash
kubectl -n external-secrets create configmap vault-ca --from-file=ca.crt=ca.crt
```

Check:

```bash
kubectl -n external-secrets get configmap vault-ca -o jsonpath='{.data.ca\.crt}' | head -3
```

> If Vault itself runs with `tls_disable = 1` (like `00_vault_install`), the HTTPS is done by the ingress or load balancer in front of it. The CA you need is the one for **that** endpoint, the URL in `server`.

### 4.4 Apply the store

Set `server` and `roleId` (from 4.1) in the file for your environment, then:

```bash
kubectl apply -f 30_clustersecretstore-vault-approle-kgov.yaml
```

Check. `STATUS` should be `Valid` and `READY` should be `True`:

```bash
kubectl get clustersecretstore vault-backend
kubectl describe clustersecretstore vault-backend    # see Events if not Ready
```

## Step 5: ClusterExternalSecret (example: kafka)

`40_clusterexternalsecret-kafka.yaml` reads the Vault secret `secret/kgov/dev/kafka` and creates a Kubernetes Secret named `kafka` in every namespace that matches the selector.

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterExternalSecret
metadata:
  name: "kafka"
spec:
  externalSecretName: "kafka"
  namespaceSelectors:
  - matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values:
          # - demo
          - demo2
  refreshTime: "15s"
  externalSecretSpec:
    secretStoreRef:
      name: vault-backend
      kind: ClusterSecretStore
    refreshPolicy: Periodic
    refreshInterval: "15s"
    target:
      name: kafka
    dataFrom:
      - extract:
          key: kgov/dev/kafka
```

### 5.1 What each field does

| Field | Value | Meaning |
|-------|-------|---------|
| `kind: ClusterExternalSecret` | | Cluster-wide. It creates one `ExternalSecret` in each matching namespace. |
| `externalSecretName` | `kafka` | Name of the `ExternalSecret` created in each namespace |
| `namespaceSelectors` | `kubernetes.io/metadata.name In [demo2]` | Which namespaces get the secret. Add more names under `values` to cover more namespaces. `demo` is commented out, so it is not selected. |
| `refreshTime` | `15s` | How often ESO re-checks which namespaces match (new namespaces are picked up) |
| `externalSecretSpec.secretStoreRef` | `vault-backend` (`ClusterSecretStore`) | The store from Step 4 |
| `refreshPolicy` / `refreshInterval` | `Periodic` / `15s` | How often each `ExternalSecret` re-reads Vault. `15s` is for the demo. Use something like `1h` in production. |
| `target.name` | `kafka` | Name of the Kubernetes Secret that is created |
| `dataFrom.extract.key` | `kgov/dev/kafka` | Vault path **under the `secret` mount, without `data/`**. Every key in that Vault secret becomes a key in the Kubernetes Secret. |

The Vault secret `kgov/dev/kafka` (from `10_vault_secret` 1.2) has `KGOV_KAFKA_HOST`, `KGOV_KAFKA_USERNAME`, `KGOV_KAFKA_PASSWORD`, so the Kubernetes Secret `kafka` gets the same 3 keys.

Allowed by the policy: `kgov-read` can read only `secret/data/kgov/*`. A `key` outside `kgov/` gives `permission denied`.

### 5.2 Create the target namespace

The namespace must exist. `demo2` is the one the file selects:

```bash
kubectl create namespace demo2
```

(If you add a namespace to `values` later, create it too. With `refreshTime` set, ESO picks it up on the next refresh.)

### 5.3 Apply

```bash
kubectl apply -f 40_clusterexternalsecret-kafka.yaml
```

### 5.4 Check

```bash
# which namespaces were provisioned
kubectl get clusterexternalsecret kafka
kubectl get clusterexternalsecret kafka -o jsonpath='{.status.provisionedNamespaces}'; echo

# the ExternalSecret created in the namespace: expect STATUS SecretSynced, READY True
kubectl -n demo2 get externalsecret kafka

# the Kubernetes Secret and one value
kubectl -n demo2 get secret kafka
kubectl -n demo2 get secret kafka -o jsonpath='{.data.KGOV_KAFKA_HOST}' | base64 -d; echo
```

If it is not synced, look at the events:

```bash
kubectl -n demo2 describe externalsecret kafka
```

### 5.5 Test that it follows Vault

Change a value in Vault (on the leader, after `vault login`):

```bash
docker exec vault vault kv put secret/kgov/dev/kafka \
  KGOV_KAFKA_HOST="kafka.example.local:9092" \
  KGOV_KAFKA_USERNAME="demo-user" \
  KGOV_KAFKA_PASSWORD="new-password"
```

Wait one `refreshInterval` (15s), then read the Kubernetes Secret again:

```bash
kubectl -n demo2 get secret kafka -o jsonpath='{.data.KGOV_KAFKA_PASSWORD}' | base64 -d; echo
```

It should show `new-password`. Pods that read the Secret through environment variables must be restarted to see the change. Secrets mounted as files update by themselves after a short delay.

### 5.6 Clean up

```bash
kubectl delete -f 40_clusterexternalsecret-kafka.yaml
```

Deleting the `ClusterExternalSecret` deletes the `ExternalSecret` it created in each namespace. By default (`creationPolicy: Owner`) the Kubernetes Secret `kafka` is owned by that `ExternalSecret`, so it is deleted too. Pods that still use the Secret will lose it, so stop them first.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `metadata.annotations: Too long` | Applied CRDs without `--server-side` |
| `failed calling webhook ...` | Webhook pod not ready yet. Wait and apply again. |
| Store `InvalidProviderConfig` / `x509: certificate signed by unknown authority` | Wrong or missing `vault-ca` ConfigMap |
| Store error `invalid role or secret ID` | Wrong `roleId`, or `vault-approle` Secret has an old secret-id |
| ExternalSecret `permission denied` | Path is outside `kgov/`, or `key` includes `data/` |
| `ClusterExternalSecret` provisions nothing | Namespace does not exist, or its name is not in `namespaceSelectors` `values` |
| `ImagePullBackOff` | Cluster cannot pull from `kcshbr83.kcs`. Check registry access / imagePullSecrets. |

## Upgrading ESO

1. Generate the new CRDs (Step 2.1) with the new `--version`.
2. Render the operator again (Step 3.1) with the same version and change the images.
3. Apply CRDs first, then the operator.
