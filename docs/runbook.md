# Alphanet deploy runbook

Alphanet is a live chain that people use. The default deploy preserves it; a genesis reset is a
separate target that refuses to run without an explicit confirmation on the command line.

## Where the deploy runs

Run the deploy from the checkout of this repository at `/home/sentinel/xrplf-alphanet-network`
on the sentinel server, as the `sentinel` user. Every command below is complete on its own: it
changes into that directory first, so it runs from any shell location. Host, port, key and user
are in the atlas entry for `server:sentinel`. The two files
that make the deploy alphanet's deploy live there and nowhere else today (unverified in this
repository; check on the server before the first run):

- the xrpld-lab workspace with the cluster keystore under `/home/sentinel/.sentinel/xrpld-lab/workspace/`.
  The keystore (`keystore/vl` plus `keystore/vnode1..6`) is the network's identity: the VL
  publisher key and the validator keys. xrpld-lab refuses a non-genesis deploy when the
  cluster directory has no keystore, rather than minting a new identity. The directory on
  sentinel is named `alphanet-cluster`; `CLUSTER` in `network/settings.mk` is `xrpld-alphanet`,
  so xrpld-lab looks for `$(WORKSPACE)/xrpld-alphanet-cluster`. Rename or symlink the directory
  on sentinel to match, or pass `CLUSTER=alphanet`, before the first deploy from this repo.
- the filled-in ansible YAML at `/home/sentinel/.sentinel/xrpld-lab/alphanet-ansible.yml`
  (topology, nginx and faucet services, the faucet seed, alloy credentials). Its seedless
  template is `network/ansible.example.yml`.

Point the Makefile at them:

```bash
cd /home/sentinel/xrplf-alphanet-network && printf 'WORKSPACE=/home/sentinel/.sentinel/xrpld-lab/workspace\nANSIBLE_CONFIG=/home/sentinel/.sentinel/xrpld-lab/alphanet-ansible.yml\n' > .env.mk
```

`network/settings.mk` includes `.env.mk` when it exists (gitignored), so the two paths are set
once per checkout instead of per shell.

Never copy the keystore or the ansible YAML into this repository or another machine without
Denis deciding it; `.gitignore` excludes `network/ansible.yml` and `workspace/`.

The build needs `gcloud` auth for project `xrplf-perf-network` (where Cloud Build runs) and
push access to the Artifact Registry in `xrplf-alphanet`. `xrpld-builder push` needs push
access to `Transia-RnD/rippled`.

## 1. Discover

```bash
cd /home/sentinel/xrplf-alphanet-network && make discover
```

Runs `xrpld-builder compose --dry-run` on `alphanet.conf` and prints the branches that will
be merged into `Transia-RnD/rippled@alphanet` without writing the tree. Get sign-off on the
list. To add a branch, add a `<owner/repo> <branch> [rebase]` line to `alphanet.conf` and
commit it here.

## 2. Compose and build

```bash
cd /home/sentinel/xrplf-alphanet-network && make compose
cd /home/sentinel/xrplf-alphanet-network && make build
```

`compose` writes the merged tree to `$(WORKSPACE)/rippled` and `manifest.json`. `build` runs
the Cloud Build (`--force-supported ON`: the chain has amendments enabled that the branch may
not mark supported, and an unsupported enabled amendment amendment-blocks the node at startup),
then pushes the tree to `Transia-RnD/rippled@alphanet` so xrpld-lab can fetch the feature
list at that commit, and writes `.last-build.env` with `IMAGE`, `BUILD_SERVER` and
`BUILD_VERSION`. `cluster` and `deploy` read that file.

## 3. Dry run, then live

```bash
cd /home/sentinel/xrplf-alphanet-network && make -n deploy
```

Prints every `xrpld-lab` command that a live run would execute. Read the `create:ansible`
line: `--genesis 0`, `--network_id 24100`, `--online_delete 10000`,
`--database_path /opt/ripple/lib/db`, the image and the build version.

```bash
cd /home/sentinel/xrplf-alphanet-network && nohup make deploy > /home/sentinel/.sentinel/logs/alphanet-$(date +%F-%H%M).log 2>&1 < /dev/null &
```

