#!/usr/bin/env bash
# Build a FreeBSD source tree inside the VM, install it, reboot into it and
# run the user supplied command. The VM must already be up (boot-vm.sh).
#
# Environment (all optional unless noted):
#   SKIP_WORLD    "true": build and install only the kernel (default false)
#   SRC_REPO  SRC_BRANCH  SRC_DIR  KERNCONF  JOBS
#   BUILD_CMD     build command, run in SRC_DIR
#   INSTALL_CMD   install command, run in SRC_DIR; empty = do not install
#   INSTALL_CMD_INPUT  like INSTALL_CMD but empty = default, "none" = skip
#   REBOOT        "true" to reboot after INSTALL_CMD (default true)
#   SRC_REPO empty: nothing is built or installed, only RUN_CMD/RUN_FILE run
#   SYNC_DIR      host directory copied (one way) into the VM before run; run starts there
#   SYNC_DEST     where it lands in the VM (default /root/work)
#   RUN_FILE      host path of a script copied into the VM and run (before RUN_CMD)
#   RUN_CMD       script run in the VM after build/install
#   PASS_ENVS     whitespace separated names of host envs to pass to the VM
#   BUILD_TIMEOUT seconds allowed for the build (default 21600)
#   BUILD_VERBOSE "true": stream the whole build output (log viewers truncate it)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

SRC_REPO="${SRC_REPO:-}"
SRC_DIR="${SRC_DIR:-/usr/src}"
KERNCONF="${KERNCONF:-GENERIC}"
JOBS="${JOBS:-}"
SKIP_WORLD="${SKIP_WORLD:-false}"
REBOOT="${REBOOT:-true}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-21600}"
# INSTALL_CMD_INPUT is what the action passes: empty = default, "none" = skip.
if [ "$SKIP_WORLD" = true ]; then
  default_install='make installkernel KERNCONF=${KERNCONF}'
else
  default_install='make installkernel installworld KERNCONF=${KERNCONF} && etcupdate -B || true'
fi
case "${INSTALL_CMD_INPUT-__unset__}" in
  __unset__) INSTALL_CMD="${INSTALL_CMD-$default_install}" ;;
  "")        INSTALL_CMD="$default_install" ;;
  none)      INSTALL_CMD="" ;;
  *)         INSTALL_CMD="$INSTALL_CMD_INPUT" ;;
esac

# Quote a value for safe use inside a POSIX sh script.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Environment file shared by all the guest scripts.
envfile="$FBSD_WORKDIR/guest.env"
{
  echo "export SRC_REPO=$(shq "$SRC_REPO")"
  echo "export SRC_DIR=$(shq "$SRC_DIR")"
  echo "export KERNCONF=$(shq "$KERNCONF")"
  echo "export SKIP_WORLD=$(shq "$SKIP_WORLD")"
  echo "export BUILD_VERBOSE=$(shq "${BUILD_VERBOSE:-false}")"
  [ -z "${SRC_BRANCH:-}" ] || echo "export SRC_BRANCH=$(shq "$SRC_BRANCH")"
  [ -z "$JOBS" ] || echo "export JOBS=$(shq "$JOBS")"
  [ -z "${BUILD_CMD:-}" ] || echo "export BUILD_CMD=$(shq "$BUILD_CMD")"
  for n in ${PASS_ENVS:-}; do
    case "$n" in *[!A-Za-z0-9_]*|"") die "invalid env name: $n" ;; esac
    echo "export $n=$(shq "${!n-}")"
  done
} > "$envfile"

guest_exec() { # guest_exec <local-script> [timeout]
  local script="$1" limit="${2:-0}" remote="/tmp/$(basename "$1")"
  vm_scp -q "$script" "$envfile" "root@127.0.0.1:/tmp/" >/dev/null
  local pre=""
  [ "$limit" = 0 ] || pre="timeout $limit "
  vm_ssh "set -e; . /tmp/$(basename "$envfile"); ${pre}sh $remote"
}

if [ -n "$SRC_REPO" ]; then
group "Fetch and build the source tree"
build_rc=0
guest_exec "$here/guest-build.sh" "$BUILD_TIMEOUT" || build_rc=$?
# keep the full build output on the runner; the action uploads it
vm_scp -q "root@127.0.0.1:/var/tmp/build.log" "$FBSD_WORKDIR/build.log" 2>/dev/null || true
endgroup
[ "$build_rc" -eq 0 ] || die "build failed (exit $build_rc), see $FBSD_WORKDIR/build.log"
else
  INSTALL_CMD=""
fi

if [ -n "$INSTALL_CMD" ]; then
  group "Install the build"
  inst="$FBSD_WORKDIR/guest-install.sh"
  # A snapshot image is installed from pkgbase packages and make refuses to
  # install over it unless told that this is intended (the VM is throw-away).
  {
    echo 'export ALLOW_PKGBASE_INSTALLKERNEL=yes ALLOW_PKGBASE_INSTALLWORLD=yes'
    printf 'cd %s\n%s\n' "$(shq "$SRC_DIR")" "$INSTALL_CMD"
  } > "$inst"
  guest_exec "$inst"
  if [ "$REBOOT" = true ]; then
    log "rebooting into the new build"
    vm_ssh 'nohup sh -c "sleep 1; shutdown -r now" >/dev/null 2>&1 &' || true
    # wait for the old instance to go away, then for the new one
    for _ in $(seq 1 60); do vm_ssh -o ConnectTimeout=3 true 2>/dev/null || break; sleep 2; done
    wait_ssh 900
  fi
  endgroup
fi

group "System under test"
vm_ssh 'uname -a'
endgroup

# Push the runner directory SYNC_DIR (one way, host -> VM) to SYNC_DEST in the
# VM. tar over ssh: the stock image has neither rsync nor extra tools.
RUN_DIR=""
if [ -n "${SYNC_DIR:-}" ]; then
  [ -d "$SYNC_DIR" ] || die "sync-dir not found: $SYNC_DIR"
  SYNC_DEST="${SYNC_DEST:-/root/work}"
  group "Copy $SYNC_DIR to the VM:$SYNC_DEST"
  vm_ssh "rm -rf $(shq "$SYNC_DEST") && mkdir -p $(shq "$SYNC_DEST")"
  tar -C "$SYNC_DIR" -cf - . | vm_ssh "tar -C $(shq "$SYNC_DEST") -xpf -"
  RUN_DIR="$SYNC_DEST"
  endgroup
fi

# Run a user script in the VM, from the synced directory, else the source tree.
run_user_script() { # run_user_script <host-script-path>
  local wrapped="$FBSD_WORKDIR/guest-run-$(basename "$1")"
  { printf 'cd %s 2>/dev/null || cd /
' "$(shq "${RUN_DIR:-$SRC_DIR}")"; cat "$1"; } > "$wrapped"
  guest_exec "$wrapped"
}

if [ -n "${RUN_FILE:-}" ]; then
  [ -f "$RUN_FILE" ] || die "run-file not found: $RUN_FILE"
  group "Run $RUN_FILE"
  run_user_script "$RUN_FILE"
  endgroup
fi

if [ -n "${RUN_CMD:-}" ]; then
  group "Run"
  printf '%s\n' "$RUN_CMD" > "$FBSD_WORKDIR/run-cmd.sh"
  run_user_script "$FBSD_WORKDIR/run-cmd.sh"
  endgroup
fi
