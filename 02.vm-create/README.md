# 02.vm-create

Create and control a VMware Workstation VM. Stage 02 reads the ISO that
`01.iso-build` produced and writes the VM. It does not provision the guest OS:
the ISO installs and provisions itself (see `00.host-config`).

## Scripts

- `create-vm-instance.py` writes the VM directory, the `.vmx`, and the virtual
  disks.
- `invoke-vmrun.py` controls a VM through `vmrun`: power, snapshots, clone, guest
  IP.
- `vmware_workstation.py` is the shared library both scripts import. It holds the
  path resolution, the VMware binary discovery, the disk creation, the `.vmx`
  assembly, and the `vmrun` call. It is not run on its own.
- `get-host-ips.py` prints the host network adapters and their IPv4 addresses. Use
  it to pick a bridged network or a free static IP.

The scripts are a Python port of the earlier PowerShell versions. Run them with
`uv`, so the pinned interpreter and dependencies resolve the same way on every
host.

## Hardware shape

`create-vm-instance.py` builds the Stage 0 VMware Workstation shape by default:

- 4 vCPU, 12 GB RAM
- PVSCSI controller
- one core disk (32 GB) plus one data disk (512 GB)
- `vmxnet3` networking, `nat` by default
- UEFI firmware, Secure Boot off
- boot delay and side-channel mitigation options written into the `.vmx`
- HGFS shared folder on by default (`S:\local-data` as `local-data`)

Override any default from the command line or a JSON definition file.

## Settings precedence

Every setting resolves in one order, highest first: a command-line value, then the
matching key in the `--config` JSON file, then the built-in default. Config keys
are PascalCase (`VmName`, `CpuCount`, `MemoryMB`), matching the
`vm-definition.<name>.json` files. Command-line flags are kebab-case
(`--vm-name`, `--cpu-count`, `--memory-mb`).

## Create a VM

`create-vm-instance.py` has two subcommands: `run` creates the VM, `validate`
checks the settings and creates nothing.

```bash
# From the command line, resolving the newest ISO from a directory
uv run python scripts/create-vm-instance.py run \
  --vm-name kymf-xd00-lde-0010 \
  --vm-root-path C:\local-data\k-vm \
  --iso-dir C:\local-data\k-vm\isos\xd00-lde-0010 \
  --disable-side-channel-mitigations

# From a definition file, with the ISO given on the command line
uv run python scripts/create-vm-instance.py run \
  --config .\vm-definitions\vm-definition.kymf-xd00-lde-0010.json \
  --iso-dir C:\local-data\k-vm\isos --iso-host xd00-lde-0010

# Check the settings without creating anything
uv run python scripts/create-vm-instance.py validate \
  --config .\vm-definitions\vm-definition.kymf-xd00-lde-0010.json \
  --iso-dir C:\local-data\k-vm\isos --iso-host xd00-lde-0010 --strict
```

A command-line flag overrides the same key in the config file, so one file drives
many VMs:

```bash
uv run python scripts/create-vm-instance.py run \
  --config .\vm-definitions\vm-definition.kymf-xd00-lde-0010.json \
  --vm-name kymf-xd00-lde-0011 \
  --vm-root-path C:\local-data\k-vm-dev
```

The `run` above writes:

- `C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010.vmx`
- `C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010-core.vmdk`
- `C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010-data-01.vmdk`

A run log lands in `<vm-root-path>/logs/<vm-name>.<timestamp>.log`.

Run flags:

- `--dry-run` shows the work without making changes.
- `--force` deletes an existing target VM directory before it creates the new one.
- `--skip-disk-creation` writes the `.vmx` but calls no `vmware-vdiskmanager`. Use
  it to check `.vmx` generation on its own.

## ISO selection

The ISO is chosen at run time, not pinned in the definition file. This keeps the
definition stable while stage 01 rebuilds the ISO under a new version and
timestamp. Two flags name the source, and they are mutually exclusive:

- `--iso-path` gives one exact ISO file.
- `--iso-dir` gives a directory, and the script resolves the newest ISO in it.

Inside an `--iso-dir`, the script prefers the `latest.txt` pointer that stage 01
writes next to each host's ISO. When no pointer is present, it falls back to the
newest `.iso` by modification time. The directory can be the host's own ISO
folder, or a parent that holds a per-host subfolder: with `--iso-host xd00-lde-0010`
(or an `IsoHost` config key) the script descends into that subfolder first. When
you omit the host, it tries a subfolder named for the VM, then searches the
directory itself.

