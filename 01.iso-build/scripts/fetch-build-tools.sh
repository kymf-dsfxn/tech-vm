#!/usr/bin/env bash
#
# fetch-build-tools.sh
#
# Fetch the standalone build tools the guest cannot get from apt: syft, shfmt
# and uv. Each download is checksum-verified and staged under
# .cache/build-tools/bin (git-ignored, not committed).
#
# syft and shfmt refetch only when their pins below change. uv defaults to
# "latest", resolved at run time, so a rerun can change the staged uv unless
# --uv-version pins it.
#
# Requirements: curl, tar, sha256sum.
#
# Usage:
#   ./fetch-build-tools.sh [--uv-version <X.Y.Z|latest>] [--out <dir>]
#
# Defaults:
#   --uv-version  latest
#   --out         ../.cache/build-tools

set -euo pipefail

_cprint() { printf '\033[0;3%sm%s\033[0m\n' "$1" "$2" ; }
_die()    { _cprint 1 "$1" >&2 ; exit 1 ; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname "${SCRIPT_DIR}")"          # 01.iso-build

# --- Pins ------------------------------------------------------------------
# syft: keep in sync with build-image.base/build.sh (SYFT_VERSION/SYFT_SHA256).
SYFT_VERSION="1.44.0"
SYFT_SHA256="0e91737aee2b5baf1d255b959630194a302335d848ff97bb07921eb6205b5f5a"
SYFT_URL="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_amd64.tar.gz"

# shfmt: keep in sync with build-image.script (SHFMT_VERSION/SHFMT_SHA256).
SHFMT_VERSION="3.10.0"
SHFMT_SHA256="1f57a384d59542f8fac5f503da1f3ea44242f46dff969569e80b524d64b71dbc"
SHFMT_URL="https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64"

# uv: version resolved at build time unless pinned; integrity checked against
# the release-published .sha256 sidecar.
UV_VERSION="latest"
UV_TRIPLE="x86_64-unknown-linux-gnu"

OUT_DIR="${BUILD_DIR}/.cache/build-tools"

# --- Args ------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uv-version) UV_VERSION="$2"; shift 2 ;;
    --out)        OUT_DIR="$2";    shift 2 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
    *) _die "Unknown argument: $1" ;;
  esac
done

for tool in curl tar sha256sum; do
  command -v "${tool}" >/dev/null 2>&1 || _die "Need '${tool}' on PATH."
done

BIN_DIR="${OUT_DIR}/bin"
mkdir -p "${BIN_DIR}"
OUT_ABS="$(cd "${OUT_DIR}" && pwd)"
BIN_ABS="${OUT_ABS}/bin"
MANIFEST="${OUT_ABS}/build-tools-manifest.txt"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

_cprint 6 "Out: ${OUT_ABS}"

# verify_sha <file> <expected-sha256>
verify_sha() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum "${file}" | cut -d' ' -f1)"
  [[ "${actual}" == "${expected}" ]] \
    || _die "Checksum mismatch for ${file##*/}: expected ${expected}, got ${actual}"
}

# --- syft ------------------------------------------------------------------
_cprint 6 "Fetching syft ${SYFT_VERSION}"
curl -fsSL "${SYFT_URL}" -o "${TMP_DIR}/syft.tar.gz"
verify_sha "${TMP_DIR}/syft.tar.gz" "${SYFT_SHA256}"
tar -xzf "${TMP_DIR}/syft.tar.gz" -C "${BIN_ABS}" syft
chmod 0755 "${BIN_ABS}/syft"

# --- shfmt -----------------------------------------------------------------
_cprint 6 "Fetching shfmt ${SHFMT_VERSION}"
curl -fsSL "${SHFMT_URL}" -o "${BIN_ABS}/shfmt"
verify_sha "${BIN_ABS}/shfmt" "${SHFMT_SHA256}"
chmod 0755 "${BIN_ABS}/shfmt"

# --- uv --------------------------------------------------------------------
if [[ "${UV_VERSION}" == "latest" ]]; then
  # Resolve the newest tag from the releases/latest redirect (no GitHub API).
  redirect="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/astral-sh/uv/releases/latest)"
  UV_VERSION="${redirect##*/}"
  UV_VERSION="${UV_VERSION#v}"
  [[ -n "${UV_VERSION}" ]] || _die "Could not resolve latest uv version."
fi
_cprint 6 "Fetching uv ${UV_VERSION}"
UV_ASSET="uv-${UV_TRIPLE}.tar.gz"
UV_BASE="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
curl -fsSL "${UV_BASE}/${UV_ASSET}"         -o "${TMP_DIR}/uv.tar.gz"
curl -fsSL "${UV_BASE}/${UV_ASSET}.sha256"  -o "${TMP_DIR}/uv.tar.gz.sha256"
# The sidecar is "<sha>  <filename>"; verify against the hash field only.
UV_SHA256="$(cut -d' ' -f1 "${TMP_DIR}/uv.tar.gz.sha256")"
[[ -n "${UV_SHA256}" ]] || _die "Empty uv checksum sidecar."
verify_sha "${TMP_DIR}/uv.tar.gz" "${UV_SHA256}"
# Asset lays out uv-<triple>/{uv,uvx}; flatten both into bin/.
tar -xzf "${TMP_DIR}/uv.tar.gz" --strip-components=1 -C "${BIN_ABS}" \
    "uv-${UV_TRIPLE}/uv" "uv-${UV_TRIPLE}/uvx"
chmod 0755 "${BIN_ABS}/uv" "${BIN_ABS}/uvx"

# --- Manifest --------------------------------------------------------------
{
  printf 'tool\tversion\tsha256\n'
  printf 'syft\t%s\t%s\n'  "${SYFT_VERSION}"  "${SYFT_SHA256}"
  printf 'shfmt\t%s\t%s\n' "${SHFMT_VERSION}" "${SHFMT_SHA256}"
  printf 'uv\t%s\t%s\n'    "${UV_VERSION}"    "${UV_SHA256}"
} > "${MANIFEST}"

_cprint 2 "Staged build tools in ${BIN_ABS}:"
ls -1 "${BIN_ABS}"
_cprint 6 "Manifest: ${MANIFEST}"
_cprint 2 "uv resolved to ${UV_VERSION} (sha256 ${UV_SHA256})"
