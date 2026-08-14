# Capability: host data access

Data moves between the Windows host and the guest in two directions, by two
mechanisms, and the asymmetry is deliberate. This document owns the design;
the implementation is the `HostSharedDrives` setting in `02.vm-create`, the
`sharedFolder` block in the generated `.vmx`, and the `/mnt` fstab block in
`guest-install.sh`.

## The two directions

**Host reads guest data over SMB.** The platform share lives on the guest's
encrypted disk and is served by the guest's own smbd, gated on the disk being
unlocked. That direction is part of the encrypted-datadisk design - see
`capability.encrypted-datadisk.md`, "Samba".

**Guest reads host data over HGFS** (VMware Shared Folders, mounted with
`vmhgfs-fuse` from `open-vm-tools`). The share list is per-VM configuration in
the `.vmx`, so there are no credentials in the guest, no dependence on the
host's network profile or firewall, and nothing to re-authenticate. SMB in
this direction was rejected because it would store a Windows credential on the
guest OS disk, and no secret lands there.

The historical note: HGFS was once disabled outright, when the old
`local-data-*` shared folders were removed. That removal was about guest data
- it must live on the guest's encrypted disk, not on host shares - and it
still holds. HGFS returns here for host data only, travelling the other way.

## Convention

| Host drive | Share name | Guest mountpoint | Access | Presence |
| ---------- | ---------- | ---------------- | ------ | -------- |
| `C:\` | `C` | `/mnt/C` | read-only | always |
| `X:\` | `X` | `/mnt/X` | read-write | external SSD, sometimes connected |
| `S:\` | `S` | `/mnt/S` | read-only | BitLocker drive, absent while locked; being deprecated |

Share name = drive letter, host path = the whole drive, mountpoint =
`/mnt/<letter>`. The convention is carried in two places that must agree: the
`HostSharedDrives` default in `create-vm-instance.py` and the fstab block in
`guest-install.sh`.

Access is enforced twice - `sharedFolderN.writeAccess` in the `.vmx` and the
`ro` mount option in the guest - so one misconfiguration is not enough. The
policy: C is reference data and a guest must not modify the host system
drive; X is the exchange medium, so read-write is its job; S is
**Resilio-synced**, and a guest write there would replicate through Resilio to
every Resilio peer, fighting the migration that is deprecating it.

## Configuration

`HostSharedDrives` (stage 02 setting, default `C:ro,X:rw,S:ro`) is a comma
list of `<letter>[=<host-path>][:ro|:rw]`; default path `<letter>:\`, default
access ro. An empty string turns HGFS off entirely and the `.vmx` reverts to
`isolation.tools.hgfs.disable = "TRUE"`.

When shares are configured, the `.vmx` also carries `msg.autoAnswer = "TRUE"`,
and it is load-bearing: a power-on with a share's host path absent (X:
unplugged) raises a Workstation dialog that would block an unattended
`vmrun start ... nogui`. Auto-answer dismisses it; the share is simply
unavailable for that session.

## Guest mounts

`guest-install.sh` writes one fstab line per drive:

```text
.host:/C /mnt/C fuse.vmhgfs-fuse ro,allow_other,noauto,x-systemd.automount,x-systemd.idle-timeout=300 0 0
```

- `x-systemd.automount`: nothing mounts at boot; the first access triggers the
  mount. An unavailable share returns an error to the caller and the automount
  retries on the next access - so boot never blocks, X: can come and go, and
  the fstab block is harmless on a VM built with `HostSharedDrives` empty.
- `x-systemd.idle-timeout=300`: an unused mount releases, so an unplugged X:
  does not leave a stale fuse mount holding handles.
- `allow_other`: the mount is made by root (systemd), so the named user and
  the platform accounts can use it too. No uid/gid mapping is attempted: hgfs
  synthesises ownership and modes, which is sufficient for reading and for X:
  exchange use.

## Boundaries and the security trade

`/mnt/*` sits outside `/srv/dsfxn`: Syncthing, the SMB share, the folder
marker and the bare-mountpoint invariant never see these mounts, and the
mounts have no relation to the encrypted-disk lifecycle.

The trade, stated plainly: guest root can read anything under the shared paths
that the Windows user running Workstation can read. A whole-drive read-only
C: is a large surface on a guest that also talks to the sync estate. If
containment should ever beat convenience, narrow the host path per share -
for example `C=C:\local-data:ro` - in the VM definition and rebuild the VM.

Existing VMs do not regenerate their `.vmx`; they pick this up at the next
rebuild (the normal path for these guests), or by adding the `sharedFolder`
block by hand while powered off plus the fstab block over SSH. A just-plugged
X: can be attached to a running VM with `vmrun addSharedFolder` (or the
Workstation UI) without a reboot.
