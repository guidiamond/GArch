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

# A minimal stow package: just the .testrc file most stow_conflicts/
# stow_apply tests either scan or conflict on.
make_repo() {
    mkdir -p "$TMP/repo/dotfiles"
    printf 'from repo\n' > "$TMP/repo/dotfiles/.testrc"
}

# Same, plus a real pre-existing file at the target that blocks it.
make_repo_with_conflict() {
    make_repo
    printf 'pre-existing\n' > "$HOME/.testrc"
}

# --- netrc detection ---------------------------------------------------

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

# netrc_has_github's regex used to be unanchored ('.' is "any char", and
# there was no end anchor), so a *different* host that merely starts with
# "github" + any-char + "com" read as a github.com credential. Real hosts
# this collides with: github.community, github.company-mirror.com, etc.
@test "netrc_has_github does not false-positive on a similar hostname" {
    printf 'machine github.community\n  login x\n  password y\n' > "$HOME/.netrc"
    run netrc_has_github
    [ "$status" -ne 0 ]
}

# The anchor that fixed the false positive above also has to not reject
# the single-line netrc form ("machine X login Y password Z" all on one
# line), which curl and git both document and which is what many real
# netrc files actually use.
@test "netrc_has_github recognizes the single-line netrc form" {
    printf 'machine github.com login someone password tok123\n' > "$HOME/.netrc"
    run netrc_has_github
    [ "$status" -eq 0 ]
}

# Leading whitespace before "machine" is also valid netrc syntax.
@test "netrc_has_github recognizes an indented machine line" {
    printf '  machine github.com\n    login x\n    password y\n' > "$HOME/.netrc"
    run netrc_has_github
    [ "$status" -eq 0 ]
}

# --- netrc_write: backup and overwrite ----------------------------------

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

# umask 077 used to leak into the caller's shell forever (lib/ files are
# sourced, not exec'd, so this is the actual process running provision.sh).
# Every file provision.sh creates afterwards -- package lists, logs, other
# dotfiles -- would silently become mode 600/700. Contained in a subshell
# now, which this pins.
@test "netrc_write restores the caller's umask" {
    local before after
    before=$(umask)
    netrc_write "someone" "tok123"
    after=$(umask)
    [ "$after" = "$before" ]
}

# An existing working credential file (github or any other unrelated host)
# must never simply vanish, whatever detection says: netrc_write does a
# whole-file overwrite.
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

# The backup name only had one-second granularity and cp overwrote
# silently, so two calls in the same second (a retry, or two provisioning
# runs) made the second backup clobber the first with the *already-
# overwritten* file -- the original ends up nowhere on disk. `date` is
# stubbed to a fixed value so the collision is deterministic instead of
# depending on hitting the same wall-clock second by luck.
@test "netrc_write never collides two same-second backups into one" {
    printf 'machine github.com\n  login old\n  password oldtok\n' > "$HOME/.netrc"
    chmod 600 "$HOME/.netrc"
    date() { echo "20260101-000000"; }
    netrc_write "mid" "midtok"
    netrc_write "new" "newtok"
    run bash -c "grep -rl 'login old' ${HOME}/.netrc.bak-* 2>/dev/null"
    [ -n "$output" ]
}

# [[ -e "$HOME/.netrc" ]] follows symlinks, so a *dangling* symlink there
# used to fail that check, skip the backup/removal step entirely, and let
# the write below follow the link, landing the token at whatever arbitrary
# path it pointed at instead of $HOME/.netrc.
@test "netrc_write removes a dangling netrc symlink instead of writing through it" {
    ln -s "$TMP/nonexistent-netrc-target" "$HOME/.netrc"
    netrc_write "someone" "tok123"
    [ ! -L "$HOME/.netrc" ]
    [ -f "$HOME/.netrc" ]
    grep -q 'login someone' "$HOME/.netrc"
    [ ! -e "$TMP/nonexistent-netrc-target" ]
}

