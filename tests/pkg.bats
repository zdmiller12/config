#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib pkg
    RUN_STAMP="test"
    DRY_RUN=1
    PKG_FAILED=()
    # Stub snap so tests never touch the real snapd.
    mkdir -p "$TMPTEST/bin"
    cat > "$TMPTEST/bin/snap" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    # "installed-snap" exists; anything else does not.
    [[ ${2:-} == installed-snap ]] && exit 0
    exit 1
    ;;
  connections)
    printf 'Interface        Plug          Slot   Notes\n'
    printf 'removable-media  %s:removable-media  :removable-media  -\n' "${2:-x}"
    printf 'camera           %s:camera  -  -\n' "${2:-x}"
    ;;
esac
exit 0
STUB
    chmod +x "$TMPTEST/bin/snap"
    PATH="$TMPTEST/bin:$PATH"
}
teardown() { teardown_tmpdir; }

@test "pkg_snap_available is true when snap exists" {
    pkg_snap_available
}

@test "pkg_snap_install composes an install for a missing snap" {
    output="$(pkg_snap_install vlc 2>&1)"
    [[ $output == *"snap install vlc"* ]]
}

@test "pkg_snap_install passes through trailing flags" {
    output="$(pkg_snap_install "code --classic" 2>&1)"
    [[ $output == *"snap install code --classic"* ]]
}

@test "pkg_snap_install skips a snap that is already installed" {
    output="$(pkg_snap_install installed-snap 2>&1)"
    [[ $output != *"snap install installed-snap"* ]]
}

@test "pkg_snap_install handles several snaps" {
    output="$(pkg_snap_install vlc installed-snap 2>&1)"
    [[ $output == *"snap install vlc"* ]]
    [[ $output != *"snap install installed-snap"* ]]
}

@test "pkg_snap_connect skips an already connected interface" {
    output="$(pkg_snap_connect vlc removable-media 2>&1)"
    [[ $output != *"snap connect"* ]]
}

@test "pkg_snap_connect connects a disconnected interface" {
    output="$(pkg_snap_connect vlc camera 2>&1)"
    [[ $output == *"snap connect vlc:camera"* ]]
}

@test "pkg_snap_install isolates a failing snap and keeps installing the rest" {
    DRY_RUN=0
    mkdir -p "$TMPTEST/bin"
    CALLS_LOG="$TMPTEST/snap.calls"
    : > "$CALLS_LOG"
    export CALLS_LOG
    # Stub snap: list reports "installed-snap" as installed; install fails
    # for "badpkg" and succeeds for others. Every invocation is logged
    # so we can confirm the other snaps were still attempted.
    cat > "$TMPTEST/bin/snap" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    echo "$2" >> "$CALLS_LOG"
    [[ ${2:-} == installed-snap ]] && exit 0
    exit 1
    ;;
  install)
    echo "$*" >> "$CALLS_LOG"
    shift 1
    [[ $1 == badpkg ]] && exit 1
    exit 0
    ;;
  connections)
    printf 'Interface        Plug          Slot   Notes\n'
    printf 'removable-media  %s:removable-media  :removable-media  -\n' "${2:-x}"
    ;;
esac
exit 0
STUB
    chmod +x "$TMPTEST/bin/snap"
    PATH="$TMPTEST/bin:$PATH"
    sudo() { "$@"; }

    local result
    pkg_snap_install git badpkg curl
    result=$?

    [ "$result" -eq 0 ]
    [ "${#PKG_FAILED[@]}" -eq 1 ]
    [[ "${PKG_FAILED[0]}" == "badpkg" ]]
    grep -q '^install git$' "$CALLS_LOG"
    grep -q '^install badpkg$' "$CALLS_LOG"
    grep -q '^install curl$' "$CALLS_LOG"
}
