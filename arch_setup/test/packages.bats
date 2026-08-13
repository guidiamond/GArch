#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/packages.sh"
    TMP="$BATS_TEST_TMPDIR"
}

@test "pkg_list strips comments and blank lines" {
    printf '# a comment\n\nfoo\n  bar  \n\n# another\nbaz\n' > "$TMP/l.txt"
    run pkg_list "$TMP/l.txt"
    [ "$output" = "$(printf 'foo\nbar\nbaz')" ]
}

@test "pkg_list on an empty file returns nothing" {
    printf '# only comments\n' > "$TMP/l.txt"
    run pkg_list "$TMP/l.txt"
    [ -z "$output" ]
}

@test "pkg_list fails on a missing file" {
    run pkg_list "$TMP/nope.txt"
    [ "$status" -ne 0 ]
}

@test "pkg_list ignores inline trailing whitespace" {
    printf 'foo   \n' > "$TMP/l.txt"
    run pkg_list "$TMP/l.txt"
    [ "$output" = "foo" ]
}

@test "all real package lists parse and are non-empty" {
    local f
    for f in base repo aur optional; do
        run pkg_list "${BATS_TEST_DIRNAME}/../packages/${f}.txt"
        [ "$status" -eq 0 ]
        [ -n "$output" ]
    done
}

@test "pkg_read populates the named array" {
    printf 'foo\n# c\nbar\n' > "$TMP/l.txt"
    local -a got
    pkg_read "$TMP/l.txt" got
    [ "${#got[@]}" -eq 2 ]
    [ "${got[0]}" = "foo" ]
    [ "${got[1]}" = "bar" ]
}

# The regression test for the mapfile trap: a missing file must FAIL, not
# quietly produce an empty array that pacstrap would then run with.
@test "pkg_read fails loudly on a missing file" {
    local -a got
    run pkg_read "$TMP/nope.txt" got
    [ "$status" -ne 0 ]
}

@test "pkg_read fails on a file with no packages in it" {
    printf '# only comments\n\n' > "$TMP/l.txt"
    local -a got
    run pkg_read "$TMP/l.txt" got
    [ "$status" -ne 0 ]
}
