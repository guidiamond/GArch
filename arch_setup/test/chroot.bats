#!/usr/bin/env bats

load helpers

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/system.sh"
    source "${BATS_TEST_DIRNAME}/../lib/chroot.sh"
    TMP="$BATS_TEST_TMPDIR"
    mkdir -p "$TMP/root"
}

# Slice the injected helper block out of the artifact into <out>.
#
# Guarded, not trusted: one caller feeds the result to `bash -c`, so if that
# end marker ever moves this must fail rather than hand over the real chroot
# body and reconfigure the developer's machine. assert_absent because a bare
# `! grep` here would be inert under errexit and wave it straight through.
extract_helpers() {
    local artifact=$1 out=$2
    awk '/^hooks_line \(\)/ { on = 1 }
         /^# ---- preflight ----$/ { exit }
         on { print }' "$artifact" > "$out"
    [ -s "$out" ]
    assert_absent 'mkinitcpio|grub-install|grub-mkconfig|useradd|usermod|chpasswd|systemctl|locale-gen|hwclock|sudo|/etc/' \
        "$out"
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

# Under `set -u` ANY variable the HEADER does not define is fatal, not just
# the colours -- ARCH_SETUP_DIR is the live one, since setup_zram,
# setup_lightdm and setup_gpu all reference it and it does not exist in the
# artifact. The injected block references no uppercase variable at all, so
# assert exactly that: a whitelist subsuming CYAN, BOLD, ARCH_SETUP_DIR,
# SUDO_USER, HOME and anything added later. The narrower colour check still
# covers the hand-written body, where uppercase config vars are legitimate
# and a whitelist is not expressible.
@test "generated chroot script references no variable its header omits" {
    chroot_write_script "$TMP/root/setup.sh"
    extract_helpers "$TMP/root/setup.sh" "$TMP/helpers.sh"
    assert_absent '\$\{?[A-Z][A-Z0-9_]*' "$TMP/helpers.sh"
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
# on a machine that still boots. The script itself holds no secret, and
# deleting it on failure would take away the file the reported line number
# refers to -- so it goes only on success.
@test "generated chroot script removes the credential file on every exit path" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -qE "^trap .*rm -f .*chroot_config\.sh.* EXIT$" "$TMP/root/setup.sh"
    assert_absent "^trap .*rm -f .*chroot_setup\.sh.*EXIT" "$TMP/root/setup.sh"
    grep -qE '^rm -f /root/chroot_setup\.sh$' "$TMP/root/setup.sh"
}

# Every guarded path in the helpers returns explicitly and would be reported
# either way. An *unguarded* failure inside one is what needs -E: without it
# the ERR trap does not reach into functions, and grub_cmdline_add's sed -i on
# a read-only /etc/default/grub yields sed's own message and no location at
# all. Driven with the artifact's own options and trap lines, not a copy.
@test "the artifact's ERR trap locates a failure inside an injected helper" {
    chroot_write_script "$TMP/root/setup.sh"
    extract_helpers "$TMP/root/setup.sh" "$TMP/helpers.sh"
    opts=$(grep -m1 '^set -' "$TMP/root/setup.sh")
    errtrap=$(grep -m1 '^trap .* ERR$' "$TMP/root/setup.sh")
    [ -n "$opts" ]
    [ -n "$errtrap" ]

    mkdir -p "$TMP/ro"
    printf 'GRUB_CMDLINE_LINUX="quiet"\n' > "$TMP/ro/grub"
    chmod 444 "$TMP/ro/grub"
    chmod 555 "$TMP/ro"
    run bash -c "${opts}
        RED=; RESET=
        error() { echo \"[ERROR] \$*\" >&2; }
        ${errtrap}
        $(cat "$TMP/helpers.sh")
        grub_cmdline_add '$TMP/ro/grub' quiet=1
        echo SHOULD_NOT_REACH"
    chmod 755 "$TMP/ro"

    [ "$status" -ne 0 ]
    [[ "$output" == *"failed at line"* ]]
    [[ "$output" == *"sed -i"* ]]
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
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
    extract_helpers "$TMP/root/setup.sh" "$TMP/helpers.sh"
    helpers=$(cat "$TMP/helpers.sh")

    run bash -c "set -Eeuo pipefail
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

# --- the generated script's bootloader section ------------------------------

# Slice the bootloader section out of the artifact.
#
# Guarded like extract_helpers above: run_bootloader feeds the result to
# `bash`, so if either marker moves this must fail rather than hand a
# different part of the chroot body to a shell on the developer's machine.
extract_bootloader() {
    local artifact=$1 out=$2
    awk '/^# ---- bootloader ----$/ { on = 1 }
         /^# ---- zram ----$/ { exit }
         on { print }' "$artifact" > "$out"
    [ -s "$out" ]
    grep -q 'grub-mkconfig' "$out"
    assert_absent 'mkinitcpio|useradd|usermod|chpasswd|systemctl|locale-gen|hwclock|zram' \
        "$out"
}

# Run that slice with /etc/default/grub redirected into the test tmpdir and
# the tools it drives replaced by recorders that print their arguments.
#
# Grepping the script text cannot tell "--removable appears in the file" from
# "--removable is passed only when GRUB_REMOVABLE is true", and the second is
# the whole point of the flag: passed unasked it overwrites whatever already
# owns the firmware fallback path. Only executing the block answers that.
#
# grub_cmdline_add/remove are deliberately left real, so the command line
# asserted afterwards is the one the function actually writes.
#
# needs_grub_install is left real too, against a fake ESP: stubbing it would
# hide the argument it is called with, and calling it without the id is
# exactly the bug Task 8 removed from the function itself.
#
# <luks> <removable> <vendor dir to pre-seed on the fake ESP, or "">
#   [pre-seed \EFI\BOOT\BOOTX64.EFI too: "fallback", or ""]
run_bootloader() {
    local luks=$1 removable=$2 preseed=$3 fallback=${4:-}
    local artifact="$TMP/root/setup.sh" slice="$TMP/bootloader.sh"
    local fixture="$TMP/default_grub" esp="$TMP/esp"
    chroot_write_script "$artifact"
    extract_bootloader "$artifact" "$slice"
    # A test that wants to start from a non-empty grub config seeds the file
    # itself; `run` subshells this function, so nothing set here escapes it.
    [ -f "$fixture" ] || printf 'GRUB_CMDLINE_LINUX=""\n' > "$fixture"
    mkdir -p "$esp"
    if [ -n "$preseed" ]; then
        mkdir -p "${esp}/EFI/${preseed}"
        touch "${esp}/EFI/${preseed}/grubx64.efi"
    fi
    # Separate from $preseed rather than "$preseed = BOOT": the fallback is a
    # named binary in EFI/BOOT, not a grubx64.efi, and the two are pre-seeded
    # together by the case that proves they are told apart.
    if [ -n "$fallback" ]; then
        mkdir -p "${esp}/EFI/BOOT"
        touch "${esp}/EFI/BOOT/BOOTX64.EFI"
    fi
    sed -i -e "s|/etc/default/grub|${fixture}|g" -e "s|/boot|${esp}|g" "$slice"
    # Nothing may still address a real system path once the rewrite is done.
    assert_absent '/etc/default/grub|(^|[ =])/boot' "$slice"
    # `env`, not a prefix assignment: a comment cannot be put between a prefix
    # assignment and its command without silently turning the assignments into
    # ordinary locals, which the block then does not see.
    #
    # Same shell options as the generated script's own header, because a block
    # that only survives with errexit off is not one the chroot survives.
    env LUKS_ENABLED="$luks" GRUB_REMOVABLE="$removable" BOOTLOADER_ID=ARCH_WORK \
        LUKS_UUID=1111-2222 \
        NEW_HOOKS='HOOKS=(base udev autodetect modconf block encrypt filesystems fsck)' \
        bash -c "
        set -Eeuo pipefail
        source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
        source '${BATS_TEST_DIRNAME}/../lib/system.sh'
        pacman() { echo \"PACMAN \$*\"; }
        grub-install() { echo \"GRUB-INSTALL \$*\"; }
        grub-mkconfig() { echo \"GRUB-MKCONFIG \$*\"; }
        source '${slice}'
    "
}

@test "generated script installs grub under the configured bootloader id" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'bootloader-id="${BOOTLOADER_ID}"' "$TMP/root/setup.sh"
    assert_absent 'bootloader-id=GRUB' "$TMP/root/setup.sh"
}

@test "generated script enables os-prober" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'GRUB_DISABLE_OS_PROBER=false' "$TMP/root/setup.sh"
    assert_absent 'GRUB_DISABLE_OS_PROBER=true' "$TMP/root/setup.sh"
}

# The os-prober package is a menu convenience. Aborting the install for it
# after pacstrap already succeeded would leave a machine with no bootloader
# over a cosmetic failure, which is the opposite of this file's own rule.
@test "generated script does not abort when os-prober cannot be installed" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -q 'if pacman -S --needed --noconfirm os-prober; then' "$TMP/root/setup.sh"
    grep -qF 'os-prober unavailable' "$TMP/root/setup.sh"
}

# The os-prober stanza is INSERTED into the bootloader section, not a
# replacement for it. Replacing the whole section deletes the crypt cmdline
# and yields an encrypted install that boots to a rescue shell -- with every
# other test in this file still green.
@test "generated script still writes the LUKS kernel command line" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -qF 'root=/dev/mapper/cryptroot' "$TMP/root/setup.sh"
    grep -qF 'grub_cmdline_remove /etc/default/grub cryptdevice' "$TMP/root/setup.sh"
    grep -qF 'grub_cmdline_remove /etc/default/grub rd.luks.name' "$TMP/root/setup.sh"
    grep -qF 'grub_cmdline_add /etc/default/grub "$CRYPT_PARAM"' "$TMP/root/setup.sh"
}

# The behavioural half of the test above: not "the text is present" but "the
# kernel command line the block leaves behind can unlock and mount the root".
@test "bootloader section puts the crypt parameters on the kernel command line" {
    run run_bootloader true false ""
    [ "$status" -eq 0 ]
    grep -qF 'cryptdevice=UUID=1111-2222:cryptroot' "$TMP/default_grub"
    grep -qF 'root=/dev/mapper/cryptroot' "$TMP/default_grub"
}

@test "bootloader section leaves the kernel command line alone without LUKS" {
    run run_bootloader false false ""
    [ "$status" -eq 0 ]
    assert_absent 'cryptdevice|rd\.luks\.name|/dev/mapper/cryptroot' "$TMP/default_grub"
}

@test "bootloader section passes --removable only when GRUB_REMOVABLE is true" {
    run run_bootloader false true ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"GRUB-INSTALL "*"--removable"* ]]
}

