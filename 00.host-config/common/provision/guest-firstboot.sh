#!/usr/bin/env bash
# =============================================================================
# guest-firstboot.sh - first-boot provisioning, run once by the
# vm-init-firstboot.service oneshot.
#
# Deliberately NON-INTERACTIVE: it classifies the data disk and records the
# state, but never formats, unlocks or mounts it, and never touches sync state
# - boot must not block on a passphrase, and identity/config cannot exist yet.
# It configures the SMB share, records the result in the manifest, and disables
# its own unit. Idempotent: a sentinel and per-step guards make a re-run safe.
# Platform identity comes from /etc/platform.env, written by guest-install.sh.
# Design: capability.encrypted-datadisk.md.
# =============================================================================

set -euo pipefail

VM_INIT_DIR="/opt/vm-init"
SENTINEL_DIR="/var/lib/vm-init"
SENTINEL="${SENTINEL_DIR}/firstboot.done"

# Platform layer identity. Every step below depends on it, so a missing file is
# fatal rather than defaulted.
PLATFORM_ENV="/etc/platform.env"
[[ -r "${PLATFORM_ENV}" ]] || {
    echo "FATAL: ${PLATFORM_ENV} missing or unreadable" >&2
    exit 1
}
# shellcheck source=/dev/null
. "${PLATFORM_ENV}"

NAMED_USER="kymf"

DATA_DEV="/dev/sdb"
DATA_PART="${DATA_DEV}1"
DATA_LUKS_NAME="${PLATFORM_NAMESPACE}_data"
DATA_MOUNT="${PLATFORM_DATA_ROOT}"
# Bare mountpoint mode while locked (the bare mountpoint invariant).
DATA_MOUNT_LOCKED_MODE="0500"

SMB_CONF="/etc/samba/smb.conf"
SMB_SHARE="${PLATFORM_NAMESPACE}"
# One level below the data root, so the sibling state directory is never
# served.
SMB_PATH="${PLATFORM_DATA_SHARE:-${DATA_MOUNT}/share}"

# Marker name resolved by the shared module (platform_node.py owns the
# fallback literal), so there is one source of truth. The `|| true` is
# load-bearing under `set -euo pipefail`: a failure here (no template, no
# module) must not kill the script before the SMB share, the manifest and the
# sentinel - the fallback below is what should happen there.
SYNC_TEMPLATE="/etc/syncthing/node-config.xml.template"
MARKER_NAME="$(python3 /usr/local/bin/platform_node.py marker-name \
    --template "${SYNC_TEMPLATE}" 2> /dev/null || true)"
MARKER_NAME="${MARKER_NAME:-.dsfxn-share-marker}"

# Syncthing facts for the manifest; identity and config are unknowable at
# first boot and recorded as null.
SYNC_DROPIN="/etc/systemd/system/syncthing@${PLATFORM_SYNC_USER:-stsync}.service.d/data-disk.conf"
SYNC_HOME="${PLATFORM_DATA_STATE:-${DATA_MOUNT}/.platform}/syncthing"

log()  { echo "==> $*"; }
info() { echo "    $*"; }

mkdir -p "${SENTINEL_DIR}"
if [[ -f "${SENTINEL}" ]]; then
    log "First-boot provisioning already done, exiting"
    exit 0
fi

# --- Data disk: detect and record, never touch -------------------------------
# Classification is the shared six-state classifier in platform_node.py, the
# same code data-disk runs, so every surface speaks one vocabulary:
# absent / unlocked / opened / uninitialised / unknown / locked.
log "Detect data disk ${DATA_DEV}"

DATA_LUKS_UUID=""
DATA_UUID=""

install -d -o root -g root -m "${DATA_MOUNT_LOCKED_MODE}" "${DATA_MOUNT}"

DATA_STATE="$(python3 /usr/local/bin/platform_node.py state \
    --device "${DATA_DEV}" --partition "${DATA_PART}" \
    --mapper "/dev/mapper/${DATA_LUKS_NAME}" --mount "${DATA_MOUNT}" \
    2> /dev/null || echo unknown)"

