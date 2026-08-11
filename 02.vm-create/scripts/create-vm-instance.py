#!/usr/bin/env python3

# Create a VMware Workstation VM instance: write the .vmx and the virtual disks.
# Python port of create-vm-instance.ps1.
#
# Pipeline position:
#   1. 01.iso-build             -- build the per-host Ubuntu ISO
#   2. create-vm-instance.py    -- write the .vmx and disks for the VM  <-- this
#   3. invoke-vmrun.py          -- start / control the VM
#
# Settings resolve in this order (highest wins): a command-line value, then the
# matching key in the --config JSON file, then the built-in default. Config keys
# are PascalCase (VmName, CpuCount, ...), matching the existing
# vm-definition.<name>.json files.
#
# The ISO is chosen at run time, not pinned in the definition file. Give an
# explicit ISO with --iso-path, or a directory of built ISOs with --iso-dir and
# let the script resolve the newest one (from stage 01's latest.txt, or the
# newest .iso when no pointer is present). See resolve_iso_path for the order.
#
# Usage:
#   uv run python create-vm-instance.py run \
#       --vm-name xd00-lde-0010 --vm-root-path S:\vms \
#       --iso-dir S:\isos\xd00-lde-0010 [--force] [--dry-run] [--skip-disk-creation]
#
#   uv run python create-vm-instance.py run \
#       --vm-name xd00-lde-0010 --vm-root-path S:\vms --iso-path .\out\ubuntu.iso
#
#   uv run python create-vm-instance.py run --config .\vm-definition.xd00-lde-0010.json \
#       --iso-dir S:\isos --iso-host xd00-lde-0010
#
#   uv run python create-vm-instance.py validate --config .\vm-definition.xd00-lde-0010.json [--strict]

import argparse
import atexit
import glob
import json
import os
import shutil
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmware_workstation as vmw  # noqa: E402


__script_name__ = "create-vm-instance"
__version__ = "1.1.0"

# Sensitive argument names to redact in log output (none expected here; kept
# for house-style consistency across scripts).
_REDACT_KEYS = {"password", "secret", "token"}


# -- Setting definitions -------------------------------------------------
# (PascalCase config/canonical name, argparse dest, kind, default, required)
#   kind: 'str' | 'int' | 'bool'
_SETTINGS = [
    ("VmName", "vm_name", "str", None, True),
    ("VmRootPath", "vm_root_path", "str", None, True),
    ("CpuCount", "cpu_count", "int", 4, False),
    ("CoresPerSocket", "cores_per_socket", "int", 4, False),
    ("MemoryMB", "memory_mb", "int", 12288, False),
    ("CoreDiskSizeGB", "core_disk_size_gb", "int", 32, False),
    ("DataDiskCount", "data_disk_count", "int", 1, False),
    ("DataDiskSizeGB", "data_disk_size_gb", "int", 512, False),
    ("NetworkType", "network_type", "str", "nat", False),
    ("NetworkName", "network_name", "str", None, False),
    ("GuestOs", "guest_os", "str", "ubuntu-64", False),
    ("Firmware", "firmware", "str", "efi", False),
    ("BootDelayMs", "boot_delay_ms", "int", 5000, False),
    ("DisplayWidth", "display_width", "int", 1280, False),
    ("DisplayHeight", "display_height", "int", 1024, False),
    ("DisplayCount", "display_count", "int", 1, False),
    ("NetworkAdapter", "network_adapter", "str", "vmxnet3", False),
    ("ScsiController", "scsi_controller", "str", "pvscsi", False),
    ("VirtualHardwareVersion", "virtual_hardware_version", "str", "21", False),
    ("DiskProvisioning", "disk_provisioning", "str", "monolithicSparse", False),
    ("VdiskManagerPath", "vdisk_manager_path", "str", None, False),
    ("EnableSecureBoot", "enable_secure_boot", "bool", False, False),
    ("DisableSideChannelMitigations", "disable_side_channel_mitigations", "bool", False, False),
    ("DataDiskSourcePath", "data_disk_source_path", "str", None, False),
]

