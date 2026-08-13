#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/system.sh"
    source "${BATS_TEST_DIRNAME}/../lib/chroot.sh"
    TMP="$BATS_TEST_TMPDIR"
    mkdir -p "$TMP/root"
}

# A bare `! grep ...` mid-test is INERT: bash exempts !-inverted pipelines
# from set -e, so it only ever fails a test when it happens to be the last
# command in the body. Every negative assertion goes through this instead --
# a function returning non-zero is a plain command, and does stop the test.
assert_absent() {
    local pattern=$1 file=$2
    if grep -qE -- "$pattern" "$file"; then
        printf 'unexpectedly found /%s/ in %s:\n' "$pattern" "$file" >&2
        grep -nE -- "$pattern" "$file" >&2
        return 1
    fi
}

# --- chroot_write_config ---------------------------------------------------

@test "chroot_write_config quotes every value" {
    chroot_write_config "$TMP/root/config.sh" \
        HOSTNAME_VAR=box USERNAME_VAR=me TIMEZONE=America/Sao_Paulo
    grep -q '^HOSTNAME_VAR="box"$' "$TMP/root/config.sh"
    grep -q '^TIMEZONE="America/Sao_Paulo"$' "$TMP/root/config.sh"
}

@test "chroot_write_config produces a file bash can source" {
    chroot_write_config "$TMP/root/config.sh" A=1 B="two words"
    run bash -c "source '$TMP/root/config.sh'; echo \"\$A-\$B\""
    [ "$output" = "1-two words" ]
}

@test "chroot_write_config makes the file 600" {
    chroot_write_config "$TMP/root/config.sh" A=1
    [ "$(stat -c '%a' "$TMP/root/config.sh")" = "600" ]
}

# The chroot script sources this file as root inside the new system, so a
# value that closes the double quote is arbitrary code execution there.
# LOCALE and KEYMAP arrive from a bare `ask` with no validation, so a typo
# reaches this path, not only malice.
@test "chroot_write_config refuses a value that would escape its quoting" {
    local bad
    for bad in 'box"; touch '"$TMP"'/PWNED; x="' 'a`id`b' 'a$(id)b' 'a\b'; do
        run chroot_write_config "$TMP/root/config.sh" "HOSTNAME_VAR=${bad}"
        [ "$status" -ne 0 ]
        [[ "$output" == *"HOSTNAME_VAR"* ]]
        [ ! -e "$TMP/root/config.sh" ]
    done
    [ ! -e "$TMP/PWNED" ]
}

@test "chroot_write_config refuses a value containing a newline" {
    run chroot_write_config "$TMP/root/config.sh" "$(printf 'KEYMAP=us\nEVIL=1')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"KEYMAP"* ]]
    [ ! -e "$TMP/root/config.sh" ]
}

# All-or-nothing: a rejected pair must not leave the earlier, accepted pairs
# on disk, or the chroot sources a config that is missing values it needs.
@test "chroot_write_config writes nothing at all when a later value is rejected" {
    run chroot_write_config "$TMP/root/config.sh" A=1 'B=oops"' C=3
    [ "$status" -ne 0 ]
    [[ "$output" == *"B"* ]]
    [ ! -e "$TMP/root/config.sh" ]
}

@test "chroot_write_config refuses a key that is not a shell identifier" {
    run chroot_write_config "$TMP/root/config.sh" '2FA=x'
    [ "$status" -ne 0 ]
    [[ "$output" == *"2FA"* ]]
    [ ! -e "$TMP/root/config.sh" ]
}

@test "chroot_write_config refuses an argument that is not KEY=VALUE" {
    run chroot_write_config "$TMP/root/config.sh" JUSTAKEY
    [ "$status" -ne 0 ]
    [[ "$output" == *"KEY=VALUE"* ]]
    [ ! -e "$TMP/root/config.sh" ]
}

# lib/ files are sourced, not exec'd: a umask left at 077 would tighten every
# file the rest of install.sh creates.
@test "chroot_write_config does not leak its umask to the caller" {
    umask 0022
    chroot_write_config "$TMP/root/config.sh" A=1
    [ "$(umask)" = "0022" ]
}

