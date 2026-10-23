#!/usr/bin/env bash
# Stop the VM. With --dump, print the tail of the serial console first.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

if [ "${1:-}" = "--dump" ]; then
  group "VM console (last 200 lines)"
  tail -n 200 "$FBSD_WORKDIR/console.log" 2>/dev/null || true
  endgroup
  exit 0
fi

pidfile="$FBSD_WORKDIR/qemu.pid"
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
  vm_ssh 'shutdown -p now' >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do kill -0 "$(cat "$pidfile")" 2>/dev/null || exit 0; sleep 1; done
  kill "$(cat "$pidfile")" 2>/dev/null || true
fi
exit 0
