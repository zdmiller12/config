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
    # Seed a genuine orphan so the untracked section is guaranteed non-empty.
    # Without this the negative assertion below passes even against a stub
    # that prints nothing at all, which is how it slipped through red->green.
    printf 'orphan\n' > "$DOTFILES_DIR/orphan.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [[ $output == *"orphan.conf"* ]]
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
    # Exercises cmd_status_untracked's find/compare loop with a repo file that
    # no manifest entry names. (The empty-`referenced` case is a different
    # scenario — this manifest has an entry — and is covered by the
    # "${referenced[@]:-}" guard rather than by this test.)
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'orphan\n' > "$DOTFILES_DIR/orphan.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    cmd_status > /dev/null
}

@test "link creates a symlink for a missing destination" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
}

@test "link converts an identical real file without a backup" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'content\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
    [ -z "$(find "$HOME" -name '*.bak-*' -print -quit)" ]
}

@test "link refuses a divergent file and leaves both sides untouched" {
    printf 'repo\n' > "$DOTFILES_DIR/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [ ! -L "$HOME/.one.conf" ]
    [ "$(cat "$HOME/.one.conf")" = live ]
    [ "$(cat "$DOTFILES_DIR/one.conf")" = repo ]
}

@test "link prints a diff for a divergent file" {
    printf 'repo\n' > "$DOTFILES_DIR/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [[ $output == *"-repo"* ]]
    [[ $output == *"+live"* ]]
}

@test "link --force backs up the live file and logs the backup path" {
    printf 'repo\n' > "$DOTFILES_DIR/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    LINK_FORCE=1
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
    [ "$(cat "$HOME/.one.conf.bak-test")" = live ]
    [[ $output == *".bak-test"* ]]
}

@test "link is a no-op on an already linked entry" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *"already linked"* ]]
}

@test "link scoped to a destination leaves other entries alone" {
    printf 'one\n' > "$DOTFILES_DIR/one.conf"
    printf 'two\n' > "$DOTFILES_DIR/two.conf"
    printf 'one.conf  ~/.one.conf\ntwo.conf  ~/.two.conf\n' > "$MANIFEST"
    TARGETS=("$HOME/.one.conf")
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
    [ ! -e "$HOME/.two.conf" ]
}

@test "link scoped by repo-relative path also matches" {
    printf 'one\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    TARGETS=("one.conf")
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
}

@test "link errors when a target matches no manifest entry" {
    printf 'one\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    TARGETS=("$HOME/.typo.conf")
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 2 ]
    [[ $output == *".typo.conf"* ]]
}

@test "link reports a broken manifest entry and exits non-zero" {
    printf 'absent.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/.one.conf" ]
}

@test "link changes nothing during a dry run" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    DRY_RUN=1
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ ! -e "$HOME/.one.conf" ]
}

@test "link completes when called directly" {
    # Direct invocation of the unscoped, link-everything path, which
    # exercises the empty-TARGETS array read under set -u.
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    TARGETS=()
    cmd_link > /dev/null
    [ -L "$HOME/.one.conf" ]
}

@test "link completes when called directly with a scoped target" {
    # The scoped path has its own array loops (matched, TARGETS) and its own
    # post-loop verification pass; both need a direct invocation.
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    TARGETS=("$HOME/.one.conf")
    cmd_link > /dev/null
    [ -L "$HOME/.one.conf" ]
}
