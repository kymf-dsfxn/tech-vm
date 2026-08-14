#!/usr/bin/env bash
# =============================================================================
# guest-install.sh - install-time guest provisioning.
#
# Run inside the target by the autoinstall late-commands (`curtin in-target`):
# a chroot on the installed root, guest paths, no network needed. Installs
# packages from the on-ISO repo, places the payload, establishes the platform
# identity (/etc/platform.env), and installs mechanism only - it never touches
# the data disk and never creates sync state. Detection is guest-firstboot.sh's
# job; identity and config are the operator's, on the encrypted disk. Design:
# capability.encrypted-datadisk.md, capability.data-synchronisation.md.
#
# Idempotent enough to re-run during development; meant to run once.
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

VM_INIT_DIR="/opt/vm-init"
APT_REPO_DIR="${VM_INIT_DIR}/apt-repo"
PAYLOAD_CFG="${VM_INIT_DIR}/extra_cfg"
PAYLOAD_DEB="${VM_INIT_DIR}/extra_deb"
PAYLOAD_TGZ="${VM_INIT_DIR}/extra_tgz"
PAYLOAD_KEYS="${VM_INIT_DIR}/extra_keys"
PACKAGES_LIST="${VM_INIT_DIR}/packages.list"
BUILD_TOOLS_DIR="${VM_INIT_DIR}/build-tools"

NAMED_USER="kymf"

# --- Platform layer identity -------------------------------------------------
# One label, the platform_namespace, derives the platform users, groups and
# data root. This is the single place the label is written; everything
# guest-side reads it back from /etc/platform.env. UID/GID are pinned so a data
# disk carried between nodes keeps valid ownership across a rename.
PLATFORM_ENV="/etc/platform.env"
PLATFORM_NAMESPACE="dsfxn"
PLATFORM_CORE_USER="${PLATFORM_NAMESPACE}"
PLATFORM_CORE_UID=500
PLATFORM_NODE_MGMT_USER="${PLATFORM_NAMESPACE}_node_mgmt"
PLATFORM_NODE_MGMT_UID=501
PLATFORM_SYNC_USER="stsync"
PLATFORM_SYNC_UID=502
PLATFORM_DATA_ROOT="/srv/${PLATFORM_NAMESPACE}"
# The share replicates and is served over SMB; the state directory holds each
# consumer's own state. data-disk creates both, sync-node reads them from here.
PLATFORM_DATA_SHARE="${PLATFORM_DATA_ROOT}/share"
PLATFORM_DATA_STATE="${PLATFORM_DATA_ROOT}/.platform"

log()  { echo "==> $*"; }
info() { echo "    $*"; }

# --- Identity from the hostname the installer already set --------------------
HOSTNAME_FULL="$(cat /etc/hostname)"
# e.g. xd00-lde-0010 -> INSTANCE_ENV=xd00-lde, HOST_ID=0010
HOST_ID="${HOSTNAME_FULL##*-}"
INSTANCE_ENV="${HOSTNAME_FULL%-*}"

log "Guest install starting for ${HOSTNAME_FULL}"

# --- APT: no recommends, then point APT at the on-ISO repo -------------------
log "Configure APT (offline, on-ISO repo)"
# apt-minimal.conf carries the no-recommends/no-suggests pair.
install -m 0644 "${PAYLOAD_CFG}/apt-minimal.conf" /etc/apt/apt.conf.d/99minimal

# Local flat repo. [trusted=yes] because the debs are staged, not signed.
printf 'deb [trusted=yes] file://%s ./\n' "${APT_REPO_DIR}" \
    > /etc/apt/sources.list.d/vm-init-local.list
# Offline: only the local repo is reachable. Do not fail if other sources 404.
apt-get -o Acquire::Retries=0 update || true

# --- Recovery user: shift to UID/GID 404 -------------------------------------
log "Shift recovery user to UID/GID 404"
usermod  -u 404 recovery
groupmod -g 404 recovery
find /home/recovery -user 1000 -exec chown 404:404 {} + 2>/dev/null || true
find /var/mail      -user 1000 -exec chown 404:404 {} + 2>/dev/null || true

# --- Disable snapd and swap --------------------------------------------------
log "Disable snapd and swap"
systemctl mask snapd.socket snapd.service || true
sed -i '/[[:space:]]swap[[:space:]]/d' /etc/fstab

