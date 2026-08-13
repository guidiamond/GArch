#!/bin/bash
# ~/.netrc, clone, stow. The only module that writes to $HOME.
# Requires lib/ui.sh.
# shellcheck shell=bash

DOTFILES_REPO="https://github.com/guidiamond/.dotfiles.git"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
STOW_PACKAGE="dotfiles"

# Anchored at the start (allowing leading whitespace, which netrc permits)
# and bounded at the end by either whitespace or end-of-line -- not just an
# end anchor. netrc allows both a multi-line "machine X\n  login Y\n
# password Z" form and a single-line "machine X login Y password Z" form,
# and both are common in the wild; a plain '$' anchor rejects the
# single-line form outright. The boundary after "github.com" still rejects
# an unrelated host that merely starts with the same characters, e.g.
# github.community or github.company-mirror.com.
netrc_has_github() {
    [[ -f "$HOME/.netrc" ]] && grep -qE '^[[:space:]]*machine[[:space:]]+github\.com([[:space:]]|$)' "$HOME/.netrc"
}

netrc_write() {
    local user=$1 token=$2 old_umask backup
    [[ -n "$user"  ]] || { error "netrc_write: empty username"; return 1; }
    [[ -n "$token" ]] || { error "netrc_write: empty token"; return 1; }

    # umask is process-wide and this file is sourced (not exec'd), so an
    # unrestored umask would silently tighten every file this process
    # creates for the rest of the run -- always restore it, success or not.
    # Set *before* the backup below, not just before the final write: a
    # loose ambient umask at backup-creation time would otherwise let the
    # old credentials sit briefly at a looser mode before the explicit
    # chmod caught up.
    old_umask=$(umask)
    umask 077

    # This is a whole-file overwrite below, and detection above can be
    # wrong (or netrc_write can be called directly). Never let a working
    # credential file -- for github.com or any other unrelated host -- just
    # disappear: copy whatever is already there aside first. Bail without
    # touching the original if the backup itself can't be made. `-L` as
    # well as `-e`: a *dangling* symlink fails `-e`, so without this it
    # would fall through untouched and the `cat >` below would follow it,
    # writing the token to whatever arbitrary path it points at instead of
    # $HOME/.netrc.
    if [[ -e "$HOME/.netrc" || -L "$HOME/.netrc" ]]; then
        if [[ -L "$HOME/.netrc" && ! -e "$HOME/.netrc" ]]; then
            # Nothing real behind the link to back up.
            rm -f "$HOME/.netrc" || { umask "$old_umask"; error "netrc_write: failed to remove dangling symlink at ${HOME}/.netrc"; return 1; }
            warn "removed dangling symlink at ${HOME}/.netrc"
        else
            # A name that can never collide with a previous run's backup,
            # even one made in the same second: two same-second calls
            # (a retry, or two provisioning runs) must not let the second
            # backup overwrite the first with the file it already replaced.
            if ! backup=$(mktemp "$HOME/.netrc.bak-$(date +%Y%m%d-%H%M%S)-XXXXXX"); then
                umask "$old_umask"
                error "netrc_write: failed to create a backup path for ${HOME}/.netrc"
                return 1
            fi
            if ! cp "$HOME/.netrc" "$backup"; then
                umask "$old_umask"
                error "netrc_write: failed to back up existing ${HOME}/.netrc"
                rm -f "$backup"
                return 1
            fi
            chmod 600 "$backup" || { umask "$old_umask"; error "netrc_write: failed to chmod backup ${backup}"; return 1; }
            warn "backed up existing ${HOME}/.netrc -> ${backup}"
            # A *valid* symlink must be removed too, so the write below
            # creates a plain regular file at $HOME/.netrc itself rather
            # than following the link and overwriting whatever real file
            # it happens to point at.
            if [[ -L "$HOME/.netrc" ]]; then
                rm -f "$HOME/.netrc" || { umask "$old_umask"; error "netrc_write: failed to remove existing symlink at ${HOME}/.netrc"; return 1; }
            fi
        fi
    fi

    if ! cat > "$HOME/.netrc" <<EOF
machine github.com
  login ${user}
  password ${token}
EOF
    then
        umask "$old_umask"
        error "netrc_write: failed to write ${HOME}/.netrc"
        return 1
    fi
    umask "$old_umask"

    chmod 600 "$HOME/.netrc" || { error "netrc_write: failed to chmod ${HOME}/.netrc"; return 1; }
}

github_verify() {
    local user=$1 token=$2 login
    login=$(curl -sf -u "${user}:${token}" https://api.github.com/user \
            | grep -oP '(?<="login": ")[^"]+' || true)
    [[ -n "$login" ]] || { error "GitHub rejected those credentials"; return 1; }
    success "authenticated as ${login}"
}

# Prompts only when there is no usable credential already.
ensure_github_auth() {
    netrc_has_github && { success "${HOME}/.netrc already has a github.com entry"; return 0; }
    local user token
    user=$(ask "GitHub username" "guidiamond")
    read -rsp "$(echo -e "${BOLD}GitHub PAT (repo scope)${RESET}: ")" token; echo ""
    github_verify "$user" "$token" || return 1
    netrc_write "$user" "$token" || return 1
    success "wrote ${HOME}/.netrc (600)"
}

