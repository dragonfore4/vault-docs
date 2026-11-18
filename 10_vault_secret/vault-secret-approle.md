# Vault Secrets, Policy and AppRole

This document is a step-by-step guide. Type each command yourself, in order. Start with Step 0 (log in), after Vault is initialized and unsealed (see `00_vault_install/vault-ha-3-nodes.md`). The `.sh` files in this folder (`00_secret.sh`, `10_app-role.sh`) hold the same commands for reference. Do not pipe them into Vault or Kubernetes.

| Part | Source file | What it does |
|------|-------------|--------------|
| 1 | `00_secret.sh` | Enable KV v2, write demo secrets, create the `kgov-read` policy |
| 2 | `10_app-role.sh` | Enable AppRole and create `kgov-read-role` (uses the `kgov-read` policy) |

Use case: an app or External Secrets Operator (ESO) in **another cluster** reads secrets from Vault over HTTPS using AppRole.

## Step 0: Log in to Vault

Every command in this document needs a token. Without one you get `permission denied` or `missing client token`. Before you start, Vault must be initialized and **unsealed** (see `00_vault_install/vault-ha-3-nodes.md`). Run the commands on the **leader** node.

Check the status first. It should show `Sealed: false` and `HA Mode: active` on the leader:

```bash
docker exec vault vault status
```

Log in with the root token from `vault operator init` (the `Initial Root Token` line):

```bash
docker exec -it vault vault login
```

Paste the token when it asks. The input is hidden. `-it` is needed because the command prompts for input.

Check who you are:

```bash
docker exec vault vault token lookup
```


### Commands in the rest of this document

They are written as `vault <command>`. With Docker, run them as `docker exec -it vault vault <command>` (after `vault login`). Example: `vault secrets list` is `docker exec -it vault vault secrets list`.


Use the root token only for this setup. Apps should use AppRole (Part 2), not the root token. Running a command twice is safe. Errors like `path is already in use` only mean that step was done before.

## Part 0: exec into vault
```bash
docker exec -it vault sh
```

## Part 1: Secrets and policy

### 1.1 Enable KV v2 at `secret/`

```bash
vault secrets enable -path=secret kv-v2
```

A standalone Vault does not create it by default.

### 1.2 Write the demo secrets

One Vault secret per group, under `secret/kgov/dev/`. The values are fake. Replace them with real ones.

```bash
vault kv put secret/kgov/dev/kafka \
  KGOV_KAFKA_HOST="kafka.example.local:9092" \
  KGOV_KAFKA_USERNAME="demo-user" \
  KGOV_KAFKA_PASSWORD="demo-password"

vault kv put secret/kgov/dev/redis \
  KGOV_REDIS_HOST="redis.example.local:6379" \
  KGOV_REDIS_USERNAME="demo-user" \
  KGOV_REDIS_PASSWORD="demo-password"
```

### 1.3 Create the policy `kgov-read`

Read-only on the `kgov/` folder. KV v2 stores data under `secret/data/...` and metadata under `secret/metadata/...`, so the policy needs both paths. The CLI path `secret/kgov/dev/kafka` is `secret/data/kgov/dev/kafka` in a policy.

Option A: save the policy as `kgov-read.hcl`, then load it:

```hcl
path "secret/data/kgov/*" {
  capabilities = ["read"]
}
path "secret/metadata/kgov/*" {
  capabilities = ["read", "list"]
}
```

```bash
vault policy write kgov-read kgov-read.hcl
```

(With Docker, the file must be inside the container, for example in the mounted `config/` folder at `/vault/config/kgov-read.hcl`.)

Option B: no file. Paste this into the terminal on the leader (it reads the policy from standard input, so `-i` is needed):

```bash
docker exec -i vault vault policy write kgov-read - <<'POLICY'
path "secret/data/kgov/*" {
  capabilities = ["read"]
}
path "secret/metadata/kgov/*" {
  capabilities = ["read", "list"]
}
POLICY
```

### 1.4 Check

```bash
vault kv get secret/kgov/dev/kafka
vault policy read kgov-read
```

## Part 2: AppRole

### 2.1 Enable AppRole

```bash
vault auth enable approle
```

### 2.2 Create the role `kgov-read-role`

```bash
vault write auth/approle/role/kgov-read-role \
  token_policies=kgov-read \
  token_ttl=1h \
  token_max_ttl=4h
```

`secret_id_ttl` and `secret_id_num_uses` are left out on purpose (lab), so the secret-id **never expires**. For production, set `secret_id_ttl` and rotate the secret-id regularly.

### 2.3 Read the role-id

```bash
vault read auth/approle/role/kgov-read-role/role-id
```

### 2.4 Create a secret-id (by hand)

```bash
vault write -f auth/approle/role/kgov-read-role/secret-id
```
**NOTED: please keep `secret-id` securely**


| Value | Secret? | Where it goes |
|-------|---------|---------------|
| `role-id` | No | In the `ClusterSecretStore` YAML (`31_clustersecretstore-vault-approle.yaml`) |
| `secret-id` | **Yes**, shown only once | Kubernetes Secret in cluster B. Never put it in a file or Git. |

Think of it as username + password: `role-id` is the username, `secret-id` is the password.

### 2.5 Test the AppRole login

Log in with the role-id and secret-id from 2.3 and 2.4. This checks the role before you give the secret-id to cluster B. Keep the secret-id until 2.6 is done, because it is shown only once.

```bash
docker exec vault vault write auth/approle/login role_id=<role_id> secret_id=<secret_id>
```

The output shows a `token`. That token should read `secret/kgov/*` and nothing else:

```bash
docker exec -e VAULT_TOKEN=<returned_token> vault vault kv get secret/kgov/dev/redis   # works
docker exec -e VAULT_TOKEN=<returned_token> vault vault kv get secret/other/path       # permission denied
```

If the login fails, fix the role or secret-id before you go on.

### 2.6 Store the secret-id in cluster B

Do this only after 2.5 works.

```bash
kubectl --context kind-cluster-b -n external-secrets create secret generic \
  vault-approle --from-literal=secret-id='<secret_id>'
```

## Notes

- The header comments in the `.sh` files mention old file names (`10_vault-secrets-policy.sh`, `12_vault-auth-approle.sh`). The real files are `00_secret.sh` and `10_app-role.sh`.
- Run the commands on the **leader**. A follower forwards writes, but using the leader avoids confusion.
- Use the root token only for setup. Apps should use AppRole, not the root token.