# Originally written to exercise the unchecked `cat > "$HOME/.netrc"`
# (chmod ran unconditionally after it, so a failed write could still fall
# through to an implicit zero exit). Now that a pre-existing ".netrc" is
# handled by netrc_clear_path first, a ".netrc" that's actually a
# directory is caught by *that* step's `cp` failing instead -- named for
# what it actually covers. The `cat` guard itself is exercised separately
# below, with no pre-existing .netrc so the backup step is skipped.
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
# in a throwaway subprocess, does discriminate: the file gets *created*
# (0 bytes) before the write that exceeds the limit kills `cat`, so the
# unconditional chmod afterward would succeed against that leftover empty
# file and mask the failure.
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

# --- github auth flow ---------------------------------------------------

# DOTFILES_DIR is computed at source time from HOME, so sourcing before
# reassigning HOME in setup() would bind it to the real invoking user's
# home instead of this test's sandbox.
@test "DOTFILES_DIR defaults relative to the test HOME, not the real one" {
    [[ "$DOTFILES_DIR" == "$HOME/.dotfiles" ]]
}

# Pressing Enter at the PAT prompt used to fire a real request at
# api.github.com before netrc_write's own empty-token guard ever got a
# chance to run. github_verify_creds is stubbed to record whether it was
# called at all -- the real assertion here, independent of exit status.
@test "ensure_github_auth refuses an empty PAT instead of asking GitHub" {
    netrc_has_github() { return 1; }
    github_verify_creds() { : > "$TMP/verify_called"; return 0; }
    # Explicit </dev/null: under a real tty (unlike bats' usual inherited
    # /dev/null stdin) `ask`'s `read -rp` would otherwise block forever
    # waiting for a username that's never coming. At EOF `ask` reports the
    # failure and returns non-zero, which `run` (errexit off) lets fall
    # through to the PAT read -- also EOF, also empty -- so the empty-token
    # guard is still what returns non-zero and both assertions hold.
    run ensure_github_auth </dev/null
    [ "$status" -ne 0 ]
    [ ! -e "$TMP/verify_called" ]
}

# Stubbed so no network or git is touched -- only the propagation of
# netrc_write's exit status is under test. Real credentials are fed via
# stdin so the empty-token guard above doesn't short-circuit first.
@test "ensure_github_auth propagates a netrc_write failure instead of claiming success" {
    netrc_has_github() { return 1; }
    github_verify_creds() { return 0; }
    netrc_write() { return 1; }
    run ensure_github_auth <<< $'someone\nsometoken\n'
    [ "$status" -ne 0 ]
    [[ "$output" != *"wrote"* ]]
}

# `git` itself is stubbed so no network is touched.
@test "dotfiles_clone propagates a git clone failure instead of claiming success" {
    DOTFILES_DIR="$TMP/nonexistent-clone-target"
    ensure_github_auth() { return 0; }
    git() { return 1; }
    run dotfiles_clone
    [ "$status" -ne 0 ]
    [[ "$output" != *"cloned to"* ]]
}

# --- clone first, authenticate only if that fails --------------------------
#
# The repository is public, so the ordinary run needs no credentials at all.
# ensure_github_auth used to run unconditionally *before* the clone, which
# demanded a PAT nobody needs and failed stage 2 outright for an operator at
# a bare console who cannot produce one.
#
# clone_stub <fail-first-n> [leave-partial]
#
# A `git` stub on PATH, standing in for the only invocation this module ever
# makes: `git clone <repo> <dest>`. It reproduces the parts of real git these
# cases turn on, each measured against git 2.55.0:
#
#   * every invocation is recorded, so call *counts* and call *order* are
#     assertable -- which is what separates "clone, then authenticate" from
#     "authenticate, then clone";
#   * a destination that already exists and is not empty is refused, exactly
#     as real git refuses it;
#   * with `leave-partial`, a failing invocation leaves the destination
#     behind with a .git inside it first. Real git cleans up after an orderly
#     failure (repository-not-found, connection refused), but a clone killed
#     mid-transfer cannot -- verified: SIGKILL during object transfer leaves
#     <dest>/.git, and the next clone then dies with "destination path
#     already exists and is not an empty directory".
clone_stub() {
    local fail_n=$1 partial=${2:-}
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${TMP}/gitcalls"
n=\$(wc -l < "${TMP}/gitcalls")
dest=\$3
if [ -d "\$dest" ] && [ -n "\$(ls -A "\$dest" 2>/dev/null)" ]; then
    echo "fatal: destination path '\$dest' already exists and is not an empty directory." >&2
    exit 128
fi
if [ "\$n" -le ${fail_n} ]; then
    if [ -n "${partial}" ]; then mkdir -p "\$dest/.git"; fi
    echo "fatal: repository not found" >&2
    exit 128
fi
mkdir -p "\$dest/.git"
exit 0
EOF
    chmod +x "$TMP/bin/git"
    : > "$TMP/gitcalls"
}

