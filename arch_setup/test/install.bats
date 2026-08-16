#!/usr/bin/env bats
#
# install.sh is an orchestrator: prompts, ordering and destructive commands.
# Most of it cannot be tested without a disk, and nothing here pretends
# otherwise. What is testable is everything pulled out of the prompt loops into
# named predicates, plus the structural facts that keep the file safe to
# source.
#
# One case does call a phase_* function: "phase_disk never reaches
# plan_execute on a closed stdin". It runs with DRY_RUN=true and with
# plan_execute stubbed, so the assertion is about where control gets to, not
# about anything being written. No other case calls a phase.

load helpers

setup() {
    ARCH_SETUP="${BATS_TEST_DIRNAME}/.."
    INSTALL_SH="${ARCH_SETUP}/install.sh"
    TMP="$BATS_TEST_TMPDIR"
}

# install.sh is sourced, never executed: executing it partitions a disk. Each
# case gets its own shell because install.sh runs under `set -euo pipefail`
# and bats' own `run` turns errexit *off* inside the run -- so `run
# valid_username root` could not show how the predicate behaves in the
# settings install.sh actually uses. Here the failing predicate is the last
# command of a `set -e` shell, so `status` is the predicate's own.
in_install() {
    bash -c "source '${INSTALL_SH}'; $*"
}

# --- structure -------------------------------------------------------------

