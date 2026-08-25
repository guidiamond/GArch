#!/usr/bin/env bats
#
# install.sh is an orchestrator: prompts, ordering and destructive commands.
# Most of it cannot be tested without a disk, and nothing here pretends
# otherwise. What is testable is everything pulled out of the prompt loops into
# named predicates, plus the structural facts that keep the file safe to
# source.
#
# The phase 3 cases at the bottom of this file are the exception: they drive
# the real phase_disk. Every one runs with DRY_RUN=true and with each host
# probe replaced by a function, so no disk is read and none is written -- the
# devices they name do not exist. run_custom's stubs make every destructive
# tool announce itself, and each case asserts that announcement never appears,
# so the assertions are about where control gets to and what the operator was
# shown, never about anything happening to a disk.

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

# "rest" is a legal partition size and an illegal EFI one: size_to_sgdisk maps
# it to sgdisk's 0, meaning "to the end of the disk", so answering it at the
# EFI prompt lays the ESP across the whole disk and leaves the root nothing --
# in whole-disk mode, after --zap-all has already run.
@test "valid_esp_size refuses rest but accepts a fixed size" {
    run in_install 'valid_esp_size 2G';   [ "$status" -eq 0 ]
    run in_install 'valid_esp_size 512M'; [ "$status" -eq 0 ]
    run in_install 'valid_esp_size rest'; [ "$status" -ne 0 ]
    run in_install 'valid_esp_size 2GB';  [ "$status" -ne 0 ]
    # Silent, for the same reason valid_size is: it runs in a re-ask loop.
    run in_install 'valid_esp_size rest'
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
    [ "$(printf '%s\n' "$required" | grep -c .)" -eq 11 ]

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

@test "chroot_config_args carries the bootloader id and removable flag" {
    run in_install "$(with_answers); BOOTLOADER_ID=ARCH_WORK; GRUB_REMOVABLE=false; chroot_config_args AAAA BBBB"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BOOTLOADER_ID=ARCH_WORK"* ]]
    [[ "$output" == *"GRUB_REMOVABLE=false"* ]]
}

# The defaults matter on their own: phase 3 is the only thing that ever
# changes them, and until it runs they are what the chroot would be handed.
# GRUB alone on a shared ESP is a collision, but the fallback path stays
# unwritten unless the inventory says it is free.
@test "install.sh defaults to the GRUB id and to not claiming the fallback path" {
    run in_install 'printf "%s %s\n" "$BOOTLOADER_ID" "$GRUB_REMOVABLE"'
    [ "$status" -eq 0 ]
    [ "$output" = "GRUB false" ]
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
#
# Aimed at phase_disk_whole rather than phase_disk since the mode selector was
# added: phase_disk's own first act is now ask_choice, which fails closed on
# EOF, so pointing this at phase_disk would prove only that -- and stop
# covering the prompts the paragraph above is about. The mode selector's own
# EOF behaviour is the next case.
@test "phase_disk_whole never reaches plan_execute on a closed stdin" {
    run timeout 5 env DRY_RUN=true bash -c "
        source '${INSTALL_SH}'
        banner(){ :; }; lsblk(){ printf 'FAKE 1G DISK\n'; }
        plan_reset(){ :; }; plan_add(){ :; }; plan_render(){ :; }
        plan_validate(){ :; }
        plan_execute(){ echo 'PLAN_EXECUTE_REACHED'; }
        phase_disk_whole
    " </dev/null
    # 124 would mean it hung re-prompting instead of stopping.
    [ "$status" -ne 124 ]
    [ "$status" -ne 0 ]
    [[ "$output" != *"PLAN_EXECUTE_REACHED"* ]]
}

# The mode selector sits in front of both partitioning paths, so a closed stdin
# has to stop there rather than fall into either one. ask_choice returning the
# first option at EOF would run the whole-disk wipe path with nobody having
# typed anything.
@test "phase_disk picks no partitioning mode on a closed stdin" {
    run timeout 5 env DRY_RUN=true bash -c "
        source '${INSTALL_SH}'
        banner(){ :; }
        phase_disk_whole(){ echo 'WHOLE_REACHED'; }
        phase_disk_custom(){ echo 'CUSTOM_REACHED'; }
        phase_disk_finish(){ echo 'FINISH_REACHED'; }
        phase_disk
    " </dev/null
    [ "$status" -ne 124 ]
    [ "$status" -ne 0 ]
    [[ "$output" != *"_REACHED"* ]]
    [[ "$output" == *"aborted"* ]]
}

# A mode string that matches neither arm must stop the phase. Falling through
# would leave PLAN_WIPE_DISKS and FORMAT_ESP at whatever they were and go
# straight into phase_disk_finish, which formats the ESP and mounts.
@test "phase_disk refuses a partitioning mode it does not recognise" {
    run timeout 5 env DRY_RUN=true bash -c "
        source '${INSTALL_SH}'
        banner(){ :; }; ask_choice(){ echo 'Something else'; }
        phase_disk_whole(){ echo 'WHOLE_REACHED'; }
        phase_disk_custom(){ echo 'CUSTOM_REACHED'; }
        phase_disk_finish(){ echo 'FINISH_REACHED'; }
        phase_disk
    " </dev/null
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" != *"_REACHED"* ]]
    [[ "$output" == *"unrecognised partitioning mode"* ]]
}

# Structural, not behavioural, and deliberately. Reaching plan_execute from
# phase_disk means getting past `[[ -b "$disk" ]]`, and there is no
# *disposable* block device to answer that prompt with: -b is a stat, so an
# unprivileged test can satisfy it, but only by naming one of the operator's
# live disks -- and this suite runs on the machine those disks belong to, one
# un-stubbed call away from partitioning one. A throwaway device would need
# /dev/loop* (absent here) plus losetup or mknod, both root-only, and
# test/run.sh refuses to run as root. So this asserts on the source instead,
# in the same style as the disk-wipe gate above.
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
@test "phase_disk_whole opts in to wiping before it reaches plan_execute" {
    local body set_line exec_line
    body=$(sed -n '/^phase_disk_whole()/,/^}/p' "$INSTALL_SH")
    [ -n "$body" ]
    set_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*PLAN_WIPE_DISKS=true[[:space:]]*$' | cut -d: -f1) || true
    exec_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*plan_execute[[:space:]]*$' | cut -d: -f1) || true
    [ -n "$set_line" ]
    [ -n "$exec_line" ]
    [ "$set_line" -lt "$exec_line" ]
}

# --- phase 3 helpers -------------------------------------------------------
#
# Each case below `source`s install.sh into the test process rather than using
# in_install. Two reasons, and both are silent when got wrong: in_install runs
# its argument in a *subshell*, so format_ledger's nameref arguments -- array
# NAMES resolved in the caller's scope -- cannot reach arrays declared in the
# test body; and setup() defines no functions, so a bare `esp_reuse_ok` call
# exits 127, which `run ...; [ "$status" -ne 0 ]` reports as a pass. The 2 GiB
# floor case in particular would then pass with the floor set to any value.
#
# Sourcing is safe because install.sh guards main() behind
# [[ "${BASH_SOURCE[0]}" == "${0}" ]]. It does turn on `set -euo pipefail` in
# the test process, which is contained: bats forks a process per @test.

@test "esp_reuse_ok accepts an esp at or above the 2GiB floor" {
    source "$INSTALL_SH"
    run esp_reuse_ok 2147483648
    [ "$status" -eq 0 ]
}

@test "esp_reuse_ok rejects the 550M esp on this machine" {
    # 576716800 bytes. It clears the old 512MiB floor and would then fill up
    # during mkinitcpio -P: one nvidia initramfs here is 213 MB and there are
    # two images plus a kernel, which is why DEFAULT_ESP_SIZE is 2G.
    source "$INSTALL_SH"
    run esp_reuse_ok 576716800
    [ "$status" -ne 0 ]
    # Guards against the 127 false pass: prove the function actually ran.
    [ -z "$output" ]
}

# parse_esp_list emits a literal "-" for an ESP with no filesystem UUID, and
# nothing stops a future caller passing the wrong field. A size that is not a
# plain integer is not a size, and bash arithmetic on a non-numeric token
# resolves it as a variable name instead of failing.
@test "esp_reuse_ok refuses a size that is not a number, silently" {
    source "$INSTALL_SH"
    run esp_reuse_ok "-"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run esp_reuse_ok ""
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run esp_reuse_ok "MIN_SHARED_ESP_BYTES"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "dev_in_list is true only for an exact match" {
    source "$INSTALL_SH"
    run dev_in_list /dev/sdz1 "/dev/sdz1 /dev/sdz2"
    [ "$status" -eq 0 ]
    run dev_in_list /dev/sdz "/dev/sdz1 /dev/sdz2"
    [ "$status" -ne 0 ]
    run dev_in_list /dev/sdz3 "/dev/sdz1 /dev/sdz2"
    [ "$status" -ne 0 ]
    run dev_in_list /dev/sdz1 ""
    [ "$status" -ne 0 ]
}

# The list is a string, so it has to be split -- but splitting it with an
# unquoted expansion also GLOBS it, and the answer would then depend on what
# happens to exist in the working directory.
#
# The working directory has to hold a file named as the needle is, or the case
# proves nothing: `for candidate in $2` in a directory with no such file globs
# to no match, leaves the '*' as a literal, and answers correctly by accident.
# Measured -- with the needle spelled /dev/sdz1 and bats' own cwd, the
# unquoted version passed this case.
@test "dev_in_list does not glob the list it is given" {
    source "$INSTALL_SH"
    mkdir -p "${TMP}/globbable"
    : > "${TMP}/globbable/sdz1"
    cd "${TMP}/globbable"
    run dev_in_list sdz1 "* /dev/sdz2"
    [ "$status" -ne 0 ]
    # Without this the case passes against a file defining nothing: a missing
    # function exits 127, which is also non-zero. A silent predicate that ran
    # says nothing at all.
    [ -z "$output" ]
}

@test "format_ledger prints device paths, not prose" {
    source "$INSTALL_SH"
    local -a fmt=(/dev/sdz1 /dev/sdz2)
    local -a pres=(/dev/sdz5)
    local -a untouched=(/dev/sdy)
    run format_ledger fmt pres untouched
    [ "$status" -eq 0 ]
    [[ "$output" == *"WILL BE FORMATTED"* ]]
    [[ "$output" == *"/dev/sdz1"* ]]
    [[ "$output" == *"/dev/sdz2"* ]]
    [[ "$output" == *"WILL BE PRESERVED"* ]]
    [[ "$output" == *"/dev/sdz5"* ]]
    [[ "$output" == *"NOT TOUCHED"* ]]
    [[ "$output" == *"/dev/sdy"* ]]
}

@test "format_ledger says none rather than printing an empty section" {
    source "$INSTALL_SH"
    local -a fmt=(/dev/sdz1)
    local -a pres=()
    local -a untouched=()
    run format_ledger fmt pres untouched
    [ "$status" -eq 0 ]
    [[ "$output" == *"(none)"* ]]
}

@test "untouched_devices lists every partition in neither ledger list" {
    source "$INSTALL_SH"
    lsblk() { printf '/dev/sdz disk\n/dev/sdz1 part\n/dev/sdz2 part\n/dev/sdy1 part\n'; }
    local -a fmt=(/dev/sdz1)
    local -a pres=(/dev/sdy1)
    run untouched_devices fmt pres
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdz2" ]
}

# An lsblk that broke must not report a machine on which nothing is being left
# alone: this list is the operator's evidence, and an empty one is a claim.
@test "untouched_devices fails rather than reporting an empty machine" {
    source "$INSTALL_SH"
    lsblk() { return 1; }
    local -a fmt=()
    local -a pres=()
    run untouched_devices fmt pres
    [ "$status" -ne 0 ]
    [[ "$output" == *"lsblk failed"* ]]
}

# needs_grub_install (phase 5) tells OUR id from a different one. It says
# nothing about our id having been somebody else's first, which on a shared ESP
# means grub-install overwrites their grubx64.efi. Checked by id, never by
# esp_has_own_grub -- that predicate is true for the layout this installer
# itself produces, so on a re-run it would report our own ESP as occupied.
@test "bootloader_id_taken reads a mounted ESP by id, case-insensitively" {
    source "$INSTALL_SH"
    mkdir -p "${TMP}/esp/EFI/Fedora" "${TMP}/esp/EFI/BOOT"
    run bootloader_id_taken FEDORA "${TMP}/esp" ""
    [ "$status" -eq 0 ]
    run bootloader_id_taken ARCH_WORK "${TMP}/esp" ""
    [ "$status" -ne 0 ]
}

# With no mountpoint -- a rehearsal, where nothing is mounted -- the adopted
# ESP's own probe is the only evidence there is. esp_dir_inventory emits one
# "vendor <DIR>" line per vendor directory.
@test "bootloader_id_taken falls back to the probe when nothing is mounted" {
    source "$INSTALL_SH"
    run bootloader_id_taken FEDORA "" "$(printf 'vendor Fedora\nfallback no\nkind grub\n')"
    [ "$status" -eq 0 ]
    run bootloader_id_taken ARCH_WORK "" "$(printf 'vendor Fedora\nfallback no\nkind grub\n')"
    [ "$status" -ne 0 ]
    # No probe at all is a carved ESP that does not exist yet: free, not taken.
    run bootloader_id_taken ARCH_WORK "" ""
    [ "$status" -ne 0 ]
}

# --- phase 3 custom mode ---------------------------------------------------
#
# The cases below drive the real phase_disk under DRY_RUN=true with every host
# probe stubbed. Nothing reads or writes a disk: /dev/sdz and /dev/sdy do not
# exist, the probes are functions, and sgdisk/mkfs/partprobe/mount are replaced
# by stubs that announce themselves. Every case asserts that announcement never
# appears, so a stub that stopped covering a call site fails the test rather
# than reaching the tool.
#
# `ask` and `ask_yes_no` are renamed and wrapped rather than replaced, so the
# real EOF and default behaviour still runs while each prompt is logged. This
# is the only way to assert that a prompt did NOT happen: `read -rp` prints
# nothing at all when stdin is not a terminal, and stdin here is a here-string.

custom_stubs() {
cat <<'STUBS'
        banner() { :; }
        lsblk() {
            case "$*" in
                *PKNAME*)    printf '/dev/sdy\n' ;;
                *PATH,TYPE*) printf '/dev/sdz disk\n/dev/sdz1 part\n/dev/sdz2 part\n/dev/sdy1 part\n/dev/sdy2 part\n/dev/sdy3 part\n' ;;
                # valid_whole_disk and disk_prompt_complaint ask lsblk for one
                # device's TYPE. /dev/sdz and /dev/sdy are the disks here;
                # everything else the cases below type at a disk prompt is a
                # partition of one of them.
                *"-dno TYPE"*)
                    case "${*: -1}" in
                        /dev/sdz|/dev/sdy)                            printf 'disk\n' ;;
                        /dev/sdz1|/dev/sdz2|/dev/sdy1|/dev/sdy2|/dev/sdy3) printf 'part\n' ;;
                        *) return 32 ;;   # real lsblk's status for a path it cannot stat
                    esac ;;
                *)           printf '/dev/sdz 10G fake\n' ;;
            esac
        }
        nvram_entries() { printf '0001 Windows Boot Manager\n'; }
        esp_list() { printf '/dev/sdy1 AAAA-BBBB 2147483648\n/dev/sdy2 CCCC-DDDD 576716800\n'; }
        esp_probe() { printf 'fallback no\nkind none\nowngrub no\n'; }
        disk_free_gaps() { printf '2048 20973567 20971520\n'; }
        valid_block_dev() {
            case "$1" in
                /dev/sdz|/dev/sdy|/dev/sdz1|/dev/sdz2|/dev/sdy1|/dev/sdy2|/dev/sdy3) return 0 ;;
            esac
            return 1
        }
        part_in_use() { return 1; }
        part_probe_os() { printf 'empty\n'; }
        # `sgdisk -p` is next_part_number reading the table and is the one
        # sgdisk that is not a write; it succeeds silently, standing in for an
        # empty table on this nonexistent device. It must not fail:
        # next_part_number refuses a table it could not read, which would abort
        # the whole custom-mode run before any of these cases got their
        # prompts. With an empty table it answers 1 for the first carve entry
        # and 2 for the second, from plan_execute's dry-run reservation list.
        # Any OTHER sgdisk here is a write reaching a tool.
        sgdisk() { [[ "$1" == "-p" ]] && return 0; printf 'DESTRUCTIVE_TOOL_RAN sgdisk %s\n' "$*"; return 1; }
        partprobe()   { printf 'DESTRUCTIVE_TOOL_RAN partprobe %s\n' "$*"; return 1; }
        mount()       { printf 'DESTRUCTIVE_TOOL_RAN mount %s\n' "$*"; return 1; }
        mkfs.fat()    { printf 'DESTRUCTIVE_TOOL_RAN mkfs.fat %s\n' "$*"; return 1; }
        mkfs.btrfs()  { printf 'DESTRUCTIVE_TOOL_RAN mkfs.btrfs %s\n' "$*"; return 1; }
        cryptsetup()  { printf 'DESTRUCTIVE_TOOL_RAN cryptsetup %s\n' "$*"; return 1; }
        eval "$(declare -f ask         | sed '1s/^ask /__real_ask /')"
        eval "$(declare -f ask_yes_no  | sed '1s/^ask_yes_no /__real_ask_yes_no /')"
        ask()        { printf 'PROMPT[%s]\n' "$1" >&2; __real_ask "$@"; }
        ask_yes_no() { printf 'PROMPT[%s]\n' "$1" >&2; __real_ask_yes_no "$@"; }
