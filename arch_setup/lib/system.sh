#!/bin/bash
# Shared transforms, host probes and one idempotent function per subsystem.
# Requires lib/ui.sh.
#
# COUPLING: everything in the first three sections below -- hooks_line,
# modules_line, gpu_packages, require_vars, grub_cmdline_add,
# locale_gen_uncomment, link_timezone, detect_ucode, detect_gpu,
# needs_grub_install -- is a candidate for injection into the generated chroot
# script, and lib/chroot.sh's CHROOT_INJECTED currently takes seven of them
# verbatim via `declare -f`. Anything injected runs under `set -Eeuo pipefail`
# in a shell that defines only RED GREEN YELLOW BLUE RESET and
# info/warn/error/success. So: no CYAN, no BOLD, no ARCH_SETUP_DIR, no sudo,
# no reading a variable the caller has not passed in -- an undefined name is
# fatal there, not cosmetic. See the CONSTRAINT block at chroot.sh's injection
# site; test/chroot.bats enforces it against the generated file.
# shellcheck shell=bash

# Arch no longer ships the proprietary nvidia/nvidia-dkms packages -- only the
# open modules. Pre-Turing cards need an AUR nvidia-<branch>xx-dkms and are out
# of scope here.
GPU_NVIDIA=(nvidia-open-dkms nvidia-utils nvidia-settings)
GPU_AMD=(xf86-video-amdgpu mesa vulkan-radeon)
GPU_INTEL=(mesa vulkan-intel intel-media-driver)

# --- pure transforms (no I/O) ----------------------------------------------

# hooks_line "HOOKS=(...)" <want_encrypt> -> new HOOKS line
hooks_line() {
    local line=$1 want_encrypt=$2 inner hooks=() out=() h
    inner=${line#*\(}; inner=${inner%\)*}
    read -ra hooks <<< "$inner"

    printf '%s\n' "${hooks[@]}" | grep -qx filesystems \
        || { error "hooks_line: no 'filesystems' hook in: $line"; return 1; }

    for h in "${hooks[@]}"; do
        # encrypt must come before filesystems, and only once
        if [[ "$h" == "filesystems" && "$want_encrypt" == true ]]; then
            printf '%s\n' "${out[@]}" | grep -qx encrypt || out+=(encrypt)
        fi
        out+=("$h")
        # microcode must come after autodetect, and only once
        if [[ "$h" == "autodetect" ]]; then
            printf '%s\n' "${hooks[@]}" | grep -qx microcode || out+=(microcode)
        fi
    done
    echo "HOOKS=(${out[*]})"
}

# modules_line "MODULES=(...)" mod... -> new MODULES line
modules_line() {
    local line=$1; shift
    local inner mods=() m
    inner=${line#*\(}; inner=${inner%\)*}
    [[ -n "${inner// }" ]] && read -ra mods <<< "$inner"
    for m in "$@"; do
        printf '%s\n' "${mods[@]}" | grep -qx -- "$m" || mods+=("$m")
    done
    echo "MODULES=(${mods[*]})"
}

gpu_packages() {
    case "$1" in
        nvidia) echo "${GPU_NVIDIA[*]}" ;;
        amd)    echo "${GPU_AMD[*]}" ;;
        intel)  echo "${GPU_INTEL[*]}" ;;
        *)      echo "" ;;
    esac
}

# require_vars NAME... -- every named variable must exist and be non-empty.
# Names them all at once so a caller running under `set -u` fails with one
# readable list before it mutates anything, rather than dying on a bare
# "unbound variable" partway through.
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

# --- config-file editors ---------------------------------------------------

