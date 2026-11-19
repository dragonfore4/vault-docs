# Vault HA – 3 Nodes (Raft)

Each node has its own copy of this folder, created on that server:

```
vault/
├── compose.yaml
├── config/
│   └── vault.hcl      # only this file in config/
└── data/              # owner must be 100:1000
```

## Step 1: Create the folder and files (every node)

```bash
# Folders
mkdir -p ~/vault/config ~/vault/data
cd ~/vault

# compose.yaml
cat > compose.yaml <<'YAML'
services:
  vault:
    image: kcshbr83.kcs/docker-hub/hashicorp/vault:latest
    container_name: vault
    ports:
      - "8200:8200"
      - "8201:8201"
    cap_add:
      - IPC_LOCK
    environment:
      VAULT_ADDR: "http://127.0.0.1:8200"
    volumes:
      - ./config:/vault/config:ro
      - ./data:/vault/data:rw
    command: vault server -config=/vault/config/vault.hcl
YAML

# config/vault.hcl (edit the 3 per-node values, see the table below)
cat > config/vault.hcl <<'HCL'
ui            = true
disable_mlock = true

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-1"                        # CHANGE per node

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

api_addr     = "http://<THIS_NODE_IP>:8200"  # CHANGE per node
cluster_addr = "http://<THIS_NODE_IP>:8201"  # CHANGE per node
HCL

# data/ must be owned by the vault user inside the container (uid 100, gid 1000)
sudo chown -R 100:1000 data
```

> **Why `chown 100:1000`:** the container runs Vault as user `vault` (uid `100`, gid `1000`). If `data/` is owned by root or your user, Vault cannot write the Raft files and fails with `permission denied`.

## Per-node values

Only these differ in `vault.hcl`:

| Node | `node_id` | `api_addr` | `cluster_addr` |
|------|-----------|------------|----------------|
| 1 | `vault-1` | `http://<NODE1_IP>:8200` | `http://<NODE1_IP>:8201` |
| 2 | `vault-2` | `http://<NODE2_IP>:8200` | `http://<NODE2_IP>:8201` |
| 3 | `vault-3` | `http://<NODE3_IP>:8200` | `http://<NODE3_IP>:8201` |

The 3 `retry_join` blocks are identical on all nodes. See `config-template/` for per-node examples.

## Step 2: Start and set up

```bash
# 1. On every node
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

- `data/` not owned by `100:1000` (`permission denied` in `docker logs vault`).
- Duplicate `node_id`.
- `api_addr` / `cluster_addr` not the node's own IP.
- Extra files in `config/`.
- Ports `8200` / `8201` blocked between nodes.