STUBS
}

# run_custom <answers> [extra shell code appended after the stubs]
run_custom() {
    local answers=$1 extra=${2:-}
    run timeout 20 env DRY_RUN=true bash -c "
        source '${INSTALL_SH}'
$(custom_stubs)
${extra}
        phase_disk
        printf 'STATE wipe=%s format_esp=%s removable=%s id=%s uuid=%s reuse=%s\n' \"\$PLAN_WIPE_DISKS\" \"\$FORMAT_ESP\" \"\$GRUB_REMOVABLE\" \"\$BOOTLOADER_ID\" \"\$ESP_FS_UUID\" \"\${PART_EFI_REUSE:-none}\"
    " <<< "$answers"
}

# The harness's own smoke test. Every "this prompt did not happen" assertion
# below is worthless if the wrapper silently stopped logging, and every "no
# tool ran" assertion is worthless if `run` never got as far as a tool.
@test "the custom-mode harness logs prompts and answers them" {
    run_custom "$(printf '2\nn\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\nArch Work\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PROMPT[Disk to install onto]"* ]]
    [[ "$output" == *"PROMPT[Encrypt the root partition with LUKS2?]"* ]]
}

# The single highest-value assertion in this task. --zap-all is the only
# command in the installer that destroys a partition table, and custom mode
# exists precisely so that it never runs.
@test "custom mode carves into free space and never reaches --zap-all" {
    run_custom "$(printf '2\nn\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\nArch Work\n')"
    [ "$status" -eq 0 ]
    [[ "$output" != *"zap"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
    # The carved sectors, resolved before anything is written: 2G from the
    # gap's aligned start, then the rest.
    [[ "$output" == *"sgdisk -n 1:2048:4196351"* ]]
    # 2, not 1: under --dry-run nothing is created, so the number for the
    # second carve comes from the reservation list plan_execute keeps.
    [[ "$output" == *"sgdisk -n 2:4196352:20973567"* ]]
    [[ "$output" == *"STATE wipe=false format_esp=true removable=false id=ARCH_WORK uuid=0000-0000 reuse=none"* ]]
}

# PLAN_WIPE_DISKS is seeded from the environment (lib/disk.sh:25), and phase 3
# is not necessarily the first thing to have touched it. Custom mode's opening
# plan_reset is what clears it, and nothing else in the mode ever assigns it --
# so that one line is the whole of why an inherited `true` cannot carry the
# --zap-all guard open through a path that never asked for it.
#
# plan_validate refuses the same combination a few prompts later, but that is a
# second mechanism and it aborts only after the operator has answered
# everything. The flag has to be false from the first line.
@test "custom mode clears an inherited wipe flag before it builds a plan" {
    run_custom "$(printf '2\nn\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\nArch Work\n')" \
        "PLAN_WIPE_DISKS=true"
    [ "$status" -eq 0 ]
    [[ "$output" != *"zap"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
    [[ "$output" == *"STATE wipe=false"* ]]
}

# The control for the case above, and the reason its `!= *"zap"*` is worth
# anything: the same harness, the same assertions, the other menu entry, and
# --zap-all appears. Without this, a harness that had stopped reaching
# plan_execute at all would report "no --zap-all" and look like a pass.
#
# It is also the only case that drives whole-disk mode through the shared
# phase_disk_finish, which is new: the LUKS block, the ESP format and the two
# boot decisions used to sit inside phase_disk itself.
@test "whole-disk mode still reaches --zap-all, and the same finish" {
    # The trailing "unused" is there so the empty answer before it survives:
    # $( ) strips trailing newlines, so a run of answers ending in a blank line
    # loses exactly the line under test.
    run_custom "$(printf '1\n/dev/sdz\n2G\nYES\nn\nn\n\nunused\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sgdisk --zap-all /dev/sdz"* ]]
    [[ "$output" == *"sgdisk -n 1:0:+2G"* ]]
    [[ "$output" == *"sgdisk -n 2:0:0"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
    [[ "$output" == *"mkfs.fat -F32 /dev/sdz1"* ]]
    # The empty answer to the name prompt takes DEFAULT_INSTALL_NAME, which is
    # the historical id -- a whole-disk install produces what it always did.
    [[ "$output" == *"STATE wipe=true format_esp=true removable=false id=GRUB uuid=0000-0000 reuse=none"* ]]
}

# The ledger is evidence, not a claim: every partition on the machine that is
# in neither plan list has to be named.
@test "custom mode's ledger names the partitions it is leaving alone" {
    run_custom "$(printf '2\nn\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\nArch Work\n')"
    [ "$status" -eq 0 ]
    local not_touched=${output##*NOT TOUCHED}
    [[ "$not_touched" == *"/dev/sdz1"* ]]
    [[ "$not_touched" == *"/dev/sdy1"* ]]
    [[ "$not_touched" == *"/dev/sdy3"* ]]
    # The disk row is not a partition and must not be listed as one.
    [[ "$not_touched" != *"/dev/sdz "* ]]
}

# A plan with a root and no ESP used to pass the Type-YES gate, LUKS-format the
# root and die on `mkfs.fat ""`. It has to be refused while the disk is still
# untouched -- before the gate, and before the passphrase prompt.
@test "custom mode refuses a plan with no ESP before the Type-YES gate" {
    run_custom "$(printf '2\nn\n/dev/sdz\nn\n/dev/sdz1\n')"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"no EFI partition in the plan"* ]]
    [[ "$output" != *"Type YES"* ]]
    [[ "$output" != *"PROMPT[Encrypt the root partition with LUKS2?]"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
    [[ "$output" != *"sgdisk -n"* ]]
}

# Typing anything other than YES has to stop the run with nothing written.
@test "custom mode's confirmation gate refuses anything but YES" {
    run_custom "$(printf '2\nn\n/dev/sdz\ny\n1\n2G\nyes\n')"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"aborted"* ]]
    [[ "$output" != *"sgdisk -n"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
}

# And it has to fail closed at EOF, which is why it is a bare `read` and not
# ask_yes_no: ask_yes_no answers with its DEFAULT at end of input, so written
# that way a closed stdin would proceed to plan_execute with nobody having
# typed anything. The answers here stop one line short of the gate.
@test "custom mode's confirmation gate fails closed on a closed stdin" {
    run_custom "$(printf '2\nn\n/dev/sdz\ny\n1\n2G\n')"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"aborted"* ]]
    [[ "$output" != *"sgdisk -n"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
}

# The ESP and the root do not have to be on the same disk -- reusing a
# neighbour's ESP while carving the root out of another disk's free space is
# the shape this whole feature exists for. plan_add validates a reused
# partition against the disk it is given, so handing it the ROOT's disk refuses
# the entry and aborts the run.
@test "custom mode adopts an ESP on a different disk from the root" {
    run_custom "$(printf '2\ny\n/dev/sdy1\n/dev/sdz\ny\n1\nYES\nn\nn\nArch Work\n')"
    [ "$status" -eq 0 ]
    [[ "$output" != *"zap"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
    [[ "$output" == *"STATE wipe=false format_esp=false"* ]]
    [[ "$output" == *"reuse=/dev/sdy1"* ]]
    [[ "$output" == *"Reusing the existing ESP at /dev/sdy1 without formatting"* ]]
    local preserved=${output##*WILL BE PRESERVED}
    [[ "${preserved%%NOT TOUCHED*}" == *"/dev/sdy1"* ]]
}

# The reuse prompt must take its answer from the enumerated list. Validating
# only `-b` let a mistyped partition number select the neighbour's ROOT
# filesystem, which phase 3 then mounted at /boot and phase 5's
# `grub-mkconfig -o /boot/grub/grub.cfg` overwrote.
@test "custom mode refuses an ESP that is not on the shareable list" {
    run_custom "$(printf '2\ny\n/dev/sdy3\n/dev/sdy2\n/dev/sdy1\n/dev/sdz\ny\n1\nYES\nn\nn\nArch Work\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"'/dev/sdy3' is not one of the shareable ESPs listed above"* ]]
    # ...including an ESP that was listed but filtered out of the menu.
    [[ "$output" == *"'/dev/sdy2' is not one of the shareable ESPs listed above"* ]]
    [[ "$output" == *"reuse=/dev/sdy1"* ]]
}

# An ESP carrying <esp>/grub is somebody's /boot: grub-install and
# grub-mkconfig would replace that install's modules and its whole menu, and
# its grubx64.efi embeds a prefix pointing at the same /grub, so it would then
# boot our menu instead of its own.
@test "custom mode does not offer an ESP that is another install's boot" {
    run_custom "$(printf '2\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\nArch Work\n')" \
        "esp_probe() { printf 'fallback no\nkind grub\nowngrub yes\n'; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in use as another install's /boot"* ]]
    # Not offered at all: the reuse question is never put, so the very next
    # answer is the disk. If it were asked, "/dev/sdz" would be read as the
    # yes/no answer and everything after it would shift.
    [[ "$output" != *"PROMPT[Reuse an existing EFI System Partition?]"* ]]
    [[ "$output" == *"STATE wipe=false format_esp=true"* ]]
}

# An ESP that could not be mounted emits no owngrub line at all. Reading that
# as "not another install's /boot" adopts an ESP nobody looked at.
@test "custom mode does not offer an ESP it could not read" {
    run_custom "$(printf '2\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\nArch Work\n')" \
        "esp_probe() { printf 'fallback unknown\nkind unreadable\n'; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not be read"* ]]
    [[ "$output" != *"PROMPT[Reuse an existing EFI System Partition?]"* ]]
}

# An enumeration that FAILED and a machine with no ESPs must not arrive at the
# same place. Read as "no ESPs", a broken esp_list gives the operator an empty
# reuse menu -- harmless -- and an empty blacklist for the root prompt, which
# is not: every ESP on the machine, including the neighbour's, becomes an
# acceptable answer to "existing partition to use for root (it WILL be
# formatted)".
@test "custom mode stops when it cannot enumerate the ESPs" {
    run_custom "$(printf '2\n/dev/sdz\n')" "esp_list() { return 1; }"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"cannot enumerate this machine's EFI System Partitions"* ]]
    [[ "$output" != *"PROMPT[Disk to install onto]"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
}

# A machine that really has no ESP is the other half of that pair: the reuse
# question is not put at all, and the run carries on to carve one.
@test "custom mode carries on when the machine genuinely has no ESP" {
    run_custom "$(printf '2\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\nArch Work\n')" \
        "esp_list() { return 0; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(none available to share)"* ]]
    [[ "$output" != *"PROMPT[Reuse an existing EFI System Partition?]"* ]]
    [[ "$output" != *"zap"* ]]
    [[ "$output" == *"STATE wipe=false format_esp=true"* ]]
}

# Same distinction on the other inventory. disk_free_gaps suppresses parted's
# stderr, so "this disk has no free space" and "nobody could read this disk"
# both come back as no output -- but not as the same status. Reported as
# "(none)", an unreadable disk sends the operator to the existing-partition
# path with no explanation of why the gap they came here for is missing.
@test "custom mode stops when it cannot read the partition table" {
    run_custom "$(printf '2\nn\n/dev/sdz\n')" "disk_free_gaps() { return 1; }"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"cannot read a partition table on /dev/sdz"* ]]
    [[ "$output" != *"PROMPT[Carve the new install out of unallocated space?]"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
}

# The root prompt's blacklist is EVERY ESP, not the shareable ones: an ESP
# excluded from the reuse menu *because it is another install's /boot* is
# precisely the one that must still be refused as a root filesystem.
@test "custom mode refuses an ESP as the root partition" {
    run_custom "$(printf '2\nn\n/dev/sdy\nn\n/dev/sdy1\n/dev/sdy2\n/dev/sdy3\n')"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"'/dev/sdy1' is an EFI System Partition"* ]]
    [[ "$output" == *"'/dev/sdy2' is an EFI System Partition"* ]]
    # It moved on to the accepted answer and then refused the incomplete plan.
    [[ "$output" == *"no EFI partition in the plan"* ]]
}

