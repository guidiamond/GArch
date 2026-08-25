#!/usr/bin/env bats

load helpers

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/boot.sh"
}

@test "bootloader_id_from uppercases and keeps safe characters" {
    [ "$(bootloader_id_from work)" = "WORK" ]
    [ "$(bootloader_id_from arch_work)" = "ARCH_WORK" ]
}

@test "bootloader_id_from replaces FAT-unsafe characters" {
    [ "$(bootloader_id_from "my box")" = "MY_BOX" ]
    [ "$(bootloader_id_from "a/b")" = "A_B" ]
}

@test "bootloader_id_from replaces every unsafe character rather than dropping it" {
    # Mapping is length-preserving, which is the point: dropping would turn
    # "a/b c" into ABC, shortening every id and making it collide with names
    # it no longer resembles. The newline case is the same rule, and the one
    # most likely to arrive by accident from a pasted name.
    [ "$(bootloader_id_from "a/b c")" = "A_B_C" ]
    [ "$(bootloader_id_from "$(printf 'a\nb')")" = "A_B" ]
}

@test "bootloader_id_from rejects a name with no letters or digits" {
    # "   " used to be accepted as the id "___" -- a legal FAT directory that
    # the operator cannot recognise in the firmware's own boot menu, which is
    # the one place this id has to be readable.
    run bootloader_id_from "   "
    [ "$status" -ne 0 ]
    [[ "$output" == *"leaves nothing usable"* ]]
    run bootloader_id_from "///"
    [ "$status" -ne 0 ]
    [[ "$output" == *"leaves nothing usable"* ]]
}

@test "bootloader_id_from truncates to 16 characters" {
    [ "$(bootloader_id_from aaaaaaaaaaaaaaaaaaaa)" = "AAAAAAAAAAAAAAAA" ]
}

# Every refusal test below asserts the wording as well as the status. A bare
# `run missing_function; [ "$status" -ne 0 ]` passes at exit 127, so the whole
# group used to go green against an empty lib/boot.sh (measured).
@test "bootloader_id_from rejects an empty name" {
    run bootloader_id_from ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"leaves nothing usable"* ]]
}

@test "removable_policy forbids when a fallback already exists" {
    [ "$(removable_policy yes no)" = "forbid" ]
    [ "$(removable_policy yes yes)" = "forbid" ]
}

@test "removable_policy offers by default on a new esp" {
    [ "$(removable_policy no yes)" = "offer-default-yes" ]
}

@test "removable_policy is conservative on a shared esp" {
    [ "$(removable_policy no no)" = "offer-default-no" ]
}

@test "removable_policy refuses an answer that is neither yes nor no" {
    # A probe that failed hands back "" or "unknown", and anything that is not
    # a clear "yes, a fallback exists" must not degrade into an answer that
    # offers to overwrite \EFI\BOOT\BOOTX64.EFI.
    run removable_policy "" no
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected 'yes' or 'no'"* ]]
    [[ "$output" != *"offer"* ]]
    run removable_policy no ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected 'yes' or 'no'"* ]]
    [[ "$output" != *"offer"* ]]
    run removable_policy unknown no
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected 'yes' or 'no'"* ]]
    [[ "$output" != *"offer"* ]]
}

@test "chain_entry generates a menuentry with the search and chainloader" {
    run chain_entry "Arch Linux (work)" "1A2B-3C4D" "/EFI/ARCH_WORK/grubx64.efi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"menuentry 'Arch Linux (work)' {"* ]]
    [[ "$output" == *"insmod chain"* ]]
    [[ "$output" == *"search --no-floppy --fs-uuid --set=root 1A2B-3C4D"* ]]
    [[ "$output" == *"chainloader /EFI/ARCH_WORK/grubx64.efi"* ]]
}

@test "chain_entry loads both partition map modules" {
    # search needs the partmap module for the label it is enumerating. The
    # target machine's ESPs are all GPT, but the entry is generated for
    # whatever the inventory finds, and grub-mkconfig emits both for exactly
    # this reason.
    run chain_entry "Arch" "1A2B-3C4D" "/EFI/X/grubx64.efi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"insmod part_gpt"* ]]
    [[ "$output" == *"insmod part_msdos"* ]]
}

@test "chain_entry refuses a uuid with no filesystem uuid shape" {
    # "-" satisfied the old [A-Za-z0-9-]+ rule and emitted
    # `search --fs-uuid --set=root -`, which matches nothing and leaves
    # chainloader resolving against whatever root happened to be set.
    local u
    for u in "-" "---" "a" "1A2B3C4D" "1A2B-3C4"; do
        run chain_entry "Arch" "$u" "/EFI/X/grubx64.efi"
        [ "$status" -ne 0 ]
        [[ "$output" == *"is not a filesystem UUID"* ]]
    done
}

@test "chain_entry accepts both real filesystem uuid shapes" {
    # FAT's XXXX-XXXX is what every ESP has; the 8-4-4-4-12 form is what the
    # rest of the machine's filesystems report.
    run chain_entry "Win" "38BD-4D38" "/EFI/X/grubx64.efi"
    [ "$status" -eq 0 ]
    run chain_entry "Arch" "0fc63daf-8483-4772-8e79-3d69d8477de4" "/EFI/X/grubx64.efi"
    [ "$status" -eq 0 ]
}

@test "chain_entry closes the menuentry block" {
    # An unclosed brace does not break this entry, it breaks every entry after
    # it in the file -- including the ones belonging to the system whose
    # bootloader we are writing into.
    run chain_entry "Arch" "1A2B-3C4D" "/EFI/X/grubx64.efi"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "menuentry 'Arch' {" ]
    [ "${lines[-1]}" = "}" ]
}

@test "chain_entry refuses a title containing a single quote" {
    run chain_entry "Gui's Arch" "1A2B-3C4D" "/EFI/X/grubx64.efi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"single quote or a newline"* ]]
}

@test "chain_entry refuses a title containing a newline" {
    run chain_entry "$(printf 'Arch\n}\nmenuentry evil {')" "1A2B-3C4D" "/EFI/X/grubx64.efi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"single quote or a newline"* ]]
}

@test "chain_entry refuses an empty title" {
    run chain_entry "" "1A2B-3C4D" "/EFI/X/grubx64.efi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty title"* ]]
}

@test "chain_entry refuses a uuid that is not a uuid" {
    run chain_entry "Arch" "\$(reboot)" "/EFI/X/grubx64.efi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a filesystem UUID"* ]]
}

@test "chain_entry refuses an efi path that is not absolute" {
    run chain_entry "Arch" "1A2B-3C4D" "EFI/X/grubx64.efi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not an absolute EFI path"* ]]
}

@test "chain_entry refuses a Windows-style backslash efi path" {
    # efibootmgr reports \EFI\MICROSOFT\BOOT\BOOTMGFW.EFI; GRUB's
    # chainloader wants slashes. Refusing makes the caller convert, where
    # accepting would emit a chainloader line that boots nothing and only says
    # so at the boot menu.
    run chain_entry "Windows" "38BD-4D38" '\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI'
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not an absolute EFI path"* ]]
}

@test "chain_entry names a rejected backslash path without eating the backslashes" {
    # The refused value is quoted back verbatim. When lib/ui.sh printed through
    # `echo -e` it was not: the operator was told the path was wrong while
    # being shown a different one, measured as
    # "^[FI\MICROSOFT\BOOT\BOOTMGFW.EFI".
    run chain_entry "Windows" "38BD-4D38" '\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI'
    [ "$status" -ne 0 ]
    [[ "$output" == *'\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI'* ]]
}

@test "custom_cfg_upsert creates the file when it does not exist" {
    local f="${BATS_TEST_TMPDIR}/40_custom"
    custom_cfg_upsert "$f" WORK "menuentry 'x' {}" 0755
    [ -f "$f" ]
    [[ "$(cat "$f")" == *"# BEGIN arch-installer:WORK"* ]]
    [[ "$(cat "$f")" == *"menuentry 'x' {}"* ]]
    [[ "$(cat "$f")" == *"# END arch-installer:WORK"* ]]
}

@test "custom_cfg_upsert gives a new file the requested mode" {
    local f="${BATS_TEST_TMPDIR}/40_custom"
    custom_cfg_upsert "$f" WORK "block" 0755
    [ "$(stat -c %a "$f")" = "755" ]
}

@test "custom_cfg_upsert preserves the mode of an existing file" {
    local f="${BATS_TEST_TMPDIR}/grub.cfg"
    echo "existing" > "$f"
    chmod 600 "$f"
    custom_cfg_upsert "$f" WORK "block" 0755
    [ "$(stat -c %a "$f")" = "600" ]
}

@test "custom_cfg_upsert keeps content outside the markers" {
    local f="${BATS_TEST_TMPDIR}/grub.cfg"
    printf 'menuentry "keepme" {}\n' > "$f"
    custom_cfg_upsert "$f" WORK "block" 0644
    [[ "$(cat "$f")" == *"keepme"* ]]
}

@test "custom_cfg_upsert keeps content that followed an earlier block" {
    # The block is rewritten at the end of the file, so the lines that used to
    # follow it must still be there afterwards -- this is another system's
    # grub.cfg, and a lost entry is an OS that no longer boots.
    local f="${BATS_TEST_TMPDIR}/grub.cfg"
    custom_cfg_upsert "$f" WORK "first" 0644
    printf 'menuentry "trailer" {}\n' >> "$f"
    custom_cfg_upsert "$f" WORK "second" 0644
    [[ "$(cat "$f")" == *"trailer"* ]]
    [[ "$(cat "$f")" == *"second"* ]]
    assert_absent 'first' "$f"
}

@test "custom_cfg_upsert run twice leaves exactly one block" {
    local f="${BATS_TEST_TMPDIR}/40_custom"
    custom_cfg_upsert "$f" WORK "first" 0755
    custom_cfg_upsert "$f" WORK "second" 0755
    [ "$(grep -c '# BEGIN arch-installer:WORK' "$f")" -eq 1 ]
    [[ "$(cat "$f")" == *"second"* ]]
    assert_absent 'first' "$f"
}

@test "custom_cfg_upsert leaves another install's block alone" {
    local f="${BATS_TEST_TMPDIR}/40_custom"
    custom_cfg_upsert "$f" WORK     "work block"     0755
    custom_cfg_upsert "$f" PERSONAL "personal block" 0755
    [[ "$(cat "$f")" == *"work block"* ]]
    [[ "$(cat "$f")" == *"personal block"* ]]
}

@test "custom_cfg_upsert refuses a symlinked target" {
    # `mv` replaces the symlink with a regular file: the real config keeps its
    # old content and silently stops receiving our block, and the replacement
    # took the symlink's own 0777 mode, because stat -c %a does not
    # dereference. In /etc/grub.d that is a world-writable file root executes.
    # Fedora and RHEL ship /boot/grub2/grub.cfg as a symlink into the ESP.
    local dir="${BATS_TEST_TMPDIR}/sym"
    mkdir -p "$dir/real"
    printf 'original\n' > "$dir/real/40_custom"
    chmod 755 "$dir/real/40_custom"
    ln -s real/40_custom "$dir/link_custom"
    run custom_cfg_upsert "$dir/link_custom" WORK "blk" 0755
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
    [ -L "$dir/link_custom" ]
    [ "$(cat "$dir/real/40_custom")" = "original" ]
    [ "$(stat -c %a "$dir/real/40_custom")" = "755" ]
}

@test "custom_cfg_upsert's cleanup trap does not abort a later source under set -u" {
    # The RETURN trap stays registered after the function returns, but its
    # local is gone with it. Under install.sh's `set -euo pipefail` the next
    # RETURN event -- the end of any later `source` -- then dereferences an
    # unbound variable and kills the run.
    #
    # bats does not run tests under set -u (nothing here inherits install.sh's
    # `set`), so this test has to turn it on itself; without that it passes
    # whether or not the guard is there and proves nothing.
    custom_cfg_upsert "${BATS_TEST_TMPDIR}/t" WORK "blk" 0644
    printf 'true\n' > "${BATS_TEST_TMPDIR}/later.sh"
    set -u
    source "${BATS_TEST_TMPDIR}/later.sh"
    set +u
}

@test "custom_cfg_upsert names a dangling symlink's target in the refusal" {
    # readlink -f canonicalises, so it fails and prints nothing when a
    # component of the target is missing -- which told the operator the file
    # "is a symlink to ; point at that path instead".
    local dir="${BATS_TEST_TMPDIR}/dangling"
    mkdir -p "$dir"
    ln -s missing_dir/40_custom "$dir/link_custom"
    run custom_cfg_upsert "$dir/link_custom" WORK "blk" 0644
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
    [[ "$output" == *"missing_dir/40_custom"* ]]
}

@test "custom_cfg_upsert refuses a file that already holds two of our blocks" {
    # Reachable through the documented CRLF path: a CRLF target gains a second
    # LF block, and normalising the line endings afterwards leaves two matched
    # pairs. Refusing is right -- which of the two is ours is not knowable --
    # but the message has to say that, not claim the markers are unmatched.
    local f="${BATS_TEST_TMPDIR}/dup"
    printf '# BEGIN arch-installer:WORK\none\n# END arch-installer:WORK\n' > "$f"
    printf '# BEGIN arch-installer:WORK\ntwo\n# END arch-installer:WORK\n' >> "$f"
    run custom_cfg_upsert "$f" WORK "new" 0644
    [ "$status" -ne 0 ]
    [[ "$output" == *"2 blocks"* ]]
    [[ "$output" == *"at most one"* ]]
    [[ "$(cat "$f")" == *"one"* ]]
    [[ "$(cat "$f")" == *"two"* ]]
}

@test "custom_cfg_upsert refuses a target that is a directory" {
    # [[ -f ]] is false for a directory, so the sibling temp file was moved
    # *into* it and the call reported success. Pointed at /etc/grub.d instead
    # of /etc/grub.d/40_custom -- a one-token slip -- that leaves a mode-0755
    # file grub-mkconfig executes forever, emitting an entry no marker matches.
    local dir="${BATS_TEST_TMPDIR}/grub.d"
    mkdir -p "$dir"
    run custom_cfg_upsert "$dir" WORK "menuentry stray {}" 0755
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a regular file"* ]]
    [ "$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -type f | wc -l)" -eq 0 ]
    [ -z "$(ls -A "$dir")" ]
}

