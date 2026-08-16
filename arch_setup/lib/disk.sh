#!/bin/bash
# Partition plan, LUKS, Btrfs. The only module that destroys data.
# Requires lib/ui.sh to be sourced first.
# shellcheck shell=bash

# Plan entries: "disk|role|type_code|label|size"
# Roles: efi, root, data.  Size: "512M", "1G", or "rest".
PART_PLAN=()

DRY_RUN=${DRY_RUN:-false}

# Consumed by Task 8's executors, not by anything in this half of the file.
# shellcheck disable=SC2034
PART_EFI=""
# shellcheck disable=SC2034
PART_ROOT=""          # the block device holding btrfs (mapper device when encrypted)
# shellcheck disable=SC2034
PART_ROOT_RAW=""      # the underlying partition (differs from PART_ROOT under LUKS)
# shellcheck disable=SC2034
LUKS_ENABLED=false
# shellcheck disable=SC2034
LUKS_UUID=""
# shellcheck disable=SC2034
LUKS_NAME="cryptroot"

# shellcheck disable=SC2034
BTRFS_SUBVOLS=("@:/" "@home:/home" "@snapshots:/.snapshots" "@var_log:/var/log")
# shellcheck disable=SC2034
BTRFS_MOUNT_OPTS="noatime,compress=zstd"

# Every destructive command goes through this, so --dry-run is honest.
# Named run_cmd, not run: bats' own `run` test helper is a shell function
# of that name, and sourcing a same-named function here clobbers it for
# every later `run <cmd>` in the test file (see disk.bats regression below).
run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '%b[dry-run]%b %s\n' "$YELLOW" "$RESET" "$*"
        return 0
    fi
    "$@"
}

part_suffix() {
    [[ "$1" =~ (nvme|mmcblk|loop) ]] && echo "p" || echo ""
}

part_device() {
    local disk=$1 index=$2
    echo "${disk}$(part_suffix "$disk")${index}"
}

size_to_sgdisk() {
    local size=$1
    [[ "$size" == "rest" ]] && { echo "0"; return 0; }
    [[ "$size" =~ ^[0-9]+[MG]$ ]] || { error "invalid partition size: '$size'"; return 1; }
    echo "+${size}"
}

# Sizes to sectors, for the carve path. size_to_sgdisk hands "+1G" to sgdisk
# and lets it do the arithmetic, which is fine when sgdisk picks the start too.
# Carving cannot do that: the plan has to know each partition's end before any
# of them exist, so that --dry-run prints the same sectors a real run creates
# and a plan that does not fit is rejected before the first sgdisk call rather
# than halfway through the gap.
size_to_sectors() {
    local size=$1 sector=${2:-512} unit num
    [[ "$size" =~ ^([0-9]+)([MG])$ ]] \
        || { error "size_to_sectors: want an integer followed by M or G, got '${size}'"; return 1; }
    # 10# forces base 10: bash arithmetic reads a leading-zero numeral as octal,
    # so "010M" silently produced 8 MiB and "08G" died on an invalid octal digit
    # with a raw bash diagnostic instead of this function's own error.
    num=$(( 10#${BASH_REMATCH[1]} ))
    unit=${BASH_REMATCH[2]}
    (( num > 0 )) || { error "size_to_sectors: zero-sized partition requested"; return 1; }
    case "$unit" in
        M) echo $(( num * 1048576 / sector )) ;;
        G) echo $(( num * 1073741824 / sector )) ;;
    esac
}

# GPT partitions want a 1 MiB-aligned start, and a last sector one below the
# next alignment boundary. Misaligning costs read-modify-write on every 4Kn and
# SSD write for the life of the install -- silent, and invisible in any test
# that only checks the partition exists.
#
# Fails, printing nothing, when alignment eats the whole gap: the caller is
# iterating gaps parted reported, and the sub-MiB slivers GPT leaves between
# partitions are the common case, not an error worth a message.
align_gap() {
    local start=$1 end=$2 aligned_start aligned_end
    # Validated before the arithmetic, not after: bash resolves a non-numeric
    # token as a variable name rather than failing, so an unexpected field from
    # a parser upstream would round some unrelated variable's value into a
    # confident-looking sector range with a zero exit status.
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || return 1
    aligned_start=$(( (start + 2047) / 2048 * 2048 ))
    aligned_end=$(( (end + 1) / 2048 * 2048 - 1 ))
    (( aligned_end > aligned_start )) || return 1
    echo "${aligned_start} ${aligned_end}"
}

