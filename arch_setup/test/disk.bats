#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/disk.sh"
    plan_reset
    PLAN_WIPE_DISKS=true
    # Defaulted here, not left to each case: a plan_execute test that forgets
    # its own DRY_RUN line runs sgdisk, mkfs and mount against this machine.
    DRY_RUN=true
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

# next_part_number refuses a disk whose partition table it cannot read, so a
# --dry-run plan_execute case against a device that does not exist has to
# stand in for that one read. Empty output is an empty table, which is what
# these cases assumed all along -- they were previously getting that answer
# from real sgdisk failing on /dev/sdz and next_part_number failing open.
stub_empty_table() {
    sgdisk() { [[ "$1" == "-p" ]] && return 0; printf 'sgdisk %s\n' "$*"; }
}

@test "plan_execute never wipes in carve mode" {
    DRY_RUN=true
    PLAN_WIPE_DISKS=false
    stub_empty_table
    plan_add /dev/sdz efi  ef00 EFI 1G   new 2048 2099199
    plan_add /dev/sdz root 8300 Root rest new 2099200 9999999
    run plan_execute
    [ "$status" -eq 0 ]
    [[ "$output" != *"--zap-all"* ]]
}

@test "plan_execute carves at the planned sectors" {
    DRY_RUN=true
    PLAN_WIPE_DISKS=false
    stub_empty_table
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

# A sizeless new entry lets sgdisk place the partition from sector 0 at the
# lowest free number, which is only meaningful on a table that was just zapped.
# In preserve mode it must be refused, not created: on a live table
# `sgdisk -n 1:0:+1G` overwrites partition 1.
#
# It must be refused *cleanly*, which is the second half of this case. The
# branch that reaches it does `seq_n=$(( seq_n + 1 ))`, and with the counter
# initialised only inside the wipe branch that was an abort on an unset
# variable rather than a diagnosis. So this runs in its own `set -euo pipefail`
# shell: bats does not set -u in the test shell and install.sh does, and called
# directly this case passed with that bug reintroduced.
@test "plan_execute refuses a sizeless new entry on a disk it is not wiping" {
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
    [ "$status" -ne 0 ]
    [[ "$output" != *"unbound variable"* ]]
    # Not matched on "sgdisk": the refusal names it. run_cmd prefixes every
    # command it issues under DRY_RUN, so its absence is the real proof that
    # nothing was issued.
    [[ "$output" != *"dry-run"* ]]
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

@test "plan_execute refuses to wipe a disk the plan also reuses a partition on" {
    # PLAN_WIPE_DISKS is one flag for a plan whose entries are per-disk, so
    # this combination zapped the very disk holding the partition being
    # adopted -- under a banner reading WILL BE WIPED directly above a row
    # reading (reuse).
    PLAN_WIPE_DISKS=true
    plan_add /dev/sdz efi  ef00 EFI  1G
    plan_add /dev/sdy root 8300 Root rest /dev/sdy3
    run plan_execute
    [ "$status" -ne 0 ]
    # Refused before anything was issued, not partway through: /dev/sdz is
    # rendered first, so a per-disk check would already have zapped it.
    [[ "$output" != *"--zap-all"* ]]
}

@test "plan_execute refuses to wipe a disk the plan carves into" {
    # A carve entry's sectors were chosen to fit around what is already on that
    # disk, so zapping it invalidates them exactly as it invalidates a reused
    # partition. With the flag left true from a whole-disk choice on another
    # disk, this zapped the carve target and then reported success.
    PLAN_WIPE_DISKS=true
    plan_add /dev/sdz efi  ef00 EFI  1G
    plan_add /dev/sdy root 8300 Root rest new 2099200 9999999
    run plan_execute
    [ "$status" -ne 0 ]
    [[ "$output" != *"dry-run"* ]]
}

@test "plan_render does not number an all-sequential plan on a disk it is not wiping" {
    # The one shape that separates "predictable" from PLAN_WIPE_DISKS itself.
    # plan_execute refuses this plan, so nothing is written wrongly -- but
    # plan_render runs before that refusal, and printing /dev/sdz1 here puts a
    # fabricated device name on the confirmation screen.
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi  ef00 EFI  1G
    plan_add /dev/sdz root 8300 Root rest
    run plan_render
    [ "$status" -eq 0 ]
    [[ "$output" != *"/dev/sdz1"* ]]
    [[ "$output" == *"assigned at write time"* ]]
}

@test "plan_execute refuses a disk that mixes placed and sector-addressed partitions" {
    # Sequential entries are numbered 1,2,3... from a freshly zapped table;
    # carved and reused ones take their number from the live table. On one disk
    # the two schemes race: both of these were issued as `sgdisk -n 1:`, the
    # second overwriting the first. Sharing one counter instead only moved the
    # damage into plan_render, whose column then disagreed with what was made.
    PLAN_WIPE_DISKS=true
    plan_add /dev/sdz efi  ef00 EFI  1G  new 2048 2099199
    plan_add /dev/sdz root 8300 Root 20G
    run plan_execute
    [ "$status" -ne 0 ]
    [[ "$output" != *"dry-run"* ]]
}

@test "plan_execute still carves several partitions into one disk" {
    # The counterpart to the case above: refusing the mix must not refuse a
    # plan that is carved throughout, which is what custom mode produces.
    PLAN_WIPE_DISKS=false
    stub_empty_table
    plan_add /dev/sdz efi  ef00 EFI  1G   new 2048 2099199
    plan_add /dev/sdz root 8300 Root rest new 2099200 9999999
    run plan_execute
    [ "$status" -eq 0 ]
    [[ "$output" == *":2048:2099199"* ]]
    [[ "$output" == *":2099200:9999999"* ]]
}

@test "plan_execute still allows reusing one partition and carving another" {
    # Reuse the ESP, carve the root -- the shape this whole feature exists for.
    PLAN_WIPE_DISKS=false
    stub_empty_table
    plan_add /dev/sdz efi  ef00 EFI  1G   /dev/sdz5
    plan_add /dev/sdz root 8300 Root rest new 2099200 9999999
    run plan_execute
    [ "$status" -eq 0 ]
    [[ "$output" == *":2099200:9999999"* ]]
}

@test "plan_render does not invent a device number it cannot predict" {
    # Mixed plans are numbered from the live table by next_part_number, which
    # plan_render cannot see. Guessing here names a device on the screen the
    # operator reads immediately before typing YES.
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi  ef00 EFI  1G /dev/sdz5
    plan_add /dev/sdz root 8300 Root 20G
    run plan_render
    [ "$status" -eq 0 ]
    [[ "$output" != *"/dev/sdz1"* ]]
    [[ "$output" == *"assigned at write time"* ]]
}

@test "plan_execute stops when sgdisk fails instead of reporting success" {
    # Measured with a failing first sgdisk: the second carve entry got the same
    # partition number, because the first write never landed, and plan_execute
    # still printed Partitioned and returned 0. install.sh's set -e covered
    # this; plan_execute should not need its caller to.
    DRY_RUN=false
    PLAN_WIPE_DISKS=true
    sgdisk() { return 1; }
    partprobe() { :; }
    plan_add /dev/sdz efi ef00 EFI 1G
    run plan_execute
    [ "$status" -ne 0 ]
    [[ "$output" != *"Partitioned /dev/sdz"* ]]
}

@test "plan_add refuses the entry separator in a field" {
    # Fields are joined and split on '|', so a '|' does not corrupt its own
    # field -- it forges every field after it. This payload turned a reuse
    # entry into a carve entry that ran sgdisk in preserve mode.
    run plan_add /dev/sdz root 8300 Root '1|new|2048|999423' /dev/sdz7
    [ "$status" -ne 0 ]
    run plan_add /dev/sdz root 8300 'Ro|ot' rest
    [ "$status" -ne 0 ]
    [ "${#PART_PLAN[@]}" -eq 0 ]
}

@test "plan_add refuses a newline in a field" {
    # A newline truncated the entry into a reuse of the empty device, setting
    # PART_ROOT_RAW="" -- the mkfs.fat "" failure plan_has_role exists to stop.
    run plan_add /dev/sdz root 8300 "$(printf 'Ro\not')" rest
    [ "$status" -ne 0 ]
    [ "${#PART_PLAN[@]}" -eq 0 ]
}

@test "plan_add refuses an empty label" {
    run plan_add /dev/sdz root 8300 "" rest
    [ "$status" -ne 0 ]
}

@test "plan_add refuses a source that is not a partition of this entry's disk" {
    # The whole disk: btrfs_create_subvols would later mkfs it, destroying
    # every partition on it.
    run plan_add /dev/sdz root 8300 Root rest /dev/sdz
    [ "$status" -ne 0 ]
    # A partition of a different disk: plan_render filed it under /dev/sdz's
    # banner and never named /dev/sdy as touched at all.
    run plan_add /dev/sdz root 8300 Root rest /dev/sdy3
    [ "$status" -ne 0 ]
    run plan_add /dev/sdz root 8300 Root rest /dev/
    [ "$status" -ne 0 ]
    run plan_add /dev/sdz root 8300 Root rest /dev/../etc/passwd
    [ "$status" -ne 0 ]
    [ "${#PART_PLAN[@]}" -eq 0 ]
}

@test "plan_add accepts a partition of an nvme disk, suffix and all" {
    # The counterpart to the case above: the check is built with part_suffix,
    # so it has to keep accepting the naming convention it encodes.
    plan_add /dev/nvme0n1 efi ef00 EFI 1G /dev/nvme0n1p5
    [ "${PART_PLAN[0]}" = "/dev/nvme0n1|efi|ef00|EFI|1G|/dev/nvme0n1p5||" ]
}

@test "plan_add refuses half a carve range" {
    run plan_add /dev/sdz root 8300 Root 1G new "" 999423
    [ "$status" -ne 0 ]
    run plan_add /dev/sdz root 8300 Root 1G new 2048 ""
    [ "$status" -ne 0 ]
    [ "${#PART_PLAN[@]}" -eq 0 ]
}

@test "plan_add refuses carve sectors that are not plain integers" {
    # Unvalidated, these reached sgdisk verbatim as `-n 1:abc:def`.
    run plan_add /dev/sdz root 8300 Root rest new abc def
    [ "$status" -ne 0 ]
    run plan_add /dev/sdz root 8300 Root rest new 2048 '$(id)'
    [ "$status" -ne 0 ]
    [ "${#PART_PLAN[@]}" -eq 0 ]
}

@test "plan_add refuses a carve range that does not run forwards" {
    run plan_add /dev/sdz root 8300 Root rest new 999423 2048
    [ "$status" -ne 0 ]
}

@test "plan_add refuses a reuse entry that also carves sectors" {
    # Two contradictory requests; silently dropping one picks for the operator.
    run plan_add /dev/sdz root 8300 Root rest /dev/sdz7 2048 999423
    [ "$status" -ne 0 ]
}

@test "plan_add reports its own error on a short call" {
    # Without an arity check this died on a raw "$5: unbound variable" from
    # bash, naming nothing the caller could act on. Run under set -u for the
    # same reason as the sizeless-new case above: bats does not set it and
    # install.sh does, and called directly this passes either way, because an
    # unset $5 without set -u is just an empty size.
    run bash -c "
        set -euo pipefail
        source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
        source '${BATS_TEST_DIRNAME}/../lib/disk.sh'
        plan_reset
        plan_add /dev/sdz efi ef00 EFI
    "
    [ "$status" -ne 0 ]
    [[ "$output" != *"unbound variable"* ]]
    [[ "$output" == *"5 to 8 arguments"* ]]
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

# --- carve numbering ---------------------------------------------------------
#
# Under --dry-run nothing is created, so next_part_number read the same live
# table for every carve entry on a disk and answered the same number twice: the
# rehearsal printed `sgdisk -n 3:...` for both the ESP and the root, and then
# mkfs.fat and cryptsetup luksFormat both against /dev/nvme0n1p3. Correct on a
# real run, but it makes a rehearsal transcript useless for checking device
# names.
#
# The whole hazard of fixing it is double-counting on a REAL run, where sgdisk
# has already written each partition and the live table therefore already
# reflects it. The two cases below are a matched pair: same plan, same
# assertions about which numbers come out, one with a table that grows as
# partitions are created and one with a table that never does.

# sgdisk_table_stub <dir> <initial numbers...>
#
# A stub sgdisk that keeps a partition table in a file: `-p` prints it in the
# shape parse_part_numbers reads, and `-n N:start:end` appends N to it, which
# is what the real tool's effect on the table amounts to here. Anything not
# naming /dev/sdz exits 99, so a stub that stopped covering a call site cannot
# quietly reach the real tool.
sgdisk_table_stub() {
    local dir=$1; shift
    SGDISK_TABLE="${BATS_TEST_TMPDIR}/table"
    mkdir -p "$dir"
    printf '%s\n' "$@" > "$SGDISK_TABLE"
    cat > "${dir}/sgdisk" <<SG
#!/bin/bash
[[ "\$*" == *"/dev/sdz"* ]] || { echo "sgdisk stub: refusing \$*" >&2; exit 99; }
if [[ "\$1" == "-p" ]]; then
    echo "Number  Start (sector)    End (sector)  Size       Code  Name"
    while read -r n; do
        [[ -n "\$n" ]] && echo "   \$n            2048            4096   1.0 MiB     8300  x"
    done < '${SGDISK_TABLE}'
    exit 0
fi
[[ "\$1" == "-n" ]] && echo "\${2%%:*}" >> '${SGDISK_TABLE}'
exit 0
SG
    printf '#!/bin/bash\nexit 0\n' > "${dir}/partprobe"
    chmod +x "${dir}/sgdisk" "${dir}/partprobe"
}

@test "next_part_number skips the numbers its caller has reserved" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    sgdisk_table_stub "$stub" 1 2
    local PATH="${stub}:${PATH}"
    [ "$(next_part_number /dev/sdz)" = "3" ]
    [ "$(next_part_number /dev/sdz 3)" = "4" ]
    [ "$(next_part_number /dev/sdz 3 4)" = "5" ]
    # A reserved number the table already holds changes nothing.
    [ "$(next_part_number /dev/sdz 1)" = "3" ]
}

@test "plan_execute numbers each carved partition once on a real run" {
    # DRY_RUN=false on purpose, which is why every tool this reaches is stubbed
    # and the stub refuses any device but /dev/sdz -- which does not exist.
    local stub="${BATS_TEST_TMPDIR}/bin"
    sgdisk_table_stub "$stub" 1 2
    DRY_RUN=false
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi  ef00 EFI  1G   new 2048 2099199
    plan_add /dev/sdz root 8300 Root rest new 2099200 9999999
    local PATH="${stub}:${PATH}"
    plan_execute
    # 3 then 4, from the table alone: the reservation list must be empty here,
    # or the second entry would come out 5 and the real run would leave a hole.
    [ "$(tr '\n' ' ' < "$SGDISK_TABLE")" = "1 2 3 4 " ]
    [ "$PART_EFI" = "/dev/sdz3" ]
    [ "$PART_ROOT_RAW" = "/dev/sdz4" ]
}

@test "plan_execute numbers a dry run the way that real run would" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    sgdisk_table_stub "$stub" 1 2
    DRY_RUN=true
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz efi  ef00 EFI  1G   new 2048 2099199
    plan_add /dev/sdz root 8300 Root rest new 2099200 9999999
    local PATH="${stub}:${PATH}"
    run plan_execute
    [ "$status" -eq 0 ]
    [[ "$output" == *"sgdisk -n 3:2048:2099199"* ]]
    [[ "$output" == *"sgdisk -n 4:2099200:9999999"* ]]
    # Nothing was created, and the table proves it: the numbers above came from
    # the reservation list, not from a write that leaked through run_cmd.
    [ "$(tr '\n' ' ' < "$SGDISK_TABLE")" = "1 2 " ]
}

@test "plan_execute counts reservations per disk, not across the whole plan" {
    # The reservation list is reset for each disk. Shared across disks, the
    # first carve on the second disk would be numbered as though the first
    # disk's partitions were on it.
    local stub="${BATS_TEST_TMPDIR}/bin"
    sgdisk_table_stub "$stub" 1 2
    # The stub answers for both disks; only /dev/sdz is refused-proofed, so
    # /dev/sdzz is used as the second disk to stay inside that guard.
    DRY_RUN=true
    PLAN_WIPE_DISKS=false
    plan_add /dev/sdz  efi  ef00 EFI  1G   new 2048 2099199
    plan_add /dev/sdz  root 8300 Root rest new 2099200 9999999
    plan_add /dev/sdzz root 8300 Data rest new 2048 9999999
    local PATH="${stub}:${PATH}"
    run plan_execute
    [ "$status" -eq 0 ]
    [[ "$output" == *"sgdisk -n 3:2048:2099199 "* ]]
    [[ "$output" == *"sgdisk -n 4:2099200:9999999"* ]]
    # Third partition, first on its own disk: 3 again, not 5.
    [[ "$output" == *"sgdisk -n 3:2048:9999999"* ]]
}

# The reservation is appended by `[[ "$DRY_RUN" == true ]] && dry_reserved+=(…)`,
# and a failing left-hand side of an AND-list is the classic way a line that is
# green in bats -- which runs with errexit off -- aborts the installer, which
# does not. The real-run path is the one where that test is false on every
# entry.
@test "plan_execute's carve path survives install.sh's set -euo pipefail" {
    local stub="${BATS_TEST_TMPDIR}/bin"
    sgdisk_table_stub "$stub" 1 2
    run env "PATH=${stub}:${PATH}" bash -c "set -euo pipefail
source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
source '${BATS_TEST_DIRNAME}/../lib/disk.sh'
plan_reset
PLAN_WIPE_DISKS=false
DRY_RUN=false
plan_add /dev/sdz efi  ef00 EFI  1G   new 2048 2099199
plan_add /dev/sdz root 8300 Root rest new 2099200 9999999
plan_execute
echo SURVIVED"
    [ "$status" -eq 0 ]
    [[ "$output" == *SURVIVED* ]]
    [ "$(tr '\n' ' ' < "$SGDISK_TABLE")" = "1 2 3 4 " ]
}

@test "next_part_number fails when the partition table cannot be read" {
    # The failure this guards: a process substitution's exit status is not
    # observable, so a failing `sgdisk -p` used to leave `used` empty and
    # lowest_free_number answered 1 with success -- and plan_execute would
    # then run `sgdisk -n 1:...` over whatever already holds number 1.
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/bash\nexit 1\n' > "${stub}/sgdisk"
    chmod +x "${stub}/sgdisk"
    PATH="${stub}:${PATH}" run next_part_number /dev/sdz
    [ "$status" -eq 1 ]
    # Not just non-zero: 127 from an undefined function satisfies that too.
    [[ "$output" == *"Could not read the partition table on /dev/sdz"* ]]
}

@test "next_part_number still answers from a table it could read" {
    # Control for the refusal above: proves the guard is reading sgdisk's
    # status and not refusing unconditionally.
    local stub="${BATS_TEST_TMPDIR}/bin"
    sgdisk_table_stub "$stub" 1 2
    local PATH="${stub}:${PATH}"
    run next_part_number /dev/sdz
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}
