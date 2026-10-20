# Capability: db-development-pg

A developer on a freshly built VM can develop and run code against PostgreSQL
in C and in Python, drive a server from the command line with `psql`, and apply
Liquibase changelogs over JDBC, with nothing to install and nothing to
configure except the server's address. This document owns the design; the
implementation is three `packages.list` entries and the JDBC driver stanza in
`guest-install.sh`, and the proof is
`00.host-config/common/tests/db-clients/run.sh`.

## What the image carries

Unlike ASE and IQ, all of it comes from the Ubuntu archive. There is no vendor
bundle, no payload tarball and no repacking:

| Layer | What | From |
| ----- | ---- | ---- |
| Command line | `psql` 18.6, and the rest of the client suite - `pg_dump`, `pg_restore`, `pg_isready`, `createdb`, `dropdb`, `vacuumdb` | `postgresql-client-18` → `/usr/lib/postgresql/18/bin`, reached through the `pg_wrapper` symlinks on `PATH` |
| C toolchain | libpq, `libpq-fe.h` and the rest of the client headers, plus the `libpq.pc` that locates them | `libpq-dev` → `/usr/include/postgresql`, `/usr/lib/x86_64-linux-gnu`; `pkg-config` from `packages.list` |
| JDBC | pgJDBC 42.7, `org.postgresql.Driver` | `libpostgresql-jdbc-java` → `/usr/share/java/postgresql.jar`, linked into `/opt/liquibase/lib` |

`psql` on `PATH` is `/usr/bin/psql`, a symlink to `pg_wrapper` from
`postgresql-client-common`. The wrapper picks the client version, so a second
major version can be added later without the first moving out from under
anyone.

## No environment contract

This is the whole difference from the SAP capabilities, and it is worth stating
plainly: nothing is written to `/etc/profile.d` and nothing to
`/etc/ld.so.conf.d`. libpq is an archive library in the default loader path and
needs no variable to initialise. A systemd unit that talks to PostgreSQL
inherits as much as a login shell does, which is to say all it needs.

The `PG*` variables - `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`,
`PGSERVICE` - are deliberately not set. They are per-connection configuration,
and setting them on the image would make every tool on it lie about which
server it was talking to.

## C development

Headers under `/usr/include/postgresql`, libraries in the default path. The one
sharp edge is the header location: `libpq-fe.h` is **not** in `/usr/include`,
so `cc app.c -lpq` does not compile. Ask `pkg-config`, which is what
`packages.list` carries it for, and which is how the test builds `pq_smoke.c`:

```sh
cc -Wall -Wextra -O2 app.c $(pkg-config --cflags --libs libpq) -o app
```

`pg_config --includedir` is the second route, and the test builds the same
source both ways so that neither can rot:

```sh
cc -Wall -O2 -I"$(pg_config --includedir)" app.c -lpq -o app
```

The built binary runs with an empty environment. ECPG is not on the image; the
supported C route is libpq.

## Python development

The image ships libpq and ships no Python database packages, exactly as it does
for ASE and IQ. `psycopg` is a per-project `pip` / `uv` install into the
project's venv, and both of its forms resolve against what is already here -
the binary wheel carries its own libpq, the pure-Python form loads the system
`libpq.so.5` through `ctypes`, and `psycopg2` builds from source against
`libpq-dev`. A connection needs no files:

```python
import psycopg
cn = psycopg.connect("host=<host> port=<port> dbname=<db> user=<user>")
```

## Liquibase ships no drivers

Liquibase 5 carries its engine and H2 in `internal/lib` and nothing else. Every
other JDBC driver is the user's to supply, and a missing one fails late and
unhelpfully:

```
Cannot find database driver: org.postgresql.Driver
```

Three facts decide where the driver goes:

- The launcher ends in `java -jar internal/lib/liquibase-core.jar`. A
  `CLASSPATH` exported in the environment is ignored, because `-jar` replaces
  it.
- `$LIQUIBASE_HOME/lib` is the vendor's global library directory. Its jars join
  every CLI run, with no argument and no variable.
- `./liquibase_libs` in the working directory does the same for one project,
  and `--classpath` does it for one invocation.

So `guest-install.sh` links the drivers into `/opt/liquibase/lib`:
`postgresql.jar` from the archive package, and `jconn4.jar` out of the IQ
bundle for ASE and IQ (`capability.db-development-iq.md`). Links, not copies,
so the driver tracks whatever installed it. The stanza runs after the SAP
bundles rather than inside the Liquibase one, because jConnect does not exist
until the IQ tarball has unpacked.

Maven is unaffected and always was: a project declares `org.postgresql:
postgresql` in its POM and resolves it through the mirror in
`~/.m2/settings.xml`. The link is for the CLI, which has no POM to read.

```sh
liquibase --headless=true --changelog-file=db_global/root.yaml \
          --url=jdbc:postgresql://<host>:<port>/<db> status
```

## What is configuration, not image

No `~/.pgpass`, no `~/.pg_service.conf`, no `PG*` in any profile. Server names,
ports, users and passwords are the operator's, and the operator's data lives on
the encrypted disk (`capability.encrypted-datadisk.md`). A PostgreSQL *server*
is not part of this image either: the image carries `podman`, and a server run
in a container or reached over the network is configuration, not capability.
This is a client capability, like the other two.

## Verified by

`00.host-config/common/tests/db-clients/run.sh` - the same throwaway-container
test that proves the ASE and IQ sides. For PostgreSQL it asserts: the packages
still resolve on the target release; `psql` runs from a login shell;
`pq_smoke.c` compiles through `pkg-config` and through `pg_config`, and runs;
and the Liquibase CLI, driven at a closed port, fails with a network error
rather than *Cannot find database driver* - which is the only way to prove the
link into `/opt/liquibase/lib` took.