# --- Packages (all from the on-ISO repo) -------------------------------------
log "Install packages from the on-ISO repo"
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "${PACKAGES_LIST}")
info "Installing: ${PKGS[*]}"
apt-get install -y --no-install-recommends "${PKGS[@]}"

# --- Locale ------------------------------------------------------------------
log "Harden locale to en_US.UTF-8, TZ=UTC"
printf 'export LANG=en_US.UTF-8\nexport LC_ALL=en_US.UTF-8\nexport TZ=UTC\n' \
    > /etc/profile.d/locale.sh
chmod 0644 /etc/profile.d/locale.sh
printf '\nexport LANG=en_US.UTF-8\nexport LC_ALL=en_US.UTF-8\nexport TZ=UTC\n' \
    >> /etc/skel/.bashrc
locale-gen en_US.UTF-8
find /usr/share/i18n/locales -mindepth 1 -maxdepth 1 -type f \
    ! -name 'en_US' ! -name 'C' ! -name 'POSIX' -exec rm -f {} +

# --- Users -------------------------------------------------------------------
log "Create platform users (namespace ${PLATFORM_NAMESPACE})"

# Record the platform layer identity first, so it is on disk for the guest-side
# consumers even if a later step of this script fails. Plain KEY=value: safe to
# source from bash, parseable by anything else.
cat > "${PLATFORM_ENV}" <<EOF
# Platform layer identity for this node. Written by guest-install.sh.
# One label, the platform_namespace, derives the rest.
PLATFORM_NAMESPACE=${PLATFORM_NAMESPACE}
PLATFORM_CORE_USER=${PLATFORM_CORE_USER}
PLATFORM_CORE_UID=${PLATFORM_CORE_UID}
PLATFORM_NODE_MGMT_USER=${PLATFORM_NODE_MGMT_USER}
PLATFORM_NODE_MGMT_UID=${PLATFORM_NODE_MGMT_UID}
PLATFORM_SYNC_USER=${PLATFORM_SYNC_USER}
PLATFORM_SYNC_UID=${PLATFORM_SYNC_UID}
PLATFORM_DATA_ROOT=${PLATFORM_DATA_ROOT}
PLATFORM_DATA_SHARE=${PLATFORM_DATA_SHARE}
PLATFORM_DATA_STATE=${PLATFORM_DATA_STATE}
PLATFORM_NAMED_USER=${NAMED_USER}
EOF
chmod 0644 "${PLATFORM_ENV}"
info "Wrote ${PLATFORM_ENV}"

# Platform layer shared user & group (${PLATFORM_CORE_USER}, 500)
groupadd --gid "${PLATFORM_CORE_UID}" "${PLATFORM_CORE_USER}"
useradd --comment "${PLATFORM_CORE_USER}" --create-home --system --shell /bin/bash \
    --uid "${PLATFORM_CORE_UID}" --gid "${PLATFORM_CORE_UID}" --groups sudo \
    "${PLATFORM_CORE_USER}"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${PLATFORM_CORE_USER}" \
    > "/etc/sudoers.d/010-${PLATFORM_CORE_USER}-nopw"
chmod 0440 "/etc/sudoers.d/010-${PLATFORM_CORE_USER}-nopw"

# Platform layer node management user & group (${PLATFORM_NODE_MGMT_USER}, 501)
groupadd --gid "${PLATFORM_NODE_MGMT_UID}" "${PLATFORM_NODE_MGMT_USER}"
useradd --comment "${PLATFORM_NODE_MGMT_USER}" --create-home --system --shell /bin/bash \
    --uid "${PLATFORM_NODE_MGMT_UID}" --gid "${PLATFORM_NODE_MGMT_UID}" \
    --groups "${PLATFORM_CORE_USER}",sudo "${PLATFORM_NODE_MGMT_USER}"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${PLATFORM_NODE_MGMT_USER}" \
    > "/etc/sudoers.d/010-${PLATFORM_NODE_MGMT_USER}-nopw"
chmod 0440 "/etc/sudoers.d/010-${PLATFORM_NODE_MGMT_USER}-nopw"
install --directory --mode=0700 \
    --owner="${PLATFORM_NODE_MGMT_USER}" --group="${PLATFORM_NODE_MGMT_USER}" \
    "/home/${PLATFORM_NODE_MGMT_USER}/.ssh"
