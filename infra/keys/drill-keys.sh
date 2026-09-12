#!/bin/bash
# Per-node drill SSH keys: one keypair per node so drill access is handed out and revoked
# one node at a time, and every session is attributable to the key that opened it.
#
#   drill-keys.sh gen                  create any missing keypairs under $SSH_KEY_DIR
#   drill-keys.sh install [node...]    append pubkeys to the nodes' authorized_keys
#   drill-keys.sh verify [node...]     prove each node answers on its own key
#   drill-keys.sh share <node>         print the handout for one node
#   drill-keys.sh revoke <node>        drop that node's drill key from authorized_keys
#   drill-keys.sh list                 show which nodes have a key installed
#
# Reads the env contract (NODE_NAMES/VIPS/PIPS/SSH_*) from the caller's environment, so it
# works on any env whose resolver emits NODE_NAMES and SSH_KEY_DIR.
#
# install/revoke authenticate with the operator break-glass key ($SSH_KEY); the per-node
# keys never touch each other's nodes. A revoke leaves the break-glass key in place.
set -uo pipefail

CMD="${1:-}"; shift 2>/dev/null || true

: "${NODE_NAMES:?run via the Makefile so the env resolver is loaded}"
: "${SSH_KEY_DIR:?env has no SSH_KEY_DIR (per-node keys are not configured)}"
: "${SSH_KEY:?env has no SSH_KEY}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"

KEY_DIR="${SSH_KEY_DIR/#\~/$HOME}"
BREAK_GLASS="${SSH_KEY/#\~/$HOME}"
COMMENT_TAG="xrpl-drill"

read -r -a NAMES <<<"$NODE_NAMES"
read -r -a IPS <<<"${VIPS:-} ${PIPS:-}"

if [ "${#NAMES[@]}" -ne "${#IPS[@]}" ]; then
  echo "inventory mismatch: ${#NAMES[@]} node names vs ${#IPS[@]} IPs" >&2
  exit 1
fi

# node name -> IP
ip_for(){
  local want="$1" i
  for i in "${!NAMES[@]}"; do
    [ "${NAMES[$i]}" = "$want" ] && { echo "${IPS[$i]}"; return 0; }
  done
  echo "unknown node '$want' (have: ${NAMES[*]})" >&2
  return 1
}

# Node list from args, or every node when none given.
selected(){ if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else printf '%s\n' "${NAMES[@]}"; fi; }

key_path(){ echo "$KEY_DIR/$1"; }
key_comment(){ echo "$COMMENT_TAG:$1"; }

remote(){
  local ip="$1"; shift
  ssh -i "$BREAK_GLASS" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 -p "$SSH_PORT" "$SSH_USER@$ip" "$@"
}

cmd_gen(){
  mkdir -p "$KEY_DIR"; chmod 700 "$KEY_DIR"
  local name path
  for name in $(selected "$@"); do
    path="$(key_path "$name")"
    if [ -f "$path" ]; then
      echo "have   $name"
      continue
    fi
    ssh-keygen -q -t ed25519 -N "" -C "$(key_comment "$name")" -f "$path"
    chmod 600 "$path"
    echo "made   $name  $(awk '{print $1, $3}' "$path.pub")"
  done
}

cmd_install(){
  local name ip path pub
  for name in $(selected "$@"); do
    path="$(key_path "$name")"
    [ -f "$path.pub" ] || { echo "SKIP   $name (no key — run 'gen' first)"; continue; }
    ip="$(ip_for "$name")" || continue
    pub="$(cat "$path.pub")"
    # Idempotent: drop any previous line for this node's tag, then append the current one.
    if remote "$ip" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && \
        sed -i '/$(key_comment "$name")\$/d' ~/.ssh/authorized_keys && \
        printf '%s\n' '$pub' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
      echo "ok     $name ($ip)"
    else
      echo "FAILED $name ($ip)"
    fi
  done
}

cmd_verify(){
  local name ip path who
  for name in $(selected "$@"); do
    path="$(key_path "$name")"
    ip="$(ip_for "$name")" || continue
    who=$(ssh -i "$path" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
             -o ConnectTimeout=10 -o BatchMode=yes -p "$SSH_PORT" "$SSH_USER@$ip" \
             'hostname' 2>/dev/null)
    if [ -n "$who" ]; then echo "ok     $name ($ip) -> $who"; else echo "FAILED $name ($ip)"; fi
  done
}

# A drill key must open its own node and nothing else. Proves the keys are actually
# distinct rather than one key copied around.
cmd_isolate(){
  local name path other oip leaked=0
  for name in $(selected "$@"); do
    path="$(key_path "$name")"
    for other in "${!NAMES[@]}"; do
      [ "${NAMES[$other]}" = "$name" ] && continue
      oip="${IPS[$other]}"
      if ssh -i "$path" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
             -o ConnectTimeout=10 -o BatchMode=yes -p "$SSH_PORT" "$SSH_USER@$oip" \
             true 2>/dev/null; then
        echo "LEAK   $name's key opens ${NAMES[$other]} ($oip)"
        leaked=1
      fi
    done
    [ "$leaked" = 0 ] && echo "ok     $name is scoped to its own node"
  done
  return "$leaked"
}

cmd_share(){
  local name="${1:?usage: drill-keys.sh share <node>}"
  local path ip
  path="$(key_path "$name")"
  [ -f "$path" ] || { echo "no key for '$name' — run 'gen' first" >&2; exit 1; }
  ip="$(ip_for "$name")" || exit 1
  cat <<HANDOUT
# Drill access: $name
# Send the key over a private channel (1Password / Signal), never in the incident channel.
host    $ip
port    $SSH_PORT
user    $SSH_USER
connect ssh -i ~/.ssh/$name -p $SSH_PORT $SSH_USER@$ip
rpc     http://$ip:5005
key     $path
# Revoke when the drill closes:  make keys-revoke NODE=$name
HANDOUT
}

cmd_revoke(){
  local name="${1:?usage: drill-keys.sh revoke <node>}"
  local ip
  ip="$(ip_for "$name")" || exit 1
  if remote "$ip" "sed -i '/$(key_comment "$name")\$/d' ~/.ssh/authorized_keys"; then
    echo "revoked $name ($ip) — break-glass key untouched"
  else
    echo "FAILED  $name ($ip)"
  fi
}

cmd_list(){
  local name ip path installed
  printf '%-8s %-16s %-7s %s\n' NODE IP LOCAL INSTALLED
  for name in "${NAMES[@]}"; do
    ip="$(ip_for "$name")"
    path="$(key_path "$name")"
    installed=$(remote "$ip" "grep -c '$(key_comment "$name")\$' ~/.ssh/authorized_keys" 2>/dev/null || echo "?")
    printf '%-8s %-16s %-7s %s\n' "$name" "$ip" \
      "$([ -f "$path" ] && echo yes || echo no)" \
      "$([ "$installed" = "1" ] && echo yes || echo "$installed")"
  done
}

case "$CMD" in
  gen)     cmd_gen "$@" ;;
  install) cmd_install "$@" ;;
  verify)  cmd_verify "$@" ;;
  isolate) cmd_isolate "$@" ;;
  share)   cmd_share "$@" ;;
  revoke)  cmd_revoke "$@" ;;
  list)    cmd_list "$@" ;;
  *) sed -n '2,16p' "$0"; exit 1 ;;
esac
