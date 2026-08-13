#!/bin/bash
# Generates the in-chroot script. Pure: config map in, files out.
# Requires lib/ui.sh and lib/system.sh (for hooks_line / grub_cmdline_add).
# shellcheck shell=bash

# The four helpers lib/system.sh must provide, plus the two defined below, in
# the order they are injected into the generated script.
CHROOT_INJECTED=(
    hooks_line
    modules_line
    grub_cmdline_add
    needs_grub_install
    require_vars
    locale_gen_uncomment
)

# --- helpers injected into the generated script ----------------------------
#
# These live here rather than inline in the body so the chroot runs code the
# bats suite covers directly. Everything in CHROOT_INJECTED must stay within
# what the generated HEADER defines -- see the comment at the injection site.

# require_vars NAME... -- every named variable must exist and be non-empty.
# Names them all at once, and before anything has been mutated: the generated
# script runs under `set -u`, where the first missing key would otherwise
# abort with a bare "unbound variable" partway through configuring the system.
require_vars() {
    local name missing=()
    for name in "$@"; do
        # The `-` default is what makes this safe under `set -u`.
        [[ -n "${!name-}" ]] || missing+=("$name")
    done
    if (( ${#missing[@]} > 0 )); then
        error "missing or empty required config value(s): ${missing[*]}"
        return 1
    fi
}

# locale_gen_uncomment <file> <locale> -- uncomment the locale.gen entry whose
# locale name is exactly <locale>.
#
# The first field is compared as a fixed string rather than interpolating
# <locale> into a regex: the value comes straight from an unvalidated prompt,
# and in a regex the '.' of 'en_US.UTF-8' is a wildcard that can match an
# unrelated entry. Absence is an error, not a no-op -- `sed` and `locale-gen`
# both exit 0 having done nothing, which leaves /etc/locale.conf naming a
# locale the system does not have and every program falling back to C.
locale_gen_uncomment() {
    local file=$1 locale=$2 tmp
    [[ -n "$locale" ]] || { error "locale_gen_uncomment: empty locale"; return 1; }
    [[ -f "$file" ]] || { error "locale_gen_uncomment: no such file: ${file}"; return 1; }

    tmp=$(mktemp "${file}.XXXXXX") \
        || { error "locale_gen_uncomment: cannot create a temp file next to ${file}"; return 1; }

    if ! awk -v loc="$locale" '
        !found {
            probe = $0
            sub(/^#[[:space:]]*/, "", probe)
            split(probe, f, /[[:space:]]+/)
            if (f[1] == loc) { print probe; found = 1; next }
        }
        { print }
        END { exit(found ? 0 : 1) }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        error "locale_gen_uncomment: ${locale} is not listed in ${file}"
        return 1
    fi

    # Copied over the original rather than moved onto it: mktemp creates 0600,
    # and a /etc/locale.gen that only root can read is a silent surprise later.
    if ! cat "$tmp" > "$file"; then
        rm -f "$tmp"
        error "locale_gen_uncomment: failed to write ${file}"
        return 1
    fi
    rm -f "$tmp"
}

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
# ln -sf on a typo'd zone happily creates a dangling symlink and the system
# stays on UTC for good, with nothing said about it.
if [[ ! -e "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    error "no such timezone: /usr/share/zoneinfo/${TIMEZONE}"
    exit 1
fi
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
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
if [[ ! -x "$USER_SHELL" ]]; then
    # zsh is in packages/base.txt, so this should not fire -- but a login
    # shell that does not exist locks the user out of their own machine at
    # the greeter, so degrade instead of trusting the package list.
    warn "${USER_SHELL} is missing; falling back to /bin/bash for ${USERNAME_VAR}"
    USER_SHELL=/bin/bash
fi

groupadd -f docker
# An interrupted install is resumed by re-running install.sh, and useradd on
# an existing user exits non-zero -- which `set -e` would turn into an abort
# on every retry, at the same point, forever.
if id -u "$USERNAME_VAR" >/dev/null 2>&1; then
    info "user ${USERNAME_VAR} already exists, updating groups and shell..."
    usermod -aG wheel,docker,video,audio,input,storage -s "$USER_SHELL" "$USERNAME_VAR"
else
    info "Creating ${USERNAME_VAR}..."
    useradd -m -G wheel,docker,video,audio,input,storage -s "$USER_SHELL" "$USERNAME_VAR"
fi
printf '%s:%s\n' "$USERNAME_VAR" "$USER_PASSWORD" | chpasswd

# A drop-in validated by visudo, not an in-place edit of /etc/sudoers: a sed
# that matches nothing leaves wheel without sudo and says so nowhere, and a
# sed that matches wrongly breaks sudo for everyone including root's rescue
# path. visudo -cf refuses the file before it can take effect.
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/10-wheel <<'WHEEL'
%wheel ALL=(ALL:ALL) ALL
WHEEL
chmod 440 /etc/sudoers.d/10-wheel
if ! visudo -cf /etc/sudoers.d/10-wheel >/dev/null; then
    rm -f /etc/sudoers.d/10-wheel
    error "the wheel sudoers drop-in failed visudo validation"
    exit 1
fi
grep -qE '^[[:space:]]*[@#]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers \
    || warn "/etc/sudoers has no active includedir for /etc/sudoers.d -- ${USERNAME_VAR} will have no sudo"
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