printf '# PLACEHOLDER\n' > "/home/${PLATFORM_NODE_MGMT_USER}/.ssh/authorized_keys"
chmod 0600 "/home/${PLATFORM_NODE_MGMT_USER}/.ssh/authorized_keys"
chown "${PLATFORM_NODE_MGMT_USER}:${PLATFORM_NODE_MGMT_USER}" \
    "/home/${PLATFORM_NODE_MGMT_USER}/.ssh/authorized_keys"

# Syncthing service account, not a login. Private primary group keeps its own
# state 0700 under a group nothing else joins; supplementary
# ${PLATFORM_CORE_USER} is what lets it write into the share. /nonexistent as
# home is what the packaged unit expects (InaccessiblePaths=-/nonexistent);
# STHOMEDIR in the drop-in names the real home on the encrypted disk.
groupadd --gid "${PLATFORM_SYNC_UID}" "${PLATFORM_SYNC_USER}"
useradd --comment "syncthing service account" --system \
    --uid "${PLATFORM_SYNC_UID}" --gid "${PLATFORM_SYNC_UID}" \
    --groups "${PLATFORM_CORE_USER}" \
    --shell /usr/sbin/nologin --home-dir /nonexistent --no-create-home \
    "${PLATFORM_SYNC_USER}"

# Named user: a person, not a platform concept. Only the group it joins is
# derived.
useradd --comment "${NAMED_USER}" --create-home --shell /bin/bash \
    --groups "${PLATFORM_CORE_USER}",sudo "${NAMED_USER}"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${NAMED_USER}" \
    > "/etc/sudoers.d/011-${NAMED_USER}-nopw"
chmod 0440 "/etc/sudoers.d/011-${NAMED_USER}-nopw"
install --directory --mode=0700 --owner="${NAMED_USER}" --group="${NAMED_USER}" \
    "/home/${NAMED_USER}/.ssh"
install -m 0600 -o "${NAMED_USER}" -g "${NAMED_USER}" \
    "${PAYLOAD_KEYS}/${NAMED_USER}.pub" \
    "/home/${NAMED_USER}/.ssh/authorized_keys"

# --- JAVA_HOME ---------------------------------------------------------------
log "Set JAVA_HOME"
JAVA_HOME_DISCOVERED="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
printf 'export JAVA_HOME=%s\nexport PATH="${JAVA_HOME}/bin:${PATH}"\n' \
    "${JAVA_HOME_DISCOVERED}" > /etc/profile.d/java.sh
chmod 0644 /etc/profile.d/java.sh
info "JAVA_HOME=${JAVA_HOME_DISCOVERED}"

# --- Maven (from payload tarball) --------------------------------------------
log "Install Maven"
MAVEN_TARBALL="$(find "${PAYLOAD_TGZ}" -maxdepth 1 -name 'apache-maven-*-bin.tar.gz' | head -1)"
if [[ -n "${MAVEN_TARBALL}" ]]; then
    mkdir -p /opt/maven
    tar -xzf "${MAVEN_TARBALL}" --strip-components=1 -C /opt/maven
    printf 'export MAVEN_HOME=/opt/maven\nexport PATH="/opt/maven/bin:${PATH}"\n' \
        > /etc/profile.d/maven.sh
    chmod 0644 /etc/profile.d/maven.sh
    info "Maven at /opt/maven"

    # settings.xml for the named user
    install --directory --owner="${NAMED_USER}" --group="${NAMED_USER}" \
        "/home/${NAMED_USER}/.m2"
    install -m 0644 --owner="${NAMED_USER}" --group="${NAMED_USER}" \
        "${PAYLOAD_CFG}/settings.xml" "/home/${NAMED_USER}/.m2/settings.xml"
    info "settings.xml installed for ${NAMED_USER}"
else
    info "No Maven tarball in payload, skipping"
fi

# --- Liquibase (from payload tarball) ----------------------------------------
log "Install Liquibase"
LIQUIBASE_TARBALL="$(find "${PAYLOAD_TGZ}" -maxdepth 1 -name 'liquibase-*.tar.gz' | head -1)"
if [[ -n "${LIQUIBASE_TARBALL}" ]]; then
    mkdir -p /opt/liquibase
    tar -xzf "${LIQUIBASE_TARBALL}" -C /opt/liquibase
    printf 'export PATH="/opt/liquibase:${PATH}"\n' > /etc/profile.d/liquibase.sh
    chmod 0644 /etc/profile.d/liquibase.sh
    info "Liquibase at /opt/liquibase"
