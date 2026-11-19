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

@test "link makes no removal in the unlinked path during a dry run" {
    # The unlinked arm is the only place cmd_link REMOVES anything (it clears
    # the destination before relinking so link_file writes no pointless .bak-
    # copy). That removal goes through the `run` wrapper, so a dry run must
    # leave the identical live file exactly where it is. The other dry-run
    # test covers `missing`, where nothing is removed — so without this one, a
    # future edit swapping `run rm -f` for a bare `rm` would pass the suite.
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'content\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    DRY_RUN=1
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ -f "$HOME/.one.conf" ]
    [ ! -L "$HOME/.one.conf" ]
    [ "$(cat "$HOME/.one.conf")" = content ]
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

@test "infer strips the ~/.config prefix" {
    [ "$(dotfiles_infer_repo_path "$HOME/.config/fish/functions/usd.fish")" = "fish/functions/usd.fish" ]
}

@test "infer groups a dotfile with an extension under its stem" {
    [ "$(dotfiles_infer_repo_path "$HOME/.tmux.conf")" = "tmux/tmux.conf" ]
}

@test "infer puts an extensionless dotfile at the top level" {
    [ "$(dotfiles_infer_repo_path "$HOME/.gitconfig")" = "gitconfig" ]
    [ "$(dotfiles_infer_repo_path "$HOME/.bashrc")" = "bashrc" ]
}

@test "infer handles a path outside HOME" {
    [ "$(dotfiles_infer_repo_path /etc/someapp.conf)" = "someapp/someapp.conf" ]
}

@test "infer handles a non-dot file under HOME" {
    [ "$(dotfiles_infer_repo_path "$HOME/notes.txt")" = "notes/notes.txt" ]
}

@test "infer returns zero when called directly" {
    # Direct invocations: assert the function returns 0 for each rule branch.
    dotfiles_infer_repo_path "$HOME/.config/fish/config.fish" > /dev/null
    dotfiles_infer_repo_path "$HOME/.tmux.conf" > /dev/null
    dotfiles_infer_repo_path "$HOME/.gitconfig" > /dev/null
}

@test "adopt moves a new file into the repo, links it, and records it" {
    printf 'live content\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = "live content" ]
    [ "$(cat "$HOME/.one.conf")" = "live content" ]
    # Assert the parsed entry, not two substrings. `grep -q` on each field
    # separately would pass even with no separator between them, which is
    # exactly the corruption this file is prone to.
    mapfile -t entries < <(link_manifest_entries "$MANIFEST" 2>/dev/null)
    [ "${#entries[@]}" -eq 1 ]
    [ "${entries[0]}" = "$(printf 'one/one.conf\t%s/.one.conf' "$HOME")" ]
}

@test "adopt appends the manifest entry with the repo's column alignment" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    cmd_adopt
    status=0
    output="$(grep 'one/one.conf' "$MANIFEST" 2>&1)" || status=$?
    [ "$output" = "$(printf '%-29s %s' 'one/one.conf' '~/.one.conf')" ]
}

@test "adopt keeps a long repo path parseable in the manifest" {
    # Regression: %-30s%s emits NO separator once the path reaches 30 chars,
    # so the entry parses as having no destination and the adopted file
    # silently stops being linked. 38 chars here.
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "fish/functions/a-rather-long-name.fish")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    mapfile -t entries < <(link_manifest_entries "$MANIFEST" 2>/dev/null)
    [ "${#entries[@]}" -eq 1 ]
    [ "${entries[0]}" = "$(printf 'fish/functions/a-rather-long-name.fish\t%s/.one.conf' "$HOME")" ]
}

@test "adopt writes a tilde rather than an expanded HOME" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    cmd_adopt
    ! grep -q "$HOME" "$MANIFEST"
}

@test "adopt is idempotent on an already adopted file" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    cmd_adopt
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *"already linked"* ]]
    [ "$(grep -c 'one/one.conf' "$MANIFEST")" -eq 1 ]
}

@test "adopt overwrites a differing repo file so local wins" {
    # git init so dotfiles_is_dirty takes its real "git repo, path clean"
    # path rather than the "not a git repo at all" early return. Both answer
    # "not dirty", so without this the clean-path branch is never exercised.
    git init -q "$TMPTEST/gitrepo"
    REPO_ROOT="$TMPTEST/gitrepo"
    DOTFILES_DIR="$REPO_ROOT/dotfiles"
    MANIFEST="$DOTFILES_DIR/links"
    mkdir -p "$DOTFILES_DIR/one"
    printf 'repo\n' > "$DOTFILES_DIR/one/one.conf"
    : > "$MANIFEST"
    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" -c user.email=t@example.com -c user.name=t commit -q -m init
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = live ]
    [ -L "$HOME/.one.conf" ]
}

@test "adopt links an identical repo file without touching its content" {
    mkdir -p "$DOTFILES_DIR/one"
    printf 'same\n' > "$DOTFILES_DIR/one/one.conf"
    printf 'same\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = same ]
    [ -L "$HOME/.one.conf" ]
}

