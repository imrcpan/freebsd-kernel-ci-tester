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
    # qemu writes its pidfile only after daemonizing: no file yet is not a death.
    if [ -s "$FBSD_WORKDIR/qemu.pid" ] && ! kill -0 "$(cat "$FBSD_WORKDIR/qemu.pid")" 2>/dev/null; then
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

# detect_base_release <repo> <ref>: print the official image that carries the
# latest prebuilt world for that source tree: "16.0-CURRENT", "15.1-STABLE" or
# a plain release such as "14.4". Reads sys/conf/newvers.sh with a blobless
# shallow fetch, so no full checkout is needed.
detect_base_release() {
  local repo="$1" ref="${2:-HEAD}" tmp rev branch
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  git -C "$tmp" remote add origin "$repo"
  git -C "$tmp" fetch -q --depth 1 --filter=blob:none origin "$ref" >&2 \
    || git -C "$tmp" fetch -q --depth 1 origin "$ref" >&2 \
    || { rm -rf "$tmp"; die "cannot fetch $repo $ref"; }
  local vers
  vers="$(git -C "$tmp" show FETCH_HEAD:sys/conf/newvers.sh)" || { rm -rf "$tmp"; die "no sys/conf/newvers.sh in $repo $ref"; }
  rm -rf "$tmp"
  rev="$(printf '%s\n' "$vers" | sed -n 's/^REVISION="\(.*\)"/\1/p' | head -n1)"
  branch="$(printf '%s\n' "$vers" | sed -n 's/^BRANCH="\(.*\)"/\1/p' | head -n1)"
  [ -n "$rev" ] && [ -n "$branch" ] || die "cannot parse REVISION/BRANCH from newvers.sh"
  case "$branch" in
    CURRENT|STABLE) echo "$rev-$branch" ;;
    RELEASE*)       echo "$rev" ;;
    *)
      # ALPHA/BETA/RC/PRERELEASE of a stable branch: the snapshot directory is
      # named after the previous release (stable/15 at 15.2-PRERELEASE is
      # published as 15.1-STABLE), so look it up by major version.
      local snap
      snap="$(curl -fsSL --retry 3 https://download.freebsd.org/snapshots/VM-IMAGES/ \
        | grep -o "href=\"${rev%%.*}\.[0-9]*-STABLE/\"" | sed 's/href="//;s#/"##' | sort -V | tail -n1)" || true
      echo "${snap:-$rev}" ;;
  esac
}
