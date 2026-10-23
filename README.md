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
          # default build is: make -j<cpus> buildworld buildkernel
          run: |
            uname -a                     # runs on the freshly built kernel
            kldload if_tuntap && echo ok
```

A full `buildworld buildkernel` takes one to a few hours on a standard
runner, so raise `timeout-minutes` accordingly. To test only a subset, give
your own `build-cmd` (and `install-cmd: none`):

```yaml
          build-cmd: make -C sbin/ping obj all
          install-cmd: none
          run: $(make -C sbin/ping -V .OBJDIR)/ping -c1 127.0.0.1
```

## Examples for other repositories

Ready to copy into `.github/workflows/` of your repository, see `example/`:

* `example/kernel-only.yml`: build only the kernel on the spot, boot it, test it
* `example/full-world.yml`: full `buildworld buildkernel`, install, reboot, test
* `example/reusable-workflow.yml`: the same through the reusable workflow
  `imrcpan/freebsd-kernel-ci-tester/.github/workflows/kernel-ci.yml@main`
  (inputs: `src-repo`, `src-branch`, `release`, `kernconf`, `world`, `run`)

To test the repository that runs the CI, pass
`src-repo: ${{ github.server_url }}/${{ github.repository }}.git` and
`src-branch: ${{ github.sha }}`. Private source repositories are not
supported (the VM clones anonymously).

## Inputs

| input | default | meaning |
| --- | --- | --- |
| `src-repo` | (required) | git URL of the source tree |
| `src-branch` | remote HEAD | branch, tag or commit to build |
| `release` | `14.4` | official FreeBSD amd64 release used as the build host |
| `kernconf` | `GENERIC` | kernel configuration |
| `build-cmd` | `make -j<cpus> buildworld buildkernel KERNCONF=<kernconf>` | run in the source tree (`/usr/src`) |
| `install-cmd` | `make installkernel installworld KERNCONF=$KERNCONF && etcupdate -B \|\| true` | `none` skips installing |
| `reboot` | `true` | reboot after install so `run` uses the new kernel |
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
* The source tree must be buildable by the chosen `release` (a tree newer than
  the build host may need a newer `release`).
* The VM has outbound network access; `git-lite` is installed with `pkg`.

## Local use

```sh
FBSD_RELEASE=14.4 ./scripts/setup-host.sh
./scripts/boot-vm.sh
SRC_REPO=https://github.com/freebsd/freebsd-src.git SRC_BRANCH=main \
  RUN_CMD='uname -a' ./scripts/run.sh
./scripts/cleanup.sh
```

The VM is reachable with `ssh -i $FBSD_WORKDIR/id_ed25519 -p 2222 root@127.0.0.1`.

## License

MIT, see `LICENSE`.
