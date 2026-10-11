#!/usr/bin/env bats
#
# test/vm.sh is the one script here that runs on the host, and the one nothing
# in this suite has ever executed end to end -- a real run needs qemu, OVMF,
# guestfish and an Arch ISO. What CAN be tested without any of that is the
# argument handling and the tool gating around the destructive parts: the
# points where a mistake costs the operator a half-made image or a scenario
# that silently seeded nothing.
#
# Every case below sources vm.sh into a subshell with VM_DIR pointed at a
# temp directory, and replaces `command` -- which `need` calls -- so that a
# tool can be made present or absent without touching PATH. Nothing here runs
# qemu, guestfish or qemu-img: they are gated by `need`, and `need` is what is
# under test.

setup() {
    VM_SH="${BATS_TEST_DIRNAME}/vm.sh"
    TMP="$BATS_TEST_TMPDIR"
}

# `command` is a builtin, and a function of the same name shadows it for
# `need`'s `command -v "$1"` without changing PATH for anything else. The
# listed tools are answered from the argument alone, so a case can say "this
# host has qemu-img but no guestfish" whatever the host actually has -- these
# tests must give the same answer on a machine with libguestfs installed and
# on one without.
tool_stub() {
    local missing=$1
    printf '%s' "
        command() {
            case \"\$2\" in
                ${missing}) return 1 ;;
                qemu-img|qemu-system-x86_64|guestfish) return 0 ;;
            esac
            builtin command \"\$@\"
        }"
}

in_vm() {
    run env VM_DIR="$TMP" bash -c "source '${VM_SH}'; $*"
}

# --- guestfish gating -------------------------------------------------------

# Ungated, `qemu-img create` runs first and guestfish then dies with a bare
# "command not found" under set -e, leaving a $DISK that `create` refuses to
# overwrite on the next run.
@test "create --scenario refuses a host without guestfish, before writing anything" {
    in_vm "$(tool_stub guestfish)
        cmd_create --scenario coexist"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing: guestfish"* ]]
    [ ! -e "${TMP}/disk.qcow2" ]
}

# The control for the case above: the same harness with guestfish present gets
# past the gate. Without it, a harness that had stopped reaching cmd_create at
# all would report "missing: guestfish" for the wrong reason -- or stop
# reporting it and look like a regression that is not there.
@test "create --scenario gets past the tool gate when guestfish is present" {
    in_vm "$(tool_stub none)
        require_space() { :; }
        seed_coexist_disk() { echo SEEDED; }
        OVMF_CODE=${TMP}/code.fd; OVMF_VARS_SRC=${TMP}/vars.fd
        : > \$OVMF_CODE; : > \$OVMF_VARS_SRC
        cmd_create --scenario coexist"
    [ "$status" -eq 0 ]
    [[ "$output" != *"missing:"* ]]
    [[ "$output" == *"SEEDED"* ]]
}

@test "verify --scenario refuses a host without guestfish" {
    : > "${TMP}/disk.qcow2"
    in_vm "$(tool_stub guestfish)
        assert_coexist() { echo ASSERTED; }
        cmd_verify --scenario coexist"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing: guestfish"* ]]
    [[ "$output" != *"ASSERTED"* ]]
}

@test "verify --scenario reaches its assertions when guestfish is present" {
    : > "${TMP}/disk.qcow2"
    in_vm "$(tool_stub none)
        assert_coexist() { echo ASSERTED; }
        cmd_verify --scenario coexist"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ASSERTED"* ]]
}

# --- reset ------------------------------------------------------------------

# A bare `cmd_create` here rebuilt a blank image after `create --scenario
# coexist` and said nothing about it, so the next `boot` installed onto a disk
# with no neighbour on it and the scenario tested nothing it claims to test.
@test "reset forwards the scenario to create" {
    : > "${TMP}/disk.qcow2"
    in_vm "$(tool_stub none)
        create_preflight() { :; }
        reclaimable_mib() { echo 0; }
        cmd_create() { echo \"CREATE[\$*]\"; }
        cmd_reset --scenario coexist"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CREATE[--scenario coexist]"* ]]
}

# The control: a plain reset must still rebuild a plain image, not acquire a
# scenario from somewhere.
@test "reset without a scenario forwards nothing" {
    : > "${TMP}/disk.qcow2"
    in_vm "$(tool_stub none)
        create_preflight() { :; }
        reclaimable_mib() { echo 0; }
        cmd_create() { echo \"CREATE[\$*]\"; }
        cmd_reset"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CREATE[]"* ]]
}

# Validated before the rm, not after: cmd_create sees these arguments only
# once the image is gone, so a typo would destroy a seeded disk and only then
# report that the name meant nothing.
@test "reset rejects an unknown scenario without deleting the image" {
    : > "${TMP}/disk.qcow2"
    in_vm "$(tool_stub none)
        create_preflight() { :; }
        reclaimable_mib() { echo 0; }
        cmd_create() { echo \"CREATE[\$*]\"; }
        cmd_reset --scenario coexits"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown scenario 'coexits'"* ]]
    [[ "$output" != *"CREATE["* ]]
    [ -e "${TMP}/disk.qcow2" ]
}

@test "reset rejects a bare trailing --scenario without deleting the image" {
    : > "${TMP}/disk.qcow2"
    in_vm "$(tool_stub none)
        create_preflight() { :; }
        reclaimable_mib() { echo 0; }
        cmd_create() { echo \"CREATE[\$*]\"; }
        cmd_reset --scenario"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--scenario requires an argument"* ]]
    [ -e "${TMP}/disk.qcow2" ]
}

@test "main hands reset its arguments" {
    in_vm "cmd_reset() { echo \"RESET[\$*]\"; }
        main reset --scenario coexist"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESET[--scenario coexist]"* ]]
}

# --- usage ------------------------------------------------------------------

# The fixture makes a vfat ESP and an ext4 root and no NTFS at all, and the
# usage text said otherwise -- an operator reading it would look for a Windows
# partition that the scenario never creates.
@test "the coexist usage text describes the fixture seed_coexist_disk builds" {
    run bash -c "source '${VM_SH}'; usage"
    [ "$status" -eq 0 ]
    [[ "$output" != *"NTFS"* ]]
    [[ "$output" == *"ESP"* ]]
    # The control: the mkfs lines the text has to agree with.
    run grep -A4 'part-init /dev/sda gpt' "$VM_SH"
    [[ "$output" == *"mkfs vfat /dev/sda1"* ]]
    [[ "$output" == *"mkfs ext4 /dev/sda2"* ]]
    [[ "$output" != *"ntfs"* ]]
}
