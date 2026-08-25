#!/bin/bash
# Stage 1: Arch install from the live ISO. Root only. Destructive.
#
#   pacman -Sy --noconfirm git
#   git clone https://github.com/guidiamond/GArch.git .dotfiles
#   cd .dotfiles/arch_setup && ./install.sh
#
# The repository is GArch, the directory is .dotfiles -- hence the explicit
# destination on the clone, without which git would create GArch/ and the next
# line would have nothing to cd into. Public, so no credentials are needed.
#
# Run `./install.sh --help` for the flags; usage() below is the one copy.
set -euo pipefail

ARCH_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ARCH_SETUP_DIR

# shellcheck source=lib/ui.sh
source "${ARCH_SETUP_DIR}/lib/ui.sh"
# shellcheck source=lib/disk.sh
source "${ARCH_SETUP_DIR}/lib/disk.sh"
# shellcheck source=lib/boot.sh
source "${ARCH_SETUP_DIR}/lib/boot.sh"
# shellcheck source=lib/system.sh
source "${ARCH_SETUP_DIR}/lib/system.sh"
# shellcheck source=lib/chroot.sh
source "${ARCH_SETUP_DIR}/lib/chroot.sh"
# shellcheck source=lib/packages.sh
source "${ARCH_SETUP_DIR}/lib/packages.sh"
# For stage_dotfiles only. Sourcing this sets DOTFILES_DIR from $HOME, which is
# root's on the ISO -- harmless here, since stage 1 takes its paths as
# arguments and never touches $HOME. It is stage 2 that uses DOTFILES_DIR.
# shellcheck source=lib/dotfiles.sh
source "${ARCH_SETUP_DIR}/lib/dotfiles.sh"

DEFAULT_HOSTNAME="archlinux"
DEFAULT_USERNAME="damn"
DEFAULT_KEYMAP="us"
DEFAULT_LOCALE="en_US.UTF-8"
DEFAULT_TIMEZONE="America/Sao_Paulo"
# 2G, not 512M: a single nvidia initramfs on this hardware is 213 MB, and the
# fallback image is bigger. The ESP holds kernel + both initramfs + grub.cfg,
# because it is mounted at /boot.
DEFAULT_ESP_SIZE="2G"
# Becomes \EFI\<id> on the ESP and the label the firmware shows in its own boot
# menu. Kept at the historical id so a whole-disk install produces exactly what
# it always did; the prompt exists for the shared-ESP case, where two installs
# cannot both call themselves GRUB.
DEFAULT_INSTALL_NAME="GRUB"
TOTAL_PHASES=6

KEYMAP=""; LOCALE=""; TIMEZONE=""
HOSTNAME_VAR=""; USERNAME_VAR=""
ROOT_PASSWORD=""; USER_PASSWORD=""; LUKS_PASSPHRASE=""

# Boot integration. BOOTLOADER_ID is the ESP vendor directory this install
# claims; GRUB_REMOVABLE decides whether it *also* writes the firmware
# fallback path \EFI\BOOT\BOOTX64.EFI. Both are resolved in phase 3 and
# consumed by the chroot in phase 5.
#
# The defaults are the conservative pair, because they are what a run that
# never reaches phase 3's boot questions would hand the chroot: the historical
# id, and no claim on the fallback path -- which on this hardware is another
# Arch install's only bootloader.
BOOTLOADER_ID="GRUB"
GRUB_REMOVABLE=false

# Also set by phase 3. FORMAT_ESP is false only when an existing ESP is
# adopted: mkfs.fat on a shared ESP destroys every other bootloader on the
# machine, so both partitioning modes state their own answer rather than
# relying on this default.
PART_EFI_REUSE=""
FORMAT_ESP=true
# The chosen ESP's FAT volume id, read once phase 3 has formatted or adopted
# it. Phase 6's chainload entry finds the ESP by this and never by device path:
# measured on this hardware, the two NVMe disks exchanged kernel names between
# one boot and the next, so nvme0n1p5 named a different partition each time.
# shellcheck disable=SC2034  # written here, consumed by phase 6
ESP_FS_UUID=""

# lib/disk.sh seeds this with ${DRY_RUN:-false} at source time, so it is always
# defined by the time anything below runs under `set -u`. Repeated here anyway:
# the guarantee currently depends on disk.sh being sourced before this line, and
# a source-order change should not silently re-arm the destructive path.
DRY_RUN=${DRY_RUN:-false}

usage() {
    cat <<'USAGE'
Usage: install.sh [--dry-run]

Stage 1 of the Arch install: partitions a disk, creates a LUKS2 container,
lays out Btrfs subvolumes and pacstraps a minimal bootable system. Run as
root from the Arch live ISO. Stage 2 is ~/.dotfiles/arch_setup/provision.sh.

Phase 3 offers two partitioning modes:

  Whole disk  wipe a disk and lay out ESP + root. The original behaviour.
  Custom      reuse existing partitions and/or carve unallocated space.
              Wipes nothing; only the partitions you select are formatted.
              Use this to install alongside an existing OS.

When other operating systems are already on the machine, phase 6 offers to
add a chainload entry to any GRUB it finds, and to add their bootloaders --
including a Windows Boot Manager registered in NVRAM -- to this install's
menu. Every edit to another system is a marker-delimited block with a
numbered backup. It never runs the other system's grub-mkconfig.

  --dry-run   run the full prompt flow and print destructive commands
              instead of executing them (DRY_RUN=true in the environment
              does the same)
  -h, --help  print this and exit
USAGE
}

# ---------------- teardown ----------------

# Split out of cleanup() so main can run it while the EXIT trap is still armed.
# Both halves are idempotent, so the trap firing after it costs nothing.
#
# Not named `teardown`, for the reason lib/disk.sh's run_cmd is not named
# `run`: bats defines setup/teardown/run/load/skip itself, and a file that
# `source`s this one into a test shell would silently swap bats' per-test
# teardown hook for this unmount. test/install.bats asserts the whole reserved
# set stays clear.
unmount_target() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    umount -R /mnt 2>/dev/null || true
    luks_close || true
}

cleanup() {
    local code=$?
    if (( code != 0 )); then
        error "Installation failed (exit ${code})"
    fi
    unmount_target
    # An EXIT trap leaves the shell's exit status alone unless it runs `exit`
    # -- or unless its own last command fails under `set -e`, which does change
    # it (verified: `set -e; t(){ false; }; trap t EXIT; exit 0` exits 1).
    # Ending on a fixed 0 keeps the status the run actually earned, so the
    # message above and the shell's status can never disagree.
    return 0
}

# ---------------- prompt-time validation ----------------
#
# Every check below has a counterpart further down the pipeline, and they are
# the right backstops. Three of them fire far too late to be the only check:
#
#   chroot_write_config's refusal set   phase 5, in this process, after the
#                                       disk is wiped and pacstrapped
#   locale_gen_uncomment's "not listed" phase 5, inside the chroot
#   lib/chroot.sh's uid<1000 guard      phase 5, inside the chroot
#
# size_to_sgdisk is the exception and is here for a different reason: it fires
# in plan_add, in phase 3, *before* the Type-YES gate and before plan_execute,
# so a bad size already aborts with nothing written. valid_size does not
# prevent a post-wipe abort -- it turns a mistyped size from an abort into a
# re-ask, which is worth three lines on its own.

# The exact set chroot_write_config refuses: each of these would close the
# double quote in KEY="value" and hand the rest to a root shell in the new
# system. Reaching that refusal is a bug in this file, not in the operator's
# typing.
config_safe() {
    case "$1" in
        *'"'*|*'`'*|*'$'*|*\\*|*$'\n'*) return 1 ;;
    esac
    return 0
}

# One RFC 1123 label -- deliberately not a dotted FQDN, because the generated
# chroot script writes "127.0.1.1 ${HOSTNAME_VAR}.localdomain ${HOSTNAME_VAR}".
valid_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

# The accounts a pacstrap of packages/base.txt is guaranteed to create: root,
# the filesystem package's sysusers (bin daemon mail ftp http), and systemd's
# own. Handing one of these a password, a login shell and the wheel group is
# the failure this list exists to prevent -- ^[a-z][a-z0-9_-]*$ admits every
# one of them.
USERNAME_RESERVED=(
    root bin daemon mail ftp http nobody dbus polkitd uuidd tss
    systemd-coredump systemd-network systemd-oom systemd-resolve
    systemd-timesync systemd-journal-remote systemd-journal-upload
)

