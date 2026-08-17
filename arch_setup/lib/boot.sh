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

# efi_path_to_slashes <path> -> the same EFI path written with forward slashes.
#
# efibootmgr and the UEFI spec both write \EFI\MICROSOFT\BOOT\BOOTMGFW.EFI;
# GRUB's chainloader wants /EFI/MICROSOFT/BOOT/BOOTMGFW.EFI. chain_entry
# refuses the backslash form rather than mangling it silently, so this is the
# one place the conversion happens -- and every NVRAM-derived entry has to pass
# through it or it is refused at the point where it matters.
#
# It lives here, beside chain_entry, rather than in the inventory: it is a pure
# transform, and it exists to satisfy chain_entry's contract. It validates with
# the same rule chain_entry does, so a caller learns here that a path is
# unusable rather than after the menu entry has been written.
#
# Refuses rather than repairs a relative path. Every EFI file path node is
# absolute, so one that is not did not come from a file path node at all --
# efibootmgr prints BBS(129,,0x0) for the firmware's own CD and network rows,
# and prefixing a slash onto that would produce a chainloader line naming a
# device path.
efi_path_to_slashes() {
    local path=$1 out
    case "$path" in
        /*|\\*) ;;
        *) error "efi_path_to_slashes: '$(_echo_e_literal "$path")' is not an absolute EFI path"
           return 1 ;;
    esac
    out=${path//\\//}
    # The same rule chain_entry applies, checked here so the refusal names the
    # backslash path the operator can actually find in efibootmgr's output
    # rather than the converted one they have never seen. A doubled separator
    # is refused with it: an empty path component reads as valid and resolves
    # to nothing.
    if [[ "$out" == *//* ]] || [[ ! "$out" =~ ^/[A-Za-z0-9_./-]+$ ]]; then
        error "efi_path_to_slashes: '$(_echo_e_literal "$path")' is not an absolute EFI path"
        return 1
    fi
    printf '%s\n' "$out"
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

# --- inventory (read-only host probes) --------------------------------------
#
# Nothing below writes. Every mount is read-only with the option that stops
# that filesystem replaying its journal, into a mktemp -d, and is unmounted
# before the function returns: this runs against filesystems belonging to
# operating systems that are staying. A plain `mount -o ro` on ext4 replays a
# dirty journal, which is a write; and a mount left behind is picked up by
# phase 4's genfstab and lands in the new system's fstab.
#
# Every probe here either answers or fails. None of them may answer "nothing
# found" because the tool it shells out to broke: an empty ESP list reads as
# "no neighbour to protect" and an empty NVRAM list reads as "the firmware
# knows about nothing", and both are the answer that lets every later guard
# through.

ESP_TYPE_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

# _esp_resolve <dir> <relative/path> -> the real path, each component matched
# case-insensitively, or 1.
#
# FAT is case-insensitive but case-*preserving*, and the kernel's vfat driver
# hands back whatever spelling created the name. grub-install writes
# BOOTX64.EFI, some firmwares and installers write bootx64.efi, and nothing
# stops a third from writing BootX64.efi. The first draft tried two spellings
# out of the 2^12 that are possible, and every one it missed read as "no
# fallback binary here" -- which is exactly the answer that lets
# removable_policy offer to overwrite somebody else's only bootloader.
#
# The real spelling is returned rather than the one asked for, because it goes
# into a chainloader line.
_esp_resolve() {
    local dir=${1%/} rest=$2 comp entry base match
    while :; do
        comp=${rest%%/*}
        [[ -n "$comp" ]] || return 1
        match=""
        # Exact first: on a case-sensitive filesystem -- which is what the
        # tests build, and what an ESP image unpacked into a directory is --
        # both spellings can exist side by side, and the one asked for is the
        # one meant.
        if [[ -e "${dir}/${comp}" ]]; then
            match="${dir}/${comp}"
        else
            for entry in "$dir"/*; do
                base=${entry##*/}
                [[ "${base,,}" == "${comp,,}" ]] || continue
                match=$entry
                break
            done
        fi
        [[ -n "$match" ]] || return 1
        dir=$match
        [[ "$rest" == */* ]] || break
        rest=${rest#*/}
        [[ -d "$dir" ]] || return 1
    done
    printf '%s\n' "$dir"
}