# ...or the whole disk itself, which a bare `${disk}*` prefix test matched.
# plan_add refuses it too, but as an abort rather than a re-ask -- and
# btrfs_create_subvols would have run mkfs on the disk, destroying every
# partition on it.
@test "custom mode refuses a root partition on another disk" {
    run_custom "$(printf '2\nn\n/dev/sdz\nn\n/dev/sdy3\n/dev/sdz\n/dev/sdz1\n')"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"'/dev/sdy3' is not a partition of /dev/sdz"* ]]
    [[ "$output" == *"'/dev/sdz' is not a partition of /dev/sdz"* ]]
    [[ "$output" == *"no EFI partition in the plan"* ]]
}

# --- the disk prompts must be given a disk ---------------------------------
#
# valid_block_dev is `[[ -b ]]`, which a partition satisfies exactly as well as
# a disk does, and nothing downstream catches the difference. Measured on the
# operator's machine: /dev/nvme1n1p1 was accepted, disk_free_gaps answered
# empty with status 0 -- not a failure -- so the carve question was skipped
# without a word, and the reuse loop then required the root partition to match
# ${disk}$(part_suffix)[0-9]*, i.e. /dev/nvme1n1p1p[0-9]*, which no device can
# ever be called. Every answer was rejected, forever; Ctrl-C was the only exit.
#
# Driving the loop is the only way to see it: both predicates are true for a
# partition in isolation, which is why 664 unit tests missed it.
@test "valid_whole_disk accepts a disk, rejects a partition, and fails closed" {
    # The accepting case is also this test's control: without it a valid_whole_disk
    # that does not exist would exit 127 and satisfy every -ne 0 below.
    run in_install 'lsblk() { printf "disk\n"; }; valid_block_dev() { :; }; valid_whole_disk /dev/x'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run in_install 'lsblk() { printf "part\n"; }; valid_block_dev() { :; }; valid_whole_disk /dev/x'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    # An lsblk that could not read the device must not read as "disk".
    run in_install 'lsblk() { return 32; }; valid_block_dev() { :; }; valid_whole_disk /dev/x'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    # -b still comes first: a path that is no block device at all is refused
    # without lsblk being consulted.
    run in_install 'lsblk() { printf "disk\n"; }; valid_block_dev() { return 1; }; valid_whole_disk /dev/x'
    [ "$status" -ne 0 ]
}

