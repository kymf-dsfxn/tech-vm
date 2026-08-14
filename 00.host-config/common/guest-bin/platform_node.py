#!/usr/bin/env python3
"""platform_node.py - shared library for the platform guest commands.

One home for the conventions that data-disk, sync-node, make-manifest.py and
guest-firstboot.sh share: /etc/platform.env, the six-state disk vocabulary and
its classifier, marker-name and folder-id resolution, and the template
placeholder scanner. Installed beside the commands in /usr/local/bin, staged
under /opt/vm-init for make-manifest.py. Design:
capability.encrypted-datadisk.md, capability.data-synchronisation.md.

Also a small CLI so bash callers share the code instead of duplicating it:

  platform_node.py state --device /dev/sdb --partition /dev/sdb1 \\
      --mapper /dev/mapper/dsfxn_data --mount /srv/dsfxn
  platform_node.py marker-name [--config PATH] [--template PATH]
"""

import argparse
import os
import re
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET

PLATFORM_ENV_PATH = "/etc/platform.env"

# The six-state disk vocabulary, in classifier test order.
STATES = ("absent", "unlocked", "opened", "uninitialised", "unknown", "locked")

# Fallbacks only; the live values come from the rendered config or template.
MARKER_NAME_DEFAULT = ".dsfxn-share-marker"
FOLDER_ID_DEFAULT = "dsfxn-share"
SYNC_TEMPLATE_PATH = "/etc/syncthing/node-config.xml.template"


class PlatformEnvError(RuntimeError):
    """Raised when /etc/platform.env is missing or unreadable - fatal for
    every consumer, because all platform identity derives from it."""


def load_platform_env(path=PLATFORM_ENV_PATH):
    """Parse the plain KEY=value file written by guest-install.sh."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        raise PlatformEnvError(f"{path} missing or unreadable") from exc
    env = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        env[key.strip()] = value.strip()
    return env


def derived(env):
    """The derived platform values, with the same fallbacks the bash consumers
    used, in one place."""
    namespace = env["PLATFORM_NAMESPACE"]
    data_root = env["PLATFORM_DATA_ROOT"]
    return {
        "namespace": namespace,
        "data_root": data_root,
        "share": env.get("PLATFORM_DATA_SHARE") or f"{data_root}/share",
        "state_dir": env.get("PLATFORM_DATA_STATE") or f"{data_root}/.platform",
        "core_user": env["PLATFORM_CORE_USER"],
        "sync_user": env.get("PLATFORM_SYNC_USER") or "stsync",
        "named_user": env.get("PLATFORM_NAMED_USER") or "kymf",
        "luks_name": f"{namespace}_data",
    }


# -- Disk state ------------------------------------------------------------

class DiskProbes:
    """The questions the classifier asks, isolated so tests can fake them."""

    def is_block_device(self, path):
        try:
            return stat.S_ISBLK(os.stat(path).st_mode)
        except OSError:
            return False

    def is_readable(self, path):
        return os.access(path, os.R_OK)

    def is_mounted(self, mountpoint):
        return subprocess.run(
            ["findmnt", "-rn", "--mountpoint", mountpoint],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False,
        ).returncode == 0

    def is_luks(self, partition):
        return subprocess.run(
            ["cryptsetup", "isLuks", partition],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False,
        ).returncode == 0


def disk_state(device, partition, mapper, mount, probes=None):
    """One word for the whole disk. Observable states first (mounted/open are
    true whatever the header says and readable by anyone); only then the
    header. `unknown` when it cannot be read - never a guess, because "no
    header" invites init, which reformats."""
    p = probes or DiskProbes()
    if not p.is_block_device(device):
        return "absent"
    if p.is_mounted(mount):
        return "unlocked"
    if p.is_block_device(mapper):
        return "opened"
    if not p.is_block_device(partition):
        return "uninitialised"
    if not p.is_readable(partition):
        return "unknown"
    if p.is_luks(partition):
        return "locked"
    return "uninitialised"


# -- Template and config reading --------------------------------------------

_XML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)


def strip_xml_comments(text):
    return _XML_COMMENT_RE.sub("", text)


def pending_tokens(text, prefix):
    """Sorted unique placeholder tokens still standing outside XML comments.
    Comments name the tokens freely, so they are stripped first."""
    return sorted(set(re.findall(prefix + r"[A-Z0-9_]*",
                                 strip_xml_comments(text))))


def scan_template(path):
    """(autofill, manual) token lists for a template file."""
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    return pending_tokens(text, "AUTOFILL_"), pending_tokens(text, "MANUALLY_FIX_")


def first_element_text(path, xpath):
    """Text of the first matching element, or None when the file is absent,
    unreadable or malformed. Element-based on purpose: a markerName written as
    an attribute is accepted and ignored by Syncthing, and must be ignored
    here too."""
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError):
        return None
    node = root.find(xpath)
    if node is None or node.text is None:
        return None
    return node.text.strip() or None


def marker_name_configured(config_path=None, template_path=SYNC_TEMPLATE_PATH):
    """The marker name the files say: rendered config first, then the
    template, then the default. Not authoritative - the daemon readback is -
    but correct for callers that cannot ask the daemon."""
    for path in (config_path, template_path):
        if not path:
            continue
        name = first_element_text(path, ".//markerName")
        if name:
            return name
    return MARKER_NAME_DEFAULT


def folder_id(config_path=None, template_path=SYNC_TEMPLATE_PATH):
    """The folder id from the config, else the template, skipping placeholder
    values (an unfilled template answers with its own placeholder, which is
    not an id), else the last-resort default."""
    for path in (config_path, template_path):
        if not path:
            continue
        try:
            root = ET.parse(path).getroot()
        except (OSError, ET.ParseError):
            continue
        node = root.find(".//folder[@id]")
        if node is None:
            continue
        value = (node.get("id") or "").strip()
        if value and not value.startswith(("MANUALLY_FIX_", "AUTOFILL_")):
            return value
    return FOLDER_ID_DEFAULT


# -- CLI --------------------------------------------------------------------

def _cli(argv):
    parser = argparse.ArgumentParser(
        prog="platform_node.py",
        description="Shared platform helpers for bash callers.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_state = sub.add_parser(
        "state", help="print the six-word disk state (" + " / ".join(STATES) + ")")
    p_state.add_argument("--device", required=True)
    p_state.add_argument("--partition", required=True)
    p_state.add_argument("--mapper", required=True,
                         help="full mapper path, e.g. /dev/mapper/dsfxn_data")
    p_state.add_argument("--mount", required=True)

    p_marker = sub.add_parser(
        "marker-name", help="print the configured folder marker name")
    p_marker.add_argument("--config", default=None)
    p_marker.add_argument("--template", default=SYNC_TEMPLATE_PATH)

    args = parser.parse_args(argv)
    if args.command == "state":
        print(disk_state(args.device, args.partition, args.mapper, args.mount))
    elif args.command == "marker-name":
        print(marker_name_configured(args.config, args.template))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
