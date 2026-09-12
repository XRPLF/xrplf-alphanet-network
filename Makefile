# Alphanet: build, deploy and operate the Foundation's live public XRPL staging network.
# Build and compose come from the xrpld-compose CLI; cluster generation and deploy from xrpld-lab.
# This Makefile knows one network, so a chain reset is never the default: `deploy` always passes
# --genesis 0 and only `genesis-deploy CONFIRM_GENESIS=alphanet` passes --genesis 1.

include network/settings.mk

PYTHON    ?= python3
INVENTORY := network/inventory
CONF      := alphanet.conf

# Node inventory, read from network/inventory.
VIPS       := $(shell awk '$$1=="VALIDATOR"{print $$2}' $(INVENTORY))
PIPS       := $(shell awk '$$1=="PEER"{print $$2}' $(INVENTORY))
NODE_NAMES := $(shell awk '$$1=="VALIDATOR"||$$1=="PEER"{print $$3}' $(INVENTORY))
SSH_KEY     := $(shell awk '$$1=="SSH_KEY"{print $$2}' $(INVENTORY))
SSH_KEY_DIR := $(shell awk '$$1=="SSH_KEY_DIR"{print $$2}' $(INVENTORY))
SSH_PORT    := $(shell awk '$$1=="SSH_PORT"{print $$2}' $(INVENTORY))
SSH_USER    := $(shell awk '$$1=="SSH_USER"{print $$2}' $(INVENTORY))
VL_SITE     := $(shell awk '$$1=="VL_SITE"{print $$2}' $(INVENTORY))

# Integration branch, read from alphanet.conf. xrpld-lab fetches the feature list from
# BUILD_SERVER at BUILD_VERSION, so the composed tree must be pushed there before deploy.
TARGET_REPO   := $(shell awk '$$1=="target"{print $$2}' $(CONF))
TARGET_BRANCH := $(shell awk '$$1=="target"{print $$3}' $(CONF))
BUILD_SERVER  ?= https://github.com/$(TARGET_REPO)/tree/$(TARGET_BRANCH)

TREE     := $(WORKSPACE)/rippled
MANIFEST := $(WORKSPACE)/manifest.json
BUILD_JSON := $(WORKSPACE)/build.json
MAIN_YML := $(WORKSPACE)/$(CLUSTER)-cluster/ansible/main.yml

# A chain reset is confirmed only by CONFIRM_GENESIS=alphanet given on the command line.
# Sub-makes inherit command-line variables with that origin, so genesis-deploy's confirmation
# reaches cluster and network-deploy without a second variable.
ifeq ($(origin CONFIRM_GENESIS),command line)
ifeq ($(CONFIRM_GENESIS),alphanet)
GENESIS_CONFIRMED := 1
endif
endif
GENESIS ?= 0

SSH_OPTS := -i $(SSH_KEY) -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -p $(SSH_PORT)

.DEFAULT_GOAL := help
.PHONY: help
help:   ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
	  awk -F':.*## *' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- compose and build ---------------------------------------------------------------
.PHONY: discover compose build push
discover:   ## show which branches alphanet.conf resolves to, without writing the tree
	@command -v xrpld-compose >/dev/null || { echo "xrpld-compose not found"; exit 1; }
	xrpld-compose compose --conf $(CONF) --workdir $(WORKSPACE) --dry-run --force-supported $(FORCE_SUPPORTED)

compose:    ## merge the alphanet.conf branches into $(WORKSPACE)/rippled and write manifest.json
	@command -v xrpld-compose >/dev/null || { echo "xrpld-compose not found"; exit 1; }
	xrpld-compose compose --conf $(CONF) --workdir $(WORKSPACE) --force-supported $(FORCE_SUPPORTED)

build:      ## Cloud Build the composed tree, push the tree to the target branch, write .last-build.env
	@command -v xrpld-compose >/dev/null || { echo "xrpld-compose not found"; exit 1; }
	@[ -d "$(TREE)" ] || { echo "no composed tree at $(TREE); run 'make compose' first"; exit 1; }
	@image=$$(xrpld-compose build --tree $(TREE) --project $(PROJECT) --ar $(AR) \
	    $(if $(TAG),--tag $(TAG)) $(if $(strip $(POOL)),--pool $(POOL)) \
	    --force-supported $(FORCE_SUPPORTED) --workdir $(WORKSPACE) | tee /dev/stderr | tail -1); \
	 [ -n "$$image" ] || { echo "BUILD FAILED: xrpld-compose build printed no image ref"; exit 1; }; \
	 sha=$$(git -C $(TREE) rev-parse HEAD); \
	 printf 'IMAGE=%s\nBUILD_SERVER=%s\nBUILD_VERSION=%s\n' "$$image" "$(BUILD_SERVER)" "$$sha" > $(LAST_BUILD); \
	 echo "wrote $(LAST_BUILD): IMAGE=$$image BUILD_VERSION=$$sha"
	$(MAKE) push

