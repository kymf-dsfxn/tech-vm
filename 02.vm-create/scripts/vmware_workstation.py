#!/usr/bin/env python3

# Shared library for the VMware Workstation VM-create tooling. Imported by
# create-vm-instance.py and invoke-vmrun.py; not runnable on its own.

import os
import re
import shutil
import subprocess


# -- Path resolution -----------------------------------------------------

def resolve_full_path(path: str) -> str:
    """Return an absolute, normalised path; relative input resolves against cwd."""
    return os.path.abspath(path)


# -- Binary discovery ----------------------------------------------------

def resolve_vmware_binary(tool_name: str, explicit_path: str = None) -> str:
    """Locate a VMware Workstation binary.

    Order:
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
    """Create a VMware virtual disk with vmware-vdiskmanager. The "disk already
    exists" guard fires even in dry-run mode."""
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


_DESCRIPTOR_MARKERS = (b"# Disk DescriptorFile", b"# Extent description")
# A standalone text descriptor is small by construction (~40 bytes per extent;
# a 512 GB splitSparse disk has ~256 extent lines, ~10 KB). Anything above this
# limit that still looks like a text descriptor is malformed rather than large.
_DESCRIPTOR_MAX_BYTES = 1024 * 1024


def _extent_names(descriptor_bytes: bytes) -> list:
    """Extent .vmdk filenames referenced by a text disk descriptor.

    Extent lines look like: RW 8388608 SPARSE "name-s001.vmdk"
    Returns [] for a binary (monolithicSparse) descriptor region.
    """
    head = descriptor_bytes[:512]
    if not any(marker in head for marker in _DESCRIPTOR_MARKERS):
        return []
    text = descriptor_bytes.decode("ascii", errors="replace")
    return re.findall(r'^\s*(?:RW|RDONLY|NOACCESS)\s+\d+\s+\S+\s+"([^"]+\.vmdk)"',
                      text, flags=re.MULTILINE | re.IGNORECASE)


def copy_virtual_disk(source_path: str, target_path: str,
                      dry_run: bool = False) -> None:
    """Copy an existing virtual disk into a new VM directory under a new name.

    Copies descriptor plus extents for both provisioning layouts. Extent
    references in the copied descriptor are rewritten to the target stem (a
    whole-file stem replace). Missing extents fail before any copy, so no
    half-copied disk is left.
    """
    resolved_source = resolve_full_path(source_path)
    resolved_target = resolve_full_path(target_path)

    if not os.path.isfile(resolved_source):
        raise FileNotFoundError(f"Source virtual disk does not exist: {resolved_source}")
    if os.path.exists(resolved_target):
        raise FileExistsError(f"Virtual disk already exists: {resolved_target}")

    target_dir = os.path.dirname(resolved_target)
    if not os.path.isdir(target_dir):
        os.makedirs(target_dir, exist_ok=True)

    source_dir = os.path.dirname(resolved_source)
    source_stem = os.path.basename(resolved_source)[: -len(".vmdk")]
    target_stem = os.path.basename(resolved_target)[: -len(".vmdk")]

    # Read the whole descriptor, not a fixed head: a truncated read would
    # silently drop extents past the cut from the missing-check, the copy and
    # the rewrite. Binary monolithic files never match the markers, so only
    # small text descriptors are ever read in full.
    with open(resolved_source, "rb") as handle:
        descriptor_bytes = handle.read(_DESCRIPTOR_MAX_BYTES + 1)
    if (len(descriptor_bytes) > _DESCRIPTOR_MAX_BYTES
            and any(marker in descriptor_bytes[:512]
                    for marker in _DESCRIPTOR_MARKERS)):
        raise RuntimeError(
            f"Text descriptor larger than {_DESCRIPTOR_MAX_BYTES} bytes, "
            f"refusing to copy a disk it may describe incompletely: "
            f"{resolved_source}"
        )
    extents = _extent_names(descriptor_bytes)

    missing = [name for name in extents
               if not os.path.isfile(os.path.join(source_dir, name))]
    if missing:
        raise FileNotFoundError(
            f"Source disk {resolved_source} references extents that do not exist: "
            + ", ".join(missing)
        )

    if dry_run:
        print(f"  [dry-run] would copy existing disk: {resolved_source}")
        print(f"  [dry-run]                       to: {resolved_target}")
        for name in extents:
            print(f"  [dry-run] would copy extent: {name} -> "
                  f"{name.replace(source_stem, target_stem, 1)}")
        if extents:
            print(f"  [dry-run] would rewrite {len(extents)} extent reference(s) "
                  f"in the copied descriptor")
        return

    print(f"  Copying existing disk: {resolved_source}")
    print(f"                     to: {resolved_target}")
    shutil.copy2(resolved_source, resolved_target)

    for name in extents:
        target_name = name.replace(source_stem, target_stem, 1)
        shutil.copy2(os.path.join(source_dir, name),
                     os.path.join(target_dir, target_name))
        print(f"  Copied extent: {name} -> {target_name}")

    if extents:
        with open(resolved_target, "rb") as handle:
            descriptor = handle.read()
        descriptor = descriptor.replace(source_stem.encode("ascii"),
                                        target_stem.encode("ascii"))
        with open(resolved_target, "wb") as handle:
            handle.write(descriptor)
        print(f"  Rewrote {len(extents)} extent reference(s) in the descriptor")


