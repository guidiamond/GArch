#!/usr/bin/env bats

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    source "${LIB}/ui.sh"
}

@test "sourcing ui.sh produces no output" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "ask returns the default when input is empty" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; echo '' | ask 'Name' 'fallback'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fallback"* ]]
}

@test "ask returns typed input over the default" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; echo 'typed' | ask 'Name' 'fallback'"
    [[ "$output" == *"typed"* ]]
    [[ "$output" != *"fallback"* ]]
}

@test "ask_yes_no accepts y" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; echo 'y' | ask_yes_no 'ok?'"
    [ "$status" -eq 0 ]
}

@test "ask_yes_no accepts n" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; echo 'n' | ask_yes_no 'ok?'"
    [ "$status" -eq 1 ]
}

@test "ask_yes_no uses the default on empty input" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; echo '' | ask_yes_no 'ok?' 'n'"
    [ "$status" -eq 1 ]
}

@test "die exits non-zero and writes to stderr" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; die 'boom'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"boom"* ]]
}
