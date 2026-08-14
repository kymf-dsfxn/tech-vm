# 01.iso-build

Builds a per-host Ubuntu 26.04 ISO that installs fully offline. The ISO carries
the autoinstall control, an offline apt repository, the guest payload, and the
provisioning scripts. A booted VM installs and provisions itself with no
network and no operator action.

## Inputs and outputs

It reads `../00.host-config`. It writes to `output/<host>/` (or a directory
given as the third argument): the timestamped ISO and `latest.txt`, the newest
ISO name, which is the stage-02 handoff.

## Build steps

Build the offline repo and fetch the build tools once, then build an ISO per
host. Both prerequisites are hard: `build-custom-iso.sh` fails without either
cache.

```bash
# 1. Fetch the package closure into an offline repo (needs docker or podman)
./scripts/build-package-repo.sh

# 2. Fetch the standalone build tools (syft, shfmt, uv; needs curl, tar, sha256sum)
./scripts/fetch-build-tools.sh

# 3. Build a host ISO (hosts are the <host>/ directories in 00.host-config)
./scripts/build-custom-iso.sh xd00-lde-0010 ~/iso/ubuntu-26.04-live-server-amd64.iso
```

Rebuild the repo only when `packages.list` changes. Refetch the build tools
when a pin in `fetch-build-tools.sh` changes - and note uv defaults to
`latest`, resolved at fetch time, so a refetch can move uv unless
`--uv-version` pins it. Both caches live under `.cache` and are not committed.
Each script's header documents its options; `build-custom-iso.sh` also honours
`APT_REPO_DIR` and `BUILD_TOOLS_DIR` to relocate the caches.

## The offline apt repository

Offline install needs every package on the ISO, because the base pool does not
hold them all. `build-package-repo.sh` resolves the closure of
`00.host-config/common/packages.list` inside a container that matches the
target release, so the resolved versions match what the guest gets. The
interface to the rest of the build is stable - a repo directory with a
`Packages` index - so the build-time fetch could later be replaced by a managed
repository artefact without touching anything downstream.

## Standalone build tools

syft, shfmt and uv are not in apt, so they cannot come from the offline repo.
`fetch-build-tools.sh` downloads them with checksum verification into
`.cache/build-tools/bin`; syft and shfmt are pinned to the exact version and
sha256 the sdlc build images use. The ISO carries the tree, and
`guest-install.sh` installs the binaries into `/usr/local/bin` with no network.

## Build metadata and the manifest

Metadata is recorded at three moments, each by the component that can know it.
The build reads `build_version`, computes the identity
`vm-ubuntu-26.04-<host>-<version>-amd64`, and writes `build-info.env` plus a
planned `build-manifest.json` into the payload. `guest-install.sh` records the
installed package versions, the platform namespace and the install moment.
`guest-firstboot.sh` records which state the encrypted data disk was found in.
Inside a built VM, `image-build-info` prints the identity and timestamp, and
`image-build-info --manifest` the full JSON manifest.

## Stage 02 handoff

`build-custom-iso.sh` writes `output/<host>/latest.txt` with the newest ISO
name. Stage 02 reads it: point the vm-definition's `IsoDir` (or `--iso-dir`) at
the output tree and the newest build is picked up on every run. See
`02.vm-create/README.md`.

## Boot behaviour

1. The VM boots from the custom ISO.
2. GRUB auto-selects the unattended entry after 5 seconds.
3. The installer reads `/cdrom/autoinstall/user-data`.
4. The late-commands copy the payload and run `guest-install.sh` in the target.
5. The install finishes and the VM reboots.
6. On first boot, `vm-init-firstboot.service` detects the encrypted data disk
   and configures the SMB share, then disables itself. It never prompts: the
   data disk is unlocked later, by hand, with `sudo data-disk unlock` (see
   `../capability.encrypted-datadisk.md`).

Auto-install only happens on a direct boot of the ISO (`grub.cfg`). Booted as
a file from another GRUB - a multiboot USB - the ISO's `loopback.cfg` offers
only the interactive "Try or Install" entry, deliberately: a loopback boot
targets some arbitrary physical machine, which must never be wiped unattended.
