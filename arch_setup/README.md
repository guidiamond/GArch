# arch_setup

Two-stage installer that rebuilds this environment on fresh hardware:
UEFI + LUKS2 + Btrfs Arch, bspwm on X11, dotfiles stowed, `ptbr` keyboard
layout, lightdm.

## Stage 1 -- from the Arch live ISO

Root only. UEFI only. Wipes the disk you point it at.

```sh
pacman -Sy --noconfirm git
git clone https://github.com/guidiamond/GArch.git .dotfiles
cd .dotfiles/arch_setup && ./install.sh
```

The repository is public, so the clone asks for no credentials. The explicit
`.dotfiles` destination is not decoration: the repository is named GArch, so
without it git makes a `GArch/` and the next line has nothing to cd into. That
clone is copied into the new system at `/home/<user>/.dotfiles`, so stage 2
starts with the repo already there.

The clone above takes the default branch, which must therefore be a branch that
actually carries this installer -- `install.sh`, `lib/`, `packages/`. Until this
work is merged, add `-b arch-installer` to the clone, and push the branch first:
a fresh machine can only fetch what the remote has.

Five phases: preflight (UEFI, network, NTP, keyring, mirrors), locale, disk,
pacstrap, chroot. Produces a minimal bootable system -- LUKS2 (prompted,
default yes) -> Btrfs (`@`, `@home`, `@snapshots`, `@var_log`, mounted
`noatime,compress=zstd`), a FAT32 ESP at `/boot` (2G by default -- it holds
both initramfs images), GRUB, zram at half of RAM,
NetworkManager enabled, microcode picked from the CPU. Nothing graphical.

Nothing on disk is written before the Type-YES gate in phase 3.

| Flag | Effect |
|---|---|
| `--dry-run` | Walk the whole prompt flow and print destructive commands instead of running them. `DRY_RUN=true` in the environment does the same -- and only the exact strings `true` and `false` are accepted, so a typo aborts rather than wiping a disk |
| `-h`, `--help` | Print the usage and exit |

A dry run is not purely a rehearsal in one place: it generates the chroot
config and script for real, into a temp dir, because that step is the one most
likely to abort a real run late -- after the disk is gone.

## Stage 2 -- on the booted machine

```sh
~/.dotfiles/arch_setup/provision.sh
```

Run as your normal user, never root; it asks for sudo up front. Idempotent --
re-run it any time to re-sync this machine with the repo.

| Flag | Effect |
|---|---|
| `--skip-packages` | Config only; skips yay and all three package lists. Fast re-run |
| `--skip-gpu` | Skip the GPU phase. It rebuilds the initramfs and `grub.cfg`, which you rarely want on a machine that already boots |
| `--no-optional` | Never prompt for the optional application group |
| `-h`, `--help` | Print the usage and exit |

Eight phases: dotfiles, yay, packages, shell, keyboard, graphics, display
manager, services. Every step reports pass/fail in a closing summary, the run
exits non-zero if any of them failed, and the whole thing is logged to
`~/arch-provision-<YYYYmmdd-HHMMSS>.log` (the last 10 are kept).

With no terminal on stdin -- cron, `ssh -n`, a pipe -- the two phases that ask
a question, the optional group and the GPU driver, skip themselves rather than
answer blind. Everything else runs unattended.

`stow` backs up any real file in the way, under `~/.dotfiles-backup-<stamp>/`,
and never uses `--adopt`. Set `DOTFILES_DIR` to stow a checkout somewhere other
than `~/.dotfiles`; otherwise the repo this script lives in wins.

## Package lists

| File | Installed by | How |
|---|---|---|
| `packages/base.txt` | stage 1 | `pacstrap`, plus the detected microcode |
| `packages/repo.txt` | stage 2 | one `pacman -S --needed` transaction |
| `packages/aur.txt` | stage 2 | `yay -S`, one at a time, failures reported not fatal |
| `packages/optional.txt` | stage 2 | prompted as a group, then `yay -S` the same way |

Blank lines and comments are ignored, inline ones included. Do not re-implement
that with `grep`: `pkg_list` is the one definition, and a hand-written pattern
diverges the first time somebody writes `foo  # needed by bar`. To check a repo
list still resolves:

```sh
source lib/ui.sh; source lib/packages.sh
pkg_list packages/repo.txt | while read -r p; do
    pacman -Si "$p" >/dev/null 2>&1 || echo "MISSING: $p"
done
```

`pacman -Si` only knows the repos, so use `yay -Si` for `aur.txt` and
`optional.txt`.

## Layout

```
install.sh     stage 1 orchestrator (root, live ISO)
provision.sh   stage 2 orchestrator (normal user, booted host)
lib/ui.sh        prompts, colours, banners
lib/disk.sh      partition plan, LUKS, Btrfs -- the only module that destroys data
lib/system.sh    pure transforms, config-file edits, host probes and host actions
lib/setup.sh     the setup_* family plus enable_services -- needs sudo, stage 2 only
lib/packages.sh  list parsing, pacman/yay, yay bootstrap
lib/chroot.sh    generates the script arch-chroot runs in phase 5
lib/dotfiles.sh  ~/.netrc, clone, stow, and staging a clone into the new root
etc/             config files installed verbatim (zram, lightdm, nvidia hook)
```

`system.sh` and `setup.sh` are split at the sudo seam: `system.sh` is safe in
both stages and parts of it are injected into the generated chroot script,
`setup.sh` is neither.

## Tests

```sh
./test/run.sh          # shellcheck over every script, then bats
```

230 tests over the pure functions in `lib/` and the sourceable parts of both
orchestrators -- partition-plan arithmetic, mkinitcpio hook and module
ordering, GRUB cmdline editing, netrc handling, stow conflict detection,
package-list parsing, the step/summary machinery. The destructive paths are
covered by `--dry-run` and the VM below.

`run.sh` refuses to run as root: the suite puts stub `pacman` and `reflector`
binaries on `PATH`, and a call that missed a stub would hit this machine rather
than a target. Unprivileged, it fails loudly instead.

```sh
./test/vm.sh fetch     # download the Arch ISO (~1.3G) and checksum it
./test/vm.sh create    # qcow2 image + a writable OVMF vars file
./test/vm.sh boot      # boot the ISO, run install.sh inside
./test/vm.sh disk      # boot the installed disk
./test/vm.sh reset     # delete the image and the vars, then create again
```

Needs `qemu`, `edk2-ovmf` and access to `/dev/kvm`. The image is 12G by
default, which fits stage 1 (roughly 8G) and not much else; a stage 2 run on
top wants more, so ask for it: `DISK_SIZE=20G ./test/vm.sh create`.

`create` checks the *virtual* size against the host's free space and refuses
rather than warns. qcow2 is sparse, so without that check `create` succeeds on
a full disk and the guest dies of `ENOSPC` an hour later -- from inside the VM
that looks like a corrupt package or a btrfs I/O error, never like a full host.
`RESERVE` (default 5G) is the margin kept for the host, `ALLOW_LOW_SPACE=1`
overrides the refusal, `VM_DIR` moves everything to another filesystem.

## Not supported

BIOS/MBR, dual-boot and os-prober, Wayland, encrypted `/boot` (it is the ESP),
TPM2 unlock, hibernate (the only swap is zram, and no resume hook is set),
snapshot automation -- `@snapshots` is created and nothing uses it.
