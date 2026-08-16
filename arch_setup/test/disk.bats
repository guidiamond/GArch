#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/disk.sh"
    plan_reset
    PLAN_WIPE_DISKS=true
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

@test "parse_free_gaps falls back to 512 when the disk row reports a zero sector size" {
    # A zero here is numeric but not a valid divisor for the threshold
    # arithmetic; the parser must fall back rather than divide by it.
    run bash -c "MIN_GAP_MIB=16; $(declare -f parse_free_gaps); cat <<'PARTED' | parse_free_gaps
BYT;
/dev/sda:2000000s:scsi:0:0:gpt:Fixture:;
1:2048s:50000s:47953s:free;
PARTED"
    [ "$status" -eq 0 ]
    [ "$output" = "2048 50000 47953" ]
}

@test "carve_layout lays two partitions into a gap, second takes the rest" {
    # 1G at 512b = 2097152 sectors, so the first runs 2048..2099199, and the
    # next 1MiB boundary after that is 2099200.
    run carve_layout 2048 10000000 1G rest
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "2048 2099199" ]
    [ "${lines[1]}" = "2099200 10000000" ]
}

@test "carve_layout gives rest the whole gap when it is the only entry" {
    run carve_layout 2048 999423 rest
    [ "$status" -eq 0 ]
    [ "$output" = "2048 999423" ]
}

@test "carve_layout refuses a 1G partition in a gap one MiB too small" {
    run carve_layout 2048 2097151 1G
    [ "$status" -ne 0 ]
}

@test "carve_layout rejects a plan larger than the gap" {
    run carve_layout 2048 999423 1G
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not fit"* ]]
}

@test "carve_layout rejects rest anywhere but last" {
    run carve_layout 2048 9999999 rest 1G
    [ "$status" -ne 0 ]
    [[ "$output" == *"only the last"* ]]
}

@test "carve_layout rejects a non-numeric gap bound instead of resolving it as a variable" {
    # gap_start="i" collides with carve_layout's own loop counter: unvalidated,
    # (( )) resolved it to that variable's value instead of failing.
    run carve_layout i 5000000 1G
    [ "$status" -ne 0 ]
}

@test "carve_layout rejects a gap bound that is an arithmetic expression" {
    # (( )) evaluates "2048+1" to 2049 while printf would emit the raw string,
    # so an unvalidated bound lets the printed range and the arithmetic used
    # to check it disagree about what the start or end actually was.
    run carve_layout "2048+1" 5000000 1G
    [ "$status" -ne 0 ]
}

@test "parse_part_numbers reads the numbers out of sgdisk -p" {
    run bash -c "$(declare -f parse_part_numbers); cat <<'SGDISK' | parse_part_numbers
Disk /dev/nvme0n1: 1953525168 sectors, 931.5 GiB
Number  Start (sector)    End (sector)  Size       Code  Name
   1              34           32767   16.0 MiB    0C01  Microsoft reserved partition
   2           32768      1024032767   488.3 GiB   0700  Basic data partition
SGDISK"
    [ "${lines[0]}" = "1" ]
    [ "${lines[1]}" = "2" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "lowest_free_number fills a hole in the numbering" {
    [ "$(lowest_free_number 1 2 4)" = "3" ]
}

@test "lowest_free_number starts at 1 on an empty table" {
    [ "$(lowest_free_number)" = "1" ]
}

@test "lowest_free_number appends after a contiguous run" {
    [ "$(lowest_free_number 1 2 3)" = "4" ]
}

@test "part_in_use is true for a mounted partition" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\nexit 0\n' > "${stub}/findmnt"
    chmod +x "${stub}/findmnt"
    PATH="${stub}:${PATH}" run part_in_use /dev/sdz1
    [ "$status" -eq 0 ]
}

@test "part_in_use is true for active swap" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\nexit 1\n' > "${stub}/findmnt"
    printf '#!/bin/bash\necho /dev/sdz1\n' > "${stub}/swapon"
    chmod +x "${stub}/findmnt" "${stub}/swapon"
    PATH="${stub}:${PATH}" run part_in_use /dev/sdz1
    [ "$status" -eq 0 ]
}

@test "part_in_use is false for an idle partition" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\nexit 1\n' > "${stub}/findmnt"
    printf '#!/bin/bash\ntrue\n' > "${stub}/swapon"
    chmod +x "${stub}/findmnt" "${stub}/swapon"
    PATH="${stub}:${PATH}" run part_in_use /dev/sdz1
    [ "$status" -ne 0 ]
}

@test "part_occupancy reports an encrypted container without mounting it" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho crypto_LUKS\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run part_occupancy /dev/sdz1
    [ "$output" = "encrypted" ]
}