@test "chroot_write_config fails loudly when the file cannot be written" {
    mkdir -p "$TMP/ro"
    chmod 555 "$TMP/ro"
    run chroot_write_config "$TMP/ro/config.sh" A=1
    [ "$status" -ne 0 ]
    # Both halves matter: a bare chmod/redirect failure names the path but not
    # the function, and a missing function names neither.
    [[ "$output" == *"chroot_write_config"* ]]
    [[ "$output" == *"$TMP/ro/config.sh"* ]]
    chmod 755 "$TMP/ro"
}

# --- chroot_write_script ---------------------------------------------------

@test "generated chroot script is valid bash" {
    chroot_write_script "$TMP/root/setup.sh"
    run bash -n "$TMP/root/setup.sh"
    [ "$status" -eq 0 ]
}

@test "generated chroot script is executable and self-contained" {
    chroot_write_script "$TMP/root/setup.sh"
    [ -x "$TMP/root/setup.sh" ]
    grep -q 'source /root/chroot_config.sh' "$TMP/root/setup.sh"
}

@test "generated chroot script guards grub-install on the EFI stub" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'grubx64.efi' "$TMP/root/setup.sh"
}

@test "generated chroot script never echoes a password" {
    chroot_write_script "$TMP/root/setup.sh"
    assert_absent 'echo .*\$(ROOT|USER)_PASSWORD[^|]*$' "$TMP/root/setup.sh"
    grep -q 'chpasswd' "$TMP/root/setup.sh"
}

# Stronger than the pattern above, which only catches `echo`: every line that
# touches a decoded password must be either its own assignment or a pipe into
# chpasswd. Anything else -- an info line, a here-doc, a stray redirect --
# puts a root password into the install log.
@test "generated chroot script only ever pipes a password into chpasswd" {
    chroot_write_script "$TMP/root/setup.sh"
    offenders=$(grep -nE '\$\{?(ROOT|USER)_PASSWORD' "$TMP/root/setup.sh" \
                | grep -vE '^[0-9]+:(ROOT|USER)_PASSWORD=\$\(printf' \
                | grep -v 'chpasswd' || true)
    [ -z "$offenders" ]
}

# Every helper the body calls must actually be in the file: `declare -f` on a
# function that was never sourced prints nothing and returns 1, which yields a
# script that dies inside the chroot with "hooks_line: command not found".
@test "generated chroot script defines every helper its body calls" {
    chroot_write_script "$TMP/root/setup.sh"
    local fn
    for fn in hooks_line modules_line grub_cmdline_add needs_grub_install \
              require_vars locale_gen_uncomment link_timezone; do
        grep -qE "^${fn} \(\)" "$TMP/root/setup.sh"
    done
}

@test "chroot_write_script refuses to write anything when a helper is missing" {
    unset -f hooks_line
    run chroot_write_script "$TMP/root/setup.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"hooks_line"* ]]
    [ ! -e "$TMP/root/setup.sh" ]
    [ -z "$(ls -A "$TMP/root")" ]
}

# The generated script runs under `set -u`, so referencing a colour the
# HEADER does not define is fatal, not cosmetic: it aborts the chroot
# mid-configuration. Any function added to the injection list must therefore
# avoid CYAN and BOLD unless the HEADER grows to define them.
@test "generated chroot script references no colour its header omits" {
    chroot_write_script "$TMP/root/setup.sh"
    assert_absent '\$\{?(CYAN|BOLD)\b' "$TMP/root/setup.sh"
}

# An interrupted install is resumed by re-running the installer; useradd on an
# existing user exits non-zero and `set -e` would abort the whole run.
@test "generated chroot script only calls useradd when the user is absent" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'id -u "\$USERNAME_VAR"' "$TMP/root/setup.sh"
    [ "$(grep -c '^ *useradd ' "$TMP/root/setup.sh")" -eq 1 ]
    grep -qE '^ *else$' "$TMP/root/setup.sh"
}