else
    info "No Liquibase tarball in payload, skipping"
fi

# --- Standalone build tools (syft, shfmt, uv) --------------------------------
# Not apt packages: fetched at ISO-build time by fetch-build-tools.sh, copied
# straight into /usr/local/bin.
log "Install standalone build tools"
if [[ -d "${BUILD_TOOLS_DIR}/bin" ]]; then
    install -m 0755 "${BUILD_TOOLS_DIR}/bin/"* /usr/local/bin/
    info "Installed: $(find "${BUILD_TOOLS_DIR}/bin" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
else
    info "No build-tools payload, skipping (syft/shfmt/uv will be absent)"
fi

# --- Rootless podman socket (Docker-API compatibility) -----------------------
# Per-user podman socket for Docker-API clients (Testcontainers, fabric8).
# `--global` writes user-unit symlinks only, so it is safe in this chroot; the
# socket activates per user at login. Why on the VM and not wsl-kf: the
# project's build-container socket decision note.
log "Enable rootless podman socket for all users"
if [[ -f /usr/lib/systemd/user/podman.socket ]]; then
    systemctl --global enable podman.socket || info "podman.socket enable failed"
    # Point Docker-API clients at the rootless socket. $(id -u) stays literal so
    # it resolves per-user at login.
    printf 'export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"\n' \
        > /etc/profile.d/podman-docker-host.sh
    chmod 0644 /etc/profile.d/podman-docker-host.sh
    info "podman.socket enabled globally; DOCKER_HOST set via profile.d"
else
    info "podman.socket unit not found, skipping"
fi

# --- Company CA (from payload .deb) ------------------------------------------
log "Install company CA certificate"
CA_DEB="$(find "${PAYLOAD_DEB}" -maxdepth 1 -name 'ca-certificates-qfree_*_all.deb' | head -1)"
if [[ -n "${CA_DEB}" ]]; then
    apt-get install -y "${CA_DEB}"
    info "Installed ${CA_DEB##*/}"
else
    info "No CA .deb in payload, skipping"
fi

# --- Syncthing (from payload .deb) -------------------------------------------
# The filename is the version pin (not in packages.list on purpose). Mechanism
# only: no identity, no rendered config - the operator creates those on the
# encrypted disk. Unit left disabled; `data-disk unlock` starts it. Rationale:
# capability.data-synchronisation.md.
log "Install Syncthing from the payload .deb"
SYNCTHING_DEB="$(find "${PAYLOAD_DEB}" -maxdepth 1 -name 'syncthing_*_amd64.deb' | head -1)"
if [[ -n "${SYNCTHING_DEB}" ]]; then
    apt-get install -y "${SYNCTHING_DEB}"
    install -m 0755 "${VM_INIT_DIR}/sync-node" /usr/local/bin/sync-node
    install -d -m 0755 /etc/syncthing
    install -m 0644 "${PAYLOAD_CFG}/syncthing/node-config.xml.template" \
        /etc/syncthing/node-config.xml.template
    install -d -m 0755 \
        "/etc/systemd/system/syncthing@${PLATFORM_SYNC_USER}.service.d"
    install -m 0644 "${PAYLOAD_CFG}/syncthing/data-disk.conf" \
        "/etc/systemd/system/syncthing@${PLATFORM_SYNC_USER}.service.d/data-disk.conf"

    # Running out of watches is quiet (fallback to periodic scans). The
    # filename must not be 30-syncthing.conf: that would replace the package's
    # QUIC-buffer sysctl file whole rather than add to it.
    printf 'fs.inotify.max_user_watches = 524288\n' \
        > /etc/sysctl.d/31-syncthing-watches.conf
    chmod 0644 /etc/sysctl.d/31-syncthing-watches.conf

    info "Installed ${SYNCTHING_DEB##*/}, unit left disabled"
else
    info "No Syncthing .deb in payload, skipping"
fi