@test "part_occupancy reports lvm, raid and swap members" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho LVM2_member\n' > "${stub}/lsblk"; chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run part_occupancy /dev/sdz1
    [ "$output" = "lvm" ]
    printf '#!/bin/bash\necho linux_raid_member\n' > "${stub}/lsblk"
    PATH="${stub}:${PATH}" run part_occupancy /dev/sdz1
    [ "$output" = "raid" ]
    printf '#!/bin/bash\necho swap\n' > "${stub}/lsblk"
    PATH="${stub}:${PATH}" run part_occupancy /dev/sdz1
    [ "$output" = "swap" ]
}

@test "part_occupancy says unknown when lsblk itself fails" {
    # Regression: lsblk failing and lsblk reporting no signature both produced
    # the empty string, which meant "unformatted", which safe_to_format accepts.
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\nexit 3\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run part_occupancy /dev/sdz1
    [ "$output" = "unknown" ]
}

@test "part_occupancy reports an unformatted partition" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run part_occupancy /dev/sdz1
    [ "$output" = "unformatted" ]
}

@test "part_occupancy passes a plain filesystem through with its type" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho ext4\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    PATH="${stub}:${PATH}" run part_occupancy /dev/sdz1
    [ "$output" = "fs:ext4" ]
}

@test "classify_mounted_tree reports a linux install by its os-release NAME" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/etc"
    printf 'NAME="Arch Linux"\nID=arch\n' > "${root}/etc/os-release"
    [ "$(classify_mounted_tree "$root")" = "linux:Arch Linux" ]
}

@test "classify_mounted_tree reports windows" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/Windows/System32"
    [ "$(classify_mounted_tree "$root")" = "windows" ]
}

@test "classify_mounted_tree reports an esp" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/EFI/BOOT"
    [ "$(classify_mounted_tree "$root")" = "esp" ]
}

@test "classify_mounted_tree reports an empty tree as empty" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "$root"
    [ "$(classify_mounted_tree "$root")" = "empty" ]
}

@test "classify_mounted_tree reports unrecognised content as data" {
    local root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${root}/photos"
    [ "$(classify_mounted_tree "$root")" = "data" ]
}

@test "part_probe_os probes a dirty xfs partition with norecovery, never a bare ro mount" {
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho xfs\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 1
MOUNT
    chmod +x "${stub}/mount"
    PATH="${stub}:${PATH}" run part_probe_os /dev/sdz1
    [ "$status" -eq 0 ]
    [ "$output" = "unmountable:xfs" ]
    grep -qF -- '-o ro,norecovery /dev/sdz1' "$log"
    ! grep -qE -- '-o ro /dev/sdz1' "$log"
}

@test "part_probe_os refuses an unrecognised filesystem instead of a bare ro mount" {
    local stub="${BATS_TEST_TMPDIR}/bin" log="${BATS_TEST_TMPDIR}/mount.log"
    mkdir -p "$stub"
    printf '#!/bin/bash\necho reiserfs\n' > "${stub}/lsblk"
    chmod +x "${stub}/lsblk"
    cat > "${stub}/mount" <<MOUNT
#!/bin/bash
echo "\$*" >> "${log}"
exit 0
MOUNT
    chmod +x "${stub}/mount"
    PATH="${stub}:${PATH}" run part_probe_os /dev/sdz1
    [ "$status" -eq 0 ]
    [ "$output" = "unmountable:reiserfs" ]
    # mount must never even be invoked for a type with no known-safe option --
    # not attempted-and-refused, simply not attempted.
    [ ! -e "$log" ]
}

@test "safe_to_format accepts only a provably empty partition" {
    run safe_to_format empty
    [ "$status" -eq 0 ]
    run safe_to_format unformatted
    [ "$status" -eq 0 ]
}

@test "safe_to_format refuses an encrypted container" {
    run safe_to_format encrypted
    [ "$status" -ne 0 ]
}

@test "safe_to_format refuses anything it could not identify" {
    run safe_to_format "unmountable:ext4"
    [ "$status" -ne 0 ]
    run safe_to_format unknown
    [ "$status" -ne 0 ]
    run safe_to_format data
    [ "$status" -ne 0 ]
}

@test "plan_add defaults source to new and start/end to empty" {
    plan_add /dev/sda efi ef00 EFI 1G
    [ "${PART_PLAN[0]}" = "/dev/sda|efi|ef00|EFI|1G|new||" ]
}

@test "plan_add records a reuse source" {
    plan_add /dev/sda efi ef00 EFI 1G /dev/sda1
    [ "${PART_PLAN[0]}" = "/dev/sda|efi|ef00|EFI|1G|/dev/sda1||" ]
}

@test "plan_add records carve sectors" {
    plan_add /dev/sda root 8300 Root rest new 2048 999423
    [ "${PART_PLAN[0]}" = "/dev/sda|root|8300|Root|rest|new|2048|999423" ]
}

