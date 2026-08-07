#!/usr/bin/env python3

# Shared helpers for the VMware Workstation VM-create tooling.
#
# Python port of vmware-workstation-common.ps1. This is a library module, not a
# runnable script: create-vm-instance.py and invoke-vmrun.py import it, the same
# way the PowerShell scripts dot-sourced the .ps1 common file.
#
# Contents:
#   resolve_full_path        -- absolute, normalised path (Resolve-FullPath)
#   resolve_vmware_binary    -- locate vmrun.exe / vmware-vdiskmanager.exe
#   create_virtual_disk      -- vmware-vdiskmanager -c (New-VMwareVirtualDisk)
#   build_vmx_content        -- assemble the .vmx text (New-VMwareVmxContent)
#   invoke_vmrun             -- run vmrun with an argument list (Invoke-VMwareVmrun)

import os
import shutil
import subprocess


# -- Path resolution -----------------------------------------------------

def resolve_full_path(path: str) -> str:
    """Return an absolute, normalised path.

    Mirrors Resolve-FullPath: absolute input is normalised as-is, relative
    input is joined to the current working directory first. os.path.abspath
    does both.
    """
    return os.path.abspath(path)


# -- Binary discovery ----------------------------------------------------

def resolve_vmware_binary(tool_name: str, explicit_path: str = None) -> str:
    """Locate a VMware Workstation binary.

    Order (mirrors Resolve-VMwareBinary):
      1. An explicit path, if given (must exist).
      2. The tool on PATH.
      3. The standard install dirs under %ProgramFiles(x86)% / %ProgramFiles%.
    Raises FileNotFoundError if none match.
    """
    if explicit_path:
        resolved = resolve_full_path(explicit_path)
        if not os.path.isfile(resolved):
            raise FileNotFoundError(
                f"Requested {tool_name} binary does not exist: {resolved}"
            )
        return resolved

    on_path = shutil.which(tool_name)
    if on_path:
        return on_path

    candidate_roots = [
        os.environ.get("ProgramFiles(x86)"),
        os.environ.get("ProgramFiles"),
    ]
    for root in candidate_roots:
        if not root:
            continue
        candidate = os.path.join(root, "VMware", "VMware Workstation", tool_name)
        if os.path.isfile(candidate):
            return candidate

    raise FileNotFoundError(
        f"Unable to locate {tool_name}. Add it to PATH or pass an explicit path."
    )


# -- Virtual disk creation -----------------------------------------------

_DISK_TYPE_CODES = {
    "monolithicSparse": "0",
    "splitSparse": "1",
}


def create_virtual_disk(path: str, size_gb: int, vdiskmanager_path: str,
                        provisioning: str = "monolithicSparse",
                        dry_run: bool = False) -> None:
    """Create a VMware virtual disk with vmware-vdiskmanager.

    Mirrors New-VMwareVirtualDisk, including the "disk already exists" guard,
    which fires even in dry-run mode (the PowerShell version checks before its
    ShouldProcess gate).
    """
    resolved = resolve_full_path(path)
    disk_dir = os.path.dirname(resolved)
    if not os.path.isdir(disk_dir):
        os.makedirs(disk_dir, exist_ok=True)

    if os.path.exists(resolved):
        raise FileExistsError(f"Virtual disk already exists: {resolved}")

    if provisioning not in _DISK_TYPE_CODES:
        raise ValueError(f"Unknown provisioning: {provisioning}")
    disk_type_code = _DISK_TYPE_CODES[provisioning]

    args = [
        vdiskmanager_path,
        "-c",
        "-s", f"{size_gb}GB",
        "-a", "scsi",
        "-t", disk_type_code,
        resolved,
    ]

    if dry_run:
        print(f"  [dry-run] would create {size_gb}GB disk: {resolved}")
        print(f"  [dry-run] {subprocess.list2cmdline(args)}")
        return

    print(f"  Creating {size_gb}GB disk: {resolved}")
    result = subprocess.run(args)
    if result.returncode != 0:
        raise RuntimeError(
            f"vmware-vdiskmanager failed creating {resolved} "
            f"(exit code {result.returncode})."
        )


# -- VMX content ---------------------------------------------------------

def _vmx_line(name: str, value) -> str:
    """Format one VMX line: name = "value" (New-VmxLine)."""
    return '{0} = "{1}"'.format(name, "" if value is None else value)