@test "adopt uses the inferred path when none is given" {
    printf 'live\n' > "$HOME/.tmux.conf"
    TARGETS=("$HOME/.tmux.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -f "$DOTFILES_DIR/tmux/tmux.conf" ]
}

@test "adopt dereferences a live symlink so the repo gets real content" {
    # Guards against `cp -a`, which preserves the link and would commit a
    # symlink to an absolute path outside the repo. cmp cannot detect this
    # (it dereferences), so the assertion is on the file type directly.
    mkdir -p "$TMPTEST/elsewhere"
    printf 'external\n' > "$TMPTEST/elsewhere/real.conf"
    ln -s "$TMPTEST/elsewhere/real.conf" "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ ! -L "$DOTFILES_DIR/one/one.conf" ]
    [ -f "$DOTFILES_DIR/one/one.conf" ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = external ]
}

@test "adopt refuses a repo path that escapes dotfiles/" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "../escaped.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
    [ ! -e "$DOTFILES_DIR/../escaped.conf" ]
    # The live file must survive a refusal untouched.
    [ -f "$HOME/.one.conf" ]
    [ ! -L "$HOME/.one.conf" ]
}

@test "adopt trims a trailing slash from the repo path" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    # Without the trim, cp would copy INTO dotfiles/one/ under the live
    # basename and the manifest would record "one/" as the entry.
    [ -f "$DOTFILES_DIR/one" ]
    [ ! -d "$DOTFILES_DIR/one" ]
    grep -q '^one  *~/\.one\.conf$' "$MANIFEST"
}

@test "adopt refuses every traversal form the guard lists" {
    # The guard's case has five arms; two were covered. A regression dropping
    # any single arm would otherwise go unnoticed, and this one is a guard
    # against writing outside the repo, so partial coverage is the wrong
    # trade. ".." bare, mid-path, and trailing are the three untested arms.
    printf 'live\n' > "$HOME/.one.conf"
    for bad in ".." "one/../../escaped.conf" "one/.."; do
        TARGETS=("$HOME/.one.conf" "$bad")
        status=0
        output="$(cmd_adopt 2>&1)" || status=$?
        [ "$status" -eq 2 ]
        [ -f "$HOME/.one.conf" ]
        [ ! -L "$HOME/.one.conf" ]
    done
    # A legitimate name merely containing ".." must still be accepted.
    TARGETS=("$HOME/.one.conf" "weird..name.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -f "$DOTFILES_DIR/weird..name.conf" ]
}

@test "adopt refuses an absolute repo path" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "$TMPTEST/escaped.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
    [ ! -e "$TMPTEST/escaped.conf" ]
    [ -f "$HOME/.one.conf" ]
}

@test "adopt rejects a directory" {
    mkdir -p "$HOME/.somedir"
    TARGETS=("$HOME/.somedir")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
    [[ $output == *director* ]]
}

@test "adopt rejects a path that does not exist" {
    TARGETS=("$HOME/.absent.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
}

@test "adopt requires a path" {
    TARGETS=()
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
}

@test "adopt refuses when the repo file has uncommitted changes" {
    git init -q "$TMPTEST/gitrepo"
    REPO_ROOT="$TMPTEST/gitrepo"
    DOTFILES_DIR="$REPO_ROOT/dotfiles"
    MANIFEST="$DOTFILES_DIR/links"
    mkdir -p "$DOTFILES_DIR/one"
    printf 'committed\n' > "$DOTFILES_DIR/one/one.conf"
    : > "$MANIFEST"
    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" -c user.email=t@example.com -c user.name=t commit -q -m init
    printf 'unreviewed repo edit\n' > "$DOTFILES_DIR/one/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = "unreviewed repo edit" ]
    [ "$(cat "$HOME/.one.conf")" = live ]
    [[ $output == *--force* ]]
}

@test "adopt --force overwrites an uncommitted repo file" {
    git init -q "$TMPTEST/gitrepo"
    REPO_ROOT="$TMPTEST/gitrepo"
    DOTFILES_DIR="$REPO_ROOT/dotfiles"
    MANIFEST="$DOTFILES_DIR/links"
    mkdir -p "$DOTFILES_DIR/one"
    printf 'committed\n' > "$DOTFILES_DIR/one/one.conf"
    : > "$MANIFEST"
    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" -c user.email=t@example.com -c user.name=t commit -q -m init
    printf 'unreviewed repo edit\n' > "$DOTFILES_DIR/one/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    LINK_FORCE=1
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = live ]
}

@test "adopt changes nothing during a dry run" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    DRY_RUN=1
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ ! -e "$DOTFILES_DIR/one/one.conf" ]
    [ ! -L "$HOME/.one.conf" ]
    [ "$(cat "$HOME/.one.conf")" = live ]
    [ ! -s "$MANIFEST" ]
}