# grub_cmdline_add <file> key=value  -- idempotent, replaces a changed value.
# Asserts before and verifies after: a silent no-op here means a kernel with no
# cryptdevice= and a system that will not boot, discovered only at reboot.
grub_cmdline_add() {
    local file=$1 kv=$2 key=${2%%=*} current new tokens=() t

    # sed would mangle these: & means "the whole match" in a replacement, | is
    # the delimiter, and a backslash starts an escape. A kernel command-line
    # token never legitimately contains them, so refuse rather than escape.
    if [[ "$kv" == *'&'* || "$kv" == *'|'* || "$kv" == *"\\"* ]]; then
        error "grub_cmdline_add: '${kv}' contains a sed metacharacter (& | \\)"
        return 1
    fi

    grep -qE '^GRUB_CMDLINE_LINUX="[^"]*"[[:space:]]*$' "$file" \
        || { error "grub_cmdline_add: ${file} has no double-quoted GRUB_CMDLINE_LINUX line"; return 1; }
    current=$(grep -oP '(?<=^GRUB_CMDLINE_LINUX=").*(?="$)' "$file" || echo "")
    read -ra tokens <<< "$current"
    new=()
    for t in "${tokens[@]}"; do
        [[ "${t%%=*}" == "$key" ]] && continue   # drop any prior value for this key
        new+=("$t")
    done
    new+=("$kv")
    sed -i "s|^GRUB_CMDLINE_LINUX=\".*\"$|GRUB_CMDLINE_LINUX=\"${new[*]}\"|" "$file"
    grep -qF -- "$kv" "$file" \
        || { error "grub_cmdline_add: failed to write '${kv}' to ${file}"; return 1; }
}

# locale_gen_uncomment <file> <locale> -- uncomment the locale.gen entry whose
# locale name is exactly <locale>.
#
# The first field is compared as a fixed string rather than interpolating
# <locale> into a regex: the value comes straight from an unvalidated prompt,
# and in a regex the '.' of 'en_US.UTF-8' is a wildcard -- it leaves
# '#en_USX.UTF-8' alone but does uncomment '#en_USxUTF-8'. Absence is an
# error, not a no-op: sed and locale-gen both exit 0 having done nothing,
# which leaves /etc/locale.conf naming a locale the system does not have.
locale_gen_uncomment() {
    local file=$1 locale=$2 tmp mode
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

    # Moved into place, not copied over: a `cat` dying midway would leave the
    # file truncated with the original already gone. mktemp makes 0600, so the
    # original mode is captured first and restored after -- a locale.gen only
    # root can read is a surprise nobody needs later.
    mode=$(stat -c '%a' "$file") \
        || { rm -f "$tmp"; error "locale_gen_uncomment: cannot stat ${file}"; return 1; }
    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        error "locale_gen_uncomment: failed to replace ${file}"
        return 1
    fi
    chmod "$mode" "$file" || { error "locale_gen_uncomment: failed to restore mode ${mode} on ${file}"; return 1; }
}

# link_timezone <zoneinfo-dir> <tz> <localtime-path>
#
# -f, not -e: /usr/share/zoneinfo/America is a directory, and "America" is the
# obvious half-typed form of the default "America/Sao_Paulo". Linking
# /etc/localtime at a directory leaves the clock on UTC and says nothing.
link_timezone() {
    local zoneinfo=$1 tz=$2 localtime=$3 src
    src="${zoneinfo}/${tz}"
    if [[ ! -f "$src" ]]; then
        error "link_timezone: no such timezone: ${src}"
        return 1
    fi
    # -n matters on the retry, not the first run: if /etc/localtime is already
    # a symlink to a *directory*, plain `ln -sf` dereferences it and creates
    # the new link inside that directory instead, fails, and every subsequent
    # attempt dies on the same line until someone removes /etc/localtime.
    if ! ln -sfn "$src" "$localtime"; then
        error "link_timezone: failed to link ${localtime} -> ${src}"
        return 1
    fi
}

# --- host probes -----------------------------------------------------------

detect_ucode() {
    if grep -qi 'GenuineIntel' /proc/cpuinfo; then echo "intel-ucode"; else echo "amd-ucode"; fi
}

detect_gpu() {
    local vga
    vga=$(lspci -mm 2>/dev/null | grep -iE 'VGA|3D controller' || true)
    case "${vga,,}" in
        *nvidia*) echo nvidia ;;
        *"advanced micro devices"*|*amd*|*ati*) echo amd ;;
        *intel*) echo intel ;;
        *) echo none ;;
    esac
}

# True (0) when GRUB still needs installing. Takes the ESP mountpoint.
needs_grub_install() {
    local esp=${1:-/boot}
    [[ -f "${esp}/EFI/GRUB/grubx64.efi" ]] && return 1
    return 0
}

# --- subsystem setup (needs sudo, host-only) -------------------------------

setup_zram() {
    local src="${ARCH_SETUP_DIR}/etc/systemd/zram-generator.conf"
    info "Configuring zram swap..."
    sudo install -Dm644 "$src" /etc/systemd/zram-generator.conf
    success "zram configured (ram/2, zstd)"
}