push:       ## push the composed tree to $(TARGET_REPO)@$(TARGET_BRANCH) so BUILD_VERSION is fetchable
	@command -v xrpld-compose >/dev/null || { echo "xrpld-compose not found"; exit 1; }
	xrpld-compose push --tree $(TREE) --target $(TARGET_REPO)@$(TARGET_BRANCH) --manifest $(MANIFEST) --build $(BUILD_JSON)

# --- cluster and deploy --------------------------------------------------------------
.PHONY: cluster network-deploy deploy genesis-deploy
cluster:   ## generate cluster config + ansible for the inventory (xrpld-lab create:ansible)
	@command -v xrpld-lab >/dev/null || { echo "xrpld-lab not found"; exit 1; }
	@if [ "$(GENESIS)" = "1" ] && [ -z "$(GENESIS_CONFIRMED)" ]; then \
	   echo "REFUSED: GENESIS=1 resets the chain and wipes every account on alphanet."; \
	   echo "Use 'make genesis-deploy CONFIRM_GENESIS=alphanet' for an intentional reset."; exit 1; fi
	@[ -n "$(IMAGE)" ] || { echo "IMAGE= required (run 'make build' first, or pass IMAGE=)"; exit 1; }
	@[ -f "$(ANSIBLE_CONFIG)" ] || { echo "no $(ANSIBLE_CONFIG); cp network/ansible.example.yml network/ansible.yml and fill in the faucet seed"; exit 1; }
	@echo ">> cluster $(CLUSTER) [genesis=$(GENESIS)]: $(IMAGE)  (log_level=$(LOG_LEVEL))"
	xrpld-lab create:ansible \
	  --cluster $(CLUSTER) \
	  --genesis $(GENESIS) $(if $(GENESIS_FILE),--genesis_file $(GENESIS_FILE)) \
	  $(if $(NETWORK_ID),--network_id $(NETWORK_ID)) \
	  --workspace $(WORKSPACE) --database_path $(DATABASE_PATH) \
	  --log_level $(LOG_LEVEL) \
	  --online_delete $(ONLINE_DELETE) \
	  --tree_cache_target_entries $(TREE_CACHE_TARGET_ENTRIES) \
	  $(if $(FEATURES_FILE),--features_file $(FEATURES_FILE)) \
	  $(if $(filter 1,$(GENESIS)),$(if $(ALL_AMENDMENTS),--all-amendments)) \
	  $(if $(STATSD_ADDRESS),--statsd_address $(STATSD_ADDRESS)) \
	  $(if $(PERF_PATH),--perf_path $(PERF_PATH)) \
	  $(if $(VL_SITE),--vl_site "$(VL_SITE)") \
	  $(if $(BOOTSTRAP_VL),--bootstrap_vl) \
	  --ansible_config $(ANSIBLE_CONFIG) \
	  --image "$(IMAGE)" \
	  --build_server "$(BUILD_SERVER)" --build_version "$(BUILD_VERSION)"

network-deploy:   ## run the generated ansible (rolling, one host at a time), then wait for consensus
	@command -v xrpld-lab >/dev/null || { echo "xrpld-lab not found"; exit 1; }
	@[ -f "$(MAIN_YML)" ] || { echo "no generated ansible at $(MAIN_YML); run 'make cluster' first"; exit 1; }
	@if grep -q 'rm -rf /var/lib/xrpld/db' "$(MAIN_YML)" && [ -z "$(GENESIS_CONFIRMED)" ]; then \
	   echo "REFUSED: $(MAIN_YML) wipes /var/lib/xrpld/db and alphanet is a live network."; \
	   echo "Regenerate with 'make cluster' (GENESIS=0), or run 'make genesis-deploy CONFIRM_GENESIS=alphanet' for a real reset."; exit 1; fi
	xrpld-lab deploy:ansible --name $(CLUSTER) --workspace $(WORKSPACE)
	xrpld-lab health --vips $(VIPS)

