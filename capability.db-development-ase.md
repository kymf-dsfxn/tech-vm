# Capability: db-development-ase

A developer on a freshly built VM can develop and run code against SAP ASE
(Sybase Adaptive Server Enterprise) in C and in Python, and can drive a server
from the command line, with nothing to install and nothing to configure except
the server's address. This document owns the design; the implementation is the
two `sap.ase-*.tgz` payload bundles, the ASE stanzas in `guest-install.sh`, a
handful of `packages.list` entries, and the proof is
`00.host-config/common/tests/db-clients/run.sh`.

## What the image carries

Three layers, from three places:

| Layer | What | From |
| ----- | ---- | ---- |
| Command line | `isql`, `bcp`, `defncopy`, `dscp`, `aseuserstore`, `pwdcrypt` | `sap.ase-client.16.tgz` → `/opt/sap/OCS-16_1/bin` |
| C toolchain | CT-Lib, DB-Lib, CS-Lib and Bulk-Library headers and shared libraries, plus the vendor's own samples | same bundle: `OCS-16_1/include`, `OCS-16_1/lib`, `OCS-16_1/sample` |
| ODBC | `libsybdrvodb.so`, registered with unixODBC as `Adaptive Server Enterprise` | `sap.ase-odbc.16.tgz` → `/opt/sap/DataAccess64`, plus `unixodbc` and `odbcinst` from `packages.list` |

The client is Open Client 16.1 SP00 PL02 (`OCS-16_1`); the ODBC driver is the
SDK's 16.1 build, the SQLLEN=8 variant that matches unixODBC. Both bundles are
repacked subsets of the vendor installers - what was kept, what was dropped and
how to rebuild them is in `00.host-config/README.md`, "The SAP client bundles".

## The environment contract

`/etc/profile.d/sap-ase.sh` supplies exactly three variables, and each is
load-bearing, not decoration:

- `SYBASE=/opt/sap` - CS-Lib reads the locale, charset and collation trees
  under it at `cs_ctx_alloc` time. A program that links perfectly still fails
  at startup without it.
- `SYBASE_OCS=OCS-16_1` - the release-dependent directory name, read off the
  bundle at install time rather than hard-coded.
- `SYBPLATFORM=linuxamd64` - the SDK's name for the build target; the vendor
  sample makefiles refuse to run without it. Threaded code wants
  `nthread_linuxamd64` and the `_r64` libraries instead.

The split matters: the **libraries** resolve from `ld.so.conf.d`
(`/opt/sap/OCS-16_1/lib`, `lib3p64`, and the ODBC lib directory) with no
`LD_LIBRARY_PATH` anywhere on the image - that is an invariant, and the test
asserts it. The **variables** come only from `/etc/profile.d`, so a login shell
has them and a systemd unit does not; a service that talks to ASE must set
`SYBASE` itself.

## C development

Headers under `$SYBASE/$SYBASE_OCS/include`, libraries under
`$SYBASE/$SYBASE_OCS/lib`. The canonical compile line is what the test builds
`ct_smoke.c` with:

```sh
cc -m64 -D${SYBPLATFORM}=1 -I"${SYBASE}/${SYBASE_OCS}/include" app.c \
   -L"${SYBASE}/${SYBASE_OCS}/lib" \
   -lsybct64 -lsybtcl64 -lsybcs64 -lsybcomn64 -lsybintl64 -lsybunic64 \
   -ldl -lm -o app
```

The built binary runs with `$SYBASE` as its only environment. The vendor's
`sample/ctlibrary` tree builds unmodified with its own makefile under
`-Werror`; `firstapp` from it is part of the test. `lib3p64` holds the crypto
providers `libsybfssl64` loads for SSL logins, which is why it is on the loader
path too.

## Python development

The route is `pyodbc` through unixODBC. The image ships the driver manager
(`libodbc.so.2`, what pyodbc actually links against) and the registered driver
name; `pyodbc` itself is a per-project install (`pip` / `uv` into the project's
venv - the image deliberately ships no Python database packages). A DSN-less
connection needs no files at all:

```python
import pyodbc
cn = pyodbc.connect(
    "DRIVER={Adaptive Server Enterprise};"
    "NetworkAddress=<host>,<port>;UID=<user>;PWD=<pw>;Database=<db>")
```

`SERVER=<host>;PORT=<port>` works as well. `Adaptive Server Enterprise` is the
label the migration-project's extraction scripts default `--driver` to, which
is why it is registered at image build and not per VM. The test drives this
exact path - the registered name, through `libodbc.so.2`, to the driver's own
"no server listening" error - so a broken registration cannot pass.

## Java, incidentally

jConnect 7 (`/opt/sap/jConnect-7_0`, `jconn4.jar`) arrives via the IQ client
bundle - see `capability.db-development-iq.md` - and speaks TDS to ASE as well
as to IQ. It is pure Java and runs on the system openjdk-25, so Maven and
Liquibase on the image can reach ASE over JDBC with
`com.sybase.jdbc4.jdbc.SybDriver` and `jdbc:sybase:Tds:<host>:<port>`.

## What is configuration, not image

No `interfaces` file is written, deliberately: server names and addresses are
configuration, configuration is the operator's, and the operator's data lives
on the encrypted disk (`capability.encrypted-datadisk.md`). `dscp` builds an
`interfaces` file when one is wanted; `isql -S host:port` and the DSN-less
connection strings above need none. `dsedit` and `sybhelp` ship in the bundle
but need Motif and X11 and cannot run on this headless guest - known-unusable,
by design.

## Verified by

`00.host-config/common/tests/db-clients/run.sh` - no ISO, no VM, ~5 minutes in
a throwaway container of the target release. It runs the real `guest-install.sh`
stanzas (extracted from that file at run time, so drift fails the test), then
asserts the tools run from a login shell, the smoke client and the vendor
sample compile and run, the ODBC registration loads through unixODBC, and the
`env -i` invariants above hold.
