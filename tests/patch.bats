#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib patch
    RUN_STAMP="test"
    DRY_RUN=0
}
teardown() { teardown_tmpdir; }

@test "patch_write_if_different writes a new file" {
    patch_write_if_different new.conf "hello"
    [ "$PATCH_RESULT" = changed ]
    [ "$(cat new.conf)" = "hello" ]
}

@test "patch_write_if_different is a no-op when content matches" {
    printf 'hello\n' > same.conf
    patch_write_if_different same.conf "hello"
    [ "$PATCH_RESULT" = unchanged ]
}

@test "patch_write_if_different backs up the file it replaces" {
    printf 'old\n' > replaced.conf
    patch_write_if_different replaced.conf "new"
    [ -f "replaced.conf.bak-test" ]
    [ "$(cat replaced.conf.bak-test)" = "old" ]
}

@test "patch_backup does not overwrite an existing backup" {
    printf 'original\n' > f.conf
    patch_backup f.conf
    printf 'modified\n' > f.conf
    patch_backup f.conf
    [ "$(cat f.conf.bak-test)" = "original" ]
}

@test "patch_backup is a no-op for a missing file" {
    patch_backup absent.conf
    [ ! -e "absent.conf.bak-test" ]
}

@test "patch_kv_set replaces an existing key" {
    printf 'GRUB_TIMEOUT=5\nGRUB_DEFAULT=0\n' > grub
    patch_kv_set grub GRUB_TIMEOUT 0
    [ "$PATCH_RESULT" = changed ]
    grep -qx 'GRUB_TIMEOUT=0' grub
    grep -qx 'GRUB_DEFAULT=0' grub
}

@test "patch_kv_set uncomments and sets a commented key" {
    printf '#GRUB_DISABLE_OS_PROBER=false\n' > grub
    patch_kv_set grub GRUB_DISABLE_OS_PROBER false
    grep -qx 'GRUB_DISABLE_OS_PROBER=false' grub
    ! grep -q '^#GRUB_DISABLE_OS_PROBER' grub
}

@test "patch_kv_set appends a key that is absent" {
    printf 'GRUB_DEFAULT=0\n' > grub
    patch_kv_set grub GRUB_TIMEOUT_STYLE hidden
    grep -qx 'GRUB_TIMEOUT_STYLE=hidden' grub
}

@test "patch_kv_set is idempotent" {
    printf 'GRUB_TIMEOUT=5\n' > grub
    patch_kv_set grub GRUB_TIMEOUT 0
    [ "$PATCH_RESULT" = changed ]
    patch_kv_set grub GRUB_TIMEOUT 0
    [ "$PATCH_RESULT" = unchanged ]
    [ "$(grep -c 'GRUB_TIMEOUT' grub)" -eq 1 ]
}

@test "patch_ini_set sets a key inside an existing section" {
    printf '[General]\nFoo=1\n\n[Policy]\n#AutoEnable=false\n' > main.conf
    patch_ini_set main.conf Policy AutoEnable true
    [ "$PATCH_RESULT" = changed ]
    grep -qx 'AutoEnable=true' main.conf
    grep -qx 'Foo=1' main.conf
}

@test "patch_ini_set creates a missing section" {
    printf '[General]\nFoo=1\n' > main.conf
    patch_ini_set main.conf Policy AutoEnable true
    grep -qx '\[Policy\]' main.conf
    grep -qx 'AutoEnable=true' main.conf
}

@test "patch_ini_set does not touch a same-named key in another section" {
    printf '[A]\nKey=one\n[B]\nKey=two\n' > ini.conf
    patch_ini_set ini.conf B Key three
    grep -qx 'Key=one' ini.conf
    grep -qx 'Key=three' ini.conf
    ! grep -qx 'Key=two' ini.conf
}

@test "patch_ini_set appends the key when the section is last and empty" {
    printf '[General]\nFoo=1\n[Policy]\n' > main.conf
    patch_ini_set main.conf Policy AutoEnable true
    grep -qx 'AutoEnable=true' main.conf
}

@test "patch_ini_set is idempotent" {
    printf '[Policy]\n#AutoEnable=false\n' > main.conf
    patch_ini_set main.conf Policy AutoEnable true
    [ "$PATCH_RESULT" = changed ]
    patch_ini_set main.conf Policy AutoEnable true
    [ "$PATCH_RESULT" = unchanged ]
    [ "$(grep -c 'AutoEnable' main.conf)" -eq 1 ]
}

@test "patch_kv_set changes nothing during a dry run" {
    printf 'GRUB_TIMEOUT=5\n' > grub
    DRY_RUN=1
    patch_kv_set grub GRUB_TIMEOUT 0
    grep -qx 'GRUB_TIMEOUT=5' grub
}

@test "patch_write_if_different does not use sudo for a path we own" {
    # If sudo were invoked it would fail, and the write would not land.
    sudo() { echo "SUDO WAS CALLED" >&2; return 1; }
    patch_write_if_different "$TMPTEST/mine.conf" "hello"
    [ "$(cat "$TMPTEST/mine.conf")" = "hello" ]
}

@test "patch_write_if_different creates missing parent directories" {
    sudo() { echo "SUDO WAS CALLED" >&2; return 1; }
    patch_write_if_different "$TMPTEST/a/b/c/deep.conf" "nested"
    [ "$(cat "$TMPTEST/a/b/c/deep.conf")" = "nested" ]
}
