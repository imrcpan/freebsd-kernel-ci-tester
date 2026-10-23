# Test 1: the system we booted really is the one that was just built.
set -eu
echo "== uname"; uname -a
echo "== kernel version"; sysctl -n kern.version

# The build job wrote its commit id into /etc/built-from (see the workflow).
echo "== built from"; cat /etc/built-from
test -s /etc/built-from

# Kernel and world must match: a mismatch means the install was partial.
k="$(uname -K)"; w="$(uname -U)"
echo "kernel osreldate=$k world osreldate=$w"
[ "$k" = "$w" ]
echo "PASS sanity"