@test "custom_cfg_upsert does not widen the mode of a target carrying an ACL" {
    command -v setfacl >/dev/null || skip "setfacl not available"
    local f="${BATS_TEST_TMPDIR}/acl_custom"
    printf 'x\n' > "$f"
    chmod 644 "$f"
    setfacl -m u:1234:rw "$f" || skip "filesystem does not support ACLs"
    # stat -c %a reports the ACL *mask* in the group bits, so this target reads
    # back as 0664; restoring that with chmod turned the mask into a real
    # group-write bit and dropped the ACL (measured).
    custom_cfg_upsert "$f" WORK "blk" 0644
    [[ "$(getfacl -c "$f")" == *"group::r--"* ]]
    [[ "$(getfacl -c "$f")" == *"user:1234:rw-"* ]]
}

@test "custom_cfg_upsert refuses a file whose BEGIN marker has no END" {
    # awk sets skip at BEGIN and only clears it at END, so an orphan BEGIN
    # dropped every line to EOF -- silently, reporting success, in another
    # operating system's bootloader config.
    local f="${BATS_TEST_TMPDIR}/orphan"
    printf 'menuentry A {}\n# BEGIN arch-installer:WORK\nstale\nmenuentry B {}\nmenuentry C {}\n' > "$f"
    run custom_cfg_upsert "$f" WORK "new" 0644
    [ "$status" -ne 0 ]
    [[ "$output" == *"matched pair"* ]]
    [[ "$(cat "$f")" == *"menuentry B {}"* ]]
    [[ "$(cat "$f")" == *"menuentry C {}"* ]]
}

@test "custom_cfg_upsert does not confuse a marker id that prefixes another" {
    # The classic marker-editor bug: a prefix match would let WORK's upsert
    # eat WORK2's block. The exact-line awk comparison already prevents it and
    # nothing pinned that.
    local f="${BATS_TEST_TMPDIR}/40_custom"
    custom_cfg_upsert "$f" WORK  "work block"  0644
    custom_cfg_upsert "$f" WORK2 "work2 block" 0644
    custom_cfg_upsert "$f" WORK  "work again"  0644
    [[ "$(cat "$f")" == *"work2 block"* ]]
    [[ "$(cat "$f")" == *"work again"* ]]
    assert_absent 'work block' "$f"
    [ "$(grep -c '# BEGIN arch-installer:WORK$' "$f")" -eq 1 ]
    [ "$(grep -c '# BEGIN arch-installer:WORK2$' "$f")" -eq 1 ]
}

@test "custom_cfg_upsert stores a chain_entry unchanged" {
    # The only pairing that ships. Everything else here writes single-line
    # blocks, which cannot catch a quoting or line-splitting fault.
    local f="${BATS_TEST_TMPDIR}/40_custom" entry
    entry=$(chain_entry "Arch Linux (personal)" "283B-4CE7" "/EFI/BOOT/BOOTX64.EFI")
    custom_cfg_upsert "$f" PERSONAL "$entry" 0755
    custom_cfg_upsert "$f" PERSONAL "$entry" 0755
    [ "$(grep -c '# BEGIN arch-installer:PERSONAL' "$f")" -eq 1 ]
    [[ "$(cat "$f")" == *"menuentry 'Arch Linux (personal)' {"* ]]
    [[ "$(cat "$f")" == *"chainloader /EFI/BOOT/BOOTX64.EFI"* ]]
    # The stored block is byte-identical to what chain_entry produced.
    [ "$(sed -n '/# BEGIN arch-installer:PERSONAL/,/# END arch-installer:PERSONAL/p' "$f" \
        | sed '1d;$d')" = "$entry" ]
}

@test "custom_cfg_upsert preserves foreign content when the markers are CRLF" {
    # A target converted to CRLF stops matching the exact-line comparison, so
    # each run appends a fresh block. That is duplicate menu entries, not a
    # broken boot: what must hold is that nothing outside is lost.
    local f="${BATS_TEST_TMPDIR}/crlf"
    printf 'menuentry "keepme" {}\r\n# BEGIN arch-installer:WORK\r\nold\r\n# END arch-installer:WORK\r\n' > "$f"
    custom_cfg_upsert "$f" WORK "new" 0644
    [[ "$(cat "$f")" == *"keepme"* ]]
    [[ "$(cat "$f")" == *"new"* ]]
}

@test "custom_cfg_upsert leaves no temporary file behind" {
    # The temp file is a sibling, created 0600 and chmod'd to the target's mode
    # before the rename. grub-mkconfig runs every executable file in
    # /etc/grub.d, so a leaked one is a duplicate of the entry forever.
    local dir="${BATS_TEST_TMPDIR}/grub.d"
    mkdir -p "$dir"
    custom_cfg_upsert "${dir}/40_custom" WORK "block" 0755
    [ "$(find "$dir" -maxdepth 1 -type f | wc -l)" -eq 1 ]
}

@test "custom_cfg_upsert refuses a marker id with shell or regex characters" {
    local f="${BATS_TEST_TMPDIR}/40_custom"
    run custom_cfg_upsert "$f" 'a b*' "block" 0644
    [ "$status" -ne 0 ]
    [[ "$output" == *"marker id must be"* ]]
    [ ! -e "$f" ]
}

@test "custom_cfg_upsert refuses an empty marker id" {
    local f="${BATS_TEST_TMPDIR}/40_custom"
    run custom_cfg_upsert "$f" "" "block" 0644
    [ "$status" -ne 0 ]
    [[ "$output" == *"marker id must be"* ]]
    [ ! -e "$f" ]
}

@test "custom_cfg_upsert refuses a block that carries its own markers" {
    # A block containing an END line ends the region early, so the next upsert
    # strips only part of it and leaves the rest as an orphan menuentry that
    # nothing will ever remove again.
    local f="${BATS_TEST_TMPDIR}/40_custom"
    run custom_cfg_upsert "$f" WORK "$(printf 'menuentry x {}\n# END arch-installer:WORK\nmenuentry orphan {}')" 0644
    [ "$status" -ne 0 ]
    [[ "$output" == *"marker line"* ]]
    [ ! -e "$f" ]
}

@test "custom_cfg_upsert reports the failure instead of writing when the directory is read-only" {
    # Non-vacuous only because test/run.sh refuses to run as root: root ignores
    # a missing write bit, so as root mktemp would succeed and this would pass
    # for the wrong reason.
    local dir="${BATS_TEST_TMPDIR}/ro"
    mkdir -p "$dir"
    chmod 500 "$dir"
    run custom_cfg_upsert "${dir}/40_custom" WORK "block" 0755
    chmod 700 "$dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"temp file"* ]]
    [ ! -e "${dir}/40_custom" ]
}

# --- inventory (read-only) -------------------------------------------------
#
# Every function below is a host probe. None of them is ever pointed at a real
# device from here: the tree-walking ones get a directory built in
# BATS_TEST_TMPDIR, and the ones that shell out get a PATH-prepended stub dir,
# which is the idiom test/disk.bats already uses for part_in_use and
# part_probe_os. This suite runs on a machine with four disks of data the
# operator is keeping.

@test "every inventory function the suite calls is defined" {
    # A `run missing_fn; [ "$status" -ne 0 ]` passes at exit 127, so the
    # predicate tests below -- esp_has_own_grub, bootloader_id_free,
    # esp_vendor_efi_path -- would go green against a lib/boot.sh defining
    # nothing at all. Measured on Task 6: all five refusal tests passed that
    # way. This test is what stops the whole group from being vacuous.
    local fn
    for fn in parse_esp_list esp_list esp_dir_inventory esp_fallback_kind \
              esp_vendor_efi_path esp_has_own_grub bootloader_id_free \
              efi_path_to_slashes parse_nvram_entries parse_nvram_loaders \
              nvram_entries nvram_loaders esp_fallback_binary \
              esp_probe linux_installs fs_uuid_for_partuuid _esp_resolve \
              _nvram_split _nvram_read; do
        declare -F "$fn" >/dev/null || { echo "not defined: $fn"; return 1; }
    done
}

@test "esp_dir_inventory lists vendor directories" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/MICROSOFT/BOOT" "${esp}/EFI/ARCH_WORK"
    run esp_dir_inventory "$esp"
    [[ "$output" == *"vendor MICROSOFT"* ]]
    [[ "$output" == *"vendor ARCH_WORK"* ]]
}

@test "esp_dir_inventory does not list the removable BOOT directory as a vendor" {
    # \EFI\BOOT is the firmware's fallback path, not somebody's vendor
    # directory. Listing it as one would offer it as a --bootloader-id.
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/BOOT" "${esp}/EFI/boot2"
    run esp_dir_inventory "$esp"
    [[ "$output" != *"vendor BOOT"* ]]
    [[ "$output" == *"vendor boot2"* ]]
}

@test "esp_dir_inventory reports a present fallback binary" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/BOOT"
    touch "${esp}/EFI/BOOT/BOOTX64.EFI"
    run esp_dir_inventory "$esp"
    [[ "$output" == *"fallback yes"* ]]
}

@test "esp_dir_inventory reports a lowercase fallback binary" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/BOOT"
    touch "${esp}/EFI/BOOT/bootx64.efi"
    run esp_dir_inventory "$esp"
    [[ "$output" == *"fallback yes"* ]]
}

@test "esp_dir_inventory finds a fallback binary in any spelling" {
    # FAT preserves whatever case created the name, and the two spellings the
    # first draft tried are two of the 2^12 an installer could have written.
    # Every one it misses reads as "no fallback here", which is the answer
    # that lets removable_policy offer to overwrite somebody's bootloader.
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/efi/Boot"
    touch "${esp}/efi/Boot/BootX64.efi"
    run esp_dir_inventory "$esp"
    [[ "$output" == *"fallback yes"* ]]
}

@test "esp_dir_inventory reports an absent fallback binary" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/MICROSOFT"
    run esp_dir_inventory "$esp"
    [[ "$output" == *"fallback no"* ]]
}

@test "esp_dir_inventory reports fallback no on an esp with no EFI dir" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "$esp"
    run esp_dir_inventory "$esp"
    [[ "$output" == *"fallback no"* ]]
}

@test "esp_fallback_kind identifies a grub binary by signature" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/BOOT"
    printf 'padding GRUB_PREFIX grub_efi padding' > "${esp}/EFI/BOOT/BOOTX64.EFI"
    [ "$(esp_fallback_kind "$esp")" = "grub" ]
}

@test "esp_fallback_kind identifies systemd-boot" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/BOOT"
    printf 'x systemd-boot x' > "${esp}/EFI/BOOT/BOOTX64.EFI"
    [ "$(esp_fallback_kind "$esp")" = "systemd-boot" ]
}

@test "esp_fallback_kind identifies the most distinctive signature, not grub" {
    # The probe order is a behaviour change from grub-first, and both orders
    # pass every other test in this file -- a binary is normally only one
    # loader. "grub" is a substring that turns up inside other loaders,
    # rEFInd's included, because they scan for it; "systemd-boot" and "refind"
    # appear in nothing but themselves. Grub-first therefore labels somebody
    # else's loader as grub, and the inventory is what the operator reads to
    # decide what is on the machine.
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/BOOT"
    printf 'x systemd-boot x grub x' > "${esp}/EFI/BOOT/BOOTX64.EFI"
    [ "$(esp_fallback_kind "$esp")" = "systemd-boot" ]
    printf 'x refind x grub x' > "${esp}/EFI/BOOT/BOOTX64.EFI"
    [ "$(esp_fallback_kind "$esp")" = "refind" ]
}

@test "esp_fallback_kind says unknown for an unrecognised binary" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/BOOT"
    printf 'some other loader' > "${esp}/EFI/BOOT/BOOTX64.EFI"
    [ "$(esp_fallback_kind "$esp")" = "unknown" ]
}

@test "esp_fallback_kind says none when there is no fallback" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "$esp"
    [ "$(esp_fallback_kind "$esp")" = "none" ]
}

@test "esp_vendor_efi_path finds a vendor grub binary" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/GRUB"
    touch "${esp}/EFI/GRUB/grubx64.efi"
    [ "$(esp_vendor_efi_path "$esp")" = "/EFI/GRUB/grubx64.efi" ]
}

@test "esp_vendor_efi_path finds the Windows boot manager a level down" {
    # Windows keeps its loader at \EFI\Microsoft\Boot\bootmgfw.efi, not at
    # \EFI\<VENDOR>\grubx64.efi. Looking only for grubx64.efi returned nothing
    # for the Windows ESP on the target machine -- so phase 6 could not have
    # produced the one chainload entry the whole feature exists for.
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/Microsoft/Boot"
    touch "${esp}/EFI/Microsoft/Boot/bootmgfw.efi"
    [ "$(esp_vendor_efi_path "$esp")" = "/EFI/Microsoft/Boot/bootmgfw.efi" ]
}

@test "esp_vendor_efi_path prefers shim over the grub it loads" {
    # Our chainloader hands the image to LoadImage, which enforces Secure Boot.
    # A distro's grubx64.efi is signed only for its own shim, so chainloading
    # it directly fails on an SB machine; shim works either way, and loads that
    # same grubx64.efi from beside itself.
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/fedora"
    touch "${esp}/EFI/fedora/shimx64.efi" "${esp}/EFI/fedora/grubx64.efi"
    [ "$(esp_vendor_efi_path "$esp")" = "/EFI/fedora/shimx64.efi" ]
}

@test "esp_vendor_efi_path ignores a directory named like a loader" {
    # chainloader pointed at a directory boots nothing and only says so at the
    # boot menu, which is the failure this whole path is written to avoid.
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/GRUB/grubx64.efi" "${esp}/EFI/BOOT"
    touch "${esp}/EFI/BOOT/BOOTX64.EFI"
    [ "$(esp_vendor_efi_path "$esp")" = "/EFI/BOOT/BOOTX64.EFI" ]
}

@test "esp_vendor_efi_path falls back to the removable path" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/BOOT"
    touch "${esp}/EFI/BOOT/BOOTX64.EFI"
    [ "$(esp_vendor_efi_path "$esp")" = "/EFI/BOOT/BOOTX64.EFI" ]
}

@test "esp_vendor_efi_path prefers a vendor dir over the fallback" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/GRUB" "${esp}/EFI/BOOT"
    touch "${esp}/EFI/GRUB/grubx64.efi" "${esp}/EFI/BOOT/BOOTX64.EFI"
    [ "$(esp_vendor_efi_path "$esp")" = "/EFI/GRUB/grubx64.efi" ]
}

