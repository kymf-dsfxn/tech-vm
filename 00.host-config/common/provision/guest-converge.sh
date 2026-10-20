#!/usr/bin/env bash
# =============================================================================
# guest-converge.sh - bring a running guest up to this checkout's recipe.
#
# Run as root, on the guest, from a checkout of this repository (the share
# carries one). It is NOT staged onto the ISO: a fresh build installs through
# guest-install.sh and needs no converge. Use it on a VM built from an older
# recipe when a rebuild is not yet wanted.
#
# It does not re-run guest-install.sh, which creates users and is not safe to
# repeat. It does four things, each safe to repeat:
#   1. apt-installs every packages.list entry that is missing (needs network).
#   2. Runs the SAP/ODBC/JDBC stanzas of guest-install.sh verbatim, cut out
#      between two section headers, with the payload read from this checkout
#      instead of /opt/vm-init/extra_tgz. One source of truth: when a stanza
#      changes in guest-install.sh, converge changes with it.
#   3. Refreshes the operator commands (data-disk, platform_node.py).
#   4. Records the converge in /etc/image-build-manifest.json.
# Config files owned by the operator or hand-edited are never touched.
#
# Usage: sudo guest-converge.sh [--dry-run]
# =============================================================================

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUEST_INSTALL="${COMMON}/provision/guest-install.sh"
PACKAGES_LIST="${COMMON}/packages.list"
PAYLOAD_TGZ="${COMMON}/payload/extra_tgz"
VERSION_FILE="${COMMON}/../build_version"
MANIFEST="/etc/image-build-manifest.json"

# Same literal headers as tests/db-clients/in-container.sh; if one is renamed,
# extraction finds nothing and converge stops rather than doing nothing.
STANZA_BEGIN='# --- SAP ASE Open Client + SDK'
STANZA_END='# --- Standalone build tools'

log()  { echo "==> $*"; }
info() { echo "    $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
[[ -r "${GUEST_INSTALL}" && -r "${PACKAGES_LIST}" ]] || die "not a tech-vm checkout: ${COMMON}"
[[ -r /etc/platform.env ]] || die "/etc/platform.env missing: not a platform guest"
RECIPE_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"

# --- 1. Packages ---------------------------------------------------------------
log "Packages missing against packages.list"
mapfile -t WANT < <(grep -vE '^\s*(#|$)' "${PACKAGES_LIST}")
MISSING=()
for pkg in "${WANT[@]}"; do
    dpkg -s "${pkg}" > /dev/null 2>&1 || MISSING+=("${pkg}")
done
if ((${#MISSING[@]})); then
    info "Missing: ${MISSING[*]}"
    if ((DRY_RUN)); then
        info "dry run: would apt-get install"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends "${MISSING[@]}"
    fi
else
    info "none"
fi

# --- 2. Install stanzas, verbatim ----------------------------------------------
log "Extract install stanzas from guest-install.sh"
STANZAS="$(mktemp)"
trap 'rm -f "${STANZAS}"' EXIT
{
    echo 'set -euo pipefail'
    printf 'PAYLOAD_TGZ=%q\n' "${PAYLOAD_TGZ}"
    echo 'log()  { echo "==> $*"; }'
    echo 'info() { echo "    $*"; }'
    awk -v b="${STANZA_BEGIN}" -v e="${STANZA_END}" \
        'index($0,b)==1 {on=1} index($0,e)==1 {on=0} on' "${GUEST_INSTALL}"
} > "${STANZAS}"
for needle in ASE_TARBALL ASE_ODBC_TARBALL SQLANY_TARBALL IQ_TARBALL JCONN_JAR; do
    grep -q "${needle}" "${STANZAS}" || die "stanza extraction lost ${needle}: have the section headers moved?"
done
info "$(wc -l < "${STANZAS}") lines"
if ((DRY_RUN)); then
    info "dry run: would run the stanzas against ${PAYLOAD_TGZ}"
else
    bash "${STANZAS}"
fi

# --- 3. Operator commands ------------------------------------------------------
# Installed as a pair: data-disk imports platform_node.py.
log "Refresh operator commands"
for f in platform_node.py data-disk; do
    if cmp -s "${COMMON}/guest-bin/${f}" "/usr/local/bin/${f}"; then
        info "${f} current"
    elif ((DRY_RUN)); then
        info "${f} differs: would install"
    else
        install -m 0755 "${COMMON}/guest-bin/${f}" "/usr/local/bin/${f}"
        info "${f} updated"
    fi
done

# --- 4. Manifest ---------------------------------------------------------------
if ((DRY_RUN)); then
    log "dry run complete, nothing changed"
    exit 0
fi
log "Record converge to ${RECIPE_VERSION} in the manifest"
python3 "${COMMON}/provision/make-manifest.py" converge \
    --out "${MANIFEST}" --version "${RECIPE_VERSION}" \
    --packages "${PACKAGES_LIST}"
log "Converge complete"
