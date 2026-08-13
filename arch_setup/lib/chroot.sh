#!/bin/bash
# Generates the in-chroot script. Pure: config map in, files out.
# Requires lib/ui.sh and lib/system.sh (for hooks_line / grub_cmdline_add).
# shellcheck shell=bash

# The helpers injected into the generated script, all of them from
# lib/system.sh so there is one home for the shared pure transforms.
CHROOT_INJECTED=(
    hooks_line
    modules_line
    grub_cmdline_add
    needs_grub_install
    require_vars
    locale_gen_uncomment
    link_timezone
)

# --- the generator ---------------------------------------------------------

# chroot_write_config <path> KEY=VALUE...
#
# Every value lands inside a double-quoted assignment that a root shell in the
# new system then sources, so a value containing " ` $ or \ closes the quote
# and the rest executes as root. LOCALE and KEYMAP reach this function from a
# bare `ask` with no validation at all, so a typo is enough -- malice is not
# required. Refuse rather than escape, the same choice grub_cmdline_add makes
# for sed metacharacters: none of these characters belongs in a hostname,
# username, timezone, locale or keymap, and an installer that stops naming the
# offending key is debuggable in a way one that silently rewrites its
# operator's input is not.
chroot_write_config() {
    local path=$1; shift
    local kv key value tmp

    # Validated in full before anything is created: a rejected pair must not
    # leave the accepted ones behind as a config the chroot would source with
    # values silently missing.
    for kv in "$@"; do
        [[ "$kv" == *=* ]] \
            || { error "chroot_write_config: '${kv}' is not KEY=VALUE"; return 1; }
        key=${kv%%=*}
        value=${kv#*=}
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
            || { error "chroot_write_config: '${key}' is not a valid shell identifier"; return 1; }
        case $value in
            *'"'*|*'`'*|*'$'*|*\\*|*$'\n'*)
                error "chroot_write_config: value for '${key}' contains one of \" \` \$ \\ or a newline, which would break out of the quoting in ${path}"
                return 1 ;;
        esac
    done

    # mktemp, not `umask 077; : > "$path"`: it creates the file 0600 whatever
    # the umask is, so there is no umask to restore and nothing to leak into
    # the rest of install.sh, which sources this file rather than exec'ing it.
    tmp=$(mktemp "${path}.XXXXXX") \
        || { error "chroot_write_config: cannot create a temp file next to ${path}"; return 1; }
    for kv in "$@"; do
        if ! printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}" >> "$tmp"; then
            error "chroot_write_config: failed to write ${path}"
            rm -f "$tmp"; return 1
        fi
    done
    if ! chmod 600 "$tmp"; then
        error "chroot_write_config: failed to chmod ${path}"
        rm -f "$tmp"; return 1
    fi
    if ! mv "$tmp" "$path"; then
        error "chroot_write_config: failed to move the config into place at ${path}"
        rm -f "$tmp"; return 1
    fi
}

