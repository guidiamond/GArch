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

# `ask` has two branches and the test above only covers the no-default one.
# The defaulted branch is what every phase-2 prompt uses, and it is the one
# with an obvious-looking "simplification": it HAS a default, so why not just
# return it at EOF? Because that is what made the re-ask loops spin, and
# because it is what keeps a closed stdin from ever reaching a confirm_step or
# the encrypt prompt -- both of which answer yes at EOF by design.
@test "ask fails at EOF even when it has a default" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; ask 'Keymap' 'us'" </dev/null
    [ "$status" -ne 0 ]
    # The default must not be echoed as though it had been chosen. `read -rp`
    # writes no prompt when stdin is not a terminal, and stdin here is
    # /dev/null regardless of whether the suite itself runs under a pty, so
    # the only way "us" appears is if ask returned it.
    [[ "$output" != *"us"* ]]
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

# --- ask_choice ------------------------------------------------------------
#
# Every case here discards stderr, so `$output` is stdout alone. That is the
# assertion, not a tidy-up: phase 3 calls this as `mode=$(ask_choice ...)`, so
# anything the function writes to stdout other than the chosen option ends up
# in $mode, matches no case arm, and aborts the phase.

@test "ask_choice returns the chosen option verbatim" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; echo 2 | ask_choice 'pick' 'alpha' 'beta' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "beta" ]
}

# Exact equality, not a substring: the retry message must not reach stdout
# either. lib/ui.sh's warn has no >&2 of its own.
@test "ask_choice re-asks on an out-of-range answer without polluting stdout" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; printf '9\n1\n' | ask_choice 'pick' 'alpha' 'beta' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "alpha" ]
}

@test "ask_choice re-asks on a non-numeric answer" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; printf 'beta\n2\n' | ask_choice 'pick' 'alpha' 'beta' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "beta" ]
}

# A leading zero is a number an operator can type. Read in bash's default base
# it is octal, and "08" aborts the arithmetic outright ("value too great for
# base") instead of selecting anything.
@test "ask_choice reads a padded number in base 10" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; echo 08 | ask_choice 'pick' a b c d e f g h 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "h" ]
}

# Arithmetic on an unbounded digit run wraps at 64 bits, so 18446744073709551617
# evaluates to 1 and would silently select the first option. The digit count is
# what makes that unreachable.
@test "ask_choice does not let a wrapped integer select an option" {
    run timeout 5 bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; printf '18446744073709551617\n2\n' | ask_choice 'pick' 'alpha' 'beta' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "beta" ]
}

# The reason this is a bare read and not ask_yes_no: it runs in front of the
# disk prompts, and a closed stdin must not select option 1 -- which on this
# menu is the whole-disk wipe.
@test "ask_choice fails closed on EOF" {
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; ask_choice 'pick' 'alpha' 'beta' < /dev/null"
    [ "$status" -ne 0 ]
    # Proves the function ran, rather than exiting 127 for not existing.
    # stderr is deliberately not discarded here, so the menu is in $output too.
    [[ "$output" == *"end of input"* ]]
}

# Called with no options, every reply is out of range, so the loop would spin
# on stdin forever -- swallowing the answers to every prompt after it -- until
# EOF. A caller bug, but one that costs the operator their input.
@test "ask_choice refuses to offer an empty menu" {
    run timeout 5 bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'; ask_choice 'pick'"
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [[ "$output" == *"at least one option"* ]]
}
