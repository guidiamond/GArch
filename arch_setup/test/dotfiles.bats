#!/usr/bin/env bats

setup() {
    TMP="$BATS_TEST_TMPDIR"
    HOME="$TMP/home"
    mkdir -p "$HOME"
    # HOME must be reassigned *before* sourcing: DOTFILES_DIR defaults to
    # "$HOME/.dotfiles" at source time, so sourcing first would bind it to
    # the real invoking user's home instead of this test's sandbox.
    source "${BATS_TEST_DIRNAME}/../lib/ui.sh"
    source "${BATS_TEST_DIRNAME}/../lib/dotfiles.sh"
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

# Originally written to exercise the unchecked `cat > "$HOME/.netrc"`
# (chmod ran unconditionally after it, so a failed write could still fall
# through to an implicit zero exit). Since round 2 added a backup-existing-
# file step that runs first, a pre-existing ".netrc" that's actually a
# directory is now caught by *that* step's `cp` failing, not by the `cat`
# guard this test was written for -- renamed to say what it now covers.
# The `cat` guard itself is exercised separately below, with no
# pre-existing .netrc so the backup step is skipped entirely.
@test "netrc_write fails loudly when it cannot back up an existing (corrupted) netrc" {
    mkdir -p "$HOME/.netrc"
    run netrc_write "someone" "tok123"
    [ "$status" -ne 0 ]
}

# Same failure class, but with nothing pre-existing at $HOME/.netrc, so the
# backup step is skipped and this actually reaches the `cat` guard. A plain
# unwritable $HOME (e.g. chmod 500) does NOT discriminate here: with no
# file ever created, the unconditional `chmod 600 "$HOME/.netrc"` that
# used to follow a bare `cat >` fails too (nothing to chmod), so the two
# failures coincidentally cancel out to the right exit status even without
# checking `cat` at all. A real disk-full write, faked with `ulimit -f 0`
# in a throwaway subshell, does discriminate: the file gets *created*
# (0 bytes) before the write that exceeds the limit kills `cat`, so the
# unconditional chmod afterward would succeed against that leftover empty
# file and mask the failure -- proven against a reverted copy of this
# guard, see the round-3 report.
@test "netrc_write fails loudly when the write itself fails" {
    run bash -c "
        ulimit -f 0
        source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
        source '${BATS_TEST_DIRNAME}/../lib/dotfiles.sh'
        HOME='${HOME}'
        netrc_write someone tok123
    "
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

# --- round 2: fixes requested by spec review ---

# Issue 1a: the anchor '[[:space:]]*$' fixed the github.community false
# positive but broke the single-line netrc form ("machine X login Y
# password Z" all on one line), which curl and git both document and which
# is what many real netrc files actually use.
@test "netrc_has_github recognizes the single-line netrc form" {
    printf 'machine github.com login someone password tok123\n' > "$HOME/.netrc"
    run netrc_has_github
    [ "$status" -eq 0 ]
}

# Issue 1a, other direction: leading whitespace before "machine" is also
# valid netrc syntax and must still be recognized.
@test "netrc_has_github recognizes an indented machine line" {
    printf '  machine github.com\n    login x\n    password y\n' > "$HOME/.netrc"
    run netrc_has_github
    [ "$status" -eq 0 ]
}

# Issue 1b: ensure_github_auth's "already configured" check can be wrong
# (see above), and netrc_write does `cat > "$HOME/.netrc"`, a whole-file
# overwrite. If detection is ever wrong, or netrc_write is called directly,
# an existing working credential file (github or any other unrelated host)
# must never simply vanish.
@test "netrc_write backs up an existing netrc before overwriting it" {
    printf 'machine github.com\n  login old\n  password oldtok\nmachine gitlab.com\n  login x\n  password y\n' > "$HOME/.netrc"
    chmod 600 "$HOME/.netrc"
    netrc_write "new" "newtok"
    run bash -c "cat ${HOME}/.netrc.bak-*"
    [ "$status" -eq 0 ]
    [[ "$output" == *"login old"* ]]
    [[ "$output" == *"gitlab.com"* ]]
    grep -q 'login new' "$HOME/.netrc"
}

# Issue 2: -type l widened the scan to symlinks-to-files (correct) but also
# to symlinks-to-directories (wrong): stow folds those into an existing
# real target directory just like a plain directory entry, so flagging one
# as a "conflict" makes stow_apply relocate the user's whole real directory
# -- and everything inside it -- into a backup dir it never needed to
# leave. This repo actually has this shape: vimspector_cfg/gadgets/linux/
# debugpy is a symlink-to-directory in the repo, and vimspector recreates a
# real directory at that same path at runtime.
@test "stow_conflicts still flags a real file blocking a symlink-to-file entry" {
    mkdir -p "$TMP/repo/dotfiles"
    ln -s /nonexistent-target "$TMP/repo/dotfiles/.testrc"
    printf 'pre-existing\n' > "$HOME/.testrc"
    run stow_conflicts "$TMP/repo" "$HOME"
    [[ "$output" == *".testrc"* ]]
}

@test "stow_conflicts does not flag a real directory blocking a symlink-to-directory entry" {
    mkdir -p "$TMP/repo/dotfiles/sub" "$TMP/real_target"
    ln -s "$TMP/real_target" "$TMP/repo/dotfiles/sub/gadgets"
    mkdir -p "$HOME/sub/gadgets"
    printf 'user data\n' > "$HOME/sub/gadgets/keep.txt"
    run stow_conflicts "$TMP/repo" "$HOME"
    [[ "$output" != *"gadgets"* ]]
}

# Issue 3: the bug class ("a command fails, its status is discarded, and
# the caller announces success") survived inside stow_conflicts itself.
# The `-d` guard only covers a missing package dir; `find` can still fail
# for other reasons (e.g. a subtree it can't read), and the trailing
# `return 0` discarded that too, handing back an empty or truncated
# conflict list at status 0 instead of surfacing the real failure.
@test "stow_conflicts fails loudly when part of the repo tree is unreadable" {
    mkdir -p "$TMP/repo/dotfiles/blocked"
    printf 'secret\n' > "$TMP/repo/dotfiles/blocked/leaf"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
    chmod 000 "$TMP/repo/dotfiles/blocked"
    run stow_conflicts "$TMP/repo" "$HOME"
    chmod 755 "$TMP/repo/dotfiles/blocked"
    [ "$status" -ne 0 ]
}

# Issue 4: mkdir -p and mv in stow_apply's backup loop were never checked.
# If either fails, the loop must stop immediately (not strand later
# conflicts partway through, and not print "backed up" for a file that
# was never actually moved).
@test "stow_apply aborts without printing a false 'backed up' message when the backup mkdir fails" {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'a\n' > "$TMP/repo/dotfiles/.a"
    printf 'b\n' > "$TMP/repo/dotfiles/.b"
    printf 'pre-existing-a\n' > "$HOME/.a"
    printf 'pre-existing-b\n' > "$HOME/.b"
    mkdir() { return 1; }
    run stow_apply "$TMP/repo" "$HOME"
    [[ "$output" != *"backed up"* ]]
    [ "$(cat "$HOME/.a")" = "pre-existing-a" ]
    [ "$(cat "$HOME/.b")" = "pre-existing-b" ]
}

@test "stow_apply aborts without printing a false 'backed up' message when the backup mv fails" {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
    printf 'pre-existing\n' > "$HOME/.testrc"
    mv() { return 1; }
    run stow_apply "$TMP/repo" "$HOME"
    [[ "$output" != *"backed up"* ]]
}

# Issue 5: `done < <(stow_conflicts ...)` is a process substitution, so
# stow_apply never saw stow_conflicts' own exit status -- only the while
# loop's. Proven independently of stow's own success/failure (which would
# otherwise mask this): stow_conflicts is stubbed to fail while the real
# stow command, left to run, would have succeeded cleanly (no real
# conflict exists).
@test "stow_apply surfaces a stow_conflicts failure even when the real stow would have succeeded" {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
    stow_conflicts() { echo "forced failure" >&2; return 1; }
    run stow_apply "$TMP/repo" "$HOME"
    [ "$status" -ne 0 ]
}

# Issue 6: setup() used to source lib/dotfiles.sh before reassigning HOME,
# so DOTFILES_DIR (computed at source time) bound to the real user's home
# instead of this test's sandbox.
@test "DOTFILES_DIR defaults relative to the test HOME, not the real one" {
    [[ "$DOTFILES_DIR" == "$HOME/.dotfiles" ]]
}

# Issue 7: ensure_github_auth discarded netrc_write's exit status.
# Stubbed so no network or git is touched -- only the propagation itself
# is under test.
@test "ensure_github_auth propagates a netrc_write failure instead of claiming success" {
    netrc_has_github() { return 1; }
    github_verify() { return 0; }
    netrc_write() { return 1; }
    run ensure_github_auth
    [ "$status" -ne 0 ]
    [[ "$output" != *"wrote"* ]]
}

# Issue 7: dotfiles_clone discarded git clone's exit status. `git` itself
# is stubbed so no network is touched.
@test "dotfiles_clone propagates a git clone failure instead of claiming success" {
    DOTFILES_DIR="$TMP/nonexistent-clone-target"
    ensure_github_auth() { return 0; }
    git() { return 1; }
    run dotfiles_clone
    [ "$status" -ne 0 ]
    [[ "$output" != *"cloned to"* ]]
}

# --- round 3: fixes requested by spec re-review ---

# BLOCKING 1a: the backup name only had one-second granularity and cp
# overwrote silently, so two netrc_write calls in the same second made the
# second backup clobber the first with the *already-overwritten* file --
# the original ends up nowhere on disk. `date` is stubbed to a fixed value
# so the collision is deterministic instead of depending on hitting the
# same wall-clock second by luck.
@test "netrc_write never collides two same-second backups into one" {
    printf 'machine github.com\n  login old\n  password oldtok\n' > "$HOME/.netrc"
    chmod 600 "$HOME/.netrc"
    date() { echo "20260101-000000"; }
    netrc_write "mid" "midtok"
    netrc_write "new" "newtok"
    run bash -c "grep -rl 'login old' ${HOME}/.netrc.bak-* 2>/dev/null"
    [ -n "$output" ]
}

# BLOCKING 1b: same collision, applied to stow_apply's
# .dotfiles-backup-<ts> directory. Two invocations in the same second with
# genuinely different conflicting content must not let the second mv
# overwrite the first invocation's already-backed-up file.
@test "stow_apply never collides two same-second backups into one directory" {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
    date() { echo "20260101-000000"; }

    printf 'first-run\n' > "$HOME/.testrc"
    stow_apply "$TMP/repo" "$HOME"

    rm -f "$HOME/.testrc"
    printf 'second-run\n' > "$HOME/.testrc"
    stow_apply "$TMP/repo" "$HOME"

    run bash -c "grep -rl 'first-run' ${HOME}/.dotfiles-backup-*/.testrc 2>/dev/null"
    [ -n "$output" ]
}

# Small fix 1: [[ -e "$HOME/.netrc" ]] follows symlinks, so a *dangling*
# symlink there failed that check, skipped the backup/removal step
# entirely, and let the `cat >` below follow the link and write the token
# to whatever arbitrary path it pointed at instead of $HOME/.netrc.
@test "netrc_write removes a dangling netrc symlink instead of writing through it" {
    ln -s "$TMP/nonexistent-netrc-target" "$HOME/.netrc"
    netrc_write "someone" "tok123"
    [ ! -L "$HOME/.netrc" ]
    [ -f "$HOME/.netrc" ]
    grep -q 'login someone' "$HOME/.netrc"
    [ ! -e "$TMP/nonexistent-netrc-target" ]
}

# Small fix 3: the abort message on a failed backup must name the backup
# directory, or a user reading "failed to back up .b" has no way to know
# ".c" and ".d" (backed up before the failure) are sitting in
# .dotfiles-backup-<ts>/ with nothing linked.
@test "stow_apply's abort message names the backup directory" {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
    printf 'mine\n' > "$HOME/.testrc"
    mv() { return 1; }
    run stow_apply "$TMP/repo" "$HOME"
    [[ "$output" == *".dotfiles-backup-"* ]]
}

# The mkdir/mv-abort-on-first-failure fix (round 2) had coverage for "don't
# print a false success message" but nothing that directly proves later
# conflicts are never even attempted. Stateless by construction -- it
# counts mv invocations rather than depending on find's traversal order,
# so a loop that stops after the first failure calls mv exactly once
# regardless of which of the three files is visited first.
@test "stow_apply stops at the first failed backup instead of trying the rest" {
    mkdir -p "$TMP/repo/dotfiles"
    for n in a b c; do
        printf 'repo\n' > "$TMP/repo/dotfiles/.$n"
        printf 'mine\n' > "$HOME/.$n"
    done
    mv() { echo x >> "$TMP/mvcalls"; return 1; }
    run stow_apply "$TMP/repo" "$HOME"
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$TMP/mvcalls")" -eq 1 ]
}
