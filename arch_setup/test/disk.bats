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

@test "luks_close under DRY_RUN goes through run_cmd instead of really closing" {
    DRY_RUN=true
    LUKS_ENABLED=true
    run luks_close
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run]"* ]]
    [[ "$output" == *"cryptsetup close cryptroot"* ]]
}

@test "size_to_sectors converts M and G at 512-byte sectors" {
    [ "$(size_to_sectors 1G)" = "2097152" ]
    [ "$(size_to_sectors 512M)" = "1048576" ]
}

@test "size_to_sectors honours a non-512 sector size" {
    [ "$(size_to_sectors 1G 4096)" = "262144" ]
}

@test "size_to_sectors rejects rest, bare numbers and garbage" {
    run size_to_sectors rest
    [ "$status" -ne 0 ]
    run size_to_sectors 100
    [ "$status" -ne 0 ]
    run size_to_sectors "; rm -rf /"
    [ "$status" -ne 0 ]
}

@test "align_gap rounds start up and end down to 1MiB" {
    [ "$(align_gap 34 1000000)" = "2048 999423" ]
}

@test "align_gap leaves an already-aligned gap alone" {
    [ "$(align_gap 2048 999423)" = "2048 999423" ]
}

@test "align_gap emits nothing when alignment collapses the gap" {
    run align_gap 2049 4000
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "parse_free_gaps finds the trailing gap and skips partitions" {
    run bash -c "MIN_GAP_MIB=16; $(declare -f parse_free_gaps); cat <<'PARTED' | parse_free_gaps
BYT;
/dev/nvme0n1:1953525168s:nvme:512:512:gpt:NVMe Device:;
1:34s:32767s:32734s::Microsoft reserved partition:msftres;
2:32768s:1024032767s:1024000000s:ntfs:Basic data partition:msftdata;
1:1024032768s:1953525134s:929492367s:free;
PARTED"
    [ "$status" -eq 0 ]
    [ "$output" = "1024032768 1953525134 929492367" ]
}

@test "parse_free_gaps drops slivers below the minimum" {
    run bash -c "MIN_GAP_MIB=16; $(declare -f parse_free_gaps); cat <<'PARTED' | parse_free_gaps
BYT;
/dev/sda:1000s:scsi:512:512:gpt:Fixture:;
1:34s:2047s:2014s:free;
PARTED"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "parse_free_gaps scales the minimum by the disk's sector size" {
    # 8192 sectors at 4096 bytes is 32 MiB, over the 16 MiB floor. The same
    # sector count at 512 bytes would be 4 MiB and must be dropped -- so this
    # fails if the parser hardcodes 512.
    run bash -c "MIN_GAP_MIB=16; $(declare -f parse_free_gaps); cat <<'PARTED' | parse_free_gaps
BYT;
/dev/sda:2000000s:scsi:4096:4096:gpt:Fixture:;
1:2048s:10239s:8192s:free;
PARTED"
    [ "$output" = "2048 10239 8192" ]
}

@test "parse_free_gaps reports every gap on a fragmented disk" {
    run bash -c "MIN_GAP_MIB=16; $(declare -f parse_free_gaps); cat <<'PARTED' | parse_free_gaps
BYT;
/dev/sda:2000000000s:scsi:512:512:gpt:Fixture:;
1:2048s:100000s:97953s:ext4::;
1:100001s:600000s:499999s:free;
2:600001s:700000s:100000s:ntfs::;
1:700001s:1999999966s:1999299966s:free;
PARTED"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "100001 600000 499999" ]
    [ "${lines[1]}" = "700001 1999999966 1999299966" ]
}

@test "parse_free_gaps ignores an fstype column that is empty" {
    run bash -c "MIN_GAP_MIB=16; $(declare -f parse_free_gaps); cat <<'PARTED' | parse_free_gaps
BYT;
/dev/sda:2000000s:scsi:512:512:gpt:Fixture:;
1:2048s:1000000s:997953s::Some Label:;
PARTED"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
