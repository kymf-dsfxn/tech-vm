# ISO-Embedded Autoinstall Build

Creates per-host custom Ubuntu 26.04 ISOs with autoinstall configs embedded directly on the ISO filesystem.

## How It Works

The stock Ubuntu ISO is extracted, a custom `grub.cfg` is injected that passes `autoinstall 'ds=nocloud;s=/cdrom/autoinstall/'` to the kernel, and the host's `user-data` + `meta-data` are placed at `/autoinstall/` on the ISO root. The ISO is then rebuilt with `xorriso`.

When booted, GRUB auto-selects the autoinstall entry after a 5-second timeout. The installer finds the nocloud datasource at `/cdrom/autoinstall/` and proceeds unattended.

## Prerequisites

- Linux host (or WSL) with `xorriso` installed
- Stock Ubuntu 26.04 Live Server ISO
- Host configs defined in `config/<hostname>/autoinstall/`
- A `build_version` file in this directory (semantic version, `N.N.N`)

```bash
# Install xorriso (Debian/Ubuntu)
sudo apt install xorriso
```

## Usage

```bash
./build-custom-iso.sh <hostname> <base-iso-path> [output-dir]
```

### Examples

```bash
# Build ISO for a single host
./build-custom-iso.sh xd00-lde-0010 ~/iso/ubuntu-26.04-live-server-amd64.iso

# Build all hosts
for host in xd00-lde-0010 xd00-lde-0020 xd00-lde-0030; do
  ./build-custom-iso.sh "$host" ~/iso/ubuntu-26.04-live-server-amd64.iso ./output
done
```

Output ISOs are named to match the WSL image artefact shape:

```text
vm-ubuntu-26.04-<hostname>-<version>-amd64-<timestamp>.iso
```

For example, `vm-ubuntu-26.04-xd00-lde-0010-1.0.0-amd64-20260805T101500Z.iso`. The version comes from `build_version`. The timestamp is UTC, generated when the ISO is assembled.

## Files

| File | Purpose |
| --- | --- |
| `build_version` | Recipe version in `N.N.N` form. One file versions all host ISOs. |
| `scripts/build-custom-iso.sh` | Main build script |
| `config/common/grub.cfg.template` | Custom GRUB config with autoinstall entry (5s timeout) |
| `config/common/loopback.cfg` | Standard loopback boot config |
| `config/common/image-build-info` | Info command baked into each installed guest |
| `config/<hostname>/autoinstall/` | Per-host `user-data` and `meta-data` |

## Build Info and Versioning

Each built VM carries the same build-info surface as the WSL base image, so one
command works on both platforms.

The build reads `build_version`, generates a UTC timestamp, and writes two files
onto the ISO under `/autoinstall/`: `build-info.env` and the `image-build-info`
command. During install the `late-commands` in `user-data` copy both into the
guest at `/etc/image-build-info.env` and `/usr/local/bin/image-build-info`. The
guest also records its own `INSTALL_TIMESTAMP`, which the ISO cannot know.

Run the command inside an installed VM to print the identity and build timestamp:

```bash
image-build-info
# vm-ubuntu-26.04-xd00-lde-0010-1.0.0-amd64
# 20260805T101500Z

cat /etc/image-build-info.env
# IMAGE_INFO=vm-ubuntu-26.04-xd00-lde-0010-1.0.0-amd64
# BUILD_TIMESTAMP=20260805T101500Z
# INSTALL_TIMESTAMP=20260805T114230Z
```

The env key `IMAGE_INFO` and the command name are shared with the WSL base
image, so `image-build-info` behaves the same on a WSL distro and a VM guest.

## Boot Behaviour

1. VM boots from custom ISO
2. GRUB shows menu with 5-second countdown
3. Default entry auto-selects: "Install Ubuntu Server - Autoinstall (Unattended)"
4. Installer reads `/cdrom/autoinstall/user-data` via nocloud datasource
5. Installation completes fully unattended
6. VM reboots into configured system

A "Try or Install Ubuntu Server" fallback entry is available for manual/recovery use.

## Comparison with HTTP Approach

| | HTTP (`serve-autoinstall.py`) | ISO-Embedded |
| --- | --- | --- |
| Network dependency | Requires reachable HTTP server | None (self-contained) |
| Operator action | Manual GRUB edit at boot | None (auto-boots) |
| Repeatable | Yes (if server available) | Yes (ISO is the artefact) |
| Offline install | No | Yes |
| Per-host artefact | No (single server, select host) | Yes (one ISO per host) |