valid_username() {
    local name=$1 reserved
    # 32 is useradd's own limit; a longer name is rejected by useradd, in the
    # chroot, after pacstrap. Leading digit excluded because an all-numeric
    # name makes every `chown name:name` ambiguous between name and uid.
    (( ${#name} >= 1 && ${#name} <= 32 )) || return 1
    [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
    for reserved in "${USERNAME_RESERVED[@]}"; do
        if [[ "$name" == "$reserved" ]]; then
            return 1
        fi
    done
    return 0
}

# The list above cannot stay complete -- any package in packages/base.txt may
# grow a sysuser. The live ISO carries the same filesystem and systemd packages
# pacstrap puts in the new root, so its own passwd database is a better oracle
# than any hardcoded list, and it is the same uid<1000 test lib/chroot.sh runs
# three phases later.
username_is_system() {
    local name=$1 uid
    # A name unknown here is not a system account; it is a new user.
    uid=$(id -u "$name" 2>/dev/null) || return 1
    (( uid < 1000 ))
}

# keymap_listed <keymap> -- 0 listed, 1 absent, 2 cannot answer.
keymap_listed() {
    local keymap=$1 all
    [[ -n "$keymap" ]] || return 1
    all=$(list_keymaps) || return 2
    # A here-string, not `printf ... | grep -q`: grep -q closes the pipe on its
    # first match, printf takes SIGPIPE, and `set -o pipefail` then reports 141
    # for the *successful* case. That only bites once the list outgrows the
    # pipe buffer -- measured here at 24 KB passing and 108 KB returning 141,
    # against a real `localectl list-keymaps` of 2.5 KB. So the pipe would work
    # today and break on the day the list grew. A here-string has no pipe and
    # no threshold.
    grep -qxF -- "$keymap" <<< "$all"
}

# Delegated to lib/disk.sh so the prompt and plan_add can never disagree about
# what a size is.
valid_size() {
    size_to_sgdisk "$1" >/dev/null 2>&1
}

# The EFI prompt's size, which unlike the root's may not be "rest".
# size_to_sgdisk maps "rest" to sgdisk's 0, meaning "to the end of the disk",
# so answering "rest" there lays the ESP across the whole disk and leaves the
# root nothing -- in whole-disk mode, after --zap-all has already run.
valid_esp_size() {
    [[ "$1" != "rest" ]] && valid_size "$1"
}

# `[[ -b ]]` behind a name, rather than inline in the three prompt loops that
# need it. A block device is the one answer this suite cannot supply: -b is a
# stat, so an unprivileged test could satisfy it only by naming one of the
# operator's live disks, and a disposable one needs losetup or mknod, both
# root-only. Behind a name it can be replaced in a test shell, which is what
# makes the custom-mode prompt flow testable at all.
valid_block_dev() {
    [[ -b "$1" ]]
}

# The answer to "which disk", which -b alone cannot check: a partition is a
# block device too. Measured on the operator's machine -- /dev/nvme1n1p1 was
# accepted at the custom-mode prompt, disk_free_gaps returned empty with status
# 0 rather than failing so the carve question was skipped silently, and the
# reuse loop then demanded a root matching /dev/nvme1n1p1p[0-9]*, a name no
# device can have. It re-asked forever; Ctrl-C was the only way out.
#
# lsblk -dno TYPE is the distinction: "disk" for a whole disk (nvme namespaces
# included), "part" for a partition, and "loop"/"crypt"/"raid1"/"lvm" for the
# rest. Refusing everything but "disk" narrows nothing the operator was offered:
# both listings these prompts print are `lsblk -e 7,11`, which excludes loop and
# optical devices already. A device lsblk could not read is refused too --
# calling it a disk would send next_part_number and disk_free_gaps, both of
# which fail open, at it.
valid_whole_disk() {
    local type
    valid_block_dev "$1" || return 1
    type=$(lsblk -dno TYPE -- "$1" 2>/dev/null) || return 1
    [[ "${type//[[:space:]]/}" == "disk" ]]
}

# The re-ask message for the two whole-disk prompts. "is not a block device"
# was the only thing either of them said, and it is the wrong sentence for the
# mistake actually made -- a partition IS a block device, so the operator reads
# it as the installer being broken rather than as the answer being wrong.
disk_prompt_complaint() {
    local dev=$1 type
    type=$(lsblk -dno TYPE -- "$dev" 2>/dev/null) || type=""
    type=${type//[[:space:]]/}
    case "$type" in
        part) warn "'${dev}' is a partition; give the whole disk it is on, e.g. /dev/nvme0n1" ;;
        "")   warn "'${dev}' is not a block device this machine can read" ;;
        *)    warn "'${dev}' is a ${type} device, not a disk; give a whole disk, e.g. /dev/nvme0n1" ;;
    esac
}

# ---------------- phase 1: preflight ----------------
phase_preflight() {
    banner 1 "$TOTAL_PHASES" "Pre-flight"
    (( EUID == 0 )) || die "must run as root"
    if [[ ! -d /run/archiso ]]; then
        ask_yes_no "Not an Arch live ISO. Continue anyway?" "n" || die "aborted"
    fi
    [[ -d /sys/firmware/efi ]] \
        || die "BIOS/legacy boot detected. This installer is UEFI-only."
    success "UEFI mode"

    net_check || die "no internet connection (ICMP to archlinux.org and HTTPS both failed)"
    success "internet OK"

    # An unsynchronised clock is not cosmetic here: pacman refuses package
    # signatures whose creation time is in the future, so a host whose RTC runs
    # ahead fails in phase 4 with signature errors that read like a corrupt
    # mirror. Say it now, in the phase that owns the clock.
    #
    # Routed through run_cmd because enabling NTP is a change to the host the
    # installer is running on, not to the target install, and it outlives the
    # run. run_cmd returns 0 under --dry-run, so the warning below is a
    # real-run-only path: a rehearsal that enabled nothing has no failure to
    # report. The command is written once, so what --dry-run prints cannot
    # differ from what a real run issues.
    if ! run_cmd timedatectl set-ntp true; then
        warn "could not enable NTP -- if this host's clock is wrong, pacman will reject package signatures"
    fi

    refresh_keyring \
        || die "cannot continue -- pacstrap would fail in phase 4 with signature errors"
    rank_mirrors
    success "ready"
}

# ---------------- phase 2: locale ----------------
phase_locale() {
    banner 2 "$TOTAL_PHASES" "Locale & Keyboard"
    local rc

    while true; do
        KEYMAP=$(ask "Console keymap" "$DEFAULT_KEYMAP")
        if ! config_safe "$KEYMAP"; then
            warn "a keymap may not contain \" \` \$ \\ or a newline"
            continue
        fi
        rc=0; keymap_listed "$KEYMAP" || rc=$?
        if (( rc == 2 )); then
            warn "cannot enumerate keymaps on this host; accepting '${KEYMAP}' unchecked"
        elif (( rc != 0 )); then
            warn "no such console keymap: ${KEYMAP}"
            continue
        fi
        # One array for both paths below, so the command --dry-run prints
        # cannot drift from the one a real run issues.
        local -a keymap_cmd=(loadkeys "$KEYMAP")
        # Still only a warning: loadkeys fails on a host with no console (a
        # serial or ssh install), and the value has already been checked
        # against the keymap list. /etc/vconsole.conf is what outlives this.
        #
        # Withheld under --dry-run all the same: this reloads the console of
        # the machine the rehearsal is running on for the rest of its boot.
        # Deliberately not `run_cmd "${keymap_cmd[@]}" >/dev/null 2>&1` -- the
        # redirection belongs to the real path, and applying it here would
        # discard run_cmd's [dry-run] line, leaving a rehearsal that shows
        # nothing where it withheld a command. The warning belongs to the real
        # branch alone: a rehearsal that loaded no keymap cannot have failed
        # to load one.
        if [[ "$DRY_RUN" == true ]]; then
            run_cmd "${keymap_cmd[@]}"
        else
            "${keymap_cmd[@]}" >/dev/null 2>&1 \
                || warn "could not load keymap '${KEYMAP}' into this console"
        fi
        break
    done

    while true; do
        LOCALE=$(ask "System locale" "$DEFAULT_LOCALE")
        if ! config_safe "$LOCALE"; then
            warn "a locale may not contain \" \` \$ \\ or a newline"
            continue
        fi
        rc=0; locale_listed /etc/locale.gen "$LOCALE" || rc=$?
        if (( rc == 2 )); then
            warn "/etc/locale.gen is not readable here; accepting '${LOCALE}' unchecked"
        elif (( rc != 0 )); then
            warn "'${LOCALE}' is not listed in /etc/locale.gen (want e.g. en_US.UTF-8)"
            continue
        fi
        break
    done

    while true; do
        TIMEZONE=$(ask "Timezone" "$DEFAULT_TIMEZONE")
        if ! config_safe "$TIMEZONE"; then
            warn "a timezone may not contain \" \` \$ \\ or a newline"
            continue
        fi
        # -f, matching link_timezone: /usr/share/zoneinfo/America is a
        # directory, and linking /etc/localtime at one leaves the clock on UTC.
        [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]] && break
        warn "no such timezone: ${TIMEZONE}"
    done

    confirm_step "  Keymap:   ${KEYMAP}
  Locale:   ${LOCALE}
  Timezone: ${TIMEZONE}"
}

# ---------------- phase 3: disk -- FIRST DESTRUCTIVE PHASE ----------------
# Nothing on any disk is written until the Type-YES gate below. Phase 1 does
# touch the ISO's own pacman database and mirrorlist, but those live on tmpfs
# and are gone at reboot.

# An ESP shared with another bootloader has to hold this install's kernel and
# both initramfs images as well as the neighbour's loader. DEFAULT_ESP_SIZE's
# comment above explains why that is 2G and not less: one nvidia initramfs on
# this hardware is 213 MB and the fallback image is bigger. A smaller floor
# lets a 550M ESP through and the run then dies inside mkinitcpio -P, several
# minutes after the last prompt, reading like a broken mirror.
MIN_SHARED_ESP_BYTES=$(( 2 * 1024 * 1024 * 1024 ))

# esp_reuse_ok <size_bytes>. Silent, because it runs inside a listing loop.
#
# The size is shape-checked before the arithmetic. parse_esp_list emits a
# literal "-" for an ESP with no filesystem UUID, and bash resolves a
# non-numeric token inside (( )) as a variable name rather than failing -- so
# an unvalidated field would be compared as 0, or as whatever some unrelated
# variable happens to hold.
esp_reuse_ok() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( $1 >= MIN_SHARED_ESP_BYTES ))
}