@test "custom mode's disk prompt rejects a partition and re-asks" {
    run_custom "$(printf '2\nn\n/dev/sdz1\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\nArch Work\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"'/dev/sdz1' is a partition"* ]]
    # The re-ask was answered with the disk, and the carve went ahead on it.
    [[ "$output" == *"sgdisk -n 1:2048:4196351"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
}

@test "whole-disk mode's disk prompt rejects a partition and re-asks" {
    run_custom "$(printf '1\n/dev/sdz1\n/dev/sdz\n2G\nYES\nn\nn\n\nunused\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"'/dev/sdz1' is a partition"* ]]
    [[ "$output" == *"sgdisk --zap-all /dev/sdz"* ]]
    # The whole point: --zap-all never names the partition that was typed.
    [[ "$output" != *"zap-all /dev/sdz1"* ]]
}

# plan_render does not validate, so a plan that plan_execute would refuse can
# otherwise be shown and confirmed as if it could run. Structural because
# neither mode can currently BUILD an invalid plan -- which is exactly what
# makes this a backstop whose ordering nothing else would notice losing.
@test "both partitioning modes validate the plan before rendering it" {
    local mode body validate_line render_line
    for mode in phase_disk_whole phase_disk_custom; do
        body=$(sed -n "/^${mode}()/,/^}/p" "$INSTALL_SH")
        [ -n "$body" ]
        validate_line=$(printf '%s\n' "$body" | grep -n 'plan_validate' | head -1 | cut -d: -f1) || true
        render_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*plan_render[[:space:]]*$' | head -1 | cut -d: -f1) || true
        [ -n "$validate_line" ]
        [ -n "$render_line" ]
        [ "$validate_line" -lt "$render_line" ]
    done
}

# Everything that is not provably empty asks, including "encrypted" and
# "unmountable:*". An answer of no must re-ask rather than proceed.
@test "custom mode asks before formatting a partition that is not empty" {
    run_custom "$(printf '2\nn\n/dev/sdz\nn\n/dev/sdz1\nn\n/dev/sdz2\ny\n')" \
        "part_probe_os() { printf 'linux:Arch Linux\n'; }"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"'/dev/sdz1' is not empty: linux:Arch Linux"* ]]
    [[ "$output" == *"'/dev/sdz2' is not empty: linux:Arch Linux"* ]]
    [[ "$output" == *"PROMPT[Format it anyway and destroy whatever is there?]"* ]]
    # Declining put nothing in the plan; accepting the second one did, and the
    # plan was then refused for having no ESP -- which is what proves the
    # first answer was honoured rather than the loop having simply moved on.
    [[ "$output" == *"no EFI partition in the plan"* ]]
}

# --- the --removable policy ------------------------------------------------

# The one rule nothing downstream can enforce. On the target machine the
# neighbour's bootloader IS \EFI\BOOT\BOOTX64.EFI, so raising GRUB_REMOVABLE
# here overwrites the operator's ability to boot their own system.
@test "a forbid policy never offers the removable fallback path" {
    # The answer after "n" to the LUKS question would be the removable answer
    # if that prompt happened; it is the install name instead, and "y" becomes
    # the bootloader id. That is what proves the question was never put.
    run_custom "$(printf '2\ny\n/dev/sdy1\n/dev/sdz\ny\n1\nYES\nn\ny\n')" \
        "esp_probe() { printf 'fallback yes\nkind grub\nowngrub no\n'; }"
    [ "$status" -eq 0 ]
    [[ "$output" != *"PROMPT[Also install to the removable fallback path"* ]]
    [[ "$output" == *"removable=false"* ]]
    [[ "$output" == *"id=Y"* ]]
    # The refusal names the path it will not touch, and lib/ui.sh's warn puts
    # the message in printf's %s so the backslashes arrive as written. This
    # used to print "<ESC>FI\BOOT\BOOTX64.EFI" -- a different path from the
    # one in use -- on the most safety-critical message in the installer.
    [[ "$output" == *'\EFI\BOOT\BOOTX64.EFI'* ]]
    [[ "$output" == *"belongs to another system"* ]]
}

@test "an offered removable path is written only on an explicit yes" {
    run_custom "$(printf '2\ny\n/dev/sdy1\n/dev/sdz\ny\n1\nYES\nn\ny\nArch Work\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PROMPT[Also install to the removable fallback path"* ]]
    # The consent question names the path in full. The stub logs $1 through
    # printf %s and ask_yes_no now builds its prompt the same way, so this is
    # what the operator is asked. Through `echo -e` they were asked about
    # "<ESC>FI\BOOT\BOOTX64.EFI".
    [[ "$output" == *'PROMPT[Also install to the removable fallback path (\EFI\BOOT\BOOTX64.EFI)?]'* ]]
    [[ "$output" == *"removable=true"* ]]
    [[ "$output" == *"id=ARCH_WORK"* ]]

    run_custom "$(printf '2\ny\n/dev/sdy1\n/dev/sdz\ny\n1\nYES\nn\nn\nArch Work\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"removable=false"* ]]
}

# An adopted ESP is probed during a rehearsal too. Skipping it would make the
# dry run offer to write a fallback path the real run refuses -- a difference
# in the unsafe direction, in the one output an operator reads to decide
# whether the real run is safe.
@test "the removable policy is resolved from a real probe under --dry-run" {
    run_custom "$(printf '2\ny\n/dev/sdy1\n/dev/sdz\ny\n1\nYES\nn\ny\n')" \
        "esp_probe() { printf 'fallback yes\nkind refind\nowngrub no\n'; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(refind)"* ]]
    [[ "$output" == *"removable=false"* ]]
}

