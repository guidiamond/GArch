#!/usr/bin/env bats
#
# provision.sh is an orchestrator, and most of it -- 250 packages, chsh,
# mkinitcpio, systemctl enable -- cannot be exercised for real. What can be is
# everything pulled out of main into a named function (step, parse_args,
# log_path, prune_logs, resolve_dotfiles_dir, print_summary), plus main itself
# with every machine-touching call stubbed out, which is where the phase
# ordering and the skip branches are actually pinned.
#
# NOTHING here may write to the real $HOME: the user's dotfiles are stowed out
# of the repo as symlinks into it, and a stray file corrupts a running desktop.
# Every case that could write reassigns HOME to $BATS_TEST_TMPDIR first.

load helpers

setup() {
    ARCH_SETUP="${BATS_TEST_DIRNAME}/.."
    PROVISION="${ARCH_SETUP}/provision.sh"
    TMP="$BATS_TEST_TMPDIR"
}

# provision.sh is sourced, never executed. Each case gets its own shell,
# because sourcing it turns on `set -euo pipefail` in the sourcing shell -- and
# because bats' own `run` turns errexit *off* inside the run, so `run step ...`
# could not show how step behaves in the settings provision.sh actually uses.
in_provision() {
    HOME="$TMP" bash -c "source '${PROVISION}'; $*"
}

# --- structure -------------------------------------------------------------

@test "provision.sh parses" {
    run bash -n "$PROVISION"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# The `if [[ "${BASH_SOURCE[0]}" == "$0" ]]` guard at the bottom is what makes
# every other test in this file safe. Without it, sourcing provision.sh parses
# the flags, asks for a sudo password and starts installing packages.
@test "sourcing provision.sh runs no phase and arms no EXIT trap" {
    run env HOME="$TMP" bash -c "source '${PROVISION}'; printf 'TRAP[%s]' \"\$(trap -p EXIT)\""
    [ "$status" -eq 0 ]
    [ "$output" = "TRAP[]" ]
}

@test "provision.sh defines no function whose name bats reserves" {
    local reserved name
    for name in run setup teardown load skip; do
        reserved=$(grep -cE "^${name}\(\)" "$PROVISION" || true)
        [ "$reserved" -eq 0 ] || {
            echo "provision.sh defines ${name}(), which bats also defines" >&2
            return 1
        }
    done
}

# --- parse_args ------------------------------------------------------------

@test "parse_args sets each flag and leaves the others alone" {
    run in_provision 'parse_args --skip-packages
                      printf "%s %s %s %s" "$SKIP_PACKAGES" "$SKIP_GPU" "$NO_OPTIONAL" "$HELP"'
    [ "$status" -eq 0 ]
    [ "$output" = "true false false false" ]

    run in_provision 'parse_args --skip-gpu --no-optional
                      printf "%s %s %s %s" "$SKIP_PACKAGES" "$SKIP_GPU" "$NO_OPTIONAL" "$HELP"'
    [ "$output" = "false true true false" ]

    run in_provision 'parse_args -h; printf "%s" "$HELP"'
    [ "$output" = "true" ]
}

@test "parse_args dies on an unknown flag" {
    run in_provision 'parse_args --wipe-everything; echo REACHED'
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown flag"* ]]
    [[ "$output" != *"REACHED"* ]]
}

# --- step ------------------------------------------------------------------

@test "step records the outcome without aborting a set -e run" {
    run in_provision 'ok(){ return 0; }; bad(){ return 1; }
                      step a ok; step b bad; step c ok
                      printf "OK[%s] FAILED[%s]" "${STEPS_OK[*]}" "${STEPS_FAILED[*]}"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK[a c] FAILED[b]"* ]]
    [[ "$output" == *"step failed: b"* ]]
}

# The reason step calls "$@" directly instead of `if ( "$@" )`. A subshell
# would contain an exit from die -- and lose every global the step set on its
# way there. pkg_install_aur appends to PKG_FAILED and print_summary reads it,
# so under a subshell the "packages that failed to build" line silently goes
# empty on exactly the runs it exists for, while the step is still correctly
# reported as failed. Mutation-checked: with `if ( "$@" ); then` this case
# fails on the PKG_FAILED assertion and on nothing else.
@test "step preserves a global the step function sets" {
    run in_provision 'f(){ PKG_FAILED+=(brokenpkg); return 1; }
                      step aur f
                      printf "PKG_FAILED[%s] FAILED[%s]" "${PKG_FAILED[*]}" "${STEPS_FAILED[*]}"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"PKG_FAILED[brokenpkg]"* ]]
    [[ "$output" == *"FAILED[aur]"* ]]
}

