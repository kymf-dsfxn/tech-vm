# Capability: data synchronisation

The platform share replicates across an estate of Windows laptops, the Ubuntu
guests and a NAS hub, using Syncthing. This document is the design record for
the whole capability - estate topology included - because the guest is only one
peer in it. The guest-side implementation is `sync-node` (on the shared
`platform_node.py` library), the config template and the systemd drop-in under
`00.host-config/common/`, all shipped by the ISO. The disk the replica lives
on is `capability.encrypted-datadisk.md`.

## The estate and its topology

| Node | Runs | Role |
| ---- | ---- | ---- |
| laptops A, B, C | Windows, VMware Workstation | user workstations, roaming |
| guests 0010/0020/0030 | Ubuntu behind VMware NAT (`10.66.81/82/83.x`) | the replica that matters, on LUKS |
| QNAP TS-673A | `syncthing/syncthing` container, host networking | hub and introducer, always on |
| OPNsense | home LAN edge | NAT, DDNS, the port forward |

Hub-and-spoke, and it is the only shape that survives the constraints. Each
laptop is sometimes on the home LAN, sometimes on open internet, sometimes
inside a corporate NAT, and any two may or may not share a network. No design
that depends on laptops reaching each other survives that; the hub does. Every
node dials out to one name, and nothing on a laptop or a guest is ever dialled
into.

The hub is a replica, not a backup: a delete propagates to it by design.
Backup is a snapshot of the hub volume, somewhere the mesh cannot reach.

## What replicates

The synced root is never the top of a shared folder or a data disk; it is
always one directory inside it. On the guests, `/srv/dsfxn/share` is synced
and `/srv/dsfxn/.platform` is a sibling holding Syncthing's own state. On the
NAS the container mounts one level below the QTS shared folder root, so QTS's
own `@Recycle`, `@Recently-Snapshot` and `.@__thumb` sit structurally outside
the tree.

Structural exclusion beats ignore patterns for that job: an ignore list is per
device and is not itself synced, so a new node starts with none, and a
forgotten pattern is a data event rather than a warning. A `.stignore` still
earns its place for build output every node wants excluded - put the shared
list in a file inside the share and have each node's `.stignore` contain
`#include ignorepatterns`, since `.stignore` itself does not sync but an
included file does.

## Identity and state placement

The image carries mechanism only: the binary (payload `.deb`, version-pinned by
filename), the packaged unit, the drop-in, the config template, the `stsync`
account and `sync-node`. It carries no device identity and no rendered config,
because both are unique to a node and secret. Baked into an image the identity
would be identical on all three guests, which makes them one device to the hub,
and it would sit on the OS disk where a stolen disk gives it away. The operator
creates both once, on the encrypted disk, after `data-disk unlock`.

The packaged `syncthing@.service` is used as-is, so its sandboxing and upgrades
come for free. The drop-in
(`payload/extra_cfg/syncthing/data-disk.conf`, installed to
`/etc/systemd/system/syncthing@stsync.service.d/`) adds two start conditions
and four service settings and runs no privileged process of its own. The unit
is left disabled: `data-disk unlock` starts it, and the conditions skip it -
skip, not fail - while the disk is locked or the node has no rendered config.
The condition-versus-hook reasoning is in `capability.encrypted-datadisk.md`,
"Consuming the data root".

`stsync` (UID/GID 502) keeps a private primary group so its own state stays
`0700` under a group nothing else joins, and joins `dsfxn` as a supplementary
group, which is what lets it write into the share at all. Its home is
`/nonexistent`, which the packaged unit expects
(`InaccessiblePaths=-/nonexistent`); `STHOMEDIR` in the drop-in names the real
home on the encrypted disk, and in 2.x that one variable covers both the config
and the separate data directory.

## The folder marker invariant

Syncthing refuses a folder whose marker is missing. The marker lives *inside*
the share, on the encrypted disk, so it is absent exactly while the disk is
locked - which is precisely when the folder must be refused, because to a peer
a bare mountpoint reads as "everything was deleted". Measured on 2.1.3: a
fresh node with an empty index against a share with no marker reports state
`error`, error `folder marker missing`, and creates nothing on disk.

Three rules keep the guard load-bearing:

- **The name is non-default on purpose.** It is `.dsfxn-share-marker`, not
  `.stfolder`. Syncthing auto-creates only the default name, so a custom one is
  never recreated behind your back - including on a first start with an empty
  index, which is the case a default marker leaves open.