@test "esp_vendor_efi_path emits nothing when there is no loader" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI"
    run esp_vendor_efi_path "$esp"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "esp_vendor_efi_path emits a path chain_entry accepts" {
    # The two halves only meet in phase 6, and a path that fails there produces
    # a menu entry that boots nothing.
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/Microsoft/Boot"
    touch "${esp}/EFI/Microsoft/Boot/bootmgfw.efi"
    run chain_entry "Windows" "38BD-4D38" "$(esp_vendor_efi_path "$esp")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"chainloader /EFI/Microsoft/Boot/bootmgfw.efi"* ]]
}

@test "esp_has_own_grub is true when the esp carries a grub boot directory" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/grub"
    touch "${esp}/grub/grub.cfg"
    run esp_has_own_grub "$esp"
    [ "$status" -eq 0 ]
}

@test "esp_has_own_grub is true for a grub directory holding only modules" {
    # grub-install alone writes <esp>/grub/x86_64-efi/ and no grub.cfg.
    # Testing for grub.cfg only would call that ESP free and then replace the
    # neighbour's modules with ours.
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/grub/x86_64-efi"
    touch "${esp}/grub/x86_64-efi/normal.mod"
    run esp_has_own_grub "$esp"
    [ "$status" -eq 0 ]
}

@test "esp_has_own_grub is true for a Fedora-style grub2 directory" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/grub2"
    touch "${esp}/grub2/grub.cfg"
    run esp_has_own_grub "$esp"
    [ "$status" -eq 0 ]
}

@test "esp_has_own_grub is false for an esp with only vendor directories" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/MICROSOFT/BOOT"
    run esp_has_own_grub "$esp"
    [ "$status" -ne 0 ]
    # This predicate is silent, so a missing function's exit 127 is the only
    # thing that could put text here -- which is what makes the status
    # assertion above mean something on its own.
    [ -z "$output" ]
}

@test "bootloader_id_free is false when the vendor dir exists" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/GRUB"
    run bootloader_id_free "$esp" GRUB
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "bootloader_id_free is true when it does not" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI"
    run bootloader_id_free "$esp" ARCH_WORK
    [ "$status" -eq 0 ]
}

@test "efi_path_to_slashes converts the form efibootmgr prints" {
    [ "$(efi_path_to_slashes '\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI')" = "/EFI/MICROSOFT/BOOT/BOOTMGFW.EFI" ]
    [ "$(efi_path_to_slashes '\EFI\BOOT\BOOTX64.EFI')" = "/EFI/BOOT/BOOTX64.EFI" ]
}

@test "efi_path_to_slashes leaves an already-converted path alone" {
    [ "$(efi_path_to_slashes '/EFI/BOOT/BOOTX64.EFI')" = "/EFI/BOOT/BOOTX64.EFI" ]
}

@test "efi_path_to_slashes produces exactly what chain_entry accepts" {
    # This pairing is the whole reason the converter exists: chain_entry
    # refuses the backslash form by design, so without it every foreign entry
    # is refused at the one point where it matters.
    run chain_entry "Windows" "38BD-4D38" "$(efi_path_to_slashes '\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"chainloader /EFI/MICROSOFT/BOOT/BOOTMGFW.EFI"* ]]
}

@test "efi_path_to_slashes refuses a relative path" {
    run efi_path_to_slashes 'EFI\BOOT\BOOTX64.EFI'
    [ "$status" -ne 0 ]
    [[ "$output" == *"absolute EFI path"* ]]
}

@test "efi_path_to_slashes refuses a device path that is not a file path" {
    # BBS and PXE entries have no file path node at all. Converting whatever
    # efibootmgr printed would emit a chainloader line naming a device path.
    run efi_path_to_slashes 'BBS(129,,0x0)'
    [ "$status" -ne 0 ]
    [[ "$output" == *"absolute EFI path"* ]]
    run efi_path_to_slashes '\EFI\BOOT\$(reboot).EFI'
    [ "$status" -ne 0 ]
    [[ "$output" == *"absolute EFI path"* ]]
}

@test "efi_path_to_slashes refuses an empty path" {
    run efi_path_to_slashes ''
    [ "$status" -ne 0 ]
    [[ "$output" == *"absolute EFI path"* ]]
}

@test "efi_path_to_slashes names a rejected path without eating its backslashes" {
    # This function's entire input domain is backslash paths, so the refusal
    # message is exactly where lib/ui.sh's old `echo -e` showed the operator a
    # path other than the one that was refused.
    run efi_path_to_slashes '\EFI\MICRO SOFT\BOOTMGFW.EFI'
    [ "$status" -ne 0 ]
    [[ "$output" == *'\EFI\MICRO SOFT\BOOTMGFW.EFI'* ]]
}

@test "parse_esp_list keeps only partitions with the ESP type guid" {
    run bash -c "ESP_TYPE_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b; $(declare -f parse_esp_list); cat <<'LSBLK' | parse_esp_list
/dev/nvme1n1p1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 104857600 38BD-4D38
/dev/nvme1n1p5 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 576716800 283B-4CE7
/dev/nvme1n1p7 0fc63daf-8483-4772-8e79-3d69d8477de4 281268224 1b13ff14
LSBLK"
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "/dev/nvme1n1p1 38BD-4D38 104857600" ]
    [ "${lines[1]}" = "/dev/nvme1n1p5 283B-4CE7 576716800" ]
}

@test "parse_esp_list matches the type guid case-insensitively" {
    run bash -c "ESP_TYPE_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b; $(declare -f parse_esp_list); cat <<'LSBLK' | parse_esp_list
/dev/sda1 C12A7328-F81F-11D2-BA4B-00A0C93EC93B 1048576 ABCD-1234
LSBLK"
    [ "$output" = "/dev/sda1 ABCD-1234 1048576" ]
}

@test "parse_esp_list keeps the size when an unformatted ESP has no uuid" {
    # An ESP partitioned but never formatted reports an empty UUID. With UUID
    # last, only it comes out empty; when FSTYPE sat in the middle, the size
    # shifted into the uuid variable and esp_bytes came out blank.
    run bash -c "ESP_TYPE_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b; $(declare -f parse_esp_list); cat <<'LSBLK' | parse_esp_list
/dev/sda1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 2147483648
LSBLK"
    # A literal "-" rather than an empty field: with UUID in the middle of the
    # emitted record, an empty one shifts the size into a consumer's $uuid.
    [ "$output" = "/dev/sda1 - 2147483648" ]
}

@test "parse_esp_list ignores the whole-disk rows lsblk emits" {
    # Measured on the target machine: a disk row is "/dev/sda  500107862016 "
    # -- PARTTYPE empty, so default-IFS read shifts the size into it. Nothing
    # must be emitted for a row that is not a partition.
    run bash -c "ESP_TYPE_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b; $(declare -f parse_esp_list); cat <<'LSBLK' | parse_esp_list
/dev/sda  500107862016 
/dev/sda1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 1048576 ABCD-1234
LSBLK"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "/dev/sda1 ABCD-1234 1048576" ]
}

@test "esp_list fails instead of reporting a machine with no ESPs when lsblk fails" {
    # An empty inventory from a failed probe reads as "nothing here to worry
    # about", which is the answer that lets every later guard through. This is
    # the defect class next_part_number and disk_free_gaps document.
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\nexit 3\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run esp_list
    [ "$status" -ne 0 ]
    [[ "$output" == *"lsblk"* ]]
}

@test "esp_list reports the ESPs lsblk lists" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    cat > "${stub}/lsblk" <<'LSBLK'
#!/bin/bash
echo "/dev/sdz  500107862016 "
echo "/dev/sdz1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 104857600 38BD-4D38"
echo "/dev/sdz2 0fc63daf-8483-4772-8e79-3d69d8477de4 281268224 1b13ff14-95ae-46f1-b975-a4233c5ed17f"
LSBLK
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run esp_list
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdz1 38BD-4D38 104857600" ]
}

@test "parse_nvram_entries pulls the boot number and label out of efibootmgr" {
    run bash -c "$(declare -f parse_nvram_entries _nvram_split); cat <<'EFIBOOT' | parse_nvram_entries
BootCurrent: 0005
BootOrder: 0005,0000
Boot0000* Windows Boot Manager	HD(1,GPT,db04a6e9,0x800,0x32000)/\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI
Boot0005* UEFI OS	HD(5,GPT,620c1fcb,0x186a0000,0x113000)/\EFI\BOOT\BOOTX64.EFI
EFIBOOT"
    [ "${lines[0]}" = "0000 Windows Boot Manager" ]
    [ "${lines[1]}" = "0005 UEFI OS" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "parse_nvram_entries ignores efibootmgr -v's continuation lines" {
    # Measured: `efibootmgr -v` follows each entry with indented "dp:" and
    # "data:" lines that are megabytes of hex on some firmwares.
    local fixture
    fixture=$(printf 'BootCurrent: 0005\nTimeout: 0 seconds\nBootOrder: 0005,0000\nBoot0000* Windows Boot Manager\tHD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI57494e444f5753\n      dp: 04 01 2a 00 01 00 00 00\n    data: 57 49 4e 44 4f 57 53 00\n')
    run parse_nvram_entries <<<"$fixture"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "0000 Windows Boot Manager" ]
}

@test "parse_nvram_entries keeps the label of an entry with no active flag" {
    # efibootmgr prints a space where the '*' would be for an inactive entry,
    # so the label sits two spaces in rather than one.
    local fixture
    fixture=$(printf 'Boot0007  Old Loader\tHD(1,GPT,db04a6e9,0x800,0x32000)/\\EFI\\X\\g.efi\n')
    run parse_nvram_entries <<<"$fixture"
    [ "$output" = "0007 Old Loader" ]
}

@test "parse_nvram_entries names an entry that carries no label" {
    # An empty label printed a bare boot number and a trailing space, which
    # reads as a display bug rather than as a real NVRAM slot.
    local fixture
    fixture=$(printf 'Boot0004* \tHD(1,GPT,db04a6e9,0x800,0x32000)/\\EFI\\X\\g.efi\n')
    run parse_nvram_entries <<<"$fixture"
    [ "$output" = "0004 (unlabelled)" ]
}

@test "parse_nvram_loaders converts the loader path and reports the partition guid" {
    local fixture
    fixture=$(printf 'Boot0000* Windows Boot Manager\tHD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI\n')
    run parse_nvram_loaders <<<"$fixture"
    [ "$output" = "0000 db04a6e9-6005-473c-b45b-ac2ca8af3a2a /EFI/MICROSOFT/BOOT/BOOTMGFW.EFI Windows Boot Manager" ]
}

@test "parse_nvram_loaders stops the path at the loader and drops the option data" {
    # Measured on the target machine: efibootmgr appends the raw option data to
    # the device path with no separator at all --
    # "...\BOOTMGFW.EFI57494e444f5753...". Carrying that hex run into a
    # chainloader line produces an entry that boots nothing.
    local fixture
    fixture=$(printf 'Boot0005* UEFI OS\tHD(5,GPT,620c1fcb-07fd-ca4f-a2a0-09c21869c7d6,0x186a0000,0x113000)/\\EFI\\BOOT\\BOOTX64.EFI0000424f\n')
    run parse_nvram_loaders <<<"$fixture"
    [ "$output" = "0005 620c1fcb-07fd-ca4f-a2a0-09c21869c7d6 /EFI/BOOT/BOOTX64.EFI UEFI OS" ]
}

@test "parse_nvram_loaders skips entries with no file path" {
    # BBS entries -- the firmware's own CD/network/removable rows -- name a
    # device and no loader. Emitting one would hand phase 6 a menu entry with
    # nothing to chainload.
    local fixture
    fixture=$(printf 'BootCurrent: 0005\nBoot0001* UEFI:CD/DVD Drive\tBBS(129,,0x0)\nBoot0002* UEFI:Network Device\tBBS(131,,0x0)\n')
    run parse_nvram_loaders <<<"$fixture"
    [ -z "$output" ]
}

@test "parse_nvram_loaders skips an entry whose partition is not a GPT guid" {
    # An MBR HD() node carries a disk signature, which lsblk reports in a
    # different form entirely -- so it cannot be resolved to a filesystem uuid
    # and must not be emitted as though it could.
    local fixture
    fixture=$(printf 'Boot0003* Legacy\tHD(1,MBR,0x12345678,0x800,0x32000)/\\EFI\\BOOT\\BOOTX64.EFI\n')
    run parse_nvram_loaders <<<"$fixture"
    [ -z "$output" ]
}

@test "parse_nvram_loaders emits paths chain_entry accepts" {
    local fixture line num pu path label
    fixture=$(printf 'Boot0000* Windows Boot Manager\tHD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI57494e444f5753\n')
    line=$(parse_nvram_loaders <<<"$fixture")
    read -r num pu path label <<<"$line"
    run chain_entry "$label" "38BD-4D38" "$path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"menuentry 'Windows Boot Manager' {"* ]]
    [[ "$output" == *"chainloader /EFI/MICROSOFT/BOOT/BOOTMGFW.EFI"* ]]
}

@test "nvram_entries fails instead of reporting empty NVRAM when efibootmgr fails" {
    # No entries and "efibootmgr is not installed" must not be the same answer:
    # the first says the firmware knows about nothing, which phase 6 would act
    # on.
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "EFI variables are not supported" >&2\nexit 1\n' > "${stub}/efibootmgr"
    chmod +x "${stub}/efibootmgr"
    PATH="${stub}:${PATH}" run nvram_entries
    [ "$status" -ne 0 ]
    [[ "$output" == *"efibootmgr"* ]]
    # Named for the function that was called, not for the parser it delegates
    # to. Both halves share one reader, and reporting "parse_nvram_entries"
    # sends the operator looking for a name that appears in no phase. Asserted
    # as an absence too: "parse_nvram_entries: efibootmgr failed" contains
    # "nvram_entries: efibootmgr failed", so the positive form alone passes
    # against exactly the wording it is meant to rule out.
    [[ "$output" == *"nvram_entries: efibootmgr failed"* ]]
    [[ "$output" != *"parse_nvram"* ]]
    [[ "$output" != *"_nvram_read"* ]]
    [[ "$output" == *"EFI variables are not supported"* ]]
}

@test "nvram_entries reports the entries efibootmgr lists" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    cat > "${stub}/efibootmgr" <<'EFIBOOTMGR'
#!/bin/bash
printf 'BootCurrent: 0005\n'
printf 'Boot0000* Windows Boot Manager\tHD(1,GPT,db04a6e9,0x800,0x32000)/\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI\n'
EFIBOOTMGR
    chmod +x "${stub}/efibootmgr"
    PATH="${stub}:${PATH}" run nvram_entries
    [ "$status" -eq 0 ]
    [ "$output" = "0000 Windows Boot Manager" ]
}

@test "esp_probe reports fallback unknown for an esp it cannot mount" {
    # "fallback no" is the answer that makes removable_policy offer to write
    # \EFI\BOOT\BOOTX64.EFI. An ESP we failed to read must not produce it --
    # removable_policy refuses anything that is not a literal yes or no, and
    # that refusal is the point.
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho vfat\n' > "${stub}/lsblk"
    printf '#!/bin/bash\nexit 32\n' > "${stub}/mount"
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" run esp_probe /dev/sdz1
    [[ "$output" == *"fallback unknown"* ]]
    [[ "$output" == *"kind unreadable"* ]]
    [[ "$output" != *"fallback no"* ]]
    run removable_policy unknown no
    [ "$status" -ne 0 ]
}

@test "esp_probe never mounts a partition whose filesystem is not FAT" {
    # An ESP is selected by GPT type GUID, and nothing stops a partition
    # carrying that GUID from holding ext4 -- for which a bare `mount -o ro`
    # replays a dirty journal. That is a write to a filesystem belonging to a
    # system that is staying, during a phase that promises not to write.
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho ext4\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 0
MOUNT
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" run esp_probe /dev/sdz1
    [[ "$output" == *"kind unreadable"* ]]
    [ ! -e "$log" ]
}

@test "esp_probe says unreadable rather than guessing when lsblk fails" {
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    printf '#!/bin/bash\nexit 3\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 0
MOUNT
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" run esp_probe /dev/sdz1
    [[ "$output" == *"fallback unknown"* ]]
    [ ! -e "$log" ]
}

@test "esp_probe unmounts and removes its mountpoint before returning" {
    # A mount left behind is picked up by phase 4's genfstab and lands in the
    # new system's fstab, pointing at somebody else's ESP.
    local stub="${BATS_TEST_TMPDIR}/bin" tmp="${BATS_TEST_TMPDIR}/mnt"
    mkdir -p "$stub" "$tmp"
    printf '#!/bin/bash\necho vfat\n' > "${stub}/lsblk"
    printf '#!/bin/bash\nexit 0\n' > "${stub}/mount"
    printf '#!/bin/bash\necho called >> "%s/umount.log"\nexit 0\n' "$BATS_TEST_TMPDIR" > "${stub}/umount"
    chmod +x "${stub}/lsblk" "${stub}/mount" "${stub}/umount"
    PATH="${stub}:${PATH}" TMPDIR="$tmp" run esp_probe /dev/sdz1
    [ "$status" -eq 0 ]
    [ -f "${BATS_TEST_TMPDIR}/umount.log" ]
    [ -z "$(ls -A "$tmp")" ]
}

@test "esp_probe mounts read-only" {
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho vfat\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 0
MOUNT
    printf '#!/bin/bash\nexit 0\n' > "${stub}/umount"
    chmod +x "${stub}/lsblk" "${stub}/mount" "${stub}/umount"
    PATH="${stub}:${PATH}" run esp_probe /dev/sdz1
    grep -qE -- '^-o ro /dev/sdz1' "$log"
}

@test "linux_installs never falls back to a bare read-only mount" {
    # `mount -o ro` on ext4 replays a dirty journal, which is a write to a
    # filesystem belonging to an operating system that is staying. The first
    # draft chained ro,noload -> ro,subvol=@ -> ro, so every ext4 whose noload
    # mount failed was written to. This is the same defect part_probe_os was
    # rewritten to remove.
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "/dev/sdz1 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 1
MOUNT
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -eq 0 ]
    grep -qF -- '-o ro,noload /dev/sdz1' "$log"
    assert_absent '[-]o ro /dev/sdz1' "$log"
    assert_absent '[-]o ro,subvol=@ /dev/sdz1' "$log"
}

