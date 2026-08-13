#!/usr/bin/env bats
#
# install.sh is an orchestrator: prompts, ordering and destructive commands.
# Most of it cannot be tested without a disk, and nothing here pretends
# otherwise -- no phase_* function is called. What is testable is everything
# that was pulled out of the prompt loops into named predicates, plus the
# structural facts that keep the file safe to source.

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
@test "sourcing install.sh starts no phase, arms no EXIT trap and says nothing" {
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

# --- locale_listed ---------------------------------------------------------

locale_fixture() {
    cat > "${TMP}/locale.gen" <<'GEN'
# Configuration file for locale-gen
#
#en_GB.UTF-8 UTF-8
#en_US.UTF-8 UTF-8
pt_BR.UTF-8 UTF-8
#en_USxUTF-8 ISO-8859-1
GEN
}

@test "locale_listed finds both a commented and an uncommented entry" {
    locale_fixture
    run in_install "locale_listed '${TMP}/locale.gen' en_US.UTF-8"
    [ "$status" -eq 0 ]
    run in_install "locale_listed '${TMP}/locale.gen' pt_BR.UTF-8"
    [ "$status" -eq 0 ]
}

# The same trap locale_gen_uncomment documents: in a regex the '.' of
# 'en_US.UTF-8' is a wildcard, so a regex match accepts an 'en_USxUTF-8' line.
# Waving that through at the prompt would be worse than not checking at all --
# it would approve exactly the value locale_gen_uncomment then rejects in the
# chroot, in phase 5, with the disk wiped behind it.
#
# The fixture deliberately omits the exact line: with both present the awk
# stops at the exact one first and a regex implementation passes anyway. That
# is how the first draft of this test passed against a regex version.
@test "locale_listed compares as a fixed string, not a regex" {
    cat > "${TMP}/wildcard.gen" <<'GEN'
# Configuration file for locale-gen
#en_USxUTF-8 ISO-8859-1
pt_BR.UTF-8 UTF-8
GEN
    run in_install "locale_listed '${TMP}/wildcard.gen' 'en_US.UTF-8'"
    [ "$status" -eq 1 ]
    # The literal line is still found, so this is not just "rejects everything".
    run in_install "locale_listed '${TMP}/wildcard.gen' 'en_USxUTF-8'"
    [ "$status" -eq 0 ]
}

@test "locale_listed rejects a locale the file does not list" {
    locale_fixture
    run in_install "locale_listed '${TMP}/locale.gen' 'xx_YY.UTF-8'"
    [ "$status" -eq 1 ]
}

# Status 2 is "cannot answer", and phase_locale accepts the value unchecked on
# a 2 rather than looping on a question it can never answer. Collapsing this
# into 1 would make an installer that cannot read /etc/locale.gen reject every
# locale the operator types.
@test "locale_listed says 'cannot answer', not 'absent', for an unreadable file" {
    run in_install "locale_listed '${TMP}/no-such-locale.gen' en_US.UTF-8"
    [ "$status" -eq 2 ]
}

# --- keymap_listed ---------------------------------------------------------

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

# Not a unit test: it asserts the real probe works on the host running the
# suite. A host with neither localectl nor /usr/share/kbd is legitimate, and is
# what status 2 exists for, so it skips rather than fails.
@test "the live host's keymap list contains us" {
    run in_install 'list_keymaps'
    [ "$status" -eq 0 ] || skip "this host cannot enumerate keymaps"
    run in_install 'keymap_listed us'
    [ "$status" -eq 0 ]
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
