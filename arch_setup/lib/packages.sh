#!/bin/bash
# Install packages from a list file. Requires lib/ui.sh.
# shellcheck shell=bash

PKG_FAILED=()

pkg_list() {
    local file=$1
    [[ -f "$file" ]] || { error "package list not found: ${file}"; return 1; }
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" | grep -v '^$'
}

# Read a list into a named array, failing loudly on a missing or empty file.
#
# Do NOT use `mapfile -t arr < <(pkg_list f) || return 1` -- mapfile's exit
# status reflects mapfile, not the process substitution, so the `||` is dead
# code and a bad path silently yields an empty array. In phase_base that would
# pacstrap only the microcode package and fail much later, confusingly.
pkg_read() {
    local __file=$1
    local -n __out=$2
    local __line
    __out=()
    while IFS= read -r __line; do __out+=("$__line"); done < <(pkg_list "$__file")
    (( ${#__out[@]} )) || { error "package list is missing or empty: ${__file}"; return 1; }
}

# One transaction: faster and resolves dependencies properly.
pkg_install_repo() {
    local file=$1
    local -a pkgs
    pkg_read "$file" pkgs || return 1
    info "Installing ${#pkgs[@]} repo packages..."
    sudo pacman -S --needed --noconfirm "${pkgs[@]}"
}

# One at a time: AUR builds genuinely fail individually, and one bad
# PKGBUILD must not take the other 30 with it.
pkg_install_aur() {
    local file=$1 pkg total=0 n=0
    local -a pkgs
    pkg_read "$file" pkgs || return 1
    total=${#pkgs[@]}
    info "Installing ${total} AUR packages..."
    for pkg in "${pkgs[@]}"; do
        n=$((n + 1))
        printf '\r  [%d/%d] %-40s' "$n" "$total" "$pkg"
        yay -S --needed --noconfirm "$pkg" &>/dev/null || PKG_FAILED+=("$pkg")
    done
    printf '\r%-60s\r' ""
    if (( ${#PKG_FAILED[@]} )); then
        warn "failed: ${PKG_FAILED[*]}"
    else
        success "all AUR packages installed"
    fi
}

ensure_yay() {
    command -v yay &>/dev/null && { success "yay already installed"; return 0; }
    info "Installing yay..."
    local tmp
    tmp=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
    ( cd "$tmp/yay-bin" && makepkg -si --noconfirm )
    rm -rf "$tmp"
    success "yay installed"
}
