#!/usr/bin/env bash
#
# build-custom-iso.sh
#
# Create a per-host custom Ubuntu ISO with embedded autoinstall configuration
# and a full offline guest payload. The resulting ISO boots into an unattended
# install that needs no network: it installs every package from an on-ISO apt
# repository, places the guest payload, and provisions the guest through
# guest-install.sh (install time) and guest-firstboot.sh (first boot).
#
# Layout (post-restructure):
#   tech-vm/
#     00.host-config/                 <- inputs (config + payload + scripts)
#       build_version
#       common/{grub.cfg.template,loopback.cfg,image-build-info,
#               guest-install.sh,guest-firstboot.sh,make-manifest.py,
#               vm-init-firstboot.service,packages.list,payload/...}
#       <host>/autoinstall/{user-data,meta-data}
#       <host>/payload/...            <- optional per-host payload overrides
#     01.iso-build/
#       scripts/build-custom-iso.sh   <- this script
#       scripts/build-package-repo.sh
#       .cache/apt-repo/              <- offline repo (built separately)
#       output/<host>/                <- built ISOs + latest.txt
#
# Usage:
#   ./build-custom-iso.sh <hostname> <base-iso-path> [output-dir]
#
# The offline apt repo must exist before this runs. Build it once with:
#   ./build-package-repo.sh
# or point APT_REPO_DIR at an existing repo.
#
# Requirements: xorriso, python3, and the apt repo from build-package-repo.sh.

set -euo pipefail

# --- Colour helpers ---
_cprint() { printf "\033[0;3%sm%s\033[0m\n" "$1" "$2" ; }
_die()    { _cprint 1 "$1" ; exit 1 ; }

