#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib patch
    load_lib apt
    load_lib pkg
    load_lib module
    RUN_STAMP="test"
    DRY_RUN=1
    MODULES_DIR="$TMPTEST/modules"
    LOCAL_ENV="$TMPTEST/local.env"
    mkdir -p "$MODULES_DIR"
}
teardown() { teardown_tmpdir; }

# Create a module: mkmod NAME [REQUIRES]
mkmod() {
    local name=$1 requires=${2:-}
    mkdir -p "$MODULES_DIR/$name"
    {
        printf 'name=%s\n' "$name"
        printf 'summary=The %s module\n' "$name"
        printf 'default=on\n'
        if [[ -n $requires ]]; then
            printf 'requires=%s\n' "$requires"
        fi
    } > "$MODULES_DIR/$name/meta"
}

@test "manifest_read strips comments, blanks, and surrounding whitespace" {
    cat > m <<'EOF'
# a comment

  git
curl

   # indented comment
  gh
EOF
    run_out="$(manifest_read m)"
    [ "$run_out" = "git
curl
gh" ]
}

@test "manifest_read preserves an inline hash inside a line" {
    printf 'deb https://example.invalid/apt stable main # not-a-comment\n' > m
    run_out="$(manifest_read m)"
    [[ $run_out == *"# not-a-comment"* ]]
}

@test "manifest_read is silent for a missing file" {
    run_out="$(manifest_read does-not-exist)"
    [ -z "$run_out" ]
}

@test "module_meta_get reads a key" {
    mkmod 00-core
    [ "$(module_meta_get "$MODULES_DIR/00-core" default)" = "on" ]
}

@test "module_meta_get prints nothing for an absent key" {
    mkmod 00-core
    [ -z "$(module_meta_get "$MODULES_DIR/00-core" requires)" ]
}

@test "module_list finds every module with a meta file, sorted" {
    mkmod 50-media
    mkmod 00-core
    mkdir -p "$MODULES_DIR/not-a-module"
    run_out="$(module_list)"
    [ "$run_out" = "00-core
50-media" ]
}

@test "module_resolve_order sorts by directory prefix" {
    mkmod 00-core
    mkmod 50-media
    mkmod 10-shell
    module_resolve_order 50-media 00-core 10-shell
    [ "${MODULE_ORDER[0]}" = "00-core" ]
    [ "${MODULE_ORDER[1]}" = "10-shell" ]
    [ "${MODULE_ORDER[2]}" = "50-media" ]
}

@test "module_resolve_order pulls in a requirement that was not selected" {
    mkmod 00-core
    mkmod 10-shell 00-core
    mkmod 20-toolchains 10-shell
    module_resolve_order 20-toolchains
    [ "${#MODULE_ORDER[@]}" -eq 3 ]
    [ "${MODULE_ORDER[0]}" = "00-core" ]
    [ "${MODULE_ORDER[2]}" = "20-toolchains" ]
}

@test "module_resolve_order places a dependency before its dependent" {
    mkmod 00-core
    mkmod 90-late 00-core
    module_resolve_order 90-late 00-core
    [ "${MODULE_ORDER[0]}" = "00-core" ]
}

@test "module_resolve_order detects a dependency cycle" {
    mkmod a b
    mkmod b a
    status=0
    module_resolve_order a || status=$?
    [ "$status" -ne 0 ]
}

@test "module_resolve_order rejects an unknown module" {
    mkmod 00-core
    status=0
    module_resolve_order nonexistent || status=$?
    [ "$status" -ne 0 ]
}

@test "localenv_set creates the file at mode 0600" {
    DRY_RUN=0
    localenv_set GIT_NAME "Test User"
    [ -f "$LOCAL_ENV" ]
    [ "$(stat -c '%a' "$LOCAL_ENV")" = "600" ]
}

@test "localenv_set and localenv_load round-trip a value" {
    DRY_RUN=0
    localenv_set NAS_HOST "nas.local"
    unset NAS_HOST
    localenv_load
    [ "$NAS_HOST" = "nas.local" ]
}

@test "localenv_set replaces rather than duplicating a key" {
    DRY_RUN=0
    localenv_set NAS_HOST "first"
    localenv_set NAS_HOST "second"
    [ "$(grep -c '^NAS_HOST=' "$LOCAL_ENV")" -eq 1 ]
    unset NAS_HOST
    localenv_load
    [ "$NAS_HOST" = "second" ]
}

@test "localenv_set preserves other keys" {
    DRY_RUN=0
    localenv_set GIT_NAME "Test User"
    localenv_set NAS_HOST "nas.local"
    unset GIT_NAME NAS_HOST
    localenv_load
    [ "$GIT_NAME" = "Test User" ]
    [ "$NAS_HOST" = "nas.local" ]
}

@test "localenv_set handles a value containing spaces" {
    DRY_RUN=0
    localenv_set GIT_NAME "First Last"
    unset GIT_NAME
    localenv_load
    [ "$GIT_NAME" = "First Last" ]
}

@test "module_run installs the apt manifest" {
    mkmod 00-core
    printf 'git\ncurl\n' > "$MODULES_DIR/00-core/apt"
    output="$(module_run 00-core 2>&1)"
    [[ $output == *"apt-get install -y git curl"* ]]
}

@test "module_run registers repos before installing" {
    mkmod 30-dev
    printf 'example|https://example.invalid/key.asc|deb [signed-by=@KEYRING@] https://example.invalid/apt stable main\n' \
        > "$MODULES_DIR/30-dev/repos"
    printf 'code\n' > "$MODULES_DIR/30-dev/apt"
    output="$(module_run 30-dev 2>&1)"
    repo_line=$(printf '%s\n' "$output" | grep -n 'example.invalid' | head -1 | cut -d: -f1)
    install_line=$(printf '%s\n' "$output" | grep -n 'apt-get install' | head -1 | cut -d: -f1)
    [ "$repo_line" -lt "$install_line" ]
}

@test "module_run sources setup.sh with MODULE_DIR set" {
    mkmod 10-shell
    printf 'printf "setup ran in %%s\\n" "$(basename "$MODULE_DIR")"\n' \
        > "$MODULES_DIR/10-shell/setup.sh"
    output="$(module_run 10-shell 2>&1)"
    [[ $output == *"setup ran in 10-shell"* ]]
}

@test "module_run contains a failing setup.sh" {
    mkmod 40-desktop
    printf 'exit 3\n' > "$MODULES_DIR/40-desktop/setup.sh"
    status=0
    module_run 40-desktop > /dev/null 2>&1 || status=$?
    [ "$status" -eq 0 ]
    printf '%s\n' "${SUMMARY_ROWS[@]}" | grep -q '^failed|40-desktop'
}

@test "module_run records success in the summary" {
    mkmod 00-core
    printf 'git\n' > "$MODULES_DIR/00-core/apt"
    module_run 00-core > /dev/null 2>&1
    printf '%s\n' "${SUMMARY_ROWS[@]}" | grep -q '00-core'
}
