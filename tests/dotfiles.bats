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