# ensure_github_auth is left REAL here, with no ~/.netrc and stdin at EOF, so
# reaching it at all cannot succeed quietly -- `ask` reports the EOF and the
# empty-token guard returns non-zero. That is deliberately the strongest form
# of "was not consulted": the case fails whether the old code merely asked or
# actually got an answer.
@test "dotfiles_clone clones a public repo without prompting for credentials" {
    clone_stub 0
    DOTFILES_DIR="$TMP/clone-target"
    PATH="$TMP/bin:$PATH" run dotfiles_clone </dev/null
    [ "$status" -eq 0 ]
    [ -d "$TMP/clone-target/.git" ]
    [[ "$output" == *"cloned to"* ]]
    [[ "$output" != *"GitHub username"* ]]
}

# The sentinel is the whole point: netrc_has_github is stubbed to return 0, so
# on the old code ensure_github_auth short-circuits and every *other*
# observable -- exit status, output, the cloned directory -- is identical
# between the two versions. Nothing but the sentinel can tell them apart, so
# nothing but the sentinel can be what fails.
@test "dotfiles_clone does not read ~/.netrc when the clone needs no credentials" {
    clone_stub 0
    DOTFILES_DIR="$TMP/clone-target"
    netrc_has_github() { : > "$TMP/netrc_read"; return 0; }
    PATH="$TMP/bin:$PATH" run dotfiles_clone
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/netrc_read" ]
}

# The repository going private is the case the retained auth functions exist
# for. `clone_stub 1` fails the first attempt without leaving anything behind,
# so this pins the fallback on its own, with the partial-clone cleanup below
# held out as a separate case.
@test "dotfiles_clone falls back to authentication when the clone fails" {
    clone_stub 1
    DOTFILES_DIR="$TMP/clone-target"
    ensure_github_auth() { : > "$TMP/auth_called"; return 0; }
    PATH="$TMP/bin:$PATH" run dotfiles_clone
    [ "$status" -eq 0 ]
    [ -e "$TMP/auth_called" ]
    [ "$(wc -l < "$TMP/gitcalls")" -eq 2 ]
    [[ "$output" == *"cloned to"* ]]
}

# The exit status alone does NOT discriminate here -- the old code also
# returns non-zero, just for the opposite reason (it gave up on the auth
# without ever attempting a clone). The call count is what pins the ordering.
@test "dotfiles_clone attempts the clone before authenticating, and fails when both fail" {
    clone_stub 99
    DOTFILES_DIR="$TMP/clone-target"
    ensure_github_auth() { return 1; }
    PATH="$TMP/bin:$PATH" run dotfiles_clone
    [ "$status" -ne 0 ]
    [[ "$output" != *"cloned to"* ]]
    [ "$(wc -l < "$TMP/gitcalls")" -eq 1 ]
}

# A failed first attempt can leave a partial destination behind (see
# clone_stub), and real git then refuses the retry outright -- so the retry
# would be dead on arrival without the cleanup, and the "trying authenticated"
# message would be followed by a failure that has nothing to do with auth.
@test "dotfiles_clone clears the partial clone it created before retrying" {
    clone_stub 1 leave-partial
    DOTFILES_DIR="$TMP/clone-target"
    ensure_github_auth() { return 0; }
    PATH="$TMP/bin:$PATH" run dotfiles_clone
    [ "$status" -eq 0 ]
    [[ "$output" != *"already exists"* ]]
}

