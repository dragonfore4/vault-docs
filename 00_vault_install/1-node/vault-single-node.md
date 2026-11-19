# Vault – 1 Node (Raft)

For learning/testing only (no HA).

```
1-node/
├── compose.yaml
├── config/vault.hcl   # only this file in config/
└── data/              # mkdir -p data
```

## Steps

```bash
mkdir -p data
docker compose up -d

export VAULT_ADDR=http://127.0.0.1:8200
vault operator init        # SAVE the unseal keys and root token
vault operator unseal      # run 3 times with different keys
vault status
```

If you access Vault remotely, set `api_addr` / `cluster_addr` in `vault.hcl` to the server IP.

## Difference from 3-node

No `retry_join`, no failover.