_RANGES = {
    "CpuCount": (1, 256),
    "CoresPerSocket": (1, 256),
    "MemoryMB": (256, 2097152),
    "CoreDiskSizeGB": (1, 65535),
    "DataDiskCount": (0, 16),
    "DataDiskSizeGB": (1, 65535),
    "BootDelayMs": (0, 600000),
    "DisplayWidth": (640, 8192),
    "DisplayHeight": (480, 4320),
    "DisplayCount": (1, 8),
}

_ALLOWED = {
    "NetworkType": ["bridged", "nat", "hostonly", "custom"],
    "GuestOs": ["ubuntu-64"],
    "Firmware": ["efi", "bios"],
    "NetworkAdapter": ["vmxnet3"],
    "ScsiController": ["pvscsi"],
    "VirtualHardwareVersion": ["21", "20", "19"],
    "DiskProvisioning": ["monolithicSparse", "splitSparse"],
}


# -- Script context ------------------------------------------------------

def _script_context():
    """The single-line script identity: '<name> v<version>'.

    Single source of truth used for argument-parse errors/help, the pre-banner
    startup guard, and the run banner, so a failure is always seen against the
    same context regardless of where it happens.
    """
    return f"{__script_name__} v{__version__}"


class HeaderArgumentParser(argparse.ArgumentParser):
    """ArgumentParser that prefixes usage, help, and errors with the script
    context line, and shows the full help (not just the terse usage line) on
    every parse failure.

    Propagates to subparsers automatically: add_subparsers() defaults its
    parser_class to type(self), so subcommand parsers inherit this behaviour.
    """

    def _header(self):
        return _script_context() + "\n"

    def error(self, message):
        # print_help() already emits the header via format_help(); follow it
        # with the error message and exit with code 2.
        self.print_help(sys.stderr)
        self.exit(2, f"\n{self.prog}: error: {message}\n")

    def format_help(self):
        return self._header() + super().format_help()


# -- Output Tee ----------------------------------------------------------

class _Tee:
    """Mirror writes to two streams (stdout + log file)."""

    def __init__(self, primary, secondary, suppress_primary=False):
        self._primary = primary
        self._secondary = secondary
        self._suppress_primary = suppress_primary

    def write(self, data):
        if not self._suppress_primary:
            self._primary.write(data)
        if not self._secondary.closed:
            self._secondary.write(data.replace('\r', '\n'))

    def flush(self):
        if not self._suppress_primary:
            self._primary.flush()
        if not self._secondary.closed:
            self._secondary.flush()

    def isatty(self):
        return False

    def __getattr__(self, name):
        return getattr(self._primary, name)


# -- Formatting Helpers --------------------------------------------------

def fmt_time(seconds):
    """Format a duration with adaptive units based on magnitude."""
    if seconds is None:
        return "-"
    if seconds < 1:
        return f"{seconds * 1000:.0f}ms"
    if seconds < 60:
        return f"{seconds:.1f}s"
    if seconds < 3600:
        m, s = divmod(int(seconds), 60)
        return f"{m}m{s:02d}s"
    h, rem = divmod(int(seconds), 3600)
    m = rem // 60
    return f"{h}h{m:02d}m"


def redact_arguments(args):
    """Return a copy of CLI args with sensitive values redacted."""
    redacted_args = vars(args).copy()
    for key in _REDACT_KEYS:
        if key in redacted_args:
            redacted_args[key] = "***"
    return redacted_args


# -- CLI -----------------------------------------------------------------

