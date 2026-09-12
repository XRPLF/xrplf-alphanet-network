# xrplf-alphanet-network

Alphanet is the XRP Ledger Foundation's live public staging network: a persistent XRPL chain
running an integration branch of feature work ahead of `develop`, with a public endpoint and a
faucet. This repository is the Foundation-owned home of everything about that network:
configuration, the deploy Makefile, faucet and health operations, per-node drill SSH keys,
monitoring setup, deploy history and the runbook.

Build and compose tooling is not here. The Makefile calls two sibling packages:
[multibranch-builder](https://github.com/XRPLF/multibranch-builder) merges the `alphanet.conf`
branches into one tree and runs the Cloud Build; [xrpld-lab](https://github.com/XRPLF/xrpld-lab)
generates the cluster config, mints the keystore and runs the ansible deploy.

## The network

| | |
|---|---|
| Nodes | six validators and two peers on XRPL-Labs bare metal; hosts in `network/inventory`, live state at `https://alphanet.xrpl.org/status/` |
| Public endpoint | `wss://alphanet.xrpl.org`, `https://alphanet.xrpl.org` (Cloudflare proxied, port 443) |
| RPC | `rpc.alphanet.xrpl.org` (DNS-only, origin nginx port 5017) |
| Faucet | `faucet.alphanet.xrpl.org` |
| Validator list | `http://vl.alphanet.xrpl.org/vl.json` (also served over https) |
| NetworkID | 21337 on the running chain; 24100 (`network/settings.mk` NETWORK_ID) from the next genesis reset |
| Integration branch | `Transia-RnD/rippled@alphanet`, composed from `alphanet.conf` |
| SDK branch | `Transia-RnD/xrpl.js@alphanet`, composed from `xrpljs.conf` after the deploy it matches |
| Images | `us-central1-docker.pkg.dev/xrplf-alphanet/xrpld`; builds run in GCP project `xrplf-perf-network` (the org policy blocks Cloud Build's service account in a fresh project) |

Every DNS record and the SSH access model are documented in `network/inventory`.

## What lives here

| Path | Holds |
|---|---|
| `alphanet.conf` | base, target and the branches merged into the xrpld integration branch |
| `xrpljs.conf` | base, target and the branches merged into the xrpl.js SDK branch, and the node its definitions.json comes from |
| `network/inventory` | hosts, roles, node names, SSH port/user/key paths, VL site, DNS record comments |
| `network/settings.mk` | build and xrpld-lab settings: NETWORK_ID, ONLINE_DELETE, DATABASE_PATH, STATSD_ADDRESS, PERF_PATH, FORCE_SUPPORTED, CLUSTER, WORKSPACE, PROJECT, POOL, AR |
| `network/ansible.example.yml` | template for `network/ansible.yml` (gitignored): topology, nginx, faucet, VL and status services, alloy credentials |
| `Makefile` | discover, compose, build, push, cluster, network-deploy, deploy, genesis-deploy, health, faucet-*, keystore-backup/restore, keys-*, alloy-*, status, status-publish, record-deploy |
| `ops/` | `nodes.py` (inventory parser, admin ports), `health.py`, `faucet.py`, `record_deploy.py`, `status_publish.py` (renders `network.json` for the status page) |
| `infra/keys/drill-keys.sh` | per-node drill SSH keys: gen, install, verify, isolate, share, revoke, list |
| `infra/observability/alloy-node-setup.sh` | adds `[insight]` and `[perf]` to a node and runs the Grafana Alloy sidecar |
| `data/deploys.json` | deploy history, appended by `make record-deploy` |
| `docs/runbook.md` | the deploy procedure |

## Quick start

```bash
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
cp network/ansible.example.yml network/ansible.yml   # fill in the faucet seed; the file is gitignored
make status                                          # inventory and last recorded deploy
make health                                          # server_info on every node's admin port
make discover                                        # which branches alphanet.conf resolves to
make compose build                                   # composed tree -> image -> .last-build.env
make deploy                                          # rolling deploy, chain preserved (--genesis 0)
```

`make deploy` never resets the chain. A genesis reset is `make genesis-deploy CONFIRM_GENESIS=alphanet`
and nothing else; see `docs/runbook.md`.

`WORKSPACE` must point at the workspace holding the live cluster keystore (`$(WORKSPACE)/$(CLUSTER)-cluster/keystore/`),
and `ANSIBLE_CONFIG` at the filled-in ansible YAML. Both live in this checkout (`workspace/` and
`network/ansible.yml`, gitignored) and are backed up to Secret Manager in project xrplf-alphanet
with `make keystore-backup`; the runbook has the procedure.

## Admin RPC ports

xrpld-lab assigns admin RPC ports by role and 1-based index: validators `5005 + i*100` (vnode1 5105 ... vnode6 5605),
peers `5005 + i*10` (pnode1 5015, pnode2 5025). `ops/nodes.py` derives them from the inventory order.

## data/deploys.json

A JSON list, one object per deploy, appended by `make record-deploy` (which `deploy` and
`genesis-deploy` run before `status-publish`):

```json
{
  "sha": "<full commit sha of the composed tree, BUILD_VERSION>",
  "image": "<image ref, IMAGE>",
  "genesis": false,
  "date": "2026-09-12T10:00:00Z",
  "operator": "<USER of the shell that ran make>"
}
```

## Tests

```bash
make test   # python3 -m pytest -q; mocks requests, touches no network
```
