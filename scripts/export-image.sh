#!/usr/bin/env bash
# Shut the VM down cleanly and pack its disk and ssh key into a bundle that
# boot-vm.sh can start later (FBSD_IMAGE=<bundle>), e.g. in another job.
# The bundle is meant to be handed over as a short-lived artifact.
#
# usage: export-image.sh <bundle.tar.zst>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

out="${1:?usage: export-image.sh <bundle.tar.zst>}"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

group "Export VM image"
# Drop the build objects and zero the free space, so that the qcow2
# conversion below can leave it out and the bundle stays small.
vm_ssh 'rm -rf /usr/obj; sync; dd if=/dev/zero of=/zero.fill bs=1m 2>/dev/null || true; sync; rm -f /zero.fill; sync'
vm_ssh 'shutdown -p now' >/dev/null 2>&1 || true
pid="$(cat "$FBSD_WORKDIR/qemu.pid")"
for _ in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$pid" 2>/dev/null; then die "VM did not power off"; fi

cd "$FBSD_WORKDIR"
qemu-img convert -O qcow2 disk.qcow2 export.qcow2
mkdir -p export
mv export.qcow2 export/disk.qcow2
cp id_ed25519 id_ed25519.pub export/
mkdir -p "$(dirname "$out")"
tar -C export -c -f - disk.qcow2 id_ed25519 id_ed25519.pub | zstd -T0 -3 -q -f -o "$out"
rm -rf export
ls -la "$out"
endgroup
