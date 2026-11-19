# Vault – 1 Node (Raft)

For learning/testing only (no HA).

```
vault/
├── compose.yaml
├── config/
│   └── vault.hcl      # only this file in config/
└── data/              # owner must be 100:1000
```

## Step 1: Create the folder and files

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

# config/vault.hcl (use the server IP instead of 127.0.0.1 if you access Vault remotely)
cat > config/vault.hcl <<'HCL'
ui            = true
disable_mlock = true

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = 1
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
HCL

# data/ must be owned by the vault user inside the container (uid 100, gid 1000)
sudo chown -R 100:1000 data
```

> **Why `chown 100:1000`:** the container runs Vault as user `vault` (uid `100`, gid `1000`). If `data/` is owned by root or your user, Vault cannot write the Raft files and fails with `permission denied`.

## Step 2: Start and set up

```bash
docker compose up -d

docker exec vault vault operator init       # SAVE the unseal keys and root token
docker exec -it vault vault operator unseal # run 3 times with different keys
docker exec vault vault status
```

## Difference from 3-node

No `retry_join`, no failover.

## Common mistakes

- `data/` not owned by `100:1000` (`permission denied` in `docker logs vault`).
- Extra files in `config/`.