# chroot_write_script <path>
#
# The generated script hardcodes the two paths it reads and cleans up:
# /root/chroot_config.sh and /root/chroot_setup.sh. Whatever <path> is here,
# the caller must land them inside the new root under exactly those names --
# i.e. /mnt/root/chroot_setup.sh and /mnt/root/chroot_config.sh -- or the
# chroot will not find its config and will not remove the passwords after.
chroot_write_script() {
    local path=$1 fn tmp

    # `declare -f` on a function that was never sourced prints nothing and
    # returns 1. Under the `set -euo pipefail` install.sh runs with, that
    # aborts the redirection group and leaves a truncated script on disk;
    # without it, it writes a complete-looking script whose missing helper
    # only surfaces inside the chroot, after the disk has been formatted.
    for fn in "${CHROOT_INJECTED[@]}"; do
        declare -F "$fn" >/dev/null \
            || { error "chroot_write_script: helper '${fn}' is not defined -- source lib/system.sh and lib/chroot.sh first"; return 1; }
    done

    tmp=$(mktemp "${path}.XXXXXX") \
        || { error "chroot_write_script: cannot create a temp file next to ${path}"; return 1; }

    # A subshell with its own `set -e`, not a plain `{ ... }` group: a group's
    # status is only its *last* command's, so a `cat` that failed partway --
    # a full /mnt is the realistic one -- would be reported as success and
    # hand the chroot a script cut off mid-function.
    if ! (
        set -e
        cat <<'HEADER'
#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'
info()    { echo -e "${BLUE}[*]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }

# Both files go on *every* exit path, not just the happy one. The config
# holds the root and user passwords, and base64 is encoding, not encryption:
# a run that dies after the bootloader is written still leaves a machine that
# boots, with the passwords sitting in /root. The cost is that a failed run
# cannot be resumed by re-running this script by hand -- re-run install.sh,
# which regenerates both files.
trap 'rm -f /root/chroot_setup.sh /root/chroot_config.sh' EXIT

if [[ ! -r /root/chroot_config.sh ]]; then
    error "/root/chroot_config.sh is missing or unreadable"
    exit 1
fi
source /root/chroot_config.sh
HEADER

        # Injected rather than re-implemented, so the chroot runs exactly the
        # code the bats suite covers.
        #
        # CONSTRAINT: the HEADER above defines RED GREEN YELLOW BLUE RESET and
        # info/warn/error/success -- deliberately not CYAN or BOLD. Under
        # `set -u` a reference to an undefined colour is fatal, not cosmetic
        # ("CYAN: unbound variable" aborts the chroot mid-configuration), and
        # every ui.sh function that touches CYAN or BOLD (banner, ask,
        # ask_yes_no, ask_password, ask_choice, confirm_step) is absent from
        # this list for that reason. Anything added to CHROOT_INJECTED must
        # reference neither, or the HEADER has to grow to define them.
        # test/chroot.bats enforces this on the generated file.
        for fn in "${CHROOT_INJECTED[@]}"; do
            declare -f "$fn"
        done

        cat <<'BODY'

# ---- preflight ----
# Fail before touching anything, naming every key at once: a half-configured
# system found at the second reboot is far worse than a run that never began.
if ! require_vars HOSTNAME_VAR USERNAME_VAR TIMEZONE LOCALE KEYMAP \
                  LUKS_ENABLED ROOT_PASS_B64 USER_PASS_B64; then
    exit 1
fi
case "$LUKS_ENABLED" in
    true|false) ;;
    *)  # hooks_line and the cryptdevice branch below both test for exactly
        # "true"; any other spelling silently produces an initramfs with no
        # encrypt hook and a machine that cannot unlock its own root.
        error "LUKS_ENABLED must be exactly 'true' or 'false', got '${LUKS_ENABLED}'"
        exit 1 ;;
esac
if [[ "$LUKS_ENABLED" == "true" ]] && ! require_vars LUKS_UUID; then
    exit 1
fi

ROOT_PASSWORD=$(printf '%s' "$ROOT_PASS_B64" | base64 -d)
USER_PASSWORD=$(printf '%s' "$USER_PASS_B64" | base64 -d)

# ---- time, locale, hostname ----
info "Setting timezone to ${TIMEZONE}..."
if ! link_timezone /usr/share/zoneinfo "$TIMEZONE" /etc/localtime; then
    exit 1
fi
hwclock --systohc

info "Generating locale ${LOCALE}..."
if ! locale_gen_uncomment /etc/locale.gen "$LOCALE"; then
    exit 1
fi
locale-gen
printf 'LANG=%s\n' "$LOCALE" > /etc/locale.conf
printf 'KEYMAP=%s\n' "$KEYMAP" > /etc/vconsole.conf

info "Setting hostname to ${HOSTNAME_VAR}..."
printf '%s\n' "$HOSTNAME_VAR" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_VAR}.localdomain ${HOSTNAME_VAR}
HOSTS

# ---- users ----
info "Setting the root password..."
printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd

USER_SHELL=/usr/bin/zsh
# zsh is in packages/base.txt and pacstrap fails loudly if it cannot install
# it, so this should be unreachable. Stop rather than substitute /bin/bash:
# these dotfiles are built around zsh, and quietly handing the operator a
# different login shell is a worse outcome than a named failure here.
if [[ ! -x "$USER_SHELL" ]]; then
    error "${USER_SHELL} is missing -- the pacstrap set should have installed zsh"
    exit 1
fi

groupadd -f docker
# An interrupted install is resumed by re-running install.sh, and useradd on
# an existing user exits non-zero, which set -e would turn into an abort at
# the same point on every retry. But "already exists" also covers root, bin
# and nobody, all of which install.sh's username regex admits: handing one of
# those the wheel group, a new shell and a new password is far worse than the
# abort being replaced, so only a real user account takes the resume path.
if EXISTING_UID=$(id -u "$USERNAME_VAR" 2>/dev/null); then
    if (( EXISTING_UID < 1000 )); then
        error "${USERNAME_VAR} is an existing system account (uid ${EXISTING_UID}); refusing to give it wheel, a new shell and a new password"
        exit 1
    fi
    info "user ${USERNAME_VAR} already exists (uid ${EXISTING_UID}), updating groups and shell..."
    usermod -aG wheel,docker,video,audio,input,storage -s "$USER_SHELL" "$USERNAME_VAR"
    # No -m on this path: usermod -m *moves* an existing home, and an account
    # this installer did not create having no home is not something to fix
    # silently. Say it, because the dotfiles chown at the end would otherwise
    # just skip.
    EXISTING_HOME=$(getent passwd "$USERNAME_VAR" | cut -d: -f6)
    [[ -d "$EXISTING_HOME" ]] \
        || warn "${USERNAME_VAR} has no home directory at ${EXISTING_HOME} -- dotfiles will not be handed over"
