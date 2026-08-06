# 00.host-config

Every input that defines a host. One tree answers "what makes this host this
host". `01.iso-build` reads this tree and bakes it onto the ISO.

## Layout

```
build_version                  Recipe version, N.N.N. One file versions all hosts.
common/
  grub.cfg.template            Boot control: the autoinstall GRUB entry.
  loopback.cfg                 Boot control: loopback entry.
  image-build-info             Guest command. Prints identity, timestamp, and
                               with --manifest the full build manifest.
  guest-install.sh             Install-time provisioning, run in the target.
  guest-firstboot.sh           First-boot provisioning: data disk, HGFS mount.
  vm-init-firstboot.service    Oneshot unit that runs guest-firstboot.sh once.
  make-manifest.py             Builds the planned manifest and completes it.
  packages.list                Every apt package the guest installs.
  payload/                     Files that land in the guest, common to all hosts.
    extra_cfg/                 apt-minimal.conf, settings.xml, and so on.
    extra_deb/                 Company CA .deb.
    extra_tgz/                 Maven and Liquibase tarballs.
    extra_keys/                Public keys (kymf.pub).
<host>/
  autoinstall/user-data        Autoinstall control. Per-host network and identity.
  autoinstall/meta-data        instance-id and local-hostname.
  payload/                     Optional per-host payload overrides (win over common).
```

## Three kinds of thing

The tree holds three kinds of input, and the ISO build treats each one
differently.

Control steers the installer: `user-data`, `meta-data`, and the GRUB files. The
build places these where the installer reads them.

Payload lands in the guest: the debs, tarballs, keys, config files, and the
`image-build-info` command. The build stages these on the ISO. The install
copies them into the guest.

Logic installs the payload and provisions the hardware: `guest-install.sh` and
`guest-firstboot.sh`. The build ships them on the ISO. The install and the first
boot run them.

## Per-host user-data

Each host keeps its own full `user-data`. The head carries the real per-host
data: the static IP and the hostname. The `late-commands` block is the same for
every host, because everything else it needs it reads at install from the ISO or
the guest. The block copies the payload into the target and runs
`guest-install.sh`.

## packages.list

The one source of truth for guest packages. `build-package-repo.sh` resolves the
dependency closure of this list into an offline repo. `guest-install.sh`
installs exactly these names from that repo. Add a package here, rebuild the
repo, rebuild the ISO.

## Payload merge

Common payload applies to every host. A per-host `payload/` overrides it on a
same-path collision. This is the union that `create-bundle.py` used to build,
moved up into the config stage.
