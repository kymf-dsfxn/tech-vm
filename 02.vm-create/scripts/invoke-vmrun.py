#!/usr/bin/env python3

# Thin argparse front-end over vmrun for VM lifecycle actions.
#
# Each vmrun action is a subcommand; _ACTION_VERBS below is the
# subcommand-to-verb map.
#
# Run with --help for the full flag surface.

import argparse
import atexit
import os
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmware_workstation as vmw  # noqa: E402


__script_name__ = "invoke-vmrun"
__version__ = "1.0.0"

_REDACT_KEYS = {"password", "secret", "token"}

# subcommand -> vmrun verb
_ACTION_VERBS = {
    "list": "list",
    "start": "start",
    "stop": "stop",
    "reset": "reset",
    "suspend": "suspend",
    "pause": "pause",
    "unpause": "unpause",
    "snapshot": "snapshot",
    "delete-snapshot": "deleteSnapshot",
    "list-snapshots": "listSnapshots",
    "clone": "clone",
    "get-guest-ip": "getGuestIPAddress",
}


# -- Script context ------------------------------------------------------

def _script_context():
    """Script identity line: single source of context for errors, help, and the banner."""
    return f"{__script_name__} v{__version__}"


class HeaderArgumentParser(argparse.ArgumentParser):
    """Parser that prefixes the script identity header to help and errors, so
    parse failures carry script identity; subparsers inherit via parser_class."""

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


def fmt_time(seconds):
    """Format a duration with adaptive units. Keep identical to the copy in
    create-vm-instance.py."""
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

def parse_arguments():
    parser = HeaderArgumentParser(
        description="Control a VMware Workstation VM through vmrun.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--version", action="version", version=_script_context())
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Options common to every action.
    base = argparse.ArgumentParser(add_help=False)
    base.add_argument("--vmrun-path", help="Explicit path to vmrun.exe")
    base.add_argument("--log-dir", help="Directory for the run log (default <vmx-dir>/logs or ./logs)")
    base.add_argument("--quiet", action="store_true", default=False,
                      help="Suppress console output; log file only")
    base.add_argument("--dry-run", action="store_true", default=False,
                      help="Print the vmrun command without running it")

    def add(name, help_text, needs_vmx=True):
        sub = subparsers.add_parser(
            name, help=help_text, parents=[base],
            formatter_class=argparse.ArgumentDefaultsHelpFormatter,
        )
        if needs_vmx:
            sub.add_argument("--vmx", required=True, help="Path to the .vmx file")
        return sub

    add("list", "List running VMs", needs_vmx=False)

    p = add("start", "Power on the VM")
    p.add_argument("--start-mode", choices=["gui", "nogui"], default="nogui")

    for verb in ("stop", "reset", "suspend"):
        p = add(verb, f"{verb.capitalize()} the VM")
        p.add_argument("--stop-mode", choices=["soft", "hard"], default="soft")

    add("pause", "Pause the VM")
    add("unpause", "Unpause the VM")

    p = add("snapshot", "Take a snapshot")
    p.add_argument("--snapshot-name", required=True)

    p = add("delete-snapshot", "Delete a snapshot")
    p.add_argument("--snapshot-name", required=True)

    add("list-snapshots", "List snapshots")

    p = add("clone", "Clone the VM")
    p.add_argument("--clone-path", required=True, help="Destination .vmx path for the clone")
    p.add_argument("--clone-type", choices=["full", "linked"], default="full")

    add("get-guest-ip", "Get the guest IP address (waits for tools)")

    return parser.parse_args()


def build_vmrun_arguments(args, resolved_vmx):
    """Assemble the vmrun argument list; always prefixed with '-T ws'."""
    verb = _ACTION_VERBS[args.command]
    arguments = ["-T", "ws"]

    if args.command == "list":
        arguments.append("list")
    elif args.command == "start":
        arguments += ["start", resolved_vmx, args.start_mode]
    elif args.command in ("stop", "reset", "suspend"):
        arguments += [verb, resolved_vmx, args.stop_mode]
    elif args.command in ("pause", "unpause", "list-snapshots"):
        arguments += [verb, resolved_vmx]
    elif args.command in ("snapshot", "delete-snapshot"):
        arguments += [verb, resolved_vmx, args.snapshot_name]
    elif args.command == "clone":
        resolved_clone = vmw.resolve_full_path(args.clone_path)
        arguments += [verb, resolved_vmx, resolved_clone, args.clone_type]
    elif args.command == "get-guest-ip":
        arguments += [verb, resolved_vmx, "-wait"]

    return arguments


# -- Main ----------------------------------------------------------------

def _bootstrap_setup(args, script_start_timestamp):
    """Set up logging.

    Runs before logging or the banner exists, so failures here land in the
    pre-banner window that main() catches and maps to exit 2.

    Returns (vmx_value, log_path).
    """
    vmx_value = getattr(args, "vmx", None)
    default_log_base = os.path.dirname(vmw.resolve_full_path(vmx_value)) if vmx_value else os.getcwd()
    log_dir = args.log_dir or os.path.join(default_log_base, "logs")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, f"{__script_name__}.{args.command}.{script_start_timestamp}.log")

    log_handle = open(log_path, "w", encoding="utf-8")
    atexit.register(log_handle.close)
    sys.stdout = _Tee(sys.stdout, log_handle, suppress_primary=args.quiet)
    sys.stderr = _Tee(sys.__stderr__, log_handle, suppress_primary=False)

    return vmx_value, log_path


def main():
    args = parse_arguments()

    script_start_timestamp = datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    try:
        vmx_value, log_path = _bootstrap_setup(args, script_start_timestamp)
    except Exception as exc:
        sys.stderr.write(f"{_script_context()}\n")
        sys.stderr.write(f"{__script_name__}: error: {exc}\n")
        return 2

    redacted_args = redact_arguments(args)

    print(f"# {_script_context()}")
    print(f"# Started:  {script_start_timestamp}")
    print(f"# Log:      {log_path}")
    print(f"# Action:   {args.command} -> vmrun {_ACTION_VERBS[args.command]}")
    print(f"# Args:     {redacted_args}")
    print("#")

    start = time.time()
    try:
        resolved_vmrun = vmw.resolve_vmware_binary("vmrun.exe", explicit_path=args.vmrun_path)

        resolved_vmx = None
        if vmx_value:
            resolved_vmx = vmw.resolve_full_path(vmx_value)
            if not os.path.isfile(resolved_vmx):
                raise FileNotFoundError(f"VMX file does not exist: {resolved_vmx}")

        arguments = build_vmrun_arguments(args, resolved_vmx)
        print(f"  vmrun: {resolved_vmrun}")
        vmw.invoke_vmrun(resolved_vmrun, arguments, dry_run=args.dry_run)
    except (FileNotFoundError, RuntimeError) as exc:
        print(f"\nError: {exc}", file=sys.stderr)
        return 1

    print(f"\nDone in {fmt_time(time.time() - start)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
