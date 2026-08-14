#!/usr/bin/env bash
#
# build-package-repo.sh
#
# Build the offline apt repository the guest installs from: the dependency
# closure of packages.list, staged as .deb files with an apt Packages index.
# Resolution runs in a container matching the target release so the closure
# is computed against the right archive.
#
# Requirements: docker or podman.
#
# Usage:
#   ./build-package-repo.sh [--image <ubuntu-image>] [--packages <list>] [--out <dir>]
#
# Defaults:
#   --image     ubuntu:26.04
#   --packages  ../../00.host-config/common/packages.list
#   --out       ../.cache/apt-repo

set -euo pipefail

_die() { printf '\033[0;31m%s\033[0m\n' "$1" >&2 ; exit 1 ; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname "${SCRIPT_DIR}")"
TECH_VM_DIR="$(dirname "${BUILD_DIR}")"

IMAGE="ubuntu:26.04"
PACKAGES_LIST="${TECH_VM_DIR}/00.host-config/common/packages.list"
OUT_DIR="${BUILD_DIR}/.cache/apt-repo"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)    IMAGE="$2"; shift 2 ;;
    --packages) PACKAGES_LIST="$2"; shift 2 ;;
    --out)      OUT_DIR="$2"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
    *) _die "Unknown argument: $1" ;;
  esac
done

[[ -f "${PACKAGES_LIST}" ]] || _die "Package list not found: ${PACKAGES_LIST}"

# Pick a container engine
ENGINE=""
for candidate in docker podman; do
  if command -v "${candidate}" &>/dev/null; then ENGINE="${candidate}"; break; fi
done
[[ -n "${ENGINE}" ]] || _die "Need docker or podman to fetch the package closure."

# Space-joined package names (drop comments and blanks)
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "${PACKAGES_LIST}")
[[ "${#PKGS[@]}" -gt 0 ]] || _die "No packages in ${PACKAGES_LIST}"

mkdir -p "${OUT_DIR}"
OUT_ABS="$(cd "${OUT_DIR}" && pwd)"

echo "Engine:   ${ENGINE}"
echo "Image:    ${IMAGE}"
echo "Packages: ${PKGS[*]}"
echo "Out:      ${OUT_ABS}"

# Inside the container: update, install dpkg-dev for the indexer, download the
# closure of the requested packages into the mounted repo, then build the index.
"${ENGINE}" run --rm -v "${OUT_ABS}:/repo" "${IMAGE}" bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends dpkg-dev
  rm -rf /repo/pool && mkdir -p /repo/pool
  apt-get install -y --no-install-recommends --download-only \
    -o Dir::Cache::archives="/repo/pool" '"${PKGS[*]}"'
  # Drop apt lock/partial artefacts, keep only .deb
  find /repo/pool -maxdepth 1 -type f ! -name "*.deb" -delete || true
  rm -rf /repo/pool/partial || true
  cd /repo
  dpkg-scanpackages pool /dev/null > Packages
  gzip -9c Packages > Packages.gz
  echo "Staged $(ls -1 /repo/pool/*.deb | wc -l) .deb files"
'

echo "Offline repo ready at ${OUT_ABS}"
echo "Packages index: ${OUT_ABS}/Packages"