# lib/boot.sh:887 states the contract this enforces: an ESP esp_probe could not
# read reports "fallback unknown", never "fallback no", because "no" is the one
# answer removable_policy acts on by OFFERING to overwrite
# \EFI\BOOT\BOOTX64.EFI -- and there is exactly one such path per ESP.
# Answering the question with `grep -q 'fallback yes'` collapses unknown into
# no and hands the offer back, in the fail-open direction, on an ESP nobody
# managed to look at.
#
# Reached by an ESP that was readable when it was listed and unreadable by the
# time it was adopted: the listing filter demands a positive "owngrub no", so
# a probe that fails from the start never gets this far. The stub flips on its
# first call to model exactly that.
@test "an ESP that stopped being readable after it was listed aborts the run" {
    run_custom "$(printf '2\ny\n/dev/sdy1\n/dev/sdz\ny\n1\nYES\nn\ny\nArch Work\n')" \
        '_PF=$(mktemp)
         esp_probe() {
             if [[ -s "$_PF" ]]; then
                 printf "fallback unknown\nkind unreadable\n"
             else
                 printf "x\n" > "$_PF"
                 printf "fallback no\nkind none\nowngrub no\n"
             fi
         }'
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" != *"PROMPT[Also install to the removable fallback path"* ]]
    [[ "$output" == *"cannot decide the --removable policy for /dev/sdy1"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
}

# --- the bootloader id -----------------------------------------------------

# lib/chroot.sh's preflight refuses anything outside [A-Za-z0-9_-], and that
# abort lands after pacstrap. bootloader_id_from is what makes it unreachable.
@test "the install name reaches the chroot as a legal bootloader id" {
    run_custom "$(printf '2\nn\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\nGui/s box!\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"id=GUI_S_BOX_"* ]]
}

@test "a name with nothing usable in it is re-asked, not accepted" {
    run_custom "$(printf '2\nn\n/dev/sdz\ny\n1\n2G\nYES\nn\nn\n///\nArch Work\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"leaves nothing usable as an id"* ]]
    [[ "$output" == *"id=ARCH_WORK"* ]]
}

# grub-install onto an existing vendor directory overwrites its grubx64.efi
# without complaint. On an adopted ESP that is another operating system's
# bootloader, and phase 5's needs_grub_install cannot tell -- it only knows
# whether OUR id is already installed, not whose it was.
@test "an install name whose id is already on the adopted ESP is re-asked" {
    run_custom "$(printf '2\ny\n/dev/sdy1\n/dev/sdz\ny\n1\nYES\nn\nn\nFedora\nArch Work\n')" \
        "esp_probe() { printf 'vendor Fedora\nfallback no\nkind none\nowngrub no\n'; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already used by another bootloader"* ]]
    # Named as the directory it will be on the ESP, backslashes intact.
    [[ "$output" == *'\EFI\FEDORA is already used by another bootloader'* ]]
    [[ "$output" == *"id=ARCH_WORK"* ]]
}

# --- phase 6: boot integration ---------------------------------------------
#
# The one phase that writes into another operating system's bootloader config.
# Every case below runs against stubs: linux_installs and neighbour_loaders are
# functions, the devices they name do not exist, and mount/umount/arch-chroot/
# grub-mkconfig/efibootmgr are replaced by stubs that announce themselves so
# that "no tool ran" can be asserted rather than assumed.
#
# custom_cfg_upsert is wrapped rather than replaced: a path under /mnt is
# announced and NOT written -- /mnt on the machine this suite runs on is the
# operator's own -- while any other path goes to the real function, so
# register_into_foreign_grub can be exercised for real against a fixture root.

boot_stubs() {
cat <<'STUBS'
        banner() { :; }
        HOSTNAME_VAR="work"
        BOOTLOADER_ID="WORK"
        ESP_FS_UUID="AAAA-BBBB"
        PART_EFI="/dev/sdz1"
        PART_ROOT="/dev/sdz2"
        PART_ROOT_RAW="/dev/sdz2"
        GRUB_REMOVABLE=false
        linux_installs()    { printf '/dev/sdy3 69da13ae-6880-492d-975d-d0227f774650 yes Debian GNU/Linux\n'; }
        neighbour_loaders() { printf '38BD-4D38 /EFI/Microsoft/Boot/bootmgfw.efi Windows Boot Manager\n'; }
        mount()         { printf 'DESTRUCTIVE_TOOL_RAN mount %s\n' "$*"; return 1; }
        umount()        { printf 'DESTRUCTIVE_TOOL_RAN umount %s\n' "$*"; return 1; }
        arch-chroot()   { printf 'DESTRUCTIVE_TOOL_RAN arch-chroot %s\n' "$*"; return 1; }
        grub-mkconfig() { printf 'DESTRUCTIVE_TOOL_RAN grub-mkconfig %s\n' "$*"; return 1; }
        grub-install()  { printf 'DESTRUCTIVE_TOOL_RAN grub-install %s\n' "$*"; return 1; }
        efibootmgr()    { printf 'DESTRUCTIVE_TOOL_RAN efibootmgr %s\n' "$*"; return 1; }
        blkid()         { printf 'DESTRUCTIVE_TOOL_RAN blkid %s\n' "$*"; return 1; }
        eval "$(declare -f custom_cfg_upsert | sed '1s/^custom_cfg_upsert /__real_upsert /')"
        custom_cfg_upsert() {
            case "$1" in
                /mnt/*) printf 'UPSERT_MNT[%s|%s]\n' "$1" "$2"; return 0 ;;
            esac
            __real_upsert "$@"
        }
        eval "$(declare -f ask_yes_no | sed '1s/^ask_yes_no /__real_ask_yes_no /')"
        ask_yes_no() { printf 'PROMPT[%s]\n' "$1" >&2; __real_ask_yes_no "$@"; }
STUBS
}

# run_boot <dry_run> <answers> [extra shell code appended after the stubs]
run_boot() {
    local dry=$1 answers=$2 extra=${3:-}
    run timeout 20 env DRY_RUN="$dry" bash -c "
        source '${INSTALL_SH}'
$(boot_stubs)
${extra}
        phase_boot_integration
    " <<< "$answers"
}

# An announcing register, for the cases that only care whether it was reached.
register_announcer() {
    printf '%s' '
        register_into_foreign_grub() {
            printf "REGISTER[%s|%s]\n" "$1" "$2" >&2
            printf "%s/etc/grub.d/40_custom.bak.WORK.1\n" "$1"
            printf "%s/boot/grub/grub.cfg.bak.WORK.1\n" "$1"
        }'
}

@test "the phase 6 harness logs prompts and answers them" {
    run_boot false "$(printf 'y\ny\n')" "$(register_announcer)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PROMPT[Add an entry for this install to its boot menu?]"* ]]
    [[ "$output" == *"PROMPT[Add it to this install's boot menu?]"* ]]
    [[ "$output" == *"boot integration complete"* ]]
}

# The single highest-value assertion in this task: --dry-run must not edit
# another operating system's bootloader config.
@test "phase 6 writes nothing under --dry-run" {
    run_boot true "$(printf 'y\ny\n')" "$(register_announcer)"
    [ "$status" -eq 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
    [[ "$output" != *"REGISTER["* ]]
    [[ "$output" != *"UPSERT_MNT["* ]]
    # It still gets far enough to say what it would have done, on both halves.
    # Both halves name the marker they would have written, so a rehearsal shows
    # which block a real run would create or replace. On a true --dry-run the
    # uuid half is phase 3's "0000-0000" placeholder; here the harness supplies
    # a real-looking one.
    [[ "$output" == *"[dry-run] would back up and edit"*"adding arch-installer:WORK_AAAA-BBBB"* ]]
    [[ "$output" == *"[dry-run] would add arch-installer:NEIGHBOUR_38BD-4D38"* ]]
}

# The control for the case above, and the reason its three "!=" assertions are
# worth anything: the same harness, the same answers, DRY_RUN false, and both
# writers are reached. Without it, a phase that had stopped running at all
# would report "nothing written" and look like a pass.
@test "phase 6 without --dry-run reaches both writers" {
    run_boot false "$(printf 'y\ny\n')" "$(register_announcer)
        mount() { return 0; }
        umount() { return 0; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REGISTER[/"* ]]
    [[ "$output" == *"UPSERT_MNT[/mnt/etc/grub.d/40_custom|NEIGHBOUR_38BD-4D38__EFI_Microsoft_Boot_bootmgfw_efi]"* ]]
    [[ "$output" == *"DESTRUCTIVE_TOOL_RAN arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg"* ]]
}

@test "phase 6 registers nothing into a system whose operator declined" {
    run_boot false "$(printf 'n\nn\n')" "$(register_announcer)"
    [ "$status" -eq 0 ]
    [[ "$output" != *"REGISTER["* ]]
    [[ "$output" != *"UPSERT_MNT["* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN"* ]]
}

# grub-mkconfig regenerates this install's own menu. Running it when nothing
# was added is a wasted os-prober pass; running it when the upsert refused
# would report success for an entry that is not there.
@test "phase 6 runs no grub-mkconfig when the reverse entry was refused" {
    run_boot false "$(printf 'n\ny\n')" '
        custom_cfg_upsert() { printf "UPSERT_MNT[%s]\n" "$1"; return 1; }'
    [ "$status" -eq 0 ]
    [[ "$output" == *"UPSERT_MNT[/mnt/etc/grub.d/40_custom]"* ]]
    [[ "$output" == *"this install's menu is unchanged"* ]]
    [[ "$output" != *"DESTRUCTIVE_TOOL_RAN arch-chroot"* ]]
}

# linux_installs emits "unknown" for a candidate it could not read. Mounting
# one of those read-write to edit a /boot/grub nobody has seen is not the
# direction to fail in.
@test "phase 6 does not offer a neighbour whose filesystem could not be read" {
    run_boot false "$(printf 'y\nn\n')" "$(register_announcer)
        linux_installs() { printf '/dev/sdy3 69da13ae-6880-492d-975d-d0227f774650 unknown (unreadable)\n'; }"
    [ "$status" -eq 0 ]
    [[ "$output" != *"PROMPT[Add an entry for this install to its boot menu?]"* ]]
    [[ "$output" != *"REGISTER["* ]]
    # The reverse half still runs: the two are independent.
    [[ "$output" == *"PROMPT[Add it to this install's boot menu?]"* ]]
}

# The restore summary is the only thing that tells the operator how to put a
# neighbour's config back. It has to name the path AS THAT SYSTEM SEES IT: the
# mountpoint the backup was written under is a mktemp -d that is gone by the
# time anyone reads the summary, and booting the neighbour to run
# `cp /tmp/tmp.XyZ/etc/grub.d/40_custom.bak.WORK.1 ...` restores nothing.
@test "phase 6 reports a restore path relative to the neighbour's own root" {
    mkdir -p "${TMP}/neigh/etc/grub.d" "${TMP}/neigh/boot/grub"
    printf '#!/bin/sh\n' > "${TMP}/neigh/etc/grub.d/40_custom"
    printf 'menuentry "debian" {}\n' > "${TMP}/neigh/boot/grub/grub.cfg"
    run_boot false "$(printf 'y\nn\n')" "
        mount()  { local t=\${!#}; rmdir \"\$t\" 2>/dev/null || true; ln -sfn '${TMP}/neigh' \"\$t\"; }
        umount() { rm -f \"\${!#}\"; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"registered into Debian GNU/Linux on /dev/sdy3"* ]]
    # .bak.WORK_AAAA-BBBB: the backup is named for the marker id, which since
    # own_marker_id carries the ESP uuid too -- two installs sharing a default
    # name must not overwrite each other's backup any more than each other's
    # block.
    [[ "$output" == *"cp /etc/grub.d/40_custom.bak.WORK_AAAA-BBBB.1 /etc/grub.d/40_custom"* ]]
    [[ "$output" == *"cp /boot/grub/grub.cfg.bak.WORK_AAAA-BBBB.1 /boot/grub/grub.cfg"* ]]
    # ...and the entry really landed in both of the neighbour's files.
    grep -q 'Arch Linux (work) \[chainload\]' "${TMP}/neigh/etc/grub.d/40_custom"
    grep -q 'Arch Linux (work) \[chainload\]' "${TMP}/neigh/boot/grub/grub.cfg"
    grep -q 'debian' "${TMP}/neigh/boot/grub/grub.cfg"
    grep -q 'chainloader /EFI/WORK/grubx64.efi' "${TMP}/neigh/boot/grub/grub.cfg"
}

# The device name in that summary was the other half of the same problem: the
# operator reads it after booting the neighbour, and kernel names are assigned
# in discovery order, so /dev/sdy3 may well be a different disk by then. Every
# other identifier this branch generates is a UUID for that reason.
@test "phase 6 names the neighbour by UUID in the restore summary" {
    mkdir -p "${TMP}/neigh/etc/grub.d" "${TMP}/neigh/boot/grub"
    printf '#!/bin/sh\n' > "${TMP}/neigh/etc/grub.d/40_custom"
    printf 'menuentry "debian" {}\n' > "${TMP}/neigh/boot/grub/grub.cfg"
    run_boot false "$(printf 'y\nn\n')" "
        mount()  { local t=\${!#}; rmdir \"\$t\" 2>/dev/null || true; ln -sfn '${TMP}/neigh' \"\$t\"; }
        umount() { rm -f \"\${!#}\"; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"on Debian GNU/Linux (UUID=69da13ae-6880-492d-975d-d0227f774650):  cp /etc/grub.d/40_custom.bak.WORK_AAAA-BBBB.1 /etc/grub.d/40_custom"* ]]
    # ...and no restore line names a device at all. The restore lines are the
    # four-space-indented ones; the "registered into ... on /dev/sdy3" progress
    # message above them is live output, not something anyone retypes later.
    ! printf '%s\n' "$output" | grep -q '^    on /dev/'
    printf '%s\n' "$output" | grep -q '^    on Debian GNU/Linux (UUID='
}

# register_into_foreign_grub returns 2 when 40_custom took the block and
# grub.cfg refused it. The backup is then the only copy of what 40_custom held
# before, so it has to be reported rather than described as safe to delete.
@test "phase 6 reports the backups of a half-updated neighbour" {
    mkdir -p "${TMP}/neigh/etc/grub.d" "${TMP}/neigh/boot/grub"
    printf '#!/bin/sh\n' > "${TMP}/neigh/etc/grub.d/40_custom"
    # Two blocks for OUR marker -- the id as own_marker_id spells it, uuid and
    # all -- is custom_cfg_upsert's permanent duplicate refusal, which is what
    # makes grub.cfg refuse while 40_custom takes the block.
    printf '# BEGIN arch-installer:WORK_AAAA-BBBB\n# END arch-installer:WORK_AAAA-BBBB\n# BEGIN arch-installer:WORK_AAAA-BBBB\n# END arch-installer:WORK_AAAA-BBBB\n' \
        > "${TMP}/neigh/boot/grub/grub.cfg"
    run_boot false "$(printf 'y\nn\n')" "
        mount()  { local t=\${!#}; rmdir \"\$t\" 2>/dev/null || true; ln -sfn '${TMP}/neigh' \"\$t\"; }
        umount() { rm -f \"\${!#}\"; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"only half of /dev/sdy3 was updated"* ]]
    [[ "$output" == *"cp /etc/grub.d/40_custom.bak.WORK_AAAA-BBBB.1 /etc/grub.d/40_custom"* ]]
    [ -f "${TMP}/neigh/etc/grub.d/40_custom.bak.WORK_AAAA-BBBB.1" ]
}

# Nothing in this phase is fatal: it runs after the new system is installed and
# bootable, so an abort would replace "installed, one neighbour unregistered"
# with "Installation failed" and no reboot prompt.
@test "phase 6 carries on when the neighbour inventory fails" {
    run_boot false "$(printf 'y\n')" "$(register_announcer)
        linux_installs() { return 1; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not enumerate the other Linux installs"* ]]
    [[ "$output" != *"REGISTER["* ]]
    [[ "$output" == *"UPSERT_MNT["* ]]
    [[ "$output" == *"boot integration complete"* ]]
}

@test "phase 6 carries on when the bootloader inventory fails" {
    run_boot false "$(printf 'y\n')" "$(register_announcer)
        mount() { return 0; }
        umount() { return 0; }
        neighbour_loaders() { return 1; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not enumerate the other bootloaders"* ]]
    [[ "$output" == *"REGISTER["* ]]
    [[ "$output" != *"UPSERT_MNT["* ]]
    [[ "$output" == *"boot integration complete"* ]]
}

# An /etc/os-release NAME containing an apostrophe reaches chain_entry through
# a neighbour's NVRAM label, and chain_entry refuses it. Under the installer's
# set -euo pipefail that refusal must not take the run down because of a file
# on a partition that is only staying.
@test "phase 6 skips a bootloader whose label cannot go in a menu entry" {
    run_boot false "$(printf 'n\ny\ny\n')" "$(register_announcer)
        neighbour_loaders() {
            printf \"38BD-4D38 /EFI/Microsoft/Boot/bootmgfw.efi Bob's Linux\n\"
            printf '283B-4CE7 /EFI/BOOT/BOOTX64.EFI UEFI OS\n'
        }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"must not contain a single quote"* ]]
    [[ "$output" != *"UPSERT_MNT[/mnt/etc/grub.d/40_custom|NEIGHBOUR_38BD-4D38"* ]]
    # The next one is still offered and still written -- the skip is of one
    # entry, not of the rest of the phase.
    [[ "$output" == *"UPSERT_MNT[/mnt/etc/grub.d/40_custom|NEIGHBOUR_283B-4CE7__EFI_BOOT_BOOTX64_EFI]"* ]]
}

# grub-mkconfig runs once, after every entry is written, rather than once per
# entry: each pass runs os-prober, which mounts every candidate root it finds.
@test "phase 6 regenerates this install's menu exactly once" {
    run_boot false "$(printf 'n\ny\ny\n')" "$(register_announcer)
        neighbour_loaders() {
            printf '38BD-4D38 /EFI/Microsoft/Boot/bootmgfw.efi Windows Boot Manager\n'
            printf '283B-4CE7 /EFI/BOOT/BOOTX64.EFI UEFI OS\n'
        }"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'arch-chroot /mnt grub-mkconfig')" -eq 1 ]
    [ "$(printf '%s\n' "$output" | grep -c 'UPSERT_MNT\[')" -eq 2 ]
}

# grub-install --removable overrides --bootloader-id: upstream forces the EFI
# distributor to "BOOT" and writes \EFI\BOOT\BOOTX64.EFI only, with no vendor
# directory and no NVRAM entry. A chainload entry naming /EFI/<id>/grubx64.efi
# would then be written into every neighbour's live menu pointing at a path no
# ESP on the machine carries -- and with nothing in NVRAM either, the new
# install would be reachable from no menu at all.
#
# The control for this one is "phase 6 reports a restore path relative to the
# neighbour's own root", which runs the same fixture with the stubs' default
# GRUB_REMOVABLE=false and asserts the vendor path.
@test "phase 6 chainloads the removable path when GRUB_REMOVABLE is true" {
    mkdir -p "${TMP}/neigh/etc/grub.d" "${TMP}/neigh/boot/grub"
    printf '#!/bin/sh\n' > "${TMP}/neigh/etc/grub.d/40_custom"
    printf 'menuentry "debian" {}\n' > "${TMP}/neigh/boot/grub/grub.cfg"
    run_boot false "$(printf 'y\nn\n')" "
        GRUB_REMOVABLE=true
        mount()  { local t=\${!#}; rmdir \"\$t\" 2>/dev/null || true; ln -sfn '${TMP}/neigh' \"\$t\"; }
        umount() { rm -f \"\${!#}\"; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"registered into Debian GNU/Linux on /dev/sdy3"* ]]
    grep -q 'chainloader /EFI/BOOT/BOOTX64.EFI' "${TMP}/neigh/boot/grub/grub.cfg"
    ! grep -q 'chainloader /EFI/WORK/grubx64.efi' "${TMP}/neigh/boot/grub/grub.cfg"
}

# The same path, on the other half. neighbour_loaders is told which loaders are
# ours so that the reverse menu does not gain a row for this install; if that
# seed keeps naming a vendor directory --removable never created, the dedupe
# stops matching and our own loader comes back as a "neighbour" in our own menu.
@test "phase 6 seeds its own-loader exclusion from the same path it chainloads" {
    run_boot false "$(printf 'n\n')" "
        GRUB_REMOVABLE=true
        neighbour_loaders() { printf 'OURS[%s]\n' \"\$*\" >&2; return 1; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OURS[/dev/sdz1 AAAA-BBBB /EFI/BOOT/BOOTX64.EFI]"* ]]
}

@test "phase 6 seeds its own-loader exclusion with the vendor path by default" {
    run_boot false "$(printf 'n\n')" "
        neighbour_loaders() { printf 'OURS[%s]\n' \"\$*\" >&2; return 1; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OURS[/dev/sdz1 AAAA-BBBB /EFI/WORK/grubx64.efi]"* ]]
}

# A bare `mount` of an Arch-style btrfs root succeeds and lands on subvolid 5,
# the top level -- nothing in this tree ever runs `btrfs subvolume set-default`
# -- and /boot/grub is not there. linux_installs tries subvol=@ first for that
# reason and certified this neighbour has_grub yes from the @ subvolume, so
# mounting it the other way round here makes the forward half a guaranteed
# no-op for the commonest btrfs layout: register_into_foreign_grub finds no
# grub.cfg and the phase reports "could not register" for a system that has one.
@test "phase 6 mounts a btrfs neighbour at subvol=@ rather than the top level" {
    mkdir -p "${TMP}/top" "${TMP}/sub/etc/grub.d" "${TMP}/sub/boot/grub"
    printf '#!/bin/sh\n' > "${TMP}/sub/etc/grub.d/40_custom"
    printf 'menuentry "debian" {}\n' > "${TMP}/sub/boot/grub/grub.cfg"
    run_boot false "$(printf 'y\nn\n')" "
        mount() {
            local t=\${!#} src='${TMP}/top'
            case \"\$*\" in *subvol=@*) src='${TMP}/sub' ;; esac
            rmdir \"\$t\" 2>/dev/null || true
            ln -sfn \"\$src\" \"\$t\"
        }
        umount() { rm -f \"\${!#}\"; }"
    [ "$status" -eq 0 ]
    [[ "$output" == *"registered into Debian GNU/Linux on /dev/sdy3"* ]]
    grep -q 'Arch Linux (work) \[chainload\]' "${TMP}/sub/boot/grub/grub.cfg"
    # The top level was never written to, not merely not reported.
    [ -z "$(ls -A "${TMP}/top")" ]
}

# --- phase 6, structural ---------------------------------------------------

# The hardest rule in this phase. A foreign grub-mkconfig regenerates that
# system's whole menu from the live ISO's view of the machine and can fail
# outright on a GRUB version mismatch, replacing a working config with one
# nobody asked for -- on a machine whose other operating systems have to keep
# booting. The only generator run anywhere is the one inside our own chroot.
@test "install.sh runs grub-mkconfig only inside its own chroot" {
    local line stripped n=0
    # Every line naming the generator, minus the comments and the operator
    # messages that quote the command for someone to re-run by hand. What is
    # left has to be one line, and that line has to be the arch-chroot form.
    #
    # usage()'s heredoc is cut out first. Its lines carry no leading `warn ` or
    # `#` to strip, so prose describing the rule scored as a second executable
    # call -- which cost the operator the sentence that states the rule
    # plainly, reworded until it stopped matching. The exclusion is the whole
    # heredoc, from `cat <<'USAGE'` to its terminator, so nothing inside it
    # ever counts as code again.
    while IFS= read -r line; do
        stripped=${line#"${line%%[![:space:]]*}"}
        case "$stripped" in
            \#*|warn\ *|info\ *|success\ *|error\ *) continue ;;
        esac
        n=$(( n + 1 ))
        [[ "$stripped" == *"arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg"* ]]
    done < <(awk '
        /^[[:space:]]*cat <<.USAGE.$/ { in_usage = 1 }
        in_usage && /^USAGE$/         { in_usage = 0; next }
        !in_usage
    ' "$INSTALL_SH" | grep -F 'grub-mkconfig')
    [ "$n" -eq 1 ]
    # And nothing in the library the phase calls into can run one at all.
    # test/boot.bats pins the same fact with its own control; this is a second
    # reader, from the file that would have to be the one calling it.
    [ -z "$(grep -nE 'grub-mkconfig|grub2-mkconfig|grub-install' "${ARCH_SETUP}/lib/boot.sh" \
            | grep -vE '^[0-9]+:[[:space:]]*#' || true)" ]
}

# custom_cfg_upsert always appends its block at the END of the file, so writing
# a second id reorders the first: everything after the rewritten block shifts
# up by one. A GRUB_DEFAULT set by index then selects a different operating
# system. Phase 6 writes one block per neighbour into one file, so this is the
# ordinary case rather than an edge one.
@test "nothing sets GRUB_DEFAULT" {
    # On the assignment, not on the name: lib/boot.sh's custom_cfg_upsert
    # header explains the hazard at length and has to keep saying so.
    assert_absent 'GRUB_DEFAULT=' "$INSTALL_SH"
    assert_absent 'GRUB_DEFAULT=' "${ARCH_SETUP}/lib/boot.sh"
    assert_absent 'GRUB_DEFAULT=' "${ARCH_SETUP}/lib/chroot.sh"
}

# The banner is what the operator counts progress against, and phase 6 is the
# one that runs after the phase the old count called last.
@test "TOTAL_PHASES counts the boot integration phase" {
    grep -qx 'TOTAL_PHASES=6' "$INSTALL_SH"
    grep -q 'banner 6 "\$TOTAL_PHASES" "Boot Integration"' "$INSTALL_SH"
}

# lib/chroot.sh tells the operator, in the branch where os-prober could not be
# installed, that "the static chainload entries from phase 6 still work". That
# is a forward reference to this phase, and renaming or renumbering it here
# without changing that string leaves a message pointing at a phase that does
# not exist.
@test "lib/chroot.sh's forward reference names the phase this file numbers 6" {
    grep -qF 'chainload entries from phase 6' "${ARCH_SETUP}/lib/chroot.sh"
    grep -qx 'TOTAL_PHASES=6' "$INSTALL_SH"
}

# /mnt must still be mounted: the reverse entries are written into
# /mnt/etc/grub.d/40_custom and picked up by a grub-mkconfig inside that
# chroot. Ordered after phase_chroot because BOOTLOADER_ID's install has to
# exist before anything chainloads it.
@test "main runs phase 6 after the chroot and before the unmount" {
    local body chroot_line boot_line umount_line
    body=$(sed -n '/^main()/,/^}/p' "$INSTALL_SH")
    [ -n "$body" ]
    chroot_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*phase_chroot[[:space:]]*$' | cut -d: -f1) || true
    boot_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*phase_boot_integration[[:space:]]*$' | cut -d: -f1) || true
    umount_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*unmount_target[[:space:]]*$' | head -1 | cut -d: -f1) || true
    [ -n "$chroot_line" ]
    [ -n "$boot_line" ]
    [ -n "$umount_line" ]
    [ "$chroot_line" -lt "$boot_line" ]
    [ "$boot_line" -lt "$umount_line" ]
}

# --- phase 5: the firmware boot entry ---------------------------------------
#
# grub-install --removable writes \EFI\BOOT\BOOTX64.EFI and stops there:
# upstream forces the EFI distributor to "BOOT" and guards the NVRAM
# registration with `if (!removable && update_nvram)`. On a machine whose
# firmware already has an entry for another operating system the fallback path
# is never reached, so without an entry of its own the install is reachable
# from no menu on the machine -- including, when phase 6 finds no neighbour to
# register into, none at all.

@test "phase 5 registers a firmware entry when GRUB_REMOVABLE is true" {
    run in_install "
        GRUB_REMOVABLE=true; PART_EFI=/dev/sdz1; BOOTLOADER_ID=ARCH_WORK
        nvram_register_removable() { echo \"REGISTER[\$*]\"; }
        chroot_register_nvram"
    [ "$status" -eq 0 ]
    [[ "$output" == *"REGISTER[/dev/sdz1 ARCH_WORK]"* ]]
}

# grub-install registers the entry itself when --removable is not passed, so
# doing it here too would leave the machine with two rows for one install.
@test "phase 5 registers nothing when GRUB_REMOVABLE is false" {
    run in_install "
        GRUB_REMOVABLE=false; PART_EFI=/dev/sdz1; BOOTLOADER_ID=ARCH_WORK
        nvram_register_removable() { echo \"REGISTER[\$*]\"; }
        chroot_register_nvram
        echo REACHED"
    [ "$status" -eq 0 ]
    [[ "$output" != *"REGISTER["* ]]
    # The control: the test above is the same harness with the flag flipped,
    # and REACHED proves this one ran the helper rather than dying before it.
    [[ "$output" == *"REACHED"* ]]
}

# Warning-grade, not fatal. By the time this runs the system is installed and
# phase 6 is still to come, and `set -euo pipefail` would otherwise turn a
# failed efibootmgr into "Installation failed" for an install that succeeded.
@test "a failed registration warns rather than aborting phase 5" {
    run in_install "
        GRUB_REMOVABLE=true; PART_EFI=/dev/sdz1; BOOTLOADER_ID=ARCH_WORK
        nvram_register_removable() { return 1; }
        chroot_register_nvram
        echo REACHED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no firmware boot entry of its own"* ]]
    # The hint is a command line the operator is meant to retype, so the
    # --loader argument has to survive printing character for character.
    [[ "$output" == *"--loader '\EFI\BOOT\BOOTX64.EFI' --label ARCH_WORK"* ]]
    [[ "$output" == *"REACHED"* ]]
}

# Both paths, because the dry-run one returns early: a rehearsal that skipped
# this would not show whether the install it describes ends up with a firmware
# entry at all.
@test "phase 5 reaches the registration on the dry-run path as well as the real one" {
    local body
    body=$(sed -n '/^phase_chroot()/,/^}/p' "$INSTALL_SH")
    [ -n "$body" ]
    [ "$(printf '%s\n' "$body" | grep -c '^[[:space:]]*chroot_register_nvram[[:space:]]*$')" -eq 2 ]
    # The first of the two sits inside the `if [[ "$DRY_RUN" == true ]]` block,
    # ahead of its `return 0`.
    [ "$(printf '%s\n' "$body" | grep -n '^[[:space:]]*chroot_register_nvram[[:space:]]*$' | head -1 | cut -d: -f1)" \
      -lt "$(printf '%s\n' "$body" | grep -n '^[[:space:]]*return 0[[:space:]]*$' | head -1 | cut -d: -f1)" ]
}

# It has to run after the chroot: grub-install is what creates the binary the
# entry points at, and an entry for a loader that is not there yet is a boot
# failure the operator only sees at the firmware menu.
@test "phase 5 registers the firmware entry after the chroot, not before" {
    local body chroot_line reg_line
    body=$(sed -n '/^phase_chroot()/,/^}/p' "$INSTALL_SH")
    chroot_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*arch-chroot /mnt /root/chroot_setup.sh[[:space:]]*$' | cut -d: -f1)
    reg_line=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*chroot_register_nvram[[:space:]]*$' | tail -1 | cut -d: -f1)
    [ -n "$chroot_line" ]
    [ -n "$reg_line" ]
    [ "$chroot_line" -lt "$reg_line" ]
}

# --- the phase 1 and phase 2 host writes under --dry-run --------------------
#
# `timedatectl set-ntp true` turns on time synchronisation on the machine the
# installer is running on, and it persists across the run; `loadkeys` reloads
# that machine's virtual console for the rest of the boot. Neither touches the
# target install, so under --dry-run both are the rehearsal reaching out and
# changing the operator's own host -- exactly what run_cmd exists to withhold.
#
# Each case carries its own DRY_RUN=false control. "The stub recorded nothing"
# is equally satisfied by a harness that never reached the command at all, so
# the same call has to produce a record once the gate is open.

# A PATH shim recording every invocation. The args file is created only by an
# execution, so its absence is the proof that nothing ran.
stub_tool() {
    local name=$1
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/%s_args\nexit 0\n' "$TMP" "$name" \
        > "$TMP/bin/$name"
    chmod +x "$TMP/bin/$name"
}

# Drives the real phase_preflight. `die` is neutralised because this suite
# never runs as root and EUID cannot be assigned, so `(( EUID == 0 )) || die
# "must run as root"` would end every case several lines before the clock
# block; with die inert, the archiso and UEFI guards fall through too. The
# three host actions around the clock are stubbed so that reaching it needs
# neither the network nor this machine's keyring and mirrorlist.
run_preflight() {
    local dry=$1
    stub_tool timedatectl
    run timeout 20 env DRY_RUN="$dry" PATH="$TMP/bin:$PATH" bash -c "
        source '${INSTALL_SH}'
        banner() { :; }
        die() { :; }
        ask_yes_no() { return 0; }
        net_check() { return 0; }
        refresh_keyring() { return 0; }
        rank_mirrors() { :; }
        phase_preflight
    "
}

@test "phase_preflight enables no NTP under --dry-run and prints what it would run" {
    run_preflight true
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/timedatectl_args" ]
    [[ "$output" == *"[dry-run]"* ]]
    [[ "$output" == *"timedatectl set-ntp true"* ]]

    run_preflight false
    [ "$status" -eq 0 ]
    grep -qF -- 'set-ntp true' "$TMP/timedatectl_args"
}

# Drives the real phase_locale. Its keymap loop is the first of three, and the
# two after it are answered rather than skipped because there is no way out of
# the function before them: `ask` returns its default at EOF and every failed
# check `continue`s, so an unanswerable prompt spins until the timeout.
run_locale() {
    local dry=$1
    stub_tool loadkeys
    run timeout 20 env DRY_RUN="$dry" PATH="$TMP/bin:$PATH" bash -c "
        source '${INSTALL_SH}'
        banner() { :; }
        confirm_step() { :; }
        keymap_listed() { return 0; }
        locale_listed() { return 0; }
        # The timezone loop's check is a real -f against /usr/share/zoneinfo,
        # which no stub here intercepts, so the answer has to be one every
        # tzdata carries.
        ask() {
            case \"\$1\" in
                'Console keymap') printf 'br-abnt2\n' ;;
                'System locale')  printf 'en_US.UTF-8\n' ;;
                *)                printf 'UTC\n' ;;
            esac
        }
        phase_locale
    "
}

@test "phase_locale loads no keymap under --dry-run and prints what it would run" {
    run_locale true
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/loadkeys_args" ]
    # The real path sends loadkeys' own output to /dev/null. Wrapping run_cmd
    # in that redirection would send the [dry-run] line there too, leaving the
    # rehearsal showing nothing where it withheld a command.
    [[ "$output" == *"[dry-run]"* ]]
    [[ "$output" == *"loadkeys br-abnt2"* ]]

    run_locale false
    [ "$status" -eq 0 ]
    grep -qF -- 'br-abnt2' "$TMP/loadkeys_args"
}

# --- phase 6: the forward marker -------------------------------------------

# Measured against a fixture root: with the marker keyed on the bootloader id
# alone, a second install carving its own ESP found \EFI\GRUB free there, took
# the same default id, and custom_cfg_upsert -- idempotent by design -- then
# REPLACED install one's block instead of adding a second. Install one dropped
# out of that neighbour's menu and survived only through its own NVRAM entry,
# the fallback this phase exists precisely so as not to rely on.
@test "a second install on its own ESP does not replace the first in a neighbour's menu" {
    local root="${TMP}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    : > "${root}/etc/grub.d/40_custom"
    printf 'menuentry "existing" {}\n' > "${root}/boot/grub/grub.cfg"
    run in_install "
        GRUB_REMOVABLE=false
        BOOTLOADER_ID=GRUB
        ESP_FS_UUID=AAAA-1111
        register_into_foreign_grub '${root}' \"\$(own_marker_id)\" \\
            \"\$(chain_entry 'Arch one' \"\$ESP_FS_UUID\" \"\$(own_loader_path)\")\" >/dev/null
        ESP_FS_UUID=BBBB-2222
        register_into_foreign_grub '${root}' \"\$(own_marker_id)\" \\
            \"\$(chain_entry 'Arch two' \"\$ESP_FS_UUID\" \"\$(own_loader_path)\")\" >/dev/null
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c '^# BEGIN arch-installer:' "${root}/boot/grub/grub.cfg")" -eq 2 ]
    grep -q 'AAAA-1111' "${root}/boot/grub/grub.cfg"
    grep -q 'BBBB-2222' "${root}/boot/grub/grub.cfg"
    grep -q 'existing'  "${root}/boot/grub/grub.cfg"
}

# The control for the case above: keying the marker on more than the id must
# not cost custom_cfg_upsert's idempotency. Re-running the same install --
# same id, same ESP -- still has to update its one block rather than append.
@test "re-registering the same install rewrites its one block" {
    local root="${TMP}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    : > "${root}/etc/grub.d/40_custom"
    printf 'menuentry "existing" {}\n' > "${root}/boot/grub/grub.cfg"
    run in_install "
        GRUB_REMOVABLE=false
        BOOTLOADER_ID=GRUB
        ESP_FS_UUID=AAAA-1111
        register_into_foreign_grub '${root}' \"\$(own_marker_id)\" \\
            \"\$(chain_entry 'Arch one' \"\$ESP_FS_UUID\" \"\$(own_loader_path)\")\" >/dev/null
        register_into_foreign_grub '${root}' \"\$(own_marker_id)\" \\
            \"\$(chain_entry 'Arch one again' \"\$ESP_FS_UUID\" \"\$(own_loader_path)\")\" >/dev/null
    "
    [ "$status" -eq 0 ]
    [ "$(grep -c '^# BEGIN arch-installer:' "${root}/boot/grub/grub.cfg")" -eq 1 ]
    grep -q 'Arch one again' "${root}/boot/grub/grub.cfg"
    [[ "$(cat "${root}/boot/grub/grub.cfg")" != *"menuentry 'Arch one' "* ]]
}

# own_marker_id must stay inside custom_cfg_upsert's [A-Za-z0-9_-], or phase 6
# refuses every foreign config it is handed -- after pacstrap, with the new
# system already on the disk.
@test "own_marker_id carries the ESP uuid and stays a legal marker id" {
    run in_install 'BOOTLOADER_ID=GRUB ESP_FS_UUID=AAAA-1111 own_marker_id'
    [ "$status" -eq 0 ]
    [ "$output" = "GRUB_AAAA-1111" ]
    run in_install 'BOOTLOADER_ID=GRUB ESP_FS_UUID="AA/AA 1111" own_marker_id'
    [ "$status" -eq 0 ]
    [ "$output" = "GRUB_AA_AA_1111" ]
}

# --- phase 5: confirming the entry grub-install was supposed to make --------
#
# On the non-removable path grub-install registers the entry itself -- but it
# WARNS AND EXITS 0 when it cannot: no efibootmgr in the chroot, a read-only
# efivarfs, an NVRAM with no room left. The result is a loader on the ESP with
# no firmware entry, and not at the fallback path either, reachable only
# through a neighbour's menu -- with nothing said about it.

@test "phase 5 warns when the firmware has no entry for a non-removable install" {
    run in_install "
        DRY_RUN=false; GRUB_REMOVABLE=false; PART_EFI=/dev/sdz1; BOOTLOADER_ID=ARCH_WORK
        lsblk() { echo 1a2b3c4d-0000-0000-0000-000000000001; }
        nvram_loaders() { printf '0002 9999aaaa-0000-0000-0000-000000000009 /EFI/Microsoft/Boot/bootmgfw.efi Windows\n'; }
        chroot_register_nvram
        echo REACHED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no firmware boot entry of its own"* ]]
    # A command the operator is meant to retype, so the --loader argument has
    # to survive printing character for character.
    [[ "$output" == *"--loader '\EFI\ARCH_WORK\grubx64.efi' --label ARCH_WORK"* ]]
    # Never fatal: the system is installed and phase 6 is still to come.
    [[ "$output" == *"REACHED"* ]]
}

# The control for the case above: with the row present the phase says so and
# says nothing about a missing entry, which is what makes that "warns"
# assertion mean anything.
@test "phase 5 confirms the firmware entry grub-install made" {
    run in_install "
        DRY_RUN=false; GRUB_REMOVABLE=false; PART_EFI=/dev/sdz1; BOOTLOADER_ID=ARCH_WORK
        lsblk() { echo 1A2B3C4D-0000-0000-0000-000000000001; }
        nvram_loaders() { printf '0003 1a2b3c4d-0000-0000-0000-000000000001 /EFI/ARCH_WORK/grubx64.efi Arch work\n'; }
        chroot_register_nvram"
    [ "$status" -eq 0 ]
    # Matched case-insensitively on both fields: lsblk reports the partition
    # GUID upper-case and efibootmgr lower-case, and FAT has no case either.
    [[ "$output" == *"entry 0003"* ]]
    [[ "$output" != *"no firmware boot entry"* ]]
}

# nvram_loaders returns non-zero when efibootmgr could not be read at all.
# That is "unable to confirm", not "the entry is missing", and under
# `set -euo pipefail` a bare call would abort the installer outright.
@test "phase 5 says it could not confirm when the firmware cannot be read" {
    run in_install "
        DRY_RUN=false; GRUB_REMOVABLE=false; PART_EFI=/dev/sdz1; BOOTLOADER_ID=ARCH_WORK
        lsblk() { echo 1a2b3c4d-0000-0000-0000-000000000001; }
        nvram_loaders() { return 1; }
        chroot_register_nvram
        echo REACHED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not"* ]]
    [[ "$output" == *"REACHED"* ]]
}

# A rehearsal never ran grub-install, so there is no entry to find and a
# warning about a missing one would be a lie about the install being described.
@test "phase 5 does not claim a missing firmware entry under --dry-run" {
    run in_install "
        DRY_RUN=true; GRUB_REMOVABLE=false; PART_EFI=/dev/sdz1; BOOTLOADER_ID=ARCH_WORK
        nvram_loaders() { echo 'NVRAM_READ'; }
        chroot_register_nvram"
    [ "$status" -eq 0 ]
    [[ "$output" != *"no firmware boot entry"* ]]
    [[ "$output" != *"NVRAM_READ"* ]]
    [[ "$output" == *"dry-run"* ]]
}

# --- phase 3 whole-disk mode ------------------------------------------------
#
# The same harness shape as the custom-mode cases above: DRY_RUN=true, every
# host probe a function, and the devices named do not exist. What these cases
# are about is what the operator is shown, and what the mode refuses outright,
# BEFORE the Type-YES gate in front of `sgdisk --zap-all`.

whole_stubs() {
    custom_stubs
cat <<'STUBS'
        # Narrower than custom_stubs' lsblk: whole-disk mode asks for one
        # disk's partitions, and the shared stub answers every PATH,TYPE query
        # with the whole machine -- which would put another disk's partitions
        # in this disk's "will be formatted" list.
        __esp_unformatted=""
        __lsblk_all() { printf '/dev/sdz disk\n/dev/sdz1 part\n/dev/sdz2 part\n/dev/sdy disk\n/dev/sdy1 part\n/dev/sdy2 part\n/dev/sdy3 part\n'; }
        lsblk() {
            case "$*" in
                *PATH,TYPE*/dev/sdz) printf '/dev/sdz disk\n/dev/sdz1 part\n/dev/sdz2 part\n' ;;
                *PATH,TYPE*)         __lsblk_all ;;
                # Per device, not one fixed answer: whole-disk mode asks
                # which disk each ESP is on, and a stub that says /dev/sdy for
                # everything would put every ESP on the other disk.
                *PKNAME*)
                    case "${*: -1}" in
                        /dev/sdz1|/dev/sdz2) printf '/dev/sdz\n' ;;
                        *)                   printf '/dev/sdy\n' ;;
                    esac ;;
                *"-dno FSTYPE"*)
                    # A device named in __esp_unformatted reports the empty
                    # FSTYPE real lsblk gives a partition that was carved and
                    # never formatted. A case sets it to reach that branch.
                    case " ${__esp_unformatted} " in
                        *" ${*: -1} "*) printf '\n'; return 0 ;;
                    esac
                    case "${*: -1}" in
                        /dev/sdz1) printf 'vfat\n' ;;
                        *)         printf 'ext4\n' ;;
                    esac ;;
                *"-dno TYPE"*)
                    case "${*: -1}" in
                        /dev/sdz|/dev/sdy) printf 'disk\n' ;;
                        /dev/sdz1|/dev/sdz2|/dev/sdy1|/dev/sdy2|/dev/sdy3) printf 'part\n' ;;
                        *) return 32 ;;
                    esac ;;
                *NAME,SIZE,FSTYPE*)  printf '/dev/sdz    100G\n/dev/sdz1   100M vfat  ESP    /boot\n/dev/sdz2  99.9G ext4  root   /\n' ;;
                *)                   printf '/dev/sdz 100G fake\n' ;;
            esac
        }