# parse_esp_list: "<path> <parttype> <size> <uuid>" lines on stdin
#   -> "<path> <fs_uuid> <size_bytes>" for ESPs only.
#
# UUID is last and FSTYPE is not requested at all, deliberately. Both can be
# empty -- an ESP that has been partitioned but never formatted has neither --
# and default-IFS `read` collapses a run of spaces, so an empty field in the
# middle shifts every later column left by one. With UUID last, the worst case
# is an empty UUID; with FSTYPE in the middle, the worst case was the size
# landing in the UUID variable and esp_bytes coming out empty.
#
# lsblk's whole-disk rows arrive here too, and they shift: measured,
# "/dev/sda  500107862016 " puts the size in parttype. They are dropped by the
# type-GUID test, which no size can satisfy.
parse_esp_list() {
    local path parttype size uuid
    while read -r path parttype size uuid; do
        [[ "${parttype,,}" == "$ESP_TYPE_GUID" ]] || continue
        printf '%s %s %s\n' "$path" "$uuid" "$size"
    done
}

# esp_list -> every EFI System Partition on the machine.
#
# Selected by GPT type GUID, not by "vfat and small": a FAT32 data partition is
# indistinguishable from an ESP by contents, and offering to install a
# bootloader onto someone's camera card is not a good failure.
#
# lsblk's status is checked rather than piped straight through. Under errexit
# the pipeline would catch it, but this is also read from `$(esp_list)` in
# tests and from subshells, and "lsblk broke" must never reach a caller as the
# empty string -- which means "this machine has no ESPs to be careful about".
esp_list() {
    local raw
    raw=$(lsblk -pnro PATH,PARTTYPE,SIZE,UUID -b) || {
        error "esp_list: lsblk failed; refusing to report a machine with no EFI System Partitions"
        return 1
    }
    printf '%s\n' "$raw" | parse_esp_list
}

# esp_dir_inventory <mountpoint> -> "vendor <DIR>" lines plus "fallback yes|no".
esp_dir_inventory() {
    local mnt=${1%/} efi dir
    if efi=$(_esp_resolve "$mnt" EFI) && [[ -d "$efi" ]]; then
        for dir in "$efi"/*/; do
            [[ -d "$dir" ]] || continue
            dir=${dir%/}
            dir=${dir##*/}
            # \EFI\BOOT is the firmware's fallback path, not a vendor's
            # directory -- listing it as one would offer it as a
            # --bootloader-id, which is grub-install --removable by the back
            # door.
            [[ "${dir^^}" == "BOOT" ]] && continue
            printf 'vendor %s\n' "$dir"
        done
    fi
    if esp_fallback_binary "$mnt" >/dev/null; then
        printf 'fallback yes\n'
    else
        printf 'fallback no\n'
    fi
}

# esp_fallback_binary <mountpoint> -> the path of \EFI\BOOT\BOOTX64.EFI as it
# is actually spelled on this ESP, or 1 if there is none.
esp_fallback_binary() {
    local found
    found=$(_esp_resolve "${1%/}" "EFI/BOOT/BOOTX64.EFI") || return 1
    [[ -f "$found" ]] || return 1
    printf '%s\n' "$found"
}

# esp_fallback_kind <mountpoint> -> grub | systemd-boot | refind | unknown | none
#
# Informational only. The --removable policy keys on presence, never on this:
# a binary this cannot identify is still somebody's bootloader.
esp_fallback_kind() {
    local bin
    bin=$(esp_fallback_binary "${1%/}") || { echo "none"; return 0; }
    if grep -qai 'systemd-boot' "$bin" 2>/dev/null; then echo "systemd-boot"; return 0; fi
    if grep -qai 'refind' "$bin" 2>/dev/null;       then echo "refind";       return 0; fi
    if grep -qai 'grub' "$bin" 2>/dev/null;         then echo "grub";         return 0; fi
    echo "unknown"
}

