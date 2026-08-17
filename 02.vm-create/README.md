# 02.vm-create

Create and control a VMware Workstation VM. Stage 02 reads the ISO that
`01.iso-build` produced and writes the VM. It does not provision the guest OS:
the ISO installs and provisions itself (see `00.host-config`).

## Scripts

- `create-vm-instance.py` writes the VM directory, the `.vmx`, and the virtual
  disks. Subcommands: `run` creates the VM, `validate` checks the settings and
  creates no VM.
- `invoke-vmrun.py` controls a VM through `vmrun`: power, snapshots, clone,
  guest IP. One subcommand per `vmrun` verb.
- `vmware_workstation.py` is the shared library both scripts import. Not run on
  its own.
- `get-host-ips.py` prints the host network adapters and their IPv4 addresses.
  Use it to pick a bridged network or a free static IP.

The scripts are stdlib-only Python 3. The full flag surface, key constraints
and value ranges are in `--help`; this README covers the concepts.

## Settings precedence

Every setting resolves in one order, highest first: a command-line value, then
the matching key in the `--config` JSON file, then the built-in default. Config
keys are PascalCase (`VmName`, `CpuCount`), command-line flags are kebab-case
(`--vm-name`, `--cpu-count`). An explicit JSON `null` counts as absent, so the
sample file's `null` entries fall through to the defaults and a required key
cannot be satisfied by `null`.

The built-in defaults describe the standard shape: 4 vCPU, 12 GB RAM, PVSCSI,
one 32 GB core disk plus one 512 GB data disk, `vmxnet3` on `nat`, UEFI with
Secure Boot off, and the host drives C:, X:, S: shared into the guest over
HGFS (`HostSharedDrives`, below). The shipped `vm-definitions/*.json` files
override parts of that shape; the definition file is the record of what a host
actually gets.

## Creating a VM

```bash
python scripts/create-vm-instance.py run \
  --config .\vm-definitions\vm-definition.kymf-xd00-lde-0010.json \
  --iso-dir C:\local-data\k-vm\isos --iso-host xd00-lde-0010
```

Outputs land under `<VmRootPath>\<VmName>\`: the `.vmx`, `<name>-core.vmdk`,
`<name>-data-NN.vmdk`, and a run log under `logs\`. `--dry-run` prints the work
without creating the VM, `--force` replaces an existing VM directory,
`--skip-disk-creation` writes only the `.vmx`.

## ISO selection

The ISO is chosen at run time, not pinned in the definition file, so the
definition stays stable while stage 01 rebuilds the ISO under a new version and
timestamp. `--iso-path` names one exact file; `--iso-dir` names a directory
(mutually exclusive; config `IsoPath`/`IsoDir` behind them). Inside a
directory, the `latest.txt` pointer that stage 01 writes wins; otherwise the
newest `.iso` by modification time. `--iso-host` (or `IsoHost`) descends into a
per-host subfolder first, then a subfolder named for the VM, then the directory
itself. When nothing resolves, the VM is created with no boot ISO.

## Data disk: fresh or attach an existing one

By default each data disk is created empty; the guest LUKS-encrypts it on first
use (`sudo data-disk init` - see `../capability.encrypted-datadisk.md`).

To move an already-encrypted data disk onto a new VM, name the source `.vmdk`
with `--data-disk-source-path` (requires `DataDiskCount` 1 - the source
descriptor maps onto exactly one slot). The source is copied, never moved: for
a `splitSparse` source the extents are copied alongside and the descriptor's
extent references are rewritten to the new base name, and a source referencing
a missing extent fails before anything is copied. On the new VM,
`guest-firstboot.sh` reports the disk as `locked`, `data-disk init` refuses it,
and `data-disk unlock` with the original passphrase brings the data back. File
ownership survives because the platform UID/GID are pinned.

## Host and guest data access

Two directions, two mechanisms (design: `../capability.host-data-access.md`).

The guest data root is reached over SMB
(`net use Z: \\<guest-ip>\dsfxn /user:kymf`), and the share answers only while
the data disk is unlocked - see `../capability.encrypted-datadisk.md`, "Samba".
Get the guest IP with `invoke-vmrun.py get-guest-ip`; the default `nat` network
is sufficient, because the host holds an address on the same vmnet segment.

The guest reaches the host drives over HGFS at `/mnt/C`, `/mnt/X`, `/mnt/S`
(all three read-write), automounted on access and tolerant of an
absent drive. `HostSharedDrives` configures the share list - a comma list of
`<letter>[=<host-path>][:ro|:rw]`, default `C:rw,X:rw,S:rw`; an empty string
turns HGFS off. The `.vmx` then also carries `msg.autoAnswer = "TRUE"`, so a
power-on with the external drive unplugged never blocks an unattended
`vmrun start`.

## Tool resolution

The VMware binaries are found by explicit flag (`--vmrun-path`,
`--vdisk-manager-path`) first, then `PATH`, then the two
`Program Files` install trees.

## Stage 01 handoff

`01.iso-build` writes `output/<host>/latest.txt` with the newest ISO name.
Point `--iso-dir` at that output tree (with `--iso-host`), and every run
attaches the ISO the pointer names - no ISO path is ever copied by hand.

## Guest provisioning

Stage 02 does not touch the guest OS. The custom ISO installs and provisions
the guest with no operator action: `guest-install.sh` at install,
`guest-firstboot.sh` at first boot, both from `00.host-config`. The static IP
comes from the per-host `autoinstall/user-data`, not from a script in this
stage.
