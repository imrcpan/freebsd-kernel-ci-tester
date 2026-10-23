#!/bin/sh
# Runs INSIDE the FreeBSD VM: fetch the source tree and build it.
#
# Environment:
#   SRC_REPO    git url of the FreeBSD source tree          (required)
#   SRC_BRANCH  branch, tag or commit to build              (default: repo HEAD)
#   SRC_DIR     checkout location                           (default /usr/src)
#   BUILD_CMD   build command, run from SRC_DIR             (default: buildworld buildkernel,
#               or only buildkernel when SKIP_WORLD=true)
#   SKIP_WORLD  "true": do not build the world, the VM's prebuilt one is used
#   JOBS        make -j value                               (default: hw.ncpu)
#   KERNCONF    kernel config                               (default: GENERIC)
#   BUILD_LOG   file that receives the build output          (default /var/tmp/build.log)
#   BUILD_VERBOSE  "true": stream the build output instead
set -eu

: "${SRC_REPO:?SRC_REPO is required}"
: "${SRC_DIR:=/usr/src}"
: "${BUILD_LOG:=/var/tmp/build.log}"
: "${KERNCONF:=GENERIC}"
: "${JOBS:=$(sysctl -n hw.ncpu)}"
: "${SKIP_WORLD:=false}"
if [ "${SKIP_WORLD}" = true ]; then
    : "${BUILD_CMD:=make -j${JOBS} buildkernel KERNCONF=${KERNCONF}}"
else
    : "${BUILD_CMD:=make -j${JOBS} buildworld buildkernel KERNCONF=${KERNCONF}}"
fi

echo "==> installing git"
if ! command -v git >/dev/null 2>&1; then
    env ASSUME_ALWAYS_YES=yes pkg install -y git-lite
fi

echo "==> fetching ${SRC_REPO} ${SRC_BRANCH:-<default branch>} into ${SRC_DIR}"
rm -rf "${SRC_DIR}"
mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"
git init -q .
git remote add origin "${SRC_REPO}"
ref="${SRC_BRANCH:-HEAD}"
# --depth 1 works for branches, tags and (on GitHub) full commit ids.
git fetch -q --depth 1 origin "${ref}"
git checkout -q FETCH_HEAD
echo "==> building $(git rev-parse --short HEAD): ${BUILD_CMD}"
start=$(date +%s)
rc=0
if [ "${BUILD_VERBOSE:-false}" = true ]; then
    sh -c "${BUILD_CMD}" || rc=$?
else
    # A world build prints hundreds of thousands of lines and the Actions log
    # viewer truncates the step. Keep the full output in a file and show a
    # progress line every few minutes instead (also keeps the ssh link busy).
    : > "${BUILD_LOG}"
    sh -c "${BUILD_CMD}" > "${BUILD_LOG}" 2>&1 &
    pid=$!
    n=0
    while kill -0 "${pid}" 2>/dev/null; do
        sleep 5
        n=$((n + 1))
        if [ $((n % 60)) -eq 0 ]; then
            echo "   ... $(( ($(date +%s) - start) / 60 ))min, $(wc -l < "${BUILD_LOG}" | tr -d ' ') lines: $(tail -n 1 "${BUILD_LOG}" | cut -c1-100)"
        fi
    done
    wait "${pid}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        echo "==> build failed (exit ${rc}), last 300 lines of ${BUILD_LOG}:"
        tail -n 300 "${BUILD_LOG}"
    fi
fi
echo "==> build finished in $(( $(date +%s) - start ))s (exit ${rc})"
exit "${rc}"
