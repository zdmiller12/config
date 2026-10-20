# shellcheck shell=bash
# fish, fisher, dotfile links, git identity, SSH key, and the default shell.

MODULE_FAILED=0

# 1. Dotfile symlinks.
# $DOTFILES_DIR is always set by bootstrap.sh, but a module sourced manually
# outside the engine (e.g. for local testing) would otherwise abort here
# under `set -u`. The fallback is intentionally empty: it degrades to a
# nonexistent manifest path rather than guessing a location.
link_manifest "${DOTFILES_DIR:-}/links" "${DOTFILES_DIR:-}"

# 2. git identity, written outside the repo so nothing personal is committed.
# Both fields are required: a `[user]` block with only one of name/email set
# is a tidiness problem waiting to surprise someone later, and it costs
# nothing to just ask for both.
if [[ -n ${GIT_NAME:-} && -n ${GIT_EMAIL:-} ]]; then
    patch_write_if_different "$HOME/.gitconfig.local" "# Written by the 10-shell module from prompted values. Not committed.
[user]
	name = ${GIT_NAME:-}
	email = ${GIT_EMAIL:-}"
elif [[ -n ${GIT_NAME:-} || -n ${GIT_EMAIL:-} ]]; then
    summary_note "Only one of GIT_NAME/GIT_EMAIL was provided; ~/.gitconfig.local was not written. Provide both to set a git identity."
else
    summary_note "No git identity was provided; ~/.gitconfig.local was not written."
fi

# 3. SSH key. Generated here, never transported by this repo. Treated as
#    essential: without a key nothing downstream can authenticate to
#    GitHub, so a real failure here fails the module.
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ -f $SSH_KEY ]]; then
    log_info "SSH key already present at $SSH_KEY"
else
    run mkdir -p "$HOME/.ssh"
    run chmod 700 "$HOME/.ssh"
    # $USER and `hostname` both need their own fallbacks: under `set -u`,
    # an unset $USER (common in minimal containers, and this module has
    # container=yes) would abort the whole sourced script while building
    # this default, not just fail the keygen. `hostname` may also be
    # absent in a minimal container, so it gets a literal fallback too.
    ssh_key_comment="${GIT_EMAIL:-${USER:-$(id -un)}@$(hostname 2>/dev/null || echo localhost)}"
    if run ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "$ssh_key_comment"; then
        if (( DRY_RUN )) || [[ -f $SSH_KEY.pub ]]; then
            if [[ -f $SSH_KEY.pub ]]; then
                log_step "Add this public key to GitHub before any step needs to authenticate:"
                cat "$SSH_KEY.pub"
            fi
            ui_pause "Press Enter once the key is added to https://github.com/settings/keys"
            summary_note "A new SSH key was generated at $SSH_KEY.pub — authorize it wherever it is needed."
        else
            log_error "ssh-keygen reported success but $SSH_KEY.pub is missing"
            summary_note "SSH key generation did not produce a public key at $SSH_KEY.pub; GitHub authentication will fail until this is resolved."
            MODULE_FAILED=1
        fi
    else
        log_error "ssh-keygen failed"
        summary_note "SSH key generation failed; GitHub authentication will not work until this is resolved."
        MODULE_FAILED=1
    fi
fi

# 4. Switch this clone's remote to SSH now that a key exists. The initial
#    clone had to use HTTPS because no key existed yet. Gated on a real
#    public key file existing, not just on having attempted keygen — a
#    failed or merely-simulated (dry-run) keygen must not flip the remote
#    to SSH with nothing able to authenticate it.
if [[ -f $SSH_KEY.pub ]] && git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | grep -q '^https://github.com/'; then
    ssh_url=$(git -C "$REPO_ROOT" remote get-url origin \
        | sed -e 's#^https://github.com/#git@github.com:#')
    run git -C "$REPO_ROOT" remote set-url origin "$ssh_url"
    log_info "Switched the origin remote to SSH: $ssh_url"
elif git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | grep -q '^https://github.com/'; then
    summary_note "origin remote left on HTTPS: no SSH public key is available at $SSH_KEY.pub"
fi

# 5. fisher, the fish plugin manager. Installed inside fish, so the whole
#    thing is one `fish -c`. A fisher failure is a convenience miss, not
#    essential, so it is logged and does not fail the module.
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

# 6. Make fish the login shell. A chsh failure is also a convenience miss
#    (e.g. fish not yet listed in /etc/shells) — log and note it accurately,
#    but do not fail the module over it.
FISH_BIN=$(command -v fish || true)
if [[ -n $FISH_BIN && ${SHELL:-} != "$FISH_BIN" ]]; then
    if run chsh -s "$FISH_BIN"; then
        summary_note "Login shell changed to fish; it takes effect on the next login."
    else
        log_error "chsh failed; login shell was not changed to fish"
        summary_note "Could not change the login shell to fish (chsh failed); change it manually if needed."
    fi
fi

(( MODULE_FAILED )) && return 1
return 0