setup_shell() {
    local check_only=${1:-} target current
    # $USER is root under `sudo ./provision.sh` (env_reset), which would chsh
    # root's shell instead of the human's. Prefer SUDO_USER when present.
    target=${SUDO_USER:-$USER}
    if [[ -z "$target" ]]; then
        error "setup_shell: cannot determine the target user (\$USER and \$SUDO_USER are both empty)"
        return 1
    fi
    current=$(getent passwd "$target" | cut -d: -f7)
    if [[ "$current" == "/usr/bin/zsh" ]]; then
        success "login shell is already zsh"
        return 0
    fi
    [[ "$check_only" == "--check-only" ]] && { info "would chsh to /usr/bin/zsh"; return 0; }

    grep -qx /usr/bin/zsh /etc/shells || echo /usr/bin/zsh | sudo tee -a /etc/shells >/dev/null
    if ! sudo chsh -s /usr/bin/zsh "$target"; then
        error "setup_shell: chsh failed for ${target}"
        return 1
    fi
    success "login shell set to /usr/bin/zsh"
}

# .zshrc needs both of these to exist before the first interactive shell.
setup_zsh_dirs() {
    mkdir -p "$HOME/.cache/zsh" "$HOME/.local/share/zinit"
    touch "$HOME/.cache/zsh/history"
    mkdir -p "$HOME/Pictures/Backgrounds" "$HOME/Documents" "$HOME/Downloads"
}

setup_xkb() {
    local script="$HOME/.config/xkb/install.sh"
    [[ -x "$script" ]] || { warn "xkb install.sh not found at ${script}, skipping"; return 0; }
    info "Installing the ptbr keyboard layout..."
    sudo "$script"
    success "keyboard layout installed"
}

# The Xsession file itself is not installed: it is a stock, unmodified copy
# of pacman's own /etc/lightdm/Xsession, and the drop-in below points
# session-wrapper at that existing path. Installing our copy on top would
# mark a pacman-owned file as locally modified (spurious .pacnew churn on
# every lightdm upgrade) for zero behavioral change.
setup_lightdm() {
    local base="${ARCH_SETUP_DIR}/etc/lightdm"
    info "Configuring lightdm..."
    sudo install -Dm644 "${base}/lightdm.conf.d/50-dotfiles.conf" \
        /etc/lightdm/lightdm.conf.d/50-dotfiles.conf
    [[ -f /usr/share/xsessions/bspwm.desktop ]] \
        || warn "/usr/share/xsessions/bspwm.desktop missing -- is bspwm installed?"
    success "lightdm configured (gtk-greeter, bspwm)"
}

setup_gpu() {
    local choice=$1 pkgs
    pkgs=$(gpu_packages "$choice")
    [[ -z "$pkgs" ]] && { info "no GPU driver selected"; return 0; }

    info "Installing GPU driver: ${pkgs}"
    # shellcheck disable=SC2086
    sudo pacman -S --needed --noconfirm $pkgs

    if [[ "$choice" == nvidia* ]]; then
        local cur new
        cur=$(grep -E '^MODULES=' /etc/mkinitcpio.conf)
        new=$(modules_line "$cur" nvidia nvidia_modeset nvidia_uvm nvidia_drm)
        sudo sed -i "s|^MODULES=.*|${new}|" /etc/mkinitcpio.conf

        sudo install -Dm644 "${ARCH_SETUP_DIR}/etc/pacman.d/hooks/nvidia.hook" \
            /etc/pacman.d/hooks/nvidia.hook

        if ! sudo bash -c "$(declare -f grub_cmdline_add error); \
            grub_cmdline_add /etc/default/grub nvidia-drm.modeset=1"; then
            error "setup_gpu: could not add nvidia-drm.modeset=1 to /etc/default/grub"
            return 1
        fi

        sudo mkinitcpio -P
        sudo grub-mkconfig -o /boot/grub/grub.cfg
    fi
    success "GPU driver configured"
}

enable_services() {
    local svc
    for svc in "$@"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null \
           && [[ -n "$(systemctl list-unit-files "${svc}.service" --no-legend)" ]]; then
            if sudo systemctl enable "$svc" &>/dev/null; then
                success "enabled ${svc}"
            else
                error "failed to enable ${svc}"
            fi
        else
            warn "unit ${svc}.service not found, skipping"
        fi
    done
}
