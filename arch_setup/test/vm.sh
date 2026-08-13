#!/bin/bash
# QEMU + OVMF harness for testing install.sh against a fake disk.
#
#   ./test/vm.sh fetch    download the latest Arch ISO
#   ./test/vm.sh create   make the qcow2 disk and a writable OVMF vars file
#   ./test/vm.sh boot     boot the ISO (run install.sh inside)
#   ./test/vm.sh disk     boot the installed disk
#   ./test/vm.sh reset    delete the disk image and start over
#
# The one script here that runs on the *host* rather than on the target, so it
# deliberately sources nothing from lib/. It gets used precisely when lib/ is
# being changed, and a harness that breaks along with the code it is meant to
# exercise is worth nothing.
set -euo pipefail

VM_DIR="${VM_DIR:-${HOME}/.cache/arch-installer-vm}"
DISK="${VM_DIR}/disk.qcow2"
VARS="${VM_DIR}/OVMF_VARS.4m.fd"
ISO="${VM_DIR}/archlinux.iso"
ISO_URL="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
SUMS_URL="https://geo.mirror.pkgbuild.com/iso/latest/sha256sums.txt"
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS_SRC="/usr/share/edk2/x64/OVMF_VARS.4m.fd"

# What the guest clones, and the branch that actually carries the installer.
# A variable rather than a literal so that the day this branch merges, one
# environment override -- or one line here -- retargets the whole recipe;
# there is nothing to hunt for in the middle of a heredoc.
VM_REPO="${VM_REPO:-https://github.com/guidiamond/GArch.git}"
VM_BRANCH="${VM_BRANCH:-arch-installer}"

# Sized to the job, not to the round number a desktop reaches for. Stage 1
# writes roughly 6-8G -- a 2G ESP, plus base, base-devel, linux, linux-headers
# and linux-firmware -- so 12G is that plus half again, and it is stage 1 this
# harness exists to exercise.
#
# The plan's 40G was not just generous, it was unusable: what has to fit on
# the host is the *virtual* size (see require_space), and 40G exceeds the free
# space here several times over, so every `create` would have been refused. A
# stage 2 run on top needs more than 12G -- ask for it explicitly with
# DISK_SIZE=, and the guard will say whether it fits.
DISK_SIZE="${DISK_SIZE:-12G}"
# Free space no VM image may eat into. $VM_DIR sits under $HOME, which on this
# machine is the same filesystem as the desktop's; filling it does a great deal
# more damage than failing to start a VM does.
RESERVE="${RESERVE:-5G}"
RAM="${RAM:-4G}"
SMP="${SMP:-4}"
VM_DISPLAY="${VM_DISPLAY:-gtk}"
# The ISO is ~1.3G today. Allowing 2G covers a release or two of growth; it
# only ever sizes the pre-download space check.
ISO_MIB=2048

die()  { echo "vm.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }

# --- space arithmetic ------------------------------------------------------

# "20G" or "512M" -> MiB. The whole free-space guard rests on this, so it
# refuses what it does not understand instead of guessing: a parse that
# silently yielded 0 would turn every check below into a no-op, which is the
# exact failure the guard exists to prevent.
size_mib() {
    local n
    [[ "$1" =~ ^([0-9]+)([MmGg])$ ]] || return 1
    n=${BASH_REMATCH[1]}
    case "${BASH_REMATCH[2]}" in
        [Gg]) echo $(( n * 1024 )) ;;
        *)    echo "$n" ;;
    esac
}

# Free MiB on the filesystem that would hold $1. The directory need not exist
# yet -- df exits 1 on a missing path -- so walk up to the nearest ancestor
# that does. Same filesystem either way, which is all this needs.
free_mib() {
    local dir=$1 avail
    while [[ ! -d "$dir" && "$dir" == */?* ]]; do
        dir="${dir%/*}"
    done
    [[ -d "$dir" ]] || dir=/
    avail=$(df -BM --output=avail "$dir" 2>/dev/null | tail -n1 | tr -dc '0-9')
    [[ -n "$avail" ]] || return 1
    echo "$avail"
}

# MiB -> "12.3G". For messages only; nothing branches on this.
as_gib() { awk -v m="$1" 'BEGIN { printf "%.1fG", m / 1024 }'; }

# The largest whole-GiB virtual disk that would pass require_space right now.
suggest_size() {
    local avail_mib reserve_mib gib
    avail_mib=$(free_mib "$VM_DIR")  || { echo "10G"; return 0; }
    reserve_mib=$(size_mib "$RESERVE") || reserve_mib=0
    gib=$(( (avail_mib - reserve_mib) / 1024 ))
    if (( gib < 1 )); then
        gib=1
    fi
    echo "${gib}G"
}

