#!/bin/bash
# Provision one node for xrpl-monitoring: add the telemetry stanzas rippled needs, then run
# Grafana Alloy as a sidecar in the node container's network namespace.
#
#   alloy-node-setup.sh <container> <node_label> [statsd_addr] [perf_path]
#
# Credentials come from /etc/xrpl-monitoring/alloy.env (mode 0600), written by the driver so
# they never appear in an argument list or this script's output.
#
# Sharing the node's netns is what makes [insight] address=127.0.0.1:<port> correct: rippled
# and Alloy see the same loopback, so no UDP port is published to the host or the world.
set -uo pipefail

CONTAINER="${1:?container name}"
NODE_LABEL="${2:?node label}"
STATSD_ADDR="${3:-127.0.0.1:9125}"
PERF_PATH="${4:-/opt/ripple/log/perf.log}"

CFG=/opt/ripple/config/xrpld.cfg
LOG_DIR=/opt/ripple/log
ENV_FILE=/etc/xrpl-monitoring/alloy.env
PASSWORD_FILE=/etc/xrpl-monitoring/alloy.password
BUILD_CTX=/opt/xrpl-monitoring
ALLOY_NAME=xrpl-monitoring-alloy
ALLOY_IMAGE=xrpl-monitoring-alloy:local
STATSD_PORT="${STATSD_ADDR##*:}"

say(){ echo "${NODE_LABEL}: $*"; }
die(){ echo "${NODE_LABEL}: ERROR $*" >&2; exit 1; }

[ -f "$CFG" ] || die "no config at $CFG"
[ -f "$ENV_FILE" ] || die "no credentials at $ENV_FILE"
[ -d "$BUILD_CTX" ] || die "no Alloy build context at $BUILD_CTX"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container $CONTAINER not found"

# The node must read the bind-mounted config, or a host-side edit is invisible to it and the
# restart below would be pure downtime.
if ! docker inspect -f '{{.Config.Entrypoint}}' "$CONTAINER" >/dev/null 2>&1; then
  die "cannot inspect $CONTAINER"
fi
if ! docker exec "$CONTAINER" sh -c "grep -q -- '--conf $CFG' /entrypoint.sh" 2>/dev/null; then
  die "$CONTAINER does not read $CFG (its config is baked into the image) — regenerate with
       xrpld-lab --statsd_address/--perf_path instead of patching the host file"
fi

# --- 1. telemetry stanzas (idempotent) ---------------------------------------------
changed=0
add_section(){
  local marker="$1" block="$2"
  if grep -q "^\[${marker}\]" "$CFG"; then
    say "[$marker] already present"
    return
  fi
  [ "$changed" = 0 ] && cp -a "$CFG" "$CFG.bak.$(date +%s)"
  printf '\n%s\n' "$block" >> "$CFG"
  changed=1
  say "[$marker] added"
}

add_section insight "$(printf '[insight]\nserver=statsd\naddress=%s\nprefix=alphanet.%s\n' \
  "$STATSD_ADDR" "$CONTAINER")"
add_section perf "$(printf '[perf]\nperf_log=%s\nlog_interval=2\n' "$PERF_PATH")"

# --- 2. restart the node only if its config actually changed -----------------------
if [ "$changed" = 1 ]; then
  say "restarting $CONTAINER to load the new stanzas"
  docker restart "$CONTAINER" >/dev/null || die "restart failed"
  for _ in $(seq 1 60); do
    state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)
    [ "$state" = "running" ] && break
    sleep 2
  done
  [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER")" = "running" ] \
    || die "$CONTAINER did not come back up"
  # Rejoin consensus before the caller moves to the next node: on a 6-validator UNL the
  # quorum is 5, so two nodes out at once halts the chain.
  server_state=""
  for _ in $(seq 1 90); do
    server_state=$(docker exec "$CONTAINER" /opt/xrpld/bin/xrpld \
      --conf "$CFG" server_info 2>/dev/null \
      | sed -n 's/.*"server_state"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1)
    case "$server_state" in
      proposing|full|validating) break ;;
    esac
    sleep 2
  done
  say "server_state=${server_state:-unknown}"
  case "$server_state" in
    proposing|full|validating) ;;
    *) die "$CONTAINER did not rejoin consensus (server_state=${server_state:-unknown}) — \
fix this node before provisioning the next" ;;
  esac
  # perf.log only appears once the node has served a log_interval.
  for _ in $(seq 1 60); do
    [ -f "$PERF_PATH" ] && break
    sleep 2
  done
fi

[ -f "$PERF_PATH" ] || say "WARN $PERF_PATH still missing — Alloy preflight will retry"

# --- 3. build the Alloy image -----------------------------------------------------
say "building $ALLOY_IMAGE"
docker build -q -f "$BUILD_CTX/docker/alloy.Dockerfile" -t "$ALLOY_IMAGE" "$BUILD_CTX" \
  >/dev/null 2>&1 || die "alloy image build failed"

# --- 4. run the sidecar in the node's network namespace ---------------------------
docker rm -f "$ALLOY_NAME" >/dev/null 2>&1 || true
docker run -d --name "$ALLOY_NAME" --restart always \
  --network "container:${CONTAINER}" \
  --env-file "$ENV_FILE" \
  --mount type=bind,src="$PASSWORD_FILE",dst=/run/secrets/xrpl_monitoring_password,readonly \
  -e ALLOY_NODE="$NODE_LABEL" \
  -e ALLOY_STATSD_LISTEN="127.0.0.1:${STATSD_PORT}" \
  -e ALLOY_XRPLD_STATSD_ADDRESS="127.0.0.1:${STATSD_PORT}" \
  -v "$CFG:/xrpld-config/xrpld.cfg:ro" \
  -v "$LOG_DIR:/xrpld-logs:ro" \
  -v "alloy-data-${CONTAINER}:/var/lib/alloy/data" \
  "$ALLOY_IMAGE" run --server.http.listen-addr=127.0.0.1:12345 \
  --storage.path=/var/lib/alloy/data /etc/alloy/config.alloy >/dev/null \
  || die "alloy run failed"

sleep 6
state=$(docker inspect -f '{{.State.Status}}' "$ALLOY_NAME" 2>/dev/null || echo missing)
say "alloy=$state node=$(docker inspect -f '{{.State.Status}}' "$CONTAINER")"
if [ "$state" != "running" ]; then
  docker logs "$ALLOY_NAME" 2>&1 | grep -aiE 'error|preflight|fail' | tail -5
  exit 1
fi
docker logs "$ALLOY_NAME" 2>&1 | grep -aiE 'preflight' | tail -4
