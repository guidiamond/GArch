# Installing alongside an existing system

A start-to-finish walkthrough for adding an encrypted Arch install to a machine
that already has an operating system on it, without wiping anything.

For the whole-disk case, and for what stage 2 does, see [README.md](README.md).

> **Read this first.** This installer has completed one full end-to-end install
> in a VM and produced a booting encrypted system. It has never been run on real
> hardware. Everything else is unit tests (704 of them), a shellcheck-clean tree,
> and two `--dry-run` rehearsals. A green suite is not a booting machine.

---

## 1. What custom mode does

Two things, either or both:

- **Carves** new partitions out of unallocated space.
- **Reuses** partitions that already exist — an ESP is shared rather than
  reformatted; a chosen root partition is formatted.

It never wipes a disk. `sgdisk --zap-all` exists in exactly one line of
`lib/disk.sh`, gated behind a flag only whole-disk mode sets.

Afterwards, phase 6 wires the menus in both directions: a chainload entry for
the new install is added to every other GRUB it finds, and the other systems'
bootloaders are added to the new install's menu. Every edit to another system is
a marker-delimited block with a numbered backup, and it never runs another
system's `grub-mkconfig`.

---

## 2. Before you start

**Back up the ESP of the system you are keeping.** It holds the only copy of its
bootloader.

```sh
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINT     # find it
sudo dd if=/dev/sdXN of=~/esp-backup.img bs=4M status=progress
```

**Record what must not change**, so you can prove afterwards that it did not:

```sh
sudo md5sum /boot/EFI/EFI/BOOT/BOOTX64.EFI /boot/grub/grub.cfg
stat -c '%n mtime=%y' /boot/grub/grub.cfg /etc/grub.d/40_custom
```

**Have an Arch ISO on USB** — to install, and to repair GRUB if you need to.

**Push the branch.** The ISO clones from the remote, so a fresh machine can only
fetch what has been pushed.

---

## 3. Boot the ISO

Boot in **UEFI mode**, not legacy/CSM. Confirm, and get networking up:

```sh
ls /sys/firmware/efi && echo "UEFI ok"
iwctl                       # wifi, if needed
ping -c2 archlinux.org
```

---

## 4. Fetch the installer

```sh
pacman -Sy --noconfirm git
git clone -b <branch> https://github.com/guidiamond/GArch.git .dotfiles
cd .dotfiles/arch_setup
```

The explicit `.dotfiles` destination matters: the repository is named GArch, so
without it git creates `GArch/` and the next line has nothing to enter.

---

## 5. Rehearse

```sh
./install.sh --dry-run
```

This writes nothing — every destructive command is printed with a `[dry-run]`
prefix instead of being run. Check the transcript before going further:

- **`sgdisk --zap-all` appears zero times.** If it appears in custom mode, stop.
- The carve sectors lie inside the gap the installer reported.
- The **NOT TOUCHED** list names every existing partition, by full device path.
- Nothing is printed without a `[dry-run]` prefix.

A rehearsal on an installed host is safe: the preflight's keyring refresh and
mirrorlist ranking are withheld too, as are `timedatectl` and `loadkeys`.

---

## 6. Install

```sh
./install.sh
```

### Answering the prompts

| Prompt | What to give it |
|---|---|
| Partitioning mode | **`2`** for custom. `1` wipes a whole disk. |
| Reuse an existing EFI System Partition? | Only offered for an ESP of **2 GiB or more** — the ESP is mounted at `/boot`, so it must hold a kernel and two initramfs images. Smaller ones are listed as too small to share and a new one is carved. |
| Disk to install onto | The **whole disk**, e.g. `/dev/nvme0n1` — not a partition. Partitions are rejected. |
| Carve out of unallocated space? | `y` to use a gap; `n` to pick an existing partition to format as root. |
| Type YES to proceed | Read the ledger above it first. |
| Encrypt root with LUKS2? | `y`, then a passphrase twice. |
| Removable fallback `\EFI\BOOT\BOOTX64.EFI`? | **Not offered** if that path already exists — it is another system's bootloader and the installer refuses to overwrite it. When it is offered, `n` is the better-tested answer: `y` takes grub-install's `--removable` path, where it ignores the bootloader id and skips firmware registration. |
| Name in the boot menu | Something distinct per install, e.g. `ARCH2`. Two installs sharing an ESP may not share an id. |
| Add an entry to `<other OS>`'s boot menu? | `y` writes a marker-delimited block into its `40_custom` and `grub.cfg`, backing both up first. |
| Add `<bootloader>` to this install's menu? | `y` adds a chainload entry so you can reach that system from the new one. |

### The confirmation screen

Before anything is written, custom mode prints three lists:

```
WILL BE FORMATTED -- all data on these is destroyed
WILL BE PRESERVED -- adopted as-is, not formatted
NOT TOUCHED       -- no write of any kind
```

Every existing partition on the machine should appear under **NOT TOUCHED** or
**PRESERVED**. If one you care about is under **FORMATTED**, answer anything
other than `YES`.

---

## 7. After it finishes

Stage 1 produces a **minimal system with no desktop** — a text login is the
expected result.

```sh
reboot                                    # remove the USB
~/.dotfiles/arch_setup/provision.sh       # stage 2, from the new system
```

### Check it did what it said

From the new install:

```sh
findmnt -no SOURCE /                       # /dev/mapper/cryptroot if encrypted
efibootmgr -v                              # your new firmware entry
grep -c chainloader /boot/grub/grub.cfg    # entries for the other systems
```

From the system you kept:

```sh
grep -c 'BEGIN arch-installer' /boot/grub/grub.cfg   # exactly 1
ls /boot/grub/*.bak.* /etc/grub.d/*.bak.*            # the backups it made
sudo md5sum /boot/EFI/EFI/BOOT/BOOTX64.EFI           # must match section 2
```

### Undoing the edits to another system

The installer prints the exact `cp` commands at the end of a run. They restore
from the numbered `.bak.<ID>.<n>` files it left beside `grub.cfg` and
`40_custom`. A second run makes `.2`, never overwriting `.1`.

---

## 8. If something goes wrong

**The old system will not boot.** From the ISO:

```sh
mount /dev/sdXN /mnt              # its root
mount /dev/sdXM /mnt/boot/EFI     # its ESP
arch-chroot /mnt
grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
```

Add `--removable` if that system booted from `\EFI\BOOT\BOOTX64.EFI`.

**The ESP is damaged.** Restore the image from section 2:

```sh
sudo dd if=~/esp-backup.img of=/dev/sdXN bs=4M status=progress
```

**The firmware menu is empty.** Most firmware has a one-time boot menu
(F12/F8/Esc) that can boot a file directly — choose
`\EFI\BOOT\BOOTX64.EFI` on the ESP.

---

## 9. Testing it without risking a machine

`test/vm.sh` runs the whole thing under QEMU + OVMF against a fixture disk that
already carries an ESP, an ext4 Arch install with its own GRUB, and a gap:

```sh
export VM_DIR=/var/tmp/arch-installer-vm
./test/vm.sh reset --scenario coexist    # --scenario every time, or you get a blank disk
./test/vm.sh boot                        # run install.sh inside the guest; its disk is /dev/vda
./test/vm.sh disk                        # boot what it built
./test/vm.sh verify --scenario coexist   # assert the neighbour survived
```

Needs qemu, edk2-ovmf, guestfish and an Arch ISO (`./test/vm.sh fetch`).
