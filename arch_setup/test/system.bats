#!/usr/bin/env bats

load helpers

DEFAULT_HOOKS='HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)'

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/system.sh"
    TMP="$BATS_TEST_TMPDIR"
}

@test "hooks_line adds microcode after autodetect when not encrypting" {
    run hooks_line "$DEFAULT_HOOKS" false
    [[ "$output" == *"autodetect microcode modconf"* ]]
    [[ "$output" != *"encrypt"* ]]
}

@test "hooks_line inserts encrypt immediately before filesystems" {
    run hooks_line "$DEFAULT_HOOKS" true
    [[ "$output" == *"block encrypt filesystems fsck"* ]]
}

@test "hooks_line is idempotent" {
    first=$(hooks_line "$DEFAULT_HOOKS" true)
    second=$(hooks_line "$first" true)
    [ "$first" = "$second" ]
}

@test "hooks_line keeps keyboard before block so the passphrase can be typed" {
    out=$(hooks_line "$DEFAULT_HOOKS" true)
    kb=${out%%block*}
    [[ "$kb" == *"keyboard"* ]]
}

@test "hooks_line fails when filesystems is absent" {
    run hooks_line 'HOOKS=(base udev autodetect)' true
    [ "$status" -ne 0 ]
}

@test "modules_line adds btrfs to an empty MODULES" {
    run modules_line 'MODULES=()' btrfs
    [ "$output" = 'MODULES=(btrfs)' ]
}

@test "modules_line appends without duplicating" {
    run modules_line 'MODULES=(btrfs)' btrfs nvidia
    [ "$output" = 'MODULES=(btrfs nvidia)' ]
}

@test "grub_cmdline_add appends to an empty cmdline" {
    printf 'GRUB_CMDLINE_LINUX=""\n' > "$TMP/grub"
    grub_cmdline_add "$TMP/grub" "nvidia-drm.modeset=1"
    grep -q 'GRUB_CMDLINE_LINUX="nvidia-drm.modeset=1"' "$TMP/grub"
}

@test "grub_cmdline_add preserves existing entries" {
    printf 'GRUB_CMDLINE_LINUX="quiet"\n' > "$TMP/grub"
    grub_cmdline_add "$TMP/grub" "nvidia-drm.modeset=1"
    grep -q 'GRUB_CMDLINE_LINUX="quiet nvidia-drm.modeset=1"' "$TMP/grub"
}

@test "grub_cmdline_add is idempotent" {
    printf 'GRUB_CMDLINE_LINUX=""\n' > "$TMP/grub"
    grub_cmdline_add "$TMP/grub" "nvidia-drm.modeset=1"
    grub_cmdline_add "$TMP/grub" "nvidia-drm.modeset=1"
    [ "$(grep -c 'nvidia-drm.modeset=1' "$TMP/grub")" -eq 1 ]
}