# require_space <want-mib> <what> [hint...]
#
# qemu-img create writes a *sparse* qcow2, so `create` succeeds instantly no
# matter how little room is left, and the shortfall only surfaces an hour
# later when the guest's writes hit ENOSPC on the host. From inside the VM
# that looks like pacstrap choking on a corrupt package, or btrfs throwing I/O
# errors -- it never once says "the host is full", so the operator debugs the
# installer instead. And because $VM_DIR shares a filesystem with $HOME, the
# same overrun takes the desktop down with it.
#
# So the check is against the *virtual* size rather than the current file
# size: only a virtual size that fits in the free space guarantees the guest
# runs out first, with an error that means what it says.
#
# It refuses rather than warns. A warning here would scroll away behind the
# installer's own output long before it mattered, and the two costs are not
# symmetric: obeying a false refusal costs one `DISK_SIZE=` prefix, ignoring a
# true one costs a wiped install and possibly a wedged desktop.
# ALLOW_LOW_SPACE=1 is the override for when the operator knows better.
require_space() {
    local want_mib=$1 what=$2 hint
    local avail_mib reserve_mib usable_mib

    avail_mib=$(free_mib "$VM_DIR") \
        || die "cannot determine the free space on the filesystem holding ${VM_DIR}"
    reserve_mib=$(size_mib "$RESERVE") \
        || die "invalid RESERVE: '${RESERVE}' (want e.g. 5G)"
    usable_mib=$(( avail_mib - reserve_mib ))

    if (( want_mib <= usable_mib )); then
        return 0
    fi

    {
        echo "Not enough space for ${what}."
        echo "  wanted:   $(as_gib "$want_mib")"
        echo "  free:     $(as_gib "$avail_mib") on the filesystem holding ${VM_DIR}"
        echo "  reserved: $(as_gib "$reserve_mib") kept for the host (override with RESERVE)"
        echo "  usable:   $(as_gib "$usable_mib")"
        for hint in "${@:3}"; do
            echo "${hint}"
        done
    } >&2

    if [[ "${ALLOW_LOW_SPACE:-}" == 1 ]]; then
        echo "continuing anyway (ALLOW_LOW_SPACE=1)" >&2
        return 0
    fi
    exit 1
}

# The image grows while the VM runs, so the figure checked at `create` time is
# already stale by the time anything boots. A warning, not a refusal: the
# image exists by now, the operator may be resuming a run they know fits, and
# refusing to boot an already-built VM helps nobody.
warn_low_space() {
    local avail_mib reserve_mib
    avail_mib=$(free_mib "$VM_DIR")    || return 0
    reserve_mib=$(size_mib "$RESERVE") || return 0
    if (( avail_mib > reserve_mib )); then
        return 0
    fi
    {
        echo ""
        echo "warning: only $(as_gib "$avail_mib") free on the filesystem holding ${VM_DIR}."
        echo "         The image grows as the guest writes. If the host fills up, the"
        echo "         install dies with I/O errors that read like installer bugs."
        echo ""
    } >&2
}

# --- subcommands -----------------------------------------------------------

# Integrity, not authenticity. This catches the truncated or corrupted
# download, which is the failure this harness actually hits; it does not check
# the ISO's GPG signature, so it is no defence against a hostile mirror.
verify_iso() {
    local file=$1 sums sum
    need sha256sum
    if ! sums=$(curl -fsL "$SUMS_URL"); then
        echo "warning: could not fetch ${SUMS_URL}; skipping the checksum" >&2
        return 0
    fi
    sum=$(sha256sum "$file" | cut -d' ' -f1)
    # Matched by hash rather than by filename: the 'latest' directory has
    # listed the ISO under its versioned name in some releases and under the
    # unversioned one in others, and the hash is the same either way. Anchored
    # at the start of a line and bounded by whitespace so it matches the hash
    # field only.
    grep -qE "^${sum}[[:space:]]" <<< "$sums" \
        || die "sha256 mismatch for ${file} -- delete it and re-run 'fetch'"
    echo "sha256 OK"
}

cmd_fetch() {
    need curl
    # `if`, not `[[ ... ]] && { ...; return 0; }`: that form leaves a non-zero
    # status behind when the file is absent, and as the last statement of a
    # function it would return 1 straight into a `set -e` caller. Verified:
    # the AND-list is exempt from errexit itself, the function's return value
    # is not.
    if [[ -f "$ISO" ]]; then
        echo "ISO already at ${ISO}"
        return 0
    fi
    require_space "$ISO_MIB" "the Arch ISO" \
        "Free some space, or point VM_DIR at another filesystem."
    mkdir -p "$VM_DIR"

    # Written to a .part name and renamed only once curl reports success.
    # Straight into $ISO, an interrupted download leaves a truncated file that
    # every later run's `[[ -f "$ISO" ]]` reports as complete -- a broken ISO
    # that never re-downloads itself. -C - resumes one instead. -f so an HTTP
    # error page is not saved as if it were the ISO.
    echo "Downloading the Arch ISO (~1.3G)..."
    curl -fL -C - -o "${ISO}.part" "$ISO_URL" \
        || die "download failed; the partial file is kept at ${ISO}.part -- re-run 'fetch' to resume"
    verify_iso "${ISO}.part"
    mv "${ISO}.part" "$ISO"
    echo "saved to ${ISO}"
}

