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
# and linux-firmware -- so 10G is that plus a couple of gigabytes of margin,
# and it is stage 1 this harness exists to exercise.
#
# 12G was the default and did not fit. What has to fit on the host is the
# *virtual* size (see require_space), and measured in the order the commands
# are actually run -- fetch, then create -- 12G was refused outright: ~18.6G
# free, the ISO takes ~1.5G of it and RESERVE keeps 5G, leaving about 12G
# usable and the guard short by tens of megabytes. Free space here drifted
# 18744 -> 18667 MiB across one afternoon, so 11G would have been a coin
# flip. 10G leaves room for that drift.
#
# A stage 2 run on top needs more than this -- ask for it explicitly with
# DISK_SIZE=, and the guard will say whether it fits.
DISK_SIZE="${DISK_SIZE:-10G}"
# Free space no VM image may eat into. $VM_DIR sits under $HOME, which on this
# machine is the same filesystem as the desktop's; filling it does a great deal
# more damage than failing to start a VM does.
RESERVE="${RESERVE:-5G}"
RAM="${RAM:-4G}"
SMP="${SMP:-4}"
VM_DISPLAY="${VM_DISPLAY:-gtk}"
# The fallback size of the ISO, for the space check that has to run before
# there is a file to measure. Measured at 1597014016 bytes -- 1.5G, not the
# 1.3G this said before, which is the whole problem with writing the number
# down: it had already drifted. 2G covers a release or two more of that.
#
# Kept as a constant because `create` must not depend on the network. `fetch`
# is online by definition and asks the mirror instead -- see iso_download_mib.
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
    # Made absolute before the walk. A relative VM_DIR that does not exist yet
    # has nothing to strip -- "vmdir" contains no slash, so the loop below
    # stops immediately and the fallback measures / instead. That is not a
    # rounding error: it reported 146826M of free space for a directory that
    # would have been created on a filesystem with 23125M. Wrong, plausible,
    # and silent, on the one number the whole guard rests on.
    [[ "$dir" == /* ]] || dir="${PWD}/${dir}"
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

# What `create` must set aside for an ISO that is not on disk yet.
#
# require_space reads *live* free space, so without this the answer depended
# on the order the two commands were run in. `create` before `fetch` looked at
# a filesystem the ISO had not landed on, passed, and left the download to eat
# into RESERVE; `fetch` before `create` saw the same ISO on disk and refused
# the identical image. Two orderings, two verdicts, and a headroom figure that
# meant nothing. Counting the absent ISO against the image's budget makes both
# orderings agree.
pending_iso_mib() {
    if [[ -f "$ISO" ]]; then
        echo 0
    else
        echo "$ISO_MIB"
    fi
}

# The largest whole-GiB virtual disk that would pass require_space right now,
# or non-zero when no whole-GiB image would.
#
# It used to floor the answer at 1G, which on a host with less free space than
# RESERVE meant printing "DISK_SIZE=1G" as the way out of a refusal that would
# refuse 1G just the same -- advice that cannot work, offered at the moment
# the operator is least placed to notice. Failing instead lets the caller say
# something true.
suggest_size() {
    local avail_mib reserve_mib gib
    avail_mib=$(free_mib "$VM_DIR")    || return 1
    reserve_mib=$(size_mib "$RESERVE") || reserve_mib=0
    gib=$(( (avail_mib - reserve_mib - $(pending_iso_mib)) / 1024 ))
    (( gib >= 1 )) || return 1
    echo "${gib}G"
}

# require_space <want-mib> <reclaim-mib> <what> [hint...]
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
#
# <reclaim-mib> is space the caller is about to free before it writes, and so
# may spend. Only `reset` has any -- it deletes the current image -- and it
# needs the allowance because it now asks this question *before* the deletion
# rather than after: without it, a reset would be refused on exactly the hosts
# where deleting the old image is what makes room for the new one.
require_space() {
    local want_mib=$1 reclaim_mib=$2 what=$3 hint
    local avail_mib reserve_mib usable_mib

    avail_mib=$(free_mib "$VM_DIR") \
        || die "cannot determine the free space on the filesystem holding ${VM_DIR}"
    reserve_mib=$(size_mib "$RESERVE") \
        || die "invalid RESERVE: '${RESERVE}' (want e.g. 5G)"
    usable_mib=$(( avail_mib + reclaim_mib - reserve_mib ))

    if (( want_mib <= usable_mib )); then
        return 0
    fi

    {
        echo "Not enough space for ${what}."
        echo "  wanted:   $(as_gib "$want_mib")"
        echo "  free:     $(as_gib "$avail_mib") on the filesystem holding ${VM_DIR}"
        if (( reclaim_mib > 0 )); then
            echo "  reclaim:  $(as_gib "$reclaim_mib") that deleting the current image gives back"
        fi
        echo "  reserved: $(as_gib "$reserve_mib") kept for the host (override with RESERVE)"
        echo "  usable:   $(as_gib "$usable_mib")"
        for hint in "${@:4}"; do
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
    if ! grep -qE "^${sum}[[:space:]]" <<< "$sums"; then
        # The bad download has to go, and this is the only place that knows it
        # is bad. Left in place it is a complete-looking .part that the next
        # `curl -C -` resumes from one byte past its end, downloading nothing
        # and failing the same checksum -- so every later `fetch` reproduced
        # this identical error, and the only way forward was an rm the message
        # did not mention. Telling the operator to delete a file the script is
        # holding is worse than deleting it.
        #
        # A full re-download is the correct price even when the cause is
        # innocent -- the mirror rolling to a new release mid-transfer leaves a
        # file that is half one ISO and half another, which is exactly as
        # unusable as a corrupt one.
        rm -f "$file"
        die "sha256 mismatch -- the download was discarded; re-run 'fetch' to try again"
    fi
    echo "sha256 OK"
}

# What the download is about to need, asked of the mirror rather than assumed.
#
# ISO_MIB is a guess that ages: it said 1.3G for an ISO that is 1.5G today,
# and a guard that under-reserves is a guard that passes a fetch which then
# fills the disk. `fetch` is the one caller that is online by definition, so
# it can just ask. Falls back to the constant on any answer it cannot use --
# no Content-Length, a mirror that refuses HEAD, no network at all -- because
# a space check is not worth failing a download over.
#
# The last Content-Length wins: -L follows redirects and each hop contributes
# a header. Plus 64 MiB for the filesystem's own overhead on a file this size.
iso_download_mib() {
    local len
    len=$(curl -fsIL --max-time 20 "$ISO_URL" 2>/dev/null \
              | tr -d '\r' \
              | awk 'tolower($1) == "content-length:" { n = $2 } END { print n }') || len=""
    if [[ "$len" =~ ^[0-9]+$ ]] && (( len > 0 )); then
        echo $(( (len + 1048575) / 1048576 + 64 ))
    else
        echo "$ISO_MIB"
    fi
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
    local need_mib
    need_mib=$(iso_download_mib)
    require_space "$need_mib" 0 "the Arch ISO" \
        "Free some space, or point VM_DIR at another filesystem."
    mkdir -p "$VM_DIR"

    # Written to a .part name and renamed only once curl reports success.
    # Straight into $ISO, an interrupted download leaves a truncated file that
    # every later run's `[[ -f "$ISO" ]]` reports as complete -- a broken ISO
    # that never re-downloads itself. -C - resumes one instead. -f so an HTTP
    # error page is not saved as if it were the ISO.
    echo "Downloading the Arch ISO (about $(as_gib "$need_mib"))..."
    curl -fL -C - -o "${ISO}.part" "$ISO_URL" \
        || die "download failed; the partial file is kept at ${ISO}.part -- re-run 'fetch' to resume"
    verify_iso "${ISO}.part"
    mv "${ISO}.part" "$ISO"
    echo "saved to ${ISO}"
}

# Everything `create` must be able to satisfy, asked without writing or
# deleting anything. Split out so that `reset` can ask it *first* -- see
# cmd_reset. <reclaim-mib> is what the caller is about to free; 0 for create,
# which frees nothing.
create_preflight() {
    local reclaim_mib=$1
    local want_mib iso_mib what suggested
    local -a hints

    need qemu-img
    [[ -f "$OVMF_CODE" ]] \
        || die "no ${OVMF_CODE} -- install edk2-ovmf (sudo pacman -S edk2-ovmf)"
    # Checked as well as OVMF_CODE. Without this the missing file surfaces as
    # a bare `cp` error naming a path the operator never chose.
    [[ -f "$OVMF_VARS_SRC" ]] \
        || die "no ${OVMF_VARS_SRC} -- install edk2-ovmf (sudo pacman -S edk2-ovmf)"

    want_mib=$(size_mib "$DISK_SIZE") \
        || die "invalid DISK_SIZE: '${DISK_SIZE}' (want e.g. 20G)"

    # The ISO is part of this budget whether or not it has been downloaded --
    # `boot` needs both on the same filesystem, so an image that only fits
    # while the ISO is missing does not fit.
    iso_mib=$(pending_iso_mib)
    what="a ${DISK_SIZE} virtual disk"
    if (( iso_mib > 0 )); then
        what="${what} and the ISO still to fetch"
    fi

    if suggested=$(suggest_size); then
        hints=("Retry with a smaller image:  DISK_SIZE=${suggested} ${0} create"
               "Stage 1 needs roughly 8G, so free space first if that is smaller.")
    else
        hints=("No image fits at all: the free space is already inside the ${RESERVE} reserve."
               "Free some space, lower RESERVE, or point VM_DIR at another filesystem.")
    fi

    require_space "$(( want_mib + iso_mib ))" "$reclaim_mib" "$what" "${hints[@]}"
}

# What deleting the current image and vars would hand back to the filesystem.
# Their *actual* allocation, not the virtual size: a qcow2 is sparse, so the
# du figure is what the rm really frees.
reclaimable_mib() {
    local f n total=0
    for f in "$DISK" "$VARS"; do
        [[ -e "$f" ]] || continue
        # cut before tr: du prints the path too, and a VM_DIR with a digit in
        # it would otherwise be read as part of the number.
        n=$(du -sBM "$f" 2>/dev/null | cut -f1 | tr -dc '0-9') || n=""
        if [[ -n "$n" ]]; then
            total=$(( total + n ))
        fi
    done
    echo "$total"
}

cmd_create() {
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

    create_preflight 0

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
    # Asked before anything is destroyed. The old order removed the image and
    # *then* found out create could not rebuild it, which on a full host --
    # the only kind where the guard fires -- turned a working VM into no VM
    # and no way back. Refusing first leaves the operator exactly where they
    # were, with a message naming what to free.
    #
    # The deletion is credited to the budget because it is certain to happen:
    # the check would otherwise be answered against a filesystem still holding
    # the image being replaced, and would refuse resets the host has ample
    # room for -- a stage 1 image sitting at 7G is enough to fail its own
    # replacement.
    create_preflight "$(reclaimable_mib)"
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
  DISK_SIZE          virtual disk size (default 10G, enough for stage 1)
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