@test "grub_cmdline_add replaces a changed value for the same key" {
    printf 'GRUB_CMDLINE_LINUX="cryptdevice=UUID=old:cryptroot"\n' > "$TMP/grub"
    grub_cmdline_add "$TMP/grub" "cryptdevice=UUID=new:cryptroot"
    grep -q 'cryptdevice=UUID=new:cryptroot' "$TMP/grub"
    assert_absent 'UUID=old' "$TMP/grub"
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

# The callers that matter run under `set -u`, where a bare ${!name} on an
# unset name aborts instead of reporting.
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

# 'en_US.UTF-8' interpolated into a regex has '.' as a wildcard, which leaves
# '#en_USX.UTF-8' alone but does uncomment '#en_USxUTF-8'.
@test "locale_gen_uncomment does not treat . in the locale as a wildcard" {
    printf '#en_USxUTF-8 UTF-8  \n' > "$TMP/locale.gen"
    run locale_gen_uncomment "$TMP/locale.gen" en_US.UTF-8
    [ "$status" -ne 0 ]
    [[ "$output" == *"en_US.UTF-8"* ]]
    grep -q '^#en_USxUTF-8' "$TMP/locale.gen"
}

@test "locale_gen_uncomment keeps the file's own permissions and leaves no temp file" {
    make_locale_gen
    chmod 644 "$TMP/locale.gen"
    locale_gen_uncomment "$TMP/locale.gen" en_US.UTF-8
    [ "$(stat -c '%a' "$TMP/locale.gen")" = "644" ]
    [ "$(ls "$TMP" | grep -c '^locale.gen')" -eq 1 ]
}

@test "locale_gen_uncomment keeps a non-default mode too" {
    make_locale_gen
    chmod 640 "$TMP/locale.gen"
    locale_gen_uncomment "$TMP/locale.gen" en_US.UTF-8
    [ "$(stat -c '%a' "$TMP/locale.gen")" = "640" ]
}

# --- link_timezone ---------------------------------------------------------

make_zoneinfo() {
    mkdir -p "$TMP/zoneinfo/America"
    printf 'TZif\n' > "$TMP/zoneinfo/America/Sao_Paulo"
}

@test "link_timezone links a real zone" {
    make_zoneinfo
    link_timezone "$TMP/zoneinfo" America/Sao_Paulo "$TMP/localtime"
    [ "$(readlink "$TMP/localtime")" = "$TMP/zoneinfo/America/Sao_Paulo" ]
}

# 'America' is the obvious half-typed form of the default 'America/Sao_Paulo',
# and it is a directory: -e would accept it, leaving the clock on UTC.
@test "link_timezone refuses a zone that is a directory" {
    make_zoneinfo
    run link_timezone "$TMP/zoneinfo" America "$TMP/localtime"
    [ "$status" -ne 0 ]
    [[ "$output" == *"America"* ]]
    [ ! -e "$TMP/localtime" ]
}

@test "link_timezone refuses a zone that does not exist" {
    make_zoneinfo
    run link_timezone "$TMP/zoneinfo" Mars/Olympus "$TMP/localtime"
    [ "$status" -ne 0 ]
    [ ! -e "$TMP/localtime" ]
}

# Without -n, ln dereferences an existing symlink-to-directory and writes the
# new link *inside* it -- so a localtime left pointing at a directory makes
# every later run die on this line until someone removes it by hand.
@test "link_timezone recovers when localtime already points at a directory" {
    make_zoneinfo
    ln -s "$TMP/zoneinfo/America" "$TMP/localtime"
    link_timezone "$TMP/zoneinfo" America/Sao_Paulo "$TMP/localtime"
    [ "$(readlink "$TMP/localtime")" = "$TMP/zoneinfo/America/Sao_Paulo" ]
    [ ! -e "$TMP/zoneinfo/America/Sao_Paulo/Sao_Paulo" ]
    [ "$(ls "$TMP/zoneinfo/America")" = "Sao_Paulo" ]
}

@test "link_timezone is idempotent" {
    make_zoneinfo
    link_timezone "$TMP/zoneinfo" America/Sao_Paulo "$TMP/localtime"
    link_timezone "$TMP/zoneinfo" America/Sao_Paulo "$TMP/localtime"
    [ "$(readlink "$TMP/localtime")" = "$TMP/zoneinfo/America/Sao_Paulo" ]
}

@test "detect_ucode returns a real package name" {
    run detect_ucode
    [[ "$output" == "intel-ucode" || "$output" == "amd-ucode" ]]
}

@test "gpu_packages maps nvidia to the open dkms modules" {
    run gpu_packages nvidia
    [[ "$output" == *"nvidia-open-dkms"* ]]
    [[ "$output" == *"nvidia-utils"* ]]
}

@test "gpu_packages maps none to nothing" {
    run gpu_packages none
    [ -z "$output" ]
}

@test "grub_cmdline_add fails loudly when the line is absent" {
    printf 'GRUB_TIMEOUT=5\n' > "$TMP/grub"
    run grub_cmdline_add "$TMP/grub" "cryptdevice=UUID=abc:cryptroot"
    [ "$status" -ne 0 ]
    assert_absent 'cryptdevice' "$TMP/grub"
}

@test "grub_cmdline_add fails loudly on a single-quoted line" {
    printf "GRUB_CMDLINE_LINUX='quiet'\n" > "$TMP/grub"
    run grub_cmdline_add "$TMP/grub" "cryptdevice=UUID=abc:cryptroot"
    [ "$status" -ne 0 ]
}

@test "grub_cmdline_add fails loudly rather than corrupting on a sed metacharacter" {
    printf 'GRUB_CMDLINE_LINUX="quiet"\n' > "$TMP/grub"
    run grub_cmdline_add "$TMP/grub" "foo=a&b"
    [ "$status" -ne 0 ]
    [ "$(cat "$TMP/grub")" = 'GRUB_CMDLINE_LINUX="quiet"' ]
}

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

@test "needs_grub_install is true when the EFI stub is absent" {
    run needs_grub_install "$TMP/nonexistent-esp"
    [ "$status" -eq 0 ]
}

@test "needs_grub_install is false when the EFI stub exists" {
    mkdir -p "$TMP/esp/EFI/GRUB"
    touch "$TMP/esp/EFI/GRUB/grubx64.efi"
    run needs_grub_install "$TMP/esp"
    [ "$status" -eq 1 ]
}

@test "setup_shell fails when the target user cannot be determined" {
    USER="" SUDO_USER="" run setup_shell --check-only
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot determine the target user"* ]]
}
