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

# pkg_list strips inline comments as well as whole-line ones. Pinned because a
# hand-written `grep -hvE '^\s*#|^\s*$'` -- the obvious "simplification", and
# what a README verification snippet would reach for -- agrees with this only
# while packages/*.txt contains no inline comment, and disagrees silently on
# the first one anyone writes. No package name contains '#', so stripping is
# always safe; the two behaviours diverging is what is not.
@test "pkg_list strips an inline comment, not just a whole-line one" {
    printf 'foo  # needed by bar\nbaz\n' > "$TMP/l.txt"
    run pkg_list "$TMP/l.txt"
    [ "$output" = "$(printf 'foo\nbaz')" ]
}

# The nameref trap. pkg_read binds `local -n <internal>=$2`, and a $2 equal to
# that internal name is a *circular* reference: bash prints a warning on stderr
# and leaves the array empty, so the call looked like an ordinary "list is
# empty" failure. The old internals were __file/__out/__line and nothing
# stopped a caller using one.
#
# The property, whichever names the implementation happens to pick: pkg_read
# either reads the list or refuses by name. It never warns about circularity,
# and it never reports "empty" for a file with two packages in it.
@test "pkg_read never silently reads nothing into a circularly named array" {
    printf 'foo\nbar\n' > "$TMP/l.txt"
    local name
    for name in __out __file __line _pkg_out _pkg_file _pkg_line out arr; do
        run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
                     source '${BATS_TEST_DIRNAME}/../lib/packages.sh'
                     declare -a ${name}
                     pkg_read '${TMP}/l.txt' ${name} || exit 1
                     printf '%s' \"\${${name}[*]}\""
        [[ "$output" != *"circular"* ]] || {
            echo "pkg_read hit a circular nameref on '${name}'" >&2; return 1
        }
        if [ "$status" -eq 0 ]; then
            [ "$output" = "foo bar" ]
        else
            [[ "$output" == *"collides"* ]] || {
                echo "pkg_read failed on '${name}' without saying why: ${output}" >&2
                return 1
            }
        fi
    done
}

@test "pkg_read refuses an empty output name instead of failing obscurely" {
    printf 'foo\n' > "$TMP/l.txt"
    run pkg_read "$TMP/l.txt" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"no output array name"* ]]
}

# --- pkg_install_aur -------------------------------------------------------
#
# yay is installed on a real Arch box, including the one this suite is
# developed on, so it is stubbed on PATH rather than as a shell function: a
# missed stub would build packages for real.

# stub_yay <packages that fail to build>
#
# A failing build prints to stdout and to stderr before exiting, the way a real
# makepkg does: what pkg_install_aur has to do with that output is the point of
# the diagnosis case below.
stub_yay() {
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nfor bad in %s; do\n  case " $* " in *" $bad "*)\n    echo "==> Making package $bad"\n    echo "error: could not satisfy dependency libfoo" >&2\n    exit 1 ;;\n  esac\ndone\nexit 0\n' \
        "$1" > "$TMP/bin/yay"
    chmod +x "$TMP/bin/yay"
}

# The defect: the function used to end on `if ((${#PKG_FAILED[@]})); then warn;
# else success; fi`, whose status is 0 down both branches. A run where every
# single AUR package failed to build reported success to provision.sh's step()
# and got a green line in the summary.
@test "pkg_install_aur fails when a package fails to build" {
    printf 'alpha\nbeta\n' > "$TMP/l.txt"
    stub_yay "beta"
    PATH="$TMP/bin:$PATH" run pkg_install_aur "$TMP/l.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"beta"* ]]
    [[ "$output" != *"all 2 AUR packages installed"* ]]
}

@test "pkg_install_aur succeeds when everything builds" {
    printf 'alpha\nbeta\n' > "$TMP/l.txt"
    stub_yay "__none__"
    PATH="$TMP/bin:$PATH" run pkg_install_aur "$TMP/l.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"all 2 AUR packages installed"* ]]
}

# `yay ... &>/dev/null` left "failed 1 of 2: beta" as the entire diagnosis of a
# failed build: no PKGBUILD error, no missing dependency, and nothing in the
# run log either, since there was nothing to tee.
@test "pkg_install_aur shows why a package failed to build" {
    printf 'alpha\nbeta\n' > "$TMP/l.txt"
    stub_yay "beta"
    PATH="$TMP/bin:$PATH" run pkg_install_aur "$TMP/l.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not satisfy dependency libfoo"* ]]
    [[ "$output" == *"yay could not build beta"* ]]
}

# ...and a build that WORKED stays quiet, or a 148-package run buries its own
# progress line under every makepkg log.
@test "pkg_install_aur stays quiet about the packages that built" {
    printf 'alpha\n' > "$TMP/l.txt"
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\necho "==> Making package alpha"\necho "noise" >&2\nexit 0\n' > "$TMP/bin/yay"
    chmod +x "$TMP/bin/yay"
    PATH="$TMP/bin:$PATH" run pkg_install_aur "$TMP/l.txt"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Making package alpha"* ]]
    [[ "$output" != *"noise"* ]]
}

@test "pkg_install_aur leaves no temp file behind" {
    printf 'alpha\nbeta\n' > "$TMP/l.txt"
    stub_yay "beta"
    # mktemp honours TMPDIR, so the whole question is answerable in a directory
    # nothing else on this machine writes to.
    mkdir -p "$TMP/tmpdir"
    PATH="$TMP/bin:$PATH" TMPDIR="$TMP/tmpdir" run pkg_install_aur "$TMP/l.txt"
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$TMP/tmpdir")" ]
}

