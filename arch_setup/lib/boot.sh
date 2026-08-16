#!/bin/bash
# Boot environment: what is already installed, and what to write so that
# everything on the machine stays reachable. Reads disks; writes only the two
# files custom_cfg_upsert is pointed at.
# Requires lib/ui.sh to be sourced first.
# shellcheck shell=bash

# _echo_e_literal <string> -- the string with every backslash doubled.
#
# lib/ui.sh prints through `echo -e`, which eats backslash escapes. The values
# these generators refuse are mostly EFI paths as efibootmgr reports them, so
# the refusal message is exactly where a backslash run shows up: measured,
# "\EFI\BOOT\BOOTX64.EFI" printed as "^[FI\BOOT\BOOTX64.EFI", telling the
# operator the path is wrong while showing them a different path. Doubling
# first means echo -e collapses each pair back to the one backslash.
_echo_e_literal() { printf '%s' "${1//\\/\\\\}"; }

# --- pure generators -------------------------------------------------------

# bootloader_id_from <name> -> a GRUB --bootloader-id.
#
# The id becomes a directory name on a FAT32 ESP, so the character set is FAT's,
# not the shell's. Truncated at 16 because a longer one is legal but unreadable
# in the firmware's own boot menu, which is where it shows up when NVRAM is the
# only thing that survived.
#
# Unsafe characters are mapped, never dropped: dropping them would let two
# different names land on the same ESP directory, where the second install
# overwrites the first one's bootloader.
bootloader_id_from() {
    local name=$1 id
    id=${name^^}
    id=${id//[^A-Z0-9_]/_}
    id=${id:0:16}
    [[ -n "$id" ]] || {
        error "bootloader_id_from: '$(_echo_e_literal "$name")' leaves nothing usable as an id"
        return 1
    }
    echo "$id"
}

# removable_policy <has_fallback yes|no> <esp_is_new yes|no>
#   -> forbid | offer-default-yes | offer-default-no
#
# `grub-install --removable` writes \EFI\BOOT\BOOTX64.EFI, the path the firmware
# falls back to when NVRAM has nothing. That makes it the right thing to write
# on an ESP that is ours, and a way to destroy another operating system's only
# bootloader on an ESP that is not -- there is exactly one such path per ESP and
# grub-install overwrites it without asking.
#
# On the machine this was written for, the personal Arch install *is* that
# fallback binary, so "forbid when one already exists" is not a hypothetical.
#
# Both arguments must be a literal yes or no. A probe that could not read an
# ESP hands back "" or something else, and the answer for an unknown ESP is
# not the conservative "offer" -- it is a refusal, because "offer" still puts
# the operator one keystroke away from overwriting a bootloader we failed to
# look at.
removable_policy() {
    local has_fallback=$1 esp_is_new=$2 arg
    for arg in "$has_fallback" "$esp_is_new"; do
        case "$arg" in
            yes|no) ;;
            *) error "removable_policy: expected 'yes' or 'no', got '$(_echo_e_literal "$arg")'"
               return 1 ;;
        esac
    done
    if [[ "$has_fallback" == "yes" ]]; then
        echo "forbid"
    elif [[ "$esp_is_new" == "yes" ]]; then
        echo "offer-default-yes"
    else
        echo "offer-default-no"
    fi
}

