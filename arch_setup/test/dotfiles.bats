#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/dotfiles.sh"
    TMP="$BATS_TEST_TMPDIR"
    HOME="$TMP/home"
    mkdir -p "$HOME"
}

@test "netrc_write creates a 600 file with the credentials" {
    netrc_write "someone" "tok123"
    [ -f "$HOME/.netrc" ]
    [ "$(stat -c '%a' "$HOME/.netrc")" = "600" ]
    grep -q 'machine github.com' "$HOME/.netrc"
    grep -q 'login someone' "$HOME/.netrc"
    grep -q 'password tok123' "$HOME/.netrc"
}

@test "netrc_write refuses an empty token" {
    run netrc_write "someone" ""
    [ "$status" -ne 0 ]
    [ ! -f "$HOME/.netrc" ]
}

# Renamed from the plan's "netrc_write does not clobber an existing valid
# netrc": this test never calls netrc_write, it only checks netrc_has_github
# against a pre-existing file. Keeping the assertion (it covers real
# behaviour) but naming it for what it actually exercises.
@test "netrc_has_github is true for an existing github entry" {
    printf 'machine github.com\n  login old\n  password oldtok\n' > "$HOME/.netrc"
    chmod 600 "$HOME/.netrc"
    netrc_has_github && result=yes || result=no
    [ "$result" = "yes" ]
}

@test "netrc_has_github is false when the file is absent" {
    run netrc_has_github
    [ "$status" -ne 0 ]
}

@test "stow_conflicts lists a real file that blocks a link" {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
    printf 'pre-existing\n' > "$HOME/.testrc"
    run stow_conflicts "$TMP/repo" "$HOME"
    [[ "$output" == *".testrc"* ]]
}

@test "stow_conflicts is silent when there is nothing in the way" {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
    run stow_conflicts "$TMP/repo" "$HOME"
    [ -z "$output" ]
}

@test "stow_apply backs up a conflicting file then links it" {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
    printf 'pre-existing\n' > "$HOME/.testrc"
    stow_apply "$TMP/repo" "$HOME"
    [ -L "$HOME/.testrc" ]
    [ "$(cat "$HOME/.testrc")" = "from repo" ]
    run bash -c "cat ${HOME}/.dotfiles-backup-*/.testrc"
    [ "$output" = "pre-existing" ]
}

# --- defects found beyond the plan's 7 tests ---

# netrc_has_github used an unanchored regex ('.' is "any char", and there
# was no end anchor), so a *different* host that merely starts with
# "github" + any-char + "com" reads as a github.com credential. Real hosts
# this collides with: github.community, github.company-mirror.com, etc.
@test "netrc_has_github does not false-positive on a similar hostname" {
    printf 'machine github.community\n  login x\n  password y\n' > "$HOME/.netrc"
    run netrc_has_github
    [ "$status" -ne 0 ]
}

# umask 077 in netrc_write leaked into the caller's shell forever (lib/
# files are sourced, not exec'd, so this is the actual process running
# provision.sh). Every file provision.sh creates afterwards -- package
# lists, logs, other dotfiles -- would silently become mode 600/700.
@test "netrc_write restores the caller's umask" {
    local before after
    before=$(umask)
    netrc_write "someone" "tok123"
    after=$(umask)
    [ "$after" = "$before" ]
}

# cat > "$HOME/.netrc" was never checked, and chmod ran unconditionally
# after it. If the write fails outright (destination is a directory, disk
# full, permission denied), chmod on the leftover/partial path can still
# succeed, so the function fell through to an implicit zero exit -- callers
# see "success" while no credentials were actually written.
@test "netrc_write fails loudly when the destination cannot be written" {
    mkdir -p "$HOME/.netrc"
    run netrc_write "someone" "tok123"
    [ "$status" -ne 0 ]
}

# stow_conflicts piped `cd pkgdir && find ...` into the while loop and
# ended with an unconditional `return 0`. If the repo package dir doesn't
# exist, cd fails, find never runs, the loop reads nothing, and the
# function still reports success with an empty (i.e. "no conflicts") list
# -- stow_apply would then charge ahead into a real `stow` invocation
# against a nonexistent package.
@test "stow_conflicts fails loudly when the repo package dir is missing" {
    run stow_conflicts "$TMP/repo" "$HOME"
    [ "$status" -ne 0 ]
}

# The loop body's last statement was a bare `[[ ... ]] && echo "$rel"`.
# Under a caller that runs with `set -e` (a real possibility for
# provision.sh), a non-matching iteration -- the common case -- makes that
# statement's status 1 with nothing exempting it, aborting the whole
# function mid-scan instead of finishing the file list.
@test "stow_conflicts finishes the scan under set -e when nothing conflicts" {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
    wrapper() { set -e; stow_conflicts "$TMP/repo" "$HOME"; echo "reached end"; }
    run wrapper
    [[ "$output" == *"reached end"* ]]
}

# stow_conflicts only looked at `-type f`, so a repo entry that is itself a
# symlink (this dotfiles repo has several, e.g. .config/fzf/*.zsh) was
# never scanned. A real file at that target path would then not get
# backed up before stow_apply calls the real `stow`.
@test "stow_conflicts also lists a real file blocking a symlinked repo entry" {
    mkdir -p "$TMP/repo/dotfiles"
    ln -s /nonexistent-target "$TMP/repo/dotfiles/.testrc"
    printf 'pre-existing\n' > "$HOME/.testrc"
    run stow_conflicts "$TMP/repo" "$HOME"
    [[ "$output" == *".testrc"* ]]
}

# stow_apply never checked stow's own exit status, so a real `stow`
# failure (here: the repo package doesn't exist at all) still printed
# "dotfiles stowed into ..." and returned success.
@test "stow_apply fails loudly when the real stow command fails" {
    run stow_apply "$TMP/repo" "$HOME"
    [ "$status" -ne 0 ]
}
