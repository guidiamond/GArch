#!/usr/bin/env bats

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
    ! grep -q 'UUID=old' "$TMP/grub"
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