@test "linux_installs never replays a btrfs log tree" {
    # subvol=@ alone still replays the log tree on mount. nologreplay is the
    # option that does not.
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "/dev/sdz1 btrfs 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 1
MOUNT
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -eq 0 ]
    grep -qF -- 'nologreplay' "$log"
    assert_absent '[-]o ro,subvol=@ /dev/sdz1' "$log"
    assert_absent '[-]o ro /dev/sdz1' "$log"
}

@test "linux_installs reports an install it could mount" {
    local stub="${BATS_TEST_TMPDIR}/bin" root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "$stub" "${root}/etc" "${root}/boot/grub"
    printf 'NAME="Arch Linux"\nID=arch\n' > "${root}/etc/os-release"
    printf '#!/bin/bash\necho "/dev/sdz1 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    # The stub mount binds nothing: it copies the fixture into the mountpoint
    # the function made, which is the only way to exercise the tree-reading
    # half without root or a loop device.
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
cp -a "${root}/." "\${!#}/"
exit 0
MOUNT
    printf '#!/bin/bash\nexit 0\n' > "${stub}/umount"
    chmod +x "${stub}/lsblk" "${stub}/mount" "${stub}/umount"
    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdz1 1b13ff14-95ae-46f1-b975-a4233c5ed17f yes Arch Linux" ]
}

@test "linux_installs skips the devices it is told to exclude" {
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "/dev/sdz1 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 1
MOUNT
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" run linux_installs /dev/sdz1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$log" ]
}

@test "linux_installs skips a row whose columns shifted" {
    # lsblk emits an empty FSTYPE for an unformatted partition and an empty
    # UUID for a filesystem that has none, and default-IFS read collapses the
    # run of spaces -- so a row can arrive with the wrong value in every
    # variable. A uuid that is not uuid-shaped is the tell, and chain_entry
    # would refuse it later anyway.
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    cat > "${stub}/lsblk" <<'LSBLK'
#!/bin/bash
echo "/dev/sdz  500107862016 "
echo "/dev/sdz1 ext4"
echo "/dev/sdz2 ext4 not-a-uuid"
LSBLK
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 1
MOUNT
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$log" ]
}

@test "linux_installs skips an encrypted root without mounting it" {
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "/dev/sdz1 crypto_LUKS 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 1
MOUNT
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$log" ]
}

@test "linux_installs fails instead of reporting no installs when lsblk fails" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\nexit 3\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -ne 0 ]
    [[ "$output" == *"lsblk"* ]]
}

@test "linux_installs leaves no mountpoint behind" {
    local stub="${BATS_TEST_TMPDIR}/bin" tmp="${BATS_TEST_TMPDIR}/mnt"
    mkdir -p "$stub" "$tmp"
    printf '#!/bin/bash\necho "/dev/sdz1 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    printf '#!/bin/bash\nexit 0\n' > "${stub}/mount"
    printf '#!/bin/bash\nexit 0\n' > "${stub}/umount"
    chmod +x "${stub}/lsblk" "${stub}/mount" "${stub}/umount"
    PATH="${stub}:${PATH}" TMPDIR="$tmp" run linux_installs
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$tmp")" ]
}

@test "fs_uuid_for_partuuid maps a partition guid to its filesystem uuid" {
    # efibootmgr identifies an entry's partition by its partition GUID, while
    # chain_entry's `search --fs-uuid` needs the filesystem's. Without the
    # translation an NVRAM-derived entry has no usable uuid at all.
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    cat > "${stub}/lsblk" <<'LSBLK'
#!/bin/bash
echo "/dev/sdz  "
echo "/dev/sdz1 db04a6e9-6005-473c-b45b-ac2ca8af3a2a 38BD-4D38"
echo "/dev/sdz2 620c1fcb-07fd-ca4f-a2a0-09c21869c7d6 283B-4CE7"
LSBLK
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run fs_uuid_for_partuuid DB04A6E9-6005-473C-B45B-AC2CA8AF3A2A
    [ "$status" -eq 0 ]
    [ "$output" = "38BD-4D38" ]
}

@test "fs_uuid_for_partuuid fails when the partition carries no filesystem uuid" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "/dev/sdz1 db04a6e9-6005-473c-b45b-ac2ca8af3a2a"\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run fs_uuid_for_partuuid db04a6e9-6005-473c-b45b-ac2ca8af3a2a
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "fs_uuid_for_partuuid fails when nothing matches" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "/dev/sdz1 620c1fcb-07fd-ca4f-a2a0-09c21869c7d6 283B-4CE7"\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run fs_uuid_for_partuuid db04a6e9-6005-473c-b45b-ac2ca8af3a2a
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "the inventory functions survive install.sh's set -euo pipefail" {
    # bats runs no test under `set -u` -- install.sh's `set -euo pipefail`
    # governs nothing here -- so a test that means to catch an unbound variable
    # or an errexit abort has to turn them on itself. A subshell is used rather
    # than `set -u` in the body so errexit is genuinely in force for the whole
    # sequence, including the trailing-`&&` returns that bit Task 6.
    #
    # Every call below is BARE. An earlier version wrote three of them as
    # `fn ... || true`, which put them in an AND-OR list -- and errexit is
    # suppressed inside a function called from one, so those three had no
    # coverage at all while the test's name claimed they did. The predicates
    # are therefore given inputs on which they must SUCCEED; their failure path
    # legitimately returns non-zero and aborting on it is the documented
    # contract, not a bug to test for here.
    local esp="${BATS_TEST_TMPDIR}/esp" empty="${BATS_TEST_TMPDIR}/empty"
    local stub="${BATS_TEST_TMPDIR}/survivebin" tmp="${BATS_TEST_TMPDIR}/survivetmp"
    mkdir -p "${esp}/EFI/GRUB" "${esp}/EFI/BOOT" "${esp}/grub" "$empty" "$stub" "$tmp"
    touch "${esp}/EFI/GRUB/grubx64.efi" "${esp}/EFI/BOOT/BOOTX64.EFI" "${esp}/grub/grub.cfg"
    # One stub branching on the column list, because the six shell-out
    # functions each ask lsblk a different question.
    cat > "${stub}/lsblk" <<'LSBLK'
#!/bin/bash
case "$*" in
    *PARTTYPE*)    echo "/dev/sdz1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 104857600 38BD-4D38" ;;
    *FSTYPE,UUID*) echo "/dev/sdz2 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f" ;;
    *PARTUUID*)    echo "/dev/sdz1 db04a6e9-6005-473c-b45b-ac2ca8af3a2a 38BD-4D38" ;;
    *FSTYPE*)      echo vfat ;;
esac
LSBLK
    cat > "${stub}/efibootmgr" <<'EFIBOOTMGR'
#!/bin/bash
printf 'BootCurrent: 0000\n'
printf 'Boot0000* Windows Boot Manager\tHD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI57494e\n'
EFIBOOTMGR
    printf '#!/bin/bash\nexit 0\n' > "${stub}/mount"
    printf '#!/bin/bash\nexit 0\n' > "${stub}/umount"
    chmod +x "${stub}/lsblk" "${stub}/efibootmgr" "${stub}/mount" "${stub}/umount"

    run env "PATH=${stub}:${PATH}" "TMPDIR=${tmp}" bash -c "set -euo pipefail
source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
source '${BATS_TEST_DIRNAME}/../lib/boot.sh'
# Tree walkers, on a populated ESP and on an empty one -- the two take
# different branches, and the empty one is where the trailing-&& returns live.
for d in '${esp}' '${empty}'; do
    esp_dir_inventory \"\$d\" >/dev/null
    esp_fallback_kind \"\$d\" >/dev/null
done
# Predicates, on inputs where each must succeed, so the call can stay bare.
esp_vendor_efi_path '${esp}' >/dev/null
esp_fallback_binary '${esp}' >/dev/null
esp_has_own_grub '${esp}'
bootloader_id_free '${esp}' ARCH_WORK
# Pure transforms.
efi_path_to_slashes '\\EFI\\BOOT\\BOOTX64.EFI' >/dev/null
printf 'x\n' | parse_esp_list >/dev/null
printf 'x\n' | parse_nvram_entries >/dev/null
printf 'x\n' | parse_nvram_loaders >/dev/null
# The six that shell out, none of which the earlier version touched.
esp_list >/dev/null
nvram_entries >/dev/null
nvram_loaders >/dev/null
esp_probe /dev/sdz1 >/dev/null
linux_installs >/dev/null
linux_installs /dev/sdz2 >/dev/null
fs_uuid_for_partuuid db04a6e9-6005-473c-b45b-ac2ca8af3a2a >/dev/null
echo SURVIVED"
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
}

@test "esp_probe reports the whole inventory for an esp it could read" {
    # The shape phase 6 consumes. Every other esp_probe test here exercises a
    # refusal path, and none of them would notice the success path losing a
    # line.
    local stub="${BATS_TEST_TMPDIR}/bin" src="${BATS_TEST_TMPDIR}/src"
    mkdir -p "$stub" "${src}/EFI/Microsoft/Boot" "${src}/EFI/BOOT" "${src}/grub"
    touch "${src}/EFI/Microsoft/Boot/bootmgfw.efi" "${src}/grub/grub.cfg"
    printf 'x systemd-boot x' > "${src}/EFI/BOOT/BOOTX64.EFI"
    printf '#!/bin/bash\necho vfat\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
cp -a "${src}/." "\${!#}/"
exit 0
MOUNT
    printf '#!/bin/bash\nexit 0\n' > "${stub}/umount"
    chmod +x "${stub}/lsblk" "${stub}/mount" "${stub}/umount"
    PATH="${stub}:${PATH}" run esp_probe /dev/sdz1
    [ "$status" -eq 0 ]
    [[ "$output" == *"vendor Microsoft"* ]]
    [[ "$output" == *"fallback yes"* ]]
    [[ "$output" == *"kind systemd-boot"* ]]
    [[ "$output" == *"owngrub yes"* ]]
    [[ "$output" == *"efipath /EFI/Microsoft/Boot/bootmgfw.efi"* ]]
}

# --- review round 2 -----------------------------------------------------------

@test "parse_nvram_loaders takes the path from the HD node it took the guid from" {
    # `=~` is leftmost-longest but UNANCHORED: when the run starting at the
    # first backslash cannot reach a ".EFI", the engine retries from a later
    # backslash and succeeds there. Measured before the fix, a legal FAT long
    # name with a space in it produced:
    #     0000 db04a6e9-... /grubx64.efi Neighbour OS
    # -- a well-formed entry chainloading a path that does not exist, which
    # chain_entry accepts because /grubx64.efi is a valid absolute EFI path.
    # The operator finds out at the boot menu.
    local fixture
    fixture=$(printf 'Boot0000* Neighbour OS\tHD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/\\EFI\\My Vendor\\grubx64.efi\n')
    local out
    out=$(parse_nvram_loaders <<<"$fixture" 2>/dev/null)
    # A space is outside chain_entry's character class, so no row is emitted --
    # but it must be dropped, never silently truncated to a different path.
    [ -z "$out" ]
    # And dropped LOUDLY: efi_path_to_slashes refuses the whole path on stderr,
    # naming it. Faithful extraction is what makes that diagnostic possible; a
    # truncated path is accepted everywhere and simply wrong.
    run parse_nvram_loaders <<<"$fixture"
    [[ "$output" == *"not an absolute EFI path"* ]]
    [[ "$output" == *"My Vendor"* ]]
}

