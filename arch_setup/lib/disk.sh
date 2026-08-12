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