# --- Data disk lifecycle command ---------------------------------------------
# Never unlocked at boot: no crypttab, noauto fstab. The fstab entry is written
# here so the srv-<namespace>.mount unit systemd derives from it exists from
# image build onwards. Rationale: capability.encrypted-datadisk.md.
log "Install the data disk lifecycle command"
# platform_node.py is the shared library data-disk, sync-node and
# guest-firstboot.sh use; it lives beside the commands so Python finds it.
install -m 0755 "${VM_INIT_DIR}/platform_node.py" /usr/local/bin/platform_node.py
install -m 0755 "${VM_INIT_DIR}/data-disk" /usr/local/bin/data-disk
DATA_FSTAB_LINE="/dev/mapper/${PLATFORM_NAMESPACE}_data ${PLATFORM_DATA_ROOT} ext4 noauto 0 0"
if ! grep -qF " ${PLATFORM_DATA_ROOT} " /etc/fstab 2> /dev/null; then
    printf '%s\n' "${DATA_FSTAB_LINE}" >> /etc/fstab
    info "Added noauto fstab entry for ${PLATFORM_DATA_ROOT}"
fi
# Bare mountpoint closed while locked (the bare mountpoint invariant).
install -d -o root -g root -m 0500 "${PLATFORM_DATA_ROOT}"

# --- Host drive mounts (HGFS) --------------------------------------------
# Host drives shared by the .vmx, mounted on demand under /mnt/<letter>.
# An absent share (X: unplugged, S: BitLocker-locked, no shares configured)
# just errors and retries on the next access; idle mounts release after 300s.
# C and S are ro here and host-side both. Design: capability.host-data-access.md.
log "Configure host drive mountpoints"
install -d -m 0755 /mnt/C /mnt/X /mnt/S
if ! grep -qF " /mnt/C " /etc/fstab 2> /dev/null; then
    {
        printf '.host:/C /mnt/C fuse.vmhgfs-fuse ro,allow_other,noauto,x-systemd.automount,x-systemd.idle-timeout=300 0 0\n'
        printf '.host:/X /mnt/X fuse.vmhgfs-fuse rw,allow_other,noauto,x-systemd.automount,x-systemd.idle-timeout=300 0 0\n'
        printf '.host:/S /mnt/S fuse.vmhgfs-fuse ro,allow_other,noauto,x-systemd.automount,x-systemd.idle-timeout=300 0 0\n'
    } >> /etc/fstab
    info "Added HGFS automount fstab entries for /mnt/C /mnt/X /mnt/S"
fi

# --- MOTD banner (derived from the hostname) ---------------------------------
log "Write MOTD banner"
rm -f /etc/update-motd.d/10-help-text /etc/update-motd.d/60-unminimize
printf '#!/bin/bash\nfiglet -k "%s" && figlet -k "%s"\n' \
    "${INSTANCE_ENV}" "${HOST_ID}" > /etc/update-motd.d/99-banner
chmod 0755 /etc/update-motd.d/99-banner
# "Is the data disk up right now?" is the first thing to know at login.
printf '#!/bin/bash\n/usr/local/bin/data-disk status --brief\n' \
    > /etc/update-motd.d/98-data-disk
chmod 0755 /etc/update-motd.d/98-data-disk

# --- Build metadata and applied manifest -------------------------------------
log "Record build metadata and manifest"
install -m 0644 "${VM_INIT_DIR}/build-info.env" /etc/image-build-info.env
install -m 0755 "${VM_INIT_DIR}/image-build-info" /usr/local/bin/image-build-info
printf 'INSTALL_TIMESTAMP=%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" \
    >> /etc/image-build-info.env
# --payload-package records what came from extra_deb rather than
# packages.list, so the manifest can answer "which Syncthing is on this VM".
python3 "${VM_INIT_DIR}/make-manifest.py" apply \
    --planned "${VM_INIT_DIR}/build-manifest.json" \
    --out /etc/image-build-manifest.json \
    --packages "${PACKAGES_LIST}" \
    --platform-namespace "${PLATFORM_NAMESPACE}" \
    --payload-package syncthing \
    --payload-package ca-certificates-qfree

# --- First-boot unit ---------------------------------------------------------
log "Enable first-boot provisioning unit"
install -m 0644 "${VM_INIT_DIR}/vm-init-firstboot.service" \
    /etc/systemd/system/vm-init-firstboot.service
systemctl enable vm-init-firstboot.service

# --- Reclaim space: drop the repo, tarballs and debs; keep the scripts -------
log "Clean up install-only payload"
rm -f /etc/apt/sources.list.d/vm-init-local.list
rm -rf "${APT_REPO_DIR}" "${PAYLOAD_TGZ}" "${PAYLOAD_DEB}" "${BUILD_TOOLS_DIR}"

log "Guest install complete"
