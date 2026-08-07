#!/usr/bin/env bash
# =============================================================================
# guest-install.sh
#
# Install-time guest provisioning. The autoinstall late-commands copy the
# vm-init payload onto the target and run this script inside the target with
# `curtin in-target`. It runs in a chroot on the installed root, so all paths
# are guest paths and the network is not required.
#
# It installs every package from the on-ISO apt repo, places the payload files,
# creates the users, sets the locale, unpacks Maven and Liquibase, installs the
# company CA, writes the MOTD banner, and records the build metadata and the
# applied manifest. It does not touch the data disk or the HGFS mount. Those
# need the running kernel and the VMware tools, so guest-firstboot.sh does them
# at first boot.
#
# The script is idempotent enough to re-run during development, but it is meant
# to run once, at install.
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
install -m 0644 "${PAYLOAD_CFG}/apt-minimal.conf" /etc/apt/apt.conf.d/99minimal
printf 'APT::Install-Recommends "0";\nAPT::Install-Suggests "0";\n' \
    > /etc/apt/apt.conf.d/99-no-recommends

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
log "Create platform users"

# Platform admin (qfree, 500)
groupadd --gid 500 qfree
useradd --comment qfree --create-home --system --shell /bin/bash \
    --uid 500 --gid 500 --groups sudo qfree
printf 'qfree ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/010-qfree-nopw
chmod 0440 /etc/sudoers.d/010-qfree-nopw

# Node management (qf_node_mgmt, 501)
groupadd --gid 501 qf_node_mgmt
useradd --comment qf_node_mgmt --create-home --system --shell /bin/bash \
    --uid 501 --gid 501 --groups qfree,sudo qf_node_mgmt
printf 'qf_node_mgmt ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/010-qf_node_mgmt-nopw
chmod 0440 /etc/sudoers.d/010-qf_node_mgmt-nopw
install --directory --mode=0700 --owner=qf_node_mgmt --group=qf_node_mgmt \
    /home/qf_node_mgmt/.ssh
printf '# PLACEHOLDER\n' > /home/qf_node_mgmt/.ssh/authorized_keys
chmod 0600 /home/qf_node_mgmt/.ssh/authorized_keys
chown qf_node_mgmt:qf_node_mgmt /home/qf_node_mgmt/.ssh/authorized_keys

# Named user (kymf, auto UID/GID). Key comes from the payload, not inline.
useradd --comment "${NAMED_USER}" --create-home --shell /bin/bash \
    --groups qfree,sudo "${NAMED_USER}"
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
# Closes the old gap: the tarball shipped in the bundle but setup-vm.sh never
# installed it.
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
# Pinned binaries fetched at ISO-build time by fetch-build-tools.sh and staged
# under build-tools/bin. They are not apt packages, so they are copied straight
# into /usr/local/bin here. syft is required by the Python SBOM step; shfmt and
# uv complete the local Python/shell build toolchain.
log "Install standalone build tools"
if [[ -d "${BUILD_TOOLS_DIR}/bin" ]]; then
    install -m 0755 "${BUILD_TOOLS_DIR}/bin/"* /usr/local/bin/
    info "Installed: $(find "${BUILD_TOOLS_DIR}/bin" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
else
    info "No build-tools payload, skipping (syft/shfmt/uv will be absent)"
fi

# --- Rootless podman socket (Docker-API compatibility) -----------------------
# Enable the per-user podman socket for every user so Docker-API clients
# (Testcontainers, the fabric8 docker-maven-plugin) can reach a daemonless
# engine. `--global` writes user-unit symlinks only; it needs no running
# systemd, so it is safe in this install-time chroot. The socket activates in
# each user's systemd session at login. See the project's build-container
# socket decision note for why this lives on the VM and not in wsl-kf.
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

# --- MOTD banner (derived from the hostname) ---------------------------------
log "Write MOTD banner"
rm -f /etc/update-motd.d/10-help-text /etc/update-motd.d/60-unminimize
printf '#!/bin/bash\nfiglet -k "%s" && figlet -k "%s"\n' \
    "${INSTANCE_ENV}" "${HOST_ID}" > /etc/update-motd.d/99-banner
chmod 0755 /etc/update-motd.d/99-banner

# --- Build metadata and applied manifest -------------------------------------
log "Record build metadata and manifest"
install -m 0644 "${VM_INIT_DIR}/build-info.env" /etc/image-build-info.env
install -m 0755 "${VM_INIT_DIR}/image-build-info" /usr/local/bin/image-build-info
printf 'INSTALL_TIMESTAMP=%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" \
    >> /etc/image-build-info.env
python3 "${VM_INIT_DIR}/make-manifest.py" apply \
    --planned "${VM_INIT_DIR}/build-manifest.json" \
    --out /etc/image-build-manifest.json \
    --packages "${PACKAGES_LIST}"

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
