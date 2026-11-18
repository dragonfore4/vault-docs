# For ESO in ANOTHER cluster (cluster B). Needs only HTTPS access to Vault.
#   kubectl exec -i -n vault vault-0 -- sh < 12_vault-auth-approle.sh
# Needs policy kgov-read from 10_vault-secrets-policy.sh.

vault auth enable approle

# secret_id_ttl and secret_id_num_uses are left out on purpose (lab):
# the secret-id never expires. For production set secret_id_ttl and rotate.
vault write auth/approle/role/kgov-read-role \
  token_policies=kgov-read \
  token_ttl=1h \
  token_max_ttl=4h

# role-id is NOT secret: put it in 31_clustersecretstore-vault-approle.yaml
vault read auth/approle/role/kgov-read-role/role-id

# The secret-id IS secret and is shown only once. Do NOT put it in this file.
# Run it by hand, then copy the value into cluster B:
#   vault write -f auth/approle/role/kgov-read-role/secret-id
#   kubectl --context kind-cluster-b -n external-secrets create secret generic \
#     vault-approle --from-literal=secret-id='<secret_id>'
