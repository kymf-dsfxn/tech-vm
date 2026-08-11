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
  guest-firstboot.sh           First-boot provisioning: data disk detection,
                               SMB share. Non-interactive by design.
  data-disk                    Guest command. Operator lifecycle for the
                               encrypted data disk: init/unlock/lock/status.
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
`image-build-info` and `data-disk` commands. The build stages these on the ISO.
The install copies them into the guest.

Logic installs the payload and provisions the hardware: `guest-install.sh` and
`guest-firstboot.sh`. The build ships them on the ISO. The install and the first
boot run them.

## Per-host user-data

Each host keeps its own full `user-data`. The head carries the real per-host
data: the static IP and the hostname. The `late-commands` block is the same for
every host, because everything else it needs it reads at install from the ISO or
the guest. The block copies the payload into the target and runs
`guest-install.sh`.

## Platform namespace

OS-level customisations and service deployment choices belong to the *platform
layer*, not to a company. One label, the `platform_namespace`, identifies that
layer and derives everything named after it:

| Derived from the label | Today (`dsfxn`) | UID/GID |
|------------------------|-----------------|---------|
| Platform shared user and group | `dsfxn` | 500 |
| Platform node management user and group | `dsfxn_node_mgmt` | 501 |
| Platform shared data root | `/srv/dsfxn` | - |

`guest-install.sh` holds the one literal (`PLATFORM_NAMESPACE`) and writes the
derived set to `/etc/platform.env` in the guest. Everything guest-side reads it
back from there: `guest-firstboot.sh` and `/usr/local/bin/data-disk`. To rename
the platform layer, change the label in `guest-install.sh` and rebuild.

The UID/GID are pinned at 500 and 501 on purpose. A data disk moved between
nodes keeps valid file ownership across a rename, because `chown dsfxn:dsfxn`
resolves to the same `500:500` the previous name did.

The rename applies at install time, under `curtin in-target`. Existing VMs keep
whatever names they were built with until they are rebuilt.

### Deliberately not renamed

These look like the same naming but are not. They are live external endpoints
and artifact filenames, and changing them breaks things:

- `Host github-qf` in `common/payload/extra_cfg/config` - an SSH host alias
  bound to a specific company identity file. (`github-dsfxn` sits beside it.)
- `<id>qf-nexus</id>` and `nexus.q-free.com` in
  `common/payload/extra_cfg/settings.xml` - a real Maven mirror.
- The `ca-certificates-qfree_*_all.deb` glob in `guest-install.sh` - the literal
  filename of the artifact in `common/payload/extra_deb/`. Renaming the glob
  without rebuilding the .deb silently skips the CA install, and the package
  name inside the control data stays `ca-certificates-qfree` regardless.

## Encrypted data disk

`/dev/sdb` is LUKS encrypted and holds the platform data root (`/srv/dsfxn`).
The disk is **never unlocked at boot**. That is the whole design:

- No `/etc/crypttab` entry, so nothing can trigger a `systemd-ask-password`
  prompt during boot.
- The `/etc/fstab` entry is `noauto`, so the mount is not pulled into
  `local-fs.target`. It still gives systemd enough to derive a
  `srv-dsfxn.mount` unit that services can bind to.
- `cryptsetup-bin` is installed rather than `cryptsetup`, so there are no
  initramfs unlock hooks either.

A VM therefore boots unattended, with the data root simply absent, and
`vmrun` start/stop cycles need no console window. Unlocking is a deliberate
operator action after an SSH login.

### Lifecycle

```
sudo data-disk init      # one-time per disk: partition, luksFormat, mkfs.ext4
sudo data-disk unlock    # cryptsetup open, mount, permissions, gated services up
sudo data-disk lock      # gated services down, umount, cryptsetup close
     data-disk status    # current state (the only command not needing root)
sudo data-disk lock --force   # kill the holders when umount says busy
```

`init` refuses a disk that already carries a LUKS header unless `--force`, which
is what makes attaching an existing data disk safe. `unlock` is idempotent.
`lock` refuses a busy mount and prints the `fuser -vm` holder list rather than
doing anything destructive.

The passphrase is only ever typed at these prompts. Nothing persists it: no
keyfile, no crypttab, no host-side escrow. Lose it and the data is gone.

`data-disk status --brief` also runs at login via
`/etc/update-motd.d/98-data-disk`.

### The bare mountpoint invariant

While the disk is locked, `/srv/dsfxn` is an ordinary empty directory on the
root filesystem. Anything written there lands on the OS disk and is silently
shadowed the moment the real disk mounts - and to a sync tool, that shadowing
reads as "the user deleted everything".

So the bare mountpoint is created **`0500 root:root`**, and `data-disk lock`
re-asserts that after unmounting and warns if it finds stray entries. Once
mounted, the ext4 root inode carries its own `2775 dsfxn:dsfxn`; the two
permission sets are independent, so this costs nothing while unlocked.

### Adding a service that consumes the data root

Two steps, both required:

1. A systemd drop-in binding it to the mount, so an out-of-band `umount` takes
   it down too:

   ```ini
   # /etc/systemd/system/<svc>.service.d/data-disk.conf
   [Unit]
   After=srv-dsfxn.mount
   BindsTo=srv-dsfxn.mount
   ```

2. An entry in the `DATA_DISK_SERVICES` array at the top of `common/data-disk`,
   so `unlock` starts it and `lock` stops it in the right order.

**Resilio Sync** is the pending case. It is not in the Ubuntu archive, so
`build-package-repo.sh` cannot resolve it - it needs a `.deb` staged under
`common/payload/extra_deb/` and installed by `guest-install.sh`, the same way
the company CA is. Once installed, wire it up with the two steps above.

**Samba is the deliberate exception.** `smbd` is enabled and stays running
whether or not the disk is unlocked, so the host always sees a live SMB server
and gets a clear "share not available" rather than "host unreachable". It is not
in `DATA_DISK_SERVICES` and has no `BindsTo` drop-in. The `[dsfxn]` share stanza
gates itself instead:

```ini
root preexec = /usr/bin/findmnt --mountpoint /srv/dsfxn
root preexec close = yes
```

A non-zero `root preexec` with `root preexec close = yes` tears the connection
down before any I/O reaches the directory.

The SMB password is not set during the build - `smbpasswd` is interactive and
`guest-firstboot.sh` must stay non-interactive. Set it once over SSH with
`sudo smbpasswd -a kymf`; `data-disk status` reports whether it is set.

## packages.list

The one source of truth for guest packages. `build-package-repo.sh` resolves the
dependency closure of this list into an offline repo. `guest-install.sh`
installs exactly these names from that repo. Add a package here, rebuild the
repo, rebuild the ISO.

## Payload merge

Common payload applies to every host. A per-host `payload/` overrides it on a
same-path collision. This is the union that `create-bundle.py` used to build,
moved up into the config stage.
