#!/usr/bin/env bash
# Common helpers shared by the scripts of this action.

: "${FBSD_WORKDIR:=${RUNNER_TEMP:-/tmp}/freebsd-vm}"
export FBSD_WORKDIR
FBSD_SSH_PORT="${FBSD_SSH_PORT:-2222}"

log() { echo "[freebsd-vm] $*"; }
die() { echo "::error::[freebsd-vm] $*" >&2; exit 1; }

group() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$*"; else log "== $* =="; fi; }
endgroup() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }

# Options shared by ssh and scp. No host key checking: the VM is throw-away
# and only reachable through the loopback forward.
FBSD_SSH_OPTS=(
  -i "$FBSD_WORKDIR/id_ed25519"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=20
  -o BatchMode=yes
)

vm_ssh() { ssh "${FBSD_SSH_OPTS[@]}" -p "$FBSD_SSH_PORT" root@127.0.0.1 "$@"; }
vm_scp() { scp "${FBSD_SSH_OPTS[@]}" -P "$FBSD_SSH_PORT" "$@"; }

# wait_ssh <timeout-seconds>: block until the VM accepts ssh logins.
wait_ssh() {
  local limit="$1" start
  start=$(date +%s)
  until vm_ssh -o ConnectTimeout=5 true 2>/dev/null; do
    if ! kill -0 "$(cat "$FBSD_WORKDIR/qemu.pid")" 2>/dev/null; then
      tail -n 50 "$FBSD_WORKDIR/console.log" || true
      die "qemu exited unexpectedly"
    fi
    if [ $(( $(date +%s) - start )) -gt "$limit" ]; then
      tail -n 50 "$FBSD_WORKDIR/console.log" || true
      die "timed out waiting for ssh"
    fi
    sleep 5
  done
  log "ssh is up after $(( $(date +%s) - start ))s"
}