# base64 is encoding, not encryption: the config must not survive a failed run
# on a machine that still boots.
@test "generated chroot script removes the credential file on every exit path" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -qE "^trap .*rm -f .*chroot_config\.sh.* EXIT$" "$TMP/root/setup.sh"
}

@test "generated chroot script refuses a LUKS_ENABLED that is neither true nor false" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'LUKS_ENABLED' "$TMP/root/setup.sh"
    grep -qE 'true\|false\)' "$TMP/root/setup.sh"
}

# A silent no-op sed on the HOOKS line is an unbootable machine found at
# reboot, and sed exits 0 when its pattern matches nothing.
@test "generated chroot script verifies the mkinitcpio lines it writes" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'grep -qxF "$NEW_HOOKS" /etc/mkinitcpio.conf' "$TMP/root/setup.sh"
    grep -q 'grep -qxF "$NEW_MODULES" /etc/mkinitcpio.conf' "$TMP/root/setup.sh"
}

# The helpers are injected into a script that runs `set -euo pipefail`, but
# every other test in the suite exercises them without it. 'MODULES=()' -- the
# state of a freshly pacstrapped mkinitcpio.conf -- takes modules_line through
# an `A && B` whose A is false, and an unset-array expansion under `set -u`;
# an abort there would leave the initramfs with no btrfs module.
@test "injected helpers still work under the generated script's shell options" {
    chroot_write_script "$TMP/root/setup.sh"
    helpers=$(awk '/^hooks_line \(\)/ { on = 1 }
                   /^# ---- preflight ----$/ { exit }
                   on { print }' "$TMP/root/setup.sh")
    # Guard the extraction rather than trusting it: if that end marker ever
    # moves, this test must fail, not eval the real body on a live machine.
    # Via assert_absent, because a bare `! grep` here is inert under set -e
    # and would wave the whole chroot body straight into the bash -c below.
    [ -n "$helpers" ]
    printf '%s\n' "$helpers" > "$TMP/helpers.sh"
    assert_absent 'mkinitcpio|grub-install|grub-mkconfig|useradd|usermod|chpasswd|systemctl|locale-gen|hwclock|/etc/' \
        "$TMP/helpers.sh"

    run bash -c "set -euo pipefail
        RED=; RESET=
        error() { echo \"[ERROR] \$*\" >&2; }
        ${helpers}
        modules_line 'MODULES=()' btrfs
        hooks_line 'HOOKS=(base udev autodetect block filesystems fsck)' true"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'MODULES=(btrfs)' ]
    [[ "${lines[1]}" == *"block encrypt filesystems"* ]]
}

# Editing /etc/sudoers in place marks a pacman-owned file locally modified,
# buying a .pacnew to reconcile on every sudo upgrade.
@test "generated chroot script uses a sudoers drop-in, not an in-place edit" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'cat > /etc/sudoers.d/10-wheel' "$TMP/root/setup.sh"
    grep -q 'chmod 440 /etc/sudoers.d/10-wheel' "$TMP/root/setup.sh"
    assert_absent 'sed -i .* /etc/sudoers$' "$TMP/root/setup.sh"
}

# The drop-in does nothing at all if /etc/sudoers no longer includes the
# directory, and "the administrator account has no sudo" is not a warning.
@test "generated chroot script treats a missing sudoers includedir as fatal" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -qE 'error ".*includedir.*would have no sudo"' "$TMP/root/setup.sh"
    assert_absent 'warn ".*includedir' "$TMP/root/setup.sh"
}

# install.sh's username regex admits root, bin and nobody. The resume path
# must not hand one of those wheel, a new shell and a new password.
@test "generated chroot script refuses to reconfigure an existing system account" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'EXISTING_UID < 1000' "$TMP/root/setup.sh"
    grep -qF 'is an existing system account' "$TMP/root/setup.sh"
}

# Silently substituting bash on a machine whose dotfiles are built around zsh
# is a worse outcome than stopping with a named cause.
@test "generated chroot script stops rather than substituting a login shell" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -qF 'the pacstrap set should have installed zsh' "$TMP/root/setup.sh"
    assert_absent 'USER_SHELL=/bin/bash' "$TMP/root/setup.sh"
}
