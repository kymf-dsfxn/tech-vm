# CLI contract for the guest operator commands

The behaviour the Python ports must preserve. Message wording is a design
artifact (cause before symptom; "not readable" is never reported as absent)
and is ported verbatim; deviations are listed in the port's commit message.

## data-disk

- Commands: `init | unlock | lock | status`; options `--force`, `--brief`
  (status), `-h/--help`. Unknown command or option: usage to stderr, exit 1.
- `status` runs without root; every other command requires root and says
  "needs root. Try: sudo data-disk <cmd>".
- Exit codes: 0 success (including a skipped gated service), 1 on `die`.
- States: the six-word vocabulary in `platform_node.STATES`, classified
  observable-first.
- Output prefixes: `==> ` (log), four spaces (info), `    WARNING: ` to
  stderr (warn), `ERROR: ` to stderr (die).
- MOTD consumes `status --brief` (one line, `data disk: ...`).

## sync-node

- Commands: `identity | id | render | ensure | marker | status | gui`;
  options `--force`, `--quiet`, `--create` (marker), `-h/--help`.
- `status`, `gui` and `marker` (report mode) run without root; `id` needs
  root in practice (identity behind 0700).
- `--quiet` silences log/info, never warn.
- Refusal semantics that must not change: `identity` refuses to replace
  without `--force`; `render` refuses to overwrite without `--force`, refuses
  surviving MANUALLY_FIX_ (names the file to edit, repository copy) and
  surviving AUTOFILL_ (says fix the build, not the node); `marker --create`
  refuses an empty share without `--force`.

## The machine-consumed interfaces (must stay stable)

- `data-disk init` invokes `sync-node marker --create --force`, tolerating
  failure with a warning.
- `guest-firstboot.sh` invokes
  `platform_node.py state --device ... --partition ... --mapper ... --mount ...`
  (one of the six states on stdout) and
  `platform_node.py marker-name --template ...`.
- `make-manifest.py` imports `platform_node.STATES` for `--data-state`.
- systemd: the drop-in conditions test the mount and the rendered config
  path; nothing else machine-parses these commands' output.
