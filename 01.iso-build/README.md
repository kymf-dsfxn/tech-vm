# 01.iso-build

Builds a per-host Ubuntu 26.04 ISO that installs fully offline. The ISO carries
the autoinstall control, an offline apt repository, the guest payload, and the
provisioning scripts. A booted VM installs and provisions itself with no
network and no operator action.

## Inputs and outputs

It reads `../00.host-config`. It writes to `output/<host>/`:

```
output/<host>/vm-ubuntu-26.04-<host>-<version>-amd64-<timestamp>.iso
output/<host>/latest.txt        # the newest ISO name, for stage 02
```

## Build steps

Build the offline repo once, then build an ISO per host.

```bash
# 1. Fetch the package closure into an offline repo (needs docker or podman)
./scripts/build-package-repo.sh

# 2. Build a host ISO
./scripts/build-custom-iso.sh xd00-lde-0010 ~/iso/ubuntu-26.04-live-server-amd64.iso

# Build all hosts
for host in xd00-lde-0010 xd00-lde-0020 xd00-lde-0030; do
  ./scripts/build-custom-iso.sh "$host" ~/iso/ubuntu-26.04-live-server-amd64.iso
done
```

Rebuild the repo only when `packages.list` changes. The repo is cached under
`.cache/apt-repo` and is not committed to git.

## The offline apt repository

Offline install needs every package on the ISO, because the base pool does not
hold them all. `build-package-repo.sh` resolves the closure of
`00.host-config/common/packages.list` inside a container that matches the target
release, so the resolved versions match what the guest gets. It writes the
`.deb` files and an apt `Packages` index. `build-custom-iso.sh` copies the repo
onto the ISO. `guest-install.sh` installs from `file:///opt/vm-init/apt-repo`.

A later phase may replace the build-time fetch with a managed repository
artefact that has its own life cycle. The interface stays the same: a repo dir
with a `Packages` index.

## Requirements

- `xorriso` and `python3` for the ISO build.
- `docker` or `podman` for the package fetch.
- A stock Ubuntu 26.04 Live Server ISO.

## Build metadata and the manifest

The build reads `build_version`, generates a UTC timestamp, and computes the
identity `vm-ubuntu-26.04-<host>-<version>-amd64`. It writes `build-info.env`
and a planned `build-manifest.json` into the payload. The guest completes both:
`guest-install.sh` records the installed package versions and the install
moment, and `guest-firstboot.sh` records the data disk UUID and the HGFS status.

Inside a built VM:

```bash
image-build-info
# vm-ubuntu-26.04-xd00-lde-0010-2.1.0-amd64
# 20260806T101500Z

image-build-info --manifest
# the full JSON manifest: recipe, planned, applied, firstboot
```

## Stage 02 handoff

`build-custom-iso.sh` writes `output/<host>/latest.txt` with the newest ISO
name. Point the `02.vm-create` `vm-definition` `IsoPath` at that ISO. This keeps
stage 02 in step with what stage 01 produced, and closes the old name drift.

## Boot behaviour

1. The VM boots from the custom ISO.
2. GRUB auto-selects the unattended entry after 5 seconds.
3. The installer reads `/cdrom/autoinstall/user-data`.
4. The late-commands copy the payload and run `guest-install.sh` in the target.
5. The install finishes and the VM reboots.
6. On first boot, `vm-init-firstboot.service` provisions the data disk and the
   HGFS mount, then disables itself.
