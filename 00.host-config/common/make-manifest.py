#!/usr/bin/env python3
"""make-manifest.py - build and complete the VM image build manifest.

The manifest records what this ISO-build approach put on the machine. It has two
moments, the same split the build metadata uses for its timestamps:

  plan       On the build host, at ISO assembly. Records what the ISO intends to
             install: identity, version, timestamp, payload files, staged
             packages, and tarballs. Written onto the ISO.

  apply      In the guest, at install. Copies the planned manifest, then records
             what actually landed: the installed version of each package as dpkg
             reports it, the platform namespace the guest was built for, and the
             install timestamp.

  firstboot  In the guest, at first boot. Adds the runtime results: which state
             the encrypted data disk was found in, and its identifiers. First
             boot never unlocks the disk, so the filesystem UUID is only present
             if something had already unlocked it.

The manifest is a single JSON file. It is read by `image-build-info --manifest`.
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone


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
    p_apply.add_argument("--out", required=True)
    p_apply.set_defaults(func=cmd_apply)

    p_fb = sub.add_parser("firstboot", help="guest: record first-boot result")
    p_fb.add_argument("--out", required=True)
    p_fb.add_argument("--data-device", default="", help="data disk block device")
    p_fb.add_argument("--data-partition", default="", help="data disk partition")
    p_fb.add_argument("--data-state", default="",
                      choices=["", "absent", "uninitialised", "locked", "opened", "unlocked"],
                      help="data disk state as guest-firstboot.sh classified it")
    p_fb.add_argument("--luks-name", default="", help="dm-crypt mapper name")
    p_fb.add_argument("--luks-uuid", default="", help="LUKS header UUID")
    p_fb.add_argument("--data-uuid", default="",
                      help="ext4 filesystem UUID (only knowable while unlocked)")
    p_fb.set_defaults(func=cmd_firstboot)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())
