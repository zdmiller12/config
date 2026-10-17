#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    RUN_STAMP="test"
    LOG_FILE="$TMPTEST/run.log"
    : > "$LOG_FILE"
}
teardown() { teardown_tmpdir; }

@test "run executes the command when DRY_RUN is 0" {
    DRY_RUN=0
    run touch made-it
    [ -f made-it ]
}

@test "run does not execute the command when DRY_RUN is 1" {
    DRY_RUN=1
    run touch should-not-exist
    [ ! -e should-not-exist ]
}

@test "run reports the command it skipped during a dry run" {
    DRY_RUN=1
    output="$(run touch nope 2>&1)"
    [[ $output == *"touch nope"* ]]
}

@test "run propagates the command's exit status" {
    DRY_RUN=0
    run_status=0
    run false || run_status=$?
    [ "$run_status" -eq 1 ]
}

@test "run_sudo prefixes sudo" {
    DRY_RUN=1
    output="$(run_sudo apt-get install foo 2>&1)"
    [[ $output == *"sudo apt-get install foo"* ]]
}

@test "log messages are appended to the transcript" {
    log_info "hello transcript"
    grep -q "hello transcript" "$LOG_FILE"
}

@test "summary_print reports failures and returns non-zero" {
    summary_add ok 00-core
    summary_add failed 40-desktop "brave"
    status=0
    output="$(summary_print)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *"40-desktop"* ]]
    [[ $output == *"brave"* ]]
}

@test "summary_print returns zero when nothing failed" {
    summary_add ok 00-core
    summary_add changed 10-shell
    status=0
    summary_print >/dev/null || status=$?
    [ "$status" -eq 0 ]
}

@test "summary_note surfaces manual follow-ups" {
    summary_note "Add the SSH key to GitHub"
    output="$(summary_print)"
    [[ $output == *"Add the SSH key to GitHub"* ]]
}
