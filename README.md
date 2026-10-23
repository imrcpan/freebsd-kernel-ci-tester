# freebsd-kernel-ci-tester

A GitHub Action that builds a FreeBSD source tree from git **inside a real
FreeBSD VM** on the runner, installs the result, reboots into it and runs a
command of your choice. It is meant for testing kernel / base system changes
from other repositories' CI.

It does not depend on any pre-built artifact other than the official FreeBSD
VM image from `download.freebsd.org` (checksum verified): QEMU boots that
image, the source tree is cloned in the guest and built there with the guest's
own toolchain.

Forked from [vmactions/freebsd-vm](https://github.com/vmactions/freebsd-vm);
the anyvm based implementation was replaced.

## Usage

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: imrcpan/freebsd-kernel-ci-tester@main
        with:
          src-repo: https://github.com/freebsd/freebsd-src.git
          src-branch: main
          run: |
            uname -a                     # runs on the freshly built kernel
            kldload if_tuntap && echo ok
```

By default (`skip-world: true`) the world is **not** built. The action reads
`sys/conf/newvers.sh` of the source tree, boots the latest official prebuilt
snapshot of that branch (`main` is 16.0-CURRENT, `stable/14` is 14.5-STABLE,
`releng/14.4` is the 14.4 release), builds only the kernel from your tree on
the spot and installs it. Detection looks at the content of the tree, not at
the branch name, so a fork's `dev` branch based on `main` gets 16.0-CURRENT.

Set `skip-world: 'false'` to build and install the world as well (stock
release image as build host, `buildworld buildkernel`, `installkernel
installworld`). That takes one to a few hours on a standard runner, so raise
`timeout-minutes`. For a subset, give your own `build-cmd` and
`install-cmd: none`:

```yaml
          build-cmd: make -C sbin/ping obj all
          install-cmd: none
          run: $(make -C sbin/ping -V .OBJDIR)/ping -c1 127.0.0.1
```

## Examples for other repositories

Ready-to-copy workflows live in [`example/`](example/). Copy one into
`.github/workflows/` of your own repository and adjust the inputs.

| example | what it does | typical time (KVM) |
| --- | --- | --- |
| [`kernel-only.yml`](example/kernel-only.yml) | builds only the kernel on the latest prebuilt world (`skip-world`), reboots into it, runs `run` | tens of minutes |
| [`full-world.yml`](example/full-world.yml) | `buildworld buildkernel`, install, reboot, runs the test suite; weekly schedule | hours (job limit is 6 h) |
| [`full-test-demo/`](example/full-test-demo/workflow.yml) | full world + kernel build once, then 3 parallel test jobs on that exact system | hours (build) + minutes (tests) |
| [`reusable-workflow.yml`](example/reusable-workflow.yml) | same as kernel-only, through the reusable workflow, one `uses:` per job | as kernel-only |

### `kernel-only.yml`

The quickest way to get "compile my kernel on the spot and boot it". With the
default `skip-world: 'true'` no world is built: the VM starts from the latest
official snapshot of the source tree's branch, and only `buildkernel` and
`installkernel` run. The `run` script executes after the reboot, i.e. on the
kernel that was just built. The snapshot is a few days old at most, so a very
recent change that needs a matching world (new syscall, changed `sysctl`
or ioctl structure used by userland) needs `skip-world: 'false'`.

### `full-world.yml`

Sets `skip-world: 'false'`, so the default `build-cmd` and `install-cmd` build
and install the full world and kernel, and raises `build-timeout`. Use it when the change touches userland or you need a
matching world and kernel.

### `full-test-demo/`

[`workflow.yml`](example/full-test-demo/workflow.yml) is a two-stage pipeline:

1. `build` compiles the whole world and kernel, installs them, reboots into
   them, and exports the installed VM disk (`export-image`) as a one-day
   artifact (`upload-artifact`, no compression since it is already zstd).
2. `test` is a matrix of three jobs, run in parallel. Each downloads that
   artifact, boots it (`image`) without building anything, and runs one
   script from [`tests/`](example/full-test-demo/tests) (`run-file`):
   `01-sanity.sh` (kernel/world match, build provenance), `02-kernel.sh`
   (modules, tmpfs, CPU load) and `03-userland.sh` (compiler, libc, network).

No `actions/cache` is used. The system is only passed along as an artifact of
the same workflow run. Copy `workflow.yml` to `.github/workflows/` and the
`tests/` directory to `example/full-test-demo/tests/` (or change `run-file`).
The bundle contains a throw-away ssh key and the installed system, so do not
publish it. `/usr/obj` is removed from it to keep it small.

### `reusable-workflow.yml`

Calls `.github/workflows/kernel-ci.yml` of this repository. Inputs: `src-repo`,
`src-branch`, `release`, `kernconf`, `world` (`true` also builds and installs
the world; default `false`), `run`, `timeout-minutes`. It is the shortest form when you do not
need the other action inputs.

### Testing the repository that runs the CI

In any example, replace the source tree with the repository under test:

```yaml
src-repo: ${{ github.server_url }}/${{ github.repository }}.git
src-branch: ${{ github.sha }}
```

The VM clones anonymously, so private source repositories are not supported.

## Inputs

| input | default | meaning |
| --- | --- | --- |
| `src-repo` | | git URL of the source tree; empty = build nothing (use with `image`) |
| `src-branch` | remote HEAD | branch, tag or commit to build |
| `skip-world` | `true` | do not build the world; use the latest official prebuilt snapshot of the tree's branch |
| `release` | detected | base image: a release (`14.4`) or snapshot branch (`16.0-CURRENT`, `15.1-STABLE`); 14.4 if `skip-world` is false |
| `kernconf` | `GENERIC` | kernel configuration |
| `build-cmd` | `make -j<cpus> buildkernel KERNCONF=<kernconf>` (`buildworld` first if `skip-world` is false) | run in the source tree (`/usr/src`) |
| `install-cmd` | `make installkernel KERNCONF=$KERNCONF` (plus `installworld` and `etcupdate` if `skip-world` is false) | `none` skips installing |
| `reboot` | `true` | reboot after install so `run` uses the new kernel |
| `run-file` | | path of a script on the runner, copied into the VM and run before `run` |
| `image` | | bundle from `export-image` to boot instead of a stock image; with empty `src-repo` nothing is built |
| `export-image` | | write a bundle (`.tar.zst`) of the final VM to this path; the VM is powered off |
| `run` | | script run (with `sh`, in the source tree) in the VM: the program under test |
| `envs` | | names of environment variables to pass into the VM |
| `mem` / `cpu` / `disk` | `10240` / runner cpus / `60G` | VM sizing (disk is sparse) |
| `build-timeout` | `18000` | seconds allowed for fetch + build |

The step fails if the build, install or `run` script fails. On failure the
tail of the VM serial console is printed.

## Requirements and notes

* Linux x86_64 runner with apt (`ubuntu-latest`). KVM is used when
  available; without it QEMU falls back to TCG, which is far too slow for
  a full build.
* The source tree must be a full FreeBSD tree (`sys/conf/newvers.sh` is read to
  pick the base image) and buildable on that base. Override with `release`.
* The source git server must support shallow fetch; a fetch by commit id works
  on GitHub. A blobless filter is used when the server offers it.
* The VM has outbound network access; `git-lite` is installed with `pkg`.

## Local use

```sh
export SKIP_WORLD=true SRC_REPO=https://github.com/freebsd/freebsd-src.git SRC_BRANCH=main
./scripts/setup-host.sh
./scripts/boot-vm.sh          # picks the base image from the source tree
RUN_CMD='uname -a' ./scripts/run.sh
./scripts/cleanup.sh
```

The VM is reachable with `ssh -i $FBSD_WORKDIR/id_ed25519 -p 2222 root@127.0.0.1`.

## License

MIT, see `LICENSE`.
