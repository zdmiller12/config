#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib patch
    load_lib apt
    RUN_STAMP="test"
    DRY_RUN=1          # compose commands without touching the machine
    APT_UPDATED=0
    APT_FAILED=()
}
teardown() { teardown_tmpdir; }

@test "apt_update_once runs update the first time" {
    # Capture via redirection rather than $(...): command substitution forks
    # a subshell, so APT_UPDATED=1 set inside apt_update_once would never be
    # visible here afterward.
    apt_update_once > "$TMPTEST/out.log" 2>&1
    output="$(cat "$TMPTEST/out.log")"
    [[ $output == *"apt-get update"* ]]
    [ "$APT_UPDATED" -eq 1 ]
}

@test "apt_update_once does not run update a second time" {
    apt_update_once > /dev/null 2>&1
    output="$(apt_update_once 2>&1)"
    [[ $output != *"apt-get update"* ]]
}

@test "apt_mark_stale forces another update" {
    apt_update_once > /dev/null 2>&1
    apt_mark_stale
    output="$(apt_update_once 2>&1)"
    [[ $output == *"apt-get update"* ]]
}

@test "apt_install with no arguments does nothing" {
    output="$(apt_install 2>&1)"
    [[ $output != *"apt-get install"* ]]
}

@test "apt_install composes a single batch install" {
    output="$(apt_install git curl 2>&1)"
    [[ $output == *"apt-get install -y git curl"* ]]
}

@test "apt_add_repo substitutes the keyring path into the sources line" {
    DRY_RUN=0
    SOURCES_DIR="$TMPTEST/sources"
    KEYRING_DIR="$TMPTEST/keyrings"
    mkdir -p "$SOURCES_DIR" "$KEYRING_DIR"
    # Pretend the keyring already exists so no network call is attempted.
    touch "$KEYRING_DIR/example.gpg"
    apt_add_repo example https://example.invalid/key.asc \
        'deb [signed-by=@KEYRING@] https://example.invalid/apt stable main'
    grep -q "signed-by=$KEYRING_DIR/example.gpg" "$SOURCES_DIR/example.list"
}

@test "apt_add_repo dearmors an ASCII-armored key but not a binary one" {
    DRY_RUN=0
    SOURCES_DIR="$TMPTEST/sources"
    KEYRING_DIR="$TMPTEST/keyrings"
    mkdir -p "$SOURCES_DIR" "$KEYRING_DIR" "$TMPTEST/bin"
    # Stub curl to serve local fixtures, and gpg to mark what it touched.
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nfake\n' > "$TMPTEST/armored.asc"
    printf '\x99\x01\x0dbinary-keyring-bytes' > "$TMPTEST/binary.gpg"
    cat > "$TMPTEST/bin/curl" <<'STUB'
#!/usr/bin/env bash
# curl -fsSL URL -o DEST
dest=""; url=""
while [[ $# -gt 0 ]]; do
  case $1 in -o) dest=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac
done
case $url in
  *armored*) cp "$FIXTURE_ARMORED" "$dest" ;;
  *) cp "$FIXTURE_BINARY" "$dest" ;;
esac
STUB
    cat > "$TMPTEST/bin/gpg" <<'STUB'
#!/usr/bin/env bash
# gpg --dearmor -o OUT   (reads stdin)
out=""
while [[ $# -gt 0 ]]; do
  case $1 in -o) out=$2; shift 2 ;; *) shift ;; esac
done
printf 'DEARMORED\n' > "$out"
STUB
    chmod +x "$TMPTEST/bin/curl" "$TMPTEST/bin/gpg"
    PATH="$TMPTEST/bin:$PATH"
    FIXTURE_ARMORED="$TMPTEST/armored.asc"
    FIXTURE_BINARY="$TMPTEST/binary.gpg"
    export FIXTURE_ARMORED FIXTURE_BINARY
    sudo() { "$@"; }

    apt_add_repo armoredrepo https://example.invalid/armored.asc 'deb https://x stable main'
    grep -q 'DEARMORED' "$KEYRING_DIR/armoredrepo.gpg"

    apt_add_repo binaryrepo https://example.invalid/keyring.gpg 'deb https://y stable main'
    ! grep -q 'DEARMORED' "$KEYRING_DIR/binaryrepo.gpg"
    grep -q 'binary-keyring-bytes' "$KEYRING_DIR/binaryrepo.gpg"
}

@test "apt_add_repo is idempotent and only marks stale on change" {
    DRY_RUN=0
    SOURCES_DIR="$TMPTEST/sources"
    KEYRING_DIR="$TMPTEST/keyrings"
    mkdir -p "$SOURCES_DIR" "$KEYRING_DIR"
    touch "$KEYRING_DIR/example.gpg"
    apt_add_repo example https://example.invalid/key.asc 'deb https://example.invalid/apt stable main'
    APT_UPDATED=1
    apt_add_repo example https://example.invalid/key.asc 'deb https://example.invalid/apt stable main'
    [ "$APT_UPDATED" -eq 1 ]
}

@test "apt_install isolates a failing package and keeps installing the rest" {
    DRY_RUN=0
    mkdir -p "$TMPTEST/bin"
    CALLS_LOG="$TMPTEST/apt-get.calls"
    : > "$CALLS_LOG"
    export CALLS_LOG
    # Stub apt-get: the batch call (more than one package) always fails;
    # individual calls fail only for "badpkg". Every invocation is logged
    # so we can confirm the other packages were still attempted.
    cat > "$TMPTEST/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS_LOG"
case "$1" in
  update) exit 0 ;;
  install)
    shift 2
    if [[ $# -gt 1 ]]; then
      exit 1
    fi
    [[ $1 == badpkg ]] && exit 1
    exit 0
    ;;
esac
STUB
    chmod +x "$TMPTEST/bin/apt-get"
    PATH="$TMPTEST/bin:$PATH"
    sudo() { "$@"; }

    local result
    apt_install git badpkg curl
    result=$?

    [ "$result" -eq 0 ]
    [ "${#APT_FAILED[@]}" -eq 1 ]
    [[ "${APT_FAILED[0]}" == "badpkg" ]]
    grep -q '^install -y git$' "$CALLS_LOG"
    grep -q '^install -y badpkg$' "$CALLS_LOG"
    grep -q '^install -y curl$' "$CALLS_LOG"
}

@test "apt_add_repo under dry-run touches neither keyring nor sources file" {
    SOURCES_DIR="$TMPTEST/sources"
    KEYRING_DIR="$TMPTEST/keyrings"
    mkdir -p "$SOURCES_DIR" "$KEYRING_DIR"
    apt_add_repo example https://example.invalid/key.asc \
        'deb [signed-by=@KEYRING@] https://example.invalid/apt stable main' > /dev/null 2>&1
    [ ! -e "$KEYRING_DIR/example.gpg" ]
    [ ! -e "$SOURCES_DIR/example.list" ]
}
