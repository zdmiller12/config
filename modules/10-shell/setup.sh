# shellcheck shell=bash
# fish, fisher, dotfile links, git identity, SSH key, and the default shell.

# 1. Dotfile symlinks.
link_manifest "$DOTFILES_DIR/links" "$DOTFILES_DIR"

# 2. git identity, written outside the repo so nothing personal is committed.
if [[ -n ${GIT_NAME:-} || -n ${GIT_EMAIL:-} ]]; then
    patch_write_if_different "$HOME/.gitconfig.local" "# Written by the 10-shell module from prompted values. Not committed.
[user]
	name = ${GIT_NAME:-}
	email = ${GIT_EMAIL:-}"
else
    summary_note "No git identity was provided; ~/.gitconfig.local was not written."
fi

# 3. SSH key. Generated here, never transported by this repo.
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ ! -f $SSH_KEY ]]; then
    run mkdir -p "$HOME/.ssh"
    run chmod 700 "$HOME/.ssh"
    run ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "${GIT_EMAIL:-$USER@$(hostname)}"
    if [[ -f $SSH_KEY.pub ]]; then
        log_step "Add this public key to GitHub before any step needs to authenticate:"
        cat "$SSH_KEY.pub"
        ui_pause "Press Enter once the key is added to https://github.com/settings/keys"
    fi
    summary_note "A new SSH key was generated at $SSH_KEY.pub — authorize it wherever it is needed."
else
    log_info "SSH key already present at $SSH_KEY"
fi

# 4. Switch this clone's remote to SSH now that a key exists. The initial
#    clone had to use HTTPS because no key existed yet.
if git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | grep -q '^https://github.com/'; then
    ssh_url=$(git -C "$REPO_ROOT" remote get-url origin \
        | sed -e 's#^https://github.com/#git@github.com:#')
    run git -C "$REPO_ROOT" remote set-url origin "$ssh_url"
    log_info "Switched the origin remote to SSH: $ssh_url"
fi

# 5. fisher, the fish plugin manager. Installed inside fish, so the whole
#    thing is one `fish -c`.
if command -v fish > /dev/null 2>&1; then
    if ! fish -c 'functions -q fisher' 2>/dev/null; then
        if (( DRY_RUN )); then
            _log DRY '0;36' "install fisher via fish"
        else
            log_info "Installing fisher"
            fish -c 'curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher' \
                || log_error "fisher installation failed"
        fi
    else
        log_info "fisher is already installed"
    fi
fi

# 6. Make fish the login shell.
FISH_BIN=$(command -v fish || true)
if [[ -n $FISH_BIN && ${SHELL:-} != "$FISH_BIN" ]]; then
    run chsh -s "$FISH_BIN"
    summary_note "Login shell changed to fish; it takes effect on the next login."
fi
return 0