# Gaps smaller than this are not offered. GPT leaves a 34-sector header hole at
# the front of every disk and alignment padding between partitions; listing
# them as installable space is noise that makes the real gap harder to find.
MIN_GAP_MIB=16

# parse_free_gaps: parted machine output on stdin -> "start end size" in
# sectors, one gap per line.
#
# Reads stdin rather than taking a disk, so the parser is testable against
# canned output from a parted this machine does not have. disk_free_gaps below
# is the half that touches a disk.
#
# Keys on the trailing "free" field, not on the field count: parted's free-space
# rows carry five fields and partition rows seven, but that has changed between
# releases and the marker has not. An fstype column can be empty; it cannot be
# the string "free".
#
# `num` is read and unused -- parted repeats a meaningless partition number on
# free rows, and reading it keeps the field list matching the row format.
# shellcheck disable=SC2034
parse_free_gaps() {
    local sector_bytes=512 min_sectors line num start end size marker
    while IFS= read -r line; do
        line=${line%;}
        # The disk row is the second line and carries the logical sector size
        # in field 4. A 4Kn disk reports 4096 there, and taking 512 on faith
        # would put the minimum-gap threshold out by a factor of eight.
        if [[ "$line" == /dev/* ]]; then
            IFS=: read -r _ _ _ sector_bytes _ <<< "$line"
            # Zero is numeric but not a valid divisor: a disk row reporting it
            # would otherwise abort the function with a bash arithmetic error
            # on the very next gap instead of falling back like any other
            # unusable value.
            [[ "$sector_bytes" =~ ^[0-9]+$ && "$sector_bytes" -gt 0 ]] || sector_bytes=512
            continue
        fi
        IFS=: read -r num start end size marker <<< "$line"
        [[ "$marker" == "free" ]] || continue
        start=${start%s}; end=${end%s}; size=${size%s}
        [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ ]] || continue
        min_sectors=$(( MIN_GAP_MIB * 1048576 / sector_bytes ))
        (( size >= min_sectors )) || continue
        printf '%s %s %s\n' "$start" "$end" "$size"
    done
}

# disk_free_gaps <disk> -- the same, for a real disk.
#
# Not run through run_cmd: it reads the partition table and writes nothing, so
# a dry run wants the real answer. Suppressing stderr loses parted's "unknown
# partition table" complaint on a blank disk, which is the expected case there
# and would otherwise print mid-prompt.
#
# That same redirect also swallows a real failure -- a bad device path,
# permission denied, a disk that vanished mid-read -- so this function cannot
# tell "no free space" from "could not read the disk"; both print nothing and
# exit success from parted's side of the pipe. Under a caller running
# set -euo pipefail, a parted failure here aborts the whole script with no
# diagnostic anywhere. Validating that $disk exists and is readable is the
# caller's job, before calling this, not this function's.
disk_free_gaps() {
    local disk=$1
    parted -m -s "$disk" unit s print free 2>/dev/null | parse_free_gaps
}

# carve_layout <gap_start> <gap_end> <size>... -> "start end" per size.
#
# The whole plan is resolved to sectors here, before any sgdisk runs, so a
# request that does not fit is refused while the disk is still untouched. The
# alternative -- letting sgdisk discover it -- fails with some partitions
# already created, on a disk the operator chose precisely because it holds data
# they are keeping.
carve_layout() {
    local gap_start=$1 gap_end=$2; shift 2
    # Validated before any (( )) touches them, same as align_gap: bash
    # resolves a non-numeric token as a variable name in arithmetic context
    # rather than failing (gap_start=i collided with this function's own loop
    # counter below and printed a fabricated-looking range at status 0), and
    # (( )) also expands $(...) and arithmetic expressions, so an unvalidated
    # bound can silently evaluate to a different number than the one printed.
    [[ "$gap_start" =~ ^[0-9]+$ && "$gap_end" =~ ^[0-9]+$ ]] \
        || { error "carve_layout: gap bounds must be plain integers, got '${gap_start}' '${gap_end}'"; return 1; }
    local cursor=$gap_start size sectors end i=0 n=$#
    for size in "$@"; do
        i=$(( i + 1 ))
        if [[ "$size" == "rest" ]]; then
            (( i == n )) \
                || { error "carve_layout: only the last partition may be 'rest'"; return 1; }
            end=$gap_end
        else
            sectors=$(size_to_sectors "$size") || return 1
            end=$(( cursor + sectors - 1 ))
        fi
        (( end <= gap_end )) \
            || { error "carve_layout: the requested layout does not fit in the gap (need through sector ${end}, gap ends at ${gap_end})"; return 1; }
        (( end > cursor )) \
            || { error "carve_layout: '${size}' leaves no sectors"; return 1; }
        printf '%s %s\n' "$cursor" "$end"
        # Next partition starts on the following 1 MiB boundary, not at end+1:
        # sgdisk would silently align it forward anyway, and then the plan's
        # printed sectors and the disk's actual ones disagree -- which is
        # exactly what --dry-run exists to rule out.
        cursor=$(( (end + 2048) / 2048 * 2048 ))
    done
}

# parse_part_numbers: sgdisk -p output on stdin -> one partition number a line.
parse_part_numbers() {
    local line num
    while IFS= read -r line; do
        read -r num _ <<< "$line"
        [[ "$num" =~ ^[0-9]+$ ]] || continue
        echo "$num"
    done
}

# lowest_free_number <used>... -> the lowest unused number >= 1.
#
# Computed, not counted: GPT numbers are neither contiguous nor ordered by
# offset, so "one more than the count" hands sgdisk a number that already
# exists on any disk a partition was ever deleted from -- and sgdisk -n onto an
# existing number overwrites its entry.
lowest_free_number() {
    local candidate=1 used
    while true; do
        for used in "$@"; do
            if [[ "$used" == "$candidate" ]]; then
                candidate=$(( candidate + 1 ))
                continue 2
            fi
        done
        echo "$candidate"
        return 0
    done
}

# next_part_number <disk> -- lowest_free_number against a real partition table.
#
# Stderr is suppressed the same way disk_free_gaps suppresses parted's, so
# this function cannot tell "disk has no partitions" from "could not read the
# disk" -- a bad device path or a disk that vanished mid-read makes sgdisk -p
# fail and print nothing, mapfile then populates an empty array without the
# process substitution's failure ever being observed, and lowest_free_number
# on an empty set returns 1 with success status. Per lowest_free_number's own
# comment, sgdisk -n onto number 1 overwrites whatever already holds it, so a
# caller must validate $disk exists and is readable before calling this, not
# trust a returned "1" to mean an empty table.
next_part_number() {
    local disk=$1
    local -a used=()
    mapfile -t used < <(sgdisk -p "$disk" 2>/dev/null | parse_part_numbers)
    lowest_free_number "${used[@]}"
}

# True when the partition is mounted, in use as swap, or open as a device
# mapper / md member.
#
# Checked before the plan is built, not at format time: mkfs.btrfs on a mounted
# filesystem fails, but mkfs.fat on one does not -- it happily writes a new FAT
# over a mounted ESP, and the first thing to notice is the firmware at reboot.
part_in_use() {
    local dev=$1 holders
    findmnt -S "$dev" >/dev/null 2>&1 && return 0
    swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$dev" && return 0
    # /sys/class/block/<name>/holders is non-empty while a LUKS mapping, LVM PV
    # or md array sits on top -- none of which findmnt reports, because the
    # thing that is mounted is the mapper device, not this partition.
    holders=$(ls -A "/sys/class/block/${dev##*/}/holders" 2>/dev/null || true)
    [[ -n "$holders" ]]
}

# part_occupancy <dev> -> encrypted | lvm | raid | swap | unformatted | fs:<type>
#
# Read from the filesystem signature, before any mount is attempted. This is
# the check that makes the probe fail *closed*: a LUKS container cannot be
# mounted, so a mount-first probe reports it as "could not identify" -- which
# on this machine is the neighbour's encrypted root, the exact partition that
# must never be formatted by accident.
part_occupancy() {
    local dev=$1 fstype
    # The failure and the empty answer must not collapse into the same value.
    # `lsblk ... 2>/dev/null | tr -d ... || true` made "lsblk errored" and
    # "no filesystem signature" both the empty string, which maps to
    # unformatted, which safe_to_format accepts -- a fail-open path in the one
    # function whose entire job is to fail closed. No pipe, so no `|| true` is
    # needed to satisfy pipefail either.
    fstype=$(lsblk -dno FSTYPE "$dev" 2>/dev/null) \
        || { echo "unknown"; return 0; }
    fstype=${fstype//[[:space:]]/}
    case "$fstype" in
        crypto_LUKS)       echo "encrypted"   ;;
        LVM2_member)       echo "lvm"         ;;
        linux_raid_member) echo "raid"        ;;
        swap)              echo "swap"        ;;
        "")                echo "unformatted" ;;
        *)                 echo "fs:${fstype}" ;;
    esac
}

