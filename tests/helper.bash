# shellcheck shell=bash
# Shared setup for all bats test files.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
export REPO_ROOT

# Source an engine library by name, e.g. load_lib patch
load_lib() {
    local name=$1
    # Engine libraries assume these are set by bootstrap.sh.
    : "${DRY_RUN:=0}"
    export DRY_RUN
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/${name}.sh"
}

setup_tmpdir() {
    TMPTEST="$(mktemp -d)"
    export TMPTEST
    cd "$TMPTEST" || return 1
}

teardown_tmpdir() {
    cd / || return 0
    [[ -n ${TMPTEST:-} && -d $TMPTEST ]] && rm -rf "$TMPTEST"
    return 0
}