- **The marker is created only where an empty share is provably a fact.**
  `data-disk init` creates it right after `mkfs.ext4`, the one moment that
  holds (mechanically, by calling `sync-node marker --create --force`).
  Everywhere else, `sync-node marker --create` refuses an empty share without
  `--force`, and never creates the share directory at all: creating the marker
  over an empty share is how a locked disk becomes a mass delete at every peer.
- **The effective name must be read back from the daemon, not the file.**
  `markerName` is a child element; written as an attribute it is accepted and
  silently ignored, and the guard reverts to `.stfolder` with nothing to say
  so. `sync-node status` and `sync-node marker` ask the running daemon and warn
  when config and daemon disagree.

The third rule generalises: **a silently ignored config element removes a guard
without saying so.** Read the effective config back through the daemon after
the first start of every node, as part of bring-up, not as a diagnostic.

Versioning (staggered, 30-day floor, on every node) is the recovery net that
turns a mistake with this invariant - or any bad delete, or ransomware on one
laptop - into an inconvenience.

Recovery is not automatic. A folder already in error stays in error until a
rescan or a service restart, even once the marker is back. The SMB share vetoes
the marker (`veto files = /.dsfxn-share-marker/`) so a tidy-up from a client
cannot delete the guard; `guest-firstboot.sh` reads the name out of the
template (with a fallback literal) so there is one primary source of truth.

## Permission replication

Syncthing replicates contents, names, modification times and permission bits.
It does not replicate ownership: uid/gid move only with `syncOwnership`, which
needs extra capabilities on both ends and is deliberately off. Each device owns
its own copy - `stsync` here, the container uid on the NAS, NTFS ACLs on
Windows - and nothing chosen on one node constrains another.

Permission bits do replicate, and should: the share holds scripts, and the
executable bit is part of the shared view of a file. `ignorePerms` is false on
every Linux node. Measured between two Linux nodes: `0755`, `0640` and `0664`
all replicated exactly.

That only works because every Linux node writes with umask 0002. Files are
then created `0664` and directories `2775`, and those are the modes that
replicate, so faithful permissions and platform group access agree instead of
fighting. At upstream's default a file lands `0640`, that mode replicates
faithfully, and no other account can edit it on any node: one node's hardening
becomes every node's lockout. Hence `UMASK=002` in the hub compose file and
`UMask=0002` in the guest drop-in, overriding the packaged `UMask=7027`. Both
are load-bearing. The umask also decides the mode of files arriving from a node
that ignores permissions - which is every Windows node. Of what 7027 protected
against, setuid/setgid stay blocked (`RestrictSUIDSGID=true` is untouched);
what is given up is that files in the share are world-readable on this guest,
on an encrypted disk whose accounts are the platform's own.

The Windows nodes keep Ignore Permissions set on their copy, which is what
Syncthing recommends, because the alternative is Windows synthesising Unix
modes from its own attributes and pushing those. `ignorePerms` is per-device,
so the Linux nodes stay faithful while Windows stays quiet. The consequence is
inherent, not a misconfiguration, and it is permanent: measured, a `0755`
script edited on a permission-ignoring node became `0664` on every
permission-respecting node, and a later Linux edit did not restore the bit. The
SMB path into the guest does the same via `create mask = 0664`. Two ways to
live with it: keep executables in git, which records the bit (first choice), or
keep mode-sensitive content in a second Linux-only folder (only if the first
proves insufficient - a second folder is a second thing to operate).

## Node bring-up

```sh
sudo sync-node identity  # one-time: the device key, on the encrypted disk
sudo sync-node id        # print the device ID, to paste into the hub
sudo sync-node render    # config.xml from the template; never overwrites
     sync-node status    # current state; runs without root, reports what it
                         # cannot read as "not readable", never as "absent"
     sync-node marker    # the marker name the daemon is really using
     sync-node gui       # the SSH tunnel that reaches the web interface
```

(`id` needs root in practice: the identity sits behind `0700` on the encrypted
disk. `status`, `marker` reporting and `gui` run unprivileged.)

`identity` and `id` are different commands whose output on a second run is not:
`identity` creates the keypair; `id` prints the device ID, which is stored
nowhere and derived from the certificate on demand. When `identity` finds a
keypair already there it prints the ID as a convenience, the one case where the
two look alike.