# esp_vendor_efi_path <mountpoint> -> the EFI path to chainload for this ESP.
#
# A vendor directory is preferred over \EFI\BOOT: the fallback path is whatever
# was installed last and can be replaced by a Windows update, while
# \EFI\<VENDOR>\grubx64.efi belongs to one install. The first draft hardcoded
# the fallback path, which was right only for the one machine this was written
# on -- any normally-installed neighbour lives in a vendor directory.
#
# The candidate list is ordered, and the order is load-bearing:
#
#   shimx64.efi first, because our chainloader hands the image to LoadImage,
#   which enforces Secure Boot. A distro's grubx64.efi is signed for its own
#   shim, not for the firmware, so chainloading it directly fails on an SB
#   machine; shim works with SB off too, and loads that same grubx64.efi from
#   beside itself.
#
#   Boot/bootmgfw.efi, because Windows does not put its loader where every
#   other vendor does -- it is at \EFI\Microsoft\Boot\bootmgfw.efi, one level
#   further down. Looking only for grubx64.efi returned nothing at all for the
#   Windows ESP on the target machine, so phase 6 could not have produced the
#   one chainload entry this whole feature exists for.
ESP_LOADER_CANDIDATES=(shimx64.efi grubx64.efi systemd-bootx64.efi Boot/bootmgfw.efi bootmgfw.efi)

esp_vendor_efi_path() {
    local mnt=${1%/} efi dir name cand found
    if efi=$(_esp_resolve "$mnt" EFI) && [[ -d "$efi" ]]; then
        for dir in "$efi"/*/; do
            [[ -d "$dir" ]] || continue
            name=${dir%/}; name=${name##*/}
            [[ "${name^^}" == "BOOT" ]] && continue
            for cand in "${ESP_LOADER_CANDIDATES[@]}"; do
                found=$(_esp_resolve "${dir%/}" "$cand") || continue
                # A directory called grubx64.efi is legal on FAT, and a
                # chainloader pointed at one boots nothing and only says so at
                # the boot menu.
                [[ -f "$found" ]] || continue
                printf '%s\n' "${found#"$mnt"}"
                return 0
            done
        done
    fi
    found=$(esp_fallback_binary "$mnt") || return 1
    printf '%s\n' "${found#"$mnt"}"
}

# esp_has_own_grub <mountpoint> -- true if this ESP already hosts a GRUB
# boot directory, i.e. some install has it mounted at /boot.
#
# bootloader_id_free only guards \EFI\<ID>, which is versioned per install.
# `grub-install --efi-directory=/boot` and `grub-mkconfig -o /boot/grub/grub.cfg`
# also write <esp>/grub/x86_64-efi/ and <esp>/grub/grub.cfg, and those are
# shared and unversioned. Adopting such an ESP replaces the neighbour's modules
# and its whole menu -- and since its grubx64.efi embeds a prefix pointing at
# that same /grub, it then boots *our* menu. If that neighbour is encrypted,
# os-prober cannot see it and it becomes unreachable.
#
# This is the layout this installer itself produces (the ESP is mounted at
# /boot), so the case arrives the first time a second install is made with it.
#
# A non-empty directory is the test, not the presence of grub.cfg: grub-install
# on its own writes the modules and no config, and replacing another install's
# modules breaks its boot just as surely as replacing its menu. grub2 is the
# same directory under the name Fedora, RHEL and SUSE give it.
esp_has_own_grub() {
    local mnt=${1%/} dir found
    for dir in grub grub2; do
        found=$(_esp_resolve "$mnt" "$dir") || continue
        [[ -d "$found" ]] || continue
        [[ -n "$(ls -A "$found" 2>/dev/null || true)" ]] && return 0
    done
    return 1
}

# bootloader_id_free <mountpoint> <id> -- false if \EFI\<id> already exists.
#
# grub-install onto an existing vendor directory overwrites its grubx64.efi
# without complaint, which on a shared ESP is another install's bootloader.
# Necessary but not sufficient on its own -- see esp_has_own_grub. Resolved
# case-insensitively, because FAT is: \EFI\Work and \EFI\WORK are one
# directory, and comparing exactly would call an occupied id free.
bootloader_id_free() {
    local mnt=${1%/} id=$2 found
    found=$(_esp_resolve "$mnt" "EFI/${id}") || return 0
    [[ -d "$found" ]] && return 1
    return 0
}

