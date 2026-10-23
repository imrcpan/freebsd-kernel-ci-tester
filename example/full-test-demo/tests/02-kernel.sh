# Test 2: kernel facilities: modules, sysctl tree, memory filesystem, threads.
set -eu
kldload -n tmpfs
kldstat | grep -q tmpfs

mkdir -p /mnt/t
mount -t tmpfs tmpfs /mnt/t
echo hello > /mnt/t/f
[ "$(cat /mnt/t/f)" = hello ]
umount /mnt/t

[ "$(sysctl -n hw.ncpu)" -ge 1 ]
sysctl -n vm.stats.vm.v_page_count >/dev/null
# Burn a little CPU on every core to catch scheduler/locking panics.
n="$(sysctl -n hw.ncpu)"
i=0
while [ "$i" -lt "$n" ]; do
  ( j=0; while [ "$j" -lt 20000 ]; do j=$((j+1)); done ) &
  i=$((i+1))
done
wait
echo "PASS kernel"
