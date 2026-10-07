# Capability: db-development-iq

A developer on a freshly built VM can develop and run code against SAP IQ
(Sybase IQ) in C and in Python, script a server from the command line with
`dbisql`, and reach it over JDBC, with nothing to install and nothing to
configure except the server's address. This document owns the design; the
implementation is the `sap.sql-anywhere-client.16.tgz`, `sap.iq-client.16.tgz`
and `sap.iq-client-jre.7.tgz` payload bundles, their stanzas in
`guest-install.sh`, and the proof is
`00.host-config/common/tests/db-clients/run.sh`.

## Two bundles, one capability

IQ's client side *is* SQL Anywhere: the wire protocol, the ODBC driver, the C
API and most of the command-line utilities are the SQL Anywhere 16 ones. So
this capability is layered:

| Layer | What | From |
| ----- | ---- | ---- |
| SQL Anywhere client | `dbisqlc`, `dbping`, `dbdsn`, `dblocate`, `dbvalid`, `dbbackup`, `dbunload`; the sacapi C SDK; the ODBC driver registered as `SQL Anywhere 16` | `sap.sql-anywhere-client.16.tgz` → `/opt/sqlanywhere16` |
| IQ network client | `dbisql` (the Java Interactive SQL console), `iqdsn`, `iqsqlpp` (embedded SQL preprocessor), the `IQ-16_0` libraries and SDK, jConnect 7 | `sap.iq-client.16.tgz` → `/opt/sap/IQ-16_0`, `/opt/sap/jConnect-7_0` |
| SAPJRE 7 (64-bit) | the JVM `dbisql` runs on | `sap.iq-client-jre.7.tgz` → `/opt/sap/shared/SAPJRE-7_1_015_64BIT` |

The SQL Anywhere bundle is a repacked vendor client; the IQ bundles are cut
from the SAP IQ Network Client 16.0 SP11 PL18 installer
(`IQNC160011P_18-20011248.TGZ`), which is an InstallAnywhere installer, not an
archive - the rebuild procedure, the trim list and the reason the JRE is a
separate tarball (GitHub's 100 MiB file limit) are in
`00.host-config/README.md`, "IQ network client bundle".

## The command line

`dbisql` is the tool that scripts IQ properly: `-nogui` runs it headless, it
executes files and inline statements, and it understands IQ's SQL. `dbisqlc`
is the deprecated C-based subset and stays available; `dbping` answers "is the
server reachable" and `dbdsn` / `iqdsn` manage data sources. A connect needs
only an address:

```sh
dbisql -nogui -c "uid=<user>;pwd=<pw>;host=<host>:<port>" "SELECT ...;"
dbping -c "uid=<user>;pwd=<pw>;host=<host>:<port>"
```

`dbisql` cannot run on the system openjdk: it needs the Java 7 extension
mechanism, removed in Java 9. That is the entire reason the vendor's SAPJRE
ships. It is reached only through `SYBASE_JRE7_64` - the one variable `dbisql`
needs, which the test pins with `env -i` - and is never on `PATH`; nothing
else on the image runs on it.

## The environment contract

`/etc/profile.d/sap-sqlanywhere.sh` supplies `SQLANY16=/opt/sqlanywhere16`
(the C API's `sqlany_init` resolves its message catalogues under it) and
`/etc/profile.d/sap-iq.sh` supplies `IQDIR16=/opt/sap/IQ-16_0` and
`SYBASE_JRE7_64`. As with ASE, variables come only from `/etc/profile.d`;
a systemd unit that talks to IQ sets what it needs itself.

Two sharp edges in the layering, both held by test:

- **PATH order.** Both bundles ship `dbisqlc`, `dbping`, `dblocate` and
  `dbvalid`. profile.d fragments source lexically and each prepends, so
  `sap-sqlanywhere.sh` lands ahead of `sap-iq.sh` and the shared tools keep
  resolving from `/opt/sqlanywhere16`, exactly as they did before the IQ
  bundle existed. The IQ bundle adds tools; it does not change which copy of
  the shared ones runs.
- **No `ld.so.conf.d` fragment for IQ.** Every native binary in
  `IQ-16_0/bin64` carries an RPATH to its own `lib64`, and that `lib64`
  duplicates the SQL Anywhere sonames already published from
  `/opt/sqlanywhere16/lib64`. Publishing both would let ldconfig pick one
  bundle's libraries for the other's tools. So the loader path carries the
  SQL Anywhere libraries only, and the IQ tools resolve their own privately.

## C development

The supported C route is the SQL Anywhere C API (sacapi): headers under
`$SQLANY16/sdk/include`, loaded through the `dlopen` shim the SDK ships as
source. The canonical build is what the test does with `sa_smoke.c`:

```sh
cp "$SQLANY16/sdk/c/sacapidll.c" .
cc -I"$SQLANY16/sdk/include" app.c sacapidll.c -ldl -o app
```

The binary runs with `$SQLANY16` as its only environment. ODBC is the other
C route - `odbc.h` and `saodbc.h` are in the same SDK, and the driver is
already registered. For embedded SQL there is `iqsqlpp` and the ESQL headers
(`sqlca.h`, `sqlda.h`) in the IQ tree.

## Python development

Two routes, both riding on what the image already resolves:

- **`sqlanydb`** - the vendor's own driver, a per-project `pip` / `uv`
  install. It loads `libdbcapi_r.so` through `ctypes` by that exact name, and
  the name resolves from `ld.so.conf.d` with no environment at all - the test
  asserts that one line. The same driver source ships on the image under
  `$IQDIR16/sdk/python` for reference.
- **`pyodbc`** - through unixODBC and the registered `SQL Anywhere 16` driver
  name (an odbcinst.ini label the migration-project's extraction scripts pass
  via `--driver`):

```python
import pyodbc
cn = pyodbc.connect(
    "DRIVER={SQL Anywhere 16};HOST=<host>:<port>;UID=<user>;PWD=<pw>")
```

As on the ASE side, the image ships drivers and driver manager but no Python
packages; `sqlanydb` and `pyodbc` are venv installs.

## Java

jConnect 7 is at `/opt/sap/jConnect-7_0` (`classes/jconn4.jar`). It is pure
Java, runs on the system openjdk-25, and speaks TDS to both IQ and ASE -
`com.sybase.jdbc4.jdbc.SybDriver`, `jdbc:sybase:Tds:<host>:<port>` - which is
what Maven builds and Liquibase changelogs on the image use.

## What is configuration, not image

Server names, addresses and DSNs are the operator's, on the encrypted disk
(`capability.encrypted-datadisk.md`). `dbdsn` and `iqdsn` write
`~/.odbc.ini`-style data sources when wanted; the connection-string forms
above need no files. The IQ *server* is not on this image and never will be -
this is a client capability.

## Verified by

`00.host-config/common/tests/db-clients/run.sh` - the same throwaway-container
test that proves the ASE side. For IQ it asserts: the stanzas install from the
real `guest-install.sh` text; `dbisql -nogui` runs headless and a connect
attempt reaches the driver's own *Database server not found*; `iqdsn` and
`iqsqlpp` run; `dbisql` runs under `env -i` on `SYBASE_JRE7_64` alone; the
PATH-order rule above holds; the sacapi smoke client compiles and runs on
`$SQLANY16` alone; and `libdbcapi_r.so` loads by name from Python with no
environment.
