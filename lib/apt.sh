# shellcheck shell=bash
# apt repository registration, coalesced cache refresh, and tolerant install.
# SOURCES_DIR and KEYRING_DIR are overridable so the unit tests can run
# without root.

: "${SOURCES_DIR:=/etc/apt/sources.list.d}"
: "${KEYRING_DIR:=/etc/apt/keyrings}"

APT_UPDATED=0
APT_FAILED=()

apt_mark_stale() { APT_UPDATED=0; }

apt_update_once() {
    (( APT_UPDATED )) && return 0
    run_sudo apt-get update -qq
    APT_UPDATED=1
}

# apt_add_repo NAME KEYRING_URL SOURCES_LINE
apt_add_repo() {
    local name=$1 key_url=$2 sources_line=$3
    local keyring="$KEYRING_DIR/$name.gpg"
    local list="$SOURCES_DIR/$name.list"

    [[ -d $KEYRING_DIR ]] || run_sudo install -d -m 0755 "$KEYRING_DIR"

    if [[ ! -f $keyring ]]; then
        if (( DRY_RUN )); then
            _log DRY '0;36' "fetch $key_url -> $keyring"
        else
            _log CMD '' "fetch keyring for $name"
            local tmp
            tmp=$(mktemp)
            if ! curl -fsSL "$key_url" -o "$tmp"; then
                log_error "could not download keyring for $name"
                rm -f "$tmp"
                return 1
            fi
            # Vendors are inconsistent: Microsoft and Docker publish an
            # ASCII-armored key, Brave publishes an already-binary keyring.
            # Dearmor only the former — doing it unconditionally corrupts
            # the latter.
            if head -c 64 "$tmp" | grep -q 'BEGIN PGP'; then
                # shellcheck disable=SC2024
                # The redirect is opened by us (we already own $tmp); sudo
                # only elevates gpg, which is what we want here.
                sudo gpg --dearmor -o "$keyring" < "$tmp"
            else
                sudo install -m 0644 "$tmp" "$keyring"
            fi
            rm -f "$tmp"
        fi
        apt_mark_stale
    fi

    sources_line=${sources_line//@KEYRING@/$keyring}
    patch_write_if_different "$list" "$sources_line"
    [[ $PATCH_RESULT == changed ]] && apt_mark_stale
    return 0
}

# apt_install PKG... — tolerates individual package failures.
apt_install() {
    (( $# )) || return 0
    apt_update_once
    if run_sudo apt-get install -y "$@"; then
        return 0
    fi
    log_warn "batch install failed; retrying individually to isolate the failure"
    local pkg
    for pkg in "$@"; do
        if ! run_sudo apt-get install -y "$pkg"; then
            APT_FAILED+=("$pkg")
            log_error "package failed: $pkg"
        fi
    done
    return 0
}