`render` refuses to overwrite, because Syncthing owns `config.xml` once it has
run: the template is a starting point, not something to re-apply, and anything
changed through the GUI lives only in that file (so it belongs to the backup of
the encrypted disk, not the repo). `sync-node ensure` is `identity` and
`render`, each only if absent. Nothing runs it automatically - the drop-in's
`ConditionPathExists` guards the same hazard instead, because Syncthing started
without a config does not fail: it generates a fresh identity and a default
config, and the node comes up as a stranger to the hub with global discovery
on. The config must exist before the binary is ever reached.

Order per node: unlock, `identity`, admit on the hub, `render`, start the
service, set the folder receive-only for first convergence, verify the marker
name comes back from the daemon, then switch to send-receive.

### The template's two placeholder namespaces

The template holds placeholders of two kinds, and the prefix says whose job
each one is. `render` refuses to write while either kind survives, because an
unfilled address fails as a quiet absence of peers rather than as an error.

`AUTOFILL_*` are filled by `render`, on the node: `AUTOFILL_DEVICE_ID_SELF`
from the identity, `AUTOFILL_DEVICE_NAME` from the host name,
`AUTOFILL_API_KEY` as 128 fresh random bits. They are per-node values that
cannot exist in a repository.

`MANUALLY_FIX_*` are filled by a person, once, in the repository copy under
`common/payload/extra_cfg/syncthing/`, before the ISO is built: the folder ID,
the hub device ID, the hub LAN address and the hub DDNS name. They are
identical on every guest and a guest cannot work them out. (The hub port is
not one of them: it is a fixed 22000 in the template - see Exposure.) Editing
only `/etc/syncthing/node-config.xml.template` on a guest works for that guest
and loses the change at the next image.

The two get separate refusals because they have separate remedies: a surviving
`MANUALLY_FIX_` value names the file to edit; a surviving `AUTOFILL_` value
means template and `sync-node` shipped out of step, so the message says to fix
the build, not the node. `sync-node status` reports the placeholder count
before the config line, because on a node that will not start an unfinished
template is the cause and "not rendered" is only the symptom.

### Folders match by ID, and by nothing else

`MANUALLY_FIX_FOLDER_ID` must equal the hub's folder ID character for
character. Syncthing pairs folders across devices by ID alone: not by path,
which differs on every node, and not by label, which is a local caption. Read
the real value on the hub (Edit Folder, or `syncthing cli config folders
list`); expect a random pair like `abcde-12345` even when the label reads like
a name; it cannot be changed after the folder is created.

A mismatch does not error. The hub's folder arrives as a New Folder offer, the
guest's own folder sits idle because no peer shares it, and the offer's
suggested path nests inside the share and draws a red "subdirectory of an
existing folder" warning. That warning is the symptom; the mismatched ID is the
cause; accepting the offer creates a second overlapping folder rather than
fixing anything. The guest is the side to change, because the hub's ID is
already held by the laptops.

## Connectivity

### Addresses

The hub is the only device a guest is told about, marked as an introducer *on
the guest's entry for the hub* - introducer means "I trust this device to tell
me about others", so each spoke marks the hub and the hub marks nobody. Never
make two devices mutual introducers: removals then loop. `autoAcceptFolders`
stays off everywhere: introduction adds devices to folders you already hold,
never creates folders, so the local path is always a decision.

The hub entry carries four addresses - TCP and QUIC for each of two paths - and
both paths are needed:

- The LAN pair (`tcp|quic://<hub lan address>:22000`) is not a tuning detail.
  Without it, a guest at home dials the DDNS name, gets the WAN address, and
  hairpins into the router from inside, which needs NAT reflection - off by
  default on OPNsense - so the dial fails. The LAN path routes out through the
  VMware NAT gateway, is faster, and survives the WAN being down.
- The public pair (`tcp|quic://<ddns name>:<public port>`) is what works away
  from home.

There is no `dynamic` entry for the hub, and that is a decision. `dynamic`
means "find it by discovery"; global discovery is off, and local discovery is
broadcast, which from a guest behind VMware NAT reaches only the vmnet - other
VMs on the same laptop and the laptop's own Syncthing, never the house LAN.
`dynamic` would resolve to nothing on every dial. It goes back in the day a
guest moves to bridged networking. `localAnnounceEnabled` stays true anyway,
because introduced devices are created with `dynamic` and do share the vmnet:
two guests on one laptop connect directly with no edit.

`alwaysLocalNet` is `10.66.0.0/16`: Syncthing classes LAN-ness from the host's
own interface subnets, so a guest at `10.66.83.x` would otherwise class the NAS
at `10.66.10.x` as WAN and give the path priority 30 instead of the LAN 10. The
guest is on a different subnet from the NAS by design, so this matters more on
a guest than on a laptop.