# classify_mounted_tree <dir> -> linux:<NAME> | windows | esp | data | empty
#
# Split from part_probe_os so the classification is testable against a
# directory tree instead of needing a loop device and root.
classify_mounted_tree() {
    local root=$1 name
    if [[ -r "${root}/etc/os-release" ]]; then
        # Read with a grep+cut rather than sourcing it: /etc/os-release on an
        # unknown partition is an untrusted file, and sourcing runs it as root.
        name=$(grep -m1 '^NAME=' "${root}/etc/os-release" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
        echo "linux:${name:-unknown}"
        return 0
    fi
    [[ -d "${root}/Windows/System32" || -e "${root}/bootmgr" ]] && { echo "windows"; return 0; }
    [[ -d "${root}/EFI" ]] && { echo "esp"; return 0; }
    [[ -z "$(ls -A "$root" 2>/dev/null || true)" ]] && { echo "empty"; return 0; }
    echo "data"
}

# part_probe_os <dev> -> what is on it, in as much detail as can be had safely.
#
# Occupancy first, mount second. Read-only with noload, and unmounted on every
# exit path including failure: this runs against partitions the operator is
# *keeping*. A plain `mount -o ro` on ext4 replays a dirty journal, which is a
# write to a neighbour's filesystem -- during a phase that promises not to
# write, and during --dry-run, which promises to touch nothing at all.
part_probe_os() {
    local dev=$1 occ tmp result
    occ=$(part_occupancy "$dev")
    case "$occ" in
        encrypted|lvm|raid|swap|unformatted)
            # unformatted maps to empty so safe_to_format can accept it; the
            # other four are terminal -- there is nothing to mount and nothing
            # about them that makes formatting safe.
            [[ "$occ" == "unformatted" ]] && { echo "empty"; return 0; }
            echo "$occ"
            return 0 ;;
    esac

    tmp=$(mktemp -d) || { echo "unknown"; return 0; }
    if mount -o ro,noload "$dev" "$tmp" 2>/dev/null \
        || mount -o ro,subvol=@ "$dev" "$tmp" 2>/dev/null \
        || mount -o ro "$dev" "$tmp" 2>/dev/null; then
        result=$(classify_mounted_tree "$tmp")
        umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
    else
        # It has a filesystem signature but would not mount: a dirty NTFS, a
        # type this ISO has no driver for, or corruption. Not empty, and not
        # identifiable -- so it must not be treated as free space.
        result="unmountable:${occ#fs:}"
    fi
    rmdir "$tmp" 2>/dev/null || true
    echo "$result"
}

