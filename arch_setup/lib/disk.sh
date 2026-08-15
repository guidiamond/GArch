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
    num=${BASH_REMATCH[1]}
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
    aligned_start=$(( (start + 2047) / 2048 * 2048 ))
    aligned_end=$(( (end + 1) / 2048 * 2048 - 1 ))
    (( aligned_end > aligned_start )) || return 1
    echo "${aligned_start} ${aligned_end}"
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