# The property step's comment relies on, checked rather than asserted: walk the
# call graph out from every function provision.sh hands to step and confirm
# none of them can reach die (which exits the process) or confirm_step (which
# dies when you decline). If one ever can, step cannot catch it and the run
# dies mid-phase -- so this is the thing to know before adding a confirmation
# prompt to a setup_* function.
@test "no function reachable from a step can reach die or confirm_step" {
    source "${ARCH_SETUP}/lib/ui.sh"
    source "${ARCH_SETUP}/lib/packages.sh"
    source "${ARCH_SETUP}/lib/dotfiles.sh"
    source "${ARCH_SETUP}/lib/system.sh"
    source "${ARCH_SETUP}/lib/setup.sh"

    local -a seeds queue bad=()
    mapfile -t seeds < <(grep -oE '^[[:space:]]*step[[:space:]]+"[^"]+"[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
                         "$PROVISION" | grep -oE '[A-Za-z_][A-Za-z0-9_]*$' | sort -u)
    # If the extraction ever stopped matching, everything below would pass by
    # walking an empty graph.
    [ "${#seeds[@]}" -ge 10 ]

    local -A seen=()
    local f w body
    queue=("${seeds[@]}")
    while (( ${#queue[@]} )); do
        f=${queue[0]}; queue=("${queue[@]:1}")
        [[ -n "${seen[$f]:-}" ]] && continue
        seen[$f]=1
        declare -F "$f" >/dev/null || continue
        # declare -f strips comments, so a comment mentioning die cannot
        # trigger this and a real call cannot hide behind one.
        body=$(declare -f "$f")
        if grep -qE '(^|[^[:alnum:]_])(die|confirm_step)([[:space:];&|)]|$)' <<< "$body"; then
            bad+=("$f")
        fi
        while IFS= read -r w; do
            declare -F "$w" >/dev/null && queue+=("$w")
        done < <(grep -oE '[A-Za-z_][A-Za-z0-9_]*' <<< "$body" | sort -u)
    done

    # Well past the 12 seeds: the walk reaches info/warn/error/success and the
    # helpers the step functions call.
    [ "${#seen[@]}" -ge 20 ]
    [ "${#bad[@]}" -eq 0 ] || {
        echo "these step-reachable functions can reach die/confirm_step: ${bad[*]}" >&2
        return 1
    }
}

# --- log_path / open_log / prune_logs --------------------------------------

@test "log_path puts the log in HOME when HOME is writable" {
    run env HOME="$TMP" bash -c "source '${PROVISION}'; log_path"
    [ "$status" -eq 0 ]
    [[ "$output" == "${TMP}/arch-provision-"*".log" ]]
    [ -f "$output" ]
}

# tee is not a usable failure signal: with an unwritable path it prints one
# line and then goes on copying stdin to stdout until EOF, so `exec > >(tee -a
# "$LOG")` reports success, the run continues, and nothing is logged anywhere.
# Measured. log_path therefore probes the directory by creating the file.
@test "log_path falls back to TMPDIR when HOME is not writable" {
    mkdir -p "$TMP/ro" "$TMP/fallback"
    chmod 500 "$TMP/ro"
    run env HOME="$TMP/ro" TMPDIR="$TMP/fallback" bash -c "source '${PROVISION}'; log_path"
    [ "$status" -eq 0 ]
    [[ "$output" == "${TMP}/fallback/arch-provision-"*".log" ]]
}

@test "log_path fails when nothing is writable, and open_log says so instead of lying" {
    mkdir -p "$TMP/ro"
    chmod 500 "$TMP/ro"
    run env HOME="$TMP/ro" TMPDIR="$TMP/ro" bash -c "source '${PROVISION}'; log_path"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    run env HOME="$TMP/ro" TMPDIR="$TMP/ro" bash -c "source '${PROVISION}'; open_log; printf 'LOG[%s]' \"\$LOG\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"will not be logged"* ]]
    [[ "$output" == *"LOG[]"* ]]
    [[ "$output" != *"Logging to"* ]]
}

@test "prune_logs keeps the newest KEEP_LOGS and touches nothing else" {
    local i
    for i in $(seq -w 1 15); do
        touch "${TMP}/arch-provision-202601${i}-000000.log"
    done
    touch "${TMP}/arch-provision-notes.txt" "${TMP}/important.log"
    mkdir -p "${TMP}/arch-provision-adir.log"

    run env HOME="$TMP" bash -c "source '${PROVISION}'
                                 LOG='${TMP}/arch-provision-20260115-000000.log'
                                 prune_logs"
    [ "$status" -eq 0 ]
    [ "$(find "$TMP" -maxdepth 1 -type f -name 'arch-provision-*.log' | wc -l)" -eq 10 ]
    # The newest survive and the oldest are gone.
    [ -f "${TMP}/arch-provision-20260115-000000.log" ]
    [ -f "${TMP}/arch-provision-20260106-000000.log" ]
    [ ! -e "${TMP}/arch-provision-20260105-000000.log" ]
    # Everything that is not one of our logs is left completely alone.
    [ -f "${TMP}/arch-provision-notes.txt" ]
    [ -f "${TMP}/important.log" ]
    [ -d "${TMP}/arch-provision-adir.log" ]
}

# --- resolve_dotfiles_dir --------------------------------------------------
#
# lib/dotfiles.sh defaults DOTFILES_DIR to $HOME/.dotfiles at source time. Run
# a clone from anywhere else and dotfiles_clone would find no
# $HOME/.dotfiles/.git, clone a second copy from GitHub, and stow that --
# ignoring the tree you launched, silently, because both operations succeed.

@test "resolve_dotfiles_dir prefers the repository provision.sh lives in" {
    mkdir -p "$TMP/clone/.git" "$TMP/clone/dotfiles" "$TMP/clone/arch_setup"
    cp "$PROVISION" "$TMP/clone/arch_setup/provision.sh"
    cp -r "${ARCH_SETUP}/lib" "$TMP/clone/arch_setup/lib"
    run env HOME="$TMP" bash -c "source '$TMP/clone/arch_setup/provision.sh'
                                 resolve_dotfiles_dir; printf 'DIR[%s]' \"\$DOTFILES_DIR\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR[${TMP}/clone]"* ]]
}

@test "resolve_dotfiles_dir leaves an explicit DOTFILES_DIR alone" {
    mkdir -p "$TMP/clone/.git" "$TMP/clone/dotfiles" "$TMP/clone/arch_setup"
    cp "$PROVISION" "$TMP/clone/arch_setup/provision.sh"
    cp -r "${ARCH_SETUP}/lib" "$TMP/clone/arch_setup/lib"
    run env HOME="$TMP" DOTFILES_DIR="$TMP/chosen" \
        bash -c "source '$TMP/clone/arch_setup/provision.sh'
                 resolve_dotfiles_dir; printf 'DIR[%s]' \"\$DOTFILES_DIR\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR[${TMP}/chosen]"* ]]
}

