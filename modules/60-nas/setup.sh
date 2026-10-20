# shellcheck shell=bash
# The NAS mount unit, rendered from prompted values. Sourced, not executed:
# signal completion with `return`, never `exit`.

MODULE_FAILED=0

if [[ -z ${NAS_HOST:-} ]]; then
    log_warn "No NAS host was provided; skipping the mount unit."
    return 0
fi

# 1. Mountpoint.
if [[ -d $NAS_MOUNT ]]; then
    log_info "Mountpoint already exists: $NAS_MOUNT"
else
    run_sudo mkdir -p "$NAS_MOUNT" || {
        log_error "failed to create mountpoint: $NAS_MOUNT"
        MODULE_FAILED=1
    }
fi
run_sudo chown "${USER:-$(id -un)}:${USER:-$(id -un)}" "$NAS_MOUNT" || {
    log_error "failed to chown mountpoint: $NAS_MOUNT"
    MODULE_FAILED=1
}

# 2. Render the ssh host entry. No secrets — just a hostname and a key path.
# $DOTFILES_DIR is always set by bootstrap.sh, but a module sourced manually
# outside the engine would otherwise abort here under `set -u`.
if [[ -f ${DOTFILES_DIR:-}/ssh/config.template ]]; then
    rendered=$(sed \
        -e "s#@NAS_HOST@#$NAS_HOST#" \
        -e "s#@NAS_USER@#${NAS_USER:-${USER:-$(id -un)}}#" \
        -e "s#@NAS_KEY@#${NAS_KEY:-$HOME/.ssh/id_ed25519}#" \
        "${DOTFILES_DIR:-}/ssh/config.template")
    run mkdir -p "$HOME/.ssh/config.d" || {
        log_error "failed to create $HOME/.ssh/config.d"
        MODULE_FAILED=1
    }
    patch_write_if_different "$HOME/.ssh/config.d/bootstrap" "$rendered"
    # ~/.ssh/config must include config.d for the entry to take effect. On a
    # fresh install that file does not exist at all, which previously
    # suppressed this note entirely — exactly the scenario this project
    # exists to serve. Fire whenever the Include line is missing, including
    # when ~/.ssh/config itself is absent. Never create or rewrite the
    # user's ~/.ssh/config here: this module cannot know what else belongs
    # in it, so a note is the right remedy.
    if [[ ! -f $HOME/.ssh/config ]] || ! grep -q 'Include config.d/\*' "$HOME/.ssh/config"; then
        summary_note "Add 'Include config.d/*' to the top of ~/.ssh/config (creating the file if it does not exist) so ssh nas resolves."
    fi
else
    log_warn "No dotfiles/ssh/config.template found; skipping ssh config fragment."
fi

# 3. Probe before enabling. Spec section 10: the key must already be
#    authorized on the NAS, and a unit that cannot mount is worse than none.
probe_ok=0
if (( DRY_RUN )); then
    _log DRY '0;36' "ssh probe to $NAS_HOST"
    probe_ok=1
else
    log_info "Probing $NAS_HOST over ssh"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        -i "${NAS_KEY:-$HOME/.ssh/id_ed25519}" \
        "${NAS_USER:-${USER:-$(id -un)}}@$NAS_HOST" true 2>/dev/null; then
        probe_ok=1
        log_ok "NAS reachable"
    else
        log_warn "Could not authenticate to $NAS_HOST"
        if [[ -f ${NAS_KEY:-$HOME/.ssh/id_ed25519}.pub ]]; then
            log_step "Authorize this key on the NAS, then re-run with --only 60-nas:"
            cat "${NAS_KEY:-$HOME/.ssh/id_ed25519}.pub"
        fi
        summary_note "NAS mount unit was written but NOT enabled — the key is not authorized on $NAS_HOST yet."
    fi
fi

# 4. The unit itself. The filename must match the escaped mount path —
#    hand-writing it is how systemd ends up silently refusing to start it.
unit_name=$(systemd-escape --path --suffix=mount "$NAS_MOUNT")
patch_write_if_different "/etc/systemd/system/$unit_name" "# Written by the 60-nas bootstrap module.
[Unit]
Description=NAS over sshfs
After=network-online.target
Wants=network-online.target

[Mount]
What=${NAS_USER:-${USER:-$(id -un)}}@$NAS_HOST:$NAS_PATH
Where=$NAS_MOUNT
Type=fuse.sshfs
Options=_netdev,allow_other,IdentityFile=${NAS_KEY:-$HOME/.ssh/id_ed25519},reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,uid=$(id -u),gid=$(id -g)

[Install]
WantedBy=multi-user.target"

run_sudo systemctl daemon-reload || {
    log_error "systemctl daemon-reload failed"
    MODULE_FAILED=1
}

if (( probe_ok )); then
    run_sudo systemctl enable --now "$unit_name" || {
        log_error "failed to enable $unit_name"
        MODULE_FAILED=1
    }
else
    log_warn "Unit $unit_name written but left disabled until the key works."
fi

(( MODULE_FAILED )) && return 1
return 0
