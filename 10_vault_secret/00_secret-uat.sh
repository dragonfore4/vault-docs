# Run inside the Vault pod after init + unseal + `vault login`:
#   kubectl exec -i -n vault vault-0 -- sh < 10_vault-secrets-policy.sh
# Errors like "path is already in use" just mean the step was done before.
#!/bin/sh

# 1. Enable the KV v2 engine at secret/ (standalone mode does not create it)
vault secrets enable -path=secret kv-v2

# 2. Secrets: one Vault secret per group, under the kgov/ path (fake demo values)
vault kv put secret/kgov/uat/kafka \
  KGOV_KAFKA_HOST="kafka.example.local:9092" \
  KGOV_KAFKA_USERNAME="demo-user" \
  KGOV_KAFKA_PASSWORD="demo-password"

vault kv put secret/kgov/uat/redis \
  KGOV_REDIS_HOST="redis.example.local:6379" \
  KGOV_REDIS_USERNAME="demo-user" \
  KGOV_REDIS_PASSWORD="demo-password"

# 3. Policy: read only the kgov/ folder (KV v2 needs data/ and metadata/)
#    Used by both auth methods (11 and 12).
vault policy write kgov-read - <<POLICY
path "secret/data/kgov/*" {
  capabilities = ["read"]
}
path "secret/metadata/kgov/*" {
  capabilities = ["read", "list"]
}
POLICY
