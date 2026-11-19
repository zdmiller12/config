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

@test "link_state reports broken when the repo file is missing" {
    [ "$(link_state "$TMPTEST/repo/absent.conf" "$TMPTEST/dest/file.conf")" = broken ]
}

@test "link_state reports broken even when the destination exists" {
    printf 'whatever\n' > "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/absent.conf" "$TMPTEST/dest/file.conf")" = broken ]
}

@test "link_state reports missing when the destination does not exist" {
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = missing ]
}

@test "link_state reports linked for a symlink pointing at the repo file" {
    ln -s "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = linked ]
}

@test "link_state reports unlinked for a real file with identical content" {
    printf 'source content\n' > "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = unlinked ]
}

@test "link_state reports diverged for a real file with different content" {
    printf 'user data\n' > "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = diverged ]
}

@test "link_state reports diverged for a dangling symlink" {
    ln -s "$TMPTEST/repo/absent.conf" "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = diverged ]
}

@test "link_state reports diverged when the destination is a directory" {
    mkdir -p "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = diverged ]
}

@test "link_state returns zero when called directly" {
    # Direct, un-wrapped invocation: asserts link_state returns 0, which the
    # output-comparison tests above do not check independently.
    link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf" > /dev/null
}

@test "link_manifest_entries emits tab-separated entries and drops comments and blanks" {
    cat > links <<EOF
# a comment

file.conf    /tmp/one.conf
second.conf  /tmp/two.conf
EOF
    mapfile -t lines < <(link_manifest_entries links)
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "$(printf 'file.conf\t/tmp/one.conf')" ]
    [ "${lines[1]}" = "$(printf 'second.conf\t/tmp/two.conf')" ]
}

@test "link_manifest_entries expands a leading tilde" {
    HOME="$TMPTEST/fakehome"
    printf 'file.conf  ~/.config/app/file.conf\n' > links
    mapfile -t lines < <(link_manifest_entries links)
    [ "${lines[0]}" = "$(printf 'file.conf\t%s/.config/app/file.conf' "$TMPTEST/fakehome")" ]
}

@test "link_manifest_entries emits a final line with no trailing newline" {
    printf 'file.conf  /tmp/one.conf' > links
    mapfile -t lines < <(link_manifest_entries links)
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "$(printf 'file.conf\t/tmp/one.conf')" ]
}

@test "link_manifest_entries keeps a no-destination diagnostic out of the data stream" {
    printf 'orphan\nfile.conf  /tmp/one.conf\n' > links
    mapfile -t lines < <(link_manifest_entries links 2>/dev/null)
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "$(printf 'file.conf\t/tmp/one.conf')" ]
}

@test "link_manifest_entries reports a no-destination line on stderr" {
    printf 'orphan\nfile.conf  /tmp/one.conf\n' > links
    err="$(link_manifest_entries links 2>&1 > /dev/null)"
    [[ $err == *"manifest line has no destination: orphan"* ]]
}

@test "link_manifest does not build a phantom entry from a diagnostic" {
    # Regression for a real defect: log_error writes to stdout, so before the
    # >&2 redirect the error line was read back as an entry and link_file was
    # called with "$root/[ERROR] manifest line has no destination: orphan".
    printf 'orphan\nfile.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    status=0
    output="$(link_manifest links "$TMPTEST/repo" 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$TMPTEST/dest/one.conf" ]
    [[ $output != *"repo/[ERROR]"* ]]
}

@test "link_manifest_entries returns zero when called directly" {
    # Direct invocation: asserts the parser returns 0, which the mapfile tests
    # above cannot check (process substitution does not expose the producer's
    # status to $?). Uses the comment/blank/multi-entry manifest so the status
    # of that path is covered, not just a single valid line.
    cat > links <<EOF
# a comment

file.conf    /tmp/one.conf
second.conf  /tmp/two.conf
EOF
    link_manifest_entries links > /dev/null
}

@test "link_manifest links a missing destination" {
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ -L "$TMPTEST/dest/one.conf" ]
    [ "$LINK_SKIPPED" -eq 0 ]
}

@test "link_manifest leaves a divergent destination byte-for-byte alone" {
    printf 'user data\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ ! -L "$TMPTEST/dest/one.conf" ]
    [ "$(cat "$TMPTEST/dest/one.conf")" = "user data" ]
    [ "$LINK_SKIPPED" -eq 1 ]
}

@test "link_manifest skips an identical destination rather than converting it" {
    printf 'source content\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ ! -L "$TMPTEST/dest/one.conf" ]
    [ "$LINK_SKIPPED" -eq 1 ]
}

@test "link_manifest never creates a backup file" {
    printf 'user data\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ -z "$(find "$TMPTEST/dest" -name '*.bak-*' -print -quit)" ]
}

@test "link_manifest returns zero even when it skipped entries" {
    printf 'user data\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    status=0
    link_manifest links "$TMPTEST/repo" || status=$?
    [ "$status" -eq 0 ]
}

@test "link_manifest skip warning names both resolution commands" {
    HOME="$TMPTEST/fakehome"
    mkdir -p "$HOME"
    printf 'user data\n' > "$HOME/.one.conf"
    printf 'file.conf  ~/.one.conf\n' > links
    status=0
    output="$(link_manifest links "$TMPTEST/repo" 2>&1)" || status=$?
    [[ $output == *"not linked: a file already exists at ~/.one.conf"* ]]
    [[ $output == *"./dotfiles.sh adopt ~/.one.conf"* ]]
    [[ $output == *"./dotfiles.sh link --force ~/.one.conf"* ]]
}

@test "link_manifest reports a broken manifest entry without failing" {
    printf 'absent.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    status=0
    output="$(link_manifest links "$TMPTEST/repo" 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *"absent.conf"* ]]
    [ ! -e "$TMPTEST/dest/one.conf" ]
    # Discriminates correct `broken` routing from a regression that misroutes
    # it into the `missing` arm. That arm calls link_file, which would emit
    # its own "link source does not exist" message (swallowed by `|| true`),
    # and every assertion above would still pass.
    [[ $output != *"link source does not exist"* ]]
}

@test "link_manifest reports a missing manifest rather than looking like a clean run" {
    # The guard this covers is the highest-value defensive line in the
    # function: the process substitution opens the manifest in a subshell, so
    # without it an unreadable path yields zero iterations, no diagnostic, and
    # a successful return -- indistinguishable from a converged machine.
    status=0
    output="$(link_manifest "$TMPTEST/nonexistent-manifest" "$TMPTEST/repo" 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *"no dotfile manifest at"* ]]
    [[ $output == *"nonexistent-manifest"* ]]
    # Direct call: the capture above runs in a subshell, so LINK_SKIPPED set
    # inside it is not observable here.
    link_manifest "$TMPTEST/nonexistent-manifest" "$TMPTEST/repo" > /dev/null 2>&1
    [ "$LINK_SKIPPED" -eq 0 ]
}

@test "link_manifest counts skips fresh on each call" {
    printf 'user data\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ "$LINK_SKIPPED" -eq 1 ]
    rm -f "$TMPTEST/dest/one.conf"
    link_manifest links "$TMPTEST/repo"
    [ "$LINK_SKIPPED" -eq 0 ]
}
