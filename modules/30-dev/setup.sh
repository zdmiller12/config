# shellcheck shell=bash
# VSCode extensions and Docker group membership.

MODULE_FAILED=0

# 1. Extensions, captured from the machine this repo came from.
#    `code --install-extension` is idempotent and exits 0 when already
#    present, but we still check `code --list-extensions` first to avoid
#    30 no-op subprocess launches.
EXTENSIONS=(
    anthropic.claude-code
    christian-kohler.npm-intellisense
    docker.docker
    eamodio.gitlens
    esbenp.prettier-vscode
    github.codespaces
    github.vscode-github-actions
    hasnainroopawalla.vscode-python-timeit
    mechatroner.rainbow-csv
    mermaidchart.vscode-mermaid-chart
    ms-azuretools.vscode-containers
    ms-azuretools.vscode-docker
    ms-python.black-formatter
    ms-python.debugpy
    ms-python.isort
    ms-python.python
    ms-python.vscode-pylance
    ms-python.vscode-python-envs
    ms-toolsai.jupyter
    ms-toolsai.jupyter-keymap
    ms-toolsai.jupyter-renderers
    ms-toolsai.vscode-jupyter-cell-tags
    ms-toolsai.vscode-jupyter-slideshow
    ms-vscode-remote.remote-containers
    ms-vscode.cmake-tools
    ms-vscode.cpp-devtools
    ms-vscode.live-server
    njpwerner.autodocstring
    tomoki1207.pdf
    yzhang.markdown-all-in-one
)

if command -v code > /dev/null 2>&1; then
    installed=$(code --list-extensions 2>/dev/null || true)
    for ext in "${EXTENSIONS[@]}"; do
        if printf '%s\n' "$installed" | grep -qix "$ext"; then
            continue
        fi
        run code --install-extension "$ext" --force || {
            log_error "extension failed: $ext"
            MODULE_FAILED=1
        }
    done
else
    log_warn "code is not on PATH; skipping extensions"
fi

# 2. Docker without sudo. Requires a full logout to take effect (newgrp
#    only affects the current shell) — the same trap documented in
#    docs/virtualization.md for libvirt.
if getent group docker > /dev/null 2>&1; then
    if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
        log_info "already in the docker group"
    else
        if run_sudo usermod -aG docker "$USER"; then
            summary_note "Added to the docker group — log out and back in before 'docker' works without sudo."
        else
            log_error "usermod failed; docker group membership not granted"
            MODULE_FAILED=1
        fi
    fi
else
    log_warn "docker group does not exist; skipping group membership"
fi

(( MODULE_FAILED )) && return 1
return 0