The full resolution order, highest first: `--iso-path`, then `--iso-dir`, then a
config `IsoPath`, then a config `IsoDir`. A command-line value beats the config
file, and an explicit path beats a directory lookup. When nothing resolves, the
VM is created with no boot ISO.

## Definition file

The JSON file is flat, so it is easy to edit and easy to override from the command
line. Copy `vm-definition.sample.json` to a working file, set the paths and the VM
name, then pass it with `--config`. The supported keys are:

`VmName`, `VmRootPath`, `IsoPath`, `IsoDir`, `IsoHost`, `CpuCount`,
`CoresPerSocket`, `MemoryMB`, `CoreDiskSizeGB`, `DataDiskCount`, `DataDiskSizeGB`,
`NetworkType`, `NetworkName`, `GuestOs`, `Firmware`, `BootDelayMs`, `DisplayWidth`,
`DisplayHeight`, `DisplayCount`, `NetworkAdapter`, `ScsiController`,
`VirtualHardwareVersion`, `DiskProvisioning`, `VdiskManagerPath`,
`EnableSecureBoot`, `DisableSideChannelMitigations`, `EnableHostSharedFolder`,
`HostSharedFolderPath`, `HostSharedFolderName`.

`VmName` and `VmRootPath` are required. The three ISO keys are optional: the
per-host definitions leave them out and name the ISO on the command line, so a
definition never pins a stale ISO path. Set `IsoDir` and `IsoHost` in the file
only if you want the config to carry the ISO source. Some keys are constrained.
`NetworkType` is one of `bridged`, `nat`, `hostonly`, or `custom`. `Firmware` is
`efi` or `bios`. `NetworkName` is required when `NetworkType` is `custom`.

## Shared folder

VM creation emits VMware HGFS shared-folder settings by default, so the guest
reaches the host tree at `.host:/local-data`:

- `isolation.tools.hgfs.disable = "FALSE"`
- `sharedFolder0.present = "TRUE"`
- `sharedFolder0.enabled = "TRUE"`
- `sharedFolder0.readAccess = "TRUE"`
- `sharedFolder0.writeAccess = "TRUE"`
- `sharedFolder0.hostPath = "S:\local-data"`
- `sharedFolder0.guestName = "local-data"`
- `sharedFolder0.expiration = "never"`
- `sharedFolder.maxNum = "1"`

Turn the folder off with `--disable-host-shared-folder`, or change the path and
name with `HostSharedFolderPath` and `HostSharedFolderName`. `guest-firstboot.sh`
in `00.host-config` mounts this share in the guest at `/mnt/s/local-data`.

## Operate a VM

Each `invoke-vmrun.py` subcommand maps to one `vmrun` verb: `list`, `start`,
`stop`, `reset`, `suspend`, `pause`, `unpause`, `snapshot`, `delete-snapshot`,
`list-snapshots`, `clone`, `get-guest-ip`.

```bash
uv run python scripts/invoke-vmrun.py start \
  --vmx C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010.vmx \
  --start-mode nogui

uv run python scripts/invoke-vmrun.py snapshot \
  --vmx C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010.vmx \
  --snapshot-name empty

uv run python scripts/invoke-vmrun.py get-guest-ip \
  --vmx C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010.vmx
```

`start` takes `--start-mode {gui,nogui}`. `stop`, `reset`, and `suspend` take
`--stop-mode {soft,hard}`. `clone` takes `--clone-path` and
`--clone-type {full,linked}`. Every action takes `--dry-run`, which prints the
`vmrun` command and runs nothing.

## Tool resolution

Both scripts locate the VMware binaries in this order:

- `PATH`
- `C:\Program Files (x86)\VMware\VMware Workstation\`
- `C:\Program Files\VMware\VMware Workstation\`

Pass `--vmrun-path` or `--vdisk-manager-path` when your install sits elsewhere.

## Stage 01 handoff

`01.iso-build` writes `output/<host>/latest.txt` with the newest ISO name. Point
`--iso-dir` at that host output directory (or a parent, with `--iso-host`), and
the script reads `latest.txt` and attaches the ISO it names. Stage 02 stays in
step with what stage 01 built, and no ISO path is copied by hand. If you keep the
built ISOs elsewhere, point `--iso-dir` at that folder: with no `latest.txt` the
script attaches the newest `.iso` there.

## Guest provisioning

Stage 02 does not touch the guest OS. The custom ISO installs and provisions the
guest with no operator action: `guest-install.sh` runs at install and
`guest-firstboot.sh` runs at first boot, both from `00.host-config`. The static
IP comes from the per-host `autoinstall/user-data`, not from a script in this
stage.