STUBS
}

run_whole() {
    local answers=$1 extra=${2:-}
    run timeout 20 env DRY_RUN=true bash -c "
        source '${INSTALL_SH}'
$(whole_stubs)
${extra}
        phase_disk_whole
    " <<< "$answers"
}

# The control the three cases below depend on: the same harness, a disk nothing
# objects to, and the mode gets all the way to the one command that destroys a
# partition table. Without it a harness that had stopped running at all would
# report every refusal as a pass.
@test "whole-disk mode still wipes a disk that is genuinely free" {
    run_whole "$(printf '/dev/sdz\n2G\nYES\n')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sgdisk --zap-all /dev/sdz"* ]]
}

# The live root's disk. Whole-disk mode used to show one line --
# "/dev/sdz 100G <model>" -- and then take YES for it.
@test "whole-disk mode refuses a disk carrying a mounted partition" {
    run_whole "$(printf '/dev/sdz\n2G\nYES\n')" '
        part_in_use() { [[ "$1" == /dev/sdz2 ]]; }'
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"/dev/sdz2 is in use"* ]]
    [[ "$output" != *"sgdisk --zap-all"* ]]
}

@test "whole-disk mode refuses a disk whose ESP carries a bootloader" {
    run_whole "$(printf '/dev/sdz\n2G\nYES\n')" '
        esp_list()  { printf "/dev/sdz1 AAAA-BBBB 104857600\n"; }
        esp_probe() { printf "fallback yes\nkind grub\nowngrub no\n"; }'
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"/dev/sdz1"*"boot partition"* ]]
    [[ "$output" != *"sgdisk --zap-all"* ]]
}

