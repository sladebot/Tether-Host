# Ubuntu installer auto-eject evidence

Tether Host can remove the manual Ubuntu installer from **future boots** after a
clean VM stop, when the stopped raw disk contains strong evidence of a bootable
Ubuntu installation. The ISO file remains in the VM bundle under its ejected
name so recovery is possible. The verifier never mounts or writes the disk.

`UbuntuInstallationVerifier` recognizes only an unencrypted GPT disk with a
FAT32 EFI System Partition and a clean ext4 Linux root partition. It requires:

- `EFI/UBUNTU/SHIMAA64.EFI` or `GRUBAA64.EFI` on the EFI partition, with a
  nonempty PE/COFF executable header;
- `/usr/lib/os-release` declaring `ID=ubuntu`;
- `/etc/fstab` mounting that ext4 filesystem's UUID at `/`;
- a nonempty `/boot/grub/grub.cfg`, plus nonempty regular kernel and initrd
  files in `/boot` with matching version suffixes;
- a human account in `/etc/passwd` with a home directory under `/home`.

This is evidence of an installed, bootable system, not a formal success event
from Ubuntu's installer. The examined incomplete disk had only
`casper-md5check.json` under `/var/log/installer`, so no installer log is used
as a completion signal.
Unsupported layouts (including encrypted or LVM roots), unexpected file
systems, corruption, and unreadable disks retain the installer for recovery.
The parser limits individual reads, total reads, directory sizes, and extent
traversal; it treats any unsupported structure as inconclusive.