# dev_in_list <dev> <space-separated list> -- exact membership.
#
# The reused-ESP prompt must not accept an arbitrary block device. Validating
# only `-b` let a mistyped partition number select the neighbour's root
# filesystem, which then got mounted at /boot and had its /boot/grub
# overwritten by phase 5. Membership of the enumerated ESP list is the check.
#
# `read -ra` rather than an unquoted `for candidate in $2`: word-splitting an
# unquoted expansion also globs it, so a list containing a `*` would be
# answered from whatever happens to sit in the working directory.
dev_in_list() {
    local needle=$1 candidate
    local -a list=()
    read -ra list <<< "$2"
    for candidate in "${list[@]}"; do
        [[ "$candidate" == "$needle" ]] && return 0
    done
    return 1
}

# format_ledger <formatted_array> <preserved_array> <untouched_array>
#
# Takes array NAMES, not strings. The first draft was handed the prose "root
# partition" and word-split it into two lines reading "root" and "partition" --
# in the one place whose whole job is to be evidence rather than a claim.
format_ledger() {
    (( $# == 3 )) || { error "format_ledger: want three array names, got $#"; return 1; }
    local -n __fmt=$1
    local -n __pres=$2
    local -n __untouched=$3
    local dev
    printf '\n'
    warn "WILL BE FORMATTED -- all data on these is destroyed:"
    if (( ${#__fmt[@]} == 0 )); then printf '    (none)\n'; fi
    for dev in "${__fmt[@]}"; do printf '    %s\n' "$dev"; done
    printf '\n'
    info "WILL BE PRESERVED -- adopted as-is, not formatted:"
    if (( ${#__pres[@]} == 0 )); then printf '    (none)\n'; fi
    for dev in "${__pres[@]}"; do printf '    %s\n' "$dev"; done
    printf '\n'
    info "NOT TOUCHED -- no write of any kind:"
    if (( ${#__untouched[@]} == 0 )); then printf '    (none)\n'; fi
    for dev in "${__untouched[@]}"; do printf '    %s\n' "$dev"; done
}

# untouched_devices <formatted_array> <preserved_array> -- every partition on
# the machine that is in neither, one a line.
#
# Both arguments must hold exact device paths. This matches by whole word, so a
# prose entry that happened to name a device would drop that device from the
# list of partitions being left alone -- silently, on the screen whose job is
# to prove they are.
#
# lsblk's status is checked rather than read through a pipe: this list is the
# operator's evidence that the disks they are keeping are being kept, and an
# empty one because lsblk broke is a claim rather than an answer. -e 7,11
# excludes loop and optical devices by major number.
untouched_devices() {
    (( $# == 2 )) || { error "untouched_devices: want two array names, got $#"; return 1; }
    local -n __u_fmt=$1
    local -n __u_pres=$2
    local raw dev kind
    raw=$(lsblk -pnro PATH,TYPE -e 7,11) || {
        error "untouched_devices: lsblk failed; refusing to report a machine on which nothing is being left alone"
        return 1
    }
    while read -r dev kind; do
        [[ "$kind" == "part" ]] || continue
        dev_in_list "$dev" "${__u_fmt[*]}" && continue
        dev_in_list "$dev" "${__u_pres[*]}" && continue
        printf '%s\n' "$dev"
    done <<< "$raw"
}

# bootloader_id_taken <id> <esp_mountpoint|""> <esp_probe output>
#
# True when \EFI\<id> already belongs to something else. grub-install onto an
# existing vendor directory overwrites its grubx64.efi without complaint, which
# on an adopted ESP is another operating system's bootloader. Phase 5's
# needs_grub_install cannot answer this: it tells our id from a different one,
# never our id from somebody else's prior claim on the same name.
#
# By id, and never by esp_has_own_grub: that predicate is true for a merely
# non-empty grub/ directory, which is the layout this installer itself
# produces, so on a second install it would report our own ESP as occupied.
#
# The mountpoint is the authoritative check and is used whenever the ESP is
# really mounted. During a rehearsal nothing is, and the adopted ESP's own
# probe -- one "vendor <DIR>" line per vendor directory -- is the only evidence
# there is. An empty probe is a carved ESP that does not exist yet, on which
# every id is free.
bootloader_id_taken() {
    local id=$1 mnt=$2 probe=$3
    if [[ -n "$mnt" ]]; then
        bootloader_id_free "$mnt" "$id" && return 1
        return 0
    fi
    # -i because FAT is case-insensitive -- \EFI\Work and \EFI\WORK are one
    # directory -- which is the rule bootloader_id_free resolves by too.
    grep -qixF -- "vendor ${id}" <<< "$probe"
}

phase_disk() {
    banner 3 "$TOTAL_PHASES" "Disk Setup"
    local mode
    mode=$(ask_choice "Partitioning mode:" \
        "Whole disk -- wipe a disk and lay out ESP + root" \
        "Custom     -- reuse existing partitions and/or carve free space") \
        || die "aborted"
    # Neither arm sets a flag: each mode function states its own answer for
    # PLAN_WIPE_DISKS and FORMAT_ESP, next to the plan_reset whose ordering
    # they depend on. Setting PLAN_WIPE_DISKS here instead would be cleared by
    # the plan_reset inside the mode.
    case "$mode" in
        Whole*)  phase_disk_whole  ;;
        Custom*) phase_disk_custom ;;
        # Reachable in practice, not just in theory: anything ask_choice lets
        # onto stdout arrives here. Falling through would go straight into
        # phase_disk_finish -- which formats an ESP and mounts -- with no plan
        # executed and both mode flags at whatever they were.
        *)       die "unrecognised partitioning mode: ${mode}" ;;
    esac
    phase_disk_finish
}

# Whole-disk mode: the one path that destroys a partition table.
phase_disk_whole() {
    info "Available disks:"
    local disks disk esp_size confirm
    # -e 7,11 excludes loop and optical devices by major number, which is what
    # was actually meant. Filtering the formatted line through `grep -v` instead
    # matched the MODEL column too, so a disk whose model contained "rom"
    # vanished from the list -- and the pipeline needed a `|| true`, because
    # grep -v exits 1 when it filters everything out and `set -o pipefail`
    # turned that into a silent abort.
    disks=$(lsblk -dpno NAME,SIZE,MODEL -e 7,11)
    [[ -n "$disks" ]] \
        || die "no installable disk found (only loop and optical devices are present)"
    printf '%s\n' "$disks"
    echo ""

    while true; do
        disk=$(ask "Disk to install to (entire disk will be wiped)")
        valid_whole_disk "$disk" && break
        disk_prompt_complaint "$disk"
    done
    while true; do
        esp_size=$(ask "EFI partition size" "$DEFAULT_ESP_SIZE")
        valid_esp_size "$esp_size" && break
        warn "invalid size: '${esp_size}' (want e.g. 2G or 512M)"
    done

    plan_reset
    # Said explicitly because lib/disk.sh defaults PLAN_WIPE_DISKS to false, so
    # that carve and reuse modes cannot wipe a disk by omission. That makes this
    # -- the one path that really does destroy the partition table -- the one
    # that has to opt in. Dropping this line does not fail loudly: plan_execute
    # skips --zap-all and then runs `sgdisk -n 1:0:...` onto the live table,
    # overwriting partition 1 on a disk the operator was told would be wiped.
    #
    # After plan_reset and never before it: plan_reset clears this flag, so the
    # two lines in the other order silently leave it false.
    PLAN_WIPE_DISKS=true
    # The ESP this mode creates is ours and empty -- nothing else on the
    # machine has a bootloader in it. Stated here rather than left to the
    # file-scope default, so each mode answers for itself.
    FORMAT_ESP=true
    plan_add "$disk" efi  ef00 "EFI System" "$esp_size"
    plan_add "$disk" root 8300 "Root"       "rest"

    # Before plan_render, not inside plan_execute alone: plan_render does not
    # validate, so an incoherent plan would otherwise be shown and confirmed as
    # if it could run.
    plan_validate || die "refusing to act on a plan that cannot be executed safely"
    info "Partition plan:"
    plan_render
    echo ""
    # A bare `read`, not ask_yes_no: this is the gate in front of sgdisk
    # --zap-all, and a bare read fails closed on EOF, leaving `confirm` empty
    # and taking the `die` branch.
    read -rp "$(printf '%b%bType YES to wipe %s%b: ' "$RED" "$BOLD" "$disk" "$RESET")" confirm || confirm=""
    [[ "$confirm" == "YES" ]] || die "aborted"

    plan_execute
}

# Custom mode. Everything up to the Type-YES gate is inventory and prompts;
# the one command that writes is the plan_execute on the last line, the same
# one the whole-disk path uses. It runs with PLAN_WIPE_DISKS false -- cleared
# by the plan_reset below and never set again in this function -- so the
# `sgdisk --zap-all` that call can issue is unreachable from here, and no
# partition table is destroyed on this path.
phase_disk_custom() {
    local disk esp_choice root_choice confirm esp_size_ans found part_prefix
    local esp_dev esp_uuid esp_bytes esp_probe_out esp_disk
    local esp_raw gap_raw untouched_raw row aligned gap_start gap_end gap_n
    local -a gaps=() layout=() esp_devs=() all_esps=() esp_rows=() gap_rows=()
    local -a ledger_fmt=() ledger_pres=() ledger_untouched=() fmt_devs=()
    local esp_dev_list="" all_esp_list=""

    plan_reset

    info "Current layout:"
    lsblk -pno NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT -e 7,11
    echo ""
    info "Firmware boot entries already registered:"
    # Shown, never acted on -- which is why this is the one inventory here
    # allowed to fail. A machine whose firmware lists nothing and a machine
    # where efibootmgr cannot run are both fine to install onto.
    nvram_entries | sed 's/^/    /' || true
    echo ""

    # --- ESP: reuse an enumerated one, or carve a new one ---
    #
    # Captured with $( ) and drained before the loop rather than read from a
    # process substitution, for two reasons. esp_list returns non-zero when
    # lsblk fails, and `mapfile -t x < <(esp_list)` cannot see that (measured;
    # chroot_config_array below documents the same result), so an inventory
    # failure would arrive as "this machine has no ESPs" -- at once an empty
    # reuse menu and an empty blacklist for the root prompt. And a
    # `while read ... done < <(cmd)` loop owns stdin for its whole body, so a
    # prompt added inside it later would silently eat the next answer.
    esp_raw=$(esp_list) || die "cannot enumerate this machine's EFI System Partitions"
    if [[ -n "$esp_raw" ]]; then mapfile -t esp_rows <<< "$esp_raw"; fi

    info "EFI System Partitions found:"
    for row in "${esp_rows[@]}"; do
        read -r esp_dev esp_uuid esp_bytes <<< "$row"
        [[ -n "$esp_dev" ]] || continue
        # Every ESP, unfiltered. This is the blacklist the root prompt checks
        # against, and it must NOT be the same list as the reuse menu: an ESP
        # excluded from reuse *because it is another install's /boot* is
        # precisely the one that must still be refused as a root partition.
        all_esps+=("$esp_dev")
        if ! esp_reuse_ok "$esp_bytes"; then
            printf '    %s  %s  %s bytes  (too small to share -- needs %s)\n' \
                "$esp_dev" "$esp_uuid" "$esp_bytes" "$MIN_SHARED_ESP_BYTES"
            continue
        fi
        # Read-only by construction, and run under --dry-run too: the same
        # precedent as the part_probe_os call further down, which has never
        # been guarded. Skipping it would make the rehearsal offer an ESP the
        # real run refuses -- a difference in the unsafe direction.
        esp_probe_out=$(esp_probe "$esp_dev") || {
            printf '    %s  %s  %s bytes  (could not be probed -- not offered)\n' \
                "$esp_dev" "$esp_uuid" "$esp_bytes"
            continue
        }
        # An ESP that already carries <esp>/grub is somebody's /boot.
        # grub-install and grub-mkconfig would replace that install's modules
        # and its entire menu -- and because its grubx64.efi embeds a prefix
        # pointing at the same /grub, it would then boot our menu instead of
        # its own. bootloader_id_free does not catch this: the vendor directory
        # is per-install, /grub is not.
        if grep -qx 'owngrub yes' <<< "$esp_probe_out"; then
            printf "    %s  %s  %s bytes  (already in use as another install's /boot)\n" \
                "$esp_dev" "$esp_uuid" "$esp_bytes"
            continue
        fi
        # A positive "no" is required, not merely the absence of a "yes": an
        # ESP esp_probe could not mount emits no owngrub line at all, and
        # reading that as "not somebody's /boot" adopts an ESP nobody looked at.
        if ! grep -qx 'owngrub no' <<< "$esp_probe_out"; then
            printf '    %s  %s  %s bytes  (could not be read -- not offered)\n' \
                "$esp_dev" "$esp_uuid" "$esp_bytes"
            continue
        fi
        esp_devs+=("$esp_dev")
        printf '    %s  %s  %s bytes  (can be shared)\n' "$esp_dev" "$esp_uuid" "$esp_bytes"
    done
    (( ${#esp_devs[@]} )) || info "    (none available to share)"
    echo ""

    esp_dev_list="${esp_devs[*]}"
    all_esp_list="${all_esps[*]}"
    if (( ${#esp_devs[@]} )) && ask_yes_no "Reuse an existing EFI System Partition?" "y"; then
        while true; do
            esp_choice=$(ask "ESP to reuse (must be one listed above)")
            # Membership first: `-b` alone accepted any device, and a mistyped
            # partition number selected the neighbour's root.
            if ! dev_in_list "$esp_choice" "$esp_dev_list"; then
                warn "'${esp_choice}' is not one of the shareable ESPs listed above"
                continue
            fi
            if part_in_use "$esp_choice"; then
                warn "'${esp_choice}' is mounted or in use"
                continue
            fi
            break
        done
        PART_EFI_REUSE="$esp_choice"
        FORMAT_ESP=false
        ledger_pres+=("$esp_choice")
    else
        PART_EFI_REUSE=""
        FORMAT_ESP=true
    fi

    # --- root ---
    while true; do
        disk=$(ask "Disk to install onto")
        valid_whole_disk "$disk" && break
        disk_prompt_complaint "$disk"
    done

    # disk_free_gaps cannot tell "no free space" from "could not read the
    # disk" -- parted's stderr is suppressed inside it and both come back
    # empty-handed -- but it does pass parted's status on. Reporting "(none)"
    # for a disk nobody could read would send the operator to the
    # existing-partition path with no explanation.
    gap_raw=$(disk_free_gaps "$disk") \
        || die "cannot read a partition table on ${disk} (custom mode needs one; whole-disk mode is for a blank disk)"
    if [[ -n "$gap_raw" ]]; then mapfile -t gap_rows <<< "$gap_raw"; fi

    info "Unallocated space on ${disk}:"
    for row in "${gap_rows[@]}"; do
        read -r gap_start gap_end _ <<< "$row"
        [[ -n "$gap_start" ]] || continue
        # align_gap prints nothing and fails when alignment eats the whole gap,
        # which is the ordinary case for the sub-MiB slivers GPT leaves between
        # partitions.
        aligned=$(align_gap "$gap_start" "$gap_end") || continue
        read -r gap_start gap_end <<< "$aligned"
        gaps+=("${gap_start} ${gap_end}")
        printf '    %d) sectors %s-%s (%s GiB)\n' "${#gaps[@]}" "$gap_start" "$gap_end" \
            "$(( (gap_end - gap_start + 1) / 2097152 ))"
    done
    (( ${#gaps[@]} )) || info "    (none)"
    echo ""

    if (( ${#gaps[@]} )) && ask_yes_no "Carve the new install out of unallocated space?" "y"; then
        while true; do
            gap_n=$(ask "Gap number" "1")
            # Digit-count bounded and read in base 10, for the reason
            # ask_choice documents: bash reads a leading-zero numeral as octal,
            # and an unbounded digit run wraps at 64 bits back into range.
            if [[ "$gap_n" =~ ^[0-9]{1,3}$ ]] && (( 10#$gap_n >= 1 && 10#$gap_n <= ${#gaps[@]} )); then
                break
            fi
            warn "enter a number between 1 and ${#gaps[@]}"
        done
        read -r gap_start gap_end <<< "${gaps[$(( 10#$gap_n - 1 ))]}"

        if [[ -n "$PART_EFI_REUSE" ]]; then
            # mapfile reports 0 whatever the producer returned -- see
            # chroot_config_array below for that measurement -- so the guard is
            # on the array, not on `||`.
            mapfile -t layout < <(carve_layout "$gap_start" "$gap_end" rest)
            (( ${#layout[@]} == 1 )) || die "the requested layout does not fit in that gap"
            # shellcheck disable=SC2086  # layout entries are "start end", split on purpose
            plan_add "$disk" root 8300 Root rest new ${layout[0]}
        else
            while true; do
                esp_size_ans=$(ask "EFI partition size" "$DEFAULT_ESP_SIZE")
                valid_esp_size "$esp_size_ans" && break
                warn "invalid size: '${esp_size_ans}' (want e.g. 2G or 512M)"
            done
            mapfile -t layout < <(carve_layout "$gap_start" "$gap_end" "$esp_size_ans" rest)
            (( ${#layout[@]} == 2 )) || die "the requested layout does not fit in that gap"
            # shellcheck disable=SC2086
            plan_add "$disk" efi  ef00 "EFI System" "$esp_size_ans" new ${layout[0]}
            # shellcheck disable=SC2086
            plan_add "$disk" root 8300 Root         rest             new ${layout[1]}
        fi
        # Prose, not a device path: the partitions do not exist yet and have no
        # names to print. fmt_devs is deliberately left alone -- nothing that
        # already exists is being formatted here.
        ledger_fmt+=("new partitions in sectors ${gap_start}-${gap_end} on ${disk}")
    else
        part_prefix="${disk}$(part_suffix "$disk")"
        while true; do
            root_choice=$(ask "Existing partition to use for root (it WILL be formatted)")
            if ! valid_block_dev "$root_choice"; then
                warn "'${root_choice}' is not a block device"; continue
            fi
            # Built the same way plan_add builds its own check, so the operator
            # gets a re-ask rather than an abort. A bare `${disk}*` prefix test
            # also matched the whole disk itself, which plan_add then refused.
            if [[ "$root_choice" != "${part_prefix}"[0-9]* ]]; then
                warn "'${root_choice}' is not a partition of ${disk}"; continue
            fi
            # all_esp_list, not esp_dev_list: the reuse menu's list has already
            # had the dangerous ESPs filtered out of it.
            if dev_in_list "$root_choice" "$all_esp_list" || [[ "$root_choice" == "$PART_EFI_REUSE" ]]; then
                warn "'${root_choice}' is an EFI System Partition -- not a root filesystem"; continue
            fi
            if part_in_use "$root_choice"; then
                warn "'${root_choice}' is mounted, in use as swap, or has an open mapping -- refusing"
                continue
            fi
            found=$(part_probe_os "$root_choice")
            if ! safe_to_format "$found"; then
                # Everything that is not provably empty asks, including
                # "encrypted" and "unmountable:*". The first draft treated
                # anything it could not identify as free space, which is every
                # LUKS container on the machine. A partition that was formatted
                # and never used reports "data" rather than "empty" --
                # lost+found always exists -- so it is asked about too.
                warn "'${root_choice}' is not empty: ${found}"
                ask_yes_no "Format it anyway and destroy whatever is there?" "n" || continue
            fi
            break
        done
        plan_add "$disk" root 8300 Root rest "$root_choice"
        ledger_fmt+=("$root_choice")
        fmt_devs+=("$root_choice")
    fi

    if [[ -n "$PART_EFI_REUSE" ]]; then
        # The ESP's own disk, not $disk. Reusing a neighbour's ESP while
        # carving the root out of another disk's free space is the shape this
        # mode exists for, and plan_add validates a reused partition against
        # the disk of the entry it is added to -- so handing it the root's disk
        # refuses the entry and aborts the run under set -e.
        esp_disk=$(lsblk -pnro PKNAME "$PART_EFI_REUSE") \
            || die "cannot tell which disk ${PART_EFI_REUSE} belongs to"
        [[ -n "$esp_disk" ]] || die "cannot tell which disk ${PART_EFI_REUSE} belongs to"
        plan_add "$esp_disk" efi ef00 "EFI System" "-" "$PART_EFI_REUSE"
    fi

    # Refuse an incomplete plan while every disk is still untouched. Without
    # this, "no ESP reuse and no carve" produced a root-only plan that
    # LUKS-formatted the root and then died on `mkfs.fat ""`.
    plan_has_role root || die "no root partition in the plan"
    plan_has_role efi  || die "no EFI partition in the plan -- reuse an existing ESP or carve a new one"

    # Before plan_render, not only inside plan_execute: plan_render does not
    # validate, so an operator could otherwise read and type YES to a plan
    # plan_execute then refuses.
    plan_validate || die "refusing to act on a plan that cannot be executed safely"
    info "Partition plan:"
    plan_render
    echo ""

    # fmt_devs and ledger_pres, not ledger_fmt: untouched_devices matches by
    # whole word, and ledger_fmt's carve line is prose that names a disk.
    untouched_raw=$(untouched_devices fmt_devs ledger_pres) \
        || die "cannot list the partitions this plan leaves alone"
    # shellcheck disable=SC2034  # passed to format_ledger by name, not by value
    if [[ -n "$untouched_raw" ]]; then mapfile -t ledger_untouched <<< "$untouched_raw"; fi
    format_ledger ledger_fmt ledger_pres ledger_untouched
    echo ""

    # A bare `read`, not ask_yes_no, for the reason the whole-disk gate is one:
    # ask_yes_no answers with its default at EOF, and this is the last thing
    # between a closed stdin and plan_execute.
    read -rp "$(printf '%b%bType YES to proceed%b: ' "$RED" "$BOLD" "$RESET")" confirm || confirm=""
    [[ "$confirm" == "YES" ]] || die "aborted"

    plan_execute
}

# Everything both modes do once the plan has been executed: encryption,
# filesystems, the mounts, and the two boot decisions that depend on which ESP
# the operator ended up with.
phase_disk_finish() {
    local has_fallback="no" esp_is_new="no" policy probe="" esp_mnt=""
    local install_name candidate

    if ask_yes_no "Encrypt the root partition with LUKS2?" "y"; then
        ask_password LUKS_PASSPHRASE "LUKS passphrase"
        luks_format "$PART_ROOT_RAW" "$LUKS_PASSPHRASE"
        luks_open   "$PART_ROOT_RAW" "$LUKS_NAME" "$LUKS_PASSPHRASE"
    else
        PART_ROOT="$PART_ROOT_RAW"
        LUKS_ENABLED=false
    fi

    if [[ "$FORMAT_ESP" == true ]]; then
        run_cmd mkfs.fat -F32 "$PART_EFI"
    else
        # mkfs.fat on an adopted ESP destroys every other bootloader on the
        # machine, which is the whole reason this flag exists.
        info "Reusing the existing ESP at ${PART_EFI} without formatting"
    fi

    # --- the --removable policy ---
    #
    # Resolved from what is on the ESP, never assumed: on a machine where the
    # existing bootloader *is* the fallback binary, --removable overwrites it.
    # The probe is taken once and reused below rather than mounting the ESP
    # again for each field.
    #
    # An ESP this install formatted is never probed: it is ours and empty by
    # construction, and under --dry-run the mkfs above did not run, so probing
    # would report on whatever partition happens to hold that number today.
    # An ADOPTED ESP is probed in a rehearsal too -- it is a real partition
    # either way, esp_probe is read-only, and skipping it would make the
    # rehearsal offer to write a fallback path the real run refuses, in the one
    # output an operator reads to decide whether the real run is safe.
    if [[ "$FORMAT_ESP" == true ]]; then
        esp_is_new="yes"
    else
        probe=$(esp_probe "$PART_EFI") || die "cannot probe the ESP at ${PART_EFI}"
        # Read positively, never as "yes or else no". lib/boot.sh:887 states the
        # contract: an ESP esp_probe could not read reports "fallback unknown",
        # and "no" is the one answer removable_policy acts on by offering to
        # overwrite \EFI\BOOT\BOOTX64.EFI -- of which there is exactly one per
        # ESP. Collapsing unknown into no hands that offer back for an ESP
        # nobody managed to look at; passed through, removable_policy refuses it
        # and the `|| die` below stops the run.
        # Unanchored, as the `kind` read below is: esp_dir_inventory prints its
        # "vendor <DIR>" lines before the fallback line, so this is not line 1
        # on any ESP that has a vendor directory. A probe carrying two fallback
        # lines would yield "yes\nno", which removable_policy also refuses --
        # the same direction.
        has_fallback=$(sed -n 's/^fallback //p' <<< "$probe")
    fi
    # removable_policy refuses anything that is not a literal yes or no, and
    # under `set -euo pipefail` that refusal aborts the run rather than
    # defaulting to an offer. Both arguments are literals here; the `|| die` is
    # for the day one of them stops being one.
    policy=$(removable_policy "$has_fallback" "$esp_is_new") \
        || die "cannot decide the --removable policy for ${PART_EFI}"
    case "$policy" in
        forbid)
            warn "${PART_EFI} already holds \\EFI\\BOOT\\BOOTX64.EFI ($(sed -n 's/^kind //p' <<< "$probe"))."
            warn "Not installing to the removable fallback path -- that binary belongs to another system."
            GRUB_REMOVABLE=false ;;
        offer-default-yes)
            if ask_yes_no "Also install to the removable fallback path (\\EFI\\BOOT\\BOOTX64.EFI)?" "y"; then
                GRUB_REMOVABLE=true; else GRUB_REMOVABLE=false; fi ;;
        offer-default-no)
            if ask_yes_no "Also install to the removable fallback path (\\EFI\\BOOT\\BOOTX64.EFI)?" "n"; then
                GRUB_REMOVABLE=true; else GRUB_REMOVABLE=false; fi ;;
        # GRUB_REMOVABLE keeps its conservative default here, but silence is
        # not the point: a policy nobody recognises means the inventory and
        # this case statement have drifted apart, one phase before the chroot
        # acts on the answer.
        *)  die "unrecognised --removable policy: ${policy}" ;;
    esac

    btrfs_create_subvols "$PART_ROOT"
    btrfs_mount_all "$PART_ROOT" /mnt
    mount_esp /mnt

    if [[ "$DRY_RUN" != true ]]; then
        # mount(8) is loud and run_cmd does not swallow its status, so this is
        # belt and braces -- but the cost of getting it wrong is a pacstrap into
        # the ISO's own tmpfs, which eats RAM until it dies, three phases from
        # any message about mounting.
        mountpoint -q /mnt      || die "/mnt is not a mountpoint after the Btrfs mounts"
        mountpoint -q /mnt/boot || die "/mnt/boot is not a mountpoint -- the ESP did not mount"
        echo ""
        findmnt -R /mnt || true
        # The ESP is mounted now, so \EFI can be read directly. During a
        # rehearsal it is not, and the empty string sends bootloader_id_taken
        # to the adopted ESP's probe instead.
        esp_mnt="/mnt/boot"
    fi

    # --- the bootloader id ---
    #
    # This id is the install's directory on the ESP and its label in the
    # firmware's own boot menu -- but only when GRUB_REMOVABLE is false.
    # grub-install --removable forces the EFI distributor to "BOOT" and skips
    # the NVRAM registration, so under it the id names neither a directory nor
    # a firmware entry: the ESP gets \EFI\BOOT\BOOTX64.EFI and nothing else.
    # It is still the marker id phase 6 writes into the other systems' configs.
    # It goes through bootloader_id_from because lib/chroot.sh's
    # preflight refuses anything outside [A-Za-z0-9_-] -- an abort that lands
    # after pacstrap, with the disk already written.
    #
    # bootloader_id_from truncates at 16 characters, so two names that differ
    # only after the 16th collide into one id and one ESP directory. On a
    # shared ESP the collision check below is what catches that; on our own
    # fresh ESP there is nothing yet to collide with.
    while true; do
        install_name=$(ask "Name for this install in the boot menu" "$DEFAULT_INSTALL_NAME")
        candidate=$(bootloader_id_from "$install_name") || continue
        if bootloader_id_taken "$candidate" "$esp_mnt" "$probe"; then
            warn "\\EFI\\${candidate} is already used by another bootloader on this ESP -- pick another name"
            continue
        fi
        BOOTLOADER_ID="$candidate"
        break
    done
    info "This install will be registered as ${BOOTLOADER_ID}"

    if [[ "$DRY_RUN" == true ]]; then
        ESP_FS_UUID="0000-0000"
    else
        # shellcheck disable=SC2034  # written here, consumed by phase 6
        ESP_FS_UUID=$(blkid -s UUID -o value "$PART_EFI") \
            || die "cannot read the ESP's filesystem UUID from ${PART_EFI}"
    fi
    success "disk ready"
}

# ---------------- phase 4: base install ----------------
# Destructive: writes to the filesystems phase 3 created.
phase_base() {
    banner 4 "$TOTAL_PHASES" "Base System"
    local ucode
    local -a pkgs
    pkg_read "${ARCH_SETUP_DIR}/packages/base.txt" pkgs \
        || die "cannot read the base package list"
    ucode=$(detect_ucode)
    pkgs+=("$ucode")
    info "pacstrap: ${pkgs[*]}"
    run_cmd pacstrap -K /mnt "${pkgs[@]}"
    # The redirection has to be inside the command run_cmd executes, not around
    # run_cmd: written the other way, --dry-run would append to the real
    # /mnt/etc/fstab while printing that it had not.
    run_cmd bash -c 'genfstab -U /mnt >> /mnt/etc/fstab'
    if [[ "$DRY_RUN" != true ]]; then
        # genfstab exits 0 having written nothing when it cannot read the
        # target's mounts, and an fstab with no root entry boots to an
        # emergency shell -- found at the first reboot, with nothing said here.
        awk '$1 !~ /^#/ && $2 == "/" { found = 1 } END { exit(found ? 0 : 1) }' \
            /mnt/etc/fstab \
            || die "genfstab wrote no root entry to /mnt/etc/fstab"
        echo ""
        cat /mnt/etc/fstab
    fi
    success "base system installed"
}

# ---------------- phase 5: chroot ----------------
# Destructive: configures the system phase 4 installed, and is the phase the
# prompt-time validation above exists to keep from aborting halfway.

# The KEY=VALUE set handed to chroot_write_config, one line each. A single
# function so the --dry-run rehearsal below cannot drift from the real write it
# is rehearsing, and so test/install.bats can compare this key set against the
# require_vars list in the script lib/chroot.sh generates.
#
# LUKS_ENABLED reaches this as the literal "true" or "false" and nothing else:
# lib/disk.sh initialises it to false and only luks_open sets it true. The
# generated script rejects any other spelling, and hooks_line tests for exactly
# "true" -- a near miss is an initramfs with no encrypt hook and a root that
# cannot be unlocked. LUKS_UUID is deliberately allowed to be empty; the
# generated script only requires it when LUKS_ENABLED is true, and
# chroot_write_config accepts an empty value.
chroot_config_args() {
    local root_b64=$1 user_b64=$2
    printf '%s\n' \
        "HOSTNAME_VAR=${HOSTNAME_VAR}" \
        "USERNAME_VAR=${USERNAME_VAR}" \
        "ROOT_PASS_B64=${root_b64}" \
        "USER_PASS_B64=${user_b64}" \
        "TIMEZONE=${TIMEZONE}" \
        "LOCALE=${LOCALE}" \
        "KEYMAP=${KEYMAP}" \
        "LUKS_ENABLED=${LUKS_ENABLED}" \
        "LUKS_UUID=${LUKS_UUID}" \
        "BOOTLOADER_ID=${BOOTLOADER_ID}" \
        "GRUB_REMOVABLE=${GRUB_REMOVABLE}"
}

# A faithful clone of lib/packages.sh's pkg_read, kept in that shape on purpose.
# Note what does the work: the emptiness check at the end. A read loop is no
# better than `mapfile -t x < <(...)` at noticing a failed process substitution
# -- measured, both report 0 for one returning 7 -- so neither could carry a
# `|| return 1`. Only the guard below catches an array that never got filled.
chroot_config_array() {
    local -n __cfg_out=$1
    local __root_b64=$2 __user_b64=$3 __line
    __cfg_out=()
    while IFS= read -r __line; do __cfg_out+=("$__line"); done \
        < <(chroot_config_args "$__root_b64" "$__user_b64")
    (( ${#__cfg_out[@]} )) || { error "chroot_config_array: produced no config lines"; return 1; }
}

# The one part of phase 5 a dry run can honestly exercise. Both generators are
# pure file writers, so pointing them at a fresh mktemp -d runs the whole
# validation path for real -- the refusal set, the shell-identifier check, the
# CHROOT_INJECTED presence check and the `bash -n` of the artifact -- while
# touching nothing outside that directory. Returning early instead, as the
# first draft did, meant --dry-run never exercised the one step most likely to
# abort a real run late.
#
# The two password keys carry a placeholder rather than the real values: base64
# output cannot contain any of " ` $ \, so they are the only pair
# chroot_write_config can never reject, and there is no reason to put an
# operator's actual password in a temp file during a rehearsal.
chroot_dry_run() {
    local tmpdir rc=0
    local -a args
    tmpdir=$(mktemp -d) || {
        warn "[dry-run] cannot create a temp dir; skipping the chroot generator check"
        return 0
    }
    warn "[dry-run] would generate and run /mnt/root/chroot_setup.sh"
    info "[dry-run] generating the chroot config and script under ${tmpdir}..."
    chroot_config_array args "RFJZLVJVTg==" "RFJZLVJVTg==" || rc=$?
    if (( rc == 0 )); then
        chroot_write_config "${tmpdir}/chroot_config.sh" "${args[@]}" || rc=$?
    fi
    if (( rc == 0 )); then
        chroot_write_script "${tmpdir}/chroot_setup.sh" || rc=$?
    fi
    rm -rf "$tmpdir"
    (( rc == 0 )) \
        || die "the chroot generator rejected this configuration -- a real run would have failed here, with the disk already wiped"
    success "[dry-run] chroot config and script generate cleanly"
}

# nvram_missing_entry_warning -- what the operator has lost, and how to get it
# back by hand. Shared by both branches below because the loss is the same one:
# an install reachable only from a neighbour's menu is one a neighbour's
# upgrade can take away.
#
# The efibootmgr line is meant to be retyped, so it names the loader path this
# install actually wrote -- own_loader_path, not a constant: under --removable
# that is \EFI\BOOT\BOOTX64.EFI and otherwise the vendor directory.
nvram_missing_entry_warning() {
    local loader
    loader=$(own_loader_path)
    warn "${BOOTLOADER_ID} has no firmware boot entry of its own -- it is reachable only from another system's boot menu."
    warn "To add one by hand: efibootmgr --create --disk <disk> --part <n> --loader '${loader//\//\\}' --label ${BOOTLOADER_ID}"
}

# Confirm the firmware entry grub-install was supposed to create.
#
# grub-install registers it itself when --removable is not passed -- but it
# WARNS AND EXITS 0 when it cannot: no efibootmgr in the chroot, a read-only
# efivarfs, an NVRAM with no room left. The install is then a loader on the ESP
# with no firmware entry, and not at the fallback path either, so nothing but a
# neighbour's menu reaches it. Silence there is the outcome the warning above
# was written for, on the branch that never used to run it.
#
# Confirming, never registering: adding an entry here would give the machine
# two rows for one install on every run where grub-install did its job.
nvram_confirm_own_entry() {
    local want guid raw enum epartuuid epath elabel
    want=$(own_loader_path)
    # Called in a conditional, and its output validated as a GPT partition
    # GUID: lsblk leaves the column empty for a device that is not a GPT
    # partition, and an empty guid would match an NVRAM row whose own column
    # was empty.
    if ! guid=$(lsblk -dnro PARTUUID "$PART_EFI" 2>/dev/null) \
       || [[ ! "$guid" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]; then
        warn "could not read ${PART_EFI}'s partition GUID -- unable to confirm ${BOOTLOADER_ID} has a firmware boot entry."
        return 0
    fi
    # Conditional, not a bare call: nvram_loaders returns non-zero when
    # efibootmgr could not be read, which under `set -euo pipefail` would abort
    # an install that has already succeeded. "Could not read the firmware" is
    # also not the same fact as "the entry is missing", and only the second one
    # justifies the how-to-fix-it warning.
    if ! raw=$(nvram_loaders); then
        warn "could not read the firmware's boot entries -- unable to confirm ${BOOTLOADER_ID} has one."
        return 0
    fi
    while read -r enum epartuuid epath elabel; do
        # Both fields compared case-insensitively: lsblk reports the partition
        # GUID upper-case where efibootmgr reports it lower-case, and the path
        # lives on FAT, which has no case at all.
        [[ "${epartuuid,,}" == "${guid,,}" ]] || continue
        [[ "${epath^^}" == "${want^^}" ]] || continue
        info "The firmware boots this install as entry ${enum} (${elabel})."
        return 0
    done <<< "$raw"
    nvram_missing_entry_warning
}

# Give this install a firmware boot entry, or confirm it already has one.
#
# nvram_register_removable runs only under --removable: without it
# grub-install registers the entry itself, and doing it here too would leave
# the firmware with two rows for one install. See nvram_register_removable in
# lib/boot.sh for why --removable skips it. The other branch therefore checks
# rather than writes.
#
# Never fatal. This runs after the chroot has returned, so the system is
# installed and phase 6 is still to come; under `set -euo pipefail` a bare call
# would turn a failed efibootmgr into "Installation failed" for an install that
# succeeded.
chroot_register_nvram() {
    if [[ "$GRUB_REMOVABLE" == true ]]; then
        nvram_register_removable "$PART_EFI" "$BOOTLOADER_ID" || nvram_missing_entry_warning
        return 0
    fi
    # A rehearsal never ran grub-install, so there is no entry to find and
    # "no firmware boot entry" would be a claim about the described install
    # that a real run would not have produced.
    if [[ "$DRY_RUN" == true ]]; then
        info "[dry-run] a real run would confirm the firmware holds an entry for ${PART_EFI}:$(own_loader_path)"
        return 0
    fi
    nvram_confirm_own_entry
}

phase_chroot() {
    banner 5 "$TOTAL_PHASES" "System Configuration"
    local -a args

    while true; do
        HOSTNAME_VAR=$(ask "Hostname" "$DEFAULT_HOSTNAME")
        valid_hostname "$HOSTNAME_VAR" && break
        warn "invalid hostname (one label of letters, digits and '-', 1-63 characters)"
    done
    while true; do
        USERNAME_VAR=$(ask "Username" "$DEFAULT_USERNAME")
        if ! valid_username "$USERNAME_VAR"; then
            warn "invalid or reserved username (want [a-z_][a-z0-9_-]*, at most 32 characters, not a system account)"
            continue
        fi
        if username_is_system "$USERNAME_VAR"; then
            warn "'${USERNAME_VAR}' is a system account on this ISO and would be one in the new root too"
            continue
        fi
        break
    done
    ask_password ROOT_PASSWORD "Root password"
    ask_password USER_PASSWORD "Password for ${USERNAME_VAR}"

    confirm_step "  Hostname:  ${HOSTNAME_VAR}
  Username:  ${USERNAME_VAR}
  Encrypted: ${LUKS_ENABLED}"

    if [[ "$DRY_RUN" == true ]]; then
        chroot_dry_run
        # On the dry-run path too, and through the same helper: run_cmd is what
        # withholds the write, and a rehearsal that skipped this could not show
        # whether the install it describes ends up with a firmware entry.
        chroot_register_nvram
        return 0
    fi

    # The paths are not free choices: the generated script hardcodes
    # /root/chroot_config.sh (which it sources, and deletes on every exit path
    # because it holds both passwords) and /root/chroot_setup.sh (which it
    # deletes on success). Under any other basename the chroot cannot find its
    # config, and the passwords survive the install.
    chroot_config_array args \
        "$(printf '%s' "$ROOT_PASSWORD" | base64 -w0)" \
        "$(printf '%s' "$USER_PASSWORD" | base64 -w0)"
    chroot_write_config /mnt/root/chroot_config.sh "${args[@]}"
    chroot_write_script /mnt/root/chroot_setup.sh
    arch-chroot /mnt /root/chroot_setup.sh

    # After the chroot, because grub-install is what creates the binary the
    # entry points at: a firmware entry for a loader that is not there yet is a
    # boot failure the operator meets at the firmware menu.
    chroot_register_nvram

    # After the chroot, never before: see stage_dotfiles in lib/dotfiles.sh for
    # what `useradd -m` does (nothing) to a home directory that already exists.
    local repo_root
    repo_root=$(cd "${ARCH_SETUP_DIR}/.." && pwd) || repo_root=""
    stage_dotfiles "$repo_root" /mnt "$USERNAME_VAR"
    success "system configured"
}

# ---------------- phase 6: boot integration ----------------
#
# The only phase that writes to a system other than the one just installed.
# Everything it does there is a marker-delimited block plus a numbered backup,
# and the summary names the exact file to copy back.
#
# It never runs a foreign grub-mkconfig -- see lib/boot.sh's header over
# register_into_foreign_grub. The one grub-mkconfig below runs inside our own
# chroot, where regenerating the menu is ours to do.
#
# Nothing here is fatal. It runs after phase 5, so the new system is already
# installed and bootable, and every failure below costs a menu row on a machine
# that still boots. A die() here would replace "installed, one neighbour
# unregistered" with "Installation failed" and no reboot prompt, for an install
# that succeeded.

# own_loader_path -> the ESP-relative path of the loader phase 5 installed.
#
# Not a constant, because grub-install --removable overrides --bootloader-id:
# upstream sets the EFI distributor to "BOOT" and writes \EFI\BOOT\BOOTX64.EFI
# only -- no vendor directory, and no NVRAM entry either, since it also skips
# grub_install_register_efi. Chainloading /EFI/<id>/grubx64.efi after such an
# install writes a dead row into every other system's live menu, and with
# nothing in NVRAM to fall back to, this install ends up reachable from no menu
# on the machine.
# own_marker_id -> the custom_cfg_upsert marker id for THIS install's block in
# another system's config.
#
# Keyed on the ESP's filesystem UUID as well as the bootloader id, for the
# reason neighbour_marker_id already gives on the reverse half: ids are not
# unique across the machine. bootloader_id_taken only ever inspects the ESP
# this install is using, so a second install carving a second ESP finds
# \EFI\GRUB free there and legitimately takes the same default id. Measured
# with the id alone as the marker: run two's block REPLACED run one's, because
# custom_cfg_upsert is idempotent on the marker -- install one silently left
# every neighbour's menu and was reachable only through its own NVRAM entry.
#
# Sanitised the same way and for the same reason: custom_cfg_upsert refuses an
# id outside [A-Za-z0-9_-], and that refusal would land in phase 6, after
# pacstrap, on a system already written to disk.
#
# Under --dry-run ESP_FS_UUID is the "0000-0000" placeholder phase 3 sets, so a
# rehearsal prints GRUB_0000-0000. Two rehearsals therefore show the same id --
# harmless, because the dry-run branch in boot_register_forward writes nothing
# and there is no block for the second to overwrite.
own_marker_id() {
    local id="${BOOTLOADER_ID}_${ESP_FS_UUID}"
    printf '%s\n' "${id//[^A-Za-z0-9_-]/_}"
}

own_loader_path() {
    if [[ "$GRUB_REMOVABLE" == true ]]; then
        printf '/EFI/BOOT/BOOTX64.EFI\n'
    else
        printf '/EFI/%s/grubx64.efi\n' "$BOOTLOADER_ID"
    fi
}

# boot_register_forward <menuentry_block> <restore_array_name>
#
# Adds <menuentry_block> to every other Linux install that has a GRUB of its
# own, after asking about each. Appends one restore instruction to the named
# array per file edited.
#
# The paths in those instructions are rewritten relative to the neighbour's own
# root: the mountpoint they were written under is a mktemp -d that is gone by
# the time the operator reads the summary, and booting that system to run
# `cp /tmp/tmp.XyZ/etc/grub.d/40_custom.bak.WORK.1 ...` restores nothing.
boot_register_forward() {
    local block=$1
    local -n __fwd_restore=$2
    local -a found=() made=()
    local raw line dev uuid has_grub name tmp out rc p rel

    info "Looking for other operating systems with their own GRUB..."
    # PART_ROOT as well as PART_ROOT_RAW: under LUKS the mounted root is
    # /dev/mapper/cryptroot, which lsblk lists as btrfs like any other
    # candidate. Without it this mounts the root it just installed a second
    # time and offers to register the install into its own menu.
    #
    # Captured with $( ) rather than read from a process substitution: mapfile
    # and a read loop both report success for a producer that failed (measured
    # -- see chroot_config_array), and linux_installs returning non-zero means
    # lsblk broke. That must not arrive here as "this machine has no other
    # Linux installs".
    if ! raw=$(linux_installs "$PART_ROOT_RAW" "$PART_ROOT" "$PART_EFI"); then
        warn "could not enumerate the other Linux installs on this machine -- none of them was touched"
        return 0
    fi
    if [[ -n "$raw" ]]; then mapfile -t found <<< "$raw"; fi

    for line in "${found[@]}"; do
        read -r dev uuid has_grub name <<< "$line"
        # Positively "yes". linux_installs emits "unknown" for a candidate it
        # could not read, and mounting one of those read-write to edit a
        # /boot/grub nobody has seen is not the direction to fail in.
        [[ "$has_grub" == "yes" ]] || continue
        echo ""
        info "Found $name on ${dev}, with a GRUB of its own."
        ask_yes_no "Add an entry for this install to its boot menu?" "y" || continue

        if [[ "$DRY_RUN" == true ]]; then
            warn "[dry-run] would back up and edit ${dev}:/etc/grub.d/40_custom and /boot/grub/grub.cfg, adding arch-installer:$(own_marker_id)"
            continue
        fi

        tmp=$(mktemp -d) || {
            warn "cannot create a mount point for ${dev} -- skipping it"
            continue
        }
        # Read-write, unlike every mount in lib/boot.sh's inventory: this one is
        # here to write. subvol=@ is tried FIRST, in the order linux_installs
        # uses and for its reason: that is where an Arch-style btrfs layout
        # keeps the root, nothing here ever runs `btrfs subvolume set-default`,
        # and so a bare mount succeeds onto subvolid 5 -- the top level, which
        # has no /boot/grub. Getting the order wrong does not fail loudly; it
        # mounts the wrong thing, and every btrfs neighbour linux_installs just
        # certified has_grub yes comes back "could not register". linux_installs
        # does not pass the filesystem type down, so an ext4 neighbour takes the
        # subvol=@ attempt too: ext4 rejects the unknown option with EINVAL and
        # the bare mount behind it is the one that runs.
        if mount -o subvol=@ "$dev" "$tmp" 2>/dev/null || mount "$dev" "$tmp" 2>/dev/null; then
            rc=0
            out=$(register_into_foreign_grub "$tmp" "$(own_marker_id)" "$block") || rc=$?
            made=()
            if [[ -n "$out" ]]; then mapfile -t made <<< "$out"; fi
            case "$rc" in
                0)  success "registered into $name on ${dev}" ;;
                2)  warn "only half of ${dev} was updated: /etc/grub.d/40_custom carries the entry and /boot/grub/grub.cfg does not."
                    warn "That system picks it up at its next 'grub-mkconfig -o /boot/grub/grub.cfg'; until then the row is not in its menu." ;;
                *)  warn "could not register into $name on ${dev} -- both of its files are unchanged" ;;
            esac
            for p in "${made[@]}"; do
                rel=${p#"$tmp"}
                # `%`, not `%%`: the shortest match strips only the suffix this
                # backup added, so a root whose own path contains ".bak." keeps
                # it.
                # Named by OS name and filesystem UUID, not by ${dev}: the
                # operator runs this after booting that system, and kernel
                # device names are not stable across boots -- the same
                # instability every UUID in this installer's generated config
                # exists to avoid. "/dev/sdy3" could be a different disk by
                # then; the UUID is the same one `blkid` and that system's own
                # fstab show.
                __fwd_restore+=("on ${name} (UUID=${uuid}):  cp ${rel} ${rel%.bak.*}")
            done
            umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
        else
            warn "could not mount ${dev} read-write -- skipping it"
        fi
        rmdir "$tmp" 2>/dev/null || true
    done
}

# boot_register_reverse
#
# Adds every other bootloader on the machine to THIS install's menu, after
# asking about each, and then regenerates our own config once.
#
# Built here rather than threaded out of phase 3: everything it needs is in
# neighbour_loaders' inventory, and the vendor path has to come from the
# neighbour's own ESP -- hardcoding \EFI\BOOT\BOOTX64.EFI was right only for
# the one machine this was written on.
boot_register_reverse() {
    local -a neighbours=() ours=()
    local raw line other_uuid other_path other_label marker reverse wrote=false

    info "Looking for other bootloaders to add to this install's menu..."
    # Our own loader is excluded by (ESP filesystem uuid, path) and never by
    # ESP alone: on a shared ESP the neighbour this exists for has exactly the
    # filesystem uuid we do. The path comes from own_loader_path, the same
    # source the forward chainload entry uses -- a seed still naming the vendor
    # directory after a --removable install would match nothing on the ESP, and
    # our own loader would come back as a "neighbour" in our own menu.
    ours=("$(own_loader_path)")
    if ! raw=$(neighbour_loaders "$PART_EFI" "$ESP_FS_UUID" "${ours[@]}"); then
        warn "could not enumerate the other bootloaders on this machine -- none was added to this menu"
        warn "os-prober still runs from this install's own grub-mkconfig, so anything it can see is still found."
        return 0
    fi
    if [[ -n "$raw" ]]; then mapfile -t neighbours <<< "$raw"; fi
    if (( ${#neighbours[@]} == 0 )); then
        info "No other bootloader found."
        return 0
    fi

    for line in "${neighbours[@]}"; do
        read -r other_uuid other_path other_label <<< "$line"
        [[ -n "$other_uuid" && -n "$other_path" ]] || continue
        echo ""
        info "Found a bootloader on ${other_uuid}: ${other_path} ($other_label)"
        ask_yes_no "Add it to this install's boot menu?" "y" || continue
        # chain_entry refuses an apostrophe, a newline or a carriage return in
        # the title, and this title is a firmware label we did not write. One
        # refused entry skips one entry: under set -euo pipefail an unguarded
        # assignment here would take the whole run down over a string in
        # somebody else's NVRAM.
        reverse=$(chain_entry "${other_label} [chainload]" "$other_uuid" "$other_path") || {
            warn "cannot put that bootloader's name in a menu entry -- skipping it"
            continue
        }
        marker=$(neighbour_marker_id "$other_uuid" "$other_path") || continue
        if [[ "$DRY_RUN" == true ]]; then
            warn "[dry-run] would add arch-installer:${marker} to /mnt/etc/grub.d/40_custom"
            continue
        fi
        # Not an && chain: a failing && list does not trip set -e, so a refusal
        # here would leave nothing said, in the phase whose whole job is making
        # the other systems reachable.
        if ! custom_cfg_upsert /mnt/etc/grub.d/40_custom "$marker" "$reverse" 0755; then
            warn "could not write the menu entry for ${other_path} -- this install's menu is unchanged"
            continue
        fi
        wrote=true
        success "added ${other_path} to this install's /etc/grub.d/40_custom"
    done

    [[ "$wrote" == true ]] || return 0
    # Our own system, so regenerating its config is safe -- unlike the foreign
    # ones boot_register_forward deliberately leaves alone. Once, after every
    # entry is written, rather than once per entry: each pass runs os-prober,
    # which mounts every candidate root on the machine.
    #
    # `< /dev/null` because os-prober can prompt, and anything it read would
    # come out of this function's stdin -- which is the operator's terminal,
    # mid-phase.
    if arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg < /dev/null; then
        success "this install's menu now lists the other bootloaders"
    else
        warn "grub-mkconfig failed: the entries are in /etc/grub.d/40_custom but not in the generated menu."
        warn "Boot this install and re-run 'grub-mkconfig -o /boot/grub/grub.cfg' to pick them up."
    fi
}

phase_boot_integration() {
    banner 6 "$TOTAL_PHASES" "Boot Integration"
    local -a restore=()
    local forward="" line

    # Unreachable from a run that got this far -- the hostname is one RFC 1123
    # label, the id is [A-Z0-9_] out of bootloader_id_from, and the uuid came
    # from blkid or is the dry run's 0000-0000 -- but the reverse half below
    # does not depend on it, so a refusal costs that half and not the phase.
    forward=$(chain_entry "Arch Linux (${HOSTNAME_VAR}) [chainload]" \
        "$ESP_FS_UUID" "$(own_loader_path)") || forward=""
    if [[ -n "$forward" ]]; then
        boot_register_forward "$forward" restore
    else
        warn "cannot build this install's own chainload entry -- no other system's menu will be touched"
    fi

    boot_register_reverse

    if (( ${#restore[@]} )); then
        echo ""
        info "To undo the edits made to other systems, boot each one and run:"
        for line in "${restore[@]}"; do
            # printf, not info: these are commands to be retyped, and info's
            # "[*] " prefix would be retyped along with them.
            printf '    %s\n' "$line"
        done
        info "Each edit sits between '# BEGIN arch-installer:$(own_marker_id)' and its END line, so it can be deleted by hand too."
    fi
    success "boot integration complete"
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run)  DRY_RUN=true ;;
            -h|--help)  usage; return 0 ;;
            *)          die "unknown flag: ${arg}" ;;
        esac
    done
    # DRY_RUN also arrives from the environment. run_cmd tests for exactly
    # "true", so DRY_RUN=yes or DRY_RUN=1 is a fully destructive run started by
    # an operator who believes they asked for a rehearsal. Refuse rather than
    # interpret.
    case "$DRY_RUN" in
        true|false) ;;
        *) die "DRY_RUN must be exactly 'true' or 'false', got '${DRY_RUN}'" ;;
    esac
    if [[ "$DRY_RUN" == true ]]; then
        # Announced here rather than only under --dry-run, so `DRY_RUN=true
        # ./install.sh` says so too instead of silently rehearsing.
        warn "DRY RUN -- no changes will be made"
    fi

    trap cleanup EXIT

    phase_preflight
    phase_locale
    phase_disk
    phase_base
    phase_chroot
    # Before unmount_target, not after: the reverse entries are written into
    # /mnt/etc/grub.d/40_custom and picked up by a grub-mkconfig run inside
    # that chroot, both of which need /mnt still mounted.
    phase_boot_integration

    # Torn down before the trap is disarmed, not after: `trap - EXIT` first
    # would leave the unmount and the LUKS close with nothing behind them.
    unmount_target
    trap - EXIT

    banner "$TOTAL_PHASES" "$TOTAL_PHASES" "Stage 1 Complete"
    success "Minimal system installed."
    echo ""
    info "Reboot, log in as ${USERNAME_VAR}, then run:"
    info "  ~/.dotfiles/arch_setup/provision.sh"
    echo ""
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    # `ask_yes_no ... && reboot` would make main return 1 when you decline, so a
    # successful install you chose not to reboot from would exit non-zero.
    if ask_yes_no "Reboot now?" "y"; then
        reboot
    fi
}

# Guarded so test/install.bats can source this file to reach the validators
# above. Without it, sourcing would parse the flags, arm an EXIT trap that
# runs `umount -R /mnt`, and start partitioning.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