case "${DATA_STATE}" in
    absent)
        info "${DATA_DEV} absent, no data disk on this VM"
        ;;
    unlocked)
        DATA_UUID="$(findmnt -rno UUID "${DATA_MOUNT}" || true)"
        info "${DATA_MOUNT} already mounted (filesystem UUID ${DATA_UUID})"
        ;;
    opened)
        info "${DATA_LUKS_NAME} is open but not mounted"
        info "Mount it over SSH: sudo data-disk unlock"
        ;;
    uninitialised)
        info "${DATA_DEV} has no LUKS header yet"
        info "Initialise it over SSH: sudo data-disk init"
        ;;
    unknown)
        info "${DATA_PART} could not be classified"
        ;;
    locked)
        DATA_LUKS_UUID="$(cryptsetup luksUUID "${DATA_PART}" 2> /dev/null || true)"
        info "${DATA_PART} carries a LUKS header (UUID ${DATA_LUKS_UUID})"
        info "Unlock it over SSH: sudo data-disk unlock"
        ;;
esac
info "Data disk state: ${DATA_STATE}"

# --- SMB share for the data root ---------------------------------------------
# smbd stays up whether or not the disk is unlocked; the share stanza gates
# itself with the root preexec mount check. The password is NOT set here -
# smbpasswd is interactive - the operator sets it over SSH
# (`sudo smbpasswd -a kymf`).
log "Configure the ${SMB_SHARE} SMB share"
if [[ -f "${SMB_CONF}" ]]; then
    if grep -q "^\[${SMB_SHARE}\]" "${SMB_CONF}"; then
        info "[${SMB_SHARE}] already present in ${SMB_CONF}"
    else
        cat >> "${SMB_CONF}" <<EOF

[${SMB_SHARE}]
   comment = Platform data share (encrypted; available only while unlocked)
   path = ${SMB_PATH}
   valid users = ${NAMED_USER}
   read only = no
   browseable = yes
   create mask = 0664
   directory mask = 2775
   # Refuse the connection unless the data disk is unlocked. The test is on
   # the mount: a bare mountpoint has no share to serve.
   root preexec = /usr/bin/findmnt --mountpoint ${DATA_MOUNT}
   root preexec close = yes
   # Hide the Syncthing folder marker and refuse to delete it.
   veto files = /${MARKER_NAME}/
EOF
        info "Appended [${SMB_SHARE}] to ${SMB_CONF}"
    fi
    if testparm -s > /dev/null 2>&1; then
        info "smb.conf validates"
    else
        info "WARNING: testparm reported problems with ${SMB_CONF}"
    fi
    systemctl enable --now smbd || info "smbd enable/start skipped"
    info "smbd $(systemctl is-active smbd 2> /dev/null || true)"
else
    info "${SMB_CONF} absent, samba not installed, skipping share config"
fi

# --- Record the result in the manifest ---------------------------------------
if [[ -f "${VM_INIT_DIR}/make-manifest.py" ]]; then
    log "Record first-boot result in the manifest"
    python3 "${VM_INIT_DIR}/make-manifest.py" firstboot \
        --out /etc/image-build-manifest.json \
        --data-device "${DATA_DEV}" \
        --data-partition "${DATA_PART}" \
        --data-state "${DATA_STATE}" \
        --data-uuid "${DATA_UUID}" \
        --luks-uuid "${DATA_LUKS_UUID}" \
        --luks-name "${DATA_LUKS_NAME}" \
        --sync-template "${SYNC_TEMPLATE}" \
        --sync-dropin "${SYNC_DROPIN}" \
        --sync-user "${PLATFORM_SYNC_USER:-stsync}" \
        --sync-home "${SYNC_HOME}" || info "Manifest update skipped"
fi

# --- Done: sentinel and self-disable -----------------------------------------
date -u +%Y%m%dT%H%M%SZ > "${SENTINEL}"
systemctl disable vm-init-firstboot.service || true
log "First-boot provisioning complete"
if [[ "${DATA_STATE}" != "unlocked" && "${DATA_STATE}" != "absent" ]]; then
    info "The data root ${DATA_MOUNT} is not available yet. Over SSH, run:"
    info "  sudo data-disk status"
fi