deploy:   ## cluster + network-deploy with the last build, preserving the chain (--genesis 0)
	@[ -n "$(IMAGE)" ] || { echo "no IMAGE: run 'make build' first (or pass IMAGE=)"; exit 1; }
	$(MAKE) cluster GENESIS=0 IMAGE="$(IMAGE)" BUILD_SERVER="$(BUILD_SERVER)" BUILD_VERSION="$(BUILD_VERSION)"
	$(MAKE) network-deploy
	$(MAKE) record-deploy GENESIS=0

genesis-deploy:   ## RESET the chain: cluster + network-deploy with --genesis 1, then fund the faucet. Needs CONFIRM_GENESIS=alphanet
	@if [ -z "$(GENESIS_CONFIRMED)" ]; then \
	   echo "REFUSED: genesis-deploy resets alphanet and wipes every account, balance and ledger on the live chain."; \
	   echo "Run 'make genesis-deploy CONFIRM_GENESIS=alphanet' on the command line to confirm the reset."; exit 1; fi
	@[ -n "$(IMAGE)" ] || { echo "no IMAGE: run 'make build' first (or pass IMAGE=)"; exit 1; }
	$(MAKE) cluster GENESIS=1 IMAGE="$(IMAGE)" BUILD_SERVER="$(BUILD_SERVER)" BUILD_VERSION="$(BUILD_VERSION)"
	$(MAKE) network-deploy
	$(MAKE) faucet-fund
	$(MAKE) faucet-verify
	$(MAKE) record-deploy GENESIS=1

# --- health, faucet, deploy history --------------------------------------------------
.PHONY: health faucet-fund faucet-verify record-deploy status
health:   ## server_info on every node's admin port; validators must be proposing, peers full
	$(PYTHON) -m ops.health --inventory $(INVENTORY)

faucet-fund:   ## pay the genesis balance to the faucet account (seed from $(ANSIBLE_CONFIG), never printed)
	$(PYTHON) -m ops.faucet fund --inventory $(INVENTORY) --ansible-config $(ANSIBLE_CONFIG)

faucet-verify:   ## check the faucet account balance is above the minimum
	$(PYTHON) -m ops.faucet verify --inventory $(INVENTORY) --ansible-config $(ANSIBLE_CONFIG)

record-deploy:   ## append {sha, image, genesis, date, operator} to data/deploys.json
	$(PYTHON) -m ops.record_deploy --sha "$(BUILD_VERSION)" --image "$(IMAGE)" --genesis $(GENESIS) --operator "$(USER)"

status:   ## print the inventory and the last recorded deploy
	@echo "validators: $(VIPS)"; echo "peers:      $(PIPS)"; echo "nodes:      $(NODE_NAMES)"
	@echo "ssh:        $(SSH_USER)@:$(SSH_PORT) key=$(SSH_KEY) drill keys=$(SSH_KEY_DIR)"
	@echo "vl_site:    $(VL_SITE)"; echo "network_id: $(NETWORK_ID) (settings.mk; takes effect at genesis)"
	@echo "cluster:    $(WORKSPACE)/$(CLUSTER)-cluster"; echo "ansible:    $(ANSIBLE_CONFIG)"
	@echo "last build: IMAGE=$(IMAGE) BUILD_VERSION=$(BUILD_VERSION)"
	@$(PYTHON) -m ops.record_deploy --show-last

# --- per-node drill SSH keys ---------------------------------------------------------
# One keypair per node, so a drill participant is given exactly one node and revoking them
# rotates nobody else. install/revoke authenticate with the operator break-glass key.
.PHONY: keys-gen keys-install keys-verify keys-isolate keys-list keys-share keys-revoke
DRILL_KEYS = @VIPS="$(VIPS)" PIPS="$(PIPS)" NODE_NAMES="$(NODE_NAMES)" SSH_KEY="$(SSH_KEY)" \
	 SSH_KEY_DIR="$(SSH_KEY_DIR)" SSH_PORT="$(SSH_PORT)" SSH_USER="$(SSH_USER)" \
	 bash infra/keys/drill-keys.sh

keys-gen:       ## generate any missing per-node drill keypairs (local only, no network)
	$(DRILL_KEYS) gen
keys-install:   ## install per-node drill pubkeys into each node's authorized_keys
	$(DRILL_KEYS) install $(NODE)
keys-verify:    ## check every node answers on its own drill key
	$(DRILL_KEYS) verify $(NODE)
keys-isolate:   ## prove each drill key opens ONLY its own node
	$(DRILL_KEYS) isolate $(NODE)
keys-list:      ## table of which nodes have a drill key locally and installed
	$(DRILL_KEYS) list
