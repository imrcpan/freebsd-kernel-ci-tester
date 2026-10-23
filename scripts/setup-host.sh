#!/usr/bin/env bash
# Install QEMU and friends on a Debian/Ubuntu runner and enable KVM if present.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

group "Install host tools"
need=()
for pair in qemu-system-x86_64:qemu-system-x86 qemu-img:qemu-utils genisoimage:genisoimage xz:xz-utils ssh:openssh-client curl:curl; do
  command -v "${pair%%:*}" >/dev/null 2>&1 || need+=("${pair##*:}")
done
if [ ${#need[@]} -gt 0 ]; then
  sudo=""; [ "$(id -u)" = 0 ] || sudo=sudo
  $sudo apt-get update -qq
  $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${need[@]}"
fi

# Hosted runners are short on disk for a full world build: drop big toolchains.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL 2>/dev/null || true
  df -h / | tail -1
fi

if [ -e /dev/kvm ] && [ ! -w /dev/kvm ]; then
  log "enabling KVM access for the current user"
  echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
    | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=kvm || true
fi
if [ -w /dev/kvm ]; then log "KVM available"; else log "KVM NOT available, falling back to slow TCG emulation"; fi
endgroup
