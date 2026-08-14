#!/usr/bin/env python3
"""make-manifest.py - build and complete the VM image build manifest.

  plan       Build host, at ISO assembly: what the ISO intends to install.
  apply      Guest, at install: what actually landed, per dpkg.
  firstboot  Guest, at first boot: data-disk state and Syncthing mechanism.

Identity/config live on the encrypted disk, unknowable at first boot, so
they are recorded as null rather than guessed.
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

# platform_node sits beside this file when staged into /opt/vm-init, and in
# ../guest-bin in the repo tree (where the build host runs `plan`).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "guest-bin"))
import platform_node  # noqa: E402


def _now():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _read_packages(path):
    names = []
    if not path or not os.path.isfile(path):
        return names
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith("#"):
                names.append(line)
    return names


def _repo_versions(repo_dir):
    """Map package name -> version from the staged repo's Packages file."""
    versions = {}
    packages_file = os.path.join(repo_dir, "Packages")
    if not os.path.isfile(packages_file):
        return versions
    name = None
    with open(packages_file, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith("Package:"):
                name = line.split(":", 1)[1].strip()
            elif line.startswith("Version:") and name:
                versions[name] = line.split(":", 1)[1].strip()
                name = None
    return versions


def _list_payload(payload_dir):
    files = []
    if not payload_dir or not os.path.isdir(payload_dir):
        return files
    for root, _dirs, names in os.walk(payload_dir):
        for fname in names:
            abs_path = os.path.join(root, fname)
            rel = os.path.relpath(abs_path, payload_dir)
            files.append({"path": rel, "bytes": os.path.getsize(abs_path)})
    return sorted(files, key=lambda item: item["path"])


def _dpkg_version(pkg):
    try:
        out = subprocess.run(
            ["dpkg-query", "-W", "-f=${Version}", pkg],
            capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def _file_present(path):
    return bool(path) and os.path.isfile(path)


def _user_present(name):
    """Is this account in /etc/passwd?"""
    if not name or not os.path.isfile("/etc/passwd"):
        return None
    with open("/etc/passwd", encoding="utf-8", errors="replace") as handle:
        return any(line.split(":", 1)[0] == name for line in handle)


def _sync_state(args):
    """Syncthing state on this node. The mechanism on the OS disk is knowable;
    identity/config on the encrypted disk are null until it is mounted."""
    identity = config = None
    if args.data_state == "unlocked" and args.sync_home:
        identity = os.path.isfile(os.path.join(args.sync_home, "key.pem"))
        config = os.path.isfile(os.path.join(args.sync_home, "config.xml"))
    return {
        "syncthing_version": _dpkg_version("syncthing"),
        "template_present": _file_present(args.sync_template),
        "dropin_present": _file_present(args.sync_dropin),
        "sync_user_present": _user_present(args.sync_user),
        "identity_present": identity,
        "config_present": config,
    }


def cmd_plan(args):
    packages = _read_packages(args.packages)
    repo_versions = _repo_versions(args.repo) if args.repo else {}
    manifest = {
        "schema": "vm-image-manifest/1",
        "recipe": {
            "image_info": args.image_info,
            "version": args.version,
            "build_timestamp": args.build_timestamp,
        },
        "planned": {
            "packages": [
                {"name": name, "version": repo_versions.get(name)}
                for name in packages
            ],
            "payload": _list_payload(args.payload),
            "tarballs": [
                os.path.basename(p) for p in (args.tarball or [])
            ],
        },
        "applied": None,
        "firstboot": None,
    }
    _write(manifest, args.out)


def cmd_apply(args):
    manifest = _load(args.planned)
    packages = _read_packages(args.packages)
    manifest["applied"] = {
        "install_timestamp": _now(),
        "platform_namespace": args.platform_namespace or None,
        "packages": [
            {"name": name, "version": _dpkg_version(name)}
            for name in packages
        ],
        # Installed from payload/extra_deb/, not packages.list, so nothing above
        # records them; without this the manifest cannot name their versions.
        "payload_packages": [
            {"name": name, "version": _dpkg_version(name)}
            for name in (args.payload_package or [])
        ],
    }
    _write(manifest, args.out)


def cmd_firstboot(args):
    manifest = _load(args.out)
    manifest["firstboot"] = {
        "firstboot_timestamp": _now(),
        "data_disk": {
            "device": args.data_device or None,
            "partition": args.data_partition or None,
            "state": args.data_state or "unknown",
            "luks_name": args.luks_name or None,
            "luks_uuid": args.luks_uuid or None,
            "filesystem_uuid": args.data_uuid or None,
        },
        "sync": _sync_state(args),
    }
    _write(manifest, args.out)


def _load(path):
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    return {"schema": "vm-image-manifest/1"}


def _write(manifest, path):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=False)
        handle.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_plan = sub.add_parser("plan", help="build host: write the planned manifest")
    p_plan.add_argument("--image-info", required=True)
    p_plan.add_argument("--version", required=True)
    p_plan.add_argument("--build-timestamp", required=True)
    p_plan.add_argument("--packages", required=True)
    p_plan.add_argument("--repo", help="staged apt repo dir (for versions)")
    p_plan.add_argument("--payload", help="payload dir to list")
    p_plan.add_argument("--tarball", action="append", help="tarball path (repeatable)")
    p_plan.add_argument("--out", required=True)
    p_plan.set_defaults(func=cmd_plan)

    p_apply = sub.add_parser("apply", help="guest: record applied packages")
    p_apply.add_argument("--planned", required=True)
    p_apply.add_argument("--packages", required=True)
    p_apply.add_argument("--platform-namespace", default="",
                         help="platform_namespace label this guest was built for")
    p_apply.add_argument("--payload-package", action="append", default=[],
                         metavar="NAME",
                         help="package installed from payload/extra_deb/ rather "
                              "than packages.list (repeatable)")
    p_apply.add_argument("--out", required=True)
    p_apply.set_defaults(func=cmd_apply)

    p_fb = sub.add_parser("firstboot", help="guest: record first-boot result")
    p_fb.add_argument("--out", required=True)
    p_fb.add_argument("--data-device", default="", help="data disk block device")
    p_fb.add_argument("--data-partition", default="", help="data disk partition")
    p_fb.add_argument("--data-state", default="",
                      choices=[""] + list(platform_node.STATES),
                      help="data disk state, the six-state vocabulary shared "
                           "with data-disk and guest-firstboot.sh")
    p_fb.add_argument("--luks-name", default="", help="dm-crypt mapper name")
    p_fb.add_argument("--luks-uuid", default="", help="LUKS header UUID")
    p_fb.add_argument("--data-uuid", default="",
                      help="ext4 filesystem UUID (only knowable while unlocked)")
    p_fb.add_argument("--sync-template", default="",
                      help="path to the Syncthing node config template")
    p_fb.add_argument("--sync-dropin", default="",
                      help="path to the syncthing@.service data-disk drop-in")
    p_fb.add_argument("--sync-user", default="",
                      help="Syncthing service account name")
    p_fb.add_argument("--sync-home", default="",
                      help="STHOMEDIR on the encrypted disk (only readable while "
                           "unlocked)")
    p_fb.set_defaults(func=cmd_firstboot)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