# An ESP with a GRUB directory but no fallback binary is still another system's
# boot partition.
@test "whole-disk mode refuses an ESP carrying a vendor bootloader directory" {
    run_whole "$(printf '/dev/sdz\n2G\nYES\n')" '
        esp_list()  { printf "/dev/sdz1 AAAA-BBBB 104857600\n"; }
        esp_probe() { printf "fallback no\nkind none\nowngrub no\nefipath /EFI/Microsoft/Boot/bootmgfw.efi\n"; }'
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"/dev/sdz1"*"boot partition"* ]]
    [[ "$output" != *"sgdisk --zap-all"* ]]
}

# An ESP that is formatted but could not be read cannot rule a bootloader out,
# and this is the gate in front of --zap-all. esp_probe reports that as
# "kind unreadable"; collapsing it into "nothing there" is the exact fail-open
# that was found and fixed on the removable-policy path.
@test "whole-disk mode refuses an ESP it could not read" {
    run_whole "$(printf '/dev/sdz\n2G\nYES\n')" '
        esp_list()  { printf "/dev/sdz1 AAAA-BBBB 104857600\n"; }
        esp_probe() { printf "fallback unknown\nkind unreadable\n"; }'
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"/dev/sdz1"* ]]
    [[ "$output" != *"sgdisk --zap-all"* ]]
}

