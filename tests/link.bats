#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib link
    RUN_STAMP="test"
    DRY_RUN=0
    mkdir -p repo dest
    printf 'source content\n' > repo/file.conf
}
teardown() { teardown_tmpdir; }

@test "link_file creates a symlink" {
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ -L "$TMPTEST/dest/file.conf" ]
    [ "$(cat "$TMPTEST/dest/file.conf")" = "source content" ]
    [ "$LINK_RESULT" = changed ]
}

@test "link_file creates missing parent directories" {
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/deep/a/b/file.conf"
    [ -L "$TMPTEST/deep/a/b/file.conf" ]
}

@test "link_file is a no-op when the correct symlink already exists" {
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ "$LINK_RESULT" = unchanged ]
}

@test "link_file backs up a pre-existing regular file" {
    printf 'user data\n' > "$TMPTEST/dest/file.conf"
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ -L "$TMPTEST/dest/file.conf" ]
    [ "$(cat "$TMPTEST/dest/file.conf.bak-test")" = "user data" ]
}

@test "link_file replaces a symlink pointing somewhere else without a backup" {
    printf 'other\n' > "$TMPTEST/repo/other.conf"
    ln -s "$TMPTEST/repo/other.conf" "$TMPTEST/dest/file.conf"
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ "$(cat "$TMPTEST/dest/file.conf")" = "source content" ]
    [ ! -e "$TMPTEST/dest/file.conf.bak-test" ]
}

@test "link_file fails when the source is missing" {
    status=0
    link_file "$TMPTEST/repo/absent.conf" "$TMPTEST/dest/x.conf" || status=$?
    [ "$status" -ne 0 ]
}

@test "link_file changes nothing during a dry run" {
    DRY_RUN=1
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ ! -e "$TMPTEST/dest/file.conf" ]
}

@test "link_manifest links every entry and skips comments and blanks" {
    printf 'second\n' > repo/second.conf
    cat > links <<EOF
# a comment
file.conf    $TMPTEST/dest/one.conf

second.conf  $TMPTEST/dest/two.conf
EOF
    link_manifest links "$TMPTEST/repo"
    [ -L "$TMPTEST/dest/one.conf" ]
    [ -L "$TMPTEST/dest/two.conf" ]
}

@test "link_manifest expands a leading tilde in the destination" {
    HOME="$TMPTEST/fakehome"
    mkdir -p "$HOME"
    printf 'file.conf  ~/.config/app/file.conf\n' > links
    link_manifest links "$TMPTEST/repo"
    [ -L "$TMPTEST/fakehome/.config/app/file.conf" ]
}

@test "link_file sets LINK_RESULT=unchanged on error path" {
    # Successful call
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ "$LINK_RESULT" = changed ]
    # Failed call with missing source in same shell
    status=0
    link_file "$TMPTEST/repo/absent.conf" "$TMPTEST/dest/x.conf" || status=$?
    [ "$status" -ne 0 ]
    [ "$LINK_RESULT" = unchanged ]
}

@test "link_manifest handles final line without trailing newline" {
    printf 'second\n' > repo/second.conf
    # Deliberately construct manifest with final line lacking newline
    printf 'file.conf    %s/dest/one.conf\n' "$TMPTEST" > links
    printf 'second.conf  %s/dest/two.conf' "$TMPTEST" >> links
    link_manifest links "$TMPTEST/repo"
    [ -L "$TMPTEST/dest/one.conf" ]
    [ -L "$TMPTEST/dest/two.conf" ]
}

@test "the real dotfiles manifest references files that exist" {
    manifest="$REPO_ROOT/dotfiles/links"
    [ -f "$manifest" ]
    while read -r rel dest _; do
        [[ -z $rel || $rel == \#* ]] && continue
        [ -e "$REPO_ROOT/dotfiles/$rel" ] || {
            echo "manifest references a missing file: $rel"
            return 1
        }
        [ -n "$dest" ]
    done < "$manifest"
}