keys-share:     ## print the handout for one node (make keys-share NODE=vnode3)
	@[ -n "$(NODE)" ] || { echo "NODE= required (e.g. NODE=vnode3)"; exit 1; }
	$(DRILL_KEYS) share $(NODE)
keys-revoke:    ## revoke one node's drill key (make keys-revoke NODE=vnode3)
	@[ -n "$(NODE)" ] || { echo "NODE= required (e.g. NODE=vnode3)"; exit 1; }
	$(DRILL_KEYS) revoke $(NODE)

# --- monitoring ----------------------------------------------------------------------
# Per-node Basic Auth: the monitoring backend maps each credential to its own tenant. The
# credentials are alloy.credentials.<node> in $(ANSIBLE_CONFIG); they are piped to the node's
# /etc/xrpl-monitoring/alloy.env and never echoed. Alphanet pushes to alloy.push_host
# (staging.push.monitoring.xrplf.org): alert thresholds are proved here before prod trusts them.
ALLOY_CRED = $(PYTHON) -c 'import sys,yaml; a=yaml.safe_load(open(sys.argv[1]))["alloy"]; c=a["credentials"].get(sys.argv[2]); print(a["push_host"], c["username"], c["password"]) if c else None' "$(ANSIBLE_CONFIG)"

.PHONY: alloy-deploy alloy-status alloy-logs
alloy-deploy:   ## add [insight]+[perf] and the Alloy sidecar to every node, one at a time
	@[ -f "$(ANSIBLE_CONFIG)" ] || { echo "no $(ANSIBLE_CONFIG) (holds alloy.credentials)"; exit 1; }
	@[ -d "$(ALLOY_SRC)" ] || { echo "no xrpl-monitoring checkout at $(ALLOY_SRC)"; exit 1; }
	@set -- $(NODE_NAMES); names="$$*"; set -- $(VIPS) $(PIPS); ips="$$*"; i=0; \
	 for ip in $$ips; do \
	   i=$$((i+1)); name=$$(echo $$names | cut -d' ' -f$$i); \
	   cred=$$($(ALLOY_CRED) "$$name"); \
	   [ -n "$$cred" ] || { echo "$$name: no alloy.credentials.$$name in $(ANSIBLE_CONFIG); skipped"; continue; }; \
	   host=$$(echo $$cred | awk '{print $$1}'); user=$$(echo $$cred | awk '{print $$2}'); pass=$$(echo $$cred | awk '{print $$3}'); \
	   echo ">> $$name ($$ip) as $$user"; \
	   rsync -az --delete -e "ssh $(SSH_OPTS)" --exclude '.git' $(ALLOY_SRC)/ $(SSH_USER)@$$ip:/opt/xrpl-monitoring/ || { echo "$$name: rsync failed"; continue; }; \
	   scp -q -i $(SSH_KEY) -o IdentitiesOnly=yes -P $(SSH_PORT) infra/observability/alloy-node-setup.sh $(SSH_USER)@$$ip:/tmp/ || { echo "$$name: scp failed"; continue; }; \
	   printf 'ALLOY_PUSH_HOST=%s\nALLOY_USERNAME=%s\nALLOY_PASSWORD=%s\n' "$$host" "$$user" "$$pass" | \
	     ssh $(SSH_OPTS) $(SSH_USER)@$$ip 'mkdir -p /etc/xrpl-monitoring && umask 077 && cat > /etc/xrpl-monitoring/alloy.env'; \
	   ssh $(SSH_OPTS) $(SSH_USER)@$$ip "bash /tmp/alloy-node-setup.sh $$name alphanet-$$name $(STATSD_ADDRESS) $(PERF_PATH)"; \
	 done
alloy-status:   ## per-node Alloy sidecar state
	@for ip in $(VIPS) $(PIPS); do \
	   s=$$(ssh $(SSH_OPTS) -o ConnectTimeout=10 $(SSH_USER)@$$ip \
	        'docker inspect -f "{{.State.Status}}" xrpl-monitoring-alloy 2>/dev/null || echo missing'); \
	   echo "$$ip  alloy=$$s"; \
	 done
alloy-logs:     ## tail one node's Alloy sidecar (make alloy-logs NODE_IP=79.110.60.99)
	@[ -n "$(NODE_IP)" ] || { echo "NODE_IP= required"; exit 1; }
	ssh $(SSH_OPTS) $(SSH_USER)@$(NODE_IP) 'docker logs --tail 60 xrpl-monitoring-alloy'

# --- tests ---------------------------------------------------------------------------
.PHONY: test
test:   ## run the ops unit tests (no network)
	$(PYTHON) -m pytest -q