# chain_entry <title> <esp_fs_uuid> <efi_path> -> a GRUB menuentry.
#
# Chainloading a complete EFI binary rather than loading the other system's
# kernel directly: the two GRUBs then share no modules and no config, so their
# versions are independent and neither one's grub-mkconfig can break the other.
#
# It is also the only thing that works when the other root is encrypted --
# os-prober mounts a candidate root to identify it, and cannot mount LUKS.
#
# The refusals below are the same choice grub_cmdline_add makes: a title with a
# quote in it would close the menuentry's quoting and turn the rest into GRUB
# commands, and none of these characters belongs in any of these fields. Note
# that the efi_path rule rejects the backslash form efibootmgr prints -- the
# caller converts to slashes, because a chainloader line silently boots nothing
# and only says so at the boot menu.
chain_entry() {
    local title=$1 uuid=$2 efi_path=$3
    case "$title" in
        "")
            error "chain_entry: refusing an empty title -- a menu row nobody can identify"
            return 1 ;;
        *"'"*|*$'\n'*)
            error "chain_entry: title must not contain a single quote or a newline: '$(_echo_e_literal "$title")'"
            return 1 ;;
    esac
    [[ "$uuid" =~ ^[A-Za-z0-9-]+$ ]] \
        || { error "chain_entry: '$(_echo_e_literal "$uuid")' is not a filesystem UUID"; return 1; }
    [[ "$efi_path" =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || { error "chain_entry: '$(_echo_e_literal "$efi_path")' is not an absolute EFI path"; return 1; }
    cat <<ENTRY
menuentry '${title}' {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root ${uuid}
    chainloader ${efi_path}
}
ENTRY
}

# custom_cfg_upsert <file> <marker_id> <block> [mode]
#
# Replaces the region between the markers, or appends it. Idempotent: running
# the installer twice leaves one block, not two, which a plain >> cannot
# promise and which matters because both files this is pointed at belong to a
# system that is already working.
#
# The mode argument is not decoration. /etc/grub.d/40_custom is only read by
# grub-mkconfig if it is executable, and mktemp creates 0600 whatever the umask
# -- so an upsert that did not restore the mode would silently drop the entry
# from that system's next regenerated config, months later.
#
# This writes unconditionally and does not go through run_cmd, the same as
# chroot_write_config. Callers that honour --dry-run must not call it.
custom_cfg_upsert() {
    local file=$1 id=$2 block=$3 mode=${4:-0644}
    local tmp begin end
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] \
        || { error "custom_cfg_upsert: marker id must be [A-Za-z0-9_-], got '$(_echo_e_literal "$id")'"; return 1; }
    begin="# BEGIN arch-installer:${id}"
    end="# END arch-installer:${id}"

    # A block carrying a marker line of its own ends the region early, so the
    # next upsert strips part of it and leaves the rest as an orphan menuentry
    # that nothing will ever match again. Prefixing a newline so the pattern
    # only has to match "\n<marker>" -- otherwise a marker on the block's first
    # line slips past.
    case $'\n'"$block" in
        *$'\n'"# BEGIN arch-installer:"*|*$'\n'"# END arch-installer:"*)
            error "custom_cfg_upsert: the block carries an arch-installer marker line, which would break the delimiters in $(_echo_e_literal "$file")"
            return 1 ;;
    esac

    [[ -f "$file" ]] && mode=$(stat -c %a "$file" 2>/dev/null || echo "$mode")

    tmp=$(mktemp "${file}.XXXXXX") \
        || { error "custom_cfg_upsert: cannot create a temp file next to $(_echo_e_literal "$file")"; return 1; }

    if [[ -f "$file" ]]; then
        # Exact line comparison, not a regex: the marker id is validated above,
        # but a grep -v pattern would still be one metacharacter away from
        # deleting lines this has no business touching.
        awk -v b="$begin" -v e="$end" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip   { print }
        ' "$file" > "$tmp" || { rm -f "$tmp"; error "custom_cfg_upsert: failed to read $(_echo_e_literal "$file")"; return 1; }
    fi

    # Every failure below removes the temp file before returning: it is a
    # sibling of the target, so in /etc/grub.d a leaked one is a second copy of
    # this entry in every config that system regenerates from then on.
    if ! { printf '%s\n' "$begin"; printf '%s\n' "$block"; printf '%s\n' "$end"; } >> "$tmp"; then
        rm -f "$tmp"; error "custom_cfg_upsert: failed to write $(_echo_e_literal "$file")"; return 1
    fi
    # chmod before the rename, not after: between the two there is a moment
    # where a 0600 40_custom is the live one, and a grub-mkconfig landing there
    # skips it.
    if ! chmod "$mode" "$tmp"; then
        rm -f "$tmp"; error "custom_cfg_upsert: failed to chmod $(_echo_e_literal "$file")"; return 1
    fi
    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"; error "custom_cfg_upsert: failed to move $(_echo_e_literal "$file") into place"; return 1
    fi
}