# --- Parse arguments ---
if [[ $# -lt 2 ]]; then
  cat <<EOF

build-custom-iso.sh - Create a per-host offline autoinstall ISO

Usage:  $(basename "$0") <hostname> <base-iso-path> [output-dir]

   <hostname>       Target host directory (e.g. xd00-lde-0010)
   <base-iso-path>  Path to stock Ubuntu 26.04 Live Server ISO
   [output-dir]     Where to write the custom ISO (default: ../output)

Environment:
   APT_REPO_DIR     Offline apt repo dir (default: ../.cache/apt-repo)

EOF
  exit 1
fi

TARGET_HOSTNAME="${1}"
BASE_ISO_PATH="${2}"

# --- Resolve paths (new numbered layout) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname "${SCRIPT_DIR}")"          # 01.iso-build
TECH_VM_DIR="$(dirname "${BUILD_DIR}")"         # tech-vm
HOST_CONFIG_DIR="${TECH_VM_DIR}/00.host-config"

OUTPUT_DIR="${3:-${BUILD_DIR}/output}"
APT_REPO_DIR="${APT_REPO_DIR:-${BUILD_DIR}/.cache/apt-repo}"
BUILD_TOOLS_DIR="${BUILD_TOOLS_DIR:-${BUILD_DIR}/.cache/build-tools}"

COMMON_DIR="${HOST_CONFIG_DIR}/common"
AUTOINSTALL_DIR="${HOST_CONFIG_DIR}/${TARGET_HOSTNAME}/autoinstall"
HOST_PAYLOAD_DIR="${HOST_CONFIG_DIR}/${TARGET_HOSTNAME}/payload"
COMMON_PAYLOAD_DIR="${COMMON_DIR}/payload"

GRUB_TEMPLATE="${COMMON_DIR}/grub.cfg.template"
LOOPBACK_CFG="${COMMON_DIR}/loopback.cfg"
VERSION_FILE="${HOST_CONFIG_DIR}/build_version"

# Common guest-side assets staged under /autoinstall/vm-init on the ISO
COMMON_ASSETS=(
  "image-build-info"
  "guest-install.sh"
  "guest-firstboot.sh"
  "make-manifest.py"
  "vm-init-firstboot.service"
  "packages.list"
)

# --- Validate inputs ---
[[ -f "${BASE_ISO_PATH}" ]]        || _die "Base ISO not found: ${BASE_ISO_PATH}"
[[ -f "${AUTOINSTALL_DIR}/user-data" ]] || _die "Missing user-data: ${AUTOINSTALL_DIR}/user-data"
[[ -f "${AUTOINSTALL_DIR}/meta-data" ]] || _die "Missing meta-data: ${AUTOINSTALL_DIR}/meta-data"
[[ -f "${GRUB_TEMPLATE}" ]]        || _die "Missing grub template: ${GRUB_TEMPLATE}"
[[ -f "${VERSION_FILE}" ]]         || _die "Missing version file: ${VERSION_FILE}"
for asset in "${COMMON_ASSETS[@]}"; do
  [[ -f "${COMMON_DIR}/${asset}" ]] || _die "Missing common asset: ${COMMON_DIR}/${asset}"
done
[[ -d "${APT_REPO_DIR}" && -f "${APT_REPO_DIR}/Packages" ]] \
  || _die "Offline apt repo not found at ${APT_REPO_DIR}. Build it: ${SCRIPT_DIR}/build-package-repo.sh"
[[ -d "${BUILD_TOOLS_DIR}/bin" ]] \
  || _die "Build tools not found at ${BUILD_TOOLS_DIR}. Fetch them: ${SCRIPT_DIR}/fetch-build-tools.sh"
command -v xorriso &>/dev/null || _die "xorriso not installed. apt install xorriso"
command -v python3 &>/dev/null || _die "python3 not installed."

# --- Version, build metadata, names ---
IMAGE_VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"
[[ "${IMAGE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || _die "Invalid version '${IMAGE_VERSION}' in ${VERSION_FILE} (expected N.N.N)"

BUILD_TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
IMAGE_TAG_PREFIX="26.04"
IMAGE_ARCH="amd64"
IMAGE_INFO="vm-ubuntu-${IMAGE_TAG_PREFIX}-${TARGET_HOSTNAME}-${IMAGE_VERSION}-${IMAGE_ARCH}"
CUSTOM_ISO_NAME="${IMAGE_INFO}-${BUILD_TIMESTAMP}.iso"

_cprint 6 "Build info: ${IMAGE_INFO}"
_cprint 6 "Timestamp:  ${BUILD_TIMESTAMP}"
_cprint 6 "Apt repo:   ${APT_REPO_DIR}"

WORK_DIR="$(mktemp -d)"
EXTRACT_DIR="${WORK_DIR}/extract"
cleanup() {
  if [[ -d "${WORK_DIR}" ]]; then
    chmod -R u+w "${WORK_DIR}" 2>/dev/null || true
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

# --- Step 1: Extract base ISO ---
_cprint 6 "Extracting base ISO"
xorriso -osirrox on -indev "${BASE_ISO_PATH}" -extract / "${EXTRACT_DIR}" 2>/dev/null
chmod -R u+w "${EXTRACT_DIR}"

# --- Step 2: Replace GRUB configuration ---
_cprint 6 "Replacing GRUB configuration"
[[ -f "${EXTRACT_DIR}/boot/grub/grub.cfg" ]] \
  || _die "Stock ISO missing boot/grub/grub.cfg - unexpected layout"
cp "${GRUB_TEMPLATE}" "${EXTRACT_DIR}/boot/grub/grub.cfg"
[[ -f "${EXTRACT_DIR}/boot/grub/loopback.cfg" && -f "${LOOPBACK_CFG}" ]] \
  && cp "${LOOPBACK_CFG}" "${EXTRACT_DIR}/boot/grub/loopback.cfg"

# --- Step 3: Autoinstall control files ---
_cprint 6 "Emplacing autoinstall control for ${TARGET_HOSTNAME}"
mkdir -p "${EXTRACT_DIR}/autoinstall"
cp "${AUTOINSTALL_DIR}/user-data" "${EXTRACT_DIR}/autoinstall/user-data"
cp "${AUTOINSTALL_DIR}/meta-data" "${EXTRACT_DIR}/autoinstall/meta-data"
touch "${EXTRACT_DIR}/autoinstall/vendor-data"

# --- Step 4: Stage the vm-init guest payload ---
# Everything the guest needs sits under one root: /cdrom/autoinstall/vm-init.
# The late-commands copy this whole tree into /target/opt/vm-init.
_cprint 6 "Staging vm-init payload"
VM_INIT_STAGE="${EXTRACT_DIR}/autoinstall/vm-init"
mkdir -p "${VM_INIT_STAGE}"

# Common guest scripts and assets
for asset in "${COMMON_ASSETS[@]}"; do
  cp "${COMMON_DIR}/${asset}" "${VM_INIT_STAGE}/${asset}"
done
chmod 0755 "${VM_INIT_STAGE}/guest-install.sh" \
           "${VM_INIT_STAGE}/guest-firstboot.sh" \
           "${VM_INIT_STAGE}/make-manifest.py" \
           "${VM_INIT_STAGE}/image-build-info"

# Payload: common first, then per-host overrides win (the create-bundle.py merge)
[[ -d "${COMMON_PAYLOAD_DIR}" ]] && cp -a "${COMMON_PAYLOAD_DIR}/." "${VM_INIT_STAGE}/"
[[ -d "${HOST_PAYLOAD_DIR}" ]]   && cp -a "${HOST_PAYLOAD_DIR}/."   "${VM_INIT_STAGE}/"

# Offline apt repo
cp -a "${APT_REPO_DIR}" "${VM_INIT_STAGE}/apt-repo"

# Standalone build tools (syft, shfmt, uv) fetched by fetch-build-tools.sh
cp -a "${BUILD_TOOLS_DIR}" "${VM_INIT_STAGE}/build-tools"

# Build metadata (identity + assembly timestamp)
printf '%s\n' \
  "IMAGE_INFO=${IMAGE_INFO}" \
  "BUILD_TIMESTAMP=${BUILD_TIMESTAMP}" \
  > "${VM_INIT_STAGE}/build-info.env"

# Planned manifest
python3 "${COMMON_DIR}/make-manifest.py" plan \
  --image-info "${IMAGE_INFO}" \
  --version "${IMAGE_VERSION}" \
  --build-timestamp "${BUILD_TIMESTAMP}" \
  --packages "${COMMON_DIR}/packages.list" \
  --repo "${APT_REPO_DIR}" \
  --payload "${VM_INIT_STAGE}" \
  --out "${VM_INIT_STAGE}/build-manifest.json"

_cprint 2 "Payload staged: $(du -sh "${VM_INIT_STAGE}" | cut -f1)"

# --- Step 5: Update md5sum.txt for the replaced GRUB (as before) ---
if [[ -f "${EXTRACT_DIR}/md5sum.txt" ]]; then
  grub_md5=$(cd "${EXTRACT_DIR}" && md5sum "./boot/grub/grub.cfg" | cut -d' ' -f1)
  sed -i -e "s|^.*[[:space:]] ./boot/grub/grub.cfg|${grub_md5}  ./boot/grub/grub.cfg|" "${EXTRACT_DIR}/md5sum.txt"
  if grep -q "loopback.cfg" "${EXTRACT_DIR}/md5sum.txt"; then
    loop_md5=$(cd "${EXTRACT_DIR}" && md5sum "./boot/grub/loopback.cfg" | cut -d' ' -f1)
    sed -i -e "s|^.*[[:space:]] ./boot/grub/loopback.cfg|${loop_md5}  ./boot/grub/loopback.cfg|" "${EXTRACT_DIR}/md5sum.txt"
  fi
fi

# --- Step 6: Extract boot images from the original ISO ---
_cprint 6 "Extracting boot images"
MBR_IMG="${WORK_DIR}/mbr.img"
EFI_IMG="${WORK_DIR}/efi.img"
dd bs=1 count=446 if="${BASE_ISO_PATH}" of="${MBR_IMG}" status=none

EFI_START="" ; EFI_SECTORS=""
FDISK_OUT=$(fdisk -l "${BASE_ISO_PATH}" 2>/dev/null || true)
if [[ -n "${FDISK_OUT}" ]]; then
  EFI_LINE=$(echo "${FDISK_OUT}" | grep -i 'EFI' | head -1 || true)
  if [[ -n "${EFI_LINE}" ]]; then
    EFI_START=$(echo "${EFI_LINE}" | awk '{ print $2 }')
    EFI_SECTORS=$(echo "${EFI_LINE}" | awk '{ print $4 }')
  fi
fi
if [[ -z "${EFI_START}" || -z "${EFI_SECTORS}" ]]; then
  XORRISO_REPORT=$(xorriso -indev "${BASE_ISO_PATH}" -report_el_torito as_mkisofs 2>/dev/null || true)
  APPEND_LINE=$(echo "${XORRISO_REPORT}" | grep 'append_partition' | head -1 || true)
  if [[ -n "${APPEND_LINE}" ]]; then
    INTERVAL=$(echo "${APPEND_LINE}" | sed -n 's/.*--interval:local_fs:\([0-9]*d-[0-9]*d\).*/\1/p')
    if [[ -n "${INTERVAL}" ]]; then
      EFI_START=$(echo "${INTERVAL}" | sed 's/d-.*//')
      EFI_END=$(echo "${INTERVAL}" | sed 's/.*-//; s/d$//')
      [[ -n "${EFI_START}" && -n "${EFI_END}" ]] && EFI_SECTORS=$(( EFI_END - EFI_START + 1 ))
    fi
  fi
fi
[[ -n "${EFI_START}" && -n "${EFI_SECTORS}" ]] \
  || _die "Could not locate EFI partition in base ISO."
dd bs=512 skip="${EFI_START}" count="${EFI_SECTORS}" if="${BASE_ISO_PATH}" of="${EFI_IMG}" status=none
_cprint 2 "Extracted MBR and EFI partition (start=${EFI_START}, sectors=${EFI_SECTORS})"

# --- Step 7: Rebuild ISO ---
HOST_OUTPUT_DIR="${OUTPUT_DIR}/${TARGET_HOSTNAME}"
mkdir -p "${HOST_OUTPUT_DIR}"
CUSTOM_ISO_PATH="${HOST_OUTPUT_DIR}/${CUSTOM_ISO_NAME}"
rm -f "${CUSTOM_ISO_PATH}"
ISO_LABEL="Ubuntu2604_${TARGET_HOSTNAME}"

_cprint 6 "Building ISO: ${CUSTOM_ISO_NAME}"
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

# Stable pointer for stage 02 (02.vm-create reads this)
printf '%s\n' "${CUSTOM_ISO_NAME}" > "${HOST_OUTPUT_DIR}/latest.txt"

# --- Step 8: Report ---
echo
_cprint 6 "=== Build Complete ==="
_cprint 2 "  Host:   ${TARGET_HOSTNAME}"
_cprint 2 "  Info:   ${IMAGE_INFO}"
_cprint 2 "  Built:  ${BUILD_TIMESTAMP}"
_cprint 2 "  ISO:    ${CUSTOM_ISO_PATH}"
_cprint 2 "  Latest: ${HOST_OUTPUT_DIR}/latest.txt"
_cprint 2 "  Size:   $(du -h "${CUSTOM_ISO_PATH}" | cut -f1)"
echo
_cprint 6 "Offline autoinstall: no network needed at install time."
