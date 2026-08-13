#!/usr/bin/env bats
#
# lib/setup.sh -- the sudo-requiring, stage-2-only half of what used to be
# lib/system.sh. Split out of test/system.bats along with the code.
#
# Almost nothing here can be exercised for real: every function runs sudo
# against /etc, systemd or the bootloader. What is testable is the branch each
# one takes *before* it reaches sudo, plus enable_services' aggregation, which
# is pure control flow over a stubbed systemctl.
#
# What IS exercisable for real, and is the bulk of this file, is what each
# function returns when a sudo command fails -- see "the errexit property"
# below for why that needs pinning and why it cannot be pinned with `run`.

load helpers

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/system.sh"
    source "${BATS_TEST_DIRNAME}/../lib/setup.sh"
    TMP="$BATS_TEST_TMPDIR"
}

# --- subsystem setup -------------------------------------------------------

# Machine-independent: assert on whichever branch this host lands in, so the
# test does not silently depend on the developer's own login shell.
@test "setup_shell --check-only reports without changing anything" {
    run setup_shell --check-only
    [ "$status" -eq 0 ]
    if [ "$(getent passwd "$USER" | cut -d: -f7)" = "/usr/bin/zsh" ]; then
        [[ "$output" == *"already"* ]]
    else
        [[ "$output" == *"would chsh"* ]]
    fi
}

@test "setup_shell fails when the target user cannot be determined" {
    USER="" SUDO_USER="" run setup_shell --check-only
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot determine the target user"* ]]
}

# --- the errexit property --------------------------------------------------
#
# provision.sh runs every phase as `step "name" <fn>`, and step is
# `if "$@"; then ... fi`. Bash suspends errexit for the WHOLE DYNAMIC EXTENT of
# a condition context -- the callee, everything it calls, and the subshells it
# spawns -- so provision.sh's own `set -e` is not in force inside any function
# below. Measured on bash 5.3: an explicit `set -e` in the function does not
# restore it, and neither does wrapping the body in `( set -e; ... )`. The only
# remedy is that each function checks its own commands, which step's comment
# states as a requirement -- and which four of these functions did not do. They
# ran `sudo install` / `sudo mkinitcpio` / `mkdir` unchecked and ended on an
# unconditional `success`, so the step landed in STEPS_OK, the summary came out
# fully green, and the run finished on "Reboot to land in lightdm" with no
# lightdm drop-in, no zram config, and -- worst -- an initramfs and a grub.cfg
# that were never regenerated for the driver /etc had just been configured for.
#
# These cases go through provision.sh's real step() rather than a copy, in a
# shell that has sourced provision.sh and so runs under its `set -euo
# pipefail`. NOT `run step ...`: bats' own `run` turns errexit off inside the
# run, which is the setting under test.

# run_step <fn> [arg]... -- echo step's verdict plus everything <fn> printed.
run_step() {
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
        bash -c 'source "$1"; shift
                 step probe "$@"
                 printf "OK[%s] FAILED[%s]\n" "${STEPS_OK[*]}" "${STEPS_FAILED[*]}"' \
        _ "${BATS_TEST_DIRNAME}/../provision.sh" "$@" 2>&1
}

# The tree these functions expect to find, built before any stub is on PATH --
# setup_xkb returns 0 without doing anything if install.sh is not there, and
# would pass every case below while testing nothing.
fake_home() {
    mkdir -p "$TMP/home/.config/xkb" "$TMP/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/home/.config/xkb/install.sh"
    chmod +x "$TMP/home/.config/xkb/install.sh"
}