cmd_create() {
    need qemu-img
    [[ -f "$OVMF_CODE" ]] \
        || die "no ${OVMF_CODE} -- install edk2-ovmf (sudo pacman -S edk2-ovmf)"
    # Checked as well as OVMF_CODE. Without this the missing file surfaces as
    # a bare `cp` error naming a path the operator never chose.
    [[ -f "$OVMF_VARS_SRC" ]] \
        || die "no ${OVMF_VARS_SRC} -- install edk2-ovmf (sudo pacman -S edk2-ovmf)"

    # `create` never overwrites. A re-run would otherwise throw away a
    # half-finished install without a word, and the OVMF vars with it -- which
    # is where UEFI keeps the boot entry `disk` needs. `reset` is the
    # subcommand licensed to destroy things, and it says so in its name.
    #
    # `if`, not `[[ -e ... ]] && die`, for the reason cmd_fetch gives: the
    # AND-list form leaves a non-zero status behind on the common path.
    if [[ -e "$DISK" ]]; then
        die "${DISK} already exists -- './test/vm.sh reset' to start over"
    fi
    if [[ -e "$VARS" ]]; then
        die "${VARS} already exists -- './test/vm.sh reset' to start over"
    fi

    local want_mib
    want_mib=$(size_mib "$DISK_SIZE") \
        || die "invalid DISK_SIZE: '${DISK_SIZE}' (want e.g. 20G)"
    require_space "$want_mib" "a ${DISK_SIZE} virtual disk" \
        "Retry with a smaller image:  DISK_SIZE=$(suggest_size) ${0} create" \
        "Stage 1 needs roughly 8G, so free space first if that suggestion is smaller."

    mkdir -p "$VM_DIR"
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
    cp "$OVMF_VARS_SRC" "$VARS"
    echo "created ${DISK} (${DISK_SIZE}) and ${VARS}"
}

qemu_run() {
    need qemu-system-x86_64
    [[ -f "$OVMF_CODE" ]] || die "no ${OVMF_CODE} -- install edk2-ovmf"
    # Its own check, separate from the disk's: `reset` removes both, and a
    # hand-deleted vars file otherwise reaches qemu as an unreadable pflash.
    [[ -f "$VARS" ]] || die "no ${VARS} -- run './test/vm.sh create' first"
    # -enable-kvm and -cpu host both need /dev/kvm. Without it qemu would fall
    # back to full emulation, where pacstrap takes hours rather than minutes;
    # saying so here beats letting the operator discover it in phase 4.
    [[ -r /dev/kvm && -w /dev/kvm ]] \
        || die "no access to /dev/kvm (is kvm_intel/kvm_amd loaded, and are you in the 'kvm' group?)"

    qemu-system-x86_64 \
        -enable-kvm \
        -m "$RAM" \
        -smp "$SMP" \
        -machine q35 \
        -cpu host \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$VARS" \
        -drive file="$DISK",if=virtio,format=qcow2 \
        -netdev user,id=n0 -device virtio-net,netdev=n0 \
        -vga virtio -display "$VM_DISPLAY" \
        "$@"
}

# The recipe below is typed at a bare console inside a VM, so every way it can
# go wrong costs an ISO boot to find out about. This is the one failure that
# can be settled from the host beforehand: whether the branch the clone names
# is on the remote at all.
#
# Not fatal when it cannot be answered. An unreachable remote or a host
# without git says nothing about the branch, and refusing to boot over it
# would break the offline re-run of a VM whose clone already happened.
require_branch() {
    local heads
    if ! command -v git >/dev/null 2>&1; then
        echo "warning: no git on the host, so ${VM_BRANCH} was not checked" >&2
        return 0
    fi
    if ! heads=$(git ls-remote --heads "$VM_REPO" "$VM_BRANCH" 2>/dev/null); then
        echo "warning: could not reach ${VM_REPO}, so ${VM_BRANCH} was not checked" >&2
        return 0
    fi
    # ls-remote exits 0 with no output for a branch that does not exist, so it
    # is the emptiness that answers the question, not the status.
    [[ -n "$heads" ]] || die "\
${VM_BRANCH} is not on ${VM_REPO} yet, so the guest has nothing to clone.

  git push -u origin ${VM_BRANCH}

Push it, then boot. The default branch carries arch_setup.sh and yay_deps.txt
and no install.sh, so booting first only spends an ISO boot to reach a
'No such file or directory' inside the VM."
}