# safe_to_format <probe_result> -- true only for a provably empty partition.
#
# Allowlist, not a denylist. The first draft of this used a denylist and
# accepted "unknown" as free space, which meant every partition the probe
# could not open -- every encrypted one included -- was formatted silently.
safe_to_format() {
    case "$1" in
        empty|unformatted) return 0 ;;
        *)                 return 1 ;;
    esac
}

plan_reset() { PART_PLAN=(); }

plan_add() {
    local disk=$1 role=$2 type_code=$3 label=$4 size=$5
    [[ "$disk" == /dev/* ]] || { error "plan_add: '$disk' is not an absolute device path"; return 1; }
    size_to_sgdisk "$size" >/dev/null || return 1
    PART_PLAN+=("${disk}|${role}|${type_code}|${label}|${size}")
}

# Unique disks, in the order they first appear.
plan_disks() {
    local entry disk seen=""
    for entry in "${PART_PLAN[@]}"; do
        IFS='|' read -r disk _ _ _ _ <<< "$entry"
        [[ "$seen" == *"|${disk}|"* ]] && continue
        seen="${seen}|${disk}|"
        echo "$disk"
    done
}

plan_render() {
    local disk entry e_disk e_role e_type e_label e_size n disk_size
    while read -r disk; do
        [[ -z "$disk" ]] && continue
        disk_size=$(lsblk -dnpo SIZE "$disk" 2>/dev/null | xargs || echo "?")
        printf '\n'
        warn "${disk} (${disk_size}) -- WILL BE WIPED"
        n=0
        for entry in "${PART_PLAN[@]}"; do
            # e_type is parsed for symmetry with the entry format but not
            # printed below.
            # shellcheck disable=SC2034
            IFS='|' read -r e_disk e_role e_type e_label e_size <<< "$entry"
            [[ "$e_disk" != "$disk" ]] && continue
            n=$((n + 1))
            printf '    %-16s %-6s %-6s %s\n' \
                "$(part_device "$disk" "$n")" "$e_size" "$e_role" "$e_label"
        done
    done < <(plan_disks)
}

plan_execute() {
    local disk entry e_disk e_role e_type e_label e_size n partdev size_flag
    while read -r disk; do
        [[ -z "$disk" ]] && continue
        info "Partitioning ${disk}..."
        run_cmd sgdisk --zap-all "$disk"
        n=0
        for entry in "${PART_PLAN[@]}"; do
            IFS='|' read -r e_disk e_role e_type e_label e_size <<< "$entry"
            [[ "$e_disk" != "$disk" ]] && continue
            n=$((n + 1))
            size_flag=$(size_to_sgdisk "$e_size") || return 1
            run_cmd sgdisk -n "${n}:0:${size_flag}" -t "${n}:${e_type}" -c "${n}:${e_label}" "$disk"
            partdev=$(part_device "$disk" "$n")
            # PART_ROOT_RAW is consumed by luks_format/luks_open, not by
            # anything in this file.
            # shellcheck disable=SC2034
            case "$e_role" in
                efi)  PART_EFI="$partdev" ;;
                root) PART_ROOT_RAW="$partdev" ;;
            esac
        done
        run_cmd partprobe "$disk"
        [[ "$DRY_RUN" == true ]] || sleep 1
        success "Partitioned ${disk}"
    done < <(plan_disks)
}

# Passphrase is fed on stdin so it never reaches the process table.
luks_format() {
    local part=$1 passphrase=$2
    [[ -n "$passphrase" ]] || { error "luks_format: empty passphrase"; return 1; }
    info "Creating LUKS2 container on ${part}..."
    if [[ "$DRY_RUN" == true ]]; then
        run_cmd "cryptsetup luksFormat --type luks2 --batch-mode ${part} (passphrase on stdin)"
        return 0
    fi
    printf '%s' "$passphrase" | cryptsetup luksFormat --type luks2 --batch-mode "$part" -
}

luks_open() {
    local part=$1 name=$2 passphrase=$3
    [[ -n "$passphrase" ]] || { error "luks_open: empty passphrase"; return 1; }
    info "Opening ${part} as /dev/mapper/${name}..."
    if [[ "$DRY_RUN" == true ]]; then
        run_cmd "cryptsetup open ${part} ${name} (passphrase on stdin)"
        LUKS_UUID="00000000-0000-0000-0000-000000000000"
        PART_ROOT="/dev/mapper/${name}"
        LUKS_ENABLED=true
        return 0
    fi
    printf '%s' "$passphrase" | cryptsetup open "$part" "$name" -
    # LUKS_UUID and PART_ROOT are consumed by later tasks (crypttab
    # generation, btrfs mounting in install.sh), not by anything in this file.
    # shellcheck disable=SC2034
    LUKS_UUID=$(blkid -s UUID -o value "$part")
    # shellcheck disable=SC2034
    PART_ROOT="/dev/mapper/${name}"
    LUKS_ENABLED=true
}

luks_close() {
    [[ "$LUKS_ENABLED" == true ]] || return 0
    run_cmd cryptsetup close "$LUKS_NAME" 2>/dev/null || true
}

btrfs_create_subvols() {
    local dev=$1 entry name
    info "Creating Btrfs subvolumes on ${dev}..."
    run_cmd mkfs.btrfs -f -L archroot "$dev"
    run_cmd mount "$dev" /mnt
    for entry in "${BTRFS_SUBVOLS[@]}"; do
        name="${entry%%:*}"
        run_cmd btrfs subvolume create "/mnt/${name}"
    done
    run_cmd umount /mnt
}

btrfs_mount_all() {
    local dev=$1 target=$2 entry name mountpoint full
    info "Mounting Btrfs subvolumes..."
    run_cmd mount -o "${BTRFS_MOUNT_OPTS},subvol=@" "$dev" "$target"
    for entry in "${BTRFS_SUBVOLS[@]}"; do
        name="${entry%%:*}"
        mountpoint="${entry##*:}"
        [[ "$name" == "@" ]] && continue
        full="${target}${mountpoint}"
        run_cmd mkdir -p "$full"
        run_cmd mount -o "${BTRFS_MOUNT_OPTS},subvol=${name}" "$dev" "$full"
    done
}

mount_esp() {
    local target=$1
    run_cmd mkdir -p "${target}/boot"
    run_cmd mount "$PART_EFI" "${target}/boot"
}