`deploy` runs `cluster` with `GENESIS=0`, `network-deploy` (rolling, one host at a time, then
`xrpld-lab health` waits for consensus), `record-deploy` and `status-publish` (renders
`network.json` from `data/deploys.json`, `alphanet.conf`, the inventory and the node's
`server_info`, `feature` and faucet `account_info`, and copies it to pnode1 for the status page
at `https://alphanet.xrpl.org/status/`). Before the ansible runs,
`network-deploy` inspects the generated `main.yml` and refuses it if it contains
`rm -rf /var/lib/xrpld/db` and no genesis confirmation was given, so a stale genesis playbook
in the workspace cannot be deployed by accident.

Launch a live run with `nohup ... &`, never as a foreground SSH command: when the SSH session
ends a foreground run dies mid-deploy. Two earlier runs (2026-08-05, 2026-08-06) died that way.
A run takes 20 to 40 minutes; follow the log file.

## 4. Genesis reset (explicit confirmation)

A genesis deploy wipes every account, balance and ledger on the live chain and funds the
faucet from the new genesis account. It also applies the pending `NETWORK_ID` change (21337 to
24100). Get explicit approval from Denis before running it.

```bash
cd /home/sentinel/xrplf-alphanet-network && make genesis-deploy                          # refuses, exit 2, prints why
cd /home/sentinel/xrplf-alphanet-network && make -n genesis-deploy CONFIRM_GENESIS=alphanet   # dry run of the live commands
cd /home/sentinel/xrplf-alphanet-network && nohup make genesis-deploy CONFIRM_GENESIS=alphanet > /home/sentinel/.sentinel/logs/alphanet-genesis-$(date +%F-%H%M).log 2>&1 < /dev/null &
```

`CONFIRM_GENESIS=alphanet` must be given on the make command line; an environment variable
or a value in a file does not count. The confirmation is inherited by the `cluster` and
`network-deploy` sub-makes, which otherwise refuse `--genesis 1` and the db-wiping playbook.
`genesis-deploy` then runs `faucet-fund` (pays the genesis balance minus 200 XRP to the faucet
account derived from the seed in the ansible YAML; the seed is passed only to the node's
`wallet_propose` and never printed) and `faucet-verify`.

After a genesis, `BOOTSTRAP_VL=1` on `make cluster` emits the static `[validators]` list
alongside the publisher list so the fresh chain reaches quorum before the VL site serves.
Drop it on the next deploy once every node fetches the VL.

## 5. Verify

```bash
curl -s https://alphanet.xrpl.org -X POST -H 'Content-Type: application/json' \
  -d '{"method":"server_info","params":[{}]}' | jq '.result.info.server_state, .result.info.complete_ledgers'
cd /home/sentinel/xrplf-alphanet-network && make health
```

Expect `proposing` or `full` and a growing `complete_ledgers`. `make health` queries each
node's admin port directly: validators must report `proposing`, peers `full`; it exits 1 if
any node does not. After a genesis, `make faucet-verify` must show a faucet balance.

## Other operations

- `make status`: inventory, cluster path, last build, last recorded deploy.
- `make keys-gen keys-install`, `keys-verify`, `keys-isolate`, `keys-list`, `keys-share NODE=vnode3`,
  `keys-revoke NODE=vnode3`: per-node drill SSH keys (`infra/keys/drill-keys.sh`). The
  operator break-glass key stays on every node and is what install and revoke authenticate with.
- `make alloy-deploy`, `alloy-status`, `alloy-logs NODE_IP=79.110.60.99`: the Grafana Alloy
  sidecar per node, credentials from `alloy.credentials` in the ansible YAML, pushing to
  `alloy.push_host` (staging.push.monitoring.xrplf.org). Needs a `peersyst/xrpl-monitoring`
  checkout at `ALLOY_SRC` (default `../xrpl-monitoring`). Restarting a node to load the
  stanzas takes it out of consensus; on a 6-validator UNL the quorum is 5, so the script
  waits for the node to rejoin before the loop moves to the next one.