@test "parse_nvram_loaders pairs the guid and the path from one device path node" {
    # Two HD nodes on a line took the guid from the first and the path from
    # wherever the unanchored search landed, which can be the second.
    local fixture
    fixture=$(printf 'Boot0000* Odd\tHD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/HD(2,GPT,620c1fcb-07fd-ca4f-a2a0-09c21869c7d6,0x0,0x0)/\\EFI\\B\\g.efi\n')
    run parse_nvram_loaders <<<"$fixture"
    [ "$status" -eq 0 ]
    [ "$output" = "0000 620c1fcb-07fd-ca4f-a2a0-09c21869c7d6 /EFI/B/g.efi Odd" ]
}

@test "parse_nvram_loaders ignores a loader path that precedes the HD node" {
    local fixture
    fixture=$(printf 'Boot0000* Odd\tFv(\\EFI\\decoy\\x.efi)/HD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/\\EFI\\B\\g.efi\n')
    run parse_nvram_loaders <<<"$fixture"
    [ "$output" = "0000 db04a6e9-6005-473c-b45b-ac2ca8af3a2a /EFI/B/g.efi Odd" ]
}

@test "parse_esp_list never hands a consumer a size where a uuid belongs" {
    # The header explains why UUID is read LAST on input: an empty middle field
    # shifts every later column. The record emitted put UUID back in the
    # middle, so an unformatted ESP -- the exact case the header is about --
    # gave a positional consumer uuid=[2147483648] and size=[].
    local out dev uuid size
    out=$(printf '/dev/sda1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 2147483648\n' | parse_esp_list)
    read -r dev uuid size <<<"$out"
    [ "$dev" = "/dev/sda1" ]
    [ "$size" = "2147483648" ]
    [ "$uuid" != "2147483648" ]
    # chain_entry must still refuse whatever stands in for the missing uuid.
    run chain_entry "X" "$uuid" "/EFI/B/g.efi"
    [ "$status" -ne 0 ]
}

@test "linux_installs reports a partition it could not mount instead of dropping it" {
    # The banner promises no probe answers "nothing found" because a tool
    # broke. An ext4 neighbour whose noload mount fails used to vanish with a
    # success status and nothing said, and phase 6 then had no entry for it.
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "/dev/sdz1 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    printf '#!/bin/bash\nexit 1\n' > "${stub}/mount"
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -eq 0 ]
    [[ "$output" == *"/dev/sdz1 1b13ff14-95ae-46f1-b975-a4233c5ed17f unknown"* ]]
    [[ "$output" == *"could not be read"* ]]
}

@test "linux_installs fails when it cannot create a mountpoint" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "/dev/sdz1 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    printf '#!/bin/bash\nexit 1\n' > "${stub}/mktemp"
    chmod +x "${stub}/lsblk" "${stub}/mktemp"
    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -ne 0 ]
    [[ "$output" == *"mountpoint"* ]]
}

@test "esp_vendor_efi_path prefers a shim in any vendor dir over a bare grub" {
    # The loop was vendor-major, so the candidate order only ranked loaders
    # WITHIN one vendor directory and the vendor was picked by glob collation.
    # That contradicts the Secure Boot reasoning the candidate order is written
    # for: chainloading a distro's grubx64.efi directly fails under SB, and
    # "arch" sorts before "fedora".
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/arch" "${esp}/EFI/fedora"
    touch "${esp}/EFI/arch/grubx64.efi" "${esp}/EFI/fedora/shimx64.efi" "${esp}/EFI/fedora/grubx64.efi"
    [ "$(esp_vendor_efi_path "$esp")" = "/EFI/fedora/shimx64.efi" ]
}

@test "_esp_resolve backtracks past a component that matches but leads nowhere" {
    # It committed to the first case-insensitive match by collation order and
    # never tried the second, so the miss landed on "fallback no" -- the answer
    # that makes removable_policy OFFER to overwrite \\EFI\\BOOT\\BOOTX64.EFI.
    local esp="${BATS_TEST_TMPDIR}/esp"
    # The empty directory is the one spelled exactly as asked for, so the
    # exact-match-first branch commits to it and the binary in the other one is
    # never reached.
    mkdir -p "${esp}/EFI/BOOT" "${esp}/EFI/bOOt"
    touch "${esp}/EFI/bOOt/BOOTX64.EFI"
    run esp_dir_inventory "$esp"
    [[ "$output" == *"fallback yes"* ]]
    [ "$(esp_fallback_binary "$esp")" = "${esp}/EFI/bOOt/BOOTX64.EFI" ]
}

@test "_esp_resolve finds an exact match and a differently-cased one" {
    local root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/EFI/BOOT"
    touch "${root}/EFI/BOOT/BOOTX64.EFI"
    [ "$(_esp_resolve "$root" "EFI/BOOT/BOOTX64.EFI")" = "${root}/EFI/BOOT/BOOTX64.EFI" ]
    [ "$(_esp_resolve "$root" "efi/boot/bootx64.efi")" = "${root}/EFI/BOOT/BOOTX64.EFI" ]
}

@test "_esp_resolve fails for a path that is not there" {
    local root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/EFI"
    run _esp_resolve "$root" "EFI/BOOT/BOOTX64.EFI"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_esp_resolve honours the required type so a directory cannot shadow a file" {
    # A directory named BOOTX64.EFI is legal on FAT. Returning it made
    # esp_fallback_binary's -f test fail, which reads as "no fallback here".
    local root="${BATS_TEST_TMPDIR}/r"
    mkdir -p "${root}/EFI/BOOT/BOOTX64.EFI" "${root}/EFI/boot2"
    touch "${root}/EFI/boot2/BOOTX64.EFI"
    run _esp_resolve "$root" "EFI/BOOT/BOOTX64.EFI" f
    [ "$status" -ne 0 ]
    [ "$(_esp_resolve "$root" "EFI/boot2/BOOTX64.EFI" f)" = "${root}/EFI/boot2/BOOTX64.EFI" ]
    [ "$(_esp_resolve "$root" "EFI/BOOT/BOOTX64.EFI" d)" = "${root}/EFI/BOOT/BOOTX64.EFI" ]
}

@test "nvram_loaders fails instead of reporting no loaders when efibootmgr fails" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "EFI variables are not supported" >&2\nexit 1\n' > "${stub}/efibootmgr"
    chmod +x "${stub}/efibootmgr"
    PATH="${stub}:${PATH}" run nvram_loaders
    [ "$status" -ne 0 ]
    [[ "$output" == *"nvram_loaders: efibootmgr failed"* ]]
    [[ "$output" != *"parse_nvram"* ]]
    [[ "$output" != *"_nvram_read"* ]]
    [[ "$output" == *"EFI variables are not supported"* ]]
}

@test "nvram_loaders reports the loaders efibootmgr lists" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    cat > "${stub}/efibootmgr" <<'EFIBOOTMGR'
#!/bin/bash
printf 'BootCurrent: 0000\n'
printf 'Boot0000* Windows Boot Manager\tHD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI57494e\n'
printf 'Boot0001* UEFI:CD/DVD Drive\tBBS(129,,0x0)\n'
EFIBOOTMGR
    chmod +x "${stub}/efibootmgr"
    PATH="${stub}:${PATH}" run nvram_loaders
    [ "$status" -eq 0 ]
    [ "$output" = "0000 db04a6e9-6005-473c-b45b-ac2ca8af3a2a /EFI/MICROSOFT/BOOT/BOOTMGFW.EFI Windows Boot Manager" ]
}

@test "fs_uuid_for_partuuid fails instead of reporting no match when lsblk fails" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\nexit 3\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run fs_uuid_for_partuuid db04a6e9-6005-473c-b45b-ac2ca8af3a2a
    [ "$status" -ne 0 ]
    [[ "$output" == *"lsblk"* ]]
}

@test "esp_probe removes its mountpoint when the mount fails" {
    local stub="${BATS_TEST_TMPDIR}/bin" tmp="${BATS_TEST_TMPDIR}/mnt"
    mkdir -p "$stub" "$tmp"
    printf '#!/bin/bash\necho vfat\n' > "${stub}/lsblk"
    printf '#!/bin/bash\nexit 32\n' > "${stub}/mount"
    chmod +x "${stub}/lsblk" "${stub}/mount"
    PATH="${stub}:${PATH}" TMPDIR="$tmp" run esp_probe /dev/sdz1
    [[ "$output" == *"fallback unknown"* ]]
    [ -z "$(ls -A "$tmp")" ]
}

@test "esp_fallback_kind aborts on a missing argument rather than answering none" {
    # It is the only probe that turned a programming error into an answer:
    # under set -u the ${1%/} abort happened inside a command substitution, so
    # only the subshell died and `|| { echo none; }` caught it -- reporting
    # "no bootloader here" for a call that never named an ESP.
    run bash -c "set -u
source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
source '${BATS_TEST_DIRNAME}/../lib/boot.sh'
esp_fallback_kind
echo REACHED"
    [ "$status" -ne 0 ]
    [[ "$output" != *"none"* ]]
    [[ "$output" != *"REACHED"* ]]
    # Positively, that it aborted for the reason claimed. Without this the
    # three assertions above are all satisfied by a status of 127 and no output
    # at all -- which is what a renamed function or a broken heredoc produces,
    # and the test would pass for the rest of its life without ever running
    # esp_fallback_kind.
    #
    # bash's own status for an expansion abort here IS 127, so bats prints a
    # BW01 "Command not found" warning for this run. It is expected and it is
    # not what happened. Do not quiet it with `run -127`: that pins an
    # undocumented bash exit status, and the day it changes this test starts
    # failing for a reason unrelated to what it checks. The assertion below is
    # what distinguishes the abort from a genuinely missing command.
    [[ "$output" == *"unbound variable"* ]]

    # And the control: the same harness, one argument, reaches the end. This is
    # what makes the negative assertions above mean something.
    run bash -c "set -u
source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
source '${BATS_TEST_DIRNAME}/../lib/boot.sh'
esp_fallback_kind '${BATS_TEST_TMPDIR}'
echo REACHED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"none"* ]]
    [[ "$output" == *"REACHED"* ]]
}

@test "bootloader_id_free's unsanitised ids resolve where the header says they do" {
    # Not reachable through bootloader_id_from, which is the only caller today.
    # Pinned because the header makes a claim about both shapes, and the claim
    # was wrong once already: "" was documented as reporting free while it
    # resolves EFI/ to the ESP's own EFI directory and reports taken.
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/ARCH"
    run bootloader_id_free "$esp" "OTHER"
    [ "$status" -eq 0 ]
    # FAT is case-insensitive, so both spellings are the one occupied directory.
    run bootloader_id_free "$esp" "ARCH"
    [ "$status" -eq 1 ]
    run bootloader_id_free "$esp" "arch"
    [ "$status" -eq 1 ]
    # The two shapes the header documents: each reports "not free", which is the
    # refusing direction, but for a path that is not \EFI\<id> at all.
    run bootloader_id_free "$esp" ""
    [ "$status" -eq 1 ]
    run bootloader_id_free "$esp" "../.."
    [ "$status" -eq 1 ]
}

@test "the nvram parsers do not leak _NV_ variables into the sourcing shell" {
    # _nvram_split assigns three unprefixed names under bash's dynamic scoping.
    # Undeclared, they landed in whatever sourced lib/boot.sh -- install.sh,
    # which runs under set -u and whose own locals are one collision away.
    #
    # Fed by REDIRECTION, not by a pipeline. `printf ... | parse_nvram_entries`
    # runs the parser in a subshell, so the assignments die with it and this
    # test would pass with every `local` deleted. That is also why the leak was
    # never observed in production -- _nvram_read pipes -- and why the guard is
    # still right: a caller reading a file into a parser does not subshell.
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
source '${BATS_TEST_DIRNAME}/../lib/boot.sh'
parse_nvram_loaders <<<\"\$(printf 'Boot0001* X\t%s' 'HD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x0,0x0)/\\EFI\\B\\g.efi')\"
parse_nvram_entries <<<'Boot0002* Y'
for v in _NV_NUM _NV_LABEL _NV_DP; do
    declare -p \"\$v\" >/dev/null 2>&1 && echo \"LEAKED \$v\"
done
echo DONE"
    [ "$status" -eq 0 ]
    # The parsers must still have worked -- a leak test that passes because
    # nothing was parsed proves nothing.
    [[ "$output" == *"0001 db04a6e9-6005-473c-b45b-ac2ca8af3a2a /EFI/B/g.efi X"* ]]
    [[ "$output" == *"0002 Y"* ]]
    [[ "$output" != *"LEAKED"* ]]
    [[ "$output" == *"DONE"* ]]
}

@test "chain_entry refuses a carriage return in the title" {
    # A CRLF /etc/os-release reaches this through linux_installs' NAME, and a
    # bare CR in a GRUB menu title is a display corruption nobody diagnoses.
    run chain_entry "$(printf 'Arch\r')" "1A2B-3C4D" "/EFI/X/grubx64.efi"
    [ "$status" -ne 0 ]
    [[ "$output" == *"carriage return"* ]]
}

# --- closing review ----------------------------------------------------------

@test "esp_fallback_binary aborts on a missing argument rather than reporting no fallback" {
    # The same swallowed set -u abort that esp_fallback_kind had, in the half
    # that matters more: this one's "no" becomes esp_dir_inventory's
    # "fallback no", which is the answer removable_policy acts on by offering to
    # overwrite \\EFI\\BOOT\\BOOTX64.EFI -- on this machine, the operator's own
    # bootloader. ${1%/} expanded inside $( ) killed only the subshell, and
    # `|| return 1` caught a programming error and returned it as an answer.
    run bash -c "set -u
source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
source '${BATS_TEST_DIRNAME}/../lib/boot.sh'
if esp_fallback_binary; then echo 'FALLBACK YES'; else echo 'FALLBACK NO'; fi
echo REACHED"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unbound variable"* ]]
    # The point of the test: the run must not continue past the abort with an
    # answer in hand. See the BW01 note on the esp_fallback_kind test above.
    [[ "$output" != *"FALLBACK NO"* ]]
    [[ "$output" != *"REACHED"* ]]

    # Control: one argument, and the same harness reaches the end and answers.
    run bash -c "set -u
