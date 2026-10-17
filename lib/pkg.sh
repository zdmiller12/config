# shellcheck shell=bash
# Snap installation. Same per-package failure tolerance as apt.

PKG_FAILED=()

pkg_snap_available() { command -v snap > /dev/null 2>&1; }

# pkg_snap_install SPEC... — SPEC is a snap name plus optional flags.
pkg_snap_install() {
    (( $# )) || return 0
    if ! pkg_snap_available; then
        log_warn "snap is not available; skipping: $*"
        return 0
    fi
    local spec name flags
    for spec in "$@"; do
        read -r name flags <<< "$spec"
        if snap list "$name" > /dev/null 2>&1; then
            log_info "snap already installed: $name"
            continue
        fi
        # Word splitting on $flags is intentional.
        # shellcheck disable=SC2086
        if ! run_sudo snap install "$name" $flags; then
            PKG_FAILED+=("$name")
            log_error "snap failed: $name"
        fi
    done
    return 0
}

# pkg_snap_connect SNAP INTERFACE
# In `snap connections` output, column 3 is the slot: "-" means disconnected.
pkg_snap_connect() {
    local snap=$1 iface=$2
    if ! pkg_snap_available; then
        log_warn "snap is not available; skipping: $snap:$iface"
        return 0
    fi
    if snap connections "$snap" 2> /dev/null \
        | awk -v i="$iface" '$1 == i && $3 != "-" { found = 1 } END { exit !found }'; then
        log_info "$snap:$iface is already connected"
        return 0
    fi
    run_sudo snap connect "$snap:$iface"
}
