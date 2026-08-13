#!/bin/bash
# Install packages from a list file. Requires lib/ui.sh.
# shellcheck shell=bash

# Cumulative across a whole run, and deliberately never reset: provision.sh
# calls pkg_install_aur twice (aur.txt, then optional.txt) and its summary
# reads this once at the end, wanting every package that failed in either.
#
# It is NOT what pkg_install_aur reports or returns on -- that used to be the
# case, and the second call then re-warned about the first call's failures and
# the summary counted them twice. Each call keeps its own list; see there.
PKG_FAILED=()

# How much of a failed AUR build to print. A makepkg log runs to thousands of
# lines and the reason is at the end of it, so the tail is what gets shown --
# and it goes through provision.sh's tee, so it survives in the run log.
AUR_LOG_LINES=20

# One package per line. Strips blank lines and comments -- BOTH whole-line and
# inline, so `foo  # needed by bar` yields `foo`.
#
# Inline stripping is safe because no repo or AUR package name contains '#',
# but it does mean this function and a hand-written `grep -hvE '^\s*#|^\s*$'`
# disagree the moment anyone writes an inline comment in packages/*.txt. Today
# the four lists use whole-line comments only, so the two happen to agree.
# Anything that counts or extracts packages outside this file -- a README
# verification snippet, a test -- must call pkg_list rather than re-implement
# it, or it will be wrong on the first inline comment somebody adds.
pkg_list() {
    local file=$1
    [[ -f "$file" ]] || { error "package list not found: ${file}"; return 1; }
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" | grep -v '^$'
}

# pkg_read <file> <array-name> -- read a list into a named array, failing
# loudly on a missing or empty file.
#
# Do NOT use `mapfile -t arr < <(pkg_list f) || return 1` -- mapfile's exit
# status reflects mapfile, not the process substitution, so the `||` is dead
# code and a bad path silently yields an empty array. In phase_base that would
# pacstrap only the microcode package and fail much later, confusingly.
#
# The locals carry a _pkg_ prefix, and the colliding names are refused outright,
# for the reason ask_password documents: a nameref bound to a variable of its
# own name is a circular reference, which bash reports as a *warning* on stderr
# and then leaves the array empty -- so `pkg_read f __out` used to "succeed" at
# reading nothing. A prefix alone is a convention somebody can break silently;
# the case below turns it into an error with a name in it.
pkg_read() {
    case "$2" in
        _pkg_file|_pkg_out|_pkg_line)
            error "pkg_read: output array name '${2}' collides with an internal local"
            return 1 ;;
        "")
            error "pkg_read: no output array name given"
            return 1 ;;
    esac
    local _pkg_file=$1 _pkg_line
    local -n _pkg_out=$2
    _pkg_out=()
    while IFS= read -r _pkg_line; do _pkg_out+=("$_pkg_line"); done < <(pkg_list "$_pkg_file")
    (( ${#_pkg_out[@]} )) || { error "package list is missing or empty: ${_pkg_file}"; return 1; }
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
#
# Returns non-zero when anything in THIS list failed. It used to end on the
# if/else below, whose status is 0 down both branches, so a run where every
# single AUR package failed to build reported success to provision.sh's step()
# and the summary printed a green line for it.
# Output goes to a temp file rather than /dev/null, and the tail of it is
# printed for each package that failed. `&>/dev/null` left "failed 3 of 13:
# a b c" as the entire diagnosis of a failed build -- no PKGBUILD error, no
# missing dependency, nothing to act on, and nothing in the run log either.
#
# It is NOT about a lost sudo password prompt: sudo writes that prompt to
# /dev/tty, not to stderr, so a redirect here never hid it (sudo(8) documents
# the stderr form as what -S selects "instead of using the terminal device";
# measured too -- a /dev/tty write survives `&>/dev/null` while stdout and
# stderr do not). Where there is no terminal sudo cannot prompt at all and
# fails, and the reason for THAT failure is one of the things this now prints.
pkg_install_aur() {
    local file=$1 pkg total=0 n=0 log
    local -a pkgs failed=()
    pkg_read "$file" pkgs || return 1
    total=${#pkgs[@]}
    log=$(mktemp) || { error "pkg_install_aur: cannot create a temp file for yay's output"; return 1; }
    info "Installing ${total} AUR packages..."
    for pkg in "${pkgs[@]}"; do
        n=$((n + 1))
        printf '\r  [%d/%d] %-40s' "$n" "$total" "$pkg"
        if ! yay -S --needed --noconfirm "$pkg" >"$log" 2>&1; then
            failed+=("$pkg")
            # The progress line is overwritten first, or the error lands on top
            # of it and the package name is half eaten.
            printf '\r%-60s\r' ""
            error "yay could not build ${pkg}, last ${AUR_LOG_LINES} lines:"
            tail -n "$AUR_LOG_LINES" "$log" >&2
        fi
    done
    printf '\r%-60s\r' ""
    rm -f "$log"
    if (( ${#failed[@]} )); then
        PKG_FAILED+=("${failed[@]}")
        warn "failed ${#failed[@]} of ${total} from ${file}: ${failed[*]}"
        return 1
    fi
    success "all ${total} AUR packages installed"
}

# Every command is checked rather than left to errexit, and that is not
# defensive style -- it is required. provision.sh calls this as
# `step "yay" ensure_yay`, which puts it in an `if` condition, and bash
# suspends errexit for the whole dynamic extent of a condition (measured on
# bash 5.3: an explicit `set -e` inside the function does not restore it, and
# neither does wrapping the body in a subshell). Before this, a failed clone or
# a failed makepkg fell straight through to `rm -rf "$tmp"` and
# `success "yay installed"`, and every AUR step afterwards then failed on a
# missing command with no explanation.
ensure_yay() {
    command -v yay &>/dev/null && { success "yay already installed"; return 0; }
    info "Installing yay..."
    local tmp rc=0
    tmp=$(mktemp -d) || { error "ensure_yay: cannot create a build directory"; return 1; }
    if ! git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"; then
        error "ensure_yay: could not clone yay-bin from the AUR"
        rc=1
    elif ! ( cd "$tmp/yay-bin" && makepkg -si --noconfirm ); then
        error "ensure_yay: makepkg could not build or install yay-bin"
        rc=1
    fi
    # Unconditional, as before: a half-built package tree in a temp dir is
    # worth nothing to anyone, and the errors above already say what happened.
    rm -rf "$tmp"
    (( rc == 0 )) || return "$rc"
    # makepkg -si can exit 0 having installed nothing (its pacman step reads
    # from the terminal, and --noconfirm is not --needed). What every later
    # step depends on is only whether the binary is on PATH now.
    command -v yay &>/dev/null \
        || { error "ensure_yay: yay is still not on PATH after makepkg -si"; return 1; }
    success "yay installed"
}
