#!/bin/sh
# Runs INSIDE the FreeBSD VM: fetch the source tree and build it.
#
# Environment:
#   SRC_REPO    git url of the FreeBSD source tree          (required)
#   SRC_BRANCH  branch, tag or commit to build              (default: repo HEAD)
#   SRC_DIR     checkout location                           (default /usr/src)
#   BUILD_CMD   build command, run from SRC_DIR             (default: buildworld buildkernel)
#   JOBS        make -j value                               (default: hw.ncpu)
#   KERNCONF    kernel config                               (default: GENERIC)
set -eu

: "${SRC_REPO:?SRC_REPO is required}"
: "${SRC_DIR:=/usr/src}"
: "${KERNCONF:=GENERIC}"
: "${JOBS:=$(sysctl -n hw.ncpu)}"
: "${BUILD_CMD:=make -j${JOBS} buildworld buildkernel KERNCONF=${KERNCONF}}"

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
sh -c "${BUILD_CMD}"
echo "==> build finished in $(( $(date +%s) - start ))s"
