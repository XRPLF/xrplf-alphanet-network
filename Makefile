# Alphanet: build, deploy and operate the Foundation's live public XRPL staging network.
# Build and compose come from the multibranch-builder CLI; cluster generation and deploy from xrpld-lab.
# This Makefile knows one network, so a chain reset is never the default: `deploy` always passes
# --genesis 0 and only `genesis-deploy CONFIRM_GENESIS=alphanet` passes --genesis 1.

include network/settings.mk

# The checkout's virtualenv holds multibranch-builder and the ops dependencies. Both are named by
# absolute path so recipes work from a shell that has not activated it.
VENV_BIN  := $(CURDIR)/.venv/bin
BUILDER   := $(if $(wildcard $(VENV_BIN)/multibranch-builder),$(VENV_BIN)/multibranch-builder,multibranch-builder)
PYTHON    ?= $(if $(wildcard $(VENV_BIN)/python3),$(VENV_BIN)/python3,python3)
INVENTORY := network/inventory
# Which conf compose/build/push act on. alphanet.conf composes the xrpld tree the network runs;
# another conf composes and pushes its own integration branch but never deploys here.
CONF       ?= alphanet.conf
XRPLD_CONF := alphanet.conf
# Every conf the status page lists, so a developer sees the chain's branches and the SDK's.
STATUS_CONFS := alphanet.conf xrpljs.conf
# One build directory per conf: manifest.json and build.json are written at its root.
BUILD_DIR  := $(WORKSPACE)/$(basename $(notdir $(CONF)))

# Node inventory, read from network/inventory.
VIPS       := $(shell awk '$$1=="VALIDATOR"{print $$2}' $(INVENTORY))
PIPS       := $(shell awk '$$1=="PEER"{print $$2}' $(INVENTORY))
NODE_NAMES := $(shell awk '$$1=="VALIDATOR"||$$1=="PEER"{print $$3}' $(INVENTORY))
SSH_KEY     := $(shell awk '$$1=="SSH_KEY"{print $$2}' $(INVENTORY))
SSH_KEY_DIR := $(shell awk '$$1=="SSH_KEY_DIR"{print $$2}' $(INVENTORY))
SSH_PORT    := $(shell awk '$$1=="SSH_PORT"{print $$2}' $(INVENTORY))
SSH_USER    := $(shell awk '$$1=="SSH_USER"{print $$2}' $(INVENTORY))
VL_SITE     := $(shell awk '$$1=="VL_SITE"{print $$2}' $(INVENTORY))

# Integration branch of $(CONF), where `push` sends that conf's composed tree.
TARGET_REPO   := $(shell awk '$$1=="target"{print $$2}' $(CONF))
TARGET_BRANCH := $(shell awk '$$1=="target"{print $$3}' $(CONF))
# xrpld-lab fetches the feature list from BUILD_SERVER at BUILD_VERSION, so the composed xrpld
# tree must be pushed to the xrpld conf's target before deploy.
BUILD_SERVER  ?= https://github.com/$(shell awk '$$1=="target"{print $$2}' $(XRPLD_CONF))/tree/$(shell awk '$$1=="target"{print $$3}' $(XRPLD_CONF))

# The xrpld kind takes force_supported; other kinds take no options.
ifeq ($(CONF),$(XRPLD_CONF))
BUILDER_OPTS ?= --set force_supported=$(FORCE_SUPPORTED)
else
BUILDER_OPTS ?=
endif

TREE     := $(WORKSPACE)/$(basename $(notdir $(XRPLD_CONF)))/rippled
MANIFEST := $(BUILD_DIR)/manifest.json
BUILD_JSON := $(BUILD_DIR)/build.json
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
discover:   ## show which branches $(CONF) resolves to, without writing the tree
	@command -v $(BUILDER) >/dev/null || { echo "multibranch-builder not found; run: python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'"; exit 1; }
	$(BUILDER) compose --conf $(CONF) --workdir $(BUILD_DIR) $(BUILDER_OPTS) --dry-run

