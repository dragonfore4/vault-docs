# Vault Raft Recovery with peers.json (2 of 3 nodes down)

Scenario: a 3-node Vault HA cluster, one node per data center (DC). Two DCs go down, only one node survives. This document is for recovery. Commands are typed by hand, and I did not run them against a real cluster. Read "Before you start" first.

Reference: HashiCorp, "Recovering from lost quorum with peers.json" (Vault tutorials, Raft).

## Why the cluster is stuck

Raft needs a **majority** of voters to elect a leader and accept writes: 2 of 3. With 2 nodes gone, the survivor cannot get a majority.

Symptoms on the survivor:
- `vault status` shows `HA Mode: standby` or no leader, or requests time out.
- `vault operator raft list-peers` fails with `no leader` / `Raft leader not found`.
- Logs repeat `failed to make requestVote RPC` and `entering candidate state`.

`peers.json` forces the survivor to start with a **new, smaller peer list** (only itself), so it can elect itself leader again.

## Before you start

1. **First try to bring one DC back.** If either of the other 2 nodes comes back with its data, quorum returns and you need nothing here. `peers.json` is the last resort.
2. **Pick the best survivor.** If more than one node is reachable, use the one with the **highest** committed index. It has the most recent data. Anything newer on a lost node is lost.
   ```bash
   docker exec vault vault status | grep -i raft
   ```
   Compare `Raft Committed Index` and `Raft Applied Index` between nodes.
3. **The survivor must be healthy**: the container runs, the data folder is intact, and you still have the unseal keys (unless you use auto-unseal).
4. **Back up the data folder first.** Recovery changes the cluster membership, and a mistake can lose data.
   ```bash
   docker compose stop
   cp -a data data.backup-$(date +%Y%m%d-%H%M%S)
   ```
5. **Do not start the dead nodes** while you recover the survivor. If an old node comes back with stale data at the wrong time, it can confuse the cluster (see Step 6).

## Step 1: Find the values for peers.json

On the survivor, from `config/vault.hcl`:

| Value | Where | Example |
|-------|-------|---------|
| `id` | `node_id` in `storage "raft"` | `vault-1` |
| `address` | this node's own `cluster_addr` host + port (**8201, not 8200**), no `http://` | `13.251.124.180:8201` |
| raft folder | `path` in `storage "raft"` + `/raft` | `/vault/data/raft` in the container, `./data/raft` on the host |

The `id` must match `node_id` exactly. A wrong `id` makes recovery fail.

## Step 2: Stop Vault on the survivor

```bash
docker compose stop
```

## Step 3: Create peers.json

The file must be at `data/raft/peers.json` (host path, mounted as `/vault/data/raft/peers.json`). The `raft` folder already exists next to `vault.db`.

```bash
ls data/raft
```

Write the file with **only the survivor** (example: node 1):

```bash
cat > data/raft/peers.json <<'EOF'
[
  {
    "id": "vault-1",
    "address": "13.251.124.180:8201",
    "non_voter": false
  }
]
EOF
```

Check that it is valid JSON and readable:

```bash
python3 -m json.tool data/raft/peers.json
ls -l data/raft/peers.json
```

Fields:

| Field | Required | Meaning |
|-------|----------|---------|
| `id` | yes | `node_id` of the node |
| `address` | yes | `host:cluster-port` (8201) |
| `non_voter` | no (default `false`) | `true` makes the node a non-voter |

## Step 4: Start Vault and unseal

```bash
docker compose up -d
docker logs -f vault
```

The log shows that the file was read and then removed (**peers.json is read at startup and deleted after use**):

```
raft recovery initiated: recovery_file=peers.json
raft recovery found new config
raft recovery deleted peers.json
```

If you do not see these lines, check the path and the `id`.

Unseal (3 different keys), because the node starts sealed:

```bash
docker exec -it vault vault operator unseal
```

## Step 5: Verify

```bash
docker exec -it vault vault login
docker exec vault vault operator raft list-peers
```

Expected: only the survivor, as `leader`, `Voter` = `true`.

```bash
docker exec vault vault status        # Sealed false, HA Mode active
```

### Check the data

1. **Read old data.** Read a secret you know existed before the outage. The values must be the ones you expect:
   ```bash
   docker exec vault vault kv get secret/kgov/dev/kafka
   ```
   (Use any path that exists in your Vault. `secret/kgov/dev/kafka` is the example from `10_vault_secret`.) If the secret is missing, you may have recovered from a node with older data. Stop and compare with your backup or snapshot before you go on.

2. **Write new data.** This proves the cluster can accept writes (it needs a leader with quorum):
   ```bash
   docker exec vault vault kv put secret/recovery-test checked_at="$(date +%FT%T)"
   docker exec vault vault kv get secret/recovery-test
   ```