source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
source '${BATS_TEST_DIRNAME}/../lib/boot.sh'
if esp_fallback_binary '${BATS_TEST_TMPDIR}'; then echo 'FALLBACK YES'; else echo 'FALLBACK NO'; fi
echo REACHED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FALLBACK NO"* ]]
    [[ "$output" == *"REACHED"* ]]
}

@test "linux_installs strips the carriage return a CRLF os-release leaves in the name" {
    # chain_entry refuses a bare CR, and under the installer's set -euo pipefail
    # that aborts phase 6 -- because of a file on a partition that is only
    # staying. The refusal is the backstop; the producer is where it is fixed.
    local stub="${BATS_TEST_TMPDIR}/bin" src="${BATS_TEST_TMPDIR}/src"
    mkdir -p "$stub" "${src}/etc" "${src}/boot/grub"
    printf 'NAME="Neighbour Linux"\r\nID=neighbour\r\n' > "${src}/etc/os-release"
    printf '#!/bin/bash\necho "/dev/sdz1 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
cp -a "${src}/." "\${!#}/"
exit 0
MOUNT
    printf '#!/bin/bash\nexit 0\n' > "${stub}/umount"
    chmod +x "${stub}/lsblk" "${stub}/mount" "${stub}/umount"

    local out
    out=$(PATH="${stub}:${PATH}" linux_installs 2>/dev/null)
    [ "$out" = "/dev/sdz1 1b13ff14-95ae-46f1-b975-a4233c5ed17f yes Neighbour Linux" ]
    # Asserted directly rather than only via the string compare, so the failure
    # message names the actual defect if this ever regresses.
    [[ "$out" != *$'\r'* ]]

    # End to end: the name this produces must be one chain_entry accepts.
    local name
    name=${out#* * * }
    run chain_entry "$name" "1A2B-3C4D" "/EFI/X/grubx64.efi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"menuentry 'Neighbour Linux' {"* ]]
}

@test "linux_installs reports a mounted partition whose os-release it cannot read" {
    # Asymmetric with the mount-failure path until now: this one mounted, could
    # not read, and emitted nothing at all. "Present but unreadable" is a
    # filesystem nobody read, which is the case the banner is about.
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho "/dev/sdz1 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    # The stub builds the unreadable file at the mountpoint rather than copying
    # one in: `cp -a` has to read the source, so a mode-000 fixture never
    # reaches the destination and the test would exercise the ABSENT branch
    # instead -- which it did, and passed, before this was fixed.
    cat > "${stub}/mount" <<'MOUNT'
#!/bin/bash
mkdir -p "${!#}/etc"
: > "${!#}/etc/os-release"
chmod 000 "${!#}/etc/os-release"
exit 0
MOUNT
    printf '#!/bin/bash\nexit 0\n' > "${stub}/umount"
    chmod +x "${stub}/lsblk" "${stub}/mount" "${stub}/umount"

    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -eq 0 ]
    [[ "$output" == *"/dev/sdz1 1b13ff14-95ae-46f1-b975-a4233c5ed17f unknown (unreadable)"* ]]
    [[ "$output" == *"unreadable /etc/os-release"* ]]
}

@test "linux_installs drops a partition with no os-release without calling it unreadable" {
    # The one "nothing here" answer in this function that is a fact about the
    # machine rather than a tool breaking: a data partition is not a Linux
    # install. The target machine's own sda2 -- 172.8G ext4, unlabelled -- is
    # this shape, and it must not appear in phase 6's list as an unknown.
    local stub="${BATS_TEST_TMPDIR}/bin" src="${BATS_TEST_TMPDIR}/src"
    mkdir -p "$stub" "${src}/some-data"
    printf '#!/bin/bash\necho "/dev/sdz1 ext4 1b13ff14-95ae-46f1-b975-a4233c5ed17f"\n' > "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
cp -a "${src}/." "\${!#}/"
exit 0
MOUNT
    printf '#!/bin/bash\nexit 0\n' > "${stub}/umount"
    chmod +x "${stub}/lsblk" "${stub}/mount" "${stub}/umount"

    PATH="${stub}:${PATH}" run linux_installs
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- registering into an already-installed system --------------------------

@test "backup_path picks an unused suffix" {
    local f="${BATS_TEST_TMPDIR}/grub.cfg"
    echo x > "$f"
    [ "$(backup_path "$f" WORK)" = "${f}.bak.WORK.1" ]
    touch "${f}.bak.WORK.1"
    [ "$(backup_path "$f" WORK)" = "${f}.bak.WORK.2" ]
}

# -e, not -f. A name already taken by a directory is taken: `cp -a x dir/`
# lands the copy inside it and reports success, so the backup this function
# promises would not exist under the name it handed back.
@test "backup_path treats a name taken by a directory as taken" {
    local f="${BATS_TEST_TMPDIR}/grub.cfg"
    echo x > "$f"
    mkdir "${f}.bak.WORK.1"
    [ "$(backup_path "$f" WORK)" = "${f}.bak.WORK.2" ]
}

@test "register_into_foreign_grub writes both files and backs them up" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    printf '#!/bin/sh\nexec tail -n +3 $0\n' > "${root}/etc/grub.d/40_custom"
    chmod 755 "${root}/etc/grub.d/40_custom"
    printf 'menuentry "existing" {}\n' > "${root}/boot/grub/grub.cfg"

    run register_into_foreign_grub "$root" WORK "$(chain_entry 'Arch (work)' 1A2B-3C4D /EFI/WORK/grubx64.efi)"
    [ "$status" -eq 0 ]
    grep -q 'Arch (work)' "${root}/etc/grub.d/40_custom"
    grep -q 'Arch (work)' "${root}/boot/grub/grub.cfg"
    grep -q 'existing'    "${root}/boot/grub/grub.cfg"
    [ -f "${root}/etc/grub.d/40_custom.bak.WORK.1" ]
    [ -f "${root}/boot/grub/grub.cfg.bak.WORK.1" ]
}

@test "register_into_foreign_grub reports the backups it made" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    : > "${root}/etc/grub.d/40_custom"
    : > "${root}/boot/grub/grub.cfg"
    run register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"40_custom.bak.WORK.1"* ]]
    [[ "$output" == *"grub.cfg.bak.WORK.1"* ]]
}

@test "register_into_foreign_grub keeps 40_custom executable" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    printf '#!/bin/sh\n' > "${root}/etc/grub.d/40_custom"
    chmod 755 "${root}/etc/grub.d/40_custom"
    : > "${root}/boot/grub/grub.cfg"
    register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    [ "$(stat -c %a "${root}/etc/grub.d/40_custom")" = "755" ]
}

# grub-mkconfig ignores a 40_custom it cannot execute, which is a silent no-op
# at that system's next kernel update rather than an error anyone sees.
@test "register_into_foreign_grub creates a missing 40_custom executable" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/boot/grub"
    : > "${root}/boot/grub/grub.cfg"
    run register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "${root}/etc/grub.d/40_custom")" = "755" ]
    # Nothing existed to back up, so nothing is reported for it.
    [[ "$output" != *"40_custom.bak"* ]]
    [[ "$output" == *"grub.cfg.bak.WORK.1"* ]]
}

# The executable bit is only half of it: grub-mkconfig *runs* each file in
# /etc/grub.d and appends its stdout to grub.cfg. A file created holding the
# raw block is executable and still contributes nothing -- the menuentry lines
# run as commands, the shell prints "command not found" and exits non-zero
# with an empty stdout. So assert what grub-mkconfig would actually capture.
@test "a 40_custom created from scratch emits its block when run" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/boot/grub"
    : > "${root}/boot/grub/grub.cfg"
    register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    run "${root}/etc/grub.d/40_custom"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BEGIN arch-installer:WORK"* ]]
    [[ "$output" == *"menuentry 'x' {}"* ]]
    [[ "$output" == *"END arch-installer:WORK"* ]]
}

# The preamble must not be left behind when the write is refused: status 1
# promises the other system is byte-for-byte as it was. The block carries a
# marker line, which custom_cfg_upsert refuses.
@test "register_into_foreign_grub removes a 40_custom it created when the write is refused" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/boot/grub"
    : > "${root}/boot/grub/grub.cfg"
    run register_into_foreign_grub "$root" WORK "# BEGIN arch-installer:OTHER"
    [ "$status" -eq 1 ]
    [ ! -e "${root}/etc/grub.d/40_custom" ]
}

@test "register_into_foreign_grub run twice does not duplicate the entry" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    : > "${root}/etc/grub.d/40_custom"
    : > "${root}/boot/grub/grub.cfg"
    register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    [ "$(grep -c 'BEGIN arch-installer:WORK' "${root}/boot/grub/grub.cfg")" -eq 1 ]
    [ "$(grep -c 'BEGIN arch-installer:WORK' "${root}/etc/grub.d/40_custom")" -eq 1 ]
}

@test "register_into_foreign_grub keeps the second backup on a re-run" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    : > "${root}/etc/grub.d/40_custom"
    : > "${root}/boot/grub/grub.cfg"
    register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    register_into_foreign_grub "$root" WORK "menuentry 'y' {}"
    [ -f "${root}/boot/grub/grub.cfg.bak.WORK.1" ]
    [ -f "${root}/boot/grub/grub.cfg.bak.WORK.2" ]
    # The first backup is the copy that predates anything this tool did, and
    # it is the one that must survive: an operator undoing a second run wants
    # the file as it was before the FIRST.
    [ ! -s "${root}/boot/grub/grub.cfg.bak.WORK.1" ]
    grep -q "menuentry 'x'" "${root}/boot/grub/grub.cfg.bak.WORK.2"
}

@test "register_into_foreign_grub refuses a root with no grub.cfg" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d"
    run register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    [ "$status" -eq 1 ]
    # Not just non-zero: a file defining nothing exits 127, which "-ne 0"
    # reports as a pass.
    [[ "$output" == *"boot/grub/grub.cfg"* ]]
    [ ! -e "${root}/etc/grub.d/40_custom" ]
}

# A /boot/grub/grub.cfg linked somewhere else is an ordinary thing to find on a
# machine somebody dual-boots, and the `[[ -f ]]` guard above does not catch it
# because -f dereferences. custom_cfg_upsert refuses a symlink too -- but only
# after this function has already copied it, and `cp -a` of a symlink is not a
# backup of anything. The assertion that matters is the absent .bak.
@test "register_into_foreign_grub refuses a symlinked config without copying it" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub" "${root}/real"
    : > "${root}/etc/grub.d/40_custom"
    printf 'menuentry "existing" {}\n' > "${root}/real/grub.cfg"
    ln -s "${root}/real/grub.cfg" "${root}/boot/grub/grub.cfg"

    run register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"symlink"* ]]
    # Nothing was written, so nothing was backed up either.
    [ -z "$(find "$root" -name '*.bak.WORK.*' -print -quit)" ]
    [ ! -s "${root}/etc/grub.d/40_custom" ]
    grep -q 'existing' "${root}/real/grub.cfg"
    [ "$(grep -c 'arch-installer' "${root}/real/grub.cfg" || true)" -eq 0 ]
}

# custom_cfg_upsert refuses a file that already holds two blocks for one id,
# permanently, until a human edits it. Both targets come back untouched, so a
# .bak next to them is a puzzle with no answer -- there is nothing to undo.
@test "register_into_foreign_grub leaves no backup when it writes nothing" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    printf '# BEGIN arch-installer:WORK\n# END arch-installer:WORK\n# BEGIN arch-installer:WORK\n# END arch-installer:WORK\n' \
        > "${root}/etc/grub.d/40_custom"
    printf 'menuentry "existing" {}\n' > "${root}/boot/grub/grub.cfg"

    run register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"already holds 2 blocks"* ]]
    [ -z "$(find "$root" -name '*.bak.WORK.*' -print -quit)" ]
    [ "$(grep -c 'menuentry' "${root}/boot/grub/grub.cfg")" -eq 1 ]
}

# The other half of that pair. 40_custom took the block and grub.cfg refused
# it, so one file on a system that is staying HAS been edited -- the backup is
# the only copy of what was there before and has to be both kept and reported.
@test "register_into_foreign_grub keeps and reports the backups on a partial write" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    printf '#!/bin/sh\n' > "${root}/etc/grub.d/40_custom"
    printf '# BEGIN arch-installer:WORK\n# END arch-installer:WORK\n# BEGIN arch-installer:WORK\n# END arch-installer:WORK\n' \
        > "${root}/boot/grub/grub.cfg"

    run register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"40_custom.bak.WORK.1"* ]]
    [[ "$output" == *"grub.cfg.bak.WORK.1"* ]]
    [ -f "${root}/etc/grub.d/40_custom.bak.WORK.1" ]
    [ -f "${root}/boot/grub/grub.cfg.bak.WORK.1" ]
    grep -q "menuentry 'x'" "${root}/etc/grub.d/40_custom"
    # The backup is the pre-edit copy, which is what makes it worth reporting.
    [ "$(grep -c 'menuentry' "${root}/etc/grub.d/40_custom.bak.WORK.1" || true)" -eq 0 ]
}

# The single hardest rule in this phase. Running the neighbour's grub-mkconfig
# regenerates its whole menu from the live ISO's view of the machine, and can
# fail outright on a GRUB version mismatch -- replacing a working config with
# one nobody asked for, on a machine whose other OS has to keep booting.
@test "register_into_foreign_grub never runs a foreign grub-mkconfig" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc/grub.d" "${root}/boot/grub"
    : > "${root}/etc/grub.d/40_custom"
    : > "${root}/boot/grub/grub.cfg"
    grub-mkconfig()  { echo 'FOREIGN_GENERATOR_RAN grub-mkconfig'; }
    grub2-mkconfig() { echo 'FOREIGN_GENERATOR_RAN grub2-mkconfig'; }
    grub-install()   { echo 'FOREIGN_GENERATOR_RAN grub-install'; }
    chroot()         { echo 'FOREIGN_GENERATOR_RAN chroot'; }
    arch-chroot()    { echo 'FOREIGN_GENERATOR_RAN arch-chroot'; }
    run register_into_foreign_grub "$root" WORK "menuentry 'x' {}"
    [ "$status" -eq 0 ]
    [[ "$output" != *"FOREIGN_GENERATOR_RAN"* ]]
    # The control: without it a function that had stopped doing anything at
    # all would satisfy the assertion above.
    grep -q "menuentry 'x'" "${root}/boot/grub/grub.cfg"
}

