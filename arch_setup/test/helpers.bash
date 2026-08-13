#!/usr/bin/env bash
# Shared bats assertions. Loaded with `load helpers`.
# shellcheck shell=bash

# assert_absent <extended-regex> <file>
#
# The only safe way to assert a pattern is missing. A bare `! grep -q ...` is
# exempt from errexit -- bash never stops on a !-inverted pipeline -- so it
# fails a test only when it happens to be the *last* command in the body, and
# silently disarms the moment anyone appends a line after it. A function
# returning non-zero is an ordinary command, so it fires wherever it sits.
# Prints the offending lines, since "pattern found" alone is a poor bug report.
assert_absent() {
    local pattern=$1 file=$2
    if grep -qE -- "$pattern" "$file"; then
        printf 'unexpectedly found /%s/ in %s:\n' "$pattern" "$file" >&2
        grep -nE -- "$pattern" "$file" >&2
        return 1
    fi
}
