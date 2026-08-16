#!/bin/bash
# Partition plan, LUKS, Btrfs. The only module that destroys data.
# Requires lib/ui.sh to be sourced first.
# shellcheck shell=bash

# Plan entries: "disk|role|type_code|label|size|source|start|end"
# Roles: efi, root, data.  Size: "512M", "1G", or "rest".
# Source: "new" to create it, or a /dev/... path to adopt an existing partition.
# Start/end: sectors, set only when carving into a gap; empty means "let sgdisk
# place it" -- correct only on a disk that was just wiped, which plan_validate
# enforces rather than trusting.
#
# Eight fields, and every `IFS='|' read` below must name all eight. The sites
# that change together when a field is added: plan_add (which joins them),
# plan_has_role, plan_disks, plan_render (twice) and plan_validate. A site left
# at the old arity does not fail -- read's last variable silently absorbs the
# remainder -- so the symptom is every later field shifted by one, which is the
# same corruption a stray '|' in a field causes and which plan_add now refuses.
PART_PLAN=()

# Whole-disk mode sets this. It gates the single `sgdisk --zap-all` in this
# file, and it is a separate flag rather than something inferred from the
# entries because "no entry says otherwise" is the wrong default for a command
# that destroys a partition table.
PLAN_WIPE_DISKS=${PLAN_WIPE_DISKS:-false}

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
#
# A predicate, not a guard: every call site must sit inside a conditional
# (if/while/&&/||). install.sh and lib/chroot.sh both run under
# `set -euo pipefail`, and the common case -- the partition is idle -- returns
# 1. A bare `part_in_use "$dev"` as a statement on its own aborts the whole
# installer on exactly the input that should let it proceed.
#
# Fails *open*, unlike part_occupancy below, if findmnt or swapon is missing
# from PATH: both short-circuits swallow a 127 the same way they swallow a
# real "not mounted"/"not swapped on" result, so a partition reports as idle
# because the tool could not run, not because it was checked and found free.
# Not guarded here -- both are base util-linux and always present on the Arch
# ISO -- but the asymmetry with part_occupancy's deliberate "unknown" is
# worth knowing before trusting this on anything other than that ISO.
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
#
# Reports "data", not "empty", for a partition that was freshly `mkfs.ext4`'d
# and never used: `lost+found` always exists, so `ls -A` is never empty.
# Fails closed -- data is refused the same as anything else unrecognised --
# so this is safe, but it means an operator who deliberately pre-formatted
# their target partition lands on the extra-confirmation path rather than
# being told it is empty. Task 10's prompt wording needs to account for that.
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
# Occupancy first, mount second, and unmounted on every exit path including
# failure: this runs against partitions the operator is *keeping*, during a
# phase that promises not to write, and during --dry-run, which promises to
# touch nothing at all.
#
# The read-only mount option is chosen from the filesystem type, not tried as
# a blind fallback chain ending in a bare `mount -o ro`. `noload` only means
# something to ext2/3/4 and `norecovery` only to xfs -- each is the only thing
# that stops that filesystem from replaying a dirty journal on a read-only
# mount. A bare `ro` fallback for a type this doesn't recognise (dirty XFS
# included -- `noload` is silently ignored by xfs, so it falls straight
# through to that bare mount) replays the journal just the same: a write to a
# neighbour's filesystem, the exact failure mode this function exists to rule
# out. So a type with no known-safe option, and occ == "unknown" (lsblk itself
# failed) with it, are refused outright instead of guessed at.
part_probe_os() {
    local dev=$1 occ fstype tmp mount_opts result
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
    fstype=${occ#fs:}
    case "$fstype" in
        ext2|ext3|ext4)                    mount_opts="ro,noload" ;;
        xfs)                               mount_opts="ro,norecovery" ;;
        btrfs)                             mount_opts="ro,nologreplay,subvol=@" ;;
        vfat|exfat|ntfs|ntfs3|iso9660|udf) mount_opts="ro" ;; # no journal to replay
        *)                                 mount_opts="" ;;
    esac

    if [[ -n "$mount_opts" ]] && mount -o "$mount_opts" "$dev" "$tmp" 2>/dev/null; then
        result=$(classify_mounted_tree "$tmp")
        umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
    else
        # It has a filesystem signature but would not mount: a dirty NTFS, an
        # unrecognised type with no known-safe read-only option, or
        # corruption. Not empty, and not identifiable -- so it must not be
        # treated as free space.
        result="unmountable:${fstype}"
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

# Clears the wipe flag along with the entries. Once a mode selector exists, an
# operator who picks whole-disk, backs out, and then picks custom would
# otherwise carry `true` into carve mode and wipe the disk they chose the mode
# precisely to preserve. Callers that do want the wipe set the flag *after*
# calling this, which is the order install.sh's phase_disk uses.
plan_reset() { PART_PLAN=(); PLAN_WIPE_DISKS=false; }

