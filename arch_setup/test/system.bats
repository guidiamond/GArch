#!/usr/bin/env bats

load helpers

DEFAULT_HOOKS='HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)'
# What a current Arch ISO actually ships. The udev-era line above is what every
# fixture here used to assume, and assuming it is what let a systemd initramfs
# be given the busybox `encrypt` hook -- an install that reaches a timeout on
# /dev/mapper/cryptroot instead of a passphrase prompt.
SYSTEMD_HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)'
# The broken hybrid itself, as produced against a real ISO.
MISMATCHED_HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block encrypt filesystems fsck)'

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/system.sh"
    TMP="$BATS_TEST_TMPDIR"
}

make_locale_gen() {
    printf '#en_US.UTF-8 UTF-8  \n#en_US ISO-8859-1  \n#pt_BR.UTF-8 UTF-8  \n' \
        > "$TMP/locale.gen"
}

make_zoneinfo() {
    mkdir -p "$TMP/zoneinfo/America"
    printf 'TZif\n' > "$TMP/zoneinfo/America/Sao_Paulo"
}

# --- hooks_line / modules_line ---------------------------------------------

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

# --- grub_cmdline_add ------------------------------------------------------

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

# --- locale_listed ---------------------------------------------------------
#
# The read-only counterpart of locale_gen_uncomment, and tested next to it on
# purpose: the two must agree about what "listed" means, and the whole point of
# locale_listed is to answer at the prompt what locale_gen_uncomment would
# answer in the chroot, on a wiped disk.

@test "locale_listed finds both a commented and an uncommented entry" {
    printf '#en_US.UTF-8 UTF-8\npt_BR.UTF-8 UTF-8\n' > "$TMP/locale.gen"
    run locale_listed "$TMP/locale.gen" en_US.UTF-8
    [ "$status" -eq 0 ]
    run locale_listed "$TMP/locale.gen" pt_BR.UTF-8
    [ "$status" -eq 0 ]
}

# The trap locale_gen_uncomment documents: in a regex the '.' of 'en_US.UTF-8'
# is a wildcard, so a regex match accepts an 'en_USxUTF-8' line. Approving that
# at the prompt is worse than not checking at all -- it waves through exactly
# the value locale_gen_uncomment then rejects in phase 5.
#
# The fixture deliberately omits the exact line: with both present the awk
# stops at the exact one first and a regex implementation passes anyway. That
# is how the first draft of this test passed against a regex version.
@test "locale_listed compares as a fixed string, not a regex" {
    printf '#en_USxUTF-8 ISO-8859-1\npt_BR.UTF-8 UTF-8\n' > "$TMP/locale.gen"
    run locale_listed "$TMP/locale.gen" 'en_US.UTF-8'
    [ "$status" -eq 1 ]
    # ...and the literal line is still found, so this is not "rejects anything".
    run locale_listed "$TMP/locale.gen" 'en_USxUTF-8'
    [ "$status" -eq 0 ]
}

@test "locale_listed rejects a locale the file does not list" {
    make_locale_gen
    run locale_listed "$TMP/locale.gen" 'xx_YY.UTF-8'
    [ "$status" -eq 1 ]
}

# Status 2 is "cannot answer", and install.sh accepts the value unchecked on a
# 2 rather than looping on a question it can never answer. Collapsing this into
# 1 would make an installer that cannot read /etc/locale.gen reject every
# locale its operator types.
@test "locale_listed says 'cannot answer', not 'absent', for an unreadable file" {
    run locale_listed "$TMP/no-such-locale.gen" en_US.UTF-8
    [ "$status" -eq 2 ]
}

# --- list_keymaps / net_check ----------------------------------------------

# A host probe, so this asserts the probe works here rather than unit-testing
# it. A host with neither localectl nor /usr/share/kbd is legitimate and is
# what the non-zero return exists for, so it skips rather than fails.
@test "list_keymaps enumerates this host's keymaps" {
    run list_keymaps
    [ "$status" -eq 0 ] || skip "this host cannot enumerate keymaps"
    [ "$(grep -cx us <<< "$output")" -eq 1 ]
}

