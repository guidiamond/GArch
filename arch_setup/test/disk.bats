#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/disk.sh"
    plan_reset
}

@test "part_suffix is p for nvme" {
    [ "$(part_suffix /dev/nvme0n1)" = "p" ]
}

@test "part_suffix is p for mmcblk" {
    [ "$(part_suffix /dev/mmcblk0)" = "p" ]
}

@test "part_suffix is empty for sata" {
    [ "$(part_suffix /dev/sda)" = "" ]
}

@test "part_device builds nvme paths" {
    [ "$(part_device /dev/nvme0n1 2)" = "/dev/nvme0n1p2" ]
}

@test "part_device builds sata paths" {
    [ "$(part_device /dev/sda 1)" = "/dev/sda1" ]
}

@test "size_to_sgdisk maps rest to 0" {
    [ "$(size_to_sgdisk rest)" = "0" ]
}

@test "size_to_sgdisk prefixes absolute sizes with +" {
    [ "$(size_to_sgdisk 1G)" = "+1G" ]
    [ "$(size_to_sgdisk 512M)" = "+512M" ]
}

@test "size_to_sgdisk rejects garbage" {
    run size_to_sgdisk "; rm -rf /"
    [ "$status" -ne 0 ]
}

@test "plan_reset empties the plan" {
    plan_add /dev/sda efi ef00 EFI 1G
    plan_reset
    [ "${#PART_PLAN[@]}" -eq 0 ]
}

@test "plan_disks returns unique disks in insertion order" {
    plan_add /dev/sdb efi  ef00 EFI  1G
    plan_add /dev/sdb root 8300 Root rest
    plan_add /dev/sda data 8300 Data rest
    [ "$(plan_disks)" = "$(printf '/dev/sdb\n/dev/sda')" ]
}

@test "plan_add rejects a non-absolute device path" {
    run plan_add sda efi ef00 EFI 1G
    [ "$status" -ne 0 ]
}

@test "plan_render names the device for each entry" {
    plan_add /dev/nvme0n1 efi  ef00 EFI  1G
    plan_add /dev/nvme0n1 root 8300 Root rest
    run plan_render
    [[ "$output" == *"/dev/nvme0n1p1"* ]]
    [[ "$output" == *"/dev/nvme0n1p2"* ]]
    [[ "$output" == *"WILL BE WIPED"* ]]
}

@test "plan_execute under DRY_RUN issues sgdisk but runs nothing" {
    DRY_RUN=true
    plan_add /dev/sdz efi  ef00 EFI  1G
    plan_add /dev/sdz root 8300 Root rest
    run plan_execute
    [ "$status" -eq 0 ]
    [[ "$output" == *"sgdisk --zap-all /dev/sdz"* ]]
    [[ "$output" == *"-n 1:0:+1G"* ]]
    [[ "$output" == *"-t 1:ef00"* ]]
    [[ "$output" == *"-n 2:0:0"* ]]
    [[ "$output" == *"-t 2:8300"* ]]
}

@test "plan_execute under DRY_RUN assigns the role globals" {
    DRY_RUN=true
    plan_add /dev/sdz efi  ef00 EFI  1G
    plan_add /dev/sdz root 8300 Root rest
    plan_execute
    [ "$PART_EFI" = "/dev/sdz1" ]
    [ "$PART_ROOT_RAW" = "/dev/sdz2" ]
}

@test "btrfs_create_subvols under DRY_RUN creates all four subvolumes" {
    DRY_RUN=true
    run btrfs_create_subvols /dev/mapper/cryptroot
    [[ "$output" == *"subvolume create /mnt/@"* ]]
    [[ "$output" == *"subvolume create /mnt/@home"* ]]
    [[ "$output" == *"subvolume create /mnt/@snapshots"* ]]
    [[ "$output" == *"subvolume create /mnt/@var_log"* ]]
}

@test "btrfs_mount_all mounts @ first with compression" {
    DRY_RUN=true
    run btrfs_mount_all /dev/sdz2 /mnt
    [[ "$output" == *"noatime,compress=zstd,subvol=@ /dev/sdz2 /mnt"* ]]
    [[ "$output" == *"subvol=@home /dev/sdz2 /mnt/home"* ]]
    [[ "$output" == *"subvol=@var_log /dev/sdz2 /mnt/var/log"* ]]
}

@test "luks_open refuses an empty passphrase" {
    DRY_RUN=true
    run luks_open /dev/sdz2 cryptroot ""
    [ "$status" -ne 0 ]
}