# Every command the setup_* family reaches for that actually DOES something,
# stubbed to fail. `sudo` failing covers every `sudo <x>` in one go, so the
# rest of this list is the handful that run without it.
stub_actions_failing() {
    local t
    for t in sudo mkdir touch; do
        printf '#!/bin/sh\necho "stub: %s $* -> failing" >&2\nexit 1\n' "$t" > "$TMP/bin/$t"
    done
    # Deliberately NOT failing: setup_shell reads the target's *current* shell
    # before it decides to act, and the real getent would answer with the
    # developer's own, so this would take a different branch on a machine that
    # already runs zsh. The unreadable-passwd case has its own test.
    printf '#!/bin/sh\necho "u:x:1000:1000::/home/u:/bin/bash"\n' > "$TMP/bin/getent"
    # Also deliberately not failing: enable_services SKIPS a unit it cannot
    # find, and skipping is correct, so the unit has to exist for the enable to
    # be the thing that fails.
    printf '#!/bin/sh\n[ "$1" = list-unit-files ] && { echo "$2 disabled preset"; exit 0; }\nexit 1\n' \
        > "$TMP/bin/systemctl"
    chmod +x "$TMP"/bin/*
}

# The arguments each step callee needs to get past its own early returns. A
# function with no entry here fails the case rather than being run bare:
# `setup_gpu` with no argument returns 0 at "no GPU driver selected" and would
# pass while testing nothing. `amd` is the plain path -- one pacman call --
# which is where the unchecked-pacman shape shows; the nvidia tail, which is
# the one that ends in an initramfs, has its own cases below.
step_args() {
    case $1 in
        setup_zram|setup_xkb|setup_lightdm|setup_shell|setup_zsh_dirs) echo "" ;;
        setup_gpu)       echo "amd" ;;
        enable_services) echo "alpha" ;;
        *) return 1 ;;
    esac
}

# Data-driven off provision.sh and lib/setup.sh, not off a hand-written list:
# a setup_* added later is covered the moment it is wired to a step, without
# anyone having to remember this file exists.
@test "every step callee in lib/setup.sh reports failure when its commands fail" {
    fake_home
    stub_actions_failing

    local -a callees=() bad=()
    local fn args out
    while IFS= read -r fn; do
        if grep -qE "^[[:space:]]*step[[:space:]]+\"[^\"]+\"[[:space:]]+${fn}([[:space:]]|\$)" \
               "${BATS_TEST_DIRNAME}/../provision.sh"; then
            callees+=("$fn")
        fi
    done < <(grep -oE '^[a-z_][a-z0-9_]*\(\)' "${BATS_TEST_DIRNAME}/../lib/setup.sh" | tr -d '()')
    # If either extraction ever stopped matching, everything below would pass
    # by iterating an empty list.
    [ "${#callees[@]}" -ge 6 ]

    for fn in "${callees[@]}"; do
        if ! args=$(step_args "$fn"); then
            echo "step_args has no entry for ${fn} -- add one, do not run it bare" >&2
            return 1
        fi
        # Unquoted on purpose: an entry may carry more than one word.
        # shellcheck disable=SC2086
        out=$(run_step "$fn" $args)
        [[ "$out" == *"FAILED[probe]"* ]] || bad+=("${fn} -> ${out}")
    done
    [ "${#bad[@]}" -eq 0 ] || { printf '%s\n' "${bad[@]}" >&2; return 1; }
}

# The nvidia tail, which the case above cannot reach: with sudo failing
# outright, setup_gpu already returns non-zero at grub_cmdline_add. The
# interesting failure is the one where everything BEFORE succeeds -- so
# /etc/mkinitcpio.conf has been rewritten with the nvidia modules and
# /etc/default/grub with nvidia-drm.modeset=1 -- and only the regeneration
# fails. That leaves a machine configured for a driver whose initramfs and
# grub.cfg do not know about it, which is the single outcome provision.sh's
# graphics phase calls out as the one that does not boot.
#
# stub_gpu <sh-case-pattern of commands sudo should fail>
# Nothing runs for real: the sudo stub records and returns without exec'ing, so
# `sudo sed -i`, `sudo install` and the `sudo bash -c grub_cmdline_add` never
# reach /etc.
stub_gpu() {
    local failing=$1
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/sudo" <<EOF
#!/bin/sh
echo "sudo \$*" >> "${TMP}/sudo_args"
case "\$1" in ${failing}) exit 1 ;; esac
exit 0
EOF
    # setup_gpu reads the host's real /etc/mkinitcpio.conf for its MODULES
    # line. Answering for that one file is what keeps this case off the
    # developer's machine; every other call is the real grep.
    cat > "$TMP/bin/grep" <<EOF
#!/bin/sh
case "\$*" in
  *'^MODULES='*'/etc/mkinitcpio.conf') echo 'MODULES=()'; exit 0 ;;
esac
exec $(command -v grep) "\$@"
EOF
    chmod +x "$TMP/bin/sudo" "$TMP/bin/grep"
    : > "$TMP/sudo_args"
}

@test "setup_gpu fails when mkinitcpio cannot rebuild the initramfs" {
    fake_home
    stub_gpu mkinitcpio
    local out
    out=$(run_step setup_gpu nvidia)
    [[ "$out" == *"FAILED[probe]"* ]]
    [[ "$out" == *"mkinitcpio"* ]]
    [[ "$out" != *"GPU driver configured"* ]]
}

@test "setup_gpu fails when grub.cfg cannot be regenerated" {
    fake_home
    stub_gpu grub-mkconfig
    local out
    out=$(run_step setup_gpu nvidia)
    [[ "$out" == *"FAILED[probe]"* ]]
    [[ "$out" != *"GPU driver configured"* ]]
    # ...and it got that far, i.e. the initramfs rebuild is not what failed.
    grep -qF 'sudo mkinitcpio -P' "$TMP/sudo_args"
}

# The case above cannot see this one: setup_zsh_dirs ended on a `mkdir`, so
# with everything failing it returned that mkdir's non-zero status and looked
# correct. The defect is the command in the MIDDLE. .zshrc needs the history
# file to exist before the first interactive shell, and a touch that failed on
# its own was the one failure the function could not report.
@test "setup_zsh_dirs fails when only the history file cannot be created" {
    fake_home
    printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/touch"
    chmod +x "$TMP/bin/touch"
    local out
    out=$(run_step setup_zsh_dirs)
    [[ "$out" == *"FAILED[probe]"* ]]
    [[ "$out" == *"history"* ]]
}

# `current` is read, not written, so the unchecked form does not look
# dangerous -- but an unread `current` is empty, empty is not "/usr/bin/zsh",
# and "I cannot tell what the login shell is" therefore became "the login shell
# is wrong, change it". chsh SUCCEEDS in this case on purpose: the assertion is
# that it is never reached.
@test "setup_shell fails when the current login shell cannot be read" {
    fake_home
    printf '#!/bin/sh\nexit 2\n' > "$TMP/bin/getent"
    printf '#!/bin/sh\necho "sudo $*" >> "%s/sudo_args"\nexit 0\n' "$TMP" > "$TMP/bin/sudo"
    chmod +x "$TMP/bin/getent" "$TMP/bin/sudo"
    : > "$TMP/sudo_args"

    local out
    out=$(run_step setup_shell)
    [[ "$out" == *"FAILED[probe]"* ]]
    [[ "$out" != *"login shell set"* ]]
    assert_absent 'chsh' "$TMP/sudo_args"
}

# --- enable_services -------------------------------------------------------
#
# systemctl and sudo are both stubbed on PATH. sudo must be: the real one would
# ask for a password nobody can type and then genuinely enable units on the
# developer's machine.

# stub_systemd <units that exist> <units whose enable fails> [extra list-unit-files output lines]
stub_systemd() {
    local exists=$1 fails=$2 noise=${3:-0}
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/systemctl" <<EOF
#!/bin/sh
case "\$1" in
  list-unit-files)
      i=0
      while [ "\$i" -lt $noise ]; do echo "filler-\$i.service disabled"; i=\$((i + 1)); done
      for u in $exists; do
          [ "\$2" = "\${u}.service" ] && { echo "\$2 disabled preset"; exit 0; }
      done
      exit 0 ;;
  enable)
      echo "\$2" >> "$TMP/enabled"
      for u in $fails; do [ "\$2" = "\$u" ] && exit 1; done
      exit 0 ;;
esac
exit 0
EOF
    printf '#!/bin/sh\nexec "$@"\n' > "$TMP/bin/sudo"
    chmod +x "$TMP/bin/systemctl" "$TMP/bin/sudo"
}

@test "enable_services succeeds when every unit enables" {
    stub_systemd "alpha beta" "__none__"
    PATH="$TMP/bin:$PATH" run enable_services alpha beta
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled alpha"* ]]
    [[ "$output" == *"enabled beta"* ]]
}

# The defect this replaced: the function returned the LAST iteration's status,
# so `enable_services NetworkManager lightdm docker bluetooth cups` could fail
# to enable NetworkManager -- no network on the next boot -- and still hand
# provision.sh a 0 because cups happened to be fine.
@test "enable_services fails on the first unit even when the last one succeeds" {
    stub_systemd "alpha beta gamma" "alpha"
    PATH="$TMP/bin:$PATH" run enable_services alpha beta gamma
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to enable alpha"* ]]
    [[ "$output" == *"1 of 3"* ]]
    # ...and it did not stop at the failure.
    [[ "$output" == *"enabled gamma"* ]]
}

@test "enable_services counts every failure, not just one" {
    stub_systemd "alpha beta gamma" "alpha gamma"
    PATH="$TMP/bin:$PATH" run enable_services alpha beta gamma
    [ "$status" -ne 0 ]
    [[ "$output" == *"2 of 3"* ]]
}

# The numerator excludes units that were not installed, by design, so the
# denominator has to as well. The real call is
# `enable_services NetworkManager lightdm docker bluetooth cups`, and on a
# --skip-packages machine three of those five are legitimately absent -- so
# counting against $# turned "every unit that exists failed" into "1 of 5",
# which reads like a 20% problem and is a 100% one.
@test "enable_services counts against the units that existed, not the ones asked for" {
    stub_systemd "alpha" "alpha"
    PATH="$TMP/bin:$PATH" run enable_services alpha docker bluetooth cups
    [ "$status" -ne 0 ]
    [[ "$output" == *"1 of 1"* ]]
}

# Not a failure, deliberately: provision.sh asks for docker, bluetooth and cups
# on every run, and a machine provisioned with --skip-packages, or one whose
# operator declined the optional group, legitimately has none of them. A red
# summary on a run where nothing went wrong trains people to ignore it.
@test "enable_services skips a unit that is not installed without failing" {
    stub_systemd "alpha" "__none__"
    PATH="$TMP/bin:$PATH" run enable_services alpha cups
    [ "$status" -eq 0 ]
    [[ "$output" == *"cups.service not found"* ]]
    [[ "$output" == *"enabled alpha"* ]]
    # and it never tried
    assert_absent '^cups$' "$TMP/enabled"
}

# A guard against a refactor, not a regression test: enable_services has never
# been written as a pipe -- every version back to its introduction used a
# command substitution -- so nothing here is being re-fixed. What this pins is
# that nobody tidies the probe into the obvious shorter form.
#
# `systemctl list-unit-files "${svc}.service" --no-legend | grep -q .` reports
# 141 for a unit that DOES exist, once the output outgrows the pipe buffer:
# grep -q closes the pipe on its first hit, systemctl takes SIGPIPE, and
# provision.sh's `set -o pipefail` surfaces it. Under 64 KB it behaves
# perfectly, which is why it would survive review -- the same trap
# test/install.bats documents for keymap_listed, where the thresholds were
# measured. Capturing the output has no pipe and no threshold.
#
# Checked by mutation rather than assumed: with the probe rewritten to that
# pipe, this case fails on the "enabled alpha" assertion -- the existing unit
# is reported as absent and silently skipped -- and every other case in this
# file still passes, so this is the only thing standing in front of it.
@test "enable_services does not depend on systemctl's output fitting in a pipe" {
    stub_systemd "alpha" "__none__" 20000
    run bash -c "set -euo pipefail
                 source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
                 source '${BATS_TEST_DIRNAME}/../lib/system.sh'
                 source '${BATS_TEST_DIRNAME}/../lib/setup.sh'
                 export PATH=\"${TMP}/bin:\$PATH\"
                 enable_services alpha
                 echo RC[\$?]"
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled alpha"* ]]
    [[ "$output" == *"RC[0]"* ]]
}
