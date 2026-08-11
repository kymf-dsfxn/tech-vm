#!/usr/bin/env bash
# =============================================================================
# guest-firstboot.sh
#
# First-boot guest provisioning. The vm-init-firstboot.service oneshot runs this
# once, on the first real boot of the installed system. It provisions the parts
# that need the running kernel, the attached hardware and the VMware tools.
#
# It is deliberately NON-INTERACTIVE. It does not unlock, format or mount the
# encrypted data disk: it only detects what state the disk is in and records it.
# The disk lifecycle is an operator action over SSH, via
# /usr/local/bin/data-disk (init / unlock / lock / status). That keeps boot from
# ever blocking on a passphrase, so unattended vmrun start/stop cycles work with
# the data root simply absent until someone unlocks it.
#
# What it does do: classify the data disk, configure the SMB share that exposes
# it, record the result in the manifest, and disable its own unit.
#
# It is idempotent. A sentinel and per-step guards make a re-run safe.
#
# The platform layer identity (namespace, users, data root) comes from
# /etc/platform.env, written by guest-install.sh at install time.
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
# Mode for the bare mountpoint. Closed on purpose: while the disk is locked the
# mountpoint is an ordinary empty directory on the root filesystem, and anything
# written there lands on the OS disk and is shadowed once the real disk mounts.
DATA_MOUNT_LOCKED_MODE="0500"

SMB_CONF="/etc/samba/smb.conf"
SMB_SHARE="${PLATFORM_NAMESPACE}"

log()  { echo "==> $*"; }
info() { echo "    $*"; }

mkdir -p "${SENTINEL_DIR}"
if [[ -f "${SENTINEL}" ]]; then
    log "First-boot provisioning already done, exiting"
    exit 0
fi

# --- Data disk: detect and record, never touch -------------------------------
# The states match `data-disk status`:
#   absent         no data disk attached
#   uninitialised  disk attached, no LUKS header yet  -> data-disk init
#   locked         LUKS header present, not open      -> data-disk unlock
#   unlocked       mounted (only if something already unlocked it)
log "Detect data disk ${DATA_DEV}"

DATA_STATE="absent"
DATA_LUKS_UUID=""
DATA_UUID=""

install -d -o root -g root -m "${DATA_MOUNT_LOCKED_MODE}" "${DATA_MOUNT}"

if [[ ! -b "${DATA_DEV}" ]]; then
    info "${DATA_DEV} absent, no data disk on this VM"
elif findmnt -rn --mountpoint "${DATA_MOUNT}" > /dev/null 2>&1; then
    DATA_STATE="unlocked"
    DATA_UUID="$(findmnt -rno UUID "${DATA_MOUNT}" || true)"
    info "${DATA_MOUNT} already mounted (filesystem UUID ${DATA_UUID})"
elif [[ -b "${DATA_PART}" ]] && cryptsetup isLuks "${DATA_PART}" 2> /dev/null; then
    DATA_STATE="locked"
    DATA_LUKS_UUID="$(cryptsetup luksUUID "${DATA_PART}" 2> /dev/null || true)"
    info "${DATA_PART} carries a LUKS header (UUID ${DATA_LUKS_UUID})"
    info "Unlock it over SSH: sudo data-disk unlock"
else
    DATA_STATE="uninitialised"
    info "${DATA_DEV} has no LUKS header yet"
    info "Initialise it over SSH: sudo data-disk init"
fi
info "Data disk state: ${DATA_STATE}"

# --- SMB share for the data root ---------------------------------------------
# smbd stays enabled and running whether or not the data disk is unlocked, so
# the host always sees a live SMB server. The share gates itself instead: a
# non-zero `root preexec` with `root preexec close = yes` refuses the connection
# before any I/O can reach the bare mountpoint.
#
# The share password is NOT set here - smbpasswd is interactive, and this script
# must stay non-interactive. The operator sets it over SSH with
# `sudo smbpasswd -a kymf`; `data-disk status` reports whether it is set.
log "Configure the ${SMB_SHARE} SMB share"
if [[ -f "${SMB_CONF}" ]]; then
    if grep -q "^\[${SMB_SHARE}\]" "${SMB_CONF}"; then
        info "[${SMB_SHARE}] already present in ${SMB_CONF}"
    else
        cat >> "${SMB_CONF}" <<EOF

[${SMB_SHARE}]
   comment = Platform data root (encrypted; available only while unlocked)
   path = ${DATA_MOUNT}
   valid users = ${NAMED_USER}
   read only = no
   browseable = yes
   create mask = 0664
   directory mask = 2775
   # Refuse the connection outright unless the LUKS data disk is unlocked.
   # Without this a client could write into the bare mountpoint, landing data on
   # the OS disk where it is shadowed the moment the real disk mounts.
   root preexec = /usr/bin/findmnt --mountpoint ${DATA_MOUNT}
   root preexec close = yes
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
        --luks-name "${DATA_LUKS_NAME}" || info "Manifest update skipped"
fi

# --- Done: sentinel and self-disable -----------------------------------------
date -u +%Y%m%dT%H%M%SZ > "${SENTINEL}"
systemctl disable vm-init-firstboot.service || true
log "First-boot provisioning complete"
if [[ "${DATA_STATE}" != "unlocked" && "${DATA_STATE}" != "absent" ]]; then
    info "The data root ${DATA_MOUNT} is not available yet. Over SSH, run:"
    info "  sudo data-disk status"
fi