def _add_domain_arguments(parser):
    """Add the VM-definition arguments shared by run and validate.

    Defaults are None so we can tell a supplied value from an absent one; the
    real defaults live in _SETTINGS and are applied during resolution.
    """
    def valid_values(name):
        return " (one of: " + ", ".join(_ALLOWED[name]) + ")" if name in _ALLOWED else ""

    def rng(name):
        return f" (range {_RANGES[name][0]}-{_RANGES[name][1]})" if name in _RANGES else ""

    parser.add_argument("--config", help="Path to a vm-definition JSON file (PascalCase keys)")

    parser.add_argument("--vm-name", help="VM name; also the directory and .vmx base name")
    parser.add_argument("--vm-root-path", help="Directory under which <vm-name>/ is created")

    # ISO source. --iso-path names one file; --iso-dir names a directory and the
    # newest ISO in it is resolved. The two are mutually exclusive.
    iso_group = parser.add_mutually_exclusive_group()
    iso_group.add_argument("--iso-path", help="Explicit ISO to attach as a boot CD-ROM")
    iso_group.add_argument("--iso-dir", help="Directory of built ISOs; resolve and attach the newest")
    parser.add_argument("--iso-host", help="Host id to pick the ISO subdir/name under --iso-dir")

    parser.add_argument("--cpu-count", type=int, help="Virtual CPUs" + rng("CpuCount"))
    parser.add_argument("--cores-per-socket", type=int, help="Cores per socket" + rng("CoresPerSocket"))
    parser.add_argument("--memory-mb", type=int, help="Memory in MB" + rng("MemoryMB"))
    parser.add_argument("--core-disk-size-gb", type=int, help="Core disk size GB" + rng("CoreDiskSizeGB"))
    parser.add_argument("--data-disk-count", type=int, help="Number of data disks" + rng("DataDiskCount"))
    parser.add_argument("--data-disk-size-gb", type=int, help="Data disk size GB" + rng("DataDiskSizeGB"))
    parser.add_argument("--boot-delay-ms", type=int, help="BIOS boot delay ms" + rng("BootDelayMs"))
    parser.add_argument("--display-width", type=int, help="Max display width" + rng("DisplayWidth"))
    parser.add_argument("--display-height", type=int, help="Max display height" + rng("DisplayHeight"))
    parser.add_argument("--display-count", type=int, help="Number of displays" + rng("DisplayCount"))

    parser.add_argument("--network-type", help="Network connection type" + valid_values("NetworkType"))
    parser.add_argument("--network-name", help="vnet name; required when network-type is custom")
    parser.add_argument("--guest-os", help="Guest OS id" + valid_values("GuestOs"))
    parser.add_argument("--firmware", help="Firmware" + valid_values("Firmware"))
    parser.add_argument("--network-adapter", help="NIC virtual device" + valid_values("NetworkAdapter"))
    parser.add_argument("--scsi-controller", help="SCSI controller" + valid_values("ScsiController"))
    parser.add_argument("--virtual-hardware-version", help="Virtual HW version" + valid_values("VirtualHardwareVersion"))
    parser.add_argument("--disk-provisioning", help="Disk provisioning" + valid_values("DiskProvisioning"))
    parser.add_argument("--vdisk-manager-path", help="Explicit path to vmware-vdiskmanager.exe")

    # Booleans use store_true with default None so absent != False, preserving
    # the config/default precedence. Each bool has an explicit on/off pair.
    for flag_base, dest, help_on in [
        ("secure-boot", "enable_secure_boot", "Enable UEFI secure boot"),
        ("side-channel-mitigations", "disable_side_channel_mitigations", "Disable side-channel mitigations"),
    ]:
        group = parser.add_mutually_exclusive_group()
        if dest == "disable_side_channel_mitigations":
            group.add_argument("--disable-side-channel-mitigations", dest=dest,
                               action="store_true", default=None, help=help_on)
            group.add_argument("--enable-side-channel-mitigations", dest=dest,
                               action="store_false", default=None, help="Keep side-channel mitigations")
        else:
            group.add_argument(f"--enable-{flag_base}", dest=dest,
                               action="store_true", default=None, help=help_on)
            group.add_argument(f"--disable-{flag_base}", dest=dest,
                               action="store_false", default=None, help="Disable UEFI secure boot")

    parser.add_argument("--data-disk-source-path",
                        help="Attach an existing data disk .vmdk instead of creating a fresh one; "
                             "the descriptor and any -s*.vmdk extents are copied into the new VM "
                             "directory (requires --data-disk-count 1)")

    parser.add_argument("--log-dir", help="Directory for the run log (default <vm-root-path>/logs)")
    parser.add_argument("--quiet", action="store_true", default=False,
                        help="Suppress console output; log file only")