# A partition carrying the ESP type GUID that was never formatted holds no
# bootloader, and refusing it would leave an operator with no way to reuse a
# disk this installer itself half-carved.
@test "whole-disk mode does not refuse an ESP-typed partition that was never formatted" {
    run_whole "$(printf '/dev/sdz\n2G\nYES\n')" '
        __esp_unformatted=/dev/sdz1
        esp_list()  { printf "/dev/sdz1 - 104857600\n"; }
        esp_probe() { echo "ESP_PROBE_RAN"; printf "fallback unknown\nkind unreadable\n"; }'
    [ "$status" -eq 0 ]
    # Not probed at all: the filesystem signature is empty, so there is nothing
    # to mount and nothing a probe could have found.
    [[ "$output" != *"ESP_PROBE_RAN"* ]]
    [[ "$output" == *"sgdisk --zap-all /dev/sdz"* ]]
}

# Custom mode shows the partition inventory, the firmware's boot entries and a
# three-way ledger before its identical gate. Whole-disk mode is the one that
# destroys a partition table, and it showed none of it.
@test "whole-disk mode shows the disk's contents and a ledger before the gate" {
    run_whole "$(printf '/dev/sdz\n2G\nYES\n')"
    [ "$status" -eq 0 ]
    # The target's real contents, not just NAME/SIZE/MODEL.
    [[ "$output" == *"/dev/sdz2  99.9G ext4  root   /"* ]]
    [[ "$output" == *"0001 Windows Boot Manager"* ]]
    [[ "$output" == *"WILL BE FORMATTED"* ]]
    [[ "$output" == *"NOT TOUCHED"* ]]
    # Every partition on the target is destroyed; the other disk's are not.
    [[ "$output" == *"/dev/sdz1"* ]]
    [[ "$output" == *"/dev/sdy3"* ]]
    # ...and all of it before the one command that destroys the table.
    local before after
    before=$(printf '%s\n' "$output" | grep -n 'WILL BE FORMATTED' | head -1 | cut -d: -f1)
    after=$(printf '%s\n' "$output" | grep -n 'zap-all' | head -1 | cut -d: -f1)
    [ -n "$before" ] && [ -n "$after" ] && [ "$before" -lt "$after" ]
}
