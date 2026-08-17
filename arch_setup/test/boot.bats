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
    # lib/ui.sh prints through `echo -e`, so an unescaped \E in the message
    # becomes an ESC character: the operator is told the path is wrong while
    # being shown a different path. Measured before the fix:
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
              nvram_entries esp_probe linux_installs fs_uuid_for_partuuid; do
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
}

@test "bootloader_id_free is false when the vendor dir exists" {
    local esp="${BATS_TEST_TMPDIR}/esp"
    mkdir -p "${esp}/EFI/GRUB"
    run bootloader_id_free "$esp" GRUB
    [ "$status" -ne 0 ]
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
    # lib/ui.sh prints through `echo -e`, so a bare \E in the message becomes an
    # ESC character and the operator is shown a path other than the one that
    # was refused. This function's entire input domain is backslash paths.
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
    [ "$output" = "/dev/sda1  2147483648" ]
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
}

@test "the inventory functions survive install.sh's set -euo pipefail" {
    # bats runs no test under `set -u` -- install.sh's `set -euo pipefail`
    # governs nothing here -- so a test that means to catch an unbound variable
    # or an errexit abort has to turn them on itself. A subshell is used rather
    # than `set -u` in the body so that errexit is genuinely in force for the
    # whole sequence, including the trailing-`&&` returns that bit Task 6.
    local esp="${BATS_TEST_TMPDIR}/esp" empty="${BATS_TEST_TMPDIR}/empty"
    mkdir -p "${esp}/EFI/GRUB" "${esp}/EFI/BOOT" "$empty"
    touch "${esp}/EFI/GRUB/grubx64.efi" "${esp}/EFI/BOOT/BOOTX64.EFI"
    run bash -c "set -euo pipefail
source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
source '${BATS_TEST_DIRNAME}/../lib/boot.sh'
for d in '${esp}' '${empty}'; do
    esp_dir_inventory \"\$d\" >/dev/null
    esp_fallback_kind \"\$d\" >/dev/null
    esp_vendor_efi_path \"\$d\" >/dev/null || true
    esp_has_own_grub \"\$d\" || true
    bootloader_id_free \"\$d\" ARCH_WORK || true
done
efi_path_to_slashes '\\EFI\\BOOT\\BOOTX64.EFI' >/dev/null
printf 'x\n' | parse_esp_list >/dev/null
printf 'x\n' | parse_nvram_entries >/dev/null
printf 'x\n' | parse_nvram_loaders >/dev/null
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
