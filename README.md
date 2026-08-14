# tech-vm

Build a per-host VM from a stock Ubuntu ISO with no operator action. The
pipeline has three numbered stages, and the numbers state the order.

- `00.host-config` holds every input that defines a host: the boot control, the
  guest payload, and the provisioning scripts. One tree answers "what makes this
  host this host".
- `01.iso-build` reads `00.host-config` and bakes a per-host Ubuntu 26.04 ISO
  that installs fully offline. The ISO carries the autoinstall control, an
  offline apt repository, the guest payload, and the provisioning scripts.
- `02.vm-create` reads the ISO that stage 01 built and creates the VMware
  Workstation VM.

A booted VM installs and provisions itself: `guest-install.sh` runs at install
and `guest-firstboot.sh` runs at first boot, both staged onto the ISO by stage
01. Each stage has its own README, kept to what the stage is and how it is
used.

Three technical capabilities span the stages, and each has its own design
document - the rationale lives there, not in READMEs or code comments:

- `capability.encrypted-datadisk.md` - the LUKS data disk: never unlocked at
  boot, the operator lifecycle, the invariants, and the gated-service pattern.
- `capability.data-synchronisation.md` - the Syncthing replication: estate
  topology, the folder marker invariant, permission replication, node
  bring-up, connectivity and operations.
- `capability.host-data-access.md` - data between host and guest: the guest
  serves its share over SMB, and reads the host drives over HGFS at
  /mnt/C, /mnt/X, /mnt/S.
