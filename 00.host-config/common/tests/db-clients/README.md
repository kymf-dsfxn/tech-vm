# Database client toolchain test

Would a developer on a freshly built VM be able to reach ASE, IQ and Postgres,
and compile C against all three? This answers that without building an ISO.

```sh
00.host-config/common/tests/db-clients/run.sh          # ~5 min cold, needs docker or podman
00.host-config/common/tests/db-clients/run.sh --keep   # leave the container to poke at
```

It runs against a container of the release the ISO is built from
(`ubuntu:26.04`, override with `--image`), mounts the repo read-only, and
throws the container away. No ISO, no VM, no root on the host.

## What it asserts

1. **`packages.list` still resolves.** Every name, on the target release. This
   catches a package that has been renamed or dropped long before an ISO build
   would.
2. **The SAP stanzas in `guest-install.sh` run.** They are read out of that
   file at run time between its two section headers, not copied here, so this
   test fails when that file drifts from what the test claims about it. If the
   headers are renamed, extraction finds nothing and the test fails rather
   than quietly passing on an empty script.
3. **The command-line clients run** from a login shell: `isql`, `bcp`,
   `dbisqlc`, `dbping`, `psql`. `dbping` is checked as far as *Database server
   not found*, which means the request reached the driver.
4. **The three smoke clients compile and run** against what step 2 installed -
   plus the vendor's own `firstapp` sample, built by its own makefile,
   unmodified and with `-Werror`.

Between steps 2 and 3 it deletes `/opt/vm-init/extra_tgz`, exactly as
`guest-install.sh` does at the end, so nothing downstream can pass on a file
that would not be on the real image.

## The smoke clients

Each is the smallest program that exercises the part of the toolchain that
actually breaks. All three run without a server.

| | proves |
| --- | --- |
| `ct_smoke.c` | CT-Lib headers, libraries and `$SYBASE`. `cs_ctx_alloc` reads the locale and charset trees, so it catches a bundle that links but cannot run. |
| `pq_smoke.c` | libpq. Built both ways, because `libpq-fe.h` lands under `/usr/include/postgresql` and a bare `cc x.c -lpq` does **not** find it. |
| `sa_smoke.c` | The SQL Anywhere C API, via the `dlopen` loader the bundle ships. `sqlany_init` resolves the message catalogues under `$SQLANY16`. |

Two checks run the built binaries under `env -i` with a single variable set.
That is not pedantry: it pins down the split between the libraries, which
resolve from `ld.so.conf.d` with no `LD_LIBRARY_PATH` anywhere, and `$SYBASE` /
`$SQLANY16`, which the runtimes read for themselves and which only
`/etc/profile.d` supplies. A systemd unit running one of these would need them
set explicitly.

## Known-unusable, by design

`dsedit` and `sybhelp` need Motif and X11 and cannot run on a headless server.
The test does not check them. `dscp` is the CLI equivalent of `dsedit` and is
how an `interfaces` file gets built; the image deliberately ships without one,
because server names and addresses are configuration, and configuration lives
on the encrypted data disk.