# _nvram_split <line> -- sets _NV_NUM, _NV_LABEL and _NV_DP from one
# efibootmgr line; returns 1 for every other line it prints.
#
# The label runs to the first tab; everything after it is the device path with
# the raw option data appended, which is megabytes of hex on some firmwares.
# The separator between the number and the label is *not* matched greedily:
# efibootmgr prints a space where the '*' would be for an inactive entry, so
# the label can sit one or two columns in -- and an entry with no label at all
# is a lone tab, which a greedy [[:space:]]+ swallowed, reporting the device
# path as the label.
#
# BootCurrent, BootOrder and BootNext are excluded by the four-hex-digit rule
# ('u', 'r' and 'e' are not hex digits); -v's "dp:" and "data:" continuation
# lines are excluded because they are indented.
_nvram_split() {
    local line=$1 rest
    local re='^Boot([0-9A-Fa-f]{4})\*?(.*)$'
    _NV_NUM=""; _NV_LABEL=""; _NV_DP=""
    [[ "$line" =~ $re ]] || return 1
    _NV_NUM=${BASH_REMATCH[1]}
    rest=${BASH_REMATCH[2]}
    _NV_LABEL=${rest%%$'\t'*}
    [[ "$rest" == *$'\t'* ]] && _NV_DP=${rest#*$'\t'}
    # Leading and trailing whitespace only; the label itself may contain runs
    # of spaces and they belong to it.
    _NV_LABEL=${_NV_LABEL#"${_NV_LABEL%%[![:space:]]*}"}
    _NV_LABEL=${_NV_LABEL%"${_NV_LABEL##*[![:space:]]}"}
    return 0
}

# parse_nvram_entries: efibootmgr -v output on stdin -> "<num> <label>".
parse_nvram_entries() {
    local line
    while IFS= read -r line; do
        _nvram_split "$line" || continue
        # A blank row reads as a rendering fault rather than as a real NVRAM
        # slot, and the operator is being asked to recognise this list.
        printf '%s %s\n' "$_NV_NUM" "${_NV_LABEL:-(unlabelled)}"
    done
}

# parse_nvram_loaders: efibootmgr -v output on stdin
#   -> "<num> <partition_guid> <efi_path> <label>" for entries that name a
#      loader file, with the path already converted to slashes.
#
# This is the half of the inventory that feeds chain_entry for a neighbour we
# cannot see from the filesystem side -- a Windows install whose ESP we did not
# mount, or one whose loader is not where esp_vendor_efi_path looks.
#
# The label is last so that spaces in it need no quoting.
#
# Entries with no file path node are dropped rather than reported with an empty
# path: the firmware's own BBS rows (CD/DVD, network, removable) name a device
# and no loader, and a chainload entry for one would boot nothing.
#
# So are MBR HD() nodes. They carry a disk signature where the GPT form carries
# a partition GUID, and lsblk reports that in a different shape entirely
# (12345678-01), so it cannot be resolved to a filesystem UUID -- and a
# plausible-looking guid that resolves to the wrong partition is worse than no
# entry at all.
parse_nvram_loaders() {
    local line partuuid path
    local hd_re='HD\([0-9]+,GPT,([0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}),'
    # Anchored at the first backslash and ending at the *last* ".EFI" in the
    # run. Measured on the target machine, efibootmgr appends the option data
    # to the device path with no separator at all:
    # "...\BOOTMGFW.EFI57494e444f5753...". Taking everything after the last
    # ")/" would carry that hex into the chainloader line, which boots nothing
    # and only says so at the boot menu. Hex digits cannot spell ".EFI", so the
    # greedy match cannot run past the real end of the path.
    local path_re='(\\[^[:space:]]*\.[Ee][Ff][Ii])'
    while IFS= read -r line; do
        _nvram_split "$line" || continue
        [[ -n "$_NV_DP" ]] || continue
        [[ "$_NV_DP" =~ $hd_re ]] || continue
        partuuid=${BASH_REMATCH[1]}
        [[ "$_NV_DP" =~ $path_re ]] || continue
        path=$(efi_path_to_slashes "${BASH_REMATCH[1]}") || continue
        printf '%s %s %s %s\n' "$_NV_NUM" "$partuuid" "$path" "${_NV_LABEL:-(unlabelled)}"
    done
}

# nvram_entries -- shown to the operator during phase 3 so the inventory they
# confirm against includes what the firmware already knows about.
#
# efibootmgr's failure is reported, not swallowed: "the firmware has no boot
# entries" and "efibootmgr is not installed, or this machine booted in BIOS
# mode" are different facts, and only the first one is safe to act on.
nvram_entries() {
    local raw err
    err=$(mktemp) || { error "nvram_entries: cannot create a temp file"; return 1; }
    if ! raw=$(efibootmgr -v 2>"$err"); then
        error "nvram_entries: efibootmgr failed: $(_echo_e_literal "$(tr '\n' ' ' < "$err")")"
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    printf '%s\n' "$raw" | parse_nvram_entries
}

# nvram_loaders -- the same NVRAM read, as chainloadable entries.
nvram_loaders() {
    local raw err
    err=$(mktemp) || { error "nvram_loaders: cannot create a temp file"; return 1; }
    if ! raw=$(efibootmgr -v 2>"$err"); then
        error "nvram_loaders: efibootmgr failed: $(_echo_e_literal "$(tr '\n' ' ' < "$err")")"
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    printf '%s\n' "$raw" | parse_nvram_loaders
}

# fs_uuid_for_partuuid <partition_guid> -> that partition's filesystem UUID.
#
# efibootmgr identifies an entry's partition by its partition GUID; chain_entry
# emits `search --fs-uuid`, which needs the filesystem's. Without the
# translation an NVRAM-derived entry has no uuid chain_entry would accept.
#
# Fails rather than emitting an empty uuid for a partition that has none: an
# empty one reaching chain_entry is refused there anyway, and failing here says
# which lookup went wrong.
fs_uuid_for_partuuid() {
    local want=${1,,} raw path pu uuid
    [[ -n "$want" ]] || return 1
    raw=$(lsblk -pnro PATH,PARTUUID,UUID) || {
        error "fs_uuid_for_partuuid: lsblk failed; cannot resolve $(_echo_e_literal "$1")"
        return 1
    }
    while read -r path pu uuid; do
        [[ "${pu,,}" == "$want" ]] || continue
        [[ -n "$uuid" ]] || return 1
        printf '%s\n' "$uuid"
        return 0
    done <<<"$raw"
    return 1
}

# esp_probe <dev> -- mount an ESP read-only and emit its inventory, plus
# "kind <x>", "owngrub yes|no" and "efipath <p>".
#
# The filesystem type is read from the signature before anything is mounted,
# exactly as part_probe_os does. An ESP is selected by GPT type GUID, and
# nothing stops a partition carrying that GUID from holding ext4 -- for which
# a bare `mount -o ro` replays a dirty journal. That is a write to a filesystem
# belonging to a system that is staying, during a phase that promises not to
# write and during --dry-run, which promises to touch nothing at all. FAT and
# exFAT have no journal to replay, so plain `ro` is right for them and only
# for them; noload is an ext4 option and makes a vfat mount fail outright.
#
# An ESP this could not read reports "fallback unknown", never "fallback no".
# "no" is the answer that makes removable_policy offer to write
# \EFI\BOOT\BOOTX64.EFI, and there is exactly one such path per ESP --
# grub-install overwrites whatever is there without asking. removable_policy
# refuses anything that is not a literal yes or no, which under the installer's
# `set -euo pipefail` aborts the run. That is the intended direction: an ESP we
# failed to look at must not put the operator one keystroke from overwriting a
# bootloader.
esp_probe() {
    local dev=$1 tmp fstype inv kind owngrub path
    fstype=$(lsblk -dno FSTYPE "$dev" 2>/dev/null) || fstype=""
    fstype=${fstype//[[:space:]]/}
    case "$fstype" in
        vfat|msdos|exfat) ;;
        *)  printf 'fallback unknown\n'
            printf 'kind unreadable\n'
            return 0 ;;
    esac

    tmp=$(mktemp -d) || { error "esp_probe: cannot create a mountpoint for $(_echo_e_literal "$dev")"; return 1; }
    if mount -o ro "$dev" "$tmp" 2>/dev/null; then
        # Read into locals and unmounted before anything is printed: a mount
        # left behind is picked up by phase 4's genfstab and lands in the new
        # system's fstab, pointing at another operating system's ESP.
        inv=$(esp_dir_inventory "$tmp")
        kind=$(esp_fallback_kind "$tmp")
        if esp_has_own_grub "$tmp"; then owngrub=yes; else owngrub=no; fi
        path=$(esp_vendor_efi_path "$tmp") || path=""
        umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
        rmdir "$tmp" 2>/dev/null || true
        printf '%s\n' "$inv"
        printf 'kind %s\n' "$kind"
        printf 'owngrub %s\n' "$owngrub"
        [[ -n "$path" ]] && printf 'efipath %s\n' "$path"
        return 0
    fi
    rmdir "$tmp" 2>/dev/null || true
    printf 'fallback unknown\n'
    printf 'kind unreadable\n'
}

# linux_installs <exclude_dev>... -> "<dev> <uuid> <has_grub yes|no> <name>"
#
# Candidates are ext4 and btrfs partitions that are not part of this install.
# An encrypted root reports as crypto_LUKS and is skipped: there is nothing to
# read without the passphrase, which is exactly why the chainload entry this
# feeds is static rather than left to os-prober.
#
# The mount options are chosen by filesystem type and there is no bare `ro`
# fallback, for the same reason part_probe_os has none: `noload` means
# something only to ext2/3/4 and `nologreplay` only to btrfs, and each is the
# only thing that stops that filesystem replaying its journal on a read-only
# mount. A chain of ro,noload -> ro,subvol=@ -> ro writes to every ext4 whose
# noload mount failed, and replays the log tree of every btrfs.
#
# btrfs is tried with subvol=@ first because that is where an Arch-style layout
# keeps the root; the second attempt is the same options without it, for a
# btrfs root that is the top-level subvolume. Both carry nologreplay.
#
# Known limitation: has_grub tests for /boot/grub on the *root*, so a neighbour
# that mounts its ESP at /boot -- which is what this installer itself produces
# -- reports no. A third install on the same machine would therefore not see
# the second one here. Phase 6 covers that case from the ESP inventory instead.
linux_installs() {
    local -a exclude=() rows=() try_opts=()
    local dev fstype uuid raw row tmp skip ex name has_grub mounted opts
    exclude=("$@")
    local uuid_re='^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$'

    raw=$(lsblk -pnro PATH,FSTYPE,UUID) || {
        error "linux_installs: lsblk failed; refusing to report a machine with no existing installs"
        return 1
    }
    [[ -n "$raw" ]] || return 0
    # Drained into an array before the loop rather than read from a process
    # substitution. `while read ... done < <(cmd)` owns stdin for the whole
    # body, and this loop is where phase 6's per-install prompt will go.
    # Measured on this plan: ask_yes_no inside such a loop consumed the next
    # line as its answer, hit EOF and returned its default *yes* -- consent
    # bypassed.
    mapfile -t rows <<<"$raw"

    for row in "${rows[@]}"; do
        read -r dev fstype uuid <<<"$row"
        case "$fstype" in ext4|btrfs) ;; *) continue ;; esac
        # A uuid that is not uuid-shaped means lsblk's columns shifted -- an
        # empty FSTYPE or UUID collapses under default-IFS read -- or the
        # filesystem has none. Either way chain_entry would refuse it later,
        # and mounting a partition identified by a shifted row is how a probe
        # returns a plausible-looking wrong answer.
        [[ "$uuid" =~ $uuid_re ]] || continue

        skip=false
        for ex in ${exclude[@]+"${exclude[@]}"}; do
            [[ "$dev" == "$ex" ]] && { skip=true; break; }
        done
        [[ "$skip" == true ]] && continue

        if [[ "$fstype" == btrfs ]]; then
            # Quoted so the commas read as part of one mount option string,
            # not as a separator shellcheck has to guess about.
            try_opts=("ro,nologreplay,subvol=@" "ro,nologreplay")
        else
            try_opts=("ro,noload")
        fi
        tmp=$(mktemp -d) || continue
        mounted=false
        for opts in "${try_opts[@]}"; do
            if mount -o "$opts" "$dev" "$tmp" 2>/dev/null; then
                mounted=true
                break
            fi
        done
        if [[ "$mounted" == true ]]; then
            if [[ -r "${tmp}/etc/os-release" ]]; then
                # Read with grep+cut rather than sourcing it: /etc/os-release
                # on a partition belonging to someone else is an untrusted
                # file, and sourcing runs it as root.
                name=$(grep -m1 '^NAME=' "${tmp}/etc/os-release" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
                has_grub=no
                [[ -d "${tmp}/boot/grub" ]] && has_grub=yes
                printf '%s %s %s %s\n' "$dev" "$uuid" "$has_grub" "${name:-unknown}"
            fi
            umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
        fi
        rmdir "$tmp" 2>/dev/null || true
    done
}
