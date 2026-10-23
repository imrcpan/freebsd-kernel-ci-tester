# Test 3: the freshly built userland: toolchain, libc, networking, pkg.
set -eu
cat > /tmp/t.c <<'C'
#include <stdio.h>
int main(void) { puts("compiled with the new world"); return 0; }
C
cc -o /tmp/t /tmp/t.c
[ "$(/tmp/t)" = "compiled with the new world" ]

echo "a b c" | awk '{print $2}' | grep -qx b
ping -c 1 127.0.0.1 >/dev/null
ifconfig lo0 | grep -q 127.0.0.1
sort /etc/passwd >/dev/null
echo "PASS userland"
