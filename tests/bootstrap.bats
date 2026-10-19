#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    BOOTSTRAP_NO_MAIN=1
    export BOOTSTRAP_NO_MAIN
    # preflight calls log_error, and bootstrap.sh only sources the libraries
    # inside main() — which BOOTSTRAP_NO_MAIN suppresses. Load log.sh first.
    load_lib log
    # select_modules needs module.sh (manifest/order/localenv) and ui.sh
    # (the checklist fallback); loaded here so tests can call it directly.
    load_lib module
    load_lib ui
    RUN_STAMP="test"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bootstrap.sh"
    DRY_RUN=0
    ASSUME_YES=0
    RECONFIGURE=0
    ONLY_MODULES=()
    SKIP_MODULES=()
    # Point select_modules at a scratch module tree and a scratch
    # local-env file instead of the real $HOME, so these tests cannot
    # read or write the machine's actual saved module selection.
    MODULES_DIR="$TMPTEST/modules"
    LOCAL_ENV="$TMPTEST/local.env"
    mkdir -p "$MODULES_DIR"
}
teardown() { teardown_tmpdir; }

@test "parse_args defaults to a live, interactive run" {
    parse_args
    [ "$DRY_RUN" -eq 0 ]
    [ "$ASSUME_YES" -eq 0 ]
    [ "$RECONFIGURE" -eq 0 ]
}

@test "parse_args handles --dry-run" {
    parse_args --dry-run
    [ "$DRY_RUN" -eq 1 ]
}

@test "parse_args handles --yes and -y" {
    parse_args --yes
    [ "$ASSUME_YES" -eq 1 ]
    ASSUME_YES=0
    parse_args -y
    [ "$ASSUME_YES" -eq 1 ]
}

@test "parse_args handles --reconfigure" {
    parse_args --reconfigure
    [ "$RECONFIGURE" -eq 1 ]
}

@test "parse_args accumulates repeated --only" {
    parse_args --only 00-core --only 50-media
    [ "${#ONLY_MODULES[@]}" -eq 2 ]
    [ "${ONLY_MODULES[0]}" = "00-core" ]
    [ "${ONLY_MODULES[1]}" = "50-media" ]
}

@test "parse_args accumulates repeated --skip" {
    parse_args --skip 40-desktop --skip 50-media
    [ "${#SKIP_MODULES[@]}" -eq 2 ]
}

@test "parse_args combines flags" {
    parse_args --dry-run --yes --only 00-core
    [ "$DRY_RUN" -eq 1 ]
    [ "$ASSUME_YES" -eq 1 ]
    [ "${ONLY_MODULES[0]}" = "00-core" ]
}

@test "parse_args rejects an unknown option" {
    status=0
    parse_args --nonsense 2>/dev/null || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args rejects --only with no value" {
    status=0
    parse_args --only 2>/dev/null || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args rejects --skip with no value" {
    status=0
    parse_args --skip 2>/dev/null || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args returns 10 for --help" {
    status=0
    parse_args --help > /dev/null 2>&1 || status=$?
    [ "$status" -eq 10 ]
}

@test "preflight refuses to run as root" {
    # EUID is readonly in bash, so preflight reads BOOTSTRAP_UID as an
    # override seam. Verified: `EUID=0` fails with "readonly variable".
    BOOTSTRAP_UID=0
    status=0
    preflight 2>/dev/null || status=$?
    [ "$status" -ne 0 ]
}

@test "preflight passes for a normal user on a Debian-family system" {
    BOOTSTRAP_UID=1000
    preflight > /dev/null 2>&1
}

@test "select_modules keeps 00-core when --skip targets it, but still drops another module" {
    mkdir -p "$MODULES_DIR/00-core" "$MODULES_DIR/10-other"
    cat > "$MODULES_DIR/00-core/meta" <<'EOF'
name=00-core
summary=Core
default=on
EOF
    cat > "$MODULES_DIR/10-other/meta" <<'EOF'
name=10-other
summary=Other
default=on
EOF
    ASSUME_YES=1
    SKIP_MODULES=(00-core 10-other)
    select_modules

    local found_core=0 found_other=0 m
    for m in "${MODULE_ORDER[@]}"; do
        [[ $m == 00-core ]] && found_core=1
        [[ $m == 10-other ]] && found_other=1
    done
    [ "$found_core" -eq 1 ]
    [ "$found_other" -eq 0 ]
}

@test "sudo_validate under dry-run invokes no sudo" {
    DRY_RUN=1
    sudo() { echo "SUDO CALLED" >&2; return 1; }
    local out
    out=$(sudo_validate 2>&1)
    [[ $out != *"SUDO CALLED"* ]]
}

@test "prompts are collected strictly before any installation" {
    local out prompt_line install_line
    out=$(BOOTSTRAP_NO_MAIN=0 bash "$REPO_ROOT/bootstrap.sh" --dry-run --yes 2>&1)
    prompt_line=$(printf '%s\n' "$out" | grep -n "Collecting answers up front" | head -1 | cut -d: -f1)
    install_line=$(printf '%s\n' "$out" | grep -n '\[DRY\] sudo apt-get' | head -1 | cut -d: -f1)
    [ -n "$prompt_line" ]
    [ -n "$install_line" ]
    [ "$prompt_line" -lt "$install_line" ]
}
