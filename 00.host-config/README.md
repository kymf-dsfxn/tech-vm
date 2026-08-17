# 00.host-config

Every input that defines a host. One tree answers "what makes this host this
host". `01.iso-build` reads this tree and bakes it onto the ISO.

## Layout

The subdirectories group by role - what determines a file's handling - not by
file type. The ISO stages the assets FLAT under /autoinstall/vm-init, so
/opt/vm-init in the guest keeps its layout whatever this tree does.

```text
build_version                  Recipe version, N.N.N. One file versions all hosts.
common/
  control/                     What steers GRUB and the installer.
    grub.cfg.template          The autoinstall GRUB entry.
    loopback.cfg               Loopback entry; deliberately no autoinstall.
  provision/                   What runs at install and first boot.
    guest-install.sh           Install-time provisioning, run in the target.
    guest-firstboot.sh         First-boot provisioning: data disk detection,
                               SMB share. Non-interactive by design.
    vm-init-firstboot.service  Oneshot unit that runs guest-firstboot.sh once.
    make-manifest.py           Builds the planned manifest and completes it.
  guest-bin/                   The operator command surface; every file here
                               lands in /usr/local/bin.
    data-disk                  Encrypted data disk: init/unlock/lock/status.
    sync-node                  Syncthing replica on that disk: identity/id/
                               render/ensure/marker/status/gui.
    host-drives                HGFS host drive mounts: status/mount/reset.
    platform_node.py           Shared library: platform.env, the six-state
                               classifier, marker/template resolution.
    image-build-info           Prints identity, timestamp, and with
                               --manifest the full build manifest.
  packages.list                Every apt package the guest installs. At the
                               top on purpose: the most-edited input.
  tests/                       Unit tests for platform_node.py, plus the CLI
                               contract the commands honour. Repo-only, not
                               staged onto the ISO.
    db-clients/                Integration test for the ASE/IQ/Postgres client
                               toolchain: run.sh drives a container of the
                               target release, runs the SAP stanzas straight
                               out of guest-install.sh, and compiles the three
                               smoke clients against the result.
  payload/                     Files that land in the guest, common to all
                               hosts, copied by the verbatim merge.
    extra_cfg/                 apt-minimal.conf, settings.xml, and so on.
      syncthing/               node-config.xml.template and the syncthing@
                               data-disk.conf drop-in.
    extra_deb/                 Company CA and Syncthing .debs.
    extra_tgz/                 Maven, Liquibase, and the SAP ASE and SQL
                               Anywhere client bundles.
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
`image-build-info`, `data-disk` and `sync-node` commands. The build stages these
on the ISO. The install copies them into the guest.

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
| ---------------------- | --------------- | ------- |
| Platform shared user and group | `dsfxn` | 500 |
| Platform node management user and group | `dsfxn_node_mgmt` | 501 |
| Platform shared data root | `/srv/dsfxn` | - |

`guest-install.sh` holds the one literal (`PLATFORM_NAMESPACE`) and writes the
derived set to `/etc/platform.env` in the guest. Everything guest-side reads it
back from there: `guest-firstboot.sh`, `/usr/local/bin/data-disk` and
`/usr/local/bin/sync-node`. To rename the platform layer, change the label in
`guest-install.sh` and rebuild.

`/etc/platform.env` also carries four things that are not derived from the
label but belong to the same one-file contract: `PLATFORM_SYNC_USER` (`stsync`,
UID/GID 502, the Syncthing service account), `PLATFORM_DATA_SHARE`,
`PLATFORM_DATA_STATE` and `PLATFORM_NAMED_USER` (`kymf`).

The UID/GID are pinned at 500-502 on purpose. A data disk moved between nodes
keeps valid file ownership across a rename, because `chown dsfxn:dsfxn`
resolves to the same `500:500` the previous name did.

The rename applies at install time, under `curtin in-target`. Existing VMs keep
whatever names they were built with until they are rebuilt.

### Deliberately not renamed

These look like the same naming but are not. They are live external endpoints
and artifact filenames, and changing them breaks things:

- `Host github-qf` in `common/payload/extra_cfg/config` - an SSH host alias
  bound to a specific company identity file. (`github-dsfxn` sits beside it.)
  Note: this file is staged to `/opt/vm-init/extra_cfg/config` but nothing
  installs it into a user's `~/.ssh` yet.
- `<id>qf-nexus</id>` and `nexus.q-free.com` in
  `common/payload/extra_cfg/settings.xml` - a real Maven mirror.
- The `ca-certificates-qfree_*_all.deb` glob in `guest-install.sh` - the literal
  filename of the artifact in `common/payload/extra_deb/`. Renaming the glob
  without rebuilding the .deb silently skips the CA install, and the package
  name inside the control data stays `ca-certificates-qfree` regardless.
- The `syncthing_*_amd64.deb` glob in `guest-install.sh` - same reasoning. The
  filename is the version pin (see `capability.data-synchronisation.md`).
  Renaming the glob silently skips the install, and `guest-install.sh` only
  prints "No Syncthing .deb in payload, skipping".

## The capabilities

The capabilities this tree implements are designed in their own documents at
the repo root, and the rationale lives there:

- **`../capability.encrypted-datadisk.md`** - `/dev/sdb` is LUKS encrypted,
  never unlocked at boot, and holds the platform data root. `data-disk` is the
  operator lifecycle; services that consume the data root register in its
  `DATA_DISK_SERVICES` array and gate themselves with a systemd drop-in (the
  gated-service pattern, including why conditions beat `ExecStartPre` hooks).
  Samba is the deliberate exception: always up, gating the share itself.
- **`../capability.data-synchronisation.md`** - Syncthing replicates the share
  to the hub. The image carries mechanism only; identity and config are created
  by the operator on the encrypted disk with `sync-node`. The folder marker
  invariant, the permission model behind `UMask=0002`, the template's two
  placeholder namespaces, and the GUI/API access model are all there.
- **`../capability.host-data-access.md`** - the guest reads the host drives
  over HGFS at `/mnt/C`, `/mnt/X`, `/mnt/S` (automounted on access, tolerant
  of absence; `guest-install.sh` writes the fstab block, and `host-drives`
  reports why a share is not there). The host reads the guest share over SMB,
  covered by the datadisk document.

On a new guest the first `data-disk unlock` starts nothing, and says so. That
is the node reporting that it is not set up yet, not a fault.

## packages.list

The one source of truth for guest packages. `build-package-repo.sh` resolves the
dependency closure of this list into an offline repo. `guest-install.sh`
installs exactly these names from that repo. Add a package here, rebuild the
repo, rebuild the ISO.

Packages that ship as a payload `.deb` are the exception and must **not** be
listed: naming `syncthing` here would make `build-package-repo.sh` resolve a
second, different Syncthing out of the Ubuntu archive into the offline repo.
Their dependencies still belong here - `procps` is listed for exactly that
reason. `make-manifest.py apply` records them separately, under
`applied.payload_packages`, via repeatable `--payload-package NAME` arguments,
so the manifest can still answer "which Syncthing is on this VM".

## The SAP client bundles

`extra_tgz/sap.ase-client.16.tgz` and `extra_tgz/sap.sql-anywhere-client.16.tgz`
are self-contained trees, unpacked by `guest-install.sh` into `/opt`. The prefix
is not a choice: `sap/SYBASE.sh` hard-codes `SYBASE=/opt/sap` and
`sqlanywhere16/bin64/sa_config.sh` hard-codes `SQLANY16=/opt/sqlanywhere16`, so
they go to `/opt` or nowhere. `SYBASE_OCS` is read off the bundle rather than
hard-coded, because it moves with the release (`OCS-16_1` today, not the
`OCS-16_0` most documentation assumes).

Both are installed as mechanism only. No `interfaces` file is written: server
names and addresses are configuration, and configuration is the operator's, on
the encrypted disk. `dscp` builds one; `dsedit` is the same tool with a Motif
UI and cannot run on a headless server.

**The ASE bundle is a repacked subset of the vendor install, not the vendor
install.** The full tree is 261 MiB compressed and 520 MiB on disk, over
GitHub's 100 MiB per-file limit and mostly irrelevant here. What ships is the
client and the SDK - `OCS-16_1` entire, plus the `config`, `locales`, `collate`
and `charsets` trees CS-Lib reads at `cs_ctx_alloc` - at 45 MiB compressed and
125 MiB on disk. Dropped: two bundled JREs (`shared/`, `jre64/`) on a VM that
already has openjdk-25, an uninstaller for an install that never happened
(`sybuninstall/`), the jConnect JDBC driver, the DBISQL Motif GUI, the Ribo TDS
tracer, and the vendor's install logs. The kept trees are byte-identical to the
vendor's.

Repack from the full bundle again if a dropped component turns out to be
needed - jConnect is the likely candidate, if anything here ever talks JDBC.

`tests/db-clients/run.sh` is what proves all of this still holds.

## Payload merge

Common payload applies to every host. A per-host `payload/` overrides it on a
same-path collision.
