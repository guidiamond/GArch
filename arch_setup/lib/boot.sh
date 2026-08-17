#!/bin/bash
# Boot environment: what to write so that everything already on the machine
# stays reachable. Nothing here reads a disk or destroys anything -- the only
# write is to the one file custom_cfg_upsert is pointed at.
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
# Unsafe characters are mapped, never dropped. This does not eliminate
# collisions -- "my box" and "my/box" both become MY_BOX either way -- but
# dropping causes strictly more of them, because "ab" would then collide with
# "a/b" as well, and it silently shortens every id, so the string the operator
# has to pick out of the firmware's own boot menu stops resembling the name
# they typed.
bootloader_id_from() {
    local name=$1 id
    id=${name^^}
    id=${id//[^A-Z0-9_]/_}
    id=${id:0:16}
    # An all-underscore id is a legal FAT directory and a useless one: this id
    # is what the operator has to recognise in the firmware's own boot menu,
    # which is the only menu left when NVRAM is all that survived.
    [[ "$id" =~ [A-Z0-9] ]] || {
        error "bootloader_id_from: '$(_echo_e_literal "$name")' leaves nothing usable as an id -- it has no letters or digits"
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
    # Shape, not just character set: a bare "-" passed a [A-Za-z0-9-]+ rule and
    # emitted `search --fs-uuid --set=root -`, which matches nothing and leaves
    # chainloader resolving against whatever root was set -- the same "boots
    # nothing and only says so at the boot menu" failure the path rule avoids.
    # FAT's XXXX-XXXX covers every ESP; 8-4-4-4-12 covers everything else.
    [[ "$uuid" =~ ^([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})$ ]] \
        || { error "chain_entry: '$(_echo_e_literal "$uuid")' is not a filesystem UUID"; return 1; }
    [[ "$efi_path" =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || { error "chain_entry: '$(_echo_e_literal "$efi_path")' is not an absolute EFI path"; return 1; }
    # Both partmaps, as grub-mkconfig emits: search needs the module for the
    # label it is enumerating, and the disk this entry names is whatever the
    # inventory found, not necessarily GPT.
    cat <<ENTRY
menuentry '${title}' {
    insmod part_gpt
    insmod part_msdos
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root ${uuid}
    chainloader ${efi_path}
}
ENTRY
}

# --- config files (writers) ------------------------------------------------

# custom_cfg_upsert <file> <marker_id> <block> [mode]
#
# Removes any existing block for this id and appends a fresh one at the end of
# the file. Idempotent: running the installer twice leaves one block, not two,
# which a plain >> cannot promise and which matters because both files this is
# pointed at belong to a system that is already working.
#
# The block always ends up at the *end*, it is not rewritten where it stood.
# Two of our own ids in one file is enough to show it: write AAA then BBB, then
# re-run AAA, and BBB is now first. Phase 6 writes a Windows entry and an Arch
# entry into the same file, so this is the ordinary case and not an edge one.
# Everything that followed the rewritten block shifts up by one, and a
# GRUB_DEFAULT set by index then selects a different operating system -- it has
# to be set by title or by id, never by number.
#
# The mode argument is not decoration. /etc/grub.d/40_custom is only read by
# grub-mkconfig if it is executable, and mktemp creates 0600 whatever the umask
# -- so an upsert that did not set the mode would silently drop the entry from
# that system's next regenerated config, months later. It applies to a file
# this creates; an existing file keeps its own mode and ACL.
#
# Known limitation: the marker comparison is exact, so a target converted to
# CRLF line endings stops matching and each run appends another block. That is
# duplicate menu entries, not a broken boot -- content outside the markers is
# still preserved, which is the guarantee that matters. Pinned by a test.
#
# This writes unconditionally and does not go through run_cmd, the same as
# chroot_write_config. Callers that honour --dry-run must not call it.
custom_cfg_upsert() {
    local file=$1 id=$2 block=$3 mode=${4:-0644}
    local _ccu_tmp="" begin end n_begin n_end link_target
    # A backstop, not the mechanism -- every failure below still removes the
    # temp file explicitly. This only catches a return path a later edit
    # forgets. It deliberately does not trap INT/TERM: a trap set inside a
    # function persists in the caller after it returns (measured), so trapping
    # them here would leave install.sh with a handler that swallows Ctrl-C for
    # the rest of a destructive run. A signal can therefore still leak the
    # temp file; that is the lesser fault.
    #
    # The _ccu_ prefix is the one ask_password uses, for the same reason. A
    # RETURN trap is not inherited by other functions, but it does stay
    # registered after this one returns and fires again at the end of the next
    # `source`, so a plain `tmp` would put an rm one name collision away from
    # a path this function never created.
    #
    # ${_ccu_tmp:-}, not "$_ccu_tmp": by that later RETURN event the local is
    # gone, and under install.sh's `set -u` the bare form aborts the installer
    # on an unbound variable -- the guard meant to make the trap harmless was
    # itself the thing that killed the run (measured). No bats test sees this,
    # because bats does not run under set -u.
    trap '[[ -z "${_ccu_tmp:-}" ]] || rm -f "$_ccu_tmp"' RETURN
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

    # A symlink is replaced by the rename, so the real config would keep its old
    # content and silently stop receiving this block -- and the replacement
    # would take the *link's* mode, which is always 0777, because stat -c %a
    # does not dereference. In /etc/grub.d that is a world-writable file root
    # executes on every regeneration. Fedora and RHEL ship /boot/grub2/grub.cfg
    # as exactly such a symlink into the ESP, and writing into another distro's
    # config is what this function is for, so this is a path we will meet.
    if [[ -L "$file" ]]; then
        # readlink -f canonicalises, so it fails and prints nothing when any
        # component of the target is missing -- which named the file as "a
        # symlink to ", the one message the operator needs in order to act.
        link_target=$(readlink -f -- "$file" 2>/dev/null) \
            || link_target=$(readlink -- "$file" 2>/dev/null) \
            || link_target="(unreadable)"
        error "custom_cfg_upsert: $(_echo_e_literal "$file") is a symlink to $(_echo_e_literal "$link_target"); point at that path instead"
        return 1
    fi
    # [[ -f ]] is false for a directory, and `mv tmp somedir` moves the temp
    # file *into* it and reports success -- so pointing at /etc/grub.d instead
    # of /etc/grub.d/40_custom used to leave an executable stray file there
    # that grub-mkconfig runs forever and no marker will ever match.
    if [[ -e "$file" && ! -f "$file" ]]; then
        error "custom_cfg_upsert: $(_echo_e_literal "$file") exists and is not a regular file"
        return 1
    fi

    # An unmatched BEGIN sets awk's skip flag with nothing left to clear it, so
    # every line to EOF would be dropped -- silently, reporting success, in a
    # working system's bootloader config. We never write an orphan (the marker
    # guard above and the atomic rename below both hold), so this means the
    # file was hand-edited, and guessing where the block ends is not ours.
    if [[ -f "$file" ]]; then
        n_begin=$(grep -cFx -- "$begin" "$file" || true)
        n_end=$(grep -cFx -- "$end" "$file" || true)
        if [[ "$n_begin" != "$n_end" ]]; then
            error "custom_cfg_upsert: the arch-installer:${id} markers in $(_echo_e_literal "$file") are not a matched pair (${n_begin} BEGIN, ${n_end} END); refusing to guess where the block ends"
            return 1
        fi
        # Counted separately from the pairing check, which would otherwise
        # report two whole blocks as "not a matched pair" while naming two of
        # each. A second complete block is a different fault: the original
        # collapsed them silently, and which one is ours is not knowable.
        # Reachable through the CRLF limitation documented above.
        if (( n_begin > 1 )); then
            error "custom_cfg_upsert: $(_echo_e_literal "$file") already holds ${n_begin} blocks for arch-installer:${id}, expected at most one; refusing to guess which is ours"
            return 1
        fi
    fi

    _ccu_tmp=$(mktemp "${file}.XXXXXX") \
        || { error "custom_cfg_upsert: cannot create a temp file next to $(_echo_e_literal "$file")"; return 1; }

    if [[ -f "$file" ]]; then
        # Exact line comparison, not a regex: the marker id is validated above,
        # but a grep -v pattern would still be one metacharacter away from
        # deleting lines this has no business touching.
        awk -v b="$begin" -v e="$end" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip   { print }
        ' "$file" > "$_ccu_tmp" || { rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to read $(_echo_e_literal "$file")"; return 1; }
    fi

    # Every *handled* failure below removes the temp file before returning --
    # signals are the trap's problem, and it cannot cover them. The file is a
    # sibling of the target, so in /etc/grub.d a leaked one is a second copy of
    # this entry in every config that system regenerates from then on, and the
    # window between the mode being set and the rename leaks it at the
    # target's mode rather than mktemp's 0600.
    if ! { printf '%s\n' "$begin"; printf '%s\n' "$block"; printf '%s\n' "$end"; } >> "$_ccu_tmp"; then
        rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to write $(_echo_e_literal "$file")"; return 1
    fi
    # Mode before the rename, not after: between the two there is a moment where
    # a 0600 40_custom is the live one, and a grub-mkconfig landing there skips
    # it.
    #
    # For an existing target, cp --attributes-only rather than
    # `chmod $(stat -c %a)`: %a reports the ACL *mask* in the group bits, so an
    # ACL'd 0644 file reads back as 0664 and restoring that turns the mask into
    # a real group-write bit while dropping the ACL entirely (measured).
    # --attributes-only copies mode and ACL and no data, so the block just
    # written to the temp file survives.
    if [[ -f "$file" ]]; then
        if ! cp --attributes-only --preserve=mode -- "$file" "$_ccu_tmp"; then
            rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to copy the mode of $(_echo_e_literal "$file")"; return 1
        fi
    elif ! chmod "$mode" "$_ccu_tmp"; then
        rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to chmod $(_echo_e_literal "$file")"; return 1
    fi
    if ! mv "$_ccu_tmp" "$file"; then
        rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to move $(_echo_e_literal "$file") into place"; return 1
    fi
}
