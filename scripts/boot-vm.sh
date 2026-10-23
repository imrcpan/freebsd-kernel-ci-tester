#!/usr/bin/env bash
# Download the official FreeBSD VM image, boot it with QEMU and wait for ssh.
#
# Environment:
#   FBSD_RELEASE  base image release, e.g. 14.4 (default 14.4)
#   FBSD_MEM      guest memory in MB (default 6144)
#   FBSD_CPU      guest cpu count (default: host cpu count)
#   FBSD_DISK     guest disk size (default 40G)
#   FBSD_BOOT_TIMEOUT  seconds to wait for ssh (default 600)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

release="${FBSD_RELEASE:-14.4}"
mem="${FBSD_MEM:-6144}"
cpu="${FBSD_CPU:-$(nproc)}"
disk="${FBSD_DISK:-40G}"
timeout_s="${FBSD_BOOT_TIMEOUT:-600}"

mkdir -p "$FBSD_WORKDIR"
cd "$FBSD_WORKDIR"

group "Prepare FreeBSD $release image"
base="https://download.freebsd.org/releases/VM-IMAGES/${release}-RELEASE/amd64/Latest"
name="FreeBSD-${release}-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2"
if [ ! -f "$name" ]; then
  curl -fsSL --retry 5 --retry-delay 5 -o "$name.xz" "$base/$name.xz"
  curl -fsSL --retry 5 --retry-delay 5 -o CHECKSUM.SHA256 "$base/CHECKSUM.SHA256"
  want="$(sed -n "s/^SHA256 ($name.xz) = //p" CHECKSUM.SHA256)"
  have="$(sha256sum "$name.xz" | cut -d' ' -f1)"
  [ -n "$want" ] && [ "$want" = "$have" ] || die "checksum mismatch for $name.xz"
  xz -dc "$name.xz" > "$name"
  rm -f "$name.xz"
fi
cp --reflink=auto "$name" disk.qcow2
qemu-img resize -q disk.qcow2 "$disk"

[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f id_ed25519

# cloud-init (nuageinit) NoCloud seed: authorise our key for root.
mkdir -p seed
cat > seed/meta-data <<META
instance-id: freebsd-vm-$(date +%s)
local-hostname: freebsd-ci
META
cat > seed/user-data <<USER
#cloud-config
users:
  - name: builder
    groups: wheel
    ssh_authorized_keys:
      - $(cat id_ed25519.pub)
write_files:
  # The first-boot freebsd-update fetch blocks sshd for minutes; we never
  # want it in a throw-away CI VM.
  - path: /etc/rc.conf.d/firstboot_freebsd_update
    content: |
      firstboot_freebsd_update_enable="NO"
runcmd:
  - mkdir -p /root/.ssh
  - cp /home/builder/.ssh/authorized_keys /root/.ssh/authorized_keys
  - chmod 700 /root/.ssh
  - chmod 600 /root/.ssh/authorized_keys
  # root is locked in the image; "-w no" makes it key-only instead.
  - pw usermod root -w no
  - echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
  - service sshd restart
USER
genisoimage -quiet -output seed.iso -volid cidata -joliet -rock seed/user-data seed/meta-data
endgroup

accel=tcg
cpu_model=max
if [ -w /dev/kvm ]; then accel=kvm; cpu_model=host; fi
log "starting qemu: accel=$accel cpu=$cpu mem=${mem}M"

rm -f qemu.pid
qemu-system-x86_64 \
  -machine "q35,accel=$accel" -cpu "$cpu_model" -smp "$cpu" -m "$mem" \
  -display none -serial "file:$FBSD_WORKDIR/console.log" -monitor none \
  -drive "file=disk.qcow2,if=virtio,format=qcow2,cache=unsafe" \
  -drive "file=seed.iso,if=virtio,format=raw,media=cdrom,readonly=on" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${FBSD_SSH_PORT}-:22" \
  -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -daemonize -pidfile qemu.pid

group "Waiting for ssh"
start=$(date +%s)
until vm_ssh -o ConnectTimeout=5 true 2>/dev/null; do
  if ! kill -0 "$(cat qemu.pid)" 2>/dev/null; then
    tail -n 50 console.log || true
    die "qemu exited unexpectedly"
  fi
  if [ $(( $(date +%s) - start )) -gt "$timeout_s" ]; then
    tail -n 50 console.log || true
    die "timed out waiting for ssh"
  fi
  sleep 5
done
log "ssh is up after $(( $(date +%s) - start ))s"
vm_ssh 'uname -a; df -h /; sysctl -n hw.ncpu hw.physmem'
endgroup