Listen addresses are explicit (`tcp|quic://0.0.0.0:22000`), never `default`:
`default` pulls in the public relay pool, the vendor dependency this design
removes. Global announce off, `natEnabled` off (the guest dials out; nothing
dials in), usage reporting declined, crash reporting off.

### Exposure

One forward: public TCP 22000 to the hub's 22000, deliberately untranslated.
The port is therefore a fixed 22000 on every path in every config, which keeps
the address lists uniform and stays within upstream's stated rule that
forwarded and destination ports match.

**Option, not taken: translate the external port.** Forwarding a non-default
high public port to the hub's 22000 was considered and documented as a
potential hardening win. It is cheap noise reduction, not a control: it
removes the drive-by traffic that only ever probes 22000, and does nothing
against anyone who scans (a full port sweep of one address takes seconds).
Taking the option later means changing the forward on the router and the
public-path port in the template's hub addresses on every node - and note that
upstream documents forwarded and destination ports as having to match; the
reading that translation is fine (the guidance covers UPnP and global
discovery, and no port travels in the protocol once every client holds an
explicit address) is untested here.

What limits the risk is that Syncthing authenticates with mutual TLS against a
device ID allow-list: no password to guess, no unauthenticated command surface.
What the port does reveal: anyone who connects completes a TLS handshake, so
the port is fingerprintable as Syncthing and discloses the hub's device ID -
a public key, not a secret - and an unknown peer is refused immediately after.
The residual risk is a pre-authentication defect in Syncthing itself, which
patch cadence addresses and a port number does not.

Stays closed, on every node: the GUI (8384) never faces the internet; local
discovery (21027) is link-local and never forwarded; UPnP off on the router. If
a corporate site blocks outbound 22000, the cheap answer is a second forward
(WAN TCP 443 to hub 22000) and one more address in the hub's list - not a
relay.
Neither survives deep TLS inspection, which rejects the protocol whatever the
port.

Carrier NAT at home is the one thing that breaks this design outright: no
forward works and the hub is unreachable from outside. Check it before
everything else (WAN address in `100.64.0.0/10`, or differing from a public
address lookup). The remedies are a public address from the ISP, a relay hosted
outside the house, or WireGuard with an external endpoint.

### The relay decision

There is no relay, and that is a decision rather than a gap. On the same box as
a reachable hub, a relay is very nearly redundant: if the house connection is
down they fail together, and if the hub is up every node already has a path
through it at the same cost. Three narrow cases where one would earn something:
the hub's folder in error while the container is fine (a state this design
deliberately introduces via the marker), the hub container down for upgrade,
and a site blocking outbound 22000 - and the third is solved cheaper by the 443
forward. Build a relay only when one of the first two bites, and host it
somewhere with its own public address, which is the only placement that adds a
capability the hub does not have.

Consequences in the template: `relaysEnabled` is false and no relay address is
listed. A relay listen address that resolves to nothing is not harmless -
measured on 2.1.3, the listener supervisor retries without limit and writes a
WRN line per attempt. A relay address also carries a shared token, which is a
secret and cannot ship in a git-tracked template; adding the relay later needs
a mechanism such as `/etc/syncthing/relay.env` read by `sync-node render`. The
commented-out relay line in the template names three `MANUALLY_FIX_RELAY_*`
tokens; note that `render` scans comment-stripped text, so those tokens only
start binding once the line is uncommented.

Expect introduced laptop peers to sit at Disconnected from a guest's point of
view when both are remote: with no global discovery and no relay, two spokes
connect directly only on the same network. Traffic flows through the hub, which
is the design, not a fault.

## GUI and API access

The GUI and the REST API share one listener, bound to `127.0.0.1:8384` inside
the guest. Nothing on the network reaches it, including the host laptop.
`sync-node gui` prints the tunnel:

```sh
ssh -N -L 18384:127.0.0.1:8384 kymf@<guest ip>
```

Then browse `http://127.0.0.1:18384`. Three details decide whether that works,
all measured on 2.1.3:

- The local port is not 8384, because each laptop runs its own Syncthing there.
  Reusing it either fails to bind or shows you the laptop while you read it as
  the guest.
- Browse to `127.0.0.1` or `localhost`. Syncthing checks the `Host` header and
  answers 403 to a host name, on any port.
- There is no login prompt. No GUI user or password is set, so whoever reaches
  the loopback port holds the node's sync config. The tunnel is the access
  control. Every account on the guest can already sudo, so a GUI password
  would add nothing against them - a decision, not an accident.