else
    info "Creating ${USERNAME_VAR}..."
    useradd -m -G wheel,docker,video,audio,input,storage -s "$USER_SHELL" "$USERNAME_VAR"
fi
printf '%s:%s\n' "$USERNAME_VAR" "$USER_PASSWORD" | chpasswd

# A drop-in rather than an in-place edit of /etc/sudoers: /etc/sudoers is
# pacman-owned, and editing it marks it locally modified, which buys a .pacnew
# to reconcile on every sudo upgrade. lib/system.sh's setup_lightdm declines
# to install a file for exactly that reason. No visudo -c here -- the content
# is one hardcoded line from a quoted heredoc with nothing interpolated, so
# validating it only asks whether visudo itself works.
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/10-wheel <<'WHEEL'
%wheel ALL=(ALL:ALL) ALL
WHEEL
chmod 440 /etc/sudoers.d/10-wheel
# The drop-in only does anything if /etc/sudoers still includes the directory.
# Without it the administrator account has no sudo at all, which is not a
# warning-grade outcome -- and failing here, before the initramfs and
# bootloader stages, aborts cleanly instead of half-building a system.
if ! grep -qE '^[[:space:]]*[@#]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers; then
    error "/etc/sudoers has no active includedir for /etc/sudoers.d -- ${USERNAME_VAR} would have no sudo"
    exit 1
fi
success "user ${USERNAME_VAR} configured"

# ---- initramfs ----
info "Configuring mkinitcpio..."
CUR_HOOKS=$(grep -E '^HOOKS=' /etc/mkinitcpio.conf)
NEW_HOOKS=$(hooks_line "$CUR_HOOKS" "$LUKS_ENABLED")
sed -i "s|^HOOKS=.*|${NEW_HOOKS}|" /etc/mkinitcpio.conf
# sed exits 0 when its pattern matched nothing, and a HOOKS line that never
# changed is an initramfs that cannot open the root device -- found at reboot.
grep -qxF "$NEW_HOOKS" /etc/mkinitcpio.conf \
    || { error "failed to write HOOKS to /etc/mkinitcpio.conf"; exit 1; }

CUR_MODULES=$(grep -E '^MODULES=' /etc/mkinitcpio.conf)
NEW_MODULES=$(modules_line "$CUR_MODULES" btrfs)
sed -i "s|^MODULES=.*|${NEW_MODULES}|" /etc/mkinitcpio.conf
grep -qxF "$NEW_MODULES" /etc/mkinitcpio.conf \
    || { error "failed to write MODULES to /etc/mkinitcpio.conf"; exit 1; }

info "HOOKS is now: ${NEW_HOOKS}"
mkinitcpio -P

# ---- bootloader ----
if [[ "$LUKS_ENABLED" == "true" ]]; then
    info "Adding cryptdevice to the kernel command line..."
    grub_cmdline_add /etc/default/grub "cryptdevice=UUID=${LUKS_UUID}:cryptroot"
    grub_cmdline_add /etc/default/grub "root=/dev/mapper/cryptroot"
fi

if needs_grub_install /boot; then
    info "Installing GRUB..."
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
    success "GRUB already installed on the ESP, skipping grub-install"
fi
grub-mkconfig -o /boot/grub/grub.cfg
success "bootloader ready"

# ---- zram ----
info "Configuring zram..."
cat > /etc/systemd/zram-generator.conf <<ZRAM
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
ZRAM

# ---- services ----
systemctl enable NetworkManager

# ---- hand the dotfiles to the user ----
if [[ -d "/home/${USERNAME_VAR}/.dotfiles" ]]; then
    chown -R "${USERNAME_VAR}:${USERNAME_VAR}" "/home/${USERNAME_VAR}/.dotfiles"
    success "dotfiles handed to ${USERNAME_VAR}"
fi

# The EXIT trap removes this script and the config.
success "chroot configuration complete"
BODY
    ) > "$tmp"; then
        error "chroot_write_script: failed to generate ${path}"
        rm -f "$tmp"; return 1
    fi

    # Parse the artifact before installing it. Nothing else between here and
    # `arch-chroot` looks at this file, and a truncated or malformed one is
    # only discovered by the shell that runs it, as root, on a system whose
    # disk has already been formatted.
    if ! bash -n "$tmp"; then
        error "chroot_write_script: the generated script is not valid bash, refusing to install it at ${path}"
        rm -f "$tmp"; return 1
    fi

    if ! chmod 700 "$tmp"; then
        error "chroot_write_script: failed to chmod ${path}"
        rm -f "$tmp"; return 1
    fi
    if ! mv "$tmp" "$path"; then
        error "chroot_write_script: failed to move the script into place at ${path}"
        rm -f "$tmp"; return 1
    fi
}
