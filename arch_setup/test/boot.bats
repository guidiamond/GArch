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
    # "a/b c" into ABC and silently shorten every id, and a dropped newline
    # would splice two lines into one id that then becomes two arguments the
    # first time it is interpolated unquoted.
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