@test "lib/boot.sh contains no generator that would rewrite a foreign menu" {
    local f="${BATS_TEST_DIRNAME}/../lib/boot.sh" hits
    # Comment lines are excluded on purpose: this file argues about
    # grub-install and grub-mkconfig at length and has to keep doing so. The
    # count below is the control -- it proves the pattern and the path are
    # right, so an empty result from the filtered grep means "no call" rather
    # than "grep matched nothing anywhere".
    [ "$(grep -cE 'grub-mkconfig|grub2-mkconfig|grub-install|arch-chroot' "$f")" -gt 0 ]
    hits=$(grep -nE 'grub-mkconfig|grub2-mkconfig|grub-install|arch-chroot' "$f" \
           | grep -vE '^[0-9]+:[[:space:]]*#') || true
    [ -z "$hits" ]
}

# --- neighbour_marker_id ---------------------------------------------------

@test "neighbour_marker_id maps an EFI path into custom_cfg_upsert's charset" {
    # custom_cfg_upsert refuses an id outside [A-Za-z0-9_-], and every EFI
    # path carries slashes and a dot.
    [ "$(neighbour_marker_id 38BD-4D38 /EFI/Microsoft/Boot/bootmgfw.efi)" \
      = "NEIGHBOUR_38BD-4D38__EFI_Microsoft_Boot_bootmgfw_efi" ]
    run custom_cfg_upsert "${BATS_TEST_TMPDIR}/cfg" \
        "$(neighbour_marker_id 38BD-4D38 /EFI/Microsoft/Boot/bootmgfw.efi)" "menuentry 'x' {}"
    [ "$status" -eq 0 ]
}

# Never from a device name: the two NVMe disks on this machine exchanged
# kernel names between one boot and the next, and custom_cfg_upsert matches
# its markers exactly -- so an id spelled NEIGHBOUR_nvme1n1p1 leaves the old
# block in place and appends a second one. A duplicated menu row per reboot.
@test "neighbour_marker_id is the same across two runs of the same loader" {
    local a b
    a=$(neighbour_marker_id 283B-4CE7 /EFI/BOOT/BOOTX64.EFI)
    b=$(neighbour_marker_id 283B-4CE7 /EFI/BOOT/BOOTX64.EFI)
    [ "$a" = "$b" ]
    # Two loaders on one ESP must not collide onto one id: the second upsert
    # would then delete the first one's block.
    [ "$a" != "$(neighbour_marker_id 283B-4CE7 /EFI/arch/grubx64.efi)" ]
}

@test "neighbour_marker_id refuses an empty uuid or path" {
    run neighbour_marker_id "" /EFI/BOOT/BOOTX64.EFI
    [ "$status" -ne 0 ]
    [[ "$output" == *"need a filesystem uuid and an EFI path"* ]]
    run neighbour_marker_id 283B-4CE7 ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"need a filesystem uuid and an EFI path"* ]]
}

# --- neighbour_loaders -----------------------------------------------------
#
# The fixtures below are this machine's real inventory, read out of the live
# `efibootmgr -v` and `lsblk` (see the header of test/boot.bats' target file
# for the measured layout). The dp:/data: continuation lines are left out --
# they are indented, so _nvram_split drops them, and the existing parser cases
# already pin that -- but the option data efibootmgr appends to the device
# path with no separator is kept verbatim, because it is what the path regex
# has to survive.

real_nvram() {
    cat <<'NVRAM'
BootCurrent: 0005
Timeout: 0 seconds
BootOrder: 0005,0000,0001,0002,0003
Boot0000* Windows Boot Manager	HD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI57494e444f5753000100000088000000780000004200430044004f0042004a004500430054003d007b00390064006500610038003600320063002d0035006300640064002d0034006500370030002d0061006300630031002d006600330032006200330034003400640034003700390035007d00000061000100000010000000040000007fff0400
Boot0001* UEFI:CD/DVD Drive	BBS(129,,0x0)
Boot0002* UEFI:Removable Device	BBS(130,,0x0)
Boot0003* UEFI:Network Device	BBS(131,,0x0)
Boot0005* UEFI OS	HD(5,GPT,620c1fcb-07fd-ca4f-a2a0-09c21869c7d6,0x186a0000,0x113000)/\EFI\BOOT\BOOTX64.EFI0000424f
NVRAM
}

real_lsblk_stub() {
    lsblk() {
        case "$*" in
            *PARTTYPE*)
                printf '/dev/nvme1n1  500107862016 \n'
                printf '/dev/nvme1n1p1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 104857600 38BD-4D38\n'
                printf '/dev/nvme1n1p5 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 576716800 283B-4CE7\n'
                printf '/dev/nvme1n1p7 0fc63daf-8483-4772-8e79-3d69d8477de4 281225986048 1b13ff14-95ae-46f1-b975-a4233c5ed17f\n'
                ;;
            *PARTUUID*)
                printf '/dev/nvme1n1p1 db04a6e9-6005-473c-b45b-ac2ca8af3a2a 38BD-4D38\n'
                printf '/dev/nvme1n1p5 620c1fcb-07fd-ca4f-a2a0-09c21869c7d6 283B-4CE7\n'
                printf '/dev/nvme1n1p7 1a6bfe58-3d64-4b2f-9d2a-6c0b8f1f0b11 1b13ff14-95ae-46f1-b975-a4233c5ed17f\n'
                ;;
        esac
    }
}

# The measured on-disk spellings. nvme1n1p5 was read directly (it is mounted
# at /boot/EFI on this machine and holds EFI/BOOT/BOOTX64.EFI and nothing
# else); the Windows ESP carries the mixed-case directory its installer
# creates, which is NOT how efibootmgr prints the same path.
real_esp_probe_stub() {
    esp_probe() {
        case "$1" in
            /dev/nvme1n1p1) printf 'vendor Microsoft\nfallback no\nkind none\nowngrub no\nefipath /EFI/Microsoft/Boot/bootmgfw.efi\n' ;;
            /dev/nvme1n1p5) printf 'fallback yes\nkind grub\nowngrub no\nefipath /EFI/BOOT/BOOTX64.EFI\n' ;;
            *)              printf 'fallback unknown\nkind unreadable\n' ;;
        esac
    }
}

# The case this exists for. On this machine BOTH routes name BOTH loaders:
# `Boot0005 UEFI OS` is /EFI/BOOT/BOOTX64.EFI on nvme1n1p5, which esp_probe
# also finds, and `Boot0000 Windows Boot Manager` is the bootmgfw esp_probe
# finds on nvme1n1p1. Undeduplicated, this machine's menu gets two rows per
# operating system.
@test "neighbour_loaders emits one row per loader on this machine's real inventory" {
    real_lsblk_stub
    real_esp_probe_stub
    efibootmgr() { real_nvram; }
    run neighbour_loaders /dev/nvme0n1p9 1111-2222
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "38BD-4D38 /EFI/MICROSOFT/BOOT/BOOTMGFW.EFI Windows Boot Manager" ]
    [ "${lines[1]}" = "283B-4CE7 /EFI/BOOT/BOOTX64.EFI UEFI OS" ]
}

# FAT is case-insensitive, and the two routes disagree about case: efibootmgr
# prints \EFI\MICROSOFT\BOOT\BOOTMGFW.EFI while the directory Windows created
# is spelled EFI/Microsoft/Boot. An exact-match dedupe passes the Arch ESP
# (both routes spell it the same) and lets the Windows row through twice.
@test "neighbour_loaders dedupes across a difference of case" {
    real_lsblk_stub
    real_esp_probe_stub
    efibootmgr() { real_nvram; }
    run neighbour_loaders /dev/nvme0n1p9 1111-2222
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -ci bootmgfw)" -eq 1 ]
    [ "$(printf '%s\n' "$output" | grep -ci bootx64)" -eq 1 ]
}

# The control for the two cases above: the same fixtures with the NVRAM route
# emptied still produce both rows, from the ESP scan alone. Without it, a
# dedupe that had started dropping everything would read as a pass.
@test "neighbour_loaders finds both loaders from the ESP scan alone" {
    real_lsblk_stub
    real_esp_probe_stub
    efibootmgr() { printf 'BootCurrent: 0005\n'; }
    run neighbour_loaders /dev/nvme0n1p9 1111-2222
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" == *"38BD-4D38 /EFI/Microsoft/Boot/bootmgfw.efi"* ]]
    [[ "$output" == *"283B-4CE7 /EFI/BOOT/BOOTX64.EFI"* ]]
}

# ...and from NVRAM alone, which is the route that needs neither root nor a
# mount and is the only one that reaches a loader sharing OUR ESP.
@test "neighbour_loaders finds both loaders from NVRAM alone" {
    real_lsblk_stub
    esp_probe() { printf 'fallback unknown\nkind unreadable\n'; }
    efibootmgr() { real_nvram; }
    run neighbour_loaders /dev/nvme0n1p9 1111-2222
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" == *"Windows Boot Manager"* ]]
    [[ "$output" == *"UEFI OS"* ]]
}

# Our own loader must not be offered back to us. Excluded by (fs uuid, path)
# and never by uuid alone: on a shared ESP the neighbour we are here for has
# exactly the same filesystem uuid we do.
@test "neighbour_loaders excludes our own loader but keeps a neighbour on the same ESP" {
    real_lsblk_stub
    real_esp_probe_stub
    efibootmgr() { real_nvram; }
    # We adopted nvme1n1p5, whose fs uuid is 283B-4CE7, and installed as WORK.
    # The neighbour's \EFI\BOOT\BOOTX64.EFI is on that same ESP.
    run neighbour_loaders /dev/nvme1n1p5 283B-4CE7 /EFI/WORK/grubx64.efi
    [ "$status" -eq 0 ]
    [[ "$output" == *"283B-4CE7 /EFI/BOOT/BOOTX64.EFI"* ]]
    [[ "$output" != *"/EFI/WORK/grubx64.efi"* ]]

    # ...and with the fallback path claimed by --removable, that same row is
    # ours and disappears.
    run neighbour_loaders /dev/nvme1n1p5 283B-4CE7 /EFI/WORK/grubx64.efi /EFI/BOOT/BOOTX64.EFI
    [ "$status" -eq 0 ]
    [[ "$output" != *"BOOTX64.EFI"* ]]
    [[ "$output" == *"38BD-4D38"* ]]
}

# By the time phase 6 runs, our own ESP is mounted read-write at /mnt/boot, and
# under --dry-run it was never formatted at all -- so the scan skips it by
# device path rather than probing it. A neighbour sharing it comes back through
# NVRAM, which needs no mount.
@test "neighbour_loaders does not probe the ESP this install is using" {
    real_lsblk_stub
    esp_probe() {
        echo "ESP_PROBE_RAN $1" >&2
        printf 'fallback no\nkind grub\nowngrub no\nefipath /EFI/somebody/grubx64.efi\n'
    }
    efibootmgr() { printf 'BootCurrent: 0005\n'; }
    run neighbour_loaders /dev/nvme1n1p5 283B-4CE7
    [ "$status" -eq 0 ]
    [[ "$output" != *"ESP_PROBE_RAN /dev/nvme1n1p5"* ]]
    [[ "$output" != *"283B-4CE7 /EFI/somebody/grubx64.efi"* ]]
    # The control: the other ESP on the same fixture IS probed and does produce
    # a row, so the two assertions above are about the skip and not about a
    # scan that stopped running.
    [[ "$output" == *"ESP_PROBE_RAN /dev/nvme1n1p1"* ]]
    [[ "$output" == *"38BD-4D38 /EFI/somebody/grubx64.efi"* ]]
}

# The exclusion is case-folded for the same reason the dedupe is.
@test "neighbour_loaders excludes our own loader regardless of case" {
    real_lsblk_stub
    esp_probe() { printf 'fallback unknown\nkind unreadable\n'; }
    efibootmgr() { real_nvram; }
    run neighbour_loaders /dev/nvme0n1p9 38bd-4d38 /efi/microsoft/boot/bootmgfw.efi
    [ "$status" -eq 0 ]
    [[ "$output" != *"Windows Boot Manager"* ]]
    [[ "$output" == *"UEFI OS"* ]]
}

# An lsblk that broke must not report a machine with no other bootloaders:
# that is the answer under which phase 6 adds nothing and says nothing is
# there.
@test "neighbour_loaders fails instead of reporting no neighbours when lsblk fails" {
    lsblk() { return 1; }
    esp_probe() { printf 'fallback unknown\n'; }
    efibootmgr() { printf 'BootCurrent: 0005\n'; }
    run neighbour_loaders /dev/nvme0n1p9 1111-2222
    [ "$status" -ne 0 ]
    [[ "$output" == *"EFI System Partitions"* ]]
}

@test "neighbour_loaders fails instead of reporting no neighbours when efibootmgr fails" {
    real_lsblk_stub
    real_esp_probe_stub
    efibootmgr() { echo 'no efi' >&2; return 1; }
    run neighbour_loaders /dev/nvme0n1p9 1111-2222
    [ "$status" -ne 0 ]
    [[ "$output" == *"firmware"* ]]
}

# A vendor directory called "My Vendor" is legal on FAT, and esp_vendor_efi_path
# does not validate what it returns. Emitted as-is it puts a space in the
# middle of a record whose LAST field is the only one allowed to hold one, so
# every consumer reads "/EFI/My" as the path -- which chain_entry accepts and
# which chainloads nothing.
@test "neighbour_loaders refuses an ESP path it cannot represent in a record" {
    lsblk() {
        case "$*" in
            *PARTTYPE*) printf '/dev/sdz1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 1073741824 AAAA-BBBB\n' ;;
            *PARTUUID*) printf '/dev/sdz1 aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee AAAA-BBBB\n' ;;
        esac
    }
    efibootmgr() { printf 'BootCurrent: 0000\n'; }
    esp_probe() { printf 'fallback no\nkind none\nowngrub no\nefipath /EFI/My Vendor/grubx64.efi\n'; }
    run neighbour_loaders /dev/sdy1 1111-2222
    [ "$status" -eq 0 ]
    [[ "$output" != *"AAAA-BBBB /EFI/My"* ]]
    [[ "$output" == *"not an absolute EFI path"* ]]

    # The control: the same ESP with a representable path does produce a row,
    # so the refusal above is the path being rejected and not the scan having
    # stopped reaching esp_probe.
    esp_probe() { printf 'fallback no\nkind none\nowngrub no\nefipath /EFI/MyVendor/grubx64.efi\n'; }
    run neighbour_loaders /dev/sdy1 1111-2222
    [ "$status" -eq 0 ]
    [[ "$output" == *"AAAA-BBBB /EFI/MyVendor/grubx64.efi"* ]]
}