compose:    ## merge the $(CONF) branches into $(BUILD_DIR) and write manifest.json
	@command -v $(BUILDER) >/dev/null || { echo "multibranch-builder not found; run: python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'"; exit 1; }
	$(BUILDER) compose --conf $(CONF) --workdir $(BUILD_DIR) $(BUILDER_OPTS)

build:      ## build the composed tree; for the xrpld conf also write .last-build.env (then `make push`)
	@command -v $(BUILDER) >/dev/null || { echo "multibranch-builder not found; run: python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'"; exit 1; }
	@[ -f "$(MANIFEST)" ] || { echo "no manifest at $(MANIFEST); run 'make compose' first"; exit 1; }
	@image=$$($(BUILDER) build --workdir $(BUILD_DIR) --project $(PROJECT) --ar $(AR) \
	    $(if $(TAG),--tag $(TAG)) $(if $(strip $(POOL)),--pool $(POOL)) \
	    $(BUILDER_OPTS) | tee /dev/stderr | tail -1); \
	 [ -n "$$image" ] || { echo "BUILD FAILED: see the multibranch-builder error above and $(BUILD_JSON)"; exit 1; }; \
	 if [ "$(CONF)" = "$(XRPLD_CONF)" ]; then \
	   sha=$$($(PYTHON) -c 'import json;print(json.load(open("$(BUILD_JSON)"))["composed_sha"])'); \
	   printf 'IMAGE=%s\nBUILD_SERVER=%s\nBUILD_VERSION=%s\n' "$$image" "$(BUILD_SERVER)" "$$sha" > $(LAST_BUILD); \
	   echo "wrote $(LAST_BUILD): IMAGE=$$image BUILD_VERSION=$$sha"; \
	 else \
	   echo "built $(CONF): $$image"; \
	 fi

push:       ## GPG-signed push of $(CONF)'s composed tree to $(TARGET_REPO)@$(TARGET_BRANCH); needs GITHUB_BOT_PAT and GIT_SIGNING_KEY
	@command -v $(BUILDER) >/dev/null || { echo "multibranch-builder not found; run: python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'"; exit 1; }
	$(BUILDER) push --workdir $(BUILD_DIR) --target $(TARGET_REPO)@$(TARGET_BRANCH)

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
	  $(if $(FEATURES_FILE),--features_file $(FEATURES_FILE),$(if $(wildcard $(TREE)/include/xrpl/protocol/detail/features.macro),--features_file $(TREE)/include/xrpl/protocol/detail/features.macro)) \
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
	$(MAKE) status-publish

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
	$(MAKE) status-publish

# --- health, faucet, deploy history --------------------------------------------------
.PHONY: health faucet-fund faucet-verify record-deploy status status-publish
health:   ## server_info on every node's admin port; validators must be proposing, peers full
	$(PYTHON) -m ops.health --inventory $(INVENTORY)

faucet-fund:   ## pay the genesis balance to the faucet account (seed from $(ANSIBLE_CONFIG), never printed)
	$(PYTHON) -m ops.faucet fund --inventory $(INVENTORY) --ansible-config $(ANSIBLE_CONFIG)

faucet-verify:   ## check the faucet account balance is above the minimum
	$(PYTHON) -m ops.faucet verify --inventory $(INVENTORY) --ansible-config $(ANSIBLE_CONFIG)

record-deploy:   ## append {sha, image, genesis, date, operator} to data/deploys.json
	$(PYTHON) -m ops.record_deploy --sha "$(BUILD_VERSION)" --image "$(IMAGE)" --genesis $(GENESIS) --operator "$(USER)"

