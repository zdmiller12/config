#!/usr/bin/env bats

load helper

setup() { setup_tmpdir; }
teardown() { teardown_tmpdir; }

@test "helper exposes REPO_ROOT pointing at the repo" {
    [ -n "$REPO_ROOT" ]
    [ -f "$REPO_ROOT/README.md" ]
}

@test "setup_tmpdir creates an empty working directory" {
    [ -d "$TMPTEST" ]
    [ "$(pwd)" = "$TMPTEST" ]
    [ -z "$(ls -A "$TMPTEST")" ]
}
