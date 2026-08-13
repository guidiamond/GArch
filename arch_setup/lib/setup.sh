#!/bin/bash
# One idempotent function per subsystem, plus enable_services. Stage 2 only.
# Requires lib/ui.sh and lib/system.sh (setup_gpu calls gpu_packages,
# modules_line and grub_cmdline_add), and reads ARCH_SETUP_DIR.
#
# Split out of lib/system.sh because the two files live under opposite
# constraints. Everything here runs `sudo`, reads ARCH_SETUP_DIR, and only ever
# runs on a booted host as the normal user -- see the COUPLING block at the top
# of lib/system.sh for the rules that apply there and that nothing in this file
# could satisfy. Nothing here is injectable into the generated chroot script,
# nothing here is sourced by install.sh, and lib/chroot.sh's CHROOT_INJECTED
# must never name a function from this file.
# shellcheck shell=bash

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