# Stubbed on PATH rather than as shell functions, for two reasons: net_check
# reaches curl through `command -v`, which does not see a shell function the
# way a bare call would; and a test host with real network access would
# otherwise let a real `ping archlinux.org` decide the result, so every case
# below would pass whatever net_check did. Each stub records that it ran, and
# the tests assert on that -- a status alone cannot tell "fell back to HTTPS"
# from "ICMP answered after all".
stub_net() {
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/ping_args\nexit %s\n' "$TMP" "$1" > "$TMP/bin/ping"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/curl_args\nexit %s\n' "$TMP" "$2" > "$TMP/bin/curl"
    chmod +x "$TMP/bin/ping" "$TMP/bin/curl"
}

@test "net_check succeeds on ICMP alone, without reaching for curl" {
    stub_net 0 1
    PATH="$TMP/bin:$PATH" run net_check
    [ "$status" -eq 0 ]
    [ -e "$TMP/ping_args" ]
    [ ! -e "$TMP/curl_args" ]
}

# The reason the fallback exists: ICMP is filtered on plenty of networks, and
# "no internet connection" on a host that can reach the mirrors perfectly well
# is a dead end for the operator.
@test "net_check falls back to HTTPS when ICMP is filtered" {
    stub_net 1 0
    PATH="$TMP/bin:$PATH" run net_check
    [ "$status" -eq 0 ]
    [ -e "$TMP/ping_args" ]
    [ -e "$TMP/curl_args" ]
    # -f is what makes curl fail on an HTTP error rather than happily writing a
    # captive portal's login page to /dev/null and reporting success, and the
    # timeout is what stops a black-holed connection hanging the phase. Both
    # are easy to drop while "simplifying" the flags.
    grep -qF -- '-sSf' "$TMP/curl_args"
    grep -qF -- '--max-time' "$TMP/curl_args"
}

@test "net_check fails when neither ICMP nor HTTPS answers" {
    stub_net 1 1
    PATH="$TMP/bin:$PATH" run net_check
    [ "$status" -ne 0 ]
    [ -e "$TMP/curl_args" ]
}

# --- link_timezone ---------------------------------------------------------

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