# parse_esp_list emits a literal "-" for an ESP that has never been formatted.
# It is not a uuid, and there is nothing on it to chainload.
@test "neighbour_loaders skips an ESP with no filesystem uuid" {
    _uuid=""
    lsblk() {
        case "$*" in
            *PARTTYPE*) printf '/dev/sdz1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b 1073741824 %s\n' "$_uuid" ;;
            *PARTUUID*) printf '/dev/sdz1 aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee %s\n' "$_uuid" ;;
        esac
    }
    esp_probe() { echo 'ESP_PROBE_RAN' >&2; printf 'fallback no\nefipath /EFI/BOOT/BOOTX64.EFI\n'; }
    efibootmgr() { printf 'BootCurrent: 0000\n'; }
    run neighbour_loaders /dev/sdy1 1111-2222
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # The control: the same ESP with a uuid is probed and does produce a row.
    # Without it, a scan that had stopped enumerating anything at all would
    # satisfy the empty-output assertion above.
    _uuid="AAAA-BBBB"
    run neighbour_loaders /dev/sdy1 1111-2222
    [ "$status" -eq 0 ]
    [[ "$output" == *"ESP_PROBE_RAN"* ]]
    [[ "$output" == *"AAAA-BBBB /EFI/BOOT/BOOTX64.EFI"* ]]
}

@test "neighbour_loaders refuses to run without our own ESP and uuid" {
    # On the message, not merely on a non-zero status: a missing function
    # exits 127, which "-ne 0" reports as a pass, and "neighbour_loaders" is
    # a substring of bash's own "command not found" line.
    run neighbour_loaders /dev/sdz1
    [ "$status" -ne 0 ]
    [[ "$output" == *"need this install's ESP device and filesystem uuid"* ]]
}

# --- nvram_register_removable ------------------------------------------------

# Stub lsblk and efibootmgr for the registration tests.
#
# One stub covers both efibootmgr roles, because nvram_register_removable
# reads NVRAM (`efibootmgr -v`) before deciding whether to write it: a stub
# that answered only the read would make "no entry was created" pass for the
# wrong reason. Everything that is not the read is recorded in
# NVRAM_WRITE_LOG, one invocation per line, and nothing is executed -- no test
# in this suite may reach this machine's real NVRAM.
#
# <efibootmgr -v fixture text>
nvram_stub() {
    NVRAM_STUB_BIN="${BATS_TEST_TMPDIR}/bin"
    NVRAM_WRITE_LOG="${BATS_TEST_TMPDIR}/efibootmgr-writes.log"
    mkdir -p "$NVRAM_STUB_BIN"
    : > "$NVRAM_WRITE_LOG"
    # Via a file rather than interpolated into the stub: the fixtures are full
    # of backslashes and newlines, and both survive a `cat` unchanged.
    printf '%s' "$1" > "${BATS_TEST_TMPDIR}/nvram.txt"
    cat > "${NVRAM_STUB_BIN}/efibootmgr" <<EFIBOOTMGR
#!/bin/bash
if [[ "\$1" == "-v" ]]; then
    cat '${BATS_TEST_TMPDIR}/nvram.txt'
    exit 0
fi
printf '%s\n' "\$*" >> '${NVRAM_WRITE_LOG}'
EFIBOOTMGR
    # PATH,PKNAME,PARTN,PARTUUID, in lsblk's own shape: whole-disk rows carry
    # no parent, no number and no partition GUID, and the two disks number
    # their partitions differently in their names.
    cat > "${NVRAM_STUB_BIN}/lsblk" <<'LSBLK'
#!/bin/bash
printf '%s\n' \
    '/dev/nvme0n1' \
    '/dev/nvme0n1p1 /dev/nvme0n1 1 db04a6e9-6005-473c-b45b-ac2ca8af3a2a' \
    '/dev/nvme0n1p5 /dev/nvme0n1 5 620c1fcb-07fd-ca4f-a2a0-09c21869c7d6' \
    '/dev/sda' \
    '/dev/sda2 /dev/sda 2 7b8e0d2c-1111-2222-3333-444455556666'
LSBLK
    chmod +x "${NVRAM_STUB_BIN}/efibootmgr" "${NVRAM_STUB_BIN}/lsblk"
}

# NVRAM holding one Windows entry and nothing for either of our partitions.
nvram_fixture_windows() {
    printf 'BootCurrent: 0000\nTimeout: 0 seconds\nBootOrder: 0000\n'
    printf 'Boot0000* Windows Boot Manager\tHD(1,GPT,db04a6e9-6005-473c-b45b-ac2ca8af3a2a,0x800,0x32000)/\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI57494e\n'
}

# Call nvram_register_removable with the stubs on PATH and lib/disk.sh's real
# run_cmd, real because the whole point of the --dry-run case is that the
# wrapper is what withholds the write. DRY_RUN is whatever the caller set.
run_register() {
    source "${BATS_TEST_DIRNAME}/../lib/disk.sh"
    local PATH="${NVRAM_STUB_BIN}:${PATH}"
    run nvram_register_removable "$@"
}

@test "nvram_register_removable creates a firmware entry for the fallback path" {
    nvram_stub "$(nvram_fixture_windows)"
    DRY_RUN=false
    run_register /dev/nvme0n1p5 ARCH_WORK
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$NVRAM_WRITE_LOG")" -eq 1 ]
    grep -qF -- '--create' "$NVRAM_WRITE_LOG"
    grep -qF -- '--disk /dev/nvme0n1 --part 5' "$NVRAM_WRITE_LOG"
    grep -qF -- '--loader \EFI\BOOT\BOOTX64.EFI' "$NVRAM_WRITE_LOG"
    grep -qF -- '--label ARCH_WORK' "$NVRAM_WRITE_LOG"
}

# The disk and the partition number are what efibootmgr wants, and they cannot
# come from stripping digits off the device name: /dev/sda2 and /dev/nvme0n1p5
# separate their number from their disk differently, and getting it wrong
# writes a boot entry pointing at some other partition.
@test "nvram_register_removable derives the disk and partition number per device" {
    nvram_stub "$(nvram_fixture_windows)"
    DRY_RUN=false
    run_register /dev/sda2 ARCH_WORK
    [ "$status" -eq 0 ]
    grep -qF -- '--disk /dev/sda --part 2' "$NVRAM_WRITE_LOG"
    [[ "$(cat "$NVRAM_WRITE_LOG")" != *"/dev/sda2"* ]]
}

@test "nvram_register_removable adds no second entry for a partition the firmware already boots" {
    nvram_stub "$(nvram_fixture_windows
        printf 'Boot0005* UEFI OS\tHD(5,GPT,620c1fcb-07fd-ca4f-a2a0-09c21869c7d6,0x186a0000,0x113000)/\\EFI\\BOOT\\BOOTX64.EFI0000424f\n')"
    DRY_RUN=false
    run_register /dev/nvme0n1p5 ARCH_WORK
    [ "$status" -eq 0 ]
    [ ! -s "$NVRAM_WRITE_LOG" ]
    # Naming the entry, so the operator can find the row in the firmware menu
    # under whatever label it already carries.
    [[ "$output" == *"0005"* ]]
    [[ "$output" == *"UEFI OS"* ]]
    # And naming the path in the form efibootmgr reports it: info puts the
    # message in printf's %s, so \E stays two characters.
    [[ "$output" == *'\EFI\BOOT\BOOTX64.EFI'* ]]
}

# The dedupe key is (partition, path), not the path alone: the fallback path
# exists once per ESP, and another disk's is not ours.
@test "nvram_register_removable still registers when another partition holds the fallback entry" {
    nvram_stub "$(nvram_fixture_windows
        printf 'Boot0005* UEFI OS\tHD(2,GPT,7b8e0d2c-1111-2222-3333-444455556666,0x800,0x32000)/\\EFI\\BOOT\\BOOTX64.EFI\n')"
    DRY_RUN=false
    run_register /dev/nvme0n1p5 ARCH_WORK
    [ "$status" -eq 0 ]
    grep -qF -- '--disk /dev/nvme0n1 --part 5' "$NVRAM_WRITE_LOG"
}

# ... and not the partition alone: an entry for our ESP naming some other
# loader on it leaves the fallback path unregistered.
@test "nvram_register_removable still registers when our partition holds a different loader" {
    nvram_stub "$(nvram_fixture_windows
        printf 'Boot0006* Other\tHD(5,GPT,620c1fcb-07fd-ca4f-a2a0-09c21869c7d6,0x800,0x32000)/\\EFI\\OTHER\\grubx64.efi\n')"
    DRY_RUN=false
    run_register /dev/nvme0n1p5 ARCH_WORK
    [ "$status" -eq 0 ]
    grep -qF -- '--disk /dev/nvme0n1 --part 5' "$NVRAM_WRITE_LOG"
}

@test "nvram_register_removable writes no NVRAM under --dry-run" {
    nvram_stub "$(nvram_fixture_windows)"
    DRY_RUN=true
    run_register /dev/nvme0n1p5 ARCH_WORK
    [ "$status" -eq 0 ]
    [ ! -s "$NVRAM_WRITE_LOG" ]
    [[ "$output" == *"[dry-run]"* ]]
    [[ "$output" == *"efibootmgr"* ]]

    # The control. "No write happened" is satisfied by a harness that never
    # reached the writer at all -- a renamed function, a stub that stopped
    # recording -- so the same call with DRY_RUN off has to produce one.
    DRY_RUN=false
    run_register /dev/nvme0n1p5 ARCH_WORK
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$NVRAM_WRITE_LOG")" -eq 1 ]
}

# "efibootmgr is not installed" and "the firmware lists no entries" are not the
# same fact, and only the second says nothing is there to duplicate. Registering
# on the strength of a read that failed is how a machine ends up with a new
# boot entry on every re-run.
@test "nvram_register_removable writes nothing when it cannot read NVRAM first" {
    nvram_stub "$(nvram_fixture_windows)"
    cat > "${NVRAM_STUB_BIN}/efibootmgr" <<EFIBOOTMGR
#!/bin/bash
if [[ "\$1" == "-v" ]]; then
    echo "EFI variables are not supported on this system." >&2
    exit 1
fi
printf '%s\n' "\$*" >> '${NVRAM_WRITE_LOG}'
EFIBOOTMGR
    chmod +x "${NVRAM_STUB_BIN}/efibootmgr"
    DRY_RUN=false
    run_register /dev/nvme0n1p5 ARCH_WORK
    [ "$status" -ne 0 ]
    [ ! -s "$NVRAM_WRITE_LOG" ]
    [[ "$output" == *"nvram_register_removable"* ]]
    [[ "$output" == *"boot entries"* ]]
}

@test "nvram_register_removable refuses a device lsblk does not list" {
    nvram_stub "$(nvram_fixture_windows)"
    DRY_RUN=false
    run_register /dev/nvme0n1p9 ARCH_WORK
    [ "$status" -ne 0 ]
    [ ! -s "$NVRAM_WRITE_LOG" ]
    # On a distinctive substring, not merely on a non-zero status: a function
    # that had been renamed exits 127, and bash's own "command not found" line
    # both satisfies "-ne 0" and contains the function's name.
    [[ "$output" == *"does not list"* ]]
    [[ "$output" == *"/dev/nvme0n1p9"* ]]
}

# A whole-disk row has no partition number and no partition GUID. Handing
# efibootmgr a disk with no --part, or matching an empty GUID against the
# NVRAM inventory, are both worse than refusing.
@test "nvram_register_removable refuses a whole disk" {
    nvram_stub "$(nvram_fixture_windows)"
    DRY_RUN=false
    run_register /dev/nvme0n1 ARCH_WORK
    [ "$status" -ne 0 ]
    [ ! -s "$NVRAM_WRITE_LOG" ]
    [[ "$output" == *"does not list"* ]]
    [[ "$output" == *"/dev/nvme0n1"* ]]
}

# Every id in this installer comes from bootloader_id_from, which emits only
# [A-Z0-9_]. A label from anywhere else arrived by a route that skipped it, and
# one that reads as an option ends up in the command run_cmd prints for the
# operator to copy.
@test "nvram_register_removable refuses a label outside the bootloader id character set" {
    nvram_stub "$(nvram_fixture_windows)"
    DRY_RUN=false
    run_register /dev/nvme0n1p5 "--delete-bootnum"
    [ "$status" -ne 0 ]
    [ ! -s "$NVRAM_WRITE_LOG" ]
    [[ "$output" == *"is not a bootloader id"* ]]
    run_register /dev/nvme0n1p5 "my install"
    [ "$status" -ne 0 ]
    [ ! -s "$NVRAM_WRITE_LOG" ]
    [[ "$output" == *"is not a bootloader id"* ]]
}

# This is the only function in lib/boot.sh that install.sh calls from a phase
# running under `set -euo pipefail`, and both of its successful paths end in a
# construct that has bitten this file before: a `while read` loop that returns
# from inside itself, and a run_cmd whose failure is caught with `||`.
@test "nvram_register_removable survives install.sh's set -euo pipefail" {
    nvram_stub "$(nvram_fixture_windows
        printf 'Boot0005* UEFI OS\tHD(5,GPT,620c1fcb-07fd-ca4f-a2a0-09c21869c7d6,0x186a0000,0x113000)/\\EFI\\BOOT\\BOOTX64.EFI0000424f\n')"
    # Bare calls, on inputs where each must succeed: /dev/sda2 has no entry and
    # takes the write path, /dev/nvme0n1p5 has one and takes the early return.
    # The refusal paths legitimately return non-zero, and install.sh's
    # chroot_register_nvram is where that is caught.
    run env "PATH=${NVRAM_STUB_BIN}:${PATH}" bash -c "set -euo pipefail
source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
source '${BATS_TEST_DIRNAME}/../lib/disk.sh'
source '${BATS_TEST_DIRNAME}/../lib/boot.sh'
DRY_RUN=false nvram_register_removable /dev/sda2 ARCH_WORK
nvram_register_removable /dev/nvme0n1p5 ARCH_WORK
DRY_RUN=true nvram_register_removable /dev/sda2 ARCH_WORK
echo SURVIVED"
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
}
