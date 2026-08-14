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
#
# grep's status is branched on rather than treated as a boolean: status 2 is
# "grep could not answer", which a two-way test reads as "pattern absent" and
# passes. That covers a missing file, and -- the likelier one, since most
# callers pass hand-written extended regexes with alternation and escaped
# braces -- a malformed pattern, which would otherwise disarm the assertion
# on the day it was written, with a green test and nothing said.
#
# `|| rc=$?` rather than `grep ...; rc=$?`: the caller runs under errexit, and
# the plain form aborts on grep's status 1 -- the ordinary "absent" path --
# before the assignment is ever reached.
assert_absent() {
    local pattern=$1 file=$2 rc=0
    grep -qE -- "$pattern" "$file" || rc=$?
    case $rc in
        0)  printf 'unexpectedly found /%s/ in %s:\n' "$pattern" "$file" >&2
            grep -nE -- "$pattern" "$file" >&2
            return 1 ;;
        1)  return 0 ;;
        *)  printf 'assert_absent: grep could not evaluate /%s/ against %s (status %d) -- malformed pattern or unreadable file\n' \
                "$pattern" "$file" "$rc" >&2
            return 1 ;;
    esac
}
