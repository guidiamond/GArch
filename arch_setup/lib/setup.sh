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
#
# EVERY function below is invoked by provision.sh as `step "name" <fn>`, i.e.
# from inside an `if` condition, and bash suspends errexit for the whole
# dynamic extent of that. So none of these can lean on provision.sh's `set -e`:
# an unchecked command here is a command whose failure nothing will ever
# notice, and a function ending on `success` is a function that returns 0 no
# matter what happened above. Check every command, and let the `success` be
# reachable only when there is something to be successful about.
# test/setup.bats pins this for each function.

setup_zram() {
    local src="${ARCH_SETUP_DIR}/etc/systemd/zram-generator.conf"
    info "Configuring zram swap..."
    if ! sudo install -Dm644 "$src" /etc/systemd/zram-generator.conf; then
        error "setup_zram: could not install ${src} to /etc/systemd/zram-generator.conf"
        return 1
    fi
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
    # Unchecked, this read the other way round: a getent that fails leaves
    # `current` empty, empty is not /usr/bin/zsh, and "cannot tell what the
    # login shell is" silently became "the login shell is wrong, chsh it".
    if ! current=$(getent passwd "$target"); then
        error "setup_shell: cannot read the passwd entry for ${target}"
        return 1
    fi
    # The shell is field 7 and field 7 is the last one, so no `cut` -- and so
    # no pipeline whose status depends on whether the caller set pipefail.
    current=${current##*:}
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
    if ! mkdir -p "$HOME/.cache/zsh" "$HOME/.local/share/zinit"; then
        error "setup_zsh_dirs: could not create ${HOME}/.cache/zsh and ${HOME}/.local/share/zinit"
        return 1
    fi
    if ! touch "$HOME/.cache/zsh/history"; then
        error "setup_zsh_dirs: could not create the zsh history file ${HOME}/.cache/zsh/history"
        return 1
    fi
    if ! mkdir -p "$HOME/Pictures/Backgrounds" "$HOME/Documents" "$HOME/Downloads"; then
        error "setup_zsh_dirs: could not create the standard user directories under ${HOME}"
        return 1
    fi
}

# ASSUMPTION: $HOME/.config/xkb/install.sh is itself idempotent. It is stowed
# from the dotfiles repo, lives outside arch_setup/, and is re-run in full on
# every provision -- nothing here checks whether the layout is already
# installed, because only that script knows where it puts it. If it ever grows
# a non-idempotent step, this is the caller that will re-run it.
setup_xkb() {
    local script="$HOME/.config/xkb/install.sh"
    [[ -x "$script" ]] || { warn "xkb install.sh not found at ${script}, skipping"; return 0; }
    info "Installing the ptbr keyboard layout..."
    if ! sudo "$script"; then
        error "setup_xkb: ${script} failed"
        return 1
    fi
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
    if ! sudo install -Dm644 "${base}/lightdm.conf.d/50-dotfiles.conf" \
            /etc/lightdm/lightdm.conf.d/50-dotfiles.conf; then
        error "setup_lightdm: could not install /etc/lightdm/lightdm.conf.d/50-dotfiles.conf"
        return 1
    fi
    [[ -f /usr/share/xsessions/bspwm.desktop ]] \
        || warn "/usr/share/xsessions/bspwm.desktop missing -- is bspwm installed?"
    success "lightdm configured (gtk-greeter, bspwm)"
}

# setup_gpu <nvidia|amd|intel|none>
#
# LIMITATION -- idempotent for a repeated answer, but it does not converge on a
# CHANGED one. Answering nvidia and then amd installs the amd packages and stops
# there: the nvidia modules stay in /etc/mkinitcpio.conf's MODULES=,
# /etc/pacman.d/hooks/nvidia.hook stays installed, and nvidia-drm.modeset=1 stays
# on the kernel command line. Deliberately left alone -- undoing it means
# removing entries from MODULES=, deleting a pacman hook and dropping a cmdline
# token, i.e. three more ways to make a machine that does not boot, for a case
# (swapping the GPU in a personal workstation) that is rare and visible. Undo it
# by hand, or reinstall.
setup_gpu() {
    local choice=$1 pkgs
    # Checked, because an unrecognised answer is not "none": see gpu_packages.
    if ! pkgs=$(gpu_packages "$choice"); then
        error "setup_gpu: refusing to configure an unrecognised GPU driver: '${choice}'"
        return 1
    fi
    [[ -z "$pkgs" ]] && { info "no GPU driver selected"; return 0; }

    info "Installing GPU driver: ${pkgs}"
    # shellcheck disable=SC2086
    if ! sudo pacman -S --needed --noconfirm $pkgs; then
        error "setup_gpu: could not install the ${choice} driver packages: ${pkgs}"
        return 1
    fi

    if [[ "$choice" == nvidia* ]]; then
        local cur new
        # Asserted rather than assumed, the same way grub_cmdline_add asserts
        # its GRUB_CMDLINE_LINUX line: the sed below is anchored to ^MODULES=,
        # so against a file without one it matches nothing, exits 0 and leaves
        # an initramfs with no nvidia modules in it.
        if ! cur=$(grep -E '^MODULES=' /etc/mkinitcpio.conf); then
            error "setup_gpu: /etc/mkinitcpio.conf has no MODULES= line to add the nvidia modules to"
            return 1
        fi
        new=$(modules_line "$cur" nvidia nvidia_modeset nvidia_uvm nvidia_drm)
        if ! sudo sed -i "s|^MODULES=.*|${new}|" /etc/mkinitcpio.conf; then
            error "setup_gpu: could not write the nvidia modules to /etc/mkinitcpio.conf"
            return 1
        fi

        if ! sudo install -Dm644 "${ARCH_SETUP_DIR}/etc/pacman.d/hooks/nvidia.hook" \
                /etc/pacman.d/hooks/nvidia.hook; then
            error "setup_gpu: could not install /etc/pacman.d/hooks/nvidia.hook"
            return 1
        fi

        if ! sudo bash -c "$(declare -f grub_cmdline_add error); \
            grub_cmdline_add /etc/default/grub nvidia-drm.modeset=1"; then
            error "setup_gpu: could not add nvidia-drm.modeset=1 to /etc/default/grub"
            return 1
        fi

        # Past this point /etc has already been rewritten for nvidia, so these
        # two are what actually make the machine bootable with it -- and they
        # are the reason this function may not end on a bare `success`. Left
        # unchecked, a failure here produced a fully green summary and
        # "Reboot to land in lightdm" on a machine whose initramfs and grub.cfg
        # know nothing about the driver /etc is now configured for.
        if ! sudo mkinitcpio -P; then
            error "setup_gpu: mkinitcpio -P failed -- the initramfs has no nvidia modules; do NOT reboot"
            return 1
        fi
        if ! sudo grub-mkconfig -o /boot/grub/grub.cfg; then
            error "setup_gpu: grub-mkconfig failed -- /boot/grub/grub.cfg has no nvidia-drm.modeset=1; do NOT reboot"
            return 1
        fi
    fi
    success "GPU driver configured"
}

# enable_services <unit>... -- non-zero if any unit that EXISTS could not be
# enabled. A unit that is not installed warns and is skipped, and that is not
# counted as a failure: provision.sh asks for docker, bluetooth and cups on
# every run, and a machine provisioned with --skip-packages, or one whose
# operator declined the optional group, legitimately has none of them. Failing
# there would make the summary red on a run where nothing went wrong.
#
# The count is the point. This used to return the last iteration's status, so
# `enable_services NetworkManager lightdm docker bluetooth cups` could fail to
# enable NetworkManager -- no network on the next boot -- and still return 0
# because cups happened to be fine.
enable_services() {
    local svc listed existing=0 failed=0
    for svc in "$@"; do
        # One systemctl call, not two. This used to be
        #   systemctl list-unit-files X &>/dev/null && [[ -n "$(systemctl ... --no-legend)" ]]
        # and the first half never decided anything: `list-unit-files <pattern>`
        # exits 0 for a pattern that matches nothing, so the emptiness of the
        # output was already the whole answer. The `|| listed=""` is the part
        # that carries meaning -- it says what a systemctl that genuinely FAILS
        # means here, and the answer is "treat it as absent and skip", because
        # the alternative is a run that reports five service failures when what
        # actually broke was one call to systemctl.
        listed=$(systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null) || listed=""
        if [[ -z "$listed" ]]; then
            warn "unit ${svc}.service not found, skipping"
            continue
        fi
        existing=$((existing + 1))
        if sudo systemctl enable "$svc" &>/dev/null; then
            success "enabled ${svc}"
        else
            error "failed to enable ${svc}"
            failed=$((failed + 1))
        fi
    done
    if (( failed )); then
        # Counted against the units that EXISTED, not against $#. The skipped
        # ones are excluded from the numerator by design, so including them in
        # the denominator understates: on a --skip-packages machine, where
        # three of the five units provision.sh asks for are legitimately
        # absent, "every unit that exists failed" printed as "1 of 5".
        error "enable_services: ${failed} of ${existing} installed unit(s) could not be enabled"
        return 1
    fi
}
