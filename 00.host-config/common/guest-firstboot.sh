#!/usr/bin/env bash
# =============================================================================
# guest-firstboot.sh
#
# First-boot guest provisioning. The vm-init-firstboot.service oneshot runs this
# once, on the first real boot of the installed system. It provisions the parts
# that need the running kernel, the attached hardware and the VMware tools:
# the data disk and the HGFS shared folder. It then records the result in the
# manifest and disables its own unit.
#
# It is idempotent. A sentinel and per-step guards make a re-run safe.
# =============================================================================

set -euo pipefail

VM_INIT_DIR="/opt/vm-init"
SENTINEL_DIR="/var/lib/vm-init"
SENTINEL="${SENTINEL_DIR}/firstboot.done"

PLATFORM_CORE_USERNAME="qfree"
NAMED_USER="kymf"

DATA_DEV="/dev/sdb"
DATA_MOUNT="/srv/qfree"

HGFS_MOUNT="/mnt/s/local-data"
HGFS_SHARE=".host:/local-data"

log()  { echo "==> $*"; }
info() { echo "    $*"; }

mkdir -p "${SENTINEL_DIR}"
if [[ -f "${SENTINEL}" ]]; then
    log "First-boot provisioning already done, exiting"
    exit 0
fi

DATA_UUID=""
HGFS_STATUS="not-mounted"

# --- Data disk /dev/sdb -> /srv/qfree ----------------------------------------
log "Provision data disk ${DATA_DEV} -> ${DATA_MOUNT}"
if findmnt -rn "${DATA_MOUNT}" > /dev/null 2>&1; then
    info "${DATA_MOUNT} already mounted, skipping"
    DATA_UUID="$(findmnt -rno UUID "${DATA_MOUNT}" || true)"
elif [[ -b "${DATA_DEV}" ]]; then
    if [[ ! -b "${DATA_DEV}1" ]]; then
        info "Partitioning ${DATA_DEV}"
        printf 'label: gpt\n, , L\n' | sfdisk "${DATA_DEV}"
        info "Formatting ${DATA_DEV}1 as ext4"
        mkfs.ext4 -F "${DATA_DEV}1"
    fi
    DATA_UUID="$(blkid -s UUID -o value "${DATA_DEV}1")"
    install -d -o "${PLATFORM_CORE_USERNAME}" -g "${PLATFORM_CORE_USERNAME}" \
        -m 0755 "${DATA_MOUNT}"
    if ! grep -q "${DATA_MOUNT}" /etc/fstab; then
        echo "UUID=${DATA_UUID} ${DATA_MOUNT} ext4 defaults 0 2" >> /etc/fstab
    fi
    systemctl daemon-reload
    mount "${DATA_MOUNT}"
    info "${DATA_MOUNT} mounted (UUID ${DATA_UUID})"
else
    info "${DATA_DEV} absent, skipping data disk"
fi

# --- HGFS shared folder ------------------------------------------------------
log "Configure HGFS mount ${HGFS_SHARE} -> ${HGFS_MOUNT}"
HGFS_UID="$(id -u "${NAMED_USER}")"
HGFS_GID="$(id -g "${NAMED_USER}")"
HGFS_LINE="${HGFS_SHARE} ${HGFS_MOUNT} fuse.vmhgfs-fuse defaults,allow_other,uid=${HGFS_UID},gid=${HGFS_GID},umask=022 0 0"
install -d -m 0755 "${HGFS_MOUNT}"
if ! grep -qF "${HGFS_MOUNT}" /etc/fstab 2>/dev/null; then
    echo "${HGFS_LINE}" >> /etc/fstab
    info "Added fstab entry for ${HGFS_MOUNT}"
fi
systemctl daemon-reload
if mount "${HGFS_MOUNT}" 2>/dev/null; then
    HGFS_STATUS="mounted"
    info "${HGFS_MOUNT} mounted"
else
    HGFS_STATUS="deferred"
    info "Host share not available yet, mount deferred to fstab"
fi

# --- Record the result in the manifest ---------------------------------------
if [[ -f "${VM_INIT_DIR}/make-manifest.py" ]]; then
    log "Record first-boot result in the manifest"
    python3 "${VM_INIT_DIR}/make-manifest.py" firstboot \
        --out /etc/image-build-manifest.json \
        --data-uuid "${DATA_UUID}" \
        --hgfs-status "${HGFS_STATUS}" || info "Manifest update skipped"
fi

# --- Done: sentinel and self-disable -----------------------------------------
date -u +%Y%m%dT%H%M%SZ > "${SENTINEL}"
systemctl disable vm-init-firstboot.service || true
log "First-boot provisioning complete"