# A directory that is not a dotfiles checkout must not be adopted: the default
# is still the right answer there.
@test "resolve_dotfiles_dir keeps the default when its own tree is not a checkout" {
    mkdir -p "$TMP/loose/arch_setup"
    cp "$PROVISION" "$TMP/loose/arch_setup/provision.sh"
    cp -r "${ARCH_SETUP}/lib" "$TMP/loose/arch_setup/lib"
    run env HOME="$TMP" bash -c "source '$TMP/loose/arch_setup/provision.sh'
                                 resolve_dotfiles_dir; printf 'DIR[%s]' \"\$DOTFILES_DIR\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR[${TMP}/.dotfiles]"* ]]
}

# --- print_summary ---------------------------------------------------------

@test "print_summary survives set -u with nothing recorded, and returns 0" {
    run in_provision 'print_summary; printf "RC[%d]" "$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Summary"* ]]
    [[ "$output" == *"RC[0]"* ]]
    [[ "$output" != *"unbound variable"* ]]
}

@test "print_summary prints once however many times it is called" {
    run in_provision 'step a true; print_summary; print_summary'
    [ "$status" -eq 0 ]
    [ "$(grep -c 'Summary' <<< "$output")" -eq 1 ]
}

@test "print_summary names the packages that failed to build" {
    run in_provision 'PKG_FAILED=(alpha beta); LOG=/tmp/x.log; print_summary'
    [ "$status" -eq 0 ]
    [[ "$output" == *"packages that failed to build: alpha beta"* ]]
    [[ "$output" == *"Full log: /tmp/x.log"* ]]
}

# --- main, with every machine-touching call stubbed ------------------------
#
# The only way to pin the phase ordering and the skip branches. sudo, the log
# redirect and every step function are replaced, so this runs the control flow
# and nothing else. HOME is $BATS_TEST_TMPDIR throughout.

