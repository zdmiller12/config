# Virtualization

No module installs a virtualization stack. The preserved Windows dual-boot
serves that need with full hardware access — see §12 of the
[design spec](../docs/superpowers/specs/2026-10-14-machine-bootstrap-design.md) for
why it was dropped.

If you do want local VMs later:

```sh
sudo apt-get install qemu-system-x86 libvirt-daemon-system libvirt-clients \
    virt-manager ovmf bridge-utils
sudo usermod -aG libvirt,kvm "$USER"
```

Two things that are easy to lose an hour to, which is the only reason this
file exists:

1. **Group membership needs a full logout.** You must be in *both* `libvirt`
   and `kvm`. `newgrp` affects only the current shell — log out and back in, or
   the GUI will fail with permission errors that look like something else.
2. **`ovmf` is mandatory for a Windows 11 guest.** Win11 requires UEFI with
   Secure Boot and a TPM 2.0 device. Without `ovmf` installed, virt-manager
   offers no UEFI firmware option and the installer refuses to proceed.