# The other side of that cleanup, and the reason it is conditional rather than
# an unguarded `rm -rf "$DOTFILES_DIR"`: a directory that was already there
# when the function started is the user's, holds whatever they put in it, and
# is left exactly as found however badly the clone goes.
@test "dotfiles_clone never deletes a DOTFILES_DIR it did not create" {
    clone_stub 99
    DOTFILES_DIR="$TMP/clone-target"
    mkdir -p "$DOTFILES_DIR"
    printf 'mine\n' > "$DOTFILES_DIR/KEEP"
    ensure_github_auth() { return 1; }
    PATH="$TMP/bin:$PATH" run dotfiles_clone
    [ "$status" -ne 0 ]
    [ -f "$DOTFILES_DIR/KEEP" ]
}

@test "dotfiles_clone short-circuits when the dotfiles are already present" {
    clone_stub 99
    DOTFILES_DIR="$TMP/clone-target"
    mkdir -p "$DOTFILES_DIR/.git"
    ensure_github_auth() { : > "$TMP/auth_called"; return 0; }
    PATH="$TMP/bin:$PATH" run dotfiles_clone
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/auth_called" ]
    [ "$(wc -l < "$TMP/gitcalls")" -eq 0 ]
}

# NOT `run dotfiles_clone`: bats' own `run` turns errexit off inside the run,
# which is the setting under test. A separate shell instead, running the
# function directly under `set -euo pipefail` -- not inside an `if`, which
# would suspend errexit for the whole call and hide exactly what this checks.
# The guard clause at the top of the function used to be a bare
# `[[ -d ... ]] && { ...; return 0; }`, whose status on the common path (no
# clone yet) is 1 with nothing exempting it, so such a caller aborted on line
# one and the clone never happened at all.
@test "dotfiles_clone runs to completion under a caller's set -e" {
    clone_stub 0
    run env PATH="$TMP/bin:$PATH" HOME="$HOME" DOTFILES_DIR="$TMP/clone-target" \
        bash -c "set -euo pipefail
                 source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
                 source '${BATS_TEST_DIRNAME}/../lib/dotfiles.sh'
                 dotfiles_clone
                 echo REACHED-END" </dev/null
    [[ "$output" == *"REACHED-END"* ]]
    [ -d "$TMP/clone-target/.git" ]
}

# The mirror image: invoked the way provision.sh's step() invokes it, as an
# `if` condition. Bash suspends errexit for the whole dynamic extent of a
# condition context, so the function cannot lean on the file's `set -e` to
# stop it -- it has to check its own commands and return non-zero itself.
@test "dotfiles_clone reports failure to a caller that has suspended errexit" {
    clone_stub 99
    run env PATH="$TMP/bin:$PATH" HOME="$HOME" DOTFILES_DIR="$TMP/clone-target" \
        bash -c "set -euo pipefail
                 source '${BATS_TEST_DIRNAME}/../lib/ui.sh'
                 source '${BATS_TEST_DIRNAME}/../lib/dotfiles.sh'
                 if dotfiles_clone; then echo VERDICT-OK; else echo VERDICT-FAIL; fi" </dev/null
    [[ "$output" == *"VERDICT-FAIL"* ]]
    [ "$(wc -l < "$TMP/gitcalls")" -ge 1 ]
}

# `guidiamond/.dotfiles` -- the dot-prefixed name this used to carry -- does
# not exist: it 404s for the owner's own authenticated token. The local
# *directory* is .dotfiles; the repository is not, and conflating the two is
# what produced a DOTFILES_REPO nobody could ever clone. GArch is the
# repository's canonical current name, and it is public.
@test "DOTFILES_REPO names a repository that exists" {
    [ "$DOTFILES_REPO" = "https://github.com/guidiamond/GArch.git" ]
}

# --- stow_conflicts: scanning --------------------------------------------

@test "stow_conflicts lists a real file that blocks a link" {
    make_repo_with_conflict
    run stow_conflicts "$TMP/repo" "$HOME"
    [[ "$output" == *".testrc"* ]]
}