# The status page (xrpld-lab `status` service) reads /opt/xrpld-status/network.json on the
# services host, the first PEER in the inventory.
STATUS_HOST := $(firstword $(PIPS))
status-publish:   ## render network.json (last deploy, pinned branches, faucet, VL, amendments) and copy it to the services host
	$(PYTHON) -m ops.status_publish --inventory $(INVENTORY) $(foreach c,$(STATUS_CONFS),--conf $(c)) --deploys data/deploys.json \
	  $(if $(wildcard $(ANSIBLE_CONFIG)),--ansible-config $(ANSIBLE_CONFIG)) --out $(WORKSPACE)/network.json
	scp -q -i $(SSH_KEY) -o IdentitiesOnly=yes -P $(SSH_PORT) $(WORKSPACE)/network.json $(SSH_USER)@$(STATUS_HOST):/opt/xrpld-status/network.json

status:   ## print the inventory and the last recorded deploy
	@echo "validators: $(VIPS)"; echo "peers:      $(PIPS)"; echo "nodes:      $(NODE_NAMES)"
	@echo "ssh:        $(SSH_USER)@:$(SSH_PORT) key=$(SSH_KEY) drill keys=$(SSH_KEY_DIR)"
	@echo "vl_site:    $(VL_SITE)"; echo "network_id: $(NETWORK_ID) (settings.mk; takes effect at genesis)"
	@echo "cluster:    $(WORKSPACE)/$(CLUSTER)-cluster"; echo "ansible:    $(ANSIBLE_CONFIG)"
	@echo "last build: IMAGE=$(IMAGE) BUILD_VERSION=$(BUILD_VERSION)"
	@$(PYTHON) -m ops.record_deploy --show-last

# --- keystore backup ------------------------------------------------------------------
# The keystore is the network's identity and exists in exactly one directory; Secret Manager
# in the alphanet GCP project holds the copy. Secret payloads are streamed, never printed.
KEYSTORE_DIR     := $(WORKSPACE)/$(CLUSTER)-cluster/keystore
SECRETS_PROJECT  ?= xrplf-alphanet
.PHONY: keystore-backup keystore-restore
keystore-backup:   ## copy the keystore tarball and network/ansible.yml into Secret Manager ($(SECRETS_PROJECT))
	@[ -d "$(KEYSTORE_DIR)" ] || { echo "no keystore at $(KEYSTORE_DIR)"; exit 1; }
	@[ -f "$(ANSIBLE_CONFIG)" ] || { echo "no $(ANSIBLE_CONFIG)"; exit 1; }
	@for name in alphanet-keystore alphanet-ansible-yml; do \
	   gcloud secrets describe $$name --project $(SECRETS_PROJECT) >/dev/null 2>&1 || \
	     gcloud secrets create $$name --project $(SECRETS_PROJECT) --replication-policy automatic >/dev/null; done
	@tar -C $(dir $(KEYSTORE_DIR)) -czf - keystore | gcloud secrets versions add alphanet-keystore --project $(SECRETS_PROJECT) --data-file=- >/dev/null
	@gcloud secrets versions add alphanet-ansible-yml --project $(SECRETS_PROJECT) --data-file=$(ANSIBLE_CONFIG) >/dev/null
	@echo "backed up $(KEYSTORE_DIR) and $(ANSIBLE_CONFIG) to Secret Manager in $(SECRETS_PROJECT)"

keystore-restore:   ## write the keystore and network/ansible.yml back from Secret Manager; refuses to overwrite a keystore
	@[ ! -d "$(KEYSTORE_DIR)" ] || { echo "REFUSED: $(KEYSTORE_DIR) exists; move it away first"; exit 1; }
	@mkdir -p $(dir $(KEYSTORE_DIR)) && umask 077 && \
	 gcloud secrets versions access latest --secret alphanet-keystore --project $(SECRETS_PROJECT) | tar -C $(dir $(KEYSTORE_DIR)) -xzf - && \
	 gcloud secrets versions access latest --secret alphanet-ansible-yml --project $(SECRETS_PROJECT) > $(ANSIBLE_CONFIG) && chmod 600 $(ANSIBLE_CONFIG)
	@echo "restored $(KEYSTORE_DIR) and $(ANSIBLE_CONFIG)"

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
