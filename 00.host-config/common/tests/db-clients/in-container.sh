#!/usr/bin/env bash
# =============================================================================
# in-container.sh - the guest half of the database client toolchain test.
#
# Not run directly: run.sh starts a container of the target Ubuntu release,
# mounts the repo read-only at /repo, and runs this inside it. Everything here
# assumes it may trash the filesystem it is running on, because it is a
# container.
#
# What it asserts, in the order a real install does it:
#   1. every name in packages.list still resolves on the target release
#   2. the SAP stanzas in guest-install.sh run, taken verbatim from that file
#      rather than copied here, so this test fails when that file drifts
#   3. isql, bcp, dbisqlc, dbping and psql run from a login shell
#   4. the three smoke clients compile and run against what step 2 installed
#
# Exit status is 0 only if every check passed.
# =============================================================================

# Single quotes around the `bash -lc` bodies are the mechanism, not an
# oversight: those expressions have to expand in the login shell, which is
# where /etc/profile.d has run, rather than here.
# shellcheck disable=SC2016

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

REPO="${REPO:-/repo}"
COMMON="${REPO}/00.host-config/common"
GUEST_INSTALL="${COMMON}/provision/guest-install.sh"
SMOKE_DIR="${COMMON}/tests/db-clients"

# The section of guest-install.sh this test drives. Both markers are the
# literal section headers in that file; if either is renamed, extraction finds
# nothing and this test fails rather than silently testing an empty script.
STANZA_BEGIN='# --- SAP ASE Open Client'
STANZA_END='# --- Standalone build tools'

FAIL=0
step() { printf '\n########## %s ##########\n' "$*"; }
ok()   { printf '  PASS: %s\n' "$*"; }
bad()  { printf '  FAIL: %s\n' "$*"; FAIL=1; }

# Run one check. The command's own output is left on the terminal on purpose:
# when a compile fails, its errors are the whole point of running this.
check() {
    local label="$1"; shift
    if "$@"; then ok "${label}"; else bad "${label}"; fi
}

# Same, for a check whose verdict is "the output said this". The output is
# captured rather than piped so that a tool which prints the right thing and
# still exits non-zero - dbisqlc -? exits 255 - counts as a pass.
check_output() {
    local label="$1" want="$2"; shift 2
    local out
    out="$("$@" 2>&1)" || true
    if printf '%s' "${out}" | grep -q -- "${want}"; then ok "${label}"
    else bad "${label} (got: $(printf '%s' "${out}" | head -1))"; fi
}

# -----------------------------------------------------------------------------
step "1. packages.list resolves and installs"
# -----------------------------------------------------------------------------
apt-get update -qq
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "${COMMON}/packages.list")
printf 'packages (%d): %s\n' "${#PKGS[@]}" "${PKGS[*]}"
if apt-get install -y --no-install-recommends "${PKGS[@]}" > /tmp/apt.log 2>&1; then
    ok "all ${#PKGS[@]} packages install"
else
    bad "packages.list install"
    tail -30 /tmp/apt.log
fi
# The compat link the SQL Anywhere stanza makes needs this specific runtime;
# only libncursesw6 arrives on its own, as a dependency of other packages.
check "libncurses.so.6 present (dbisqlc compat link target)" \
    test -e /usr/lib/x86_64-linux-gnu/libncurses.so.6

# -----------------------------------------------------------------------------
step "2. the SAP stanzas from guest-install.sh, run verbatim"
# -----------------------------------------------------------------------------
mkdir -p /opt/vm-init/extra_tgz
cp "${COMMON}"/payload/extra_tgz/sap.*.tgz /opt/vm-init/extra_tgz/
ls -la /opt/vm-init/extra_tgz

{
    echo 'set -euo pipefail'
    echo 'PAYLOAD_TGZ="/opt/vm-init/extra_tgz"'
    echo 'log()  { echo "==> $*"; }'
    echo 'info() { echo "    $*"; }'
    awk -v b="${STANZA_BEGIN}" -v e="${STANZA_END}" \
        'index($0,b)==1 {on=1} index($0,e)==1 {on=0} on' "${GUEST_INSTALL}"
} > /tmp/stanzas.sh

if grep -q 'ASE_TARBALL' /tmp/stanzas.sh && grep -q 'SQLANY_TARBALL' /tmp/stanzas.sh; then
    ok "extracted both stanzas ($(wc -l < /tmp/stanzas.sh) lines)"
else
    bad "could not extract the SAP stanzas - have the section headers moved?"
fi
if bash /tmp/stanzas.sh; then ok "stanzas ran clean"; else bad "stanzas exited non-zero"; fi

printf '\n--- what they wrote ---\n'
cat /etc/profile.d/sap-ase.sh /etc/profile.d/sap-sqlanywhere.sh
cat /etc/ld.so.conf.d/sap-ase.conf /etc/ld.so.conf.d/sap-sqlanywhere.conf
ls -l /usr/lib/x86_64-linux-gnu/libncurses.so.5