@test "bootloader section omits --removable when GRUB_REMOVABLE is false" {
    run run_bootloader false false ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"GRUB-INSTALL "* ]]
    [[ "$output" != *"--removable"* ]]
}

@test "bootloader section installs under the configured id, not GRUB" {
    run run_bootloader false false ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"--bootloader-id=ARCH_WORK"* ]]
}

@test "bootloader section skips grub-install when our own id is already there" {
    run run_bootloader false false ARCH_WORK
    [ "$status" -eq 0 ]
    [[ "$output" != *"GRUB-INSTALL"* ]]
    [[ "$output" == *"GRUB-MKCONFIG"* ]]
}

# The shared-ESP case. Somebody else's GRUB in EFI/GRUB must not be read as
# ours: skipping grub-install here leaves this install with no binary of its
# own, while grub-mkconfig below still writes the grub.cfg their binary loads.
@test "bootloader section installs anyway when only a foreign id is present" {
    run run_bootloader false false GRUB
    [ "$status" -eq 0 ]
    [[ "$output" == *"--bootloader-id=ARCH_WORK"* ]]
}

# The removable half of the same question. --removable writes
# \EFI\BOOT\BOOTX64.EFI and no vendor directory at all, so a vendor directory
# on the ESP says nothing about whether this install has a bootloader -- and
# reading it as "already installed" skips grub-install, leaving the fallback
# path, which is the only path a removable install boots from, untouched.
@test "bootloader section installs anyway under --removable when only a vendor dir is present" {
    run run_bootloader false true ARCH_WORK ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"GRUB-INSTALL "*"--removable"* ]]
}

