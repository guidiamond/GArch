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

# install.sh wraps `ask` in "ask, validate, re-ask" loops. When `ask` handed
# back the default at EOF those loops spun forever on a closed stdin -- the
# disk prompt has no default, so it re-asked for a block device nobody could
# type. `timeout` is the assertion: a regression here does not fail, it hangs.
#
# `set -euo pipefail` is install.sh's own line and it is load-bearing, not
# decoration: `ask` returning non-zero only stops the loop because errexit
# turns the failed `d=$(ask ...)` into an exit. Without it this still hangs,
# which is also why it cannot be written as `run ask` -- bats' `run` disables
# errexit inside the run.
@test "ask fails at EOF instead of looping forever" {
    run timeout 5 bash -c "
        set -euo pipefail
        source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
        while true; do d=\$(ask 'Disk'); [[ -b \"\$d\" ]] && break; warn 'no'; done
    " </dev/null
    [ "$status" -ne 124 ]
    [ "$status" -ne 0 ]
    [[ "$output" == *"end of input"* ]]
}

# Same loop, no default to fall back on at all: verified to exit 124 before
# this fix. install.sh calls ask_password three times.
@test "ask_password fails at EOF instead of looping forever" {
    run timeout 5 bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; ask_password OUT" </dev/null
    [ "$status" -ne 124 ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"end of input"* ]]
}

# The EOF fix routes both password reads through one helper, and the helper has
# to pass -s through, or the root and LUKS passwords are echoed to the console.
#
# Asserted on the source, not the behaviour, because the behaviour cannot be
# observed here: echo is the terminal's, so it never reaches captured output,
# and `script -qec` with piped stdin was measured to produce byte-identical
# output with and without -s. A behavioural version of this test passes
# whether or not -s is there, which is worse than no test. This one fails when
# -s is dropped, which is the whole regression.
@test "ask_password reads with echo off" {
    local ui="${BATS_TEST_DIRNAME}/../lib/ui.sh"
    # Both password reads ask for silence...
    [ "$(grep -cE '_ask_read _ap_pass[12] .* --silent' "$ui")" -eq 2 ]
    # ...and the silent branch is the only one that uses -s, so a caller that
    # forgets --silent cannot get it by accident either.
    [ "$(grep -cE '^[[:space:]]*read -rsp' "$ui")" -eq 1 ]
    # The value still survives the round trip.
    run bash -c "source '${ui}'
                 ask_password OUT <<< \$'hunter2\nhunter2'
                 printf 'GOT[%s]' \"\$OUT\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"GOT[hunter2]"* ]]
}

# EOF and "a last line with no trailing newline" both make `read` return
# non-zero. Only the first is EOF; treating the second as EOF would reject the
# final answer of any here-string or piped input.
@test "ask accepts a final line with no trailing newline" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; printf 'sda' | ask 'Disk'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sda"* ]]
}
