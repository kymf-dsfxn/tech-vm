#!/usr/bin/env bash
#
# run.sh
#
# Integration test for the database client toolchain the VM ships: the SAP ASE
# Open Client, the SAP SQL Anywhere client (the client side of IQ), and the
# PostgreSQL client and libpq. It answers one question - would a developer on
# a freshly built VM be able to reach these databases and compile against them.
#
# It runs against a container of the target Ubuntu release rather than a VM, so
# it needs no ISO, no install and no root on the host. The repo is mounted
# read-only; the container is thrown away afterwards.
#
# The SAP stanzas are read out of guest-install.sh at run time, not copied, so
# this test starts failing the moment that file drifts from what it asserts.
#
# Requirements: docker or podman. ~2 GB of pulls and unpacking on a cold run.
#
# Usage:
#   ./run.sh [--image <ubuntu-image>] [--keep]
#
# Defaults:
#   --image   ubuntu:26.04    the release the ISO is built from
#   --keep    leave the container in place afterwards, to poke at it

set -euo pipefail

_cprint() { printf "\033[0;3%sm%s\033[0m\n" "$1" "$2" ; }
_die()    { _cprint 1 "$1" ; exit 1 ; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# .../00.host-config/common/tests/db-clients -> the repo root
REPO_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

IMAGE="ubuntu:26.04"
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)   IMAGE="$2"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
    *) _die "Unknown argument: $1" ;;
  esac
done

# Pick a container engine, the same way build-package-repo.sh does.
ENGINE=""
for candidate in docker podman; do
  if command -v "${candidate}" &> /dev/null; then ENGINE="${candidate}"; break; fi
done
[[ -n "${ENGINE}" ]] || _die "Need docker or podman to run this test."

# The payload bundles are the subject of the test, not an optional extra.
PAYLOAD_TGZ="${REPO_DIR}/00.host-config/common/payload/extra_tgz"
for bundle in sap.ase-client.*.tgz sap.sql-anywhere-client.*.tgz; do
  # shellcheck disable=SC2086  # the glob is the point
  compgen -G "${PAYLOAD_TGZ}/${bundle}" > /dev/null \
    || _die "Missing payload bundle ${bundle} in ${PAYLOAD_TGZ}"
done

# Git Bash rewrites both halves of a -v argument into Windows paths. Hand it
# the Windows source itself and switch the rewrite off, so one script serves
# Linux, WSL and Git Bash alike.
MOUNT_SRC="${REPO_DIR}"
if command -v cygpath &> /dev/null; then
  MOUNT_SRC="$(cygpath -w "${REPO_DIR}")"
  export MSYS_NO_PATHCONV=1
fi

NAME="tech-vm-db-clients-test"
RM_FLAG="--rm"
[[ "${KEEP}" -eq 1 ]] && RM_FLAG=""

_cprint 6 "Engine: ${ENGINE}"
_cprint 6 "Image:  ${IMAGE}"
_cprint 6 "Repo:   ${REPO_DIR}"
echo

"${ENGINE}" rm -f "${NAME}" &> /dev/null || true
# A failing test is a result, not a reason to abort before reporting it, so
# the status is captured rather than left to `set -e`.
STATUS=0
# shellcheck disable=SC2086  # RM_FLAG is deliberately unquoted, it may be empty
"${ENGINE}" run ${RM_FLAG} --name "${NAME}" \
  -v "${MOUNT_SRC}:/repo:ro" \
  "${IMAGE}" \
  bash /repo/00.host-config/common/tests/db-clients/in-container.sh || STATUS=$?

echo
if [[ ${STATUS} -eq 0 ]]; then
  _cprint 2 "=== db client toolchain: PASS ==="
else
  _cprint 1 "=== db client toolchain: FAIL (exit ${STATUS}) ==="
fi
[[ "${KEEP}" -eq 1 ]] && _cprint 6 "Container kept as '${NAME}' (${ENGINE} start -ai ${NAME})"
exit "${STATUS}"