@test "bootloader section skips grub-install under --removable once the fallback binary is there" {
    run run_bootloader false true "" fallback
    [ "$status" -eq 0 ]
    [[ "$output" != *"GRUB-INSTALL"* ]]
    [[ "$output" == *"GRUB-MKCONFIG"* ]]
}

# The skip message names the vendor id, which under --removable is not what is
# on the ESP: the operator reading "GRUB ARCH_WORK already installed" goes
# looking for an EFI/ARCH_WORK that does not exist.
@test "bootloader section names the fallback path when it skips a removable install" {
    run run_bootloader false true "" fallback
    [ "$status" -eq 0 ]
    [[ "$output" == *'\EFI\BOOT\BOOTX64.EFI'* ]]
}

@test "bootloader section still skips a non-removable install by its vendor id" {
    # The control for the pair above: same harness, removable off, and the
    # vendor directory is once again the thing that decides.
    run run_bootloader false false ARCH_WORK fallback
    [ "$status" -eq 0 ]
    [[ "$output" != *"GRUB-INSTALL"* ]]
}

@test "bootloader section passes GRUB_REMOVABLE to needs_grub_install" {
    chroot_write_script "$TMP/root/setup.sh"
    grep -qF 'needs_grub_install /boot "${BOOTLOADER_ID}" "${GRUB_REMOVABLE}"' \
        "$TMP/root/setup.sh"
}

@test "bootloader section appends the os-prober switch when grub has none" {
    run run_bootloader false false ""
    [ "$status" -eq 0 ]
    grep -qxF 'GRUB_DISABLE_OS_PROBER=false' "$TMP/default_grub"
}