# -- VMX content ---------------------------------------------------------

def parse_host_shared_drives(spec: str) -> list:
    """Parse a HostSharedDrives value: a comma list of
    <letter>[=<host-path>][:ro|:rw], default path <letter>:\\, default ro.
    Returns [{'GuestName', 'HostPath', 'WriteAccess'}]; raises ValueError.
    Convention: share name = drive letter, guest mountpoint = /mnt/<letter>
    (capability.host-data-access.md)."""
    shares = []
    seen = set()
    for token in filter(None, (t.strip() for t in (spec or "").split(","))):
        body, access = token, "ro"
        if body[-3:].lower() in (":ro", ":rw"):
            access = body[-2:].lower()
            body = body[:-3]
        letter, _, host_path = body.partition("=")
        letter = letter.strip()
        if len(letter) != 1 or not letter.isalpha():
            raise ValueError(
                f"HostSharedDrives entry {token!r}: the share name must be a "
                f"single drive letter, optionally =<host-path> and :ro|:rw"
            )
        letter = letter.upper()
        if letter in seen:
            raise ValueError(f"HostSharedDrives lists drive {letter} twice")
        seen.add(letter)
        shares.append({
            "GuestName": letter,
            "HostPath": host_path.strip() or f"{letter}:\\",
            "WriteAccess": access == "rw",
        })
    return shares


def _vmx_line(name: str, value) -> str:
    """Format one VMX line: name = "value"."""
    return '{0} = "{1}"'.format(name, "" if value is None else value)


def build_vmx_content(definition: dict) -> str:
    """Assemble the full .vmx file text from a definition dict. Lines are
    joined with CRLF and the text ends with a trailing CRLF."""
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

    # HGFS carries host data guest-ward, mounted under /mnt/<letter>; the
    # platform share still travels host-ward over SMB. Design:
    # capability.host-data-access.md. No shares configured -> HGFS off.
    shares = definition.get("HostSharedFolders") or []
    if shares:
        lines.append(_vmx_line("isolation.tools.hgfs.disable", "FALSE"))
        lines.append(_vmx_line("sharedFolder.maxNum", len(shares)))
        for index, share in enumerate(shares):
            prefix = f"sharedFolder{index}"
            lines.append(_vmx_line(f"{prefix}.present", "TRUE"))
            lines.append(_vmx_line(f"{prefix}.enabled", "TRUE"))
            lines.append(_vmx_line(f"{prefix}.readAccess", "TRUE"))
            lines.append(_vmx_line(f"{prefix}.writeAccess",
                                   "TRUE" if share["WriteAccess"] else "FALSE"))
            lines.append(_vmx_line(f"{prefix}.hostPath", share["HostPath"]))
            lines.append(_vmx_line(f"{prefix}.guestName", share["GuestName"]))
            lines.append(_vmx_line(f"{prefix}.expiration", "never"))
        # A power-on with a share's host path absent raises a Workstation
        # dialog that would block an unattended `vmrun start`; auto-answer
        # dismisses it and the share is unavailable for that session.
        lines.append(_vmx_line("msg.autoAnswer", "TRUE"))
    else:
        lines.append(_vmx_line("isolation.tools.hgfs.disable", "TRUE"))

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
    """Write VMX text as ASCII; newline='' stops translation of the explicit CRLFs."""
    with open(path, "w", encoding="ascii", newline="") as handle:
        handle.write(content)


# -- vmrun ---------------------------------------------------------------

def invoke_vmrun(vmrun_path: str, arguments, dry_run: bool = False) -> int:
    """Run vmrun; returns the exit code, raises RuntimeError on a non-zero exit."""
    args = [vmrun_path] + list(arguments)
    if dry_run:
        print(f"  [dry-run] {subprocess.list2cmdline(args)}")
        return 0

    result = subprocess.run(args)
    if result.returncode != 0:
        raise RuntimeError(f"vmrun failed with exit code {result.returncode}.")
    return result.returncode
