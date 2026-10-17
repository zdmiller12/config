#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib ui
    RUN_STAMP="test"
    DRY_RUN=0
    ASSUME_YES=1
}
teardown() { teardown_tmpdir; }

@test "ui_checklist under --yes returns exactly the defaults that are on" {
    UI_ITEMS=(
        "00-core|Core build tooling|on"
        "60-nas|NAS mount|off"
        "50-media|Media tooling|on"
    )
    run_out="$(ui_checklist "Select modules")"
    [[ $run_out == *"00-core"* ]]
    [[ $run_out == *"50-media"* ]]
    [[ $run_out != *"60-nas"* ]]
}

@test "ui_checklist returns nothing when every default is off" {
    UI_ITEMS=("90-dualboot|Dual boot|off")
    run_out="$(ui_checklist "Select modules")"
    [ -z "$run_out" ]
}

@test "ui_prompt keeps an existing value" {
    GIT_NAME="Already Set"
    ui_prompt GIT_NAME "Your name" "Default Name"
    [ "$GIT_NAME" = "Already Set" ]
}

@test "ui_prompt takes the default when unset under --yes" {
    unset NAS_HOST
    ui_prompt NAS_HOST "NAS host" "nas.local"
    [ "$NAS_HOST" = "nas.local" ]
}

@test "ui_prompt leaves the value empty when there is no default" {
    unset NAS_KEY
    ui_prompt NAS_KEY "NAS key path" ""
    [ -z "$NAS_KEY" ]
}

@test "ui_pause returns immediately under --yes" {
    output="$(ui_pause "Add the key to GitHub" 2>&1)"
    [[ $output == *"Add the key to GitHub"* ]]
}

@test "ui_prompt is immune to lowercase variable-name collisions" {
    unset value
    ui_prompt value "prompt text" "the-default"
    [ "$value" = "the-default" ]
}