def build_vmx_content(definition: dict) -> str:
    """Assemble the full .vmx file text from a definition dict.

    Faithful port of New-VMwareVmxContent: same keys, same values, same order.
    Lines are joined with CRLF and the text ends with a trailing CRLF, matching
    the PowerShell output on Windows. Booleans are the strings 'TRUE'/'FALSE',
    exactly as the caller supplies them.
    """
    lines = []
    lines.append(_vmx_line(".encoding", "UTF-8"))
    lines.append(_vmx_line("config.version", "8"))
    lines.append(_vmx_line("virtualHW.version", definition["VirtualHardwareVersion"]))
    lines.append(_vmx_line("virtualHW.productCompatibility", "hosted"))
    lines.append(_vmx_line("displayName", definition["DisplayName"]))
    lines.append(_vmx_line("guestOS", definition["GuestOs"]))
    lines.append(_vmx_line("firmware", definition["Firmware"]))
    lines.append(_vmx_line("numvcpus", definition["CpuCount"]))
    lines.append(_vmx_line("cpuid.coresPerSocket", definition["CoresPerSocket"]))
    lines.append(_vmx_line("memsize", definition["MemoryMB"]))
    lines.append(_vmx_line("bios.bootDelay", definition["BootDelayMs"]))
    lines.append(_vmx_line("ulm.disableMitigations", definition["DisableSideChannelMitigations"]))
    lines.append(_vmx_line("uefi.secureBoot.enabled", definition["SecureBootEnabled"]))
    lines.append(_vmx_line("pciBridge0.present", "TRUE"))
    lines.append(_vmx_line("pciBridge4.present", "TRUE"))
    lines.append(_vmx_line("pciBridge4.virtualDev", "pcieRootPort"))
    lines.append(_vmx_line("pciBridge4.functions", "8"))
    lines.append(_vmx_line("pciBridge5.present", "TRUE"))
    lines.append(_vmx_line("pciBridge5.virtualDev", "pcieRootPort"))
    lines.append(_vmx_line("pciBridge5.functions", "8"))
    lines.append(_vmx_line("pciBridge6.present", "TRUE"))
    lines.append(_vmx_line("pciBridge6.virtualDev", "pcieRootPort"))
    lines.append(_vmx_line("pciBridge6.functions", "8"))
    lines.append(_vmx_line("pciBridge7.present", "TRUE"))
    lines.append(_vmx_line("pciBridge7.virtualDev", "pcieRootPort"))
    lines.append(_vmx_line("pciBridge7.functions", "8"))
    lines.append(_vmx_line("vmci0.present", "TRUE"))
    lines.append(_vmx_line("hpet0.present", "TRUE"))
    lines.append(_vmx_line("floppy0.present", "FALSE"))
    lines.append(_vmx_line("sound.present", "FALSE"))

    hgfs_disable = "FALSE" if definition["EnableHostSharedFolder"] == "TRUE" else "TRUE"
    lines.append(_vmx_line("isolation.tools.hgfs.disable", hgfs_disable))

    if definition["EnableHostSharedFolder"] == "TRUE":
        lines.append(_vmx_line("sharedFolder0.present", "TRUE"))
        lines.append(_vmx_line("sharedFolder0.enabled", "TRUE"))
        lines.append(_vmx_line("sharedFolder0.readAccess", "TRUE"))
        lines.append(_vmx_line("sharedFolder0.writeAccess", "TRUE"))
        lines.append(_vmx_line("sharedFolder0.hostPath", definition["HostSharedFolderPath"]))
        lines.append(_vmx_line("sharedFolder0.guestName", definition["HostSharedFolderName"]))
        lines.append(_vmx_line("sharedFolder0.expiration", "never"))
        lines.append(_vmx_line("sharedFolder.maxNum", "1"))

    lines.append(_vmx_line("mks.enable3d", "FALSE"))
    lines.append(_vmx_line("svga.vramSize", "8388608"))
    lines.append(_vmx_line("svga.maxWidth", definition["DisplayWidth"]))
    lines.append(_vmx_line("svga.maxHeight", definition["DisplayHeight"]))
    lines.append(_vmx_line("numDisplays", definition["DisplayCount"]))
    lines.append(_vmx_line("ethernet0.present", "TRUE"))
    lines.append(_vmx_line("ethernet0.virtualDev", definition["NetworkAdapter"]))
    lines.append(_vmx_line("ethernet0.connectionType", definition["NetworkType"]))
    lines.append(_vmx_line("ethernet0.addressType", "generated"))

    if definition["NetworkType"] == "custom" and definition.get("NetworkName"):
        lines.append(_vmx_line("ethernet0.vnet", definition["NetworkName"]))

    lines.append(_vmx_line("scsi0.present", "TRUE"))
    lines.append(_vmx_line("scsi0.virtualDev", definition["ScsiController"]))

    for index, disk in enumerate(definition["Disks"]):
        lines.append(_vmx_line(f"scsi0:{index}.present", "TRUE"))
        lines.append(_vmx_line(f"scsi0:{index}.fileName", disk["FileName"]))
        lines.append(_vmx_line(f"scsi0:{index}.deviceType", "scsi-hardDisk"))

    if definition.get("IsoPath"):
        lines.append(_vmx_line("sata0.present", "TRUE"))
        lines.append(_vmx_line("sata0:0.present", "TRUE"))
        lines.append(_vmx_line("sata0:0.deviceType", "cdrom-image"))
        lines.append(_vmx_line("sata0:0.startConnected", "TRUE"))
        lines.append(_vmx_line("sata0:0.fileName", definition["IsoPath"]))

    return "\r\n".join(lines) + "\r\n"


def write_vmx_file(path: str, content: str) -> None:
    """Write VMX text as ASCII with CRLF line endings preserved.

    newline='' stops Python from translating the explicit CRLFs in content.
    Encoding matches the PowerShell 'Set-Content -Encoding ASCII'.
    """
    with open(path, "w", encoding="ascii", newline="") as handle:
        handle.write(content)


# -- vmrun ---------------------------------------------------------------

def invoke_vmrun(vmrun_path: str, arguments, dry_run: bool = False) -> int:
    """Run vmrun with the given arguments (Invoke-VMwareVmrun).

    Returns the exit code. Raises RuntimeError on a non-zero exit, matching the
    PowerShell throw.
    """
    args = [vmrun_path] + list(arguments)
    if dry_run:
        print(f"  [dry-run] {subprocess.list2cmdline(args)}")
        return 0

    result = subprocess.run(args)
    if result.returncode != 0:
        raise RuntimeError(f"vmrun failed with exit code {result.returncode}.")
    return result.returncode