# guest-install.sh reclaims the payload at the end; do the same, so the rest of
# this test can only pass on what actually landed in the image.
rm -rf /opt/vm-init/extra_tgz

# -----------------------------------------------------------------------------
step "3. login shell environment and the command-line clients"
# -----------------------------------------------------------------------------
bash -lc 'echo "  SYBASE=$SYBASE  SYBASE_OCS=$SYBASE_OCS  SYBPLATFORM=$SYBPLATFORM"
          echo "  SQLANY16=$SQLANY16"
          echo "  isql:    $(command -v isql)"
          echo "  bcp:     $(command -v bcp)"
          echo "  dbisqlc: $(command -v dbisqlc)"
          echo "  LD_LIBRARY_PATH (unset by design): [${LD_LIBRARY_PATH:-}]"'

check "isql -v"       bash -lc 'isql -v > /dev/null 2>&1'
check "bcp -v"        bash -lc 'bcp  -v > /dev/null 2>&1'
check "psql --version" bash -lc 'psql --version > /dev/null'
# dbisqlc is the ncurses 5 case: it loads at all only via the compat link.
check_output "dbisqlc loads (ncurses compat link works)" 'Usage' \
    bash -lc 'TERM=xterm dbisqlc -?'
# Reaching "server not found" means the request went through the driver.
check_output "dbping drives the SQL Anywhere client" 'Database server not found' \
    bash -lc 'dbping -c "uid=x;pwd=y;host=127.0.0.1:2638"'

# -----------------------------------------------------------------------------
step "4. CT-Lib: smoke client + the vendor sample"
# -----------------------------------------------------------------------------
mkdir -p /tmp/build && cp "${SMOKE_DIR}"/*.c /tmp/build/

check "ct_smoke builds" bash -lc 'cd /tmp/build &&
  cc -m64 -g -Wall -Wformat=2 -D${SYBPLATFORM}=1 \
     -I"${SYBASE}/${SYBASE_OCS}/include" ct_smoke.c \
     -L"${SYBASE}/${SYBASE_OCS}/lib" \
     -lsybct64 -lsybtcl64 -lsybcs64 -lsybcomn64 -lsybintl64 -lsybunic64 \
     -Wl,-Bdynamic -ldl -lm -o ct_smoke'
check "ct_smoke runs" bash -lc /tmp/build/ct_smoke
# The libraries resolve from ld.so.conf.d with no LD_LIBRARY_PATH at all; only
# $SYBASE is still needed, because CS-Lib reads the locale tree under it.
check 'ct_smoke runs on $SYBASE alone (no LD_LIBRARY_PATH)' \
    env -i SYBASE=/opt/sap /tmp/build/ct_smoke

# The vendor sample builds with -Werror, against its own makefile, unmodified.
cp -r "$(bash -lc 'echo ${SYBASE}/${SYBASE_OCS}')/sample/ctlibrary" /tmp/ctsample
bash -lc 'cd /tmp/ctsample && make firstapp' > /tmp/firstapp.log 2>&1
if [[ -x /tmp/ctsample/firstapp ]]; then
    ok "vendor sample firstapp builds unmodified"
else
    bad "vendor sample firstapp"; tail -15 /tmp/firstapp.log
fi

# -----------------------------------------------------------------------------
step "5. libpq"
# -----------------------------------------------------------------------------
check "pq_smoke builds via pkg-config" bash -lc 'cd /tmp/build &&
  cc -Wall -Wextra -O2 pq_smoke.c $(pkg-config --cflags --libs libpq) -o pq_smoke'
check "pq_smoke builds via pg_config" bash -lc 'cd /tmp/build &&
  cc -Wall -O2 -I$(pg_config --includedir) pq_smoke.c -lpq -o pq_smoke_pgc'
check "pq_smoke runs" /tmp/build/pq_smoke

# -----------------------------------------------------------------------------
step "6. SQL Anywhere C API"
# -----------------------------------------------------------------------------
cp "$(bash -lc 'echo $SQLANY16')/sdk/c/sacapidll.c" /tmp/build/
check "sa_smoke builds" bash -lc 'cd /tmp/build &&
  cc -Wall -O2 -I"${SQLANY16}/sdk/include" sa_smoke.c sacapidll.c -ldl -o sa_smoke'
check "sa_smoke runs" bash -lc /tmp/build/sa_smoke
check 'sa_smoke runs on $SQLANY16 alone' \
    env -i SQLANY16=/opt/sqlanywhere16 /tmp/build/sa_smoke

# -----------------------------------------------------------------------------
step "7. installed footprint"
# -----------------------------------------------------------------------------
du -sh /opt/sap /opt/sqlanywhere16

printf '\n########## RESULT ##########\n'
if [[ ${FAIL} -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES ABOVE"; fi
exit "${FAIL}"