The GUI's red "Danger" panel appears when it is reachable off loopback with no
authentication - the check is literally whether the address starts `127.`,
`[::1]:` or `/` - so seeing it means the GUI address was changed. The green
"GUI Authentication" banner is a different mechanism: it is driven by
`unackedNotificationID` elements, where listing an ID makes the GUI *show* that
notification. The template deliberately carries none; an earlier draft listed
`authenticationUserAndPassword` believing it suppressed the nag, and produced
it instead.

The API key is a bearer token and nothing more: 128 random bits, generated per
node by `render`, sent in an `X-API-Key` header by programmatic callers. The
browser is admitted because no password is set and carries CSRF tokens instead;
`?apikey=` in a URL is refused. On the guest,
`syncthing cli --home=/srv/dsfxn/.platform/syncthing` reads the key from the
config, which is why `sync-node` needs no `curl` and no key handling of its
own - and it is always the same version as the daemon.

## Operations

**When a device shows Disconnected**, work down this list; it is ordered by
how often each one is the answer:

1. The folder state is irrelevant to this symptom - a missing marker holds the
   folder in error and devices still connect. Do not chase it here.
2. Is the hub's Addresses field still `dynamic` alone on that node? With global
   discovery off and no relay, that only works on the same broadcast domain.
   The most common cause.
3. Windows Defender Firewall with no rule for a service-installed Syncthing
   (a service install gets no interactive prompt; add rules for TCP/UDP 22000
   and UDP 21027).
4. Where is the node? At home local discovery connects laptops in seconds;
   anywhere else only a configured address can.
5. Can it reach the port at all? `Test-NetConnection <hub> -Port 22000` at
   home, the DDNS name from a hotspot.
6. Is the hub listening? Zero listeners on the hub's device panel means the
   container never bound the port - a conflict under host networking.
7. Does the forward have a firewall rule attached?
8. Is the WAN address actually public? Carrier NAT defeats every forward.
9. Both sides must hold the other's device ID; a one-sided entry shows
   Disconnected on that side only.

**Watches**: a watch per file is how `fsWatcherEnabled` sees changes, and
running out is quiet - Syncthing falls back to periodic scans and says so once.
The guests raise `fs.inotify.max_user_watches` to 524288 via
`/etc/sysctl.d/31-syncthing-watches.conf`; the filename must not be
`30-syncthing.conf`, which would replace the package's QUIC-buffer sysctl file
whole. Keep an `.stignore` covering build output; syncing `node_modules` and
`target/` is what exhausts watches and the home upstream link.

**Upgrades**: `autoUpgradeIntervalH` is 0 - the image installs offline,
upgrades belong to the image, and the packaged binary is a `[noupgrade]` build
anyway. The payload `.deb` filename is the version pin; bumping it is a
deliberate act of replacing the file. Keep all three Linux nodes on one version
(the hub container tag is pinned to match) and move one node at a time.

**Monitoring**: `sync-node status` reports folder state and connected peers;
the hub's GUI shows the estate; an alarm can poll `/rest/db/status` on the hub
for a non-empty `errors` count.

**Test remote access from a mobile hotspot, not the home LAN**: a forward is
not exercised from inside, and dialling the DDNS name from inside needs NAT
reflection, which is off. The LAN pair in the address list is what avoids
needing reflection at all.

## Deployment record

Values that define the deployed estate. The hub device ID is a public key;
none of these are secrets.

| Value | Setting |
| ----- | ------- |
| Hub device ID (`ds-nas-01`) | `IHWXMZT-6XMZUH6-YCR37GD-PFHI4NP-6ZNFLP4-2ZRYH2C-4IUONRQ-54FLLAC` |
| Hub DDNS name | `sync.disfix.net` |
| Hub LAN address | `10.66.10.117` |
| Hub public port | `22000` - the forward is deliberately untranslated (see Exposure for the translation option, not taken) |
| Folder ID | not recorded anywhere yet - read it off the hub and fill `MANUALLY_FIX_FOLDER_ID` in the repository template |
| Guest 0010 device ID | `2Q7VKHZ-ZFOYBMQ-ZDZH3CM-3GKTV7B-X2FPPSK-BPFR2W4-K4I2CFE-2O5Q4AJ` |
| Marker name | `.dsfxn-share-marker` |
| Versioning | staggered, 30-day floor, every node |
| Version line | 2.x everywhere; guests and hub pinned 2.1.3 |