cmd_boot() {
    [[ -f "$ISO" ]]  || die "no ISO -- run './test/vm.sh fetch' first"
    [[ -f "$DISK" ]] || die "no disk image -- run './test/vm.sh create' first"
    require_branch
    # The repository is guidiamond/GArch; the *directory* it clones into is
    # .dotfiles. Hence the explicit destination below -- without it git names
    # the new directory after the repo and the next line has nothing to cd
    # into. Checked against GitHub rather than copied from anywhere: the
    # dot-prefixed guidiamond/.dotfiles this used to name 404s for the owner's
    # own token, while GArch answers an *anonymous* git-upload-pack with 200.
    # So the repo is public and the clone needs no credentials.
    #
    # Interpolating heredoc: the branch and URL are settings, and a recipe
    # that disagreed with the check above would be worse than no check.
    cat <<EOF
Booting the Arch ISO. Inside the VM:

  pacman -Sy --noconfirm git
  git clone -b ${VM_BRANCH} ${VM_REPO} .dotfiles
  cd .dotfiles/arch_setup
  ./install.sh --dry-run    # rehearse the whole prompt flow, write nothing
  ./install.sh              # the real run

The -b is load-bearing: the default branch has no install.sh. That the branch
is on the remote was checked before this window opened.

The repository is public, so the clone asks for no credentials. (Stage 2's
~/.netrc prompt is a separate thing, on the installed system.)

The virtio disk appears as /dev/vda -- answer the "Disk to install to"
prompt with exactly that. Every other prompt can take its default.

When install.sh finishes, close this window and run './test/vm.sh disk'
to check that what it built actually boots.
EOF
    warn_low_space
    qemu_run -cdrom "$ISO" -boot d
}

cmd_disk() {
    [[ -f "$DISK" ]] || die "no disk image -- run './test/vm.sh create' first"
    warn_low_space
    qemu_run
}

# The one destructive subcommand, and so the only path allowed to remove an
# existing image -- see cmd_create.
cmd_reset() {
    rm -f "$DISK" "$VARS"
    echo "removed the disk image and the OVMF vars (the ISO is kept)"
    cmd_create
}

usage() {
    cat <<'USAGE'
Usage: test/vm.sh {fetch|create|boot|disk|reset}

A QEMU + OVMF harness for running install.sh end to end against a fake disk.

  fetch    download the latest Arch ISO into $VM_DIR, and checksum it
  create   make the qcow2 image and a writable copy of the OVMF vars
  boot     boot the ISO with the disk attached -- run install.sh in here
  disk     boot the installed disk, to check stage 1 produced a bootable system
  reset    delete the disk image and the OVMF vars, then create them again

Environment:
  VM_DIR             where everything lives (default ~/.cache/arch-installer-vm)
  DISK_SIZE          virtual disk size (default 12G, enough for stage 1)
  RESERVE            free space kept for the host (default 5G)
  RAM, SMP           guest memory and vCPUs (default 4G, 4)
  VM_DISPLAY         qemu -display backend (default gtk)
  VM_REPO            repository the guest clones (default guidiamond/GArch)
  VM_BRANCH          branch it clones; must be pushed (default arch-installer)
  ALLOW_LOW_SPACE=1  proceed past the free-space refusal

Testing uncommitted work:
  The guest clones from the remote, so `boot` only ever tests what has been
  pushed. To run the working tree as it stands, hand qemu a 9p export -- add
  to the qemu-system-x86_64 line in qemu_run():

    -virtfs local,path=REPO,mount_tag=dotfiles,security_model=mapped-xattr,readonly=on

  and inside the guest, in place of the clone:

    mkdir -p /mnt/dotfiles
    mount -t 9p -o trans=virtio dotfiles /mnt/dotfiles
    cd /mnt/dotfiles/arch_setup

  Deliberately an edit you make rather than a flag this script carries. It is
  the better way to test an unpushed change, but it cannot be verified from
  outside a VM, and it has no business sitting on the path of `boot` -- the
  one command this harness exists to run. readonly=on is what keeps a guest
  mid-install from writing to your checkout; drop it only knowing that.
USAGE
}

main() {
    case "${1:-}" in
        fetch)      cmd_fetch  ;;
        create)     cmd_create ;;
        boot)       cmd_boot   ;;
        disk)       cmd_disk   ;;
        reset)      cmd_reset  ;;
        -h|--help)  usage      ;;
        *)          usage >&2; exit 1 ;;
    esac
}

# Guarded like provision.sh: without it, sourcing this file to reach size_mib
# or free_mib would parse the sourcing shell's own arguments and start a VM.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