# A grub config that already disables os-prober must be rewritten, not have a
# second, contradictory line appended after it.
@test "bootloader section rewrites an existing os-prober switch in place" {
    printf 'GRUB_CMDLINE_LINUX=""\nGRUB_DISABLE_OS_PROBER=true\n' > "$TMP/default_grub"
    run run_bootloader false false ""
    [ "$status" -eq 0 ]
    [ "$(grep -c '^GRUB_DISABLE_OS_PROBER=' "$TMP/default_grub")" -eq 1 ]
    grep -qxF 'GRUB_DISABLE_OS_PROBER=false' "$TMP/default_grub"
}

# --- the generated script's preflight ---------------------------------------

# Slice and run the preflight section only. It reads its config and decodes
# two base64 blobs and touches nothing else, so it is safe to execute here --
# and executing it is the only way to show a guard actually stops the run
# rather than merely appearing in the file.
#
# KEY=VALUE... ; every key left out is simply unset for the run.
run_preflight() {
    local artifact="$TMP/root/setup.sh" slice="$TMP/preflight.sh" assign=()
    local kv
    chroot_write_script "$artifact"
    awk '/^# ---- preflight ----$/ { on = 1 }
         /^# ---- time, locale, hostname ----$/ { exit }
         on { print }' "$artifact" > "$slice"
    [ -s "$slice" ]
    grep -q 'require_vars' "$slice"
    assert_absent 'grub-install|mkinitcpio|useradd|chpasswd|systemctl' "$slice"
    for kv in "$@"; do assign+=("$kv"); done
    # `env` rather than a prefix assignment, and the generated script's own
    # shell options: under `set -u` an omitted key has to be genuinely unset
    # for the refusal under test to be the one the chroot would hit.
    env "${assign[@]}" bash -c "
        set -Eeuo pipefail
        source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
        source '${BATS_TEST_DIRNAME}/../lib/system.sh'
        source '${slice}'
        echo PREFLIGHT_OK
    "
}

# Every key the preflight needs, with LUKS off. Callers word-split this on
# purpose -- one KEY=VALUE per word -- and drop or override a line with grep
# to build the case they want. (run.sh does not shellcheck .bats files, so
# there is no SC2046 to disable here; this comment is the whole warning.)
preflight_env() {
    printf '%s\n' HOSTNAME_VAR=box USERNAME_VAR=me TIMEZONE=UTC \
        LOCALE=en_US.UTF-8 KEYMAP=us LUKS_ENABLED=false \
        ROOT_PASS_B64=cGFzcw== USER_PASS_B64=cGFzcw== \
        BOOTLOADER_ID=ARCH_WORK GRUB_REMOVABLE=false
}

# The control: proves run_preflight can distinguish a pass from a refusal, so
# the two cases below are not both passing on a broken harness.
@test "preflight accepts a complete config" {
    run run_preflight $(preflight_env)
    [ "$status" -eq 0 ]
    [[ "$output" == *"PREFLIGHT_OK"* ]]
}

@test "preflight refuses a missing bootloader id" {
    run run_preflight $(preflight_env | grep -v '^BOOTLOADER_ID=')
    [ "$status" -ne 0 ]
    [[ "$output" == *"BOOTLOADER_ID"* ]]
    [[ "$output" != *"PREFLIGHT_OK"* ]]
}

# The block below tests GRUB_REMOVABLE for exactly "true". "yes" or "True"
# would silently mean "no", so the install would never write the firmware
# fallback path it was told to -- found only when the machine will not boot.
@test "preflight refuses a GRUB_REMOVABLE that is not true or false" {
    run run_preflight $(preflight_env | grep -v '^GRUB_REMOVABLE=') GRUB_REMOVABLE=yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"GRUB_REMOVABLE"* ]]
    [[ "$output" != *"PREFLIGHT_OK"* ]]
}

# The id is interpolated into ${esp}/EFI/${id}/grubx64.efi and handed to
# grub-install as a directory name. chroot_write_config already refuses " ` $
# and \, none of which is enough to stop ../MICROSOFT from installing this
# bootloader over somebody else's.
@test "preflight refuses a bootloader id that is not a bare directory name" {
    run run_preflight $(preflight_env | grep -v '^BOOTLOADER_ID=') BOOTLOADER_ID=../MICROSOFT
    [ "$status" -ne 0 ]
    [[ "$output" == *"BOOTLOADER_ID"* ]]
    [[ "$output" != *"PREFLIGHT_OK"* ]]
}

# Pre-existing guard, kept under test now that a harness exists for it.
@test "preflight refuses a LUKS_ENABLED that is not true or false" {
    run run_preflight $(preflight_env | grep -v '^LUKS_ENABLED=') LUKS_ENABLED=yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"LUKS_ENABLED"* ]]
    [[ "$output" != *"PREFLIGHT_OK"* ]]
}