dotfiles_clone() {
    [[ -d "${DOTFILES_DIR}/.git" ]] && { success "dotfiles already present at ${DOTFILES_DIR}"; return 0; }
    ensure_github_auth || return 1
    info "Cloning dotfiles..."
    git clone "$DOTFILES_REPO" "$DOTFILES_DIR" || { error "failed to clone ${DOTFILES_REPO}"; return 1; }
    success "cloned to ${DOTFILES_DIR}"
}

# Real files (not symlinks) that stow would refuse to overwrite. Also scans
# repo entries that are themselves symlinks-to-files (this dotfiles repo has
# several, e.g. .config/fzf/*.zsh) -- a plain -type f miss there means a
# real file blocking one never gets backed up before stow_apply runs the
# real stow. Symlinks-to-*directories* are deliberately excluded (-xtype):
# stow folds those into an existing real target directory exactly like a
# plain directory entry, so flagging one would make stow_apply relocate the
# user's whole real directory -- and everything inside it -- into a backup
# it never needed to leave (e.g. vimspector_cfg/gadgets/linux/debugpy,
# which vimspector recreates as a real directory at runtime). A plain
# directory in the repo colliding with a real directory at the target is
# not a conflict either, for the same folding reason, and needs no special
# case: the leaf-file granularity of this scan already matches it.
# One case is deliberately left unhandled: a real *file* blocking a
# symlink-to-directory repo entry (rather than a real directory blocking
# it). This scan stays silent about it -- verified as the right trade --
# and lets the real `stow` command refuse that one link with its own
# actionable message rather than have this function guess whether to
# relocate the blocking file. Do not "fix" this back to flagging it.
stow_conflicts() {
    local repo=$1 target=$2 pkgdir rel abs listing
    pkgdir="${repo}/${STOW_PACKAGE}"
    [[ -d "$pkgdir" ]] || { error "stow_conflicts: no such package dir: ${pkgdir}"; return 1; }

    # Captured via command substitution, not streamed straight into the
    # while loop's process substitution, specifically so find's own exit
    # status is visible here: a `cd && find` that fails partway through
    # (e.g. a subtree it can't read) must not be reported as "no
    # conflicts" at status 0 -- that would hand stow_apply a silently
    # truncated list and let it charge ahead anyway.
    if ! listing=$(cd "$pkgdir" && find . \( -type f -o \( -type l -a ! -xtype d \) \) -printf '%P\n'); then
        error "stow_conflicts: failed to scan ${pkgdir}"
        return 1
    fi

    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        abs="${target}/${rel}"
        # `if`, not a bare `[[ ]] && echo`: the non-match case (the common
        # one) must not leave a non-zero status as the last statement run,
        # or a caller with `set -e` would abort mid-scan on the first file
        # that isn't a conflict.
        if [[ -e "$abs" && ! -L "$abs" ]]; then
            echo "$rel"
        fi
    done <<< "$listing"
    return 0
}

stow_apply() {
    local repo=$1 target=$2 backup="" rel conflicts

    # Captured via command substitution: `done < <(stow_conflicts ...)`
    # would only expose the while loop's own status, not stow_conflicts'
    # -- a scan failure would pass through here silently.
    if ! conflicts=$(stow_conflicts "$repo" "$target"); then
        error "stow_apply: could not determine conflicts for ${repo} -> ${target}"
        return 1
    fi

    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        if [[ -z "$backup" ]]; then
            # Created lazily, on the first real conflict, and named so it
            # can never collide with another run's backup dir even in the
            # same second: a same-second retry must not let the second
            # run's mv overwrite the first run's already-backed-up file
            # inside what would otherwise be the identical directory name.
            if ! backup=$(mktemp -d "${target}/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)-XXXXXX"); then
                error "stow_apply: failed to create a backup dir under ${target}"
                return 1
            fi
        fi
        # Stop at the first failure instead of limping on: with several
        # conflicts, continuing past a failed mkdir/mv would relocate the
        # ones that did succeed while stow (below) still aborts wholesale,
        # stranding files in the backup dir with nothing linked and a
        # "backed up" message that was never true for the failed one. Name
        # the backup dir in both messages: a user reading "failed to back
        # up .b" has no way to know ".a" (backed up before the failure) is
        # already sitting there with nothing linked, unless we say where.
        if ! mkdir -p "${backup}/$(dirname "$rel")"; then
            error "stow_apply: failed to create backup dir for ${rel} under ${backup}"
            return 1
        fi
        if ! mv "${target}/${rel}" "${backup}/${rel}"; then
            error "stow_apply: failed to back up ${rel} (earlier files, if any, are under ${backup})"
            return 1
        fi
        warn "backed up ${rel} -> ${backup}/${rel}"
    done <<< "$conflicts"

    # -R restows, so re-running cleans up links whose targets moved.
    # Never --adopt: that pulls machine state into the repo silently.
    if stow -R -t "$target" -d "$repo" "$STOW_PACKAGE"; then
        success "dotfiles stowed into ${target}"
    else
        error "stow failed for ${STOW_PACKAGE} -> ${target}"
        return 1
    fi
}
