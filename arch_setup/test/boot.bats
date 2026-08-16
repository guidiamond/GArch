#!/usr/bin/env bats

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
    # The id is one path component and one --bootloader-id argument. Dropping
    # characters instead of mapping them would let two different names collide
    # on one ESP directory, and a surviving newline would make the id two
    # arguments the first time it is interpolated unquoted.
    [ "$(bootloader_id_from "///")" = "___" ]
    [ "$(bootloader_id_from "$(printf 'a\nb')")" = "A_B" ]
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
    [[ "$(cat "$f")" != *"first"* ]]
}

@test "custom_cfg_upsert run twice leaves exactly one block" {
    local f="${BATS_TEST_TMPDIR}/40_custom"
    custom_cfg_upsert "$f" WORK "first" 0755
    custom_cfg_upsert "$f" WORK "second" 0755
    [ "$(grep -c '# BEGIN arch-installer:WORK' "$f")" -eq 1 ]
    [[ "$(cat "$f")" == *"second"* ]]
    [[ "$(cat "$f")" != *"first"* ]]
}

@test "custom_cfg_upsert leaves another install's block alone" {
    local f="${BATS_TEST_TMPDIR}/40_custom"
    custom_cfg_upsert "$f" WORK     "work block"     0755
    custom_cfg_upsert "$f" PERSONAL "personal block" 0755
    [[ "$(cat "$f")" == *"work block"* ]]
    [[ "$(cat "$f")" == *"personal block"* ]]
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
    local dir="${BATS_TEST_TMPDIR}/ro"
    mkdir -p "$dir"
    chmod 500 "$dir"
    run custom_cfg_upsert "${dir}/40_custom" WORK "block" 0755
    chmod 700 "$dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"temp file"* ]]
    [ ! -e "${dir}/40_custom" ]
}