3. **Delete the test secret** when you are done:
   ```bash
   docker exec vault vault kv metadata delete secret/recovery-test
   ```

The cluster is now a **1-node** cluster. It works, but it has no fault tolerance until you add nodes. Do Step 6 as soon as the DCs are back.

## Step 6: Bring the other nodes back

The nodes that were down still hold **old Raft data and an old membership list**. Do not just start them. Wipe their Raft data and join them again as new members.

On each recovered node (node 2, then node 3). Check the survivor is the leader first:

1. Make sure Vault is stopped:
   ```bash
   docker compose stop
   ```
2. Back up, then empty the data folder (old Raft state):
   ```bash
   cp -a data data.old-$(date +%Y%m%d-%H%M%S)
   rm -rf data/*
   ```
   Keep `config/vault.hcl` as is (its own `node_id`, `api_addr`, `cluster_addr`).
3. Start Vault:
   ```bash
   docker compose up -d
   ```
   `retry_join` in `vault.hcl` should join the leader by itself. Wait about 30 seconds, then check whether this node has already joined.

   **Check A: on the leader** (the survivor). This is the reliable check. The node must be in the peer list:
   ```bash
   docker exec vault vault operator raft list-peers
   ```
   If this node's `node_id` (for example `vault-2`) is listed, it **has joined**. **You can skip the manual join below and go to step 4 (unseal).**

   **Only if the node is not in `list-peers` on the leader**, join by hand. Join must be done **before** unseal:
   ```bash
   docker exec vault vault operator raft join http://<SURVIVOR_IP>:8200
   ```
   Then run Check A again. If the join fails because the leader is not reachable, check that port `8200` and `8201` are open between the nodes.
4. Unseal (3 keys):
   ```bash
   docker exec -it vault vault operator unseal
   ```
5. On the leader, check:
   ```bash
   docker exec vault vault operator raft list-peers
   ```
   Expect 2 peers, then 3 after the last node. Do the nodes **one at a time**.
6. Check that the node has the data. A follower forwards `kv get` requests to the leader, so a normal read does **not** prove the data was copied. Compare the Raft indexes instead. Run on the leader and on the rejoined node:
   ```bash
   docker exec vault vault status | grep -i "raft"
   ```
   The rejoined node's `Applied Index` should be equal to (or just behind) the leader's `Committed Index`, and it should catch up within a few seconds. If it stays far behind, check the node's logs and the network on port `8201`.

   Then read a secret **through the rejoined node** to confirm it answers (use the root token, because the login in step 5 was saved only on the other node):
   ```bash
   docker exec -e VAULT_TOKEN=<root_token> vault vault kv get secret/kgov/dev/kafka
   ```

> Why wipe the data? The recovered node would still think it is part of the old 3-node cluster, and its log can have entries the new leader never had. Joining as a fresh node lets the leader replicate its data to it.

### Alternative: list all 3 nodes in peers.json

If the 2 DCs will be back **soon**, with the **same host addresses and the original data**, HashiCorp says you can list every server in `peers.json` instead:

```json
[
  { "id": "vault-1", "address": "13.251.124.180:8201", "non_voter": false },
  { "id": "vault-2", "address": "13.212.227.50:8201",  "non_voter": false },
  { "id": "vault-3", "address": "18.138.224.190:8201", "non_voter": false }
]
```

Put the **same file** on every node you want to restore, then restart them. Quorum returns once 2 of the 3 are up. Use this only when the nodes' data is healthy. Otherwise use the wipe-and-join method above.

## After recovery

- Check `raft list-peers` shows 3 voters and one leader.
- Unseal every node. Restart does not keep the unsealed state.
- Take a Raft snapshot and store it **outside** the cluster:
  ```bash
  docker exec vault vault operator raft snapshot save /vault/data/backup.snap
  ```
  Copy the file off the server (the data folder is on the same disk as Vault).
- Delete the `data.backup-*` and `data.old-*` folders when you are sure everything works. They contain Vault data. Keep them in a safe place until then.
- Write down what failed, so that next time 2 of 3 nodes are not in 2 DCs that can fail together.

## Common mistakes

- Using port `8200` in `address`. It must be the **cluster port 8201**.
- `id` different from `node_id` in `vault.hcl`.
- Writing `peers.json` in `data/` instead of `data/raft/`.
- Starting the old nodes with their old data while the survivor is a 1-node cluster.
- Doing this when only the network between DCs is cut. Both sides may elect a leader (**split brain**). Make sure the other nodes are really down before using `peers.json`.
- Forgetting to unseal after the restart.

## Prevention

- A 3-node cluster survives only **1** failure. To survive 2 DCs down you need 5 nodes (majority 3), or accept manual recovery like this document.
- Schedule `raft snapshot save` (cron) and store the snapshots off-site.
- Raft Autopilot can remove dead servers automatically only while quorum still exists. It cannot fix a lost quorum.
