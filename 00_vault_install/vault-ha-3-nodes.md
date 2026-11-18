# Vault HA with 3 Nodes (Raft)

## Key rule

Each node runs its **own copy** of the project folder. On every node:

- The `config/` folder contains **only one file: `vault.hcl`**.
  Do not keep `vault1.hcl`, `vault2.hcl`, `vault3.hcl` side by side on a node.
  `compose.yaml` mounts `./config` and starts `vault server -config=/vault/config/vault.hcl`, so any other name is ignored.
- You must **create a folder named `data`** next to `config/` (Raft storage is mounted from `./data`).
- Only **3 values** differ between nodes: `node_id`, `api_addr`, `cluster_addr`.

## Folder layout (per node)

```
00_vault_install/
├── compose.yaml
├── config/
│   └── vault.hcl      # the only file in config
└── data/              # create this folder (mkdir data)
```

```bash
mkdir -p data
```

## What to change on each node

| Node | `node_id` | `api_addr` | `cluster_addr` |
|------|-----------|------------|----------------|
| 1 | `vault-1` | `http://<NODE1_IP>:8200` | `http://<NODE1_IP>:8201` |
| 2 | `vault-2` | `http://<NODE2_IP>:8200` | `http://<NODE2_IP>:8201` |
| 3 | `vault-3` | `http://<NODE3_IP>:8200` | `http://<NODE3_IP>:8201` |

Everything else (`ui`, `disable_mlock`, `listener`, and the three `retry_join` blocks) is **identical on all nodes**.
The `retry_join` list contains the `api_addr` of all 3 nodes.

## `vault.hcl` template

```hcl
ui            = true
disable_mlock = true

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-1"            # CHANGE per node: vault-1 / vault-2 / vault-3

  retry_join {
    leader_api_addr = "http://<NODE1_IP>:8200"
  }
  retry_join {
    leader_api_addr = "http://<NODE2_IP>:8200"
  }
  retry_join {
    leader_api_addr = "http://<NODE3_IP>:8200"
  }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

api_addr     = "http://<NODE1_IP>:8200"   # CHANGE per node: this node's own IP
cluster_addr = "http://<NODE1_IP>:8201"   # CHANGE per node: this node's own IP
```

## Steps

1. Copy the folder to each of the 3 servers.
2. On each server, create `config/vault.hcl` from the template and set `node_id`, `api_addr`, `cluster_addr` for that node.
3. On each server, run `mkdir -p data`.
4. Start each node: `docker compose up -d`.
5. Initialize **once** on node 1 only:
   ```bash
   docker exec vault vault operator init
   ```
   **Noted: MUST Save the unseal keys and root token securely.**
6. Unseal node 1 (3 different keys out of 5 by default):
   ```bash
   # -i is required so the key prompt can read your input
   docker exec -it vault vault operator unseal
   ```
   Repeat the command 3 times, entering a different key each time.
7. Join node 2 and node 3 to the cluster (run on each of them, not on node 1):
   ```bash
   docker exec vault vault operator raft join http://<NODE1_IP>:8200
   ```
   > `retry_join` in `vault.hcl` often joins nodes automatically. If it did, this command is not needed (it will report that the node is already joined/initialized). Run it manually if the node does not appear in `list-peers`.
8. Unseal node 2 and node 3 (same command and keys as step 6, 3 times each):
   ```bash
   docker exec -it vault vault operator unseal
   ```
9. Check the cluster from any node:
   ```bash
   docker exec -e VAULT_TOKEN=<root_token> vault vault operator raft list-peers
   ```
   Expect 3 peers: one `leader` and two `follower`.

## Common mistakes

- `node_id` duplicated on two nodes. Each must be unique.
- `api_addr` / `cluster_addr` set to another node's IP. Each must be the node's own address.
- Missing `data/` folder or wrong permissions, so Raft cannot write.
- Leaving extra files in `config/`. Keep only `vault.hcl`.
- Ports `8200` (API) and `8201` (cluster) blocked by firewall or security group between nodes.