@test "plan_add rejects a source that is neither new nor a device" {
    run plan_add /dev/sda efi ef00 EFI 1G sda1
    [ "$status" -ne 0 ]
}

@test "plan_has_role finds a planned role" {
    plan_add /dev/sda root 8300 Root rest
    run plan_has_role root
    [ "$status" -eq 0 ]
    run plan_has_role efi
    [ "$status" -ne 0 ]
}

@test "plan_execute wipes only when PLAN_WIPE_DISKS is true" {
    DRY_RUN=true
    PLAN_WIPE_DISKS=true
    plan_add /dev/sdz efi  ef00 EFI  1G
    plan_add /dev/sdz root 8300 Root rest
    run plan_execute
    [[ "$output" == *"sgdisk --zap-all /dev/sdz"* ]]
}

@test "plan_execute never wipes in carve mode" {
    DRY_RUN=true
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi  ef00 EFI 1G   new 2048 2099199
    plan_add /dev/sdz root 8300 Root rest new 2099200 9999999
    run plan_execute
    [ "$status" -eq 0 ]
    [[ "$output" != *"--zap-all"* ]]
}

@test "plan_execute carves at the planned sectors" {
    DRY_RUN=true
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi ef00 EFI 1G new 2048 2099199
    run plan_execute
    [[ "$output" == *":2048:2099199"* ]]
}

@test "plan_execute issues no sgdisk at all for a reused partition" {
    DRY_RUN=true
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi ef00 EFI 1G /dev/sdz5
    run plan_execute
    [ "$status" -eq 0 ]
    [[ "$output" != *"sgdisk"* ]]
}

@test "plan_execute assigns role globals from a reused partition" {
    DRY_RUN=true
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi  ef00 EFI  1G   /dev/sdz5
    plan_add /dev/sdz root 8300 Root rest /dev/sdz7
    plan_execute
    [ "$PART_EFI" = "/dev/sdz5" ]
    [ "$PART_ROOT_RAW" = "/dev/sdz7" ]
}

# Regression: n was initialised only inside the wipe branch, so the
# sizeless-new path in carve mode reached `n=$(( n + 1 ))` with n never
# assigned and died with "n: unbound variable".
#
# Run in its own `set -euo pipefail` shell, not called directly: bats does not
# set -u in the test shell, and install.sh -- the only caller that matters --
# does. Called directly this case passes with the bug reintroduced, which is
# how it was written first and why it is written this way now.
@test "plan_execute does not abort on a sizeless new entry in carve mode" {
    run bash -c "
        set -euo pipefail
        source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
        source '${BATS_TEST_DIRNAME}/../lib/disk.sh'
        DRY_RUN=true
        PLAN_WIPE_DISKS=false
        plan_reset
        plan_add /dev/sdz root 8300 Root 1G
        plan_execute
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"unbound variable"* ]]
}

@test "plan_execute issues no partprobe for a reuse-only plan" {
    # partprobe re-reads the partition table it was just told not to touch.
    # Harmless in isolation, but it is the one command in the reuse path that
    # would still reach a disk this mode promised to leave alone.
    DRY_RUN=true
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi  ef00 EFI  1G   /dev/sdz5
    plan_add /dev/sdz root 8300 Root rest /dev/sdz7
    run plan_execute
    [ "$status" -eq 0 ]
    [[ "$output" != *"partprobe"* ]]
}

@test "plan_render shows the device a reused partition will be adopted from" {
    # This string is what the operator reads immediately before typing YES, so
    # it has to name the partition that is actually being taken over.
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi ef00 EFI 1G /dev/sdz5
    run plan_render
    [ "$status" -eq 0 ]
    [[ "$output" == *"/dev/sdz5"* ]]
    [[ "$output" == *"reuse"* ]]
}

@test "plan_reset clears the wipe flag, not just the entries" {
    # A mode selector lets an operator choose whole-disk, back out, and choose
    # custom; a flag left standing from the first choice wipes the disk the
    # second was picked to preserve.
    PLAN_WIPE_DISKS=true
    plan_add /dev/sdz root 8300 Root rest
    plan_reset
    [ "$PLAN_WIPE_DISKS" = false ]
}

@test "plan_render marks a carve plan as preserving the disk" {
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz root 8300 Root rest new 2048 999423
    run plan_render
    [[ "$output" != *"WILL BE WIPED"* ]]
    [[ "$output" == *"WILL BE PRESERVED"* ]]
}

@test "plan_render still names devices in whole-disk mode" {
    PLAN_WIPE_DISKS=true
    plan_add /dev/nvme0n1 efi  ef00 EFI  1G
    plan_add /dev/nvme0n1 root 8300 Root rest
    run plan_render
    [[ "$output" == *"/dev/nvme0n1p1"* ]]
    [[ "$output" == *"/dev/nvme0n1p2"* ]]
    [[ "$output" == *"WILL BE WIPED"* ]]
}
