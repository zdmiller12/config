#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    DOTFILES_NO_MAIN=1
    export DOTFILES_NO_MAIN
    load_lib log
    load_lib link
    load_lib ui
    RUN_STAMP="test"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles.sh"
    DRY_RUN=0
    ASSUME_YES=0
    LINK_FORCE=0
    SUBCOMMAND=status
    TARGETS=()
    # Point the CLI at a scratch repo so no test can touch the real
    # dotfiles/ tree or the real $HOME.
    DOTFILES_DIR="$TMPTEST/dotfiles"
    MANIFEST="$DOTFILES_DIR/links"
    HOME="$TMPTEST/fakehome"
    mkdir -p "$DOTFILES_DIR" "$HOME"
    : > "$MANIFEST"
}
teardown() { teardown_tmpdir; }

@test "parse_args defaults to status with no arguments" {
    parse_args
    [ "$SUBCOMMAND" = status ]
    [ "$DRY_RUN" -eq 0 ]
    [ "$LINK_FORCE" -eq 0 ]
    [ "${#TARGETS[@]}" -eq 0 ]
}

@test "parse_args accepts each subcommand" {
    parse_args status
    [ "$SUBCOMMAND" = status ]
    parse_args link
    [ "$SUBCOMMAND" = link ]
    parse_args adopt
    [ "$SUBCOMMAND" = adopt ]
}

@test "parse_args rejects an unknown subcommand" {
    status=0
    parse_args bogus || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args rejects an unknown option" {
    status=0
    parse_args link --nope || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args collects flags and targets" {
    parse_args link --force --dry-run "$HOME/.one.conf"
    [ "$SUBCOMMAND" = link ]
    [ "$LINK_FORCE" -eq 1 ]
    [ "$DRY_RUN" -eq 1 ]
    [ "${TARGETS[0]}" = "$HOME/.one.conf" ]
}

@test "parse_args returns 10 for help" {
    status=0
    parse_args --help || status=$?
    [ "$status" -eq 10 ]
}

@test "usage names every subcommand" {
    status=0
    output="$(usage 2>&1)" || status=$?
    [[ $output == *status* ]]
    [[ $output == *link* ]]
    [[ $output == *adopt* ]]
}

@test "dotfiles_tildify abbreviates a path under HOME" {
    [ "$(dotfiles_tildify "$HOME/.one.conf")" = "~/.one.conf" ]
}

@test "dotfiles_tildify leaves a path outside HOME alone" {
    [ "$(dotfiles_tildify /etc/hosts)" = "/etc/hosts" ]
}

@test "dotfiles_tildify abbreviates HOME itself" {
    [ "$(dotfiles_tildify "$HOME")" = "~" ]
}

@test "status reports linked and exits zero when everything is linked" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *linked* ]]
    [[ $output == *"~/.one.conf"* ]]
}

@test "status reports missing and exits non-zero" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *missing* ]]
}

@test "status reports unlinked for an identical real file" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'content\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *unlinked* ]]
}

@test "status reports DIVERGED for a differing real file" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'other\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *DIVERGED* ]]
}

@test "status reports BROKEN for a manifest entry with no repo file" {
    printf 'absent.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *BROKEN* ]]
}

@test "status lists repo files no manifest entry references" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    mkdir -p "$DOTFILES_DIR/ssh"
    printf 'template\n' > "$DOTFILES_DIR/ssh/config.template"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [[ $output == *"ssh/config.template"* ]]
}

@test "status untracked files do not affect the exit status" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'orphan\n' > "$DOTFILES_DIR/orphan.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *orphan.conf* ]]
}

@test "status does not list the manifest itself as untracked" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [[ $output != *"  links"* ]]
}

@test "status completes when called directly on a fully linked manifest" {
    # Direct invocation on the all-linked case, the only state returning 0.
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    cmd_status > /dev/null
}

@test "status completes when called directly with an unreferenced repo file" {
    # Exercises cmd_status_untracked's array handling: an empty `referenced`
    # array under `set -u` is a classic abort.
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'orphan\n' > "$DOTFILES_DIR/orphan.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    cmd_status > /dev/null
}
