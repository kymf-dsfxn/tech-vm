#!/usr/bin/env bash
#
# build-custom-iso.sh
#
# Creates a per-host custom Ubuntu ISO with embedded autoinstall configuration.
# The resulting ISO boots directly into unattended installation without requiring
# an HTTP server or manual GRUB editing.
#
# Usage:
#   ./build-custom-iso.sh <hostname> <base-iso-path> [output-dir]
#
# Example:
#   ./build-custom-iso.sh xd00-lde-0010 ./ubuntu-26.04-live-server-amd64.iso ./output
#
# Requirements:
#   - xorriso
#   - Linux (or WSL on Windows)
#
# The script expects the following directory layout relative to the 00.os-iso-build root:
#   build_version
#   config/<hostname>/autoinstall/user-data
#   config/<hostname>/autoinstall/meta-data
#   config/common/grub.cfg.template
#   config/common/loopback.cfg
#   config/common/image-build-info
#
# The output ISO is named:
#   vm-ubuntu-26.04-<hostname>-<version>-amd64-<timestamp>.iso
#

set -euo pipefail

# --- Colour helpers ---
_cprint() { printf "\033[0;3%sm%s\033[0m\n" "$1" "$2" ; }
_die()    { _cprint 1 "$1" ; exit 1 ; }

