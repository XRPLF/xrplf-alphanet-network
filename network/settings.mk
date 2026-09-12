# Alphanet build and deploy settings. One network, so every value is a plain assignment;
# override on the command line only when the change is deliberate.

# Where builds RUN. The xrpl.foundation org policy (iam.managed.disableServiceAccountCreation)
# blocks Cloud Build from provisioning its service account in a fresh project, so builds run in
# the perf project, which owns the worker pool.
PROJECT ?= xrplf-perf-network
# Private Cloud Build worker pool in PROJECT. POOL= (empty) falls back to the default pool.
POOL    ?= xrpld-pool
# Where images LIVE: the alphanet project, not the build project, so the artifacts outlive the
# perf project's lifecycle and budget. `AR` collides with make's built-in archiver variable
# (=ar), so it is only assigned when nothing else set it.
ifeq ($(origin AR),default)
AR = us-central1-docker.pkg.dev/xrplf-alphanet/xrpld
endif

# Compile every amendment as Supported::Yes. The chain has amendments enabled that a branch may
# not mark supported, and an unsupported enabled amendment amendment-blocks the node at startup.
FORCE_SUPPORTED ?= ON
# No DatagramMonitor merge: the composed branch ships as-is, with no perf instrumentation.
DATAGRAM        ?=
# No amendment macro at deploy: the amendment set comes from the composed branch.
FEATURES_FILE   ?=
# 1 = pre-enable every amendment in genesis (the binary is built with FORCE_SUPPORTED=ON, so
# every amendment is supported). Genesis only; a rolling deploy never touches the amendment set.
ALL_AMENDMENTS  ?= 1
# No prefunded genesis: xrpld-lab's bundled genesis plus the faucet.
GENESIS_FILE    ?=
# online_delete ledger count; xrpld-lab's default and what the live nodes already run.
ONLINE_DELETE   ?= 10000
# 0 = [node_size] preset (huge on the 47GB boxes) plus the RAM guardrail; no fixed tree cache.
TREE_CACHE_TARGET_ENTRIES ?= 0
# Node log level.
LOG_LEVEL       ?= warning
# NetworkID. 24100-24107 is reserved for XRPLF networks (24100 alphanet, 24101/24102 the future
# dev/test rungs). Changing it needs a genesis reset, so it takes effect only on genesis-deploy.
NETWORK_ID      ?= 24100
# [database_path] (SQLite). The path the running nodes already use; changing it strands their
# relational db.
DATABASE_PATH   ?= /opt/ripple/lib/db
# [insight] StatsD sink and [perf] log read by the Alloy sidecar. The sidecar joins the node
# container's network namespace, so both ends of the StatsD hop are this loopback address.
STATSD_ADDRESS  ?= 127.0.0.1:9125
PERF_PATH       ?= /opt/ripple/log/perf.log
# 1 = emit the static [validators] list alongside the publisher list, so a fresh chain reaches
# quorum before the VL site serves. Drop it once every node fetches the VL.
BOOTSTRAP_VL    ?=

# xrpld-lab cluster name: $(WORKSPACE)/$(CLUSTER)-cluster holds the keystore (VL publisher key
# plus validator keys) that is the network's identity.
CLUSTER   ?= xrpld-alphanet
# Workspace root for xrpld-builder (tree, manifest, build record) and xrpld-lab (cluster dir).
# Point it at the canonical workspace holding the live keystore; a fresh workspace has no
# keystore and xrpld-lab refuses a non-genesis deploy without one.
WORKSPACE ?= workspace
# Topology + services YAML for xrpld-lab create:ansible; carries the faucet seed, gitignored.
ANSIBLE_CONFIG ?= network/ansible.yml
# Checkout of peersyst/xrpl-monitoring, the Alloy image build context.
ALLOY_SRC ?= ../xrpl-monitoring

# `make build` writes IMAGE, BUILD_SERVER and BUILD_VERSION here; cluster and deploy read them
# back so nothing is copied by hand. Pass IMAGE=/BUILD_SERVER=/BUILD_VERSION= to override.
LAST_BUILD := .last-build.env
-include $(LAST_BUILD)
