#!/bin/bash
# Stage 2: provision a booted Arch system. Run as your normal user.
# Idempotent -- safe to re-run at any time to re-sync this machine.
#
#   ~/.dotfiles/arch_setup/provision.sh
#
# Run `./provision.sh --help` for the flags; usage() below is the one copy.
set -euo pipefail

ARCH_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ARCH_SETUP_DIR

# Whether the operator chose DOTFILES_DIR themselves has to be answered before
# lib/dotfiles.sh is sourced, because sourcing it fills the variable in.
# resolve_dotfiles_dir below is what reads this.
DOTFILES_DIR_PRESET=${DOTFILES_DIR:-}

# shellcheck source=lib/ui.sh
source "${ARCH_SETUP_DIR}/lib/ui.sh"
# shellcheck source=lib/packages.sh
source "${ARCH_SETUP_DIR}/lib/packages.sh"
# shellcheck source=lib/dotfiles.sh
source "${ARCH_SETUP_DIR}/lib/dotfiles.sh"
# shellcheck source=lib/system.sh
source "${ARCH_SETUP_DIR}/lib/system.sh"
# The setup_* family, split out of lib/system.sh at the sudo seam. Must come
# after lib/system.sh: setup_gpu calls gpu_packages, modules_line and
# grub_cmdline_add, all of which live there.
# shellcheck source=lib/setup.sh
source "${ARCH_SETUP_DIR}/lib/setup.sh"

SKIP_PACKAGES=false
SKIP_GPU=false
NO_OPTIONAL=false
HELP=false
# Set once in main from `[[ -t 0 ]]`. The two phases that ask a question branch
# on this rather than prompting into a closed stdin -- see main.
INTERACTIVE=true
TOTAL_PHASES=8
STEPS_OK=(); STEPS_FAILED=()
# Empty means "this run is not being logged", which open_log says out loud.
LOG=""
SUMMARY_PRINTED=false
KEEP_LOGS=10

usage() {
    cat <<'USAGE'
Usage: provision.sh [--skip-packages] [--skip-gpu] [--no-optional]

Stage 2 of the Arch install: installs the package set, stows the dotfiles,
sets the login shell, installs the keyboard layout and enables the services.
Run as your normal user on a booted system. Idempotent -- re-run it any time
to re-sync this machine. Stage 1 is arch_setup/install.sh.

  --skip-packages  skip the pacman/yay steps (fast config-only re-run)
  --skip-gpu       skip the GPU phase -- it rebuilds the initramfs and
                   grub.cfg, which you rarely want on a machine that already
                   boots
  --no-optional    never prompt for the optional application group
  -h, --help       print this and exit

With no terminal on stdin (cron, `ssh -n`, a pipe) the two phases that ask a
question -- the optional application group and the GPU driver -- are skipped
rather than answered blind. Everything else runs unattended.
USAGE
}

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --skip-packages) SKIP_PACKAGES=true ;;
            --skip-gpu)      SKIP_GPU=true ;;
            --no-optional)   NO_OPTIONAL=true ;;
            -h|--help)       HELP=true ;;
            *) die "unknown flag: ${arg}" ;;
        esac
    done
}

# ---------------- logging ----------------

# Prints a writable log path, or nothing at status 1 when there is none.
#
# The directory is probed by creating the file, not by trusting tee. With an
# unwritable path `exec > >(tee -a "$LOG")` reports SUCCESS: bash sets the
# redirection up regardless, tee prints one "Permission denied" line to the
# terminal and then goes on copying stdin to stdout perfectly happily until
# EOF. Measured on this bash -- exec status 0, every later message still on
# screen, and no log file anywhere. So nothing downstream can notice, and
# "Logging to ~/arch-provision-....log" would be a lie the operator only
# discovers when they go looking for the file.
log_path() {
    local dir probe name
    name="arch-provision-$(date +%Y%m%d-%H%M%S).log"
    for dir in "${HOME:-}" "${TMPDIR:-/tmp}"; do
        [[ -n "$dir" && -d "$dir" ]] || continue
        probe="${dir}/${name}"
        # umask in a subshell so it cannot leak into the rest of the run. The
        # log carries whatever pacman, git and yay print, which is not secret,
        # but it is nobody else's business either.
        if ( umask 077; : > "$probe" ) 2>/dev/null; then
            echo "$probe"
            return 0
        fi
    done
    return 1
}