# stub_main <extra shell code> -- everything provision.sh's main would touch,
# replaced with a recorder. Defined after the source so it wins.
stubbed_main() {
    local extra=${1:-} args=${2:-}
    HOME="$TMP" bash -c "
        source '${PROVISION}'
        sudo(){ :; }
        open_log(){ LOG=''; }
        resolve_dotfiles_dir(){ :; }
        dotfiles_clone(){ :; }
        stow_apply(){ :; }
        ensure_yay(){ :; }
        pkg_install_repo(){ :; }
        pkg_install_aur(){ :; }
        setup_zsh_dirs(){ :; }
        setup_shell(){ :; }
        setup_xkb(){ :; }
        setup_lightdm(){ :; }
        setup_zram(){ :; }
        enable_services(){ :; }
        detect_gpu(){ echo nvidia; }
        setup_gpu(){ echo \"SETUP_GPU_CALLED[\$1]\"; }
        ${extra}
        main ${args}
    " </dev/null
}

@test "a clean non-interactive run reaches every phase and exits 0" {
    run stubbed_main
    [ "$status" -eq 0 ]
    local n
    for n in 1 2 3 4 5 6 7 8; do
        [[ "$output" == *"[${n}/8]"* ]] || {
            echo "phase ${n} never ran" >&2; return 1
        }
    done
    [[ "$output" == *"Provisioning complete"* ]]
}

# ask now fails at EOF, so without the -t 0 branch `choice=$(ask ...)` aborts
# the whole run under errexit one phase short of the services -- and with a
# default instead it would rebuild the initramfs and grub.cfg for a driver
# nobody chose. Neither is acceptable for a script that has to be re-runnable
# from cron or `ssh -n`.
@test "the graphics phase does not run, or abort the run, without a terminal" {
    run stubbed_main
    [ "$status" -eq 0 ]
    [[ "$output" != *"SETUP_GPU_CALLED"* ]]
    [[ "$output" == *"no terminal here to confirm the driver"* ]]
    [[ "$output" != *"end of input"* ]]
    # ...and the phases after it still ran.
    [[ "$output" == *"[8/8]"* ]]
    [[ "$output" == *"Provisioning complete"* ]]
}

@test "--skip-gpu and --skip-packages skip their phases and nothing else" {
    run stubbed_main '' '--skip-gpu --skip-packages'
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping (--skip-gpu)"* ]]
    [ "$(grep -c 'skipping (--skip-packages)' <<< "$output")" -eq 2 ]
    [[ "$output" != *"SETUP_GPU_CALLED"* ]]
    [[ "$output" == *"Provisioning complete"* ]]
}

@test "--help prints the usage and runs no phase" {
    run stubbed_main '' '--help'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: provision.sh"* ]]
    [[ "$output" != *"[1/8]"* ]]
    [[ "$output" != *"Summary"* ]]
}

# One failed step must not stop the other seven, and must still make the whole
# run exit non-zero -- the two halves of what step exists for.
@test "a failed step is reported, does not stop the run, and makes it exit 1" {
    run stubbed_main 'setup_xkb(){ return 1; }'
    [ "$status" -eq 1 ]
    [[ "$output" == *"step failed: xkb"* ]]
    [[ "$output" == *"[8/8]"* ]]
    [[ "$output" == *"1 step(s) failed"* ]]
    [[ "$output" != *"Provisioning complete"* ]]
}

# The end-to-end version of the step/PKG_FAILED case above: a package that
# failed to build has to survive from inside pkg_install_aur all the way to the
# summary. Under `if ( "$@" )` the step is still reported red and this line
# goes silently empty.
@test "a package that failed to build reaches the summary by name" {
    run stubbed_main 'pkg_install_aur(){ PKG_FAILED+=(nvidia-broken); return 1; }'
    [ "$status" -eq 1 ]
    [[ "$output" == *"packages that failed to build: nvidia-broken"* ]]
    [[ "$output" == *"step failed: aur-packages"* ]]
}

# What actually happens if a step ever does reach a die: the process is gone
# before step regains control. The EXIT trap is why that leaves a partial
# report rather than silence between the last banner and nothing. The
# reachability test above is what keeps this hypothetical.
@test "an exit from inside a step still prints a summary, from the EXIT trap" {
    run stubbed_main 'setup_xkb(){ die "declined"; }'
    [ "$status" -eq 1 ]
    [[ "$output" == *"declined"* ]]
    [[ "$output" == *"Summary"* ]]
    # Everything before the die is reported...
    [[ "$output" == *"zsh-dirs"* ]]
    # ...and it is honest about having stopped there.
    [[ "$output" != *"[7/8]"* ]]
    [[ "$output" != *"Provisioning complete"* ]]
}