plan_add() {
    # Arity first, before any $5 is read: a four-argument call otherwise dies
    # with a raw `$5: unbound variable` from bash rather than this function's
    # own diagnostic. size_to_sectors takes the same care for the same reason.
    (( $# >= 5 && $# <= 8 )) \
        || { error "plan_add: want 5 to 8 arguments (disk role type_code label size [source [start end]]), got $#"; return 1; }
    local disk=$1 role=$2 type_code=$3 label=$4 size=$5
    local source=${6:-new} start=${7:-} end=${8:-}
    local field prefix index

    # A '|' or newline in any field does not corrupt that field -- it forges
    # the ones after it, because the entry is joined and split on '|'.
    # Measured: a '|' in a label shifted every later field right and left
    # PART_EFI holding "1G"; a newline truncated the entry into a reuse of the
    # empty device, setting PART_ROOT_RAW="" -- the mkfs.fat "" failure
    # plan_has_role exists to prevent; and a reuse entry whose size read
    # "1|new|2048|999423" came back out as a carve entry, running sgdisk in the
    # one mode that promises never to. Refused, not escaped, as
    # chroot_write_config and grub_cmdline_add refuse their own metacharacters.
    for field in "$disk" "$role" "$type_code" "$label" "$size" "$source" "$start" "$end"; do
        [[ "$field" != *"|"* && "$field" != *$'\n'* ]] \
            || { error "plan_add: '|' and newline separate entry fields and cannot appear inside one"; return 1; }
    done
    # An empty field reaches sgdisk as an empty argument (`-c 1:`) or matches
    # no branch of plan_execute's role case, in both cases silently.
    [[ -n "$role" && -n "$type_code" && -n "$label" && -n "$size" ]] \
        || { error "plan_add: role, type_code, label and size must all be non-empty"; return 1; }
    [[ "$disk" == /dev/* ]] || { error "plan_add: '$disk' is not an absolute device path"; return 1; }

    if [[ "$source" != "new" ]]; then
        # Must be a partition *of this entry's disk*, checked by construction
        # with part_suffix so both naming conventions (sda1, nvme0n1p5) come
        # from the one place that already knows them. A bare `/dev/*` prefix
        # test was not validation: it accepted the whole disk /dev/sdz (which
        # btrfs_create_subvols would later mkfs, destroying every partition on
        # it), '/dev/', '/dev/../etc/passwd', and a partition of a *different*
        # disk -- which plan_render then listed under this disk's banner while
        # never naming the disk it would actually touch.
        prefix="${disk}$(part_suffix "$disk")"
        index=${source#"$prefix"}
        [[ "$source" != "$prefix" && "$index" != "$source" && "$index" =~ ^[0-9]+$ ]] \
            || { error "plan_add: source must be 'new' or a partition of ${disk}, got '${source}'"; return 1; }
        # The operator asked for two contradictory things; silently dropping
        # one of them picks for them.
        [[ -z "$start" && -z "$end" ]] \
            || { error "plan_add: a reuse entry cannot also carve sectors (source '${source}' with '${start}'/'${end}')"; return 1; }
        # A reuse entry's size is descriptive only -- the partition already has
        # one -- so it is not validated against sgdisk's grammar.
    else
        size_to_sgdisk "$size" >/dev/null || return 1
        if [[ -n "$start" || -n "$end" ]]; then
            # Both or neither. One alone is a half-built carve entry, and
            # plan_execute's sequential branch would take it and create the
            # partition at sgdisk's choice of offset rather than the
            # operator's.
            [[ -n "$start" && -n "$end" ]] \
                || { error "plan_add: a carve entry needs both start and end, got '${start}'/'${end}'"; return 1; }
            # Validated before any arithmetic, as align_gap and carve_layout
            # do: bash resolves a non-numeric token in (( )) as a variable name
            # instead of failing, and unvalidated sectors reach sgdisk verbatim
            # (`sgdisk -n 1:abc:def`).
            [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] \
                || { error "plan_add: carve sectors must be plain integers, got '${start}'/'${end}'"; return 1; }
            (( end > start )) \
                || { error "plan_add: carve end (${end}) must be past its start (${start})"; return 1; }
        fi
    fi
    PART_PLAN+=("${disk}|${role}|${type_code}|${label}|${size}|${source}|${start}|${end}")
}

# plan_has_role <role> -- true if the plan contains one.
#
# Exists so callers can refuse an incomplete plan *before* the Type-YES gate. A
# plan with a root and no ESP got as far as LUKS-formatting the root and then
# died on `mkfs.fat ""`, leaving a wiped partition and no install.
plan_has_role() {
    local role=$1 entry e_role
    for entry in "${PART_PLAN[@]}"; do
        IFS='|' read -r _ e_role _ _ _ _ _ _ <<< "$entry"
        [[ "$e_role" == "$role" ]] && return 0
    done
    return 1
}

# Unique disks, in the order they first appear.
plan_disks() {
    local entry disk seen=""
    for entry in "${PART_PLAN[@]}"; do
        IFS='|' read -r disk _ _ _ _ _ _ _ <<< "$entry"
        [[ "$seen" == *"|${disk}|"* ]] && continue
        seen="${seen}|${disk}|"
        echo "$disk"
    done
}

# plan_validate -- refuse an incoherent plan before anything is written.
#
# Runs over the whole plan up front rather than per disk inside plan_execute's
# write loop: refusing on the second disk after the first has already been
# zapped is not a refusal. Same reasoning as carve_layout resolving every
# partition to sectors before the first sgdisk.
plan_validate() {
    local entry e_disk e_role e_type e_label e_size e_src e_start e_end
    local disk has_reuse has_placed has_sectored
    while read -r disk; do
        [[ -z "$disk" ]] && continue
        has_reuse=false
        has_placed=false
        has_sectored=false
        for entry in "${PART_PLAN[@]}"; do
            IFS='|' read -r e_disk e_role e_type e_label e_size e_src e_start e_end <<< "$entry"
            [[ "$e_disk" != "$disk" ]] && continue
            if [[ "$e_src" != "new" ]]; then
                has_reuse=true
                has_sectored=true
            elif [[ -n "$e_start" ]]; then
                has_sectored=true
            elif [[ "$PLAN_WIPE_DISKS" == true ]]; then
                has_placed=true
            else
                # A sizeless new entry lets sgdisk place the partition from
                # sector 0 at the lowest free number, which only means anything
                # on a table that was just zapped. On a live table
                # `sgdisk -n 1:0:+1G` overwrites partition 1 -- on the target
                # machine that is the Windows ESP -- under a banner that just
                # told the operator the disk would be preserved.
                error "plan_validate: ${e_role} on ${disk} has no sectors, and only whole-disk mode may let sgdisk place it"
                return 1
            fi
        done
        # Sequential placement counts 1, 2, 3... from a table that was just
        # zapped; carving and reuse take their numbers from the live table via
        # next_part_number. Mixing the two on one disk means two numbering
        # schemes racing: measured, a carve and a sizeless-new entry were both
        # issued as `sgdisk -n 1:`, the second overwriting the first. Sharing
        # one counter instead only moves the damage -- it made plan_render's
        # column disagree with the number actually created. Neither scheme is
        # right for a mixed disk, so the mix is refused and each stays correct
        # in the case it owns.
        if [[ "$has_placed" == true && "$has_sectored" == true ]]; then
            error "plan_validate: ${disk} mixes partitions placed by sgdisk with partitions at explicit sectors; the two cannot be numbered consistently"
            return 1
        fi
        # PLAN_WIPE_DISKS is one flag for the whole plan while entries are
        # per-disk, so "wipe this disk, adopt a partition on that one" cannot
        # be expressed -- the zap destroys the partition the other entry
        # adopts. Refused rather than given a per-disk field, which is a plan
        # change Task 10 owns; "carve on one disk, reuse an ESP on another" is
        # the shape that needs it.
        if [[ "$PLAN_WIPE_DISKS" == true && "$has_reuse" == true ]]; then
            error "plan_validate: ${disk} is set to be wiped, but the plan also reuses a partition on it"
            return 1
        fi
    done < <(plan_disks)
}

plan_render() {
    local disk entry e_disk e_role e_type e_label e_size e_src e_start e_end
    local disk_size n shown predictable
    while read -r disk; do
        [[ -z "$disk" ]] && continue
        disk_size=$(lsblk -dnpo SIZE "$disk" 2>/dev/null | xargs || echo "?")
        printf '\n'
        if [[ "$PLAN_WIPE_DISKS" == true ]]; then
            warn "${disk} (${disk_size}) -- WILL BE WIPED"
        else
            info "${disk} (${disk_size}) -- WILL BE PRESERVED, only the partitions below are touched"
        fi
        # Sequential numbering is predictable only on a disk whose entire plan
        # is sequential-new on a table about to be zapped. Mix in a reuse or a
        # carve and the numbers come from the live table via next_part_number,
        # which this function never calls and cannot predict: measured, it
        # printed /dev/sdz1 for a partition plan_execute went on to create as
        # /dev/sdz2. Naming the wrong device on the screen the operator reads
        # immediately before typing YES is the one thing this must not do, so
        # an unpredictable row says so instead of guessing.
        predictable=$PLAN_WIPE_DISKS
        for entry in "${PART_PLAN[@]}"; do
            IFS='|' read -r e_disk _ _ _ _ e_src e_start _ <<< "$entry"
            [[ "$e_disk" != "$disk" ]] && continue
            if [[ "$e_src" != "new" || -n "$e_start" ]]; then
                predictable=false
            fi
        done
        n=0
        for entry in "${PART_PLAN[@]}"; do
            # e_type is parsed for symmetry with the entry format but not
            # printed below.
            # shellcheck disable=SC2034
            IFS='|' read -r e_disk e_role e_type e_label e_size e_src e_start e_end <<< "$entry"
            [[ "$e_disk" != "$disk" ]] && continue
            if [[ "$e_src" != "new" ]]; then
                shown="$e_src (reuse)"
            elif [[ -n "$e_start" ]]; then
                shown="new, sectors ${e_start}-${e_end}"
            elif [[ "$predictable" == true ]]; then
                n=$(( n + 1 ))
                shown=$(part_device "$disk" "$n")
            else
                shown="new, number assigned at write time"
            fi
            printf '    %-6s %-6s %-30s %s\n' "$e_role" "$e_size" "$shown" "$e_label"
        done
    done < <(plan_disks)
}

plan_execute() {
    local disk entry e_disk e_role e_type e_label e_size e_src e_start e_end
    local seq_n part_n partdev size_flag touched
    plan_validate || return 1
    while read -r disk; do
        [[ -z "$disk" ]] && continue
        touched=false
        # Counts the sequential entries only, and is never seeded from
        # next_part_number. One counter shared with the carve branch below let
        # the sequential branch resume from a table-derived number, so a mixed
        # plan created /dev/sdz2 for the row plan_render had called /dev/sdz1.
        #
        # Initialised per disk, not inside the wipe branch: the sizeless-new
        # path does `seq_n=$(( seq_n + 1 ))`, and in carve mode that branch was
        # reached with it never assigned -- an abort under set -u.
        seq_n=0
        if [[ "$PLAN_WIPE_DISKS" == true ]]; then
            info "Partitioning ${disk}..."
            run_cmd sgdisk --zap-all "$disk" || return 1
            touched=true
        fi
        for entry in "${PART_PLAN[@]}"; do
            IFS='|' read -r e_disk e_role e_type e_label e_size e_src e_start e_end <<< "$entry"
            [[ "$e_disk" != "$disk" ]] && continue

            if [[ "$e_src" != "new" ]]; then
                # Adopting an existing partition: no sgdisk, no partprobe, and
                # deliberately no type-code fix-up. Rewriting the GPT type of a
                # partition the operator is reusing is a write to a table this
                # mode promised not to touch, and nothing in the install needs
                # it -- GRUB finds the ESP by contents, not by type code.
                partdev=$e_src
            elif [[ -n "$e_start" ]]; then
                # Under --dry-run nothing is created, so a second carve entry on
                # the same disk prints the same partition number as the first.
                # Not a bug to fix by faking a counter: the sectors are what the
                # rehearsal is for, and a faked number would be wrong on any
                # disk with a hole in its numbering. On a real run sgdisk has
                # already written the GPT, so the next call reads the new one.
                part_n=$(next_part_number "$disk") || return 1
                run_cmd sgdisk -n "${part_n}:${e_start}:${e_end}" -t "${part_n}:${e_type}" -c "${part_n}:${e_label}" "$disk" || return 1
                partdev=$(part_device "$disk" "$part_n")
                touched=true
            else
                # Sequential placement is an explicit case now, not the branch
                # anything unrecognised falls into. plan_validate has already
                # refused this combination before a byte was written; this is
                # the second lock, for a PART_PLAN assembled by some future
                # caller that does not go through plan_add.
                [[ "$PLAN_WIPE_DISKS" == true ]] \
                    || { error "plan_execute: refusing to let sgdisk place ${e_role} on ${disk}, which is not being wiped"; return 1; }
                seq_n=$(( seq_n + 1 ))
                size_flag=$(size_to_sgdisk "$e_size") || return 1
                run_cmd sgdisk -n "${seq_n}:0:${size_flag}" -t "${seq_n}:${e_type}" -c "${seq_n}:${e_label}" "$disk" || return 1
                partdev=$(part_device "$disk" "$seq_n")
                touched=true
            fi

            # PART_ROOT_RAW is consumed by luks_format/luks_open, not by
            # anything in this file.
            # shellcheck disable=SC2034
            case "$e_role" in
                efi)  PART_EFI="$partdev" ;;
                root) PART_ROOT_RAW="$partdev" ;;
            esac
        done
        if [[ "$touched" == true ]]; then
            run_cmd partprobe "$disk"
            [[ "$DRY_RUN" == true ]] || sleep 1
            success "Partitioned ${disk}"
        fi
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
