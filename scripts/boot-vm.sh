#!/usr/bin/env bash
# Download the official FreeBSD VM image, boot it with QEMU and wait for ssh.
#
# Environment:
#   FBSD_RELEASE  base image: a release (14.4) or a snapshot branch
#                 (16.0-CURRENT, 15.1-STABLE). Empty: with SKIP_WORLD=true it is
#                 detected from SRC_REPO/SRC_BRANCH, otherwise 14.4.
#   SKIP_WORLD    "true": the base image's prebuilt world is used as is
#   FBSD_MEM      guest memory in MB (default 6144)
#   FBSD_CPU      guest cpu count (default: host cpu count)
#   FBSD_DISK     guest disk size (default 40G)
#   FBSD_BOOT_TIMEOUT  seconds to wait for ssh (default 1800)
#   FBSD_IMAGE    bundle written by export-image.sh; boot it instead of a stock image
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

release="${FBSD_RELEASE:-}"
if [ -z "$release" ] && [ "${SKIP_WORLD:-false}" = true ] && [ -n "${SRC_REPO:-}" ] && [ -z "${FBSD_IMAGE:-}" ]; then
  release="$(detect_base_release "$SRC_REPO" "${SRC_BRANCH:-HEAD}")"
  log "source tree is $release, using the latest prebuilt world of that branch"
fi
release="${release:-14.4}"
mem="${FBSD_MEM:-6144}"
cpu="${FBSD_CPU:-$(nproc)}"
disk="${FBSD_DISK:-40G}"
timeout_s="${FBSD_BOOT_TIMEOUT:-1800}"

mkdir -p "$FBSD_WORKDIR"
cd "$FBSD_WORKDIR"

if [ -n "${FBSD_IMAGE:-}" ]; then
group "Unpack image bundle $FBSD_IMAGE"
[ -f "$FBSD_IMAGE" ] || die "no such image bundle: $FBSD_IMAGE"
zstd -dc "$FBSD_IMAGE" | tar -x -f - disk.qcow2 id_ed25519 id_ed25519.pub
chmod 600 id_ed25519
qemu-img resize -q disk.qcow2 "$disk"
endgroup
else
group "Prepare FreeBSD $release image"
case "$release" in
  *-CURRENT|*-STABLE)
    base="https://download.freebsd.org/snapshots/VM-IMAGES/${release}/amd64/Latest"
    name="FreeBSD-${release}-amd64-BASIC-CLOUDINIT-ufs.qcow2" ;;
  *)
    base="https://download.freebsd.org/releases/VM-IMAGES/${release}-RELEASE/amd64/Latest"
    name="FreeBSD-${release}-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2" ;;
esac
if [ ! -f "$name" ]; then
  curl -fsSL --retry 5 --retry-delay 5 -o "$name.xz" "$base/$name.xz"
  curl -fsSL --retry 5 --retry-delay 5 -o CHECKSUM.SHA256 "$base/CHECKSUM.SHA256"
  # Snapshot checksum files list dated names ("...-20261019-<id>-ufs.qcow2.xz")
# while Latest/ serves the undated one, so match on the image kind instead.
want="$(sed -n 's/^SHA256 (.*BASIC-CLOUDINIT-\(.*[-.]\)\{0,1\}ufs\.qcow2\.xz) = //p' CHECKSUM.SHA256)"
[ "$(printf '%s\n' "$want" | grep -c .)" = 1 ] || die "cannot find a unique checksum for $name.xz"
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
fi

accel=tcg
cpu_model=max
if [ -w /dev/kvm ]; then accel=kvm; cpu_model=host; fi
log "starting qemu: accel=$accel cpu=$cpu mem=${mem}M"

# The cloud-init seed only exists for a stock image; a bundle is already set up.
seed_args=()
if [ -z "${FBSD_IMAGE:-}" ]; then
  seed_args=(-drive "file=seed.iso,if=virtio,format=raw,media=cdrom,readonly=on")
fi

rm -f qemu.pid
qemu-system-x86_64 \
  -machine "q35,accel=$accel" -cpu "$cpu_model" -smp "$cpu" -m "$mem" \
  -display none -serial "file:$FBSD_WORKDIR/console.log" -monitor none \
  -drive "file=disk.qcow2,if=virtio,format=qcow2,cache=unsafe" \
  "${seed_args[@]}" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${FBSD_SSH_PORT}-:22" \
  -device virtio-net-pci,netdev=n0 \
  -device virtio-rng-pci \
  -daemonize -pidfile qemu.pid

group "Waiting for ssh"
wait_ssh "$timeout_s"
vm_ssh 'uname -a; df -h /; sysctl -n hw.ncpu hw.physmem'
endgroup