# One log per run, kept forever, is a $HOME that only grows -- and after a few
# months of re-runs the useful one is buried. Deliberately narrow: regular
# files only, this exact name shape only, and only in the directory the log was
# just written to. `sort -r` is chronological here because the timestamp is
# fixed-width.
prune_logs() {
    local dir=${LOG%/*} old
    [[ -n "$dir" && -d "$dir" ]] || return 0
    while IFS= read -r old; do
        [[ -n "$old" ]] || continue
        rm -f -- "${dir}/${old}" || warn "could not remove the old log ${dir}/${old}"
    done < <(find "$dir" -maxdepth 1 -type f -name 'arch-provision-*.log' -printf '%f\n' 2>/dev/null \
             | sort -r | tail -n "+$((KEEP_LOGS + 1))")
}

# Everything after this point -- including every prompt -- goes through tee.
# That is fine for the prompts: bash's `read -p` writes to stderr and reads
# from the terminal, so with 2>&1 the prompt travels through tee and still
# arrives (verified under `script -qec` against a real tty, prompt and all).
# It is why `sudo -v` runs BEFORE this, though; see main.
open_log() {
    if ! LOG=$(log_path); then
        LOG=""
        warn "no writable directory for a log file; this run will not be logged"
        return 0
    fi
    exec > >(tee -a "$LOG") 2>&1
    info "Logging to ${LOG}"
    prune_logs
}

# ---------------- where the dotfiles are ----------------

# lib/dotfiles.sh defaults DOTFILES_DIR to $HOME/.dotfiles at source time. That
# is right for the documented invocation and quietly wrong for any other one:
# run a clone from /opt/dotfiles and dotfiles_clone would see no
# $HOME/.dotfiles/.git, clone a SECOND copy from GitHub, and stow that --
# ignoring the tree you launched, with no message saying so, because both
# operations succeed.
#
# So prefer the repository this script actually lives in, when it looks like a
# dotfiles checkout: a .git, plus the stow package stow_apply needs. An
# explicit DOTFILES_DIR in the environment still beats both.
resolve_dotfiles_dir() {
    local repo_root
    if [[ -n "$DOTFILES_DIR_PRESET" ]]; then
        return 0
    fi
    repo_root=$(cd "${ARCH_SETUP_DIR}/.." && pwd) || return 0
    if [[ ! -d "${repo_root}/.git" || ! -d "${repo_root}/${STOW_PACKAGE}" ]]; then
        return 0
    fi
    if [[ "$repo_root" != "$DOTFILES_DIR" ]]; then
        info "using the repository this script lives in: ${repo_root}"
        DOTFILES_DIR="$repo_root"
    fi
}

# ---------------- steps and the summary ----------------

# Runs a step, records the outcome, and never aborts the whole run.
#
# Called directly rather than as `if ( "$@" )` in a subshell, and that is a
# real choice: pkg_install_aur appends to PKG_FAILED and the summary reads it,
# so a subshell would silently empty the "packages that failed to build" line
# while still looking like it worked. The one thing a subshell buys -- catching
# an `exit` from die (and so from confirm_step, which dies when you decline) --
# is covered two other ways instead: no lib/ function any step can reach calls
# either, which test/provision.bats pins as a transitive property rather than a
# promise; and print_summary runs from an EXIT trap, so even an exit nobody
# predicted leaves a partial report rather than silence.
#
# NOTE for anything invoked through here: `if "$@"` puts the callee in a
# condition context, and bash suspends errexit for the WHOLE DYNAMIC EXTENT of
# that -- every command in the function, in everything it calls, and in
# subshells it spawns. Measured on bash 5.3: an explicit `set -e` inside does
# not restore it, and neither does wrapping the body in `( set -e; ... )`. So a
# step function has to check its own commands; it cannot lean on the `set -e`
# at the top of this file. lib/packages.sh's ensure_yay was written assuming it
# could, and reported "yay installed" after a failed build.
step() {
    local name=$1; shift
    if "$@"; then
        STEPS_OK+=("$name")
    else
        STEPS_FAILED+=("$name")
        warn "step failed: ${name}"
    fi
}

# Idempotent, because it is called both from main's tail (the normal path) and
# from the EXIT trap (the abnormal one), and exactly one of them should print.
#
# It must not run `exit` and must not end on a failing command: an EXIT trap
# leaves the shell's status alone unless it does one of those. See install.sh's
# cleanup() for where that was measured.
print_summary() {
    if [[ "$SUMMARY_PRINTED" == true ]]; then
        return 0
    fi
    SUMMARY_PRINTED=true
    echo ""
    banner "$TOTAL_PHASES" "$TOTAL_PHASES" "Summary"
    local s
    # "${empty[@]}" expands to nothing under `set -u` on bash 4.4 and later
    # (verified on 5.3); older bash aborted on it, which is why this looks like
    # it needs a guard and does not.
    for s in "${STEPS_OK[@]}";     do success "$s"; done
    for s in "${STEPS_FAILED[@]}"; do error   "$s"; done
    # An `if`, not `(( ... )) && warn ...`. In this position the && form does
    # not abort under errexit -- the failing `((` is the left operand of &&, so
    # it is exempt, and the list's own status is only checked when the list is
    # the last command of a function or script (both verified). But that is a
    # property of where the line SITS: append nothing after it, or move it to
    # the end of print_summary, and a clean run starts exiting 1 after printing
    # a fully green summary. The `if` makes the position stop mattering.
    if (( ${#PKG_FAILED[@]} )); then
        warn "packages that failed to build: ${PKG_FAILED[*]}"
    fi
    echo ""
    if [[ -n "$LOG" ]]; then
        info "Full log: ${LOG}"
    fi
    return 0
}

main() {
    parse_args "$@"
    if [[ "$HELP" == true ]]; then
        usage
        return 0
    fi
    [[ -t 0 ]] || INTERACTIVE=false

    (( EUID != 0 )) || die "run as your normal user, not root (sudo is used where needed)"

    # Before open_log, not after. sudo writes its prompt to stderr and reads the
    # password from /dev/tty, so it does survive the redirect -- but the one
    # prompt that has to be unmistakable is the one asking for a password, and
    # behind tee there is no way to tell a sudo waiting for input from a script
    # that has hung. Nothing has been written at this point either, so failing
    # here costs nothing.
    sudo -v || die "sudo is required"

    open_log
    resolve_dotfiles_dir

    # Armed after the flags are parsed, so `--help` and an unknown flag do not
    # print an empty summary. See print_summary for why this exists at all.
    trap print_summary EXIT

    banner 1 "$TOTAL_PHASES" "Dotfiles"
    step "dotfiles-clone" dotfiles_clone
    step "stow"           stow_apply "$DOTFILES_DIR" "$HOME"

    banner 2 "$TOTAL_PHASES" "AUR Helper"
    if [[ "$SKIP_PACKAGES" == true ]]; then
        info "skipping (--skip-packages)"
    else
        step "yay" ensure_yay
    fi

    banner 3 "$TOTAL_PHASES" "Packages"
    if [[ "$SKIP_PACKAGES" == true ]]; then
        info "skipping (--skip-packages)"
    else
        step "repo-packages" pkg_install_repo "${ARCH_SETUP_DIR}/packages/repo.txt"
        step "aur-packages"  pkg_install_aur  "${ARCH_SETUP_DIR}/packages/aur.txt"
        if [[ "$NO_OPTIONAL" == true ]]; then
            info "skipping the optional group (--no-optional)"
        elif [[ "$INTERACTIVE" != true ]]; then
            info "skipping the optional group (stdin is not a terminal)"
        elif ask_yes_no "Install the optional application group (browsers, IDEs, chat)?" "n"; then
            step "optional-packages" pkg_install_aur "${ARCH_SETUP_DIR}/packages/optional.txt"
        fi
    fi

    banner 4 "$TOTAL_PHASES" "Shell"
    step "zsh-dirs"  setup_zsh_dirs
    step "zsh-shell" setup_shell

    banner 5 "$TOTAL_PHASES" "Keyboard"
    step "xkb" setup_xkb

    banner 6 "$TOTAL_PHASES" "Graphics"
    # The only phase that touches the bootloader and the initramfs, and the only
    # one whose failure mode is a machine that does not boot. It is therefore
    # the only one that refuses to run itself: --skip-gpu turns it off, and with
    # no terminal it turns itself off, because the alternative is a cron or
    # `ssh -n` run rebuilding grub.cfg with a driver nobody chose. (Without the
    # check it would not silently pick one either -- `ask` fails at EOF and
    # `choice=$(ask ...)` would abort the whole run under errexit, one phase
    # short of the services. Skipping is the same safety, reported properly.)
    if [[ "$SKIP_GPU" == true ]]; then
        info "skipping (--skip-gpu)"
    elif [[ "$INTERACTIVE" != true ]]; then
        warn "skipping the graphics phase: it rebuilds the initramfs and grub.cfg,"
        warn "and there is no terminal here to confirm the driver. Re-run"
        warn "interactively if this machine needs its GPU driver configured."
    else
        local detected choice
        detected=$(detect_gpu)
        info "Detected GPU: ${detected}"
        warn "This phase rebuilds the initramfs and grub.cfg."
        choice=$(ask "GPU driver (nvidia / amd / intel / none)" "$detected")
        step "gpu" setup_gpu "$choice"
    fi

    banner 7 "$TOTAL_PHASES" "Display Manager"
    step "lightdm" setup_lightdm

    banner 8 "$TOTAL_PHASES" "Services"
    step "zram"     setup_zram
    step "services" enable_services NetworkManager lightdm docker bluetooth cups

    print_summary

    if (( ${#STEPS_FAILED[@]} )); then
        error "${#STEPS_FAILED[@]} step(s) failed"
        return 1
    fi
    success "Provisioning complete. Reboot to land in lightdm."
}

# Guarded so test/provision.bats can source this file to reach step,
# parse_args, log_path and print_summary. Without it, sourcing would parse the
# flags, ask for a sudo password and start installing 250 packages.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