# PKG_FAILED is initialised once at source time and only ever appended to,
# because provision.sh's summary reads it at the end and wants both calls'
# failures. Each CALL must still report and return on its own list only --
# before this, the optional.txt call re-warned about aur.txt's failures and
# returned non-zero with nothing of its own wrong, and the summary counted the
# same packages twice.
@test "a second pkg_install_aur call does not inherit the first call's failures" {
    printf 'alpha\n' > "$TMP/first.txt"
    printf 'gamma\n' > "$TMP/second.txt"
    stub_yay "alpha"
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
                 source '${BATS_TEST_DIRNAME}/../lib/packages.sh'
                 export PATH=\"${TMP}/bin:\$PATH\"
                 pkg_install_aur '${TMP}/first.txt'  && echo FIRST_OK  || echo FIRST_FAILED
                 echo ===SECOND-CALL-STARTS-HERE===
                 pkg_install_aur '${TMP}/second.txt' && echo SECOND_OK || echo SECOND_FAILED
                 echo ===SECOND-CALL-ENDS-HERE===
                 printf 'CUMULATIVE[%s]' \"\${PKG_FAILED[*]}\""
    [[ "$output" == *"FIRST_FAILED"* ]]
    [[ "$output" == *"SECOND_OK"* ]]
    # ...and the summary still gets to see alpha, exactly once.
    [[ "$output" == *"CUMULATIVE[alpha]"* ]]
    # The second call must not mention alpha at all. Bracketed by markers
    # rather than counted: the first call legitimately names a failed package
    # more than once now that it also prints why the build failed, so a total
    # count says nothing about which call did the naming.
    local second=${output#*===SECOND-CALL-STARTS-HERE===}
    second=${second%%===SECOND-CALL-ENDS-HERE===*}
    [[ "$second" != *"alpha"* ]]
}

# --- ensure_yay ------------------------------------------------------------
#
# PATH is replaced outright, not prepended to: this host has a real
# /usr/bin/yay, and `command -v yay` finding it would make ensure_yay return at
# its first line and every case below pass without testing anything. mktemp and
# rm are linked in because ensure_yay genuinely needs them, and mkdir/chmod
# because the stubs below run under this same stripped PATH.

# ensure_yay_env <git rc> <makepkg rc> <makepkg installs yay: true|false>
ensure_yay_env() {
    local tool
    mkdir -p "$TMP/bin"
    for tool in mktemp rm mkdir chmod; do
        ln -sf "$(command -v "$tool")" "$TMP/bin/${tool}"
    done
    # `git clone --depth 1 <url> <dest>` -- $5 is the destination.
    printf '#!/bin/sh\nmkdir -p "$5" 2>/dev/null\nexit %s\n' "$1" > "$TMP/bin/git"
    if [[ "$3" == true ]]; then
        printf '#!/bin/sh\nprintf "#!/bin/sh\\nexit 0\\n" > %s/bin/yay\nchmod +x %s/bin/yay\nexit %s\n' \
            "$TMP" "$TMP" "$2" > "$TMP/bin/makepkg"
    else
        printf '#!/bin/sh\nexit %s\n' "$2" > "$TMP/bin/makepkg"
    fi
    chmod +x "$TMP/bin/git" "$TMP/bin/makepkg"
}

# Invoked the way provision.sh invokes it -- through an `if` condition, which
# is what suspends errexit for the whole dynamic extent of the call. That
# suspension is the entire reason ensure_yay has to check its own commands, so
# testing it any other way would test a situation that never happens.
run_ensure_yay_as_step() {
    bash -c "set -euo pipefail
             source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
             source '${BATS_TEST_DIRNAME}/../lib/packages.sh'
             export PATH='${TMP}/bin' TMPDIR='${TMP}'
             if ensure_yay; then echo STEP_OK; else echo STEP_FAILED; fi"
}

@test "ensure_yay fails, and says nothing about success, when the clone fails" {
    ensure_yay_env 1 0 false
    run run_ensure_yay_as_step
    [[ "$output" == *"STEP_FAILED"* ]]
    [[ "$output" == *"could not clone"* ]]
    [[ "$output" != *"yay installed"* ]]
}

@test "ensure_yay fails, and says nothing about success, when makepkg fails" {
    ensure_yay_env 0 1 false
    run run_ensure_yay_as_step
    [[ "$output" == *"STEP_FAILED"* ]]
    [[ "$output" == *"makepkg could not build"* ]]
    [[ "$output" != *"yay installed"* ]]
}

# makepkg -si can exit 0 having installed nothing. The only thing every later
# AUR step depends on is whether the binary is on PATH now.
@test "ensure_yay fails when makepkg exits 0 but leaves no yay on PATH" {
    ensure_yay_env 0 0 false
    run run_ensure_yay_as_step
    [[ "$output" == *"STEP_FAILED"* ]]
    [[ "$output" == *"still not on PATH"* ]]
}

@test "ensure_yay succeeds when the build really does install yay" {
    ensure_yay_env 0 0 true
    run run_ensure_yay_as_step
    [[ "$output" == *"STEP_OK"* ]]
    [[ "$output" == *"yay installed"* ]]
}

@test "ensure_yay leaves no build directory behind on any path" {
    local rc
    for rc in "1 0" "0 1" "0 0"; do
        # shellcheck disable=SC2086
        ensure_yay_env $rc false
        run run_ensure_yay_as_step
        [ -z "$(find "$TMP" -maxdepth 1 -type d -name 'tmp.*' -print -quit)" ] || {
            echo "ensure_yay left a build directory behind for rc='${rc}'" >&2
            return 1
        }
    done
}
