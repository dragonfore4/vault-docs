# Vault HA – 3 Nodes (Raft)

Each node has its own copy of this folder:

```
3-node/
├── compose.yaml
├── config/vault.hcl   # only this file in config/
└── data/              # mkdir -p data
```

## Per-node values

Only these differ in `vault.hcl`:

| Node | `node_id` | `api_addr` | `cluster_addr` |
|------|-----------|------------|----------------|
| 1 | `vault-1` | `http://<NODE1_IP>:8200` | `http://<NODE1_IP>:8201` |
| 2 | `vault-2` | `http://<NODE2_IP>:8200` | `http://<NODE2_IP>:8201` |
| 3 | `vault-3` | `http://<NODE3_IP>:8200` | `http://<NODE3_IP>:8201` |

Everything else, including the 3 `retry_join` blocks, is identical. See `config-template/` for per-node examples.

## Steps

```bash
# 1. On every node
mkdir -p data
docker compose up -d

# 2. Node 1 only: init (SAVE the unseal keys and root token)
docker exec vault vault operator init

# 3. Every node: unseal, run 3 times with different keys
docker exec -it vault vault operator unseal

# 4. Node 2 and 3 only, if not auto-joined via retry_join
docker exec vault vault operator raft join http://<NODE1_IP>:8200

# 5. Verify: expect 1 leader + 2 followers
docker exec -e VAULT_TOKEN=<root_token> vault vault operator raft list-peers
```

## Common mistakes

- Duplicate `node_id`.
- `api_addr` / `cluster_addr` not the node's own IP.
- Missing `data/` folder.
- Extra files in `config/`.
- Ports `8200` / `8201` blocked between nodes.