@test "install.sh parses" {
    run bash -n "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# The `if [[ "${BASH_SOURCE[0]}" == "$0" ]]` guard at the bottom is what makes
# every other test in this file safe. Without it, sourcing install.sh parses
# flags, arms an EXIT trap that runs `umount -R /mnt`, and enters phase 1.
#
# Named for exactly what it guarantees and no more. Sourcing is NOT free of
# side effects: it also turns on `set -euo pipefail` in the sourcing shell
# (measured: SHELLOPTS goes from "hBc" to "ehuBc"). That is harmless here
# because in_install uses a `bash -c` subshell per case, but it means
# `load install` from a bats file would change how every later assertion
# behaves. Source it in a subshell, not into the test process.
@test "sourcing install.sh runs no phase and arms no EXIT trap" {
    run bash -c "source '${INSTALL_SH}'; printf 'TRAP[%s]' \"\$(trap -p EXIT)\""
    [ "$status" -eq 0 ]
    [ "$output" = "TRAP[]" ]
}

# lib/disk.sh's dry-run wrapper is `run_cmd`, not `run`, because a shell
# function named `run` clobbers bats' own test helper. A caller that still
# writes `run pacstrap ...` gets an unknown command under `set -e` -- the
# destructive commands are exactly the ones that would fail.
@test "install.sh calls run_cmd, never a bare 'run'" {
    assert_absent '(^|[;&|][[:space:]]*)[[:space:]]*run[[:space:]]+[a-z]' "$INSTALL_SH"
}

# The header's three lines are the only instructions an operator has at a bare
# console on the live ISO, so they have to work as typed. Two ways they did
# not: `guidiamond/.dotfiles` does not exist (it 404s for the owner's own
# token -- the local *directory* is .dotfiles, the repository is not), and a
# `git clone <url>` with no destination names the new directory after the
# *repository*, so with the real name it would create GArch/ and the very next
# line's `cd .dotfiles/arch_setup` would fail. The explicit destination is
# what keeps the two lines consistent.
@test "install.sh's bootstrap clones a real repo into the directory the next line enters" {
    assert_absent 'guidiamond/\.dotfiles' "$INSTALL_SH"
    grep -qF 'git clone https://github.com/guidiamond/GArch.git .dotfiles' "$INSTALL_SH"
    grep -qF 'cd .dotfiles/arch_setup' "$INSTALL_SH"
}

# The same collision class, one level up: bats owns these names, and install.sh
# is a file test/install.bats sources.
@test "install.sh defines no function whose name bats reserves" {
    local reserved name
    for name in run setup teardown load skip; do
        reserved=$(grep -cE "^${name}\(\)" "$INSTALL_SH" || true)
        [ "$reserved" -eq 0 ] || {
            echo "install.sh defines ${name}(), which bats also defines" >&2
            return 1
        }
    done
}

# The generated chroot script hardcodes the two paths it sources and deletes:
# /root/chroot_config.sh (which holds both passwords, removed on every exit
# path) and /root/chroot_setup.sh. Any other basename under /mnt/root and the
# chroot cannot find its config and never deletes the passwords.
@test "install.sh writes the two chroot files under the hardcoded basenames" {
    grep -qF 'chroot_write_config /mnt/root/chroot_config.sh' "$INSTALL_SH"
    grep -qF 'chroot_write_script /mnt/root/chroot_setup.sh' "$INSTALL_SH"
    grep -qF 'arch-chroot /mnt /root/chroot_setup.sh' "$INSTALL_SH"
}

# --- config_safe -----------------------------------------------------------

@test "config_safe rejects every character chroot_write_config refuses" {
    run in_install 'config_safe "a\"b"';   [ "$status" -ne 0 ]
    run in_install 'config_safe "a\`b"';   [ "$status" -ne 0 ]
    run in_install 'config_safe "a\$b"';   [ "$status" -ne 0 ]
    run in_install 'config_safe "a\\\\b"'; [ "$status" -ne 0 ]
    run in_install "config_safe \$'a\nb'"; [ "$status" -ne 0 ]
}

@test "config_safe accepts the values the defaults actually produce" {
    run in_install 'config_safe "en_US.UTF-8"';      [ "$status" -eq 0 ]
    run in_install 'config_safe "America/Sao_Paulo"'; [ "$status" -eq 0 ]
    run in_install 'config_safe "us"';               [ "$status" -eq 0 ]
    run in_install 'config_safe ""';                 [ "$status" -eq 0 ]
}

# --- valid_hostname --------------------------------------------------------

@test "valid_hostname accepts a plain label" {
    run in_install 'valid_hostname archlinux'; [ "$status" -eq 0 ]
    run in_install 'valid_hostname a';         [ "$status" -eq 0 ]
    run in_install 'valid_hostname a-b-9';     [ "$status" -eq 0 ]
}

@test "valid_hostname rejects the malformed shapes" {
    run in_install 'valid_hostname ""';       [ "$status" -ne 0 ]
    run in_install 'valid_hostname -lead';    [ "$status" -ne 0 ]
    run in_install 'valid_hostname trail-';   [ "$status" -ne 0 ]
    run in_install 'valid_hostname "a b"';    [ "$status" -ne 0 ]
    run in_install 'valid_hostname under_score'; [ "$status" -ne 0 ]
}

@test "valid_hostname rejects a 64-character label but accepts 63" {
    run in_install 'valid_hostname "$(printf a%.0s {1..63})"'; [ "$status" -eq 0 ]
    run in_install 'valid_hostname "$(printf a%.0s {1..64})"'; [ "$status" -ne 0 ]
}

# --- valid_username --------------------------------------------------------

# The whole reason this predicate exists. ^[a-z][a-z0-9_-]*$ -- the regex the
# first draft used -- accepts every one of these, and lib/chroot.sh's uid<1000
# guard only catches them inside the chroot, after pacstrap.
@test "valid_username rejects the system accounts a bare regex admits" {
    local name
    for name in root bin daemon mail ftp http nobody dbus; do
        run in_install "valid_username ${name}"
        [ "$status" -ne 0 ] || {
            echo "valid_username accepted the system account '${name}'" >&2
            return 1
        }
    done
}

@test "valid_username accepts an ordinary login name" {
    run in_install 'valid_username damn';    [ "$status" -eq 0 ]
    run in_install 'valid_username a';       [ "$status" -eq 0 ]
    run in_install 'valid_username _svc';    [ "$status" -eq 0 ]
    run in_install 'valid_username gui-9_x'; [ "$status" -eq 0 ]
}

@test "valid_username rejects what useradd itself would reject" {
    run in_install 'valid_username ""';      [ "$status" -ne 0 ]
    run in_install 'valid_username 1abc';    [ "$status" -ne 0 ]
    run in_install 'valid_username Damn';    [ "$status" -ne 0 ]
    run in_install 'valid_username "a b"';   [ "$status" -ne 0 ]
    run in_install 'valid_username "$(printf a%.0s {1..32})"'; [ "$status" -eq 0 ]
    run in_install 'valid_username "$(printf a%.0s {1..33})"'; [ "$status" -ne 0 ]
}

# The hardcoded list cannot stay complete, so the live passwd database is
# consulted too. root is uid 0 on every host this could ever run on.
@test "username_is_system flags root and ignores a name that exists nowhere" {
    run in_install 'username_is_system root'
    [ "$status" -eq 0 ]
    run in_install 'username_is_system no_such_user_a7f3c1'
    [ "$status" -ne 0 ]
}

# --- keymap_listed ---------------------------------------------------------
#
# keymap_listed stays in install.sh while list_keymaps lives in lib/system.sh.
# The rule is the one lib/system.sh:167-171 states: a predicate lives next to
# the writer it has to agree with, and where there is no such writer it is
# prompt flow. locale_listed has one -- locale_gen_uncomment, which it must
# match character for character -- so it moved. keymap_listed has none; nothing
# later re-derives "is this a real keymap", so a disagreement is impossible.
# Its 0/1/2 contract is what phase_locale branches on, so it is tested here
# against a stubbed list.

@test "keymap_listed matches a whole line only" {
    run in_install 'list_keymaps() { printf "%s\n" us br-abnt2 uk; }; keymap_listed us'
    [ "$status" -eq 0 ]
    run in_install 'list_keymaps() { printf "%s\n" us br-abnt2 uk; }; keymap_listed u'
    [ "$status" -eq 1 ]
    run in_install 'list_keymaps() { printf "%s\n" us br-abnt2 uk; }; keymap_listed br'
    [ "$status" -eq 1 ]
}

# Written as `printf ... | grep -q` this reports 141 for a *successful* match:
# grep -q closes the pipe on its first hit, printf takes SIGPIPE, and
# `set -o pipefail` surfaces it. It only bites once the list outgrows the pipe
# buffer, measured on this host at 5000 lines / 24 KB passing and 20000 lines /
# 108 KB returning 141 -- against a real `localectl list-keymaps` of 252
# entries and 2.5 KB. So a pipe would work today and break silently the day the
# list grew past 64 KB. The here-string has no pipe and no threshold; the size
# below is what it takes to make that difference observable at all.
@test "keymap_listed does not depend on the keymap list fitting in a pipe" {
    run in_install 'list_keymaps() { printf "%s\n" br-abnt2; seq 1 20000; }; keymap_listed br-abnt2'
    [ "$status" -eq 0 ]
    run in_install 'list_keymaps() { seq 1 20000; printf "%s\n" br-abnt2; }; keymap_listed br-abnt2'
    [ "$status" -eq 0 ]
}

@test "keymap_listed says 'cannot answer' when no keymap list can be built" {
    run in_install 'list_keymaps() { return 1; }; keymap_listed us'
    [ "$status" -eq 2 ]
    run in_install 'list_keymaps() { printf "%s\n" us; }; keymap_listed ""'
    [ "$status" -eq 1 ]
}

# --- valid_size ------------------------------------------------------------

# Delegated to size_to_sgdisk rather than re-written, so the prompt and
# plan_add can never disagree about what a size is.
@test "valid_size agrees with lib/disk.sh's size_to_sgdisk" {
    run in_install 'valid_size 2G';    [ "$status" -eq 0 ]
    run in_install 'valid_size 512M';  [ "$status" -eq 0 ]
    run in_install 'valid_size rest';  [ "$status" -eq 0 ]
    run in_install 'valid_size 2GB';   [ "$status" -ne 0 ]
    run in_install 'valid_size 2g';    [ "$status" -ne 0 ]
    run in_install 'valid_size ""';    [ "$status" -ne 0 ]
}

# valid_size must stay silent: it runs inside a re-ask loop, and
# size_to_sgdisk's own error() would print an unexplained second complaint
# above the prompt's.
@test "valid_size prints nothing when it rejects" {
    run in_install 'valid_size 2GB'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# --- the contract with lib/chroot.sh ---------------------------------------

# Sets every value phase_locale and phase_chroot would have collected, so
# chroot_config_args can be called without running a phase.
# No trailing separator: callers append either "; more" or a newline, and a
# trailing ';' here turns the first of those into a ';;' syntax error.
with_answers() {
    printf '%s' "HOSTNAME_VAR=archlinux; USERNAME_VAR=damn; TIMEZONE=America/Sao_Paulo;
                 LOCALE=en_US.UTF-8; KEYMAP=us; LUKS_ENABLED=${1:-true}; LUKS_UUID='${2-abc-123}'"
}

@test "chroot_config_args emits exactly the keys the generated script requires" {
    local script="${TMP}/chroot_setup.sh"
    bash -c "source '${ARCH_SETUP}/lib/ui.sh'
             source '${ARCH_SETUP}/lib/system.sh'
             source '${ARCH_SETUP}/lib/chroot.sh'
             chroot_write_script '${script}'"
    [ -f "$script" ]

    # Join the `\`-continued require_vars call, then take the names off both
    # invocations (the unconditional one and the LUKS_UUID one).
    local required
    required=$(sed -e ':a' -e '/\\$/{N;s/\\\n[[:space:]]*/ /;ba' -e '}' "$script" \
               | grep -oE 'require_vars[[:space:]]+[A-Z][A-Z0-9_[:space:]]*' \
               | sed -E 's/^require_vars[[:space:]]+//' \
               | tr ' ' '\n' | grep -E '^[A-Z][A-Z0-9_]*$' | sort -u)
    # If the extraction silently stopped matching, this test would pass by
    # comparing two empty sets.
    [ "$(printf '%s\n' "$required" | grep -c .)" -eq 9 ]

    local written
    written=$(in_install "$(with_answers); chroot_config_args AAAA BBBB" | cut -d= -f1 | sort)
    [ "$written" = "$required" ]
}

# LUKS_ENABLED must be the literal string, and it is the literal string on both
# branches: lib/disk.sh initialises it to false and only luks_open sets true.
# "yes", "1" or "True" all abort the generated script's preflight, and
# hooks_line tests for exactly "true" -- a near miss is an initramfs with no
# encrypt hook and a root that cannot be unlocked.
@test "chroot_config_args carries LUKS_ENABLED as a literal true or false" {
    run in_install "$(with_answers true); chroot_config_args A B"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LUKS_ENABLED=true"* ]]

    run in_install "$(with_answers false ''); chroot_config_args A B"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LUKS_ENABLED=false"* ]]
    # Empty is correct and accepted: the generated script only requires
    # LUKS_UUID when LUKS_ENABLED is true.
    [[ "$output" == *"LUKS_UUID="* ]]
}

@test "chroot_write_config accepts what chroot_config_args produces, LUKS on and off" {
    run in_install "$(with_answers true)
                    chroot_config_array a A B
                    chroot_write_config '${TMP}/on.sh' \"\${a[@]}\""
    [ "$status" -eq 0 ]
    grep -qx 'LUKS_ENABLED="true"' "${TMP}/on.sh"
    grep -qx 'LUKS_UUID="abc-123"' "${TMP}/on.sh"

    run in_install "$(with_answers false '')
                    chroot_config_array a A B
                    chroot_write_config '${TMP}/off.sh' \"\${a[@]}\""
    [ "$status" -eq 0 ]
    grep -qx 'LUKS_ENABLED="false"' "${TMP}/off.sh"
    grep -qx 'LUKS_UUID=""' "${TMP}/off.sh"
}

# The backstop this file's prompt-time validation exists to keep out of reach.
# It is a phase-5 abort: by the time it fires the disk is wiped and the base
# system is installed, which is why config_safe runs at the prompt instead.
@test "chroot_write_config still refuses a locale phase_locale would re-ask for" {
    run in_install "$(with_answers true); LOCALE='en_US\$(id).UTF-8'
                    chroot_config_array a A B
                    chroot_write_config '${TMP}/bad.sh' \"\${a[@]}\""
    [ "$status" -ne 0 ]
    [[ "$output" == *"LOCALE"* ]]
    [ ! -e "${TMP}/bad.sh" ]

    # ...and config_safe rejects the same value at the prompt, one phase before
    # anything has been wiped.
    run in_install "config_safe 'en_US\$(id).UTF-8'"
    [ "$status" -ne 0 ]
}

# --- the gate in front of plan_execute -------------------------------------
#
# Two individually plausible cleanups -- "ask has a default, why error at
# EOF?" and "we have two confirmation styles, unify them" -- were each
# survivable by the rest of this suite, and together reached plan_execute on a
# closed stdin with nobody having typed anything. These two cases are what make
# that combination fail.

# ask_yes_no answers with its default at EOF (deliberately -- see the warning
# above it in lib/ui.sh), and confirm_step's default is yes. So this gate has
# to stay a bare `read`: it is the last thing between a closed stdin and
# sgdisk --zap-all, and it is the only one of the three that fails closed.
@test "the disk-wipe gate is a bare read, not ask_yes_no or confirm_step" {
    grep -qF 'Type YES to wipe' "$INSTALL_SH"
    grep -qE 'read -rp .*Type YES to wipe.* confirm \|\| confirm=""' "$INSTALL_SH"
    assert_absent 'confirm_step .*[Ww]ipe' "$INSTALL_SH"
}

# The behavioural counterpart, and the one that fires on the consequence rather
# than the edit. DRY_RUN=true so that nothing downstream of the gate could act
# even if a future change let control past it; plan_execute is stubbed so the
# assertion has something to name.
#
# Mutation-tested, and the results are worth writing down because they are not
# what they look like. Reverting only `ask`'s DEFAULTED branch does not reach
# plan_execute even with the wipe gate unified into confirm_step: the disk
# prompt is the one `ask` call with no default, so control still dies there.
# What this case actually catches is
#   - the whole of `ask` reverted: the disk prompt loops, timeout 124, caught
#     by the `-ne 124` assertion (a regression here hangs, it does not fail);
#   - that, plus a default added to the disk prompt: plan_execute genuinely
#     reached on a closed stdin with nobody having typed anything.
# The second is the one worth fearing, and it is two innocuous-looking edits
# away -- "give the disk prompt a sensible default" is a plausible commit on
# its own.
@test "phase_disk never reaches plan_execute on a closed stdin" {
    run timeout 5 env DRY_RUN=true bash -c "
        source '${INSTALL_SH}'
        banner(){ :; }; lsblk(){ printf 'FAKE 1G DISK\n'; }
        plan_reset(){ :; }; plan_add(){ :; }; plan_render(){ :; }
        plan_execute(){ echo 'PLAN_EXECUTE_REACHED'; }
        phase_disk
    " </dev/null
    # 124 would mean it hung re-prompting instead of stopping.
    [ "$status" -ne 124 ]
    [ "$status" -ne 0 ]
    [[ "$output" != *"PLAN_EXECUTE_REACHED"* ]]
}

# Structural, not behavioural, and deliberately: reaching plan_execute from
# phase_disk means getting past `[[ -b "$disk" ]]`, which needs a real block
# device. Creating one needs root, and test/run.sh refuses to run as root. So
# this asserts on the source, in the same style as the disk-wipe gate above.
#
# Worth asserting at all because lib/disk.sh defaults PLAN_WIPE_DISKS to false,
# so carve and reuse modes cannot wipe by omission -- which leaves whole-disk
# mode as the one path that has to opt in, and nothing else in this suite
# notices if it stops. plan_execute would skip --zap-all and then run
# `sgdisk -n 1:0:...` onto the live partition table, overwriting partition 1 on
# a disk whose operator had just answered a prompt reading "Type YES to wipe".
#
# The ordering matters as much as the presence: set after plan_execute, the
# flag is true only for whoever runs next.
@test "phase_disk opts in to wiping before it reaches plan_execute" {
    local body set_line exec_line
    body=$(sed -n '/^phase_disk()/,/^}/p' "$INSTALL_SH")
    [ -n "$body" ]
    set_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*PLAN_WIPE_DISKS=true[[:space:]]*$' | cut -d: -f1) || true
    exec_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*plan_execute[[:space:]]*$' | cut -d: -f1) || true
    [ -n "$set_line" ]
    [ -n "$exec_line" ]
    [ "$set_line" -lt "$exec_line" ]
}
