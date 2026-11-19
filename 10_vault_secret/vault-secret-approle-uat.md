# Vault Secrets, Policy and AppRole

## What is this and why do we need it

Apps in another Kubernetes cluster need passwords (Kafka, Redis, ...). Putting them in Git or YAML is unsafe. Instead we store them in Vault and let the app fetch them at runtime. This guide sets up three pieces:

| Piece | What it is | Why we need it |
|-------|------------|----------------|
| **KV v2 secrets** | Key/value store in Vault, with versioning | One safe place for passwords, not in Git |
| **Policy** (`kgov-read`) | Rules saying who can read which path | Least privilege: the app reads only `kgov/*`, nothing else |
| **AppRole** (`kgov-read-role`) | A login method for machines (`role-id` + `secret-id`) | Apps cannot type a password or use the root token. They log in with AppRole and get a short-lived token limited by the policy |

Flow: the app (or External Secrets Operator in cluster B) logs in with AppRole, gets a token, then reads `secret/kgov/*` over HTTPS.

Prerequisite: Vault is initialized and unsealed (see `../00_vault_install/3-node/vault-ha-3-nodes.md`). Run everything on the **leader**.

Reference scripts: `00_secret-uat.sh` (Part 1), `10_app-role.sh` (Part 2). Type the commands yourself; do not pipe the scripts in.

## Step 0: Log in

Every command needs a token, otherwise you get `permission denied`. Use the root token for setup only.

```bash
docker exec vault vault status          # Sealed: false, HA Mode: active
docker exec -it vault vault login       # paste the root token (hidden)
docker exec -it vault sh                # then run the commands below as `vault ...`
```

Re-running a command is safe (`path is already in use` just means it was done before).

## Part 1: Secrets and policy

**Goal:** store the secrets and define who may read them.

### 1.1 - 1.2 Enable KV v2 and write secrets

A standalone Vault has no KV engine by default. Values below are fake, replace them with real ones.

```bash
vault secrets enable -path=secret kv-v2

vault kv put secret/kgov/uat/kafka \
  KGOV_KAFKA_HOST="kafka.example.local:9092" \
  KGOV_KAFKA_USERNAME="demo-user" \
  KGOV_KAFKA_PASSWORD="demo-password"

vault kv put secret/kgov/uat/redis \
  KGOV_REDIS_HOST="redis.example.local:6379" \
  KGOV_REDIS_USERNAME="demo-user" \
  KGOV_REDIS_PASSWORD="demo-password"
```

### 1.3 Policy `kgov-read`

Gives read-only access to `kgov/`. KV v2 splits storage into `data/` (the values) and `metadata/` (versions, list), so the policy needs both paths.

```bash
# Run from the host (-i reads the policy from stdin)
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
vault kv get secret/kgov/uat/kafka
vault policy read kgov-read
```

## Part 2: AppRole

**Goal:** give the app its own login that is tied to the `kgov-read` policy.

```bash
# 2.1 Enable the AppRole login method
vault auth enable approle

# 2.2 Create the role: tokens get the kgov-read policy, live 1h (max 4h)
vault write auth/approle/role/kgov-read-role \
  token_policies=kgov-read \
  token_ttl=1h \
  token_max_ttl=4h

# 2.3 Get the role-id
vault read auth/approle/role/kgov-read-role/role-id

# 2.4 Create a secret-id
#     !!! SAVE THE `secret_id` VALUE IMMEDIATELY !!!
#     It is shown ONLY ONCE. Vault cannot show it again.
#     If you lose it, you must create a new one (run this command again).
vault write -f auth/approle/role/kgov-read-role/secret-id
```

> **MUST SAVE: copy the `secret_id` from the output now.**
> You need it for 2.5 (test) and `../20_ESO/eso-install.md` step 4.2 (cluster B). Store it in a password manager or a safe note until step 4.2 is done. Do not put it in Git.

Think of it as username + password. `secret_id_ttl` is unset (lab), so the secret-id never expires. In production, set it and rotate.

| Value | Secret? | Where it goes |
|-------|---------|---------------|
| `role-id` | No (username) | `ClusterSecretStore` YAML (`31_clustersecretstore-vault-approle.yaml`) |
| `secret-id` | **Yes** (password) | Kubernetes Secret in cluster B. Never in Git. |

### 2.5 Test the login

Confirms the role works and the policy limits it, before you hand the secret-id to cluster B.

```bash
docker exec vault vault write auth/approle/login role_id=<role_id> secret_id=<secret_id>

# Use the returned token: kgov/* works, everything else is denied
docker exec -e VAULT_TOKEN=<token> vault vault kv get secret/kgov/uat/redis   # works
docker exec -e VAULT_TOKEN=<token> vault vault kv get secret/other/path        # permission denied
```

If login fails, fix the role or secret-id before continuing.

### 2.6 Store the secret-id in cluster

Not in this doc. Continue in `../20_ESO/eso-install.md` (step 4.2), which creates the Kubernetes Secret `vault-approle` in cluster B.