def parse_arguments():
    parser = HeaderArgumentParser(
        description="Create a VMware Workstation VM (.vmx + disks).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--version", action="version", version=_script_context())
    subparsers = parser.add_subparsers(dest="command", required=True, metavar="{run,validate}")

    parser_run = subparsers.add_parser(
        "run", help="Create the VM",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    _add_domain_arguments(parser_run)
    parser_run.add_argument("--dry-run", action="store_true", default=False,
                            help="Show what would be done without making changes")
    parser_run.add_argument("--force", action="store_true", default=False,
                            help="Delete an existing target VM directory before creating")
    parser_run.add_argument("--skip-disk-creation", action="store_true", default=False,
                            help="Write the .vmx but do not create virtual disks")

    parser_val = subparsers.add_parser(
        "validate", help="Validate settings without creating anything",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    _add_domain_arguments(parser_val)
    parser_val.add_argument("--strict", action="store_true", default=False,
                            help="Treat warnings as errors")

    return parser.parse_args()


# -- Setting resolution --------------------------------------------------

class SettingError(Exception):
    """Raised for a missing required setting or a failed validation check."""


def load_config(config_path):
    if not config_path:
        return None
    resolved = vmw.resolve_full_path(config_path)
    if not os.path.isfile(resolved):
        raise SettingError(f"Config file does not exist: {resolved}")
    with open(resolved, "r", encoding="utf-8") as handle:
        return json.load(handle)


def resolve_settings(args, config):
    """Apply the command-line > config > default precedence (Get-SettingValue)."""
    resolved = {}
    for name, dest, kind, default, required in _SETTINGS:
        cli_value = getattr(args, dest, None)
        if cli_value is not None:
            value = cli_value
        elif config is not None and name in config:
            value = config[name]
        elif required:
            raise SettingError(
                f"A value is required for {name}. Provide it via --config or the command line."
            )
        else:
            value = default

        if value is not None:
            if kind == "int":
                value = int(value)
            elif kind == "bool":
                value = bool(value)
        resolved[name] = value
    return resolved


# -- ISO resolution ------------------------------------------------------

def _newest_iso_in(directory):
    """Return the most recently modified '*.iso' in a directory, or None.

    Used as the fallback when a directory holds no latest.txt. Modification time
    beats name order, because the version field sits before the timestamp in the
    ISO name and would otherwise sort a newer minor version behind an older one.
    """
    candidates = glob.glob(os.path.join(directory, "*.iso"))
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def _resolve_iso_from_dir(iso_dir, host, vm_name):
    """Resolve one ISO path from a directory of built ISOs.

    The directory can be the host's own ISO folder or a parent that holds a
    per-host subfolder. The lookup descends into a subfolder named for the host,
    or failing that the VM, when one exists. It then takes the ISO named in
    latest.txt (the pointer stage 01 writes), or the newest .iso when no pointer
    is present.
    """
    base = vmw.resolve_full_path(iso_dir)
    if not os.path.isdir(base):
        raise SettingError(f"ISO directory does not exist: {base}")

    search = base
    for name in (host, vm_name):
        if name and os.path.isdir(os.path.join(base, name)):
            search = os.path.join(base, name)
            break

    pointer = os.path.join(search, "latest.txt")
    if os.path.isfile(pointer):
        with open(pointer, encoding="utf-8") as handle:
            iso_name = handle.read().strip()
        if iso_name:
            resolved = os.path.join(search, iso_name)
            if not os.path.isfile(resolved):
                raise SettingError(f"latest.txt in {search} names a missing ISO: {resolved}")
            return resolved

    newest = _newest_iso_in(search)
    if not newest:
        raise SettingError(f"No ISO found in {search} (no latest.txt and no .iso file).")
    return newest


def resolve_iso_path(args, config, vm_name):
    """Resolve the ISO to attach, or None.

    Order, highest first: the command-line --iso-path, then --iso-dir, then the
    config IsoPath, then the config IsoDir. A command-line value beats the config
    file, and an explicit path beats a directory lookup. The host for a directory
    lookup is --iso-host, then the config IsoHost, then none.
    """
    cfg = config or {}
    host = args.iso_host or cfg.get("IsoHost")

    if args.iso_path:
        return vmw.resolve_full_path(args.iso_path)
    if args.iso_dir:
        return _resolve_iso_from_dir(args.iso_dir, host, vm_name)
    if cfg.get("IsoPath"):
        return vmw.resolve_full_path(cfg["IsoPath"])
    if cfg.get("IsoDir"):
        return _resolve_iso_from_dir(cfg["IsoDir"], host, vm_name)
    return None


def validate_settings(s, strict=False):
    """Range and choice checks (Assert-InRange / Assert-OneOf) plus cross-field
    rules. Returns a list of non-fatal warnings; raises SettingError on any
    fatal problem (or on a warning when strict)."""
    for name, (lo, hi) in _RANGES.items():
        value = s[name]
        if value < lo or value > hi:
            raise SettingError(f"{name} must be between {lo} and {hi}. Actual value: {value}")

    for name, allowed in _ALLOWED.items():
        value = s[name]
        if value not in allowed:
            raise SettingError(
                f"{name} must be one of: {', '.join(allowed)}. Actual value: {value}"
            )

    if s["NetworkType"] == "custom" and not s["NetworkName"]:
        raise SettingError("NetworkName is required when NetworkType is custom.")

    # Attaching an existing data disk is a single-disk operation: the source
    # descriptor maps onto exactly one data-disk slot.
    source_path = (s["DataDiskSourcePath"] or "").strip()
    if source_path:
        if s["DataDiskCount"] != 1:
            raise SettingError(
                "DataDiskSourcePath requires DataDiskCount to be 1. "
                f"Actual value: {s['DataDiskCount']}"
            )
        resolved_source = vmw.resolve_full_path(source_path)
        if not os.path.isfile(resolved_source):
            raise SettingError(f"DataDiskSourcePath not found: {resolved_source}")
        if not resolved_source.lower().endswith(".vmdk"):
            raise SettingError(f"DataDiskSourcePath must be a .vmdk file: {resolved_source}")

    warnings = []
    if s["CoresPerSocket"] and (s["CpuCount"] % s["CoresPerSocket"]) != 0:
        warnings.append(
            f"CpuCount ({s['CpuCount']}) is not divisible by CoresPerSocket ({s['CoresPerSocket']})."
        )

    if strict and warnings:
        raise SettingError("Strict mode: " + " ".join(warnings))
    return warnings


# -- Main ----------------------------------------------------------------

def _bootstrap_setup(args, script_start_timestamp):
    """Resolve settings and set up logging.

    Everything here runs BEFORE the banner (the first normal output). Settings
    must resolve first because the default log directory is derived from the
    resolved VM root path, so config/settings errors and log-setup errors both
    fall inside this pre-banner window. main() wraps the single call so any
    failure -- of any type -- is still prefixed with the script context.

    Returns (settings, resolved_vm_root, log_path, config).
    """
    config = load_config(args.config)
    settings = resolve_settings(args, config)

    resolved_vm_root = vmw.resolve_full_path(settings["VmRootPath"])
    log_dir = args.log_dir or os.path.join(resolved_vm_root, "logs")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, f"{settings['VmName']}.{script_start_timestamp}.log")

    log_handle = open(log_path, "w", encoding="utf-8")
    atexit.register(log_handle.close)
    sys.stdout = _Tee(sys.stdout, log_handle, suppress_primary=args.quiet)
    sys.stderr = _Tee(sys.__stderr__, log_handle, suppress_primary=False)

    return settings, resolved_vm_root, log_path, config


def main():
    args = parse_arguments()

    # Capture startup timestamp
    script_start_timestamp = datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    # Guard the pre-banner window. Until _bootstrap_setup() prints the context
    # banner, a failure (bad --config, a missing required setting, an
    # unwritable log dir) has no script identity on screen, so emit the context
    # line and the error here. Catches EVERY exception type, so no pre-banner
    # path can fail without context. SettingError / bad input map to exit 2.
    try:
        settings, resolved_vm_root, log_path, config = _bootstrap_setup(args, script_start_timestamp)
    except Exception as exc:
        sys.stderr.write(f"{_script_context()}\n")
        sys.stderr.write(f"{__script_name__}: error: {exc}\n")
        return 2

    # Redact sensitive values before logging.
    redacted_args = redact_arguments(args)

    # -- Standard run banner (printed before subcommand dispatch) --
    print(f"# {_script_context()}")
    print(f"# Started:  {script_start_timestamp}")
    print(f"# Log:      {log_path}")
    print(f"# Command:  {args.command}")
    print(f"# Args:     {redacted_args}")
    print("#")

    try:
        if args.command == "validate":
            return _cmd_validate(args, settings, config)
        if args.command == "run":
            return _cmd_run(args, settings, resolved_vm_root, config)
    except (SettingError, FileNotFoundError, FileExistsError, RuntimeError) as exc:
        print(f"\nError: {exc}", file=sys.stderr)
        return 1

    return 0


# -- Subcommand: validate ------------------------------------------------

def _cmd_validate(args, settings, config):
    print("\n" + "=" * 60)
    print("VALIDATION")
    print("=" * 60)

    warnings = validate_settings(settings, strict=args.strict)

    resolved_iso = resolve_iso_path(args, config, settings["VmName"])
    if resolved_iso:
        if not os.path.isfile(resolved_iso):
            raise SettingError(f"ISO file does not exist: {resolved_iso}")
        print(f"  ISO found: {resolved_iso}")
    else:
        warnings.append("No ISO set; the VM will be created without a boot ISO.")

    if warnings:
        print(f"\n  {len(warnings)} warning(s):")
        for w in warnings:
            print(f"    - {w}")
    print("\n  Settings valid.")
    return 0


# -- Subcommand: run -----------------------------------------------------

def _cmd_run(args, settings, resolved_vm_root, config):
    overall_start = time.time()

    # =================================================================
    # PHASE 1: Pre-flight validation (fail fast before expensive work)
    # =================================================================
    print("\n" + "=" * 60)
    print("PHASE 1: PRE-FLIGHT CHECKS")
    print("=" * 60)

    validate_settings(settings, strict=False)

    vm_directory = os.path.join(resolved_vm_root, settings["VmName"])
    vmx_path = os.path.join(vm_directory, f"{settings['VmName']}.vmx")

    existing_dir = os.path.exists(vm_directory)
    if existing_dir and not args.force:
        raise SettingError(f"Target VM directory already exists: {vm_directory}")

    resolved_iso = resolve_iso_path(args, config, settings["VmName"])
    if resolved_iso and not os.path.isfile(resolved_iso):
        raise SettingError(f"ISO file does not exist: {resolved_iso}")

    resolved_vdiskmanager = None
    if not args.skip_disk_creation:
        resolved_vdiskmanager = vmw.resolve_vmware_binary(
            "vmware-vdiskmanager.exe", explicit_path=settings["VdiskManagerPath"]
        )

    print(f"  VM directory: {vm_directory}")
    print(f"  VMX path:     {vmx_path}")
    print(f"  ISO:          {resolved_iso or '(none)'}")
    print(f"  vdiskmanager: {resolved_vdiskmanager or '(skipped)'}")
    print("  Pre-flight checks passed.")

    # =================================================================
    # PHASE 2: Execute
    # =================================================================
    print("\n" + "=" * 60)
    print("PHASE 2: EXECUTE")
    print("=" * 60)

    if existing_dir and args.force:
        if args.dry_run:
            print(f"  [dry-run] would remove existing VM directory: {vm_directory}")
        else:
            print(f"  Removing existing VM directory: {vm_directory}")
            shutil.rmtree(vm_directory)

    if args.dry_run:
        print(f"  [dry-run] would create VM directory: {vm_directory}")
    else:
        os.makedirs(vm_directory, exist_ok=True)

    # Build the disk list: one core disk plus N data disks.
    disks = []
    core_disk_name = f"{settings['VmName']}-core.vmdk"
    core_disk_path = os.path.join(vm_directory, core_disk_name)
    disks.append({"FileName": core_disk_name, "Path": core_disk_path,
                  "SizeGB": settings["CoreDiskSizeGB"]})

    # DataDiskSourcePath attaches an existing disk instead of creating a fresh
    # one. Validated in validate_settings(): set implies DataDiskCount == 1 and
    # an existing .vmdk, so the single data-disk entry below is the target.
    data_disk_source = (settings["DataDiskSourcePath"] or "").strip()
    data_disk_source = vmw.resolve_full_path(data_disk_source) if data_disk_source else None

    for index in range(1, settings["DataDiskCount"] + 1):
        data_disk_name = "{0}-data-{1:02d}.vmdk".format(settings["VmName"], index)
        data_disk_path = os.path.join(vm_directory, data_disk_name)
        disks.append({"FileName": data_disk_name, "Path": data_disk_path,
                      "SizeGB": settings["DataDiskSizeGB"],
                      "SourcePath": data_disk_source})

    if not args.skip_disk_creation:
        for disk in disks:
            if disk.get("SourcePath"):
                vmw.copy_virtual_disk(
                    source_path=disk["SourcePath"],
                    target_path=disk["Path"],
                    dry_run=args.dry_run,
                )
            else:
                vmw.create_virtual_disk(
                    path=disk["Path"],
                    size_gb=disk["SizeGB"],
                    vdiskmanager_path=resolved_vdiskmanager,
                    provisioning=settings["DiskProvisioning"],
                    dry_run=args.dry_run,
                )
    else:
        print("  Disk creation skipped (--skip-disk-creation).")

    definition = {
        "VirtualHardwareVersion": settings["VirtualHardwareVersion"],
        "DisplayName": settings["VmName"],
        "GuestOs": settings["GuestOs"],
        "Firmware": settings["Firmware"],
        "CpuCount": str(settings["CpuCount"]),
        "CoresPerSocket": str(settings["CoresPerSocket"]),
        "MemoryMB": str(settings["MemoryMB"]),
        "BootDelayMs": str(settings["BootDelayMs"]),
        "DisableSideChannelMitigations": "TRUE" if settings["DisableSideChannelMitigations"] else "FALSE",
        "SecureBootEnabled": "TRUE" if settings["EnableSecureBoot"] else "FALSE",
        "DisplayWidth": str(settings["DisplayWidth"]),
        "DisplayHeight": str(settings["DisplayHeight"]),
        "DisplayCount": str(settings["DisplayCount"]),
        "NetworkAdapter": settings["NetworkAdapter"],
        "NetworkType": settings["NetworkType"],
        "NetworkName": settings["NetworkName"],
        "ScsiController": settings["ScsiController"],
        "Disks": disks,
        "IsoPath": resolved_iso,
    }

    vmx_content = vmw.build_vmx_content(definition)
    if args.dry_run:
        print(f"  [dry-run] would write VMX file: {vmx_path} ({len(vmx_content)} bytes)")
    else:
        vmw.write_vmx_file(vmx_path, vmx_content)
        print(f"  Wrote VMX file: {vmx_path}")

    # =================================================================
    # SUMMARY
    # =================================================================
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  {'VmName':<20} {settings['VmName']}")
    print(f"  {'VmDirectory':<20} {vm_directory}")
    print(f"  {'VmxPath':<20} {vmx_path}")
    print(f"  {'ConfigPath':<20} {args.config or '(none)'}")
    print(f"  {'CoreDiskPath':<20} {core_disk_path}")
    print(f"  {'DataDiskCount':<20} {settings['DataDiskCount']}")
    print(f"  {'IsoPath':<20} {resolved_iso or '(none)'}")
    print(f"  {'DiskCreationSkipped':<20} {bool(args.skip_disk_creation)}")
    print(f"  {'DryRun':<20} {bool(args.dry_run)}")
    print("=" * 60)
    print(f"\nDone in {fmt_time(time.time() - overall_start)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
