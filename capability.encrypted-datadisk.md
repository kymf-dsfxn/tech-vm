# Capability: encrypted data disk

The platform data root (`/srv/dsfxn`) lives on a LUKS-encrypted second disk
(`/dev/sdb`), unlocked only by a deliberate operator action after an SSH login.
This document is the design record. The implementation is
`00.host-config/common/guest-bin/data-disk` (the operator command),
`provision/guest-install.sh` (install-time mechanism),
`provision/guest-firstboot.sh` (first-boot detection), the shared
`guest-bin/platform_node.py` library, and the drop-ins of the services that
consume the data root.

## Threat model and premise

Two facts drive everything here.

A stolen or copied disk must carry nothing. The data root and every consumer's
state under it - including the Syncthing identity, config and index database
(see `capability.data-synchronisation.md`) - live on the encrypted disk. The OS
disk carries mechanism only: commands, units, templates, accounts.

A VM must boot unattended. `vmrun` start/stop cycles run with no console
window, so nothing at boot may ever wait for a passphrase. The data root is
simply absent until someone unlocks it, and every service that needs it is
built to tolerate that.

The passphrase is only ever typed at the `data-disk` prompts. Nothing persists
it: no keyfile, no crypttab, no host-side escrow. Lose it and the data is gone.

## Never unlocked at boot

Three installation choices enforce this, all made by `guest-install.sh`:

- No `/etc/crypttab` entry, so nothing can trigger a `systemd-ask-password`
  prompt during boot.
- The `/etc/fstab` entry is `noauto`, so the mount is not pulled into
  `local-fs.target`. It still gives systemd enough to derive a
  `srv-dsfxn.mount` unit that services can bind to, which is why the entry is
  written at install time rather than at first boot.
- `cryptsetup-bin` is installed rather than `cryptsetup`, so there are no
  initramfs unlock hooks either.

`guest-firstboot.sh` detects and records the disk state but never touches the
disk: no format, no unlock, no mount. Detection needs the running kernel, which
is why it happens at first boot rather than at install.

## Lifecycle

```sh
sudo data-disk init      # one-time per disk: partition, luksFormat, mkfs.ext4,
                         # share layout and folder marker
sudo data-disk unlock    # cryptsetup open, mount, permissions, gated services up
sudo data-disk lock      # gated services down, umount, cryptsetup close
     data-disk status    # current state; runs without root, see below
sudo data-disk lock --force   # kill the holders when umount says busy
```

`init` refuses a disk that already carries a LUKS header unless `--force`,
which is what makes attaching an existing data disk safe. `unlock` is
idempotent. `lock` refuses a busy mount and prints the `fuser -vm` holder list
rather than doing anything destructive.

`data-disk status --brief` also runs at login via
`/etc/update-motd.d/98-data-disk`: with manual unlock, "is the data disk up
right now?" is the first thing an operator wants to know.

## Honest reporting without root

`status` runs as any user, but two of the facts it reports are privileged, and
it says so rather than guessing:

| Fact | Readable by | Why |
| ---- | ----------- | --- |
| device, partition, mapper nodes | anyone | `[[ -b ]]`, a stat |
| mount, permissions, usage | anyone | mount table and `df` |
| LUKS header and UUID | root | `/dev/sdb1` is `brw-rw---- root:disk`, so `cryptsetup isLuks` gets EACCES |
| SMB password set? | root | `pdbedit` reads the tdbsam under `/var/lib/samba/private/` |

The distinction matters because the two answers have opposite remedies. An
unreadable header is not "no header": reporting the latter invites
`data-disk init`, which reformats. So an unprivileged caller sees
`not readable as kymf - run: sudo data-disk status`, and the state reads
`unknown` rather than `uninitialised`.

This is a general rule for every status surface on the platform: **never
report "absent" for "not allowed to look"** when the two have different
remedies. `sync-node status` follows it for the identity, config and daemon
readback behind `0700` on the encrypted disk.

The observable states are also tested first. A mounted filesystem means
`unlocked` and an open mapper means `opened` whatever the header says, and both
are readable by anyone, so only a disk that is neither needs the header at all.

The state vocabulary is six words - `absent` / `unlocked` / `opened` /
`uninitialised` / `unknown` / `locked` - and there is exactly one classifier:
`platform_node.py`, used by `data-disk status`, called by `guest-firstboot.sh`
through its CLI, and imported by the manifest's `--data-state`. It is
unit-tested without a VM (`00.host-config/common/tests/`).

## The bare mountpoint invariant

While the disk is locked, `/srv/dsfxn` is an ordinary empty directory on the
root filesystem. Anything written there lands on the OS disk and is silently
shadowed the moment the real disk mounts - and to a sync tool, that shadowing
reads as "the user deleted everything".

So the bare mountpoint is created `0500 root:root`, and `data-disk lock`
re-asserts that after unmounting and warns if it finds stray entries. Once
mounted, the ext4 root inode carries its own `2775 dsfxn:dsfxn`; the two
permission sets are independent, so this costs nothing while unlocked.

