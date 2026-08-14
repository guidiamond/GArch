#!/usr/bin/env bats
#
# Tests for the shared assertions themselves. A test helper that cannot fail
# is worse than no helper: it reports green forever and nobody looks again.

load helpers

setup() {
    TMP="$BATS_TEST_TMPDIR"
    printf 'first line\nsecond line has a needle\nthird line\n' > "$TMP/hay"
}

@test "assert_absent passes when the pattern is absent" {
    run assert_absent 'haystack' "$TMP/hay"
    [ "$status" -eq 0 ]
}

# The normal path runs grep to a status of 1, which aborts the function under
# the caller's errexit unless the status is captured with `|| rc=$?`.
@test "assert_absent passing does not abort its caller under errexit" {
    run bash -c "set -euo pipefail
        $(declare -f assert_absent)
        assert_absent 'haystack' '$TMP/hay'
        echo REACHED"
    [ "$status" -eq 0 ]
    [ "$output" = "REACHED" ]
}

@test "assert_absent fails and names the line when the pattern is present" {
    run assert_absent 'needle' "$TMP/hay"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpectedly found"* ]]
    [[ "$output" == *"2:second line has a needle"* ]]
}

# grep exits 2 here. Read as a boolean that is "not found", i.e. a pass.
@test "assert_absent fails when the file does not exist" {
    run assert_absent 'needle' "$TMP/no-such-file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not evaluate"* ]]
}

# The likelier one: six call sites pass hand-written extended regexes with
# alternation and escaped braces, and a typo would otherwise pass forever.
@test "assert_absent fails on a malformed pattern instead of passing" {
    run assert_absent '\$\{?(CYAN|BOLD\b' "$TMP/hay"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not evaluate"* ]]
}

@test "assert_absent fires wherever it sits in a test body" {
    run bash -c "set -euo pipefail
        $(declare -f assert_absent)
        assert_absent 'needle' '$TMP/hay'
        echo SHOULD_NOT_REACH"
    [ "$status" -ne 0 ]
    [[ "$output" != *"SHOULD_NOT_REACH"* ]]
    # On the helper's own message, not just a non-zero status: if the function
    # vanished, `declare -f` would emit nothing and the 127 from "command not
    # found" would satisfy the two assertions above.
    [[ "$output" == *"unexpectedly found"* ]]
}
