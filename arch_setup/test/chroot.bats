#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/system.sh"
    source "${BATS_TEST_DIRNAME}/../lib/chroot.sh"
    TMP="$BATS_TEST_TMPDIR"
    mkdir -p "$TMP/root"
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

# --- require_vars ----------------------------------------------------------

@test "require_vars passes when every name is set and non-empty" {
    A=1 B=2
    run require_vars A B
    [ "$status" -eq 0 ]
}

@test "require_vars names every missing or empty value at once" {
    A=1 B=""
    unset C
    run require_vars A B C
    [ "$status" -ne 0 ]
    [[ "$output" == *"B"* ]]
    [[ "$output" == *"C"* ]]
}

@test "require_vars survives set -u on an unset name" {
    run bash -c "set -euo pipefail
        $(declare -f error); RED=; RESET=
        $(declare -f require_vars)
        require_vars NOPE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOPE"* ]]
    [[ "$output" != *"unbound variable"* ]]
}

# --- locale_gen_uncomment --------------------------------------------------

make_locale_gen() {
    printf '#en_US.UTF-8 UTF-8  \n#en_US ISO-8859-1  \n#pt_BR.UTF-8 UTF-8  \n' \
        > "$TMP/locale.gen"
}

@test "locale_gen_uncomment uncomments exactly the requested entry" {
    make_locale_gen
    locale_gen_uncomment "$TMP/locale.gen" en_US.UTF-8
    grep -q '^en_US.UTF-8 UTF-8' "$TMP/locale.gen"
    grep -q '^#en_US ISO-8859-1' "$TMP/locale.gen"
    grep -q '^#pt_BR.UTF-8 UTF-8' "$TMP/locale.gen"
}

@test "locale_gen_uncomment is idempotent" {
    make_locale_gen
    locale_gen_uncomment "$TMP/locale.gen" en_US.UTF-8
    first=$(cat "$TMP/locale.gen")
    locale_gen_uncomment "$TMP/locale.gen" en_US.UTF-8
    [ "$first" = "$(cat "$TMP/locale.gen")" ]
}

# locale-gen exits 0 having generated nothing when the entry is absent, and
# /etc/locale.conf then names a locale that does not exist on the system.
@test "locale_gen_uncomment fails when the locale is absent, leaving the file alone" {
    make_locale_gen
    before=$(cat "$TMP/locale.gen")
    run locale_gen_uncomment "$TMP/locale.gen" nl_NL.UTF-8
    [ "$status" -ne 0 ]
    [[ "$output" == *"nl_NL.UTF-8"* ]]
    [ "$before" = "$(cat "$TMP/locale.gen")" ]
}

# 'en_US.UTF-8' interpolated into a regex has '.' as a wildcard.
@test "locale_gen_uncomment does not treat . in the locale as a wildcard" {
    printf '#en_USxUTF-8 UTF-8  \n' > "$TMP/locale.gen"
    run locale_gen_uncomment "$TMP/locale.gen" en_US.UTF-8
    [ "$status" -ne 0 ]
    [[ "$output" == *"en_US.UTF-8"* ]]
    grep -q '^#en_USxUTF-8' "$TMP/locale.gen"
}

@test "locale_gen_uncomment keeps the file's own permissions" {
    make_locale_gen
    chmod 644 "$TMP/locale.gen"
    locale_gen_uncomment "$TMP/locale.gen" en_US.UTF-8
    [ "$(stat -c '%a' "$TMP/locale.gen")" = "644" ]
    [ "$(ls "$TMP" | grep -c '^locale.gen')" -eq 1 ]
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
    ! grep -qE 'echo .*\$(ROOT|USER)_PASSWORD[^|]*$' "$TMP/root/setup.sh"
    grep -q 'chpasswd' "$TMP/root/setup.sh"
}

# Every helper the body calls must actually be in the file: `declare -f` on a
# function that was never sourced prints nothing and returns 1, which yields a
# script that dies inside the chroot with "hooks_line: command not found".
@test "generated chroot script defines every helper its body calls" {
    chroot_write_script "$TMP/root/setup.sh"
    local fn
    for fn in hooks_line modules_line grub_cmdline_add needs_grub_install \
              require_vars locale_gen_uncomment; do
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
    ! grep -qE '\$\{?(CYAN|BOLD)\b' "$TMP/root/setup.sh"
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
    [ -n "$helpers" ]
    ! grep -qE 'mkinitcpio|grub-install|grub-mkconfig|useradd|usermod|chpasswd|systemctl|locale-gen|hwclock|visudo|/etc/' <<< "$helpers"

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

# /etc/sudoers is the one file where a bad edit locks every user out of sudo.
@test "generated chroot script validates its sudoers change before trusting it" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'visudo -cf /etc/sudoers.d/10-wheel' "$TMP/root/setup.sh"
    ! grep -q 'sed -i .* /etc/sudoers$' "$TMP/root/setup.sh"
}
