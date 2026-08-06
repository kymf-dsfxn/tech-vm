# VMware Workstation VM Scripts

These scripts keep VMware Workstation instance creation separate from guest OS
installation and guest provisioning.

## Script boundaries

- `create-vm-instance.ps1` owns VM directory creation, `.vmx` generation, and
  VMDK creation.
- `invoke-vmrun.ps1` owns VM lifecycle control through `vmrun.exe`.
- `setup-vm.sh` remains the post-install guest provisioning script.

## Current scope

The first implementation slice covers the Stage 0 VMware Workstation shape from
`Sequence.txt`:

- 4 vCPU, 12 GB RAM
- PVSCSI controller
- Core OS disk plus optional data disk(s)
- `vmxnet3` networking (default `nat`, configurable)
- UEFI firmware, Secure Boot disabled by default
- boot delay and side-channel mitigation options encoded in `.vmx`

## Example: create a VM instance

```powershell
cd S:\local-data\00.kymf-work\00.dev\01.work-data\work-data_virtual-machines\vm-create

.\scripts\create-vm-instance.ps1 \
  -VmName kymf-xd00-lde-0010 \
  -VmRootPath C:\local-data\k-vm \
  -IsoPath C:\iso\ubuntu-26.04-live-server-amd64.iso \
  -DisableSideChannelMitigations
```

## Example: create a VM instance from a parameter file

Copy `vm-definition.sample.json` to a working file, update the paths and VM
name, then run:

```powershell
.\scripts\create-vm-instance.ps1 \
  -ConfigPath .\vm-definitions\vm-definition.sample.json
```

Any explicitly passed CLI parameter overrides the value from the JSON file.

```powershell
.\scripts\create-vm-instance.ps1 \
  -ConfigPath .\vm-definitions\vm-definition.sample.json \
  -VmName kymf-xd00-lde-0011 \
  -VmRootPath C:\local-data\k-vm-dev
```

This creates:

- `C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010.vmx`
- `C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010-core.vmdk`
- `C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010-data-01.vmdk`

Use `-SkipDiskCreation` if you want to validate `.vmx` generation without
calling `vmware-vdiskmanager.exe`.

## Parameter file format

The JSON parameter file is intentionally flat so it can be edited easily and
overridden from the CLI when needed. The current supported fields are:

- `VmName`
- `VmRootPath`
- `IsoPath`
- `CpuCount`
- `CoresPerSocket`
- `MemoryMB`
- `CoreDiskSizeGB`
- `DataDiskCount`
- `DataDiskSizeGB`
- `NetworkType`
- `NetworkName`
- `GuestOs`
- `Firmware`
- `BootDelayMs`
- `DisplayWidth`
- `DisplayHeight`
- `DisplayCount`
- `NetworkAdapter`
- `ScsiController`
- `VirtualHardwareVersion`
- `DiskProvisioning`
- `VdiskManagerPath`
- `EnableSecureBoot`
- `DisableSideChannelMitigations`
- `EnableHostSharedFolder`
- `HostSharedFolderPath`
- `HostSharedFolderName`

By default, VM creation now emits VMware shared-folder settings for
`.host:/local-data` style guest access:

- `isolation.tools.hgfs.disable = "FALSE"`
- `sharedFolder0.present = "TRUE"`
- `sharedFolder0.enabled = "TRUE"`
- `sharedFolder0.readAccess = "TRUE"`
- `sharedFolder0.writeAccess = "TRUE"`
- `sharedFolder0.hostPath = "S:\local-data"`
- `sharedFolder0.guestName = "local-data"`
- `sharedFolder0.expiration = "never"`
- `sharedFolder.maxNum = "1"`

Override with JSON fields above if needed.

## Example: operate the VM

```powershell
.\scripts\invoke-vmrun.ps1 \
  -Action start \
  -VmxPath C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010.vmx

.\scripts\invoke-vmrun.ps1 \
  -Action snapshot \
  -VmxPath C:\local-data\k-vm\kymf-xd00-lde-0010\kymf-xd00-lde-0010.vmx \
  -SnapshotName empty
```

## Tool resolution

Both PowerShell scripts try to locate VMware binaries from:

- `PATH`
- `C:\Program Files (x86)\VMware\VMware Workstation\`
- `C:\Program Files\VMware\VMware Workstation\`

Pass `-VmrunPath` or `-VdiskManagerPath` explicitly if your installation is in
a different location.

## Guest provisioning: setup-vm.sh

`setup-vm.sh` is run inside the Ubuntu guest after OS installation. It requires
three mandatory network flags to configure a static IP via Netplan:

| Flag | Description |
| ------ | ------------- |
| `--static-ip` | Static IPv4 address for the VM |
| `--gateway` | Default gateway IPv4 address |
| `--iface` | Network interface name (e.g. `ens160`) |

### Per-VM invocation examples

```bash
# xd00-lde-0010 (10.66.81.x subnet)
sudo ./setup-vm.sh --static-ip 10.66.81.101 --gateway 10.66.81.2 --iface ens160

# xd00-lde-0020 (10.66.82.x subnet)
sudo ./setup-vm.sh --static-ip 10.66.82.102 --gateway 10.66.82.2 --iface ens160

# xd00-lde-0030 (10.66.83.x subnet)
sudo ./setup-vm.sh --static-ip 10.66.83.103 --gateway 10.66.83.2 --iface ens160
```

All other flags (`--platform-username`, `--platform-prefix`, `--named-user`,
`--break-glass-pw`) remain optional with sensible defaults.
