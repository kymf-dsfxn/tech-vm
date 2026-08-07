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
01. Each stage has its own README.