The folder marker invariant in `capability.data-synchronisation.md` is the same
hazard guarded from the other side: this invariant stops writes landing on the
OS disk, that one stops a sync tool reading a bare mountpoint as a mass delete
at every peer.

## Layout and ownership

Two directories on the mounted filesystem, created by `data-disk` and nothing
else:

- `/srv/dsfxn/share`, `2775 dsfxn:dsfxn` - what replicates and what SMB serves.
- `/srv/dsfxn/.platform`, `0750 root:dsfxn` - each consumer's own state,
  invisible over SMB.

`init` creates them on the provably new filesystem; `unlock` re-asserts them.
No consumer command may create the share: a command that can conjure an empty
share is a command that can tell every peer the share was emptied. (There is
also a mechanical block: a consumer running inside the packaged Syncthing
unit's sandbox could not set the setgid bit anyway - see the seccomp note
below.)

The platform UID/GIDs are pinned (`dsfxn` 500, `dsfxn_node_mgmt` 501, `stsync`
502) so a data disk moved between nodes keeps valid file ownership across a
platform rename: `chown dsfxn:dsfxn` resolves to the same `500:500` the
previous name did.

## Consuming the data root: the gated-service pattern

Any service that consumes the data root must not run while it is locked. Three
steps; the first two are always required, the third applies to any service that
needs setup before it can start.

1. A systemd drop-in binding it to the mount, so an out-of-band `umount` takes
   it down too:

   ```ini
   # /etc/systemd/system/<svc>.service.d/data-disk.conf
   [Unit]
   After=srv-dsfxn.mount
   BindsTo=srv-dsfxn.mount
   ConditionPathIsMountPoint=/srv/dsfxn
   ```

   `BindsTo` handles teardown. The condition handles startup: it skips the unit
   while the disk is locked rather than letting it run against a bare
   mountpoint. A failed condition is not a failed unit - systemd logs
   "Condition check resulted in ... being skipped" and `systemctl start` still
   returns success. That is the point: a node that is not set up yet is not a
   broken node, and `data-disk unlock` should not report one as the other.
   `unlock` names skipped services explicitly, because the skip is otherwise
   silent.

2. An entry in the `DATA_DISK_SERVICES` array at the top of
   `common/guest-bin/data-disk`,
   so `unlock` starts it and `lock` stops it (in reverse order) around the
   mount.

3. If it needs state that only an operator can create, a second condition
   naming that state, not an `ExecStartPre` hook:

   ```ini
   ConditionPathExists=/srv/dsfxn/.platform/syncthing/config.xml
   ```

   The condition gives the same guarantee as a hook - the service cannot run
   before its state exists - without a privileged process, and it reports the
   state correctly. A node that is installed but not set up yet is skipped,
   where a failing hook makes it a failed unit, and upstream's
   `Restart=on-failure` then retries the same error until the start limit stops
   it. (Measured: `RestartSec=1` retried four times in two seconds.) Order the
   condition after the mount, so an absent path is a real answer rather than an
   artefact of testing too early.

   Reach for `ExecStartPre` only when something must happen on every start, and
   read what the `+` prefix does first. `+` lifts `User=`, `Group=`,
   `CapabilityBoundingSet=`, `AmbientCapabilities=` and the filesystem
   namespacing options. It does **not** lift the seccomp options, and
   `RestrictSUIDSGID=true` is one of them: under it, any `chmod` carrying the
   setgid bit is denied, even as root.

Syncthing is the worked example; its drop-in and settings are covered in
`capability.data-synchronisation.md`.

## Samba: the deliberate exception

`smbd` is enabled and stays running whether or not the disk is unlocked, so the
host always sees a live SMB server and gets a clear "share not available"
rather than "host unreachable". It is not in `DATA_DISK_SERVICES` and has no
`BindsTo` drop-in. The `[dsfxn]` share stanza gates itself instead:

```ini
root preexec = /usr/bin/findmnt --mountpoint /srv/dsfxn
root preexec close = yes
```

A non-zero `root preexec` with `root preexec close = yes` tears the connection
down before any I/O reaches the directory. The test is on the mount, not the
share directory, which is the right question: the share lives inside the mount,
so a bare mountpoint has no share to serve.

The share points at `/srv/dsfxn/share` (one level below the data root, so
`.platform` is never served), carries `create mask = 0664` and
`directory mask = 2775` to match the platform permission model, and vetoes the
folder marker so a tidy-up from a client cannot delete the guard.

The SMB password is not set during the build - `smbpasswd` is interactive and
`guest-firstboot.sh` must stay non-interactive. Set it once over SSH with
`sudo smbpasswd -a kymf`; `data-disk status` reports whether it is set.

From the Windows host: `net use X: \\<guest ip>\dsfxn /user:kymf`. While the
disk is locked the mapping is refused, which is the design reporting itself.