@test "stow_conflicts is silent when there is nothing in the way" {
    make_repo
    run stow_conflicts "$TMP/repo" "$HOME"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# cd pkgdir && find used to be piped straight into the while loop with an
# unconditional `return 0` at the end. If the repo package dir doesn't
# exist, cd fails, find never runs, the loop reads nothing, and the
# function used to still report success with an empty conflict list --
# stow_apply would then charge ahead into a real `stow` invocation against
# a nonexistent package.
@test "stow_conflicts fails loudly when the repo package dir is missing" {
    run stow_conflicts "$TMP/repo" "$HOME"
    [ "$status" -ne 0 ]
}

# The `-d` guard above only covers a missing package dir; find can still
# fail for other reasons (e.g. a subtree it can't read), and the same
# trailing `return 0` used to discard that too, handing back an empty or
# truncated conflict list at status 0 instead of surfacing the failure.
@test "stow_conflicts fails loudly when part of the repo tree is unreadable" {
    make_repo
    mkdir -p "$TMP/repo/dotfiles/blocked"
    printf 'secret\n' > "$TMP/repo/dotfiles/blocked/leaf"
    chmod 000 "$TMP/repo/dotfiles/blocked"
    run stow_conflicts "$TMP/repo" "$HOME"
    chmod 755 "$TMP/repo/dotfiles/blocked"
    [ "$status" -ne 0 ]
}

# The loop body's last statement used to be a bare `[[ ... ]] && echo
# "$rel"`. Under a caller that runs with `set -e` (a real possibility for
# provision.sh), a non-matching iteration -- the common case -- makes that
# statement's status 1 with nothing exempting it, aborting the whole
# function mid-scan instead of finishing the file list.
@test "stow_conflicts finishes the scan under set -e when nothing conflicts" {
    make_repo
    wrapper() { set -e; stow_conflicts "$TMP/repo" "$HOME"; echo "reached end"; }
    run wrapper
    [[ "$output" == *"reached end"* ]]
}

# The scan used to only look at -type f, so a repo entry that is itself a
# symlink-to-a-file (this dotfiles repo has several, e.g. .config/fzf/
# *.zsh) was never scanned, and a real file blocking one never got backed
# up before stow_apply ran the real stow.
@test "stow_conflicts still flags a real file blocking a symlink-to-file entry" {
    mkdir -p "$TMP/repo/dotfiles"
    ln -s /nonexistent-target "$TMP/repo/dotfiles/.testrc"
    printf 'pre-existing\n' > "$HOME/.testrc"
    run stow_conflicts "$TMP/repo" "$HOME"
    [[ "$output" == *".testrc"* ]]
}

# Widening the scan to symlinks was right for symlinks-to-files (above) but
# wrong for symlinks-to-directories, which stow folds into an existing real
# target directory rather than conflicting on. Flagging one would make
# stow_apply relocate the user's whole real directory -- and everything
# inside it -- into a backup it never needed to leave. Reachable in this
# repo: vimspector_cfg/gadgets/linux/debugpy is a symlink-to-directory in
# the repo, and vimspector recreates a real directory at that same path at
# runtime.
@test "stow_conflicts does not flag a real directory blocking a symlink-to-directory entry" {
    mkdir -p "$TMP/repo/dotfiles/sub" "$TMP/real_target"
    ln -s "$TMP/real_target" "$TMP/repo/dotfiles/sub/gadgets"
    mkdir -p "$HOME/sub/gadgets"
    printf 'user data\n' > "$HOME/sub/gadgets/keep.txt"
    run stow_conflicts "$TMP/repo" "$HOME"
    [ "$status" -eq 0 ]
    [[ "$output" != *"gadgets"* ]]
}

# The remaining case -- a real *file* (not a directory) blocking a
# symlink-to-directory entry -- is deliberately left unhandled: this scan
# stays silent, and stow itself refuses that one link with its own
# actionable message rather than have this function guess whether to
# relocate the blocking file.
@test "real file blocking a symlink-to-directory entry is left to stow itself" {
    mkdir -p "$TMP/repo/dotfiles/sub" "$TMP/real_target"
    ln -s "$TMP/real_target" "$TMP/repo/dotfiles/sub/gadgets"
    mkdir -p "$HOME/sub"
    printf 'mine\n' > "$HOME/sub/gadgets"
    run stow_conflicts "$TMP/repo" "$HOME"
    [ "$status" -eq 0 ]
    [[ "$output" != *"gadgets"* ]]
}

# --- stow_apply: backup and link ------------------------------------------

@test "stow_apply backs up a conflicting file then links it" {
    make_repo_with_conflict
    stow_apply "$TMP/repo" "$HOME"
    [ -L "$HOME/.testrc" ]
    [ "$(cat "$HOME/.testrc")" = "from repo" ]
    run bash -c "cat ${HOME}/.dotfiles-backup-*/.testrc"
    [ "$output" = "pre-existing" ]
}

# stow_apply never checked stow's own exit status, so a real `stow`
# failure (here: the repo package doesn't exist at all) still printed
# "dotfiles stowed into ..." and returned success.
@test "stow_apply fails loudly when the real stow command fails" {
    run stow_apply "$TMP/repo" "$HOME"
    [ "$status" -ne 0 ]
}

# mkdir -p and mv in the backup loop used to be unchecked. If either
# fails, the loop must stop immediately (not strand later conflicts
# partway through, and not print "backed up" for a file that was never
# actually moved) -- and the caller must be told it failed, not just shown
# a suspiciously quiet success.
@test "stow_apply aborts without printing a false 'backed up' message when the backup mkdir fails" {
    make_repo
    printf 'a\n' > "$TMP/repo/dotfiles/.a"
    printf 'b\n' > "$TMP/repo/dotfiles/.b"
    printf 'pre-existing-a\n' > "$HOME/.a"
    printf 'pre-existing-b\n' > "$HOME/.b"
    mkdir() { return 1; }
    run stow_apply "$TMP/repo" "$HOME"
    [ "$status" -ne 0 ]
    [[ "$output" != *"backed up"* ]]
    [ "$(cat "$HOME/.a")" = "pre-existing-a" ]
    [ "$(cat "$HOME/.b")" = "pre-existing-b" ]
}

@test "stow_apply aborts without printing a false 'backed up' message when the backup mv fails" {
    make_repo_with_conflict
    mv() { return 1; }
    run stow_apply "$TMP/repo" "$HOME"
    [ "$status" -ne 0 ]
    [[ "$output" != *"backed up"* ]]
}

# `done < <(stow_conflicts ...)` is a process substitution, so stow_apply
# never saw stow_conflicts' own exit status -- only the while loop's.
# Proven independently of stow's own success/failure (which would
# otherwise mask this): stow_conflicts is stubbed to fail while the real
# stow command, left to run, would have succeeded cleanly (no real
# conflict exists).
@test "stow_apply surfaces a stow_conflicts failure even when the real stow would have succeeded" {
    make_repo
    stow_conflicts() { echo "forced failure" >&2; return 1; }
    run stow_apply "$TMP/repo" "$HOME"
    [ "$status" -ne 0 ]
}

# Same collision as netrc_write's backup file, applied to stow_apply's
# .dotfiles-backup-<ts> directory. Two invocations in the same second with
# genuinely different conflicting content must not let the second mv
# overwrite the first invocation's already-backed-up file.
@test "stow_apply never collides two same-second backups into one directory" {
    make_repo
    date() { echo "20260101-000000"; }

    printf 'first-run\n' > "$HOME/.testrc"
    stow_apply "$TMP/repo" "$HOME"

    rm -f "$HOME/.testrc"
    printf 'second-run\n' > "$HOME/.testrc"
    stow_apply "$TMP/repo" "$HOME"

    run bash -c "grep -rl 'first-run' ${HOME}/.dotfiles-backup-*/.testrc 2>/dev/null"
    [ -n "$output" ]
}

# The abort message on a failed backup must name the backup directory, or
# a user reading "failed to back up .b" has no way to know ".c" and ".d"
# (backed up before the failure) are sitting in .dotfiles-backup-<ts>/
# with nothing linked.
@test "stow_apply's abort message names the backup directory" {
    make_repo_with_conflict
    mv() { return 1; }
    run stow_apply "$TMP/repo" "$HOME"
    [[ "$output" == *".dotfiles-backup-"* ]]
}

# The mkdir/mv-abort-on-first-failure behaviour above had coverage for
# "don't print a false success message" but nothing that directly proves
# later conflicts are never even attempted. Stateless by construction --
# it counts mv invocations rather than depending on find's traversal
# order, so a loop that stops after the first failure calls mv exactly
# once regardless of which of the three files is visited first.
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

# --- stage_dotfiles --------------------------------------------------------
#
# Called by install.sh with /mnt as the target root. Everything here works
# against a fake target root under $TMP instead, which is the reason the
# function takes its paths as arguments rather than reading install.sh's
# globals -- a hardcoded /mnt could only be tested on a real install.
#
# arch-chroot is stubbed on PATH: it is the one command in the function that
# needs a real installed system, and stubbing it is what makes the happy path
# reachable at all. It records its arguments so the chown can be asserted.
stage_fixture() {
    mkdir -p "$TMP/mnt/home/damn" "$TMP/repo/.git"
    printf 'repo file\n' > "$TMP/repo/README"
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/chroot_calls\n' "$TMP" > "$TMP/bin/arch-chroot"
    chmod +x "$TMP/bin/arch-chroot"
}

@test "stage_dotfiles copies the repo and hands it to the user" {
    stage_fixture
    PATH="$TMP/bin:$PATH" run stage_dotfiles "$TMP/repo" "$TMP/mnt" damn
    [ "$status" -eq 0 ]
    [ -f "$TMP/mnt/home/damn/.dotfiles/README" ]
    # The copy is only half the job: cp -a preserves the ISO's ownership, whose
    # uid numbering is not the new root's, so the chown has to happen and has
    # to happen through the chroot.
    grep -qF 'chown -R damn:damn /home/damn/.dotfiles' "$TMP/chroot_calls"
}

# The ordering guard. install.sh must call this after arch-chroot has created
# the user; if it ever runs first there is no home directory, and the right
# answer is to say so rather than to mkdir one -- a pre-created home makes
# `useradd -m` skip the owner, the mode and /etc/skel entirely.
@test "stage_dotfiles refuses to create a home directory that useradd should own" {
    stage_fixture
    rm -rf "$TMP/mnt/home/damn"
    PATH="$TMP/bin:$PATH" run stage_dotfiles "$TMP/repo" "$TMP/mnt" damn
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/mnt/home/damn" ]
    [[ "$output" == *"fresh clone"* ]]
    [ ! -e "$TMP/chroot_calls" ]
}

# `cp -a src dest` where dest exists copies *into* it, leaving
# .dotfiles/.dotfiles. Skip instead, and say so.
@test "stage_dotfiles leaves an existing .dotfiles alone" {
    stage_fixture
    mkdir -p "$TMP/mnt/home/damn/.dotfiles"
    printf 'mine\n' > "$TMP/mnt/home/damn/.dotfiles/KEEP"
    PATH="$TMP/bin:$PATH" run stage_dotfiles "$TMP/repo" "$TMP/mnt" damn
    [ "$status" -eq 0 ]
    [ -f "$TMP/mnt/home/damn/.dotfiles/KEEP" ]
    [ ! -e "$TMP/mnt/home/damn/.dotfiles/.dotfiles" ]
    [ ! -e "$TMP/mnt/home/damn/.dotfiles/README" ]
}

# Non-fatal by design: the machine boots by this point and stage 2 can clone,
# so a missing repo must not take down a working install.
@test "stage_dotfiles warns rather than failing when there is no repo to copy" {
    stage_fixture
    PATH="$TMP/bin:$PATH" run stage_dotfiles "$TMP/no-such-repo" "$TMP/mnt" damn
    [ "$status" -eq 0 ]
    [[ "$output" == *"fresh clone"* ]]
    [ ! -e "$TMP/mnt/home/damn/.dotfiles" ]
}