# --- Parse arguments ---
if [[ $# -lt 2 ]]; then
  cat <<EOF

build-custom-iso.sh - Create a per-host autoinstall ISO

Usage:  $(basename "$0") <hostname> <base-iso-path> [output-dir]

   <hostname>       Target hostname directory (e.g. xd00-lde-0010)
   <base-iso-path>  Path to stock Ubuntu 26.04 Live Server ISO
   [output-dir]     Where to write the custom ISO (default: ./output)

Example:
   $(basename "$0") xd00-lde-0010 ./ubuntu-26.04-live-server-amd64.iso

EOF
  exit 1
fi

TARGET_HOSTNAME="${1}"
BASE_ISO_PATH="${2}"
OUTPUT_DIR="${3:-./output}"

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_OS_INIT_DIR="$(dirname "${SCRIPT_DIR}")"

CONFIG_DIR="${VM_OS_INIT_DIR}/config"
COMMON_DIR="${CONFIG_DIR}/common"
AUTOINSTALL_DIR="${CONFIG_DIR}/${TARGET_HOSTNAME}/autoinstall"
GRUB_TEMPLATE="${COMMON_DIR}/grub.cfg.template"
LOOPBACK_CFG="${COMMON_DIR}/loopback.cfg"
IMAGE_BUILD_INFO_CMD="${COMMON_DIR}/image-build-info"

# --- Validate inputs ---
if [[ ! -f "${BASE_ISO_PATH}" ]]; then
  _die "Base ISO not found: ${BASE_ISO_PATH}"
fi
if [[ ! -f "${AUTOINSTALL_DIR}/user-data" ]]; then
  _die "Missing autoinstall user-data: ${AUTOINSTALL_DIR}/user-data"
fi
if [[ ! -f "${AUTOINSTALL_DIR}/meta-data" ]]; then
  _die "Missing autoinstall meta-data: ${AUTOINSTALL_DIR}/meta-data"
fi
if [[ ! -f "${GRUB_TEMPLATE}" ]]; then
  _die "Missing grub.cfg template: ${GRUB_TEMPLATE}"
fi
if [[ ! -f "${IMAGE_BUILD_INFO_CMD}" ]]; then
  _die "Missing image-build-info command asset: ${IMAGE_BUILD_INFO_CMD}"
fi
if ! command -v xorriso &>/dev/null; then
  _die "xorriso is not installed. Install with: apt install xorriso"
fi

# --- Load and validate recipe version ---
# One build_version file versions the whole recipe. Same file and format as the
# WSL image build.
VERSION_FILE="${VM_OS_INIT_DIR}/build_version"
if [[ ! -f "${VERSION_FILE}" ]]; then
  _die "Required version file not found: ${VERSION_FILE} (create it with a semantic version, e.g. 1.0.0)"
fi
IMAGE_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
if [[ ! "${IMAGE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  _die "Invalid version '${IMAGE_VERSION}' in ${VERSION_FILE} (expected N.N.N)"
fi

# --- Build metadata (ISO assembly time) ---
# ISO8601 basic, filename-safe, UTC. Same format as the WSL image build.
# This marks the moment the ISO artefact was produced. The guest records its own
# INSTALL_TIMESTAMP during autoinstall, because the ISO cannot know install time.
BUILD_TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
IMAGE_TAG_PREFIX="26.04"
IMAGE_ARCH="amd64"
IMAGE_INFO="vm-ubuntu-${IMAGE_TAG_PREFIX}-${TARGET_HOSTNAME}-${IMAGE_VERSION}-${IMAGE_ARCH}"

# --- Derived names ---
# ISO name mirrors the WSL artefact shape: <image-info>-<timestamp>.iso
BASE_ISO_NAME="$(basename "${BASE_ISO_PATH}")"
CUSTOM_ISO_NAME="${IMAGE_INFO}-${BUILD_TIMESTAMP}.iso"

_cprint 6 "Build info: ${IMAGE_INFO}"
_cprint 6 "Timestamp:  ${BUILD_TIMESTAMP}"
_cprint 6 "Version:    ${IMAGE_VERSION} (from ${VERSION_FILE})"

# Working directory (temporary)
WORK_DIR="$(mktemp -d)"
EXTRACT_DIR="${WORK_DIR}/extract"

# Ensure cleanup on exit
cleanup() {
  if [[ -d "${WORK_DIR}" ]]; then
    chmod -R u+w "${WORK_DIR}" 2>/dev/null || true
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

# --- Step 1: Extract base ISO ---
_cprint 6 "Extracting base ISO: ${BASE_ISO_NAME}"
xorriso -osirrox on -indev "${BASE_ISO_PATH}" -extract / "${EXTRACT_DIR}" 2>/dev/null
chmod -R u+w "${EXTRACT_DIR}"
_cprint 2 "Extraction complete"

# --- Step 2: Replace GRUB configuration ---
_cprint 6 "Replacing GRUB configuration"

if [[ -f "${EXTRACT_DIR}/boot/grub/grub.cfg" ]]; then
  cp "${GRUB_TEMPLATE}" "${EXTRACT_DIR}/boot/grub/grub.cfg"
  _cprint 2 "Replaced: boot/grub/grub.cfg"
else
  _die "Stock ISO missing boot/grub/grub.cfg - unexpected ISO layout"
fi

if [[ -f "${EXTRACT_DIR}/boot/grub/loopback.cfg" ]]; then
  cp "${LOOPBACK_CFG}" "${EXTRACT_DIR}/boot/grub/loopback.cfg"
  _cprint 2 "Replaced: boot/grub/loopback.cfg"
fi

# --- Step 3: Create autoinstall directory on ISO ---
_cprint 6 "Emplacing autoinstall configs for: ${TARGET_HOSTNAME}"

mkdir -p "${EXTRACT_DIR}/autoinstall"
cp "${AUTOINSTALL_DIR}/user-data" "${EXTRACT_DIR}/autoinstall/user-data"
cp "${AUTOINSTALL_DIR}/meta-data" "${EXTRACT_DIR}/autoinstall/meta-data"
touch "${EXTRACT_DIR}/autoinstall/vendor-data"

_cprint 2 "Emplaced: autoinstall/user-data, meta-data, vendor-data"

# --- Step 3b: Emplace build metadata for the guest ---
# The late-commands in user-data read these from /cdrom/autoinstall during
# install and bake them into the installed system. This is the ISO equivalent of
# the WSL build baking metadata straight into the image.
_cprint 6 "Emplacing build metadata"

printf '%s\n' \
  "IMAGE_INFO=${IMAGE_INFO}" \
  "BUILD_TIMESTAMP=${BUILD_TIMESTAMP}" \
  > "${EXTRACT_DIR}/autoinstall/build-info.env"
cp "${IMAGE_BUILD_INFO_CMD}" "${EXTRACT_DIR}/autoinstall/image-build-info"

_cprint 2 "Emplaced: autoinstall/build-info.env, image-build-info"

# --- Step 4: Update md5sum.txt if present ---
if [[ -f "${EXTRACT_DIR}/md5sum.txt" ]]; then
  _cprint 6 "Updating md5sum.txt"

  # Update checksum for grub.cfg
  grub_md5=$(cd "${EXTRACT_DIR}" && md5sum "./boot/grub/grub.cfg" | cut -d' ' -f1)
  sed -i -e "s|^.*[[:space:]] ./boot/grub/grub.cfg|${grub_md5}  ./boot/grub/grub.cfg|" "${EXTRACT_DIR}/md5sum.txt"

  # Update checksum for loopback.cfg if it was in the original checksums
  if grep -q "loopback.cfg" "${EXTRACT_DIR}/md5sum.txt"; then
    loop_md5=$(cd "${EXTRACT_DIR}" && md5sum "./boot/grub/loopback.cfg" | cut -d' ' -f1)
    sed -i -e "s|^.*[[:space:]] ./boot/grub/loopback.cfg|${loop_md5}  ./boot/grub/loopback.cfg|" "${EXTRACT_DIR}/md5sum.txt"
  fi

  _cprint 2 "Checksums updated"
fi

# --- Step 5: Extract boot images from original ISO ---
_cprint 6 "Extracting boot images from original ISO"

MBR_IMG="${WORK_DIR}/mbr.img"
EFI_IMG="${WORK_DIR}/efi.img"

# Extract MBR boot code (first 446 bytes)
dd bs=1 count=446 if="${BASE_ISO_PATH}" of="${MBR_IMG}" status=none

EFI_START=""
EFI_SECTORS=""

# Method 1: fdisk can parse the hybrid GPT embedded in the ISO
FDISK_OUT=$(fdisk -l "${BASE_ISO_PATH}" 2>/dev/null || true)
if [[ -n "${FDISK_OUT}" ]]; then
  EFI_LINE=$(echo "${FDISK_OUT}" | grep -i 'EFI' | head -1 || true)
  if [[ -n "${EFI_LINE}" ]]; then
    EFI_START=$(echo "${EFI_LINE}" | awk '{ print $2 }')
    EFI_SECTORS=$(echo "${EFI_LINE}" | awk '{ print $4 }')
  fi
fi

# Method 2: use xorriso to report the appended partition info
if [[ -z "${EFI_START}" || -z "${EFI_SECTORS}" ]]; then
  _cprint 3 "fdisk could not locate EFI partition, trying xorriso -report_el_torito"
  XORRISO_REPORT=$(xorriso -indev "${BASE_ISO_PATH}" -report_el_torito as_mkisofs 2>/dev/null || true)
  # Find line containing: --interval:local_fs:STARTd-ENDd::
  # e.g. -append_partition 2 0xEF --interval:local_fs:2656d-10847d::'file.iso'
  APPEND_LINE=$(echo "${XORRISO_REPORT}" | grep 'append_partition' | head -1 || true)
  if [[ -n "${APPEND_LINE}" ]]; then
    # Extract STARTd-ENDd using sed capture group (no PCRE needed)
    INTERVAL=$(echo "${APPEND_LINE}" | sed -n 's/.*--interval:local_fs:\([0-9]*d-[0-9]*d\).*/\1/p')
    if [[ -n "${INTERVAL}" ]]; then
      # Parse: "2656d-10847d" -> start=2656, end=10847
      EFI_START=$(echo "${INTERVAL}" | sed 's/d-.*//')
      EFI_END=$(echo "${INTERVAL}" | sed 's/.*-//; s/d$//')
      if [[ -n "${EFI_START}" && -n "${EFI_END}" ]]; then
        EFI_SECTORS=$(( EFI_END - EFI_START + 1 ))
      fi
    fi
  fi
  # Debug: show what xorriso reported if we still failed
  if [[ -z "${EFI_START}" || -z "${EFI_SECTORS}" ]]; then
    _cprint 3 "xorriso append_partition line: ${APPEND_LINE:-<not found>}"
  fi
fi

if [[ -n "${EFI_START}" && -n "${EFI_SECTORS}" ]]; then
  dd bs=512 skip="${EFI_START}" count="${EFI_SECTORS}" if="${BASE_ISO_PATH}" of="${EFI_IMG}" status=none
  _cprint 2 "Extracted MBR (446 bytes) and EFI partition (start=${EFI_START}, sectors=${EFI_SECTORS})"
else
  echo "fdisk output:"
  echo "${FDISK_OUT:-<empty>}"
  echo "xorriso report:"
  echo "${XORRISO_REPORT:-<empty>}"
  _die "Could not locate EFI partition in base ISO. Is this a valid Ubuntu Live Server ISO?"
fi

# --- Step 6: Rebuild ISO with xorriso ---
_cprint 6 "Building custom ISO: ${CUSTOM_ISO_NAME}"

mkdir -p "${OUTPUT_DIR}"
CUSTOM_ISO_PATH="${OUTPUT_DIR}/${CUSTOM_ISO_NAME}"

# Remove existing output if present
rm -f "${CUSTOM_ISO_PATH}"

# Determine ISO volume label (max 32 chars for ISO 9660)
ISO_LABEL="Ubuntu2604_${TARGET_HOSTNAME}"

xorriso -as mkisofs \
  -V "${ISO_LABEL}" \
  --grub2-mbr "${MBR_IMG}" \
  --protective-msdos-label \
  -partition_cyl_align off \
  -partition_offset 16 \
  --mbr-force-bootable \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${EFI_IMG}" \
  -appended_part_as_gpt \
  -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
  -c '/boot.catalog' \
  -b '/boot/grub/i386-pc/eltorito.img' \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --grub2-boot-info \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2_start_s_size_d:all::' \
  -no-emul-boot \
  -o "${CUSTOM_ISO_PATH}" "${EXTRACT_DIR}" 2>&1

_cprint 2 "Custom ISO created: ${CUSTOM_ISO_PATH}"

# --- Step 7: Report ---
echo
_cprint 6 "=== Build Complete ==="
_cprint 2 "  Host:   ${TARGET_HOSTNAME}"
_cprint 2 "  Info:   ${IMAGE_INFO}"
_cprint 2 "  Built:  ${BUILD_TIMESTAMP}"
_cprint 2 "  Ver:    ${IMAGE_VERSION}"
_cprint 2 "  ISO:    ${CUSTOM_ISO_PATH}"
_cprint 2 "  Size:   $(du -h "${CUSTOM_ISO_PATH}" | cut -f1)"
echo
_cprint 6 "Boot this ISO in VMware - autoinstall will begin automatically after 5s timeout."
_cprint 6 "No HTTP server or manual GRUB editing required."
