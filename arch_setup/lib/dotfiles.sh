#!/bin/bash
# ~/.netrc, clone, stow. The only module that writes to $HOME.
# Requires lib/ui.sh.
# shellcheck shell=bash

DOTFILES_REPO="https://github.com/guidiamond/.dotfiles.git"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
STOW_PACKAGE="dotfiles"

# Anchored on both ends: an unanchored '.' (regex "any char") would also
# match an unrelated host that merely starts with "github" + any-char +
# "com", e.g. github.community or github.company-mirror.com.
netrc_has_github() {
    [[ -f "$HOME/.netrc" ]] && grep -qE '^machine[[:space:]]+github\.com[[:space:]]*$' "$HOME/.netrc"
}

netrc_write() {
    local user=$1 token=$2 old_umask
    [[ -n "$user"  ]] || { error "netrc_write: empty username"; return 1; }
    [[ -n "$token" ]] || { error "netrc_write: empty token"; return 1; }

    # umask is process-wide and this file is sourced (not exec'd), so an
    # unrestored umask would silently tighten every file this process
    # creates for the rest of the run -- always restore it, success or not.
    old_umask=$(umask)
    umask 077
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
# repo entries that are themselves symlinks (this dotfiles repo has several,
# e.g. .config/fzf/*.zsh) -- a plain -type f miss there means a real file
# blocking one never gets backed up before stow_apply runs the real stow.
# A directory in the repo colliding with a real directory at the target is
# not a conflict: stow folds into an existing real directory and links the
# leaf files inside it, which is exactly the granularity this scan uses.
stow_conflicts() {
    local repo=$1 target=$2 pkgdir rel abs
    pkgdir="${repo}/${STOW_PACKAGE}"
    [[ -d "$pkgdir" ]] || { error "stow_conflicts: no such package dir: ${pkgdir}"; return 1; }
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
    done < <(cd "$pkgdir" && find . \( -type f -o -type l \) -printf '%P\n')
    return 0
}

stow_apply() {
    local repo=$1 target=$2 backup rel
    backup="${target}/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"

    while read -r rel; do
        [[ -z "$rel" ]] && continue
        mkdir -p "${backup}/$(dirname "$rel")"
        mv "${target}/${rel}" "${backup}/${rel}"
        warn "backed up ${rel} -> ${backup}/${rel}"
    done < <(stow_conflicts "$repo" "$target")

    # -R restows, so re-running cleans up links whose targets moved.
    # Never --adopt: that pulls machine state into the repo silently.
    if stow -R -t "$target" -d "$repo" "$STOW_PACKAGE"; then
        success "dotfiles stowed into ${target}"
    else
        error "stow failed for ${STOW_PACKAGE} -> ${target}"
        return 1
    fi
}