# --- host detection --------------------------------------------------------

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
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# "none" and "a value I do not recognise" must not share an answer. This used
# to return "" at status 0 for everything unrecognised, and setup_gpu reads an
# empty package list as "no GPU driver selected" -- so `nvidai`, and `NVIDIA`,
# which is exactly what the prompt's own "Detected GPU: nvidia" line invites,
# installed nothing, configured nothing and landed in the summary as a green
# step.
@test "gpu_packages rejects an unrecognised choice instead of answering nothing" {
    local bad
    for bad in NVIDIA nvidai Intel "" "amd intel"; do
        run gpu_packages "$bad"
        [ "$status" -ne 0 ] || {
            echo "gpu_packages accepted '${bad}' at status 0 with output '${output}'" >&2
            return 1
        }
        [[ "$output" == *"unrecognised GPU driver"* ]] || {
            echo "gpu_packages said nothing useful about '${bad}': ${output}" >&2
            return 1
        }
    done
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

# --- refresh_keyring / rank_mirrors ----------------------------------------
#
# Extracted from install.sh's phase_preflight, which left the path its own
# comment calls out as failing "often enough to matter on an ISO a few months
# old" with no coverage at all. pacman and reflector are stubbed on PATH, the
# same technique as stub_net above and for the same reason: neither may run for
# real, and reflector's success path writes to /etc/pacman.d/mirrorlist.
#
# TMPDIR is redirected at $TMP so refresh_keyring's mktemp lands somewhere the
# leak check below can see.
stub_pacman() {
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/pacman_args\n%s\nexit %s\n' \
        "$TMP" "$2" "$1" > "$TMP/bin/pacman"
    chmod +x "$TMP/bin/pacman"
}

@test "refresh_keyring succeeds quietly and asks pacman for the keyring" {
    stub_pacman 0 'echo "resolving dependencies..."'
    PATH="$TMP/bin:$PATH" TMPDIR="$TMP" run refresh_keyring
    [ "$status" -eq 0 ]
    grep -qF -- '-Sy --noconfirm archlinux-keyring' "$TMP/pacman_args"
    # pacman's chatter stays out of the way on success; the caller prints its
    # own phase line.
    [[ "$output" != *"resolving dependencies"* ]]
}

# The defect this replaced: the output went to /dev/null while `set -e` took
# the run down, leaving the operator an exit code and nothing to read.
@test "refresh_keyring surfaces pacman's output when it fails" {
    stub_pacman 1 'echo "error: failed retrieving file from mirror" >&2'
    PATH="$TMP/bin:$PATH" TMPDIR="$TMP" run refresh_keyring
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed retrieving file from mirror"* ]]
}

@test "refresh_keyring leaves no temp file behind on either path" {
    stub_pacman 0 ':'
    PATH="$TMP/bin:$PATH" TMPDIR="$TMP" run refresh_keyring
    [ "$status" -eq 0 ]
    stub_pacman 1 'echo boom >&2'
    PATH="$TMP/bin:$PATH" TMPDIR="$TMP" run refresh_keyring
    [ "$status" -ne 0 ]
    # mktemp's own names are tmp.XXXXXXXXXX; nothing but the stub's records and
    # its bin directory should remain.
    [ -z "$(find "$TMP" -maxdepth 1 -name 'tmp.*' -print -quit)" ]
}

@test "rank_mirrors ranks by rate and saves over the mirrorlist" {
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/reflector_args\nexit 0\n' "$TMP" \
        > "$TMP/bin/reflector"
    chmod +x "$TMP/bin/reflector"
    PATH="$TMP/bin:$PATH" run rank_mirrors
    [ "$status" -eq 0 ]
    grep -qF -- '--sort rate' "$TMP/reflector_args"
    grep -qF -- '--save /etc/pacman.d/mirrorlist' "$TMP/reflector_args"
}

# Never fatal, but never silent either: the ISO ships a working mirrorlist, so
# both of these cost speed rather than correctness -- and pacstrapping from an
# unranked list looks exactly like a hung phase if nothing says so.
@test "rank_mirrors warns instead of failing when reflector errors" {
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/reflector"
    chmod +x "$TMP/bin/reflector"
    PATH="$TMP/bin:$PATH" run rank_mirrors
    [ "$status" -eq 0 ]
    [[ "$output" == *"reflector failed"* ]]
}

@test "rank_mirrors warns instead of failing when reflector is absent" {
    mkdir -p "$TMP/empty"
    PATH="$TMP/empty" run rank_mirrors
    [ "$status" -eq 0 ]
    [[ "$output" == *"not installed"* ]]
}

# --- initramfs flavour -----------------------------------------------------
#
# The systemd and udev initramfs take different LUKS hooks AND different kernel
# parameters, and neither ignores the other's politely: sd-encrypt does nothing
# with cryptdevice=, encrypt does nothing with rd.luks.name=. Pairing them
# wrongly builds an image that asks for no passphrase and times out waiting for
# /dev/mapper/cryptroot. Verified in the VM before these tests were written.

@test "initramfs_flavor detects a systemd initramfs" {
    [ "$(initramfs_flavor "$SYSTEMD_HOOKS")" = "systemd" ]
}

@test "initramfs_flavor detects a udev initramfs" {
    [ "$(initramfs_flavor "$DEFAULT_HOOKS")" = "udev" ]
}

@test "hooks_line uses sd-encrypt in a systemd initramfs" {
    run hooks_line "$SYSTEMD_HOOKS" true
    [ "$status" -eq 0 ]
    [[ "$output" == *"block sd-encrypt filesystems"* ]]
}

@test "hooks_line uses encrypt in a udev initramfs" {
    run hooks_line "$DEFAULT_HOOKS" true
    [ "$status" -eq 0 ]
    [[ "$output" == *"block encrypt filesystems"* ]]
    [[ "$output" != *"sd-encrypt"* ]]
}

# The regression that shipped. A systemd HOOKS line carrying the busybox hook
# must come back carrying the systemd one and *only* the systemd one -- adding
# sd-encrypt while leaving encrypt in place would still boot to the timeout.
@test "hooks_line replaces a mismatched encrypt hook with sd-encrypt" {
    run hooks_line "$MISMATCHED_HOOKS" true
    [ "$status" -eq 0 ]
    [[ "$output" == *"block sd-encrypt filesystems"* ]]
    stripped=${output//sd-encrypt/}
    [[ "$stripped" != *"encrypt"* ]]
}

@test "hooks_line drops a stale sd-encrypt when encryption is off" {
    run hooks_line "$SYSTEMD_HOOKS" false
    [ "$status" -eq 0 ]
    [[ "$output" != *"encrypt"* ]]
}

@test "hooks_line is idempotent on a systemd line" {
    first=$(hooks_line "$SYSTEMD_HOOKS" true)
    second=$(hooks_line "$first" true)
    [ "$first" = "$second" ]
}

@test "hooks_line keeps keyboard before the LUKS hook on systemd" {
    out=$(hooks_line "$SYSTEMD_HOOKS" true)
    kb=${out%%sd-encrypt*}
    [[ "$kb" == *"keyboard"* ]]
}

@test "hooks_line does not duplicate microcode already present on systemd" {
    out=$(hooks_line "$SYSTEMD_HOOKS" true)
    [ "$(grep -o 'microcode' <<< "$out" | wc -l)" -eq 1 ]
}

# --- crypt_cmdline ---------------------------------------------------------

@test "crypt_cmdline gives rd.luks.name for a systemd initramfs" {
    [ "$(crypt_cmdline systemd DEAD-BEEF)" = "rd.luks.name=DEAD-BEEF=cryptroot" ]
}

@test "crypt_cmdline gives cryptdevice for a udev initramfs" {
    [ "$(crypt_cmdline udev DEAD-BEEF)" = "cryptdevice=UUID=DEAD-BEEF:cryptroot" ]
}

@test "crypt_cmdline rejects an unknown flavour rather than guessing" {
    # -eq 1, not -ne 0: a missing function exits 127, which "non-zero" would
    # accept -- the assertion would then pass before the function is written
    # and keep passing if it were deleted.
    run crypt_cmdline banana DEAD-BEEF
    [ "$status" -eq 1 ]
    [ -z "${output//*invalid*/}" ] || [[ "$output" == *"flavour"* || "$output" == *"flavor"* ]]
}

# --- grub_cmdline_remove ---------------------------------------------------

@test "grub_cmdline_remove drops the named key" {
    printf 'GRUB_CMDLINE_LINUX="quiet cryptdevice=UUID=old:cryptroot rw"\n' > "$TMP/grub"
    grub_cmdline_remove "$TMP/grub" cryptdevice
    grep -q 'GRUB_CMDLINE_LINUX="quiet rw"' "$TMP/grub"
}

@test "grub_cmdline_remove is a no-op when the key is absent" {
    printf 'GRUB_CMDLINE_LINUX="quiet rw"\n' > "$TMP/grub"
    grub_cmdline_remove "$TMP/grub" cryptdevice
    grep -q 'GRUB_CMDLINE_LINUX="quiet rw"' "$TMP/grub"
}

# Switching flavour must not leave both parameters behind: the stale one is
# inert on the new initramfs but reads as intent to anyone debugging later.
@test "the two LUKS parameters never coexist after a flavour switch" {
    printf 'GRUB_CMDLINE_LINUX="cryptdevice=UUID=old:cryptroot"\n' > "$TMP/grub"
    grub_cmdline_remove "$TMP/grub" cryptdevice
    grub_cmdline_add "$TMP/grub" "$(crypt_cmdline systemd NEW-UUID)"
    grep -q 'rd.luks.name=NEW-UUID=cryptroot' "$TMP/grub"
    assert_absent 'cryptdevice' "$TMP/grub"
}
