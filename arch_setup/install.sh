#!/bin/bash
# Stage 1: Arch install from the live ISO. Root only. Destructive.
#
#   pacman -Sy --noconfirm git
#   git clone https://github.com/guidiamond/.dotfiles
#   cd .dotfiles/arch_setup && ./install.sh
#
# Run `./install.sh --help` for the flags; usage() below is the one copy.
set -euo pipefail

ARCH_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ARCH_SETUP_DIR

# shellcheck source=lib/ui.sh
source "${ARCH_SETUP_DIR}/lib/ui.sh"
# shellcheck source=lib/disk.sh
source "${ARCH_SETUP_DIR}/lib/disk.sh"
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
TOTAL_PHASES=5

KEYMAP=""; LOCALE=""; TIMEZONE=""
HOSTNAME_VAR=""; USERNAME_VAR=""
ROOT_PASSWORD=""; USER_PASSWORD=""; LUKS_PASSPHRASE=""

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
    if ! timedatectl set-ntp true; then
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
        # Still only a warning: loadkeys fails on a host with no console (a
        # serial or ssh install), and the value has already been checked
        # against the keymap list. /etc/vconsole.conf is what outlives this.
        loadkeys "$KEYMAP" >/dev/null 2>&1 \
            || warn "could not load keymap '${KEYMAP}' into this console"
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
# Everything before this point is reversible by pressing ctrl-c. From the
# Type-YES gate below onward it is not.
phase_disk() {
    banner 3 "$TOTAL_PHASES" "Disk Setup"
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
        [[ -b "$disk" ]] && break
        warn "'${disk}' is not a block device"
    done
    while true; do
        esp_size=$(ask "EFI partition size" "$DEFAULT_ESP_SIZE")
        valid_size "$esp_size" && break
        warn "invalid size: '${esp_size}' (want e.g. 2G or 512M)"
    done

    plan_reset
    plan_add "$disk" efi  ef00 "EFI System" "$esp_size"
    plan_add "$disk" root 8300 "Root"       "rest"

    info "Partition plan:"
    plan_render
    echo ""
    # A bare `read`, not ask_yes_no: this is the gate in front of sgdisk
    # --zap-all, and a bare read fails closed on EOF, leaving `confirm` empty
    # and taking the `die` branch.
    read -rp "$(echo -e "${RED}${BOLD}Type YES to wipe ${disk}${RESET}: ")" confirm || confirm=""
    [[ "$confirm" == "YES" ]] || die "aborted"

    plan_execute

    if ask_yes_no "Encrypt the root partition with LUKS2?" "y"; then
        ask_password LUKS_PASSPHRASE "LUKS passphrase"
        luks_format "$PART_ROOT_RAW" "$LUKS_PASSPHRASE"
        luks_open   "$PART_ROOT_RAW" "$LUKS_NAME" "$LUKS_PASSPHRASE"
    else
        PART_ROOT="$PART_ROOT_RAW"
        LUKS_ENABLED=false
    fi

    run_cmd mkfs.fat -F32 "$PART_EFI"
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
        "LUKS_UUID=${LUKS_UUID}"
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

    # After the chroot, never before: see stage_dotfiles in lib/dotfiles.sh for
    # what `useradd -m` does (nothing) to a home directory that already exists.
    local repo_root
    repo_root=$(cd "${ARCH_SETUP_DIR}/.." && pwd) || repo_root=""
    stage_dotfiles "$repo_root" /mnt "$USERNAME_VAR"
    success "system configured"
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
