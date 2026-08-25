#!/bin/bash
# Boot environment: what to write so that everything already on the machine
# stays reachable. The writes are custom_cfg_upsert's, into the one file it is
# pointed at, and nvram_register_removable's single efibootmgr --create;
# everything else reads.
# Requires lib/ui.sh to be sourced first, and lib/disk.sh for run_cmd, which
# nvram_register_removable -- and nothing else here -- depends on.
# shellcheck shell=bash

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
        error "bootloader_id_from: '$name' leaves nothing usable as an id -- it has no letters or digits"
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
            *) error "removable_policy: expected 'yes' or 'no', got '$arg'"
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
        *) error "efi_path_to_slashes: '$path' is not an absolute EFI path"
           return 1 ;;
    esac
    out=${path//\\//}
    # The same rule chain_entry applies, checked here so the refusal names the
    # backslash path the operator can actually find in efibootmgr's output
    # rather than the converted one they have never seen. A doubled separator
    # is refused with it: an empty path component reads as valid and resolves
    # to nothing.
    if [[ "$out" == *//* ]] || [[ ! "$out" =~ ^/[A-Za-z0-9_./-]+$ ]]; then
        error "efi_path_to_slashes: '$path' is not an absolute EFI path"
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
            error "chain_entry: title must not contain a single quote or a newline: '$title'"
            return 1 ;;
        *$'\r'*)
            # A CRLF /etc/os-release reaches this through linux_installs' NAME
            # field. A bare CR does not break the entry the way a newline does,
            # it corrupts the rendering of the menu row -- which nobody
            # diagnoses, because the file it came from looks correct in an
            # editor.
            error "chain_entry: title must not contain a carriage return: '$title'"
            return 1 ;;
    esac
    # Shape, not just character set: a bare "-" passed a [A-Za-z0-9-]+ rule and
    # emitted `search --fs-uuid --set=root -`, which matches nothing and leaves
    # chainloader resolving against whatever root was set -- the same "boots
    # nothing and only says so at the boot menu" failure the path rule avoids.
    # FAT's XXXX-XXXX covers every ESP; 8-4-4-4-12 covers everything else.
    [[ "$uuid" =~ ^([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})$ ]] \
        || { error "chain_entry: '$uuid' is not a filesystem UUID"; return 1; }
    [[ "$efi_path" =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || { error "chain_entry: '$efi_path' is not an absolute EFI path"; return 1; }
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
        || { error "custom_cfg_upsert: marker id must be [A-Za-z0-9_-], got '$id'"; return 1; }
    begin="# BEGIN arch-installer:${id}"
    end="# END arch-installer:${id}"

    # A block carrying a marker line of its own ends the region early, so the
    # next upsert strips part of it and leaves the rest as an orphan menuentry
    # that nothing will ever match again. Prefixing a newline so the pattern
    # only has to match "\n<marker>" -- otherwise a marker on the block's first
    # line slips past.
    case $'\n'"$block" in
        *$'\n'"# BEGIN arch-installer:"*|*$'\n'"# END arch-installer:"*)
            error "custom_cfg_upsert: the block carries an arch-installer marker line, which would break the delimiters in $file"
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
        error "custom_cfg_upsert: $file is a symlink to $link_target; point at that path instead"
        return 1
    fi
    # [[ -f ]] is false for a directory, and `mv tmp somedir` moves the temp
    # file *into* it and reports success -- so pointing at /etc/grub.d instead
    # of /etc/grub.d/40_custom used to leave an executable stray file there
    # that grub-mkconfig runs forever and no marker will ever match.
    if [[ -e "$file" && ! -f "$file" ]]; then
        error "custom_cfg_upsert: $file exists and is not a regular file"
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
            error "custom_cfg_upsert: the arch-installer:${id} markers in $file are not a matched pair (${n_begin} BEGIN, ${n_end} END); refusing to guess where the block ends"
            return 1
        fi
        # Counted separately from the pairing check, which would otherwise
        # report two whole blocks as "not a matched pair" while naming two of
        # each. A second complete block is a different fault: the original
        # collapsed them silently, and which one is ours is not knowable.
        # Reachable through the CRLF limitation documented above.
        if (( n_begin > 1 )); then
            error "custom_cfg_upsert: $file already holds ${n_begin} blocks for arch-installer:${id}, expected at most one; refusing to guess which is ours"
            return 1
        fi
    fi

    _ccu_tmp=$(mktemp "${file}.XXXXXX") \
        || { error "custom_cfg_upsert: cannot create a temp file next to $file"; return 1; }

    if [[ -f "$file" ]]; then
        # Exact line comparison, not a regex: the marker id is validated above,
        # but a grep -v pattern would still be one metacharacter away from
        # deleting lines this has no business touching.
        awk -v b="$begin" -v e="$end" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip   { print }
        ' "$file" > "$_ccu_tmp" || { rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to read $file"; return 1; }
    fi

    # Every *handled* failure below removes the temp file before returning --
    # signals are the trap's problem, and it cannot cover them. The file is a
    # sibling of the target, so in /etc/grub.d a leaked one is a second copy of
    # this entry in every config that system regenerates from then on, and the
    # window between the mode being set and the rename leaks it at the
    # target's mode rather than mktemp's 0600.
    if ! { printf '%s\n' "$begin"; printf '%s\n' "$block"; printf '%s\n' "$end"; } >> "$_ccu_tmp"; then
        rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to write $file"; return 1
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
            rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to copy the mode of $file"; return 1
        fi
    elif ! chmod "$mode" "$_ccu_tmp"; then
        rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to chmod $file"; return 1
    fi
    if ! mv "$_ccu_tmp" "$file"; then
        rm -f "$_ccu_tmp"; error "custom_cfg_upsert: failed to move $file into place"; return 1
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
#
# The three lsblk readers -- esp_list, fs_uuid_for_partuuid and linux_installs
# -- follow one rule between them, because they drifted apart when they did
# not. Each checks lsblk's exit status and fails loudly rather than returning
# an empty result; each validates the field it identifies a partition by,
# because lsblk leaves middle columns empty for whole-disk and unformatted rows
# and default-IFS `read` then shifts every later column left; and none of them
# emits a record in which an optional field can be empty, since a consumer
# reading positionally cannot tell a shifted record from a short one.
#
# "Validates" differs by what the field is. fs_uuid_for_partuuid and
# linux_installs shape-check a GUID against a regex. parse_esp_list identifies
# an ESP by an exact PARTTYPE match, which no shifted value can pass, and
# shape-checks the SIZE it would otherwise carry across -- a numeric test,
# because that is the column a shift puts a non-number in.
#
# Whitespace contract for every record emitted below: fields are
# space-separated and the LAST field is the only one that may contain spaces
# (a vendor directory name, an OS name, an NVRAM label). Consumers must read
# with `read -r a b c rest`, never `awk '{print $N}'` -- a vendor directory
# called "My Vendor" makes the fourth field of an awk-split record "/EFI/My",
# which chain_entry accepts and which boots nothing.

ESP_TYPE_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

# _esp_resolve <dir> <relative/path> -> the path, each component matched
# case-insensitively, or 1.
#
# On a real ESP this changes nothing, and the comment that used to sit here
# claiming otherwise was wrong. Measured on the operator's live vfat mount:
# `[[ -f /boot/EFI/EFI/BoOt/BoOtX64.eFi ]]` is true, because Linux's vfat
# driver resolves lookups in any case. The plan's two-spelling test for
# BOOTX64.EFI was therefore never broken in production.
#
# What comes back is the spelling ON DISK, not the one asked for. The exact
# spelling is tried first, so when it exists that is also the spelling asked
# for and the distinction does not arise; when it does not exist, the
# case-insensitive match returns the name as the filesystem holds it. Callers
# depend on this -- esp_fallback_binary documents its result as "as it is
# actually spelled on this ESP", and a test pins EFI/bOOt/BOOTX64.EFI coming
# back under that spelling. Either spelling chainloads regardless, since GRUB's
# fat module is case-insensitive too.
#
# What this does buy is that the case-insensitivity is ours rather than an
# undeclared dependency on the vfat driver's lookup behaviour, so the same
# functions give the same answers against a case-sensitive tree -- an ESP
# image unpacked into a directory, or the fixtures this file's tests build.
# Without it those tests would be testing something the production path does
# not do.
# The optional third argument is the type the *last* component must have, f or
# d. It is not decoration: a directory named BOOTX64.EFI is legal on FAT, and
# resolving to it made esp_fallback_binary's own -f test fail -- which reads as
# "no fallback binary on this ESP", the answer that lets removable_policy offer
# to overwrite one.
#
# Every candidate is *tried* rather than committed to, and the recursion
# backtracks. Committing to the first match by collation order meant that an
# empty EFI/BOOT/ alongside a populated EFI/bOOt/ resolved to the empty one and
# stopped -- again reporting no fallback where one exists.
_esp_resolve() {
    local dir=${1%/} rest=$2 want=${3:-} comp tail cand base
    comp=${rest%%/*}
    [[ -n "$comp" ]] || return 1
    if [[ "$rest" == */* ]]; then tail=${rest#*/}; else tail=""; fi
    # The exact spelling is tried first and then again as part of the glob;
    # the repeat costs one stat on a path at most three components deep and is
    # cheaper than tracking which candidate has already been seen.
    for cand in "${dir}/${comp}" "$dir"/*; do
        [[ -e "$cand" ]] || continue
        base=${cand##*/}
        [[ "${base,,}" == "${comp,,}" ]] || continue
        if [[ -n "$tail" ]]; then
            [[ -d "$cand" ]] || continue
            _esp_resolve "$cand" "$tail" "$want" && return 0
            continue
        fi
        case "$want" in
            f) [[ -f "$cand" ]] || continue ;;
            d) [[ -d "$cand" ]] || continue ;;
        esac
        printf '%s\n' "$cand"
        return 0
    done
    return 1
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
#
# The emitted record keeps UUID in the middle, so the same collapse would
# happen again on the way OUT: an unformatted ESP -- the very case this header
# is about -- gave `read -r dev uuid size` a size in $uuid and nothing in
# $size. A missing UUID is therefore emitted as a literal "-" rather than as an
# empty field. It is not a UUID, so chain_entry refuses it exactly as it
# refuses the empty string, and no consumer can silently read the size as one.
parse_esp_list() {
    local path parttype size uuid
    while read -r path parttype size uuid; do
        [[ "${parttype,,}" == "$ESP_TYPE_GUID" ]] || continue
        # A non-numeric size means the columns shifted anyway, which for a row
        # that matched the type GUID should be impossible -- so it is a fault
        # to drop, not to pass on as an ESP the operator might adopt.
        [[ "$size" =~ ^[0-9]+$ ]] || continue
        printf '%s %s %s\n' "$path" "${uuid:--}" "$size"
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
    if efi=$(_esp_resolve "$mnt" EFI d); then
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
# is actually spelled on this ESP -- which is not necessarily the spelling asked
# for, since _esp_resolve matches case-insensitively -- or 1 if there is none.
#
# ${1%/} is expanded before the command substitution, for the reason spelled out
# over esp_fallback_kind below, and this is the half that matters more. Under
# set -u a missing argument expanded inside $( ) killed only the subshell, and
# `|| return 1` then caught a programming error and returned it as "there is no
# fallback binary on this ESP" -- which esp_dir_inventory turns into
# "fallback no", the one answer removable_policy acts on by offering to write
# \EFI\BOOT\BOOTX64.EFI over whatever is there. esp_fallback_kind's swallowed
# "none" is only a label; this one reaches the operator as a prompt.
esp_fallback_binary() {
    local mnt=${1%/} found
    found=$(_esp_resolve "$mnt" "EFI/BOOT/BOOTX64.EFI" f) || return 1
    printf '%s\n' "$found"
}

# esp_fallback_kind <mountpoint> -> grub | systemd-boot | refind | unknown | none
#
# Informational only. The --removable policy keys on presence, never on this:
# a binary this cannot identify is still somebody's bootloader.
# The probe order is most-distinctive-first, which is a change from the
# grub-first order this started with. "grub" is a substring that turns up
# inside other loaders -- rEFInd's binary names it because it scans for it --
# while "systemd-boot" and "refind" appear in nothing but themselves. Testing
# for grub first therefore reports somebody else's loader as grub. Nothing but
# the label is affected, since the --removable policy keys on presence, but a
# mislabelled row is what the operator reads the inventory for.
esp_fallback_kind() {
    # ${1%/} is expanded here rather than inside the command substitution
    # below. Under set -u a missing argument aborts, and inside $( ) only the
    # subshell died -- so `|| { echo none; }` caught a programming error and
    # turned it into "there is no bootloader on this ESP", which is the answer
    # that lets removable_policy offer to write one.
    local mnt=${1%/} bin
    bin=$(esp_fallback_binary "$mnt") || { echo "none"; return 0; }
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
# Exactly one loader is returned per ESP. The search is candidate-major -- the
# outer loop is over loader names and the inner one over vendor directories --
# so a shim in ANY vendor directory beats a bare grub in any other. Vendor-major
# ranked the candidates only within one directory and then picked the directory
# by glob collation, which made the Secure Boot reasoning above false in exactly
# the case it is written for: with EFI/arch/grubx64.efi and
# EFI/fedora/shimx64.efi present, "arch" sorts first and the unbootable-under-SB
# one won.
#
# Which vendor wins among equally-ranked candidates is still collation order,
# and that genuinely is arbitrary rather than wrong -- both are a chainload
# target for this ESP, and neither is more correct than the other. Phase 6
# needing every loader on an ESP would need this to return a list.
esp_vendor_efi_path() {
    local mnt=${1%/} efi dir name cand found
    # Local rather than a file-scope global: it is one function's detail, and an
    # unprefixed mutable global is one assignment away from being changed by
    # something that has no business knowing about it.
    local -a candidates=(shimx64.efi grubx64.efi systemd-bootx64.efi Boot/bootmgfw.efi bootmgfw.efi)
    if efi=$(_esp_resolve "$mnt" EFI d); then
        for cand in "${candidates[@]}"; do
            for dir in "$efi"/*/; do
                [[ -d "$dir" ]] || continue
                name=${dir%/}; name=${name##*/}
                [[ "${name^^}" == "BOOT" ]] && continue
                found=$(_esp_resolve "${dir%/}" "$cand" f) || continue
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
        found=$(_esp_resolve "$mnt" "$dir" d) || continue
        [[ -n "$(ls -A "$found" 2>/dev/null || true)" ]] && return 0
    done
    return 1
}

# bootloader_id_free <mountpoint> <id> -- false if \EFI\<id> already exists.
#
# Precondition: <id> is a bare directory name, as bootloader_id_from produces.
# It is interpolated into a path and not re-checked here. Measured, both bad
# shapes currently answer "not free", which is the refusing direction, but they
# answer it for the wrong reason and neither is a guarantee to lean on: "" makes
# the path "EFI/", which resolves to the ESP's own EFI directory, and "../.."
# makes it "EFI/../..", which resolves outside the ESP entirely and then reports
# on whatever is there. Every caller today goes through bootloader_id_from,
# which maps everything outside [A-Z0-9_] to an underscore and refuses an id
# with no letters or digits, so neither shape is reachable -- a future caller
# that skips that step is where it would start.
#
# grub-install onto an existing vendor directory overwrites its grubx64.efi
# without complaint, which on a shared ESP is another install's bootloader.
# Necessary but not sufficient on its own -- see esp_has_own_grub. Resolved
# case-insensitively, because FAT is: \EFI\Work and \EFI\WORK are one
# directory, and comparing exactly would call an occupied id free.
bootloader_id_free() {
    local mnt=${1%/} id=$2 found
    found=$(_esp_resolve "$mnt" "EFI/${id}" d) || return 0
    [[ -n "$found" ]] && return 1
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
# Locale note: `[[ =~ ]]` fails on a byte sequence that is not valid in the
# current locale, so in a UTF-8 locale a stray non-UTF-8 byte anywhere in a
# label drops that whole NVRAM entry, while LC_ALL=C parses it. That is a
# partial instance of the failure this file's banner forbids -- an entry
# vanishing rather than being reported. It is benign on the Arch ISO, where
# these labels are firmware-written ASCII, and left alone rather than papered
# over with a locale override that would change how every other string in the
# installer compares.
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
    local _NV_NUM _NV_LABEL _NV_DP
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
    local line partuuid tailpart path
    # Declared here so _nvram_split's assignments land in this function's scope
    # under bash's dynamic scoping, rather than leaking into whatever sourced
    # the library.
    local _NV_NUM _NV_LABEL _NV_DP
    # One regex for the guid AND the start of the file path, so both come from
    # the same device path node. The trailing (\\.*)$ requires a backslash
    # immediately after this node's closing ")/" -- which is what ties them
    # together, and what makes a line carrying two HD nodes take both fields
    # from whichever node actually carries the loader.
    #
    # It requires ADJACENCY, not merely order: a device path that puts another
    # node between the HD node and the file path node --
    # HD(...)/CDROM(0x1,0x2,0x3)/\EFI\B\g.efi -- matches nothing and the entry
    # is dropped, where the old unanchored form emitted it. That is the
    # fail-closed direction and it is deliberate, because the whole point of
    # this regex is that the guid and the path came from one node; but it is a
    # narrowing, so it is written down. Not observed on this machine
    # (efibootmgr 18 / libefivar 38) -- a loader on an optical device is the
    # shape that would produce it, and such an entry has no partition to
    # resolve to a filesystem UUID anyway.
    local hd_re='HD\([0-9]+,GPT,([0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}),[^)]*\)/(\\.*)$'
    # Anchored at the first backslash and ending at the *last* ".EFI" in the
    # run. Measured on the target machine, efibootmgr appends the option data
    # to the device path with no separator at all:
    # "...\BOOTMGFW.EFI57494e444f5753...". Taking everything after the last
    # ")/" would carry that hex into the chainloader line, which boots nothing
    # and only says so at the boot menu. Hex digits cannot spell ".EFI", so the
    # greedy match cannot run past the real end of the path.
    #
    # That last step holds only because the reader above calls `efibootmgr -v`
    # and *not* `-u`. With -u the optional data is printed as text instead of
    # hex, and text can contain ".EFI" -- at which point the leftmost-longest
    # match overruns the real path silently. Do not add -u here.
    #
    # ANCHORED at ^, against the tail the regex above captured. Bash's =~ is
    # leftmost-longest but unanchored, so the previous unanchored form retried
    # from a later backslash whenever the run starting at the first one could
    # not reach a ".EFI". Measured: a legal FAT long name with a space in it,
    # \EFI\My Vendor\grubx64.efi, came out as /grubx64.efi -- a well-formed
    # entry, accepted by chain_entry, chainloading a path that does not exist.
    # The operator finds out at the boot menu.
    #
    # Greedy .* backtracks to the LAST ".EFI", which is where the real path
    # ends because the appended option data is hex and hex cannot spell a dot.
    # A path this extracts but chain_entry cannot represent -- a space is
    # outside its character class -- is refused by efi_path_to_slashes, which
    # says so on stderr. That diagnostic is why the extraction has to be
    # faithful rather than merely fail-closed: a truncated path is accepted
    # everywhere and wrong, while the whole path is refused loudly.
    local path_re='^(\\.*\.[Ee][Ff][Ii])'
    while IFS= read -r line; do
        _nvram_split "$line" || continue
        [[ -n "$_NV_DP" ]] || continue
        [[ "$_NV_DP" =~ $hd_re ]] || continue
        partuuid=${BASH_REMATCH[1]}
        tailpart=${BASH_REMATCH[3]}
        [[ "$tailpart" =~ $path_re ]] || continue
        path=$(efi_path_to_slashes "${BASH_REMATCH[1]}") || continue
        printf '%s %s %s %s\n' "$_NV_NUM" "$partuuid" "$path" "${_NV_LABEL:-(unlabelled)}"
    done
}

# _nvram_read <parser> -- run efibootmgr once and pipe it through <parser>.
#
# efibootmgr's failure is reported, not swallowed: "the firmware has no boot
# entries" and "efibootmgr is not installed, or this machine booted in BIOS
# mode" are different facts, and only the first one is safe to act on. stderr
# is captured rather than discarded so the refusal can say which it was.
#
# Note for phase 6, which wants both views: this reads NVRAM once per call, so
# calling nvram_entries and nvram_loaders is two efibootmgr invocations of the
# same unchanging data.
_nvram_read() {
    local parser=$1 raw err
    # The refusal names the function the operator's code called, not this
    # helper and not the parser it was handed. Naming the parser sent them
    # looking for "parse_nvram_entries", which is not a name that appears
    # anywhere in the phase that failed.
    local who=${FUNCNAME[1]:-_nvram_read}
    err=$(mktemp) || { error "${who}: cannot create a temp file"; return 1; }
    if ! raw=$(efibootmgr -v 2>"$err"); then
        error "${who}: efibootmgr failed: $(tr '\n' ' ' < "$err")"
        rm -f "$err"
        return 1
    fi
    rm -f "$err"
    printf '%s\n' "$raw" | "$parser"
}

# nvram_entries -- shown to the operator during phase 3 so the inventory they
# confirm against includes what the firmware already knows about.
nvram_entries() { _nvram_read parse_nvram_entries; }

# nvram_loaders -- the same NVRAM read, as chainloadable entries.
nvram_loaders() { _nvram_read parse_nvram_loaders; }

# fs_uuid_for_partuuid <partition_guid> -> that partition's filesystem UUID.
#
# efibootmgr identifies an entry's partition by its partition GUID; chain_entry
# emits `search --fs-uuid`, which needs the filesystem's. Without the
# translation an NVRAM-derived entry has no uuid chain_entry would accept.
#
# Fails rather than emitting an empty uuid for a partition that has none: an
# empty one reaching chain_entry is refused there anyway, and failing here says
# which lookup went wrong.
#
# GPT only. The shape check below accepts the 8-4-4-4-12 form and nothing else,
# so an MBR PARTUUID -- lsblk reports those as <disk-signature>-<nn>, e.g.
# 12345678-01 -- never matches any row and the lookup fails. That is the same
# boundary parse_nvram_loaders draws when it drops MBR HD() nodes, and for the
# same reason: an MBR signature is not a partition GUID and resolving one to a
# filesystem UUID by coincidence is worse than failing. Every disk on the target
# machine is GPT, so this is a limit of the contract rather than a live gap --
# but this function is public, and a caller holding a PARTUUID from anywhere
# else needs to know it will be refused rather than answered.
fs_uuid_for_partuuid() {
    local want=${1,,} raw path pu uuid
    local partuuid_re='^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$'
    [[ -n "$want" ]] || return 1
    raw=$(lsblk -pnro PATH,PARTUUID,UUID) || {
        error "fs_uuid_for_partuuid: lsblk failed; cannot resolve $1"
        return 1
    }
    while read -r path pu uuid; do
        # Same shape check linux_installs applies, for the same reason: PARTUUID
        # sits in the middle and lsblk leaves it empty for whole-disk rows, so
        # default-IFS read shifts the columns and $pu can hold a filesystem
        # UUID from the next column along.
        [[ "$pu" =~ $partuuid_re ]] || continue
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

    tmp=$(mktemp -d) || { error "esp_probe: cannot create a mountpoint for $dev"; return 1; }
    if mount -o ro "$dev" "$tmp" 2>/dev/null; then
        # Read into locals and unmounted before anything is printed: a mount
        # left behind is picked up by phase 4's genfstab and lands in the new
        # system's fstab, pointing at another operating system's ESP.
        #
        # Nothing between the mount and the umount can return non-zero today --
        # every call is either total or guarded -- so there is no leak now and
        # no trap. Anything added here that *can* fail must not be left to
        # errexit, or it takes the abort before the umount. A trap is not the
        # fix: one set inside a function stays registered in the caller after it
        # returns (measured in Task 6), which is why custom_cfg_upsert traps
        # only RETURN and deliberately not INT/TERM.
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

# linux_installs <exclude_dev>... -> "<dev> <uuid> <has_grub yes|no|unknown> <name>"
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
#
# Second known limitation: identification is by /etc/os-release, which on Arch
# and every other systemd distribution is a SYMLINK to ../usr/lib/os-release
# (checked on this machine). It therefore resolves only once the root carrying
# /usr is mounted, which is the ordinary layout; a neighbour keeping /usr on a
# separate partition leaves the link dangling, so -e is false and the install is
# classified as "not Linux" rather than as unreadable. Rare enough on modern
# systems -- systemd requires /usr mounted from the initramfs -- to document
# rather than chase.
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
        # Not `|| continue`: mktemp failing is the tool breaking, and silently
        # dropping the candidate answers "there is no other Linux here" for a
        # reason that has nothing to do with the machine. esp_probe treats the
        # same failure the same way.
        tmp=$(mktemp -d) || {
            error "linux_installs: cannot create a mountpoint for $dev"
            return 1
        }
        mounted=false
        for opts in "${try_opts[@]}"; do
            if mount -o "$opts" "$dev" "$tmp" 2>/dev/null; then
                mounted=true
                break
            fi
        done
        if [[ "$mounted" != true ]]; then
            # A candidate that would not mount is reported, not dropped. It
            # used to vanish with a success status and nothing said, so an ext4
            # neighbour with a dirty journal simply stopped existing as far as
            # phase 6 was concerned. has_grub is "unknown" rather than "no",
            # because "no" is a claim about a filesystem nobody read.
            error "linux_installs: ${dev} (${fstype}) could not be read; it is reported as unknown rather than skipped"
            printf '%s %s unknown (unreadable)\n' "$dev" "$uuid"
            rmdir "$tmp" 2>/dev/null || true
            continue
        fi
        # As in esp_probe: nothing below can currently return non-zero before
        # the umount, so there is no trap and no leak. A future edit that adds
        # a failing call here leaks a mount of a neighbour's root into phase
        # 4's genfstab. (The not-mounted branch above `continue`s before
        # reaching here, and has no mount to leak.)
        if [[ -r "${tmp}/etc/os-release" ]]; then
            # Read with grep+cut rather than sourcing it: /etc/os-release
            # on a partition belonging to someone else is an untrusted
            # file, and sourcing runs it as root.
            # tr strips the CR as well as the quotes, and both for the same
            # reason: they are os-release *file syntax*, not part of the
            # name. A CRLF /etc/os-release is ordinary on a partition
            # touched by a Windows editor, and the bare CR it leaves rides
            # this record into every consumer and onto the operator's
            # terminal -- and into chain_entry, which refuses it and, under
            # the installer's set -euo pipefail, takes the whole run down
            # because of a file on a partition that is only staying.
            #
            # chain_entry's refusal stays as the backstop it is meant to be.
            # The apostrophe hazard (note: "Bob's Linux") is deliberately
            # NOT sanitised here and still refuses: an apostrophe is part of
            # the name a human chose, and silently rewriting a neighbour's
            # OS name in the boot menu is worse than saying so. A carriage
            # return is nobody's name.
            name=$(grep -m1 '^NAME=' "${tmp}/etc/os-release" 2>/dev/null | cut -d= -f2- | tr -d '"\r' || true)
            has_grub=no
            [[ -d "${tmp}/boot/grub" ]] && has_grub=yes
            printf '%s %s %s %s\n' "$dev" "$uuid" "$has_grub" "${name:-unknown}"
        elif [[ -e "${tmp}/etc/os-release" ]]; then
            # Present and unreadable is the same shape as a mount that failed --
            # a filesystem nobody could read -- and is reported the same way,
            # rather than dropped. Distinguished from ABSENT deliberately: a
            # partition with no /etc/os-release at all is not a Linux install
            # and has no business in this list. That drop is a fact about the
            # filesystem, like the fstype and exclude tests above it, and not
            # the "a tool broke, so nothing was found" the banner forbids.
            error "linux_installs: ${dev} (${fstype}) has an unreadable /etc/os-release; it is reported as unknown rather than skipped"
            printf '%s %s unknown (unreadable)\n' "$dev" "$uuid"
        fi
        umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
        rmdir "$tmp" 2>/dev/null || true
    done
}

# --- registering this install with the firmware -----------------------------

# nvram_register_removable <esp_partition> <label>
#
# Give this install a firmware boot entry pointing at \EFI\BOOT\BOOTX64.EFI on
# <esp_partition>, unless the firmware already has one for that exact
# (partition, path) pair.
#
# grub-install --removable does not create one. Upstream's util/grub-install.c
# forces the EFI distributor to "BOOT" when --removable is given, and then
# guards the registration with `if (!removable && update_nvram)` -- so a
# removable install writes the fallback binary and leaves the firmware's boot
# list untouched. That is only survivable on a machine whose firmware has
# nothing else to boot: where another operating system is already registered,
# the fallback path is never reached and this install is in no boot menu at
# all. On the machine this installer was written for, Windows is registered.
#
# Destructive, so `efibootmgr --create` goes through run_cmd (lib/disk.sh) like
# every other write in this installer -- this function is the one thing in this
# file that depends on that module. The read half is the same read-only
# `efibootmgr -v` the inventory above uses.
#
# efibootmgr's --disk/--part are necessarily device-based, which is why this
# resolves them from lsblk at the moment of the write rather than storing them:
# device names are not stable across boots, and the entry the firmware keeps
# records the partition GUID, not the name.
#
# Returns non-zero when it registered nothing, which is warning-grade for the
# caller: phase 5 has already installed a working system by the time this runs,
# and phase 6's chainload entries are a second route in.
nvram_register_removable() {
    local dev=$1 label=$2
    local raw path pkname partn partuuid
    local disk="" num="" guid=""
    local enum epartuuid epath elabel
    local partuuid_re='^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$'

    [[ -n "$dev" ]] || { error "nvram_register_removable: no ESP partition given"; return 1; }
    # The same character set lib/chroot.sh's preflight enforces on
    # BOOTLOADER_ID, and for the same reason: every id reaching either place
    # comes from bootloader_id_from, which emits only [A-Z0-9_], so anything
    # else arrived by a route that skipped it.
    #
    # The leading character is excluded from the "-" half deliberately.
    # efibootmgr's own getopt takes the word after --label as the label
    # whatever it starts with, so this is not an injection -- but run_cmd
    # prints this command under --dry-run and the warning in install.sh's
    # chroot_register_nvram prints it for the operator to run by hand, and a
    # label spelled "--delete-bootnum" is a paste away from being read as one.
    [[ "$label" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] || {
        error "nvram_register_removable: '$label' is not a bootloader id ([A-Za-z0-9_-], not starting with '-'); refusing to pass it to efibootmgr as a label"
        return 1
    }

    # PKNAME and PARTN rather than stripping digits off the name: /dev/sda2 and
    # /dev/nvme0n1p5 separate the number from the disk differently, and a
    # wrongly split name sends efibootmgr at some other partition. Checked for
    # failure like every other lsblk reader in this file -- "lsblk broke" must
    # not arrive as "that partition does not exist".
    raw=$(lsblk -pnro PATH,PKNAME,PARTN,PARTUUID) || {
        error "nvram_register_removable: lsblk failed; cannot locate $dev"
        return 1
    }
    while read -r path pkname partn partuuid; do
        [[ "$path" == "$dev" ]] || continue
        disk=$pkname; num=$partn; guid=$partuuid
        break
    done <<< "$raw"
    # All three validated rather than merely non-empty, which is the rule the
    # lsblk readers above share: lsblk leaves middle columns empty -- a
    # whole-disk row has no parent, no number and no GUID -- and default-IFS
    # `read` shifts every later column left when one of them is, so a variable
    # holding something is not evidence it holds the right thing. The GPT
    # partition GUID is also what the duplicate check below matches on, and the
    # MBR form lsblk reports (12345678-01) is not one -- the same boundary
    # fs_uuid_for_partuuid draws.
    if [[ -z "$disk" ]] || [[ ! "$num" =~ ^[0-9]+$ ]] || [[ ! "$guid" =~ $partuuid_re ]]; then
        error "nvram_register_removable: lsblk does not list $dev as a GPT partition with a parent disk; refusing to guess where to register the loader"
        return 1
    fi

    # Read before writing, so a re-run adds nothing. "efibootmgr is not
    # installed" and "the firmware lists no entries" are different facts and
    # only the second says there is nothing to duplicate, so a failed read
    # refuses rather than registering.
    raw=$(nvram_loaders) || {
        error "nvram_register_removable: cannot read the firmware's boot entries; refusing to add one that may duplicate an entry already there"
        return 1
    }
    while read -r enum epartuuid epath elabel; do
        [[ "${epartuuid,,}" == "${guid,,}" ]] || continue
        # Compared case-insensitively because FAT is: \efi\boot\bootx64.efi and
        # \EFI\BOOT\BOOTX64.EFI are one file, and a firmware that wrote the
        # entry in the other case would otherwise get a second one every run.
        [[ "${epath^^}" == "/EFI/BOOT/BOOTX64.EFI" ]] || continue
        # An entry naming this partition and this path already boots this
        # install's binary, whatever label it carries: there is exactly one
        # fallback binary per ESP, and removable_policy only lets --removable
        # through when nothing already owned that path, so the binary behind
        # such an entry is ours. The label is therefore reported rather than
        # corrected -- adding a second entry to get a nicer name is exactly
        # what "do not duplicate on a re-run" rules out.
        info "The firmware already boots $dev through \\EFI\\BOOT\\BOOTX64.EFI as entry ${enum} ($elabel) -- not adding a second entry."
        return 0
    done <<< "$raw"

    info "Registering this install with the firmware as ${label}..."
    # --create, not --create-only: it also puts the new entry at the front of
    # BootOrder, which is what makes the install the machine boots by default.
    # An install the operator has to reach through the firmware's one-time boot
    # menu is the outcome this whole function exists to avoid.
    #
    # Not --quiet, deliberately: efibootmgr prints the resulting boot list, and
    # that list is the only confirmation the operator gets that the entry now
    # exists -- this function writes nothing to a disk they could go and check.
    run_cmd efibootmgr --create \
        --disk "$disk" --part "$num" \
        --loader '\EFI\BOOT\BOOTX64.EFI' --label "$label" || {
        error "nvram_register_removable: efibootmgr could not create a boot entry for $dev"
        return 1
    }
}

# --- registering into an already-installed system ---------------------------
#
# Everything below writes, or is read by something that writes, into a system
# other than the one being installed. Two rules hold across all of it.
#
# It never runs a foreign grub-mkconfig. That command regenerates the whole of
# another system's menu from the live ISO's view of the machine, and can fail
# outright on a GRUB version mismatch -- replacing a working config with one
# nobody asked for. Appending a marker-delimited block is strictly less
# destructive than regenerating everything around it, and it is what the two
# writes in register_into_foreign_grub do.
#
# Nothing here calls die. The caller runs after the new system is installed and
# bootable, so every failure below costs a menu row on a machine that still
# boots, and the decision about how loud to be belongs to the phase.

# backup_path <file> <tag> -> the first <file>.bak.<tag>.<n> that does not exist.
#
# Never overwrites: a second run of the installer must not clobber the backup
# taken before the first one, which is the copy that predates anything this
# tool did.
#
# -e rather than -f, plus -L for the dangling case: a name already taken by a
# directory is taken, and `cp -a file dir` puts the copy inside it and reports
# success -- so the backup this function promised would not exist under the
# name it handed back.
backup_path() {
    local file=$1 tag=$2 n=1
    while [[ -e "${file}.bak.${tag}.${n}" || -L "${file}.bak.${tag}.${n}" ]]; do
        n=$(( n + 1 ))
    done
    printf '%s.bak.%s.%s\n' "$file" "$tag" "$n"
}

# register_into_foreign_grub <mounted_root> <marker_id> <menuentry_block>
#
# Writes the entry twice, on purpose:
#   40_custom          -- an input to that system's grub-mkconfig, so the entry
#                         survives its next kernel update.
#   boot/grub/grub.cfg -- the generated config it actually boots from, so the
#                         entry works on the next boot without anyone having
#                         run grub-mkconfig.
#
# Statuses, and the difference between them is the whole reason there are
# three:
#   0  both files carry the block. The backup paths are on stdout.
#   1  nothing was written and any backup this call made has been removed
#      again. The other system is byte-for-byte as it was, so there is nothing
#      to undo and an unexplained .bak file in someone else's /etc would be a
#      puzzle with no answer.
#   2  40_custom carries the block and grub.cfg does not. A file on a system
#      that is staying HAS been edited; the backup paths are on stdout and are
#      the only copy of what was there before.
#
# stdout is backup paths and nothing else, so the caller can name the exact
# file to copy back rather than guessing ".1" -- which is wrong on every
# re-run. Diagnostics go to stderr through error().
#
# 40_custom is written first, and the order is the failure mode: a block that
# reaches 40_custom but not grub.cfg is invisible until that system next
# regenerates its menu, while the other order puts a row in the live menu that
# disappears at the next kernel update -- which reads as the entry having
# broken rather than as never having arrived.
#
# /boot/grub/grub.cfg is the only config shape handled. Fedora, RHEL and SUSE
# spell it grub2, and this refuses those roots -- consistently with
# linux_installs, whose has_grub field tests for /boot/grub and reports "no"
# for them, so they never reach here in the first place.
register_into_foreign_grub() {
    local root=$1 id=$2 block=$3 target
    local custom="${root}/etc/grub.d/40_custom"
    local cfg="${root}/boot/grub/grub.cfg"
    local custom_bak="" cfg_bak="" custom_created=false

    [[ -f "$cfg" ]] || {
        error "register_into_foreign_grub: no ${root}/boot/grub/grub.cfg -- nothing on that root generates a GRUB menu"
        return 1
    }

    # custom_cfg_upsert refuses both of these itself, but only after this
    # function has already copied the file -- and `cp -a` of a symlink is not a
    # backup of anything. Refusing first is what keeps status 1's promise that
    # a backup exists only when there is something to undo. The `[[ -f ]]` test
    # above does not cover it: -f dereferences, so a grub.cfg symlinked onto a
    # real file passes it. The distros that ship their generated config as a
    # link into the ESP spell the directory grub2, so they are turned away
    # earlier by linux_installs' has_grub test; what this catches is a root
    # where the config or 40_custom has been linked elsewhere by hand, which is
    # an ordinary thing to find on a machine somebody dual-boots.
    for target in "$custom" "$cfg"; do
        if [[ -L "$target" ]]; then
            error "register_into_foreign_grub: $target is a symlink; not editing it or the file it points at"
            return 1
        fi
        if [[ -e "$target" && ! -f "$target" ]]; then
            error "register_into_foreign_grub: $target exists and is not a regular file"
            return 1
        fi
    done

    mkdir -p "${root}/etc/grub.d" || {
        error "register_into_foreign_grub: cannot create ${root}/etc/grub.d"
        return 1
    }

    if [[ -f "$custom" ]]; then
        custom_bak=$(backup_path "$custom" "$id")
        cp -a -- "$custom" "$custom_bak" || {
            error "register_into_foreign_grub: could not back up $custom"
            return 1
        }
    fi
    cfg_bak=$(backup_path "$cfg" "$id")
    if ! cp -a -- "$cfg" "$cfg_bak"; then
        error "register_into_foreign_grub: could not back up $cfg"
        if [[ -n "$custom_bak" ]]; then rm -f -- "$custom_bak"; fi
        return 1
    fi

    # A 40_custom this creates has to be a *script*, not a bare block: files in
    # /etc/grub.d are executed by grub-mkconfig and it is their stdout that
    # reaches grub.cfg. Raw menuentry syntax is run as shell commands instead --
    # measured, `menuentry: command not found` and an empty stdout -- so the
    # entry silently never arrives in the regenerated menu, months later. The
    # two lines are the preamble the grub package's own 40_custom carries;
    # `exec tail -n +3 $0` makes the file print everything after them. 0755
    # here rather than as custom_cfg_upsert's mode argument because that
    # argument only applies to a file it creates itself, and by then this one
    # exists -- upsert copies its mode instead.
    if [[ ! -e "$custom" ]]; then
        # shellcheck disable=SC2016  # $0 is the created script's own argument, not ours
        if ! { printf '%s\n' '#!/bin/sh' 'exec tail -n +3 $0' > "$custom" \
                && chmod 0755 "$custom"; }; then
            error "register_into_foreign_grub: could not create $custom"
            # No custom_bak to remove: it is taken only for a 40_custom that
            # already existed, and this branch is the one where none did.
            rm -f -- "$custom" "$cfg_bak"
            return 1
        fi
        custom_created=true
    fi

    if ! custom_cfg_upsert "$custom" "$id" "$block"; then
        # custom_cfg_upsert is mktemp + mv, so a refusal leaves both targets
        # exactly as they were and the copies just taken have nothing to
        # restore. backup_path never picks a name that already existed, so
        # these two removals cannot reach a backup an earlier run took. The
        # preamble file is removed with them: status 1 promises the other
        # system is byte-for-byte as it was, and a stray executable in its
        # /etc/grub.d is not that.
        if [[ -n "$custom_bak" ]]; then rm -f -- "$custom_bak"; fi
        if [[ "$custom_created" == true ]]; then rm -f -- "$custom"; fi
        rm -f -- "$cfg_bak"
        return 1
    fi
    if ! custom_cfg_upsert "$cfg" "$id" "$block"; then
        if [[ -n "$custom_bak" ]]; then printf '%s\n' "$custom_bak"; fi
        printf '%s\n' "$cfg_bak"
        return 2
    fi

    if [[ -n "$custom_bak" ]]; then printf '%s\n' "$custom_bak"; fi
    printf '%s\n' "$cfg_bak"
    return 0
}

# neighbour_marker_id <fs_uuid> <efi_path> -> a custom_cfg_upsert marker id.
#
# Built from the filesystem UUID and the loader path, never from a device name.
# Measured on the target machine, the two NVMe disks exchanged kernel names
# between one boot and the next -- and custom_cfg_upsert matches its markers
# exactly, so an id spelled NEIGHBOUR_nvme1n1p1 leaves the previous run's block
# in place and appends a second one. That is a duplicated menu row per reboot,
# in our own config.
#
# custom_cfg_upsert refuses an id outside [A-Za-z0-9_-] and every EFI path
# carries slashes and a dot, so everything outside that set is mapped to an
# underscore rather than dropped: dropping would let /EFI/BOOT/BOOTX64.EFI and
# /EFI/BOOTBOOTX64/EFI land on one id, and one block would then overwrite the
# other.
neighbour_marker_id() {
    local uuid=$1 path=$2 id
    [[ -n "$uuid" && -n "$path" ]] || {
        error "neighbour_marker_id: need a filesystem uuid and an EFI path"
        return 1
    }
    id="NEIGHBOUR_${uuid}_${path}"
    id=${id//[^A-Za-z0-9_-]/_}
    printf '%s\n' "$id"
}

# neighbour_loaders <our_esp_dev> <our_esp_fs_uuid> [<our_efi_path>...]
#   -> "<fs_uuid> <efi_path> <label>", one row per bootloader belonging to some
#      other operating system.
#
# Two routes, because neither one sees everything:
#
#   NVRAM     every loader the firmware holds an entry for. Needs neither root
#             nor a mount, carries the firmware's own label -- a far better
#             menu row than anything this can synthesise -- and is the only
#             route that reaches a neighbour sharing OUR ESP, which the scan
#             below skips wholesale.
#   ESP scan  every other ESP on the machine, whether or not the firmware still
#             has an entry for it. A UEFI setup menu can clear NVRAM, and an
#             installer that then found nothing would leave the neighbour off
#             the menu it is here to build.
#
# They overlap, and on the machine this was written for they overlap on
# everything: `Boot0005 UEFI OS` is /EFI/BOOT/BOOTX64.EFI on nvme1n1p5, which
# esp_probe finds too, and `Boot0000 Windows Boot Manager` is the bootmgfw
# esp_probe finds on nvme1n1p1. Undeduplicated, that machine's menu gets two
# rows per operating system.
#
# The key is (fs uuid, EFI path), case-folded. Folding is not tidiness: FAT is
# case-insensitive and the two routes genuinely disagree, efibootmgr printing
# \EFI\MICROSOFT\BOOT\BOOTMGFW.EFI where the directory Windows created is
# spelled EFI/Microsoft/Boot. NVRAM is read first, so it wins a tie and the row
# keeps the firmware's label.
#
# Our own install is excluded by seeding the seen-set with (<our_esp_fs_uuid>,
# <our_efi_path>) for each path given, and never by dropping our ESP's UUID: on
# a shared ESP the neighbour this exists for has exactly the filesystem uuid we
# do. The ESP scan skips our own ESP by device path on top of that, for two
# reasons that have nothing to do with which loader is whose: by the time this
# runs, that partition is mounted read-write at /mnt/boot and a second
# read-only mount of it reads metadata we are still changing; and under
# --dry-run it was never formatted, so esp_probe would report it unreadable.
# A neighbour sharing that ESP is reached through NVRAM instead, which is the
# route that needs no mount at all.
#
# Fails rather than returning fewer rows when either route's tool fails -- the
# rule this file's inventory banner states, and it matters here because "no
# other bootloader" is the answer under which the phase adds nothing and says
# nothing is there. A single row it cannot resolve or cannot represent is
# dropped with an error on stderr; stdout carries records only, so nothing here
# may use info/warn/success.
#
# Known limitation: an NVRAM entry naming a loader that has since been deleted
# is emitted like any other, because telling would mean mounting the partition
# it names. It costs a menu row that fails to boot.
neighbour_loaders() {
    (( $# >= 2 )) || {
        error "neighbour_loaders: need this install's ESP device and filesystem uuid"
        return 1
    }
    local our_dev=$1 our_uuid=$2
    shift 2
    local -A seen=()
    local -a rows=()
    local raw line num partuuid path label uuid dev size probe key p

    for p in "$@"; do
        seen["${our_uuid,,}"$'\t'"${p,,}"]=1
    done

    raw=$(nvram_loaders) || {
        error "neighbour_loaders: cannot read the firmware's boot entries"
        return 1
    }
    rows=()
    if [[ -n "$raw" ]]; then mapfile -t rows <<< "$raw"; fi
    for line in "${rows[@]}"; do
        read -r num partuuid path label <<< "$line"
        [[ -n "$partuuid" && -n "$path" ]] || continue
        if ! uuid=$(fs_uuid_for_partuuid "$partuuid"); then
            # "no such partition" and "lsblk broke" both come back as 1 and
            # cannot be told apart here. Dropping the row is right for the
            # first -- an NVRAM entry for a disk that has left the machine --
            # and the second cannot go unnoticed, because the ESP scan below
            # reads the same lsblk and fails this whole function.
            error "neighbour_loaders: boot entry ${num} names partition ${partuuid}, which has no filesystem uuid here; skipping it"
            continue
        fi
        key="${uuid,,}"$'\t'"${path,,}"
        [[ -n "${seen[$key]:-}" ]] && continue
        seen[$key]=1
        printf '%s %s %s\n' "$uuid" "$path" "$label"
    done

    raw=$(esp_list) || {
        error "neighbour_loaders: cannot list this machine's EFI System Partitions"
        return 1
    }
    rows=()
    if [[ -n "$raw" ]]; then mapfile -t rows <<< "$raw"; fi
    for line in "${rows[@]}"; do
        # shellcheck disable=SC2034  # size is read for field symmetry with esp_list
        read -r dev uuid size <<< "$line"
        [[ -n "$dev" ]] || continue
        [[ "$dev" == "$our_dev" ]] && continue
        # parse_esp_list emits a literal "-" for an ESP that has never been
        # formatted. It is not a uuid, and an unformatted ESP has nothing on it
        # to chainload.
        [[ "$uuid" == "-" ]] && continue
        probe=$(esp_probe "$dev") || {
            error "neighbour_loaders: could not probe ${dev}; skipping it"
            continue
        }
        path=$(sed -n 's|^efipath ||p' <<< "$probe")
        [[ -n "$path" ]] || continue
        # esp_vendor_efi_path does not validate what it returns, and a vendor
        # directory called "My Vendor" is legal on FAT. Emitted as-is it puts a
        # space in the middle of a record whose LAST field is the only one
        # allowed to hold one, so every consumer reads the path as "/EFI/My" --
        # which chain_entry accepts and which chainloads nothing.
        # efi_path_to_slashes applies chain_entry's own rule and says so on
        # stderr, so the refusal happens here rather than at the boot menu.
        path=$(efi_path_to_slashes "$path") || continue
        key="${uuid,,}"$'\t'"${path,,}"
        [[ -n "${seen[$key]:-}" ]] && continue
        seen[$key]=1
        # The label names the filesystem uuid rather than the device: this
        # string becomes a permanent menu row, and a device name is not the
        # same partition on the next boot. The NVRAM route above is where the
        # readable names come from.
        printf '%s %s Existing bootloader on %s\n' "$uuid" "$path" "$uuid"
    done
}
