#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    BOOTSTRAP_NO_MAIN=1
    export BOOTSTRAP_NO_MAIN
    # preflight calls log_error, and bootstrap.sh only sources the libraries
    # inside main() — which BOOTSTRAP_NO_MAIN suppresses. Load log.sh first.
    load_lib log
    RUN_STAMP="test"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bootstrap.sh"
    DRY_RUN=0
    ASSUME_YES=0
    RECONFIGURE=0
    ONLY_MODULES=()
    SKIP_MODULES=()
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
