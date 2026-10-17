# shellcheck shell=bash
# Check-then-patch helpers for config files. Every setter is idempotent and
# sets PATCH_RESULT to "changed" or "unchanged".

PATCH_RESULT=unchanged

# _patch_needs_sudo FILE — true when we cannot write the path as ourselves.
# Without this, a write to ~/.gitconfig.local would go through `sudo tee` and
# leave a root-owned file in the user's own home that they cannot edit.
_patch_needs_sudo() {
    local file=$1 dir
    dir=$(dirname "$file")
    # Walk up to the nearest existing ancestor; missing parents will be
    # created under the same permissions as that ancestor.
    while [[ ! -d $dir ]]; do
        dir=$(dirname "$dir")
    done
    [[ -w $dir ]] || return 0
    [[ ! -e $file || -w $file ]] || return 0
    return 1
}

# patch_backup FILE — copy to FILE.bak-$RUN_STAMP, once per run.
patch_backup() {
    local file=$1
    [[ -e $file ]] || return 0
    local bak="$file.bak-$RUN_STAMP"
    [[ -e $bak ]] && return 0
    if _patch_needs_sudo "$file"; then
        run_sudo cp -a "$file" "$bak"
    else
        run cp -a "$file" "$bak"
    fi
}

# patch_write_if_different FILE CONTENT
patch_write_if_different() {
    local file=$1 content=$2
    if [[ -f $file ]] && [[ "$(cat "$file")" == "$content" ]]; then
        PATCH_RESULT=unchanged
        return 0
    fi
    # Public result flag, read by callers of the three setters.
    # shellcheck disable=SC2034
    PATCH_RESULT=changed
    patch_backup "$file"
    if (( DRY_RUN )); then
        _log DRY '0;36' "write $file (content differs)"
        return 0
    fi
    _log CMD '' "write $file"
    local dir
    dir=$(dirname "$file")
    if _patch_needs_sudo "$file"; then
        run_sudo install -d -m 0755 "$dir"
        printf '%s\n' "$content" | sudo tee "$file" > /dev/null
    else
        run mkdir -p "$dir"
        printf '%s\n' "$content" > "$file"
    fi
}

# patch_kv_set FILE KEY VALUE — section-less KEY=VALUE files.
# Replaces the key whether it is active or commented out; appends if absent.
# KEY is interpolated unescaped into an awk regex, so it must be a plain
# identifier (alphanumerics and underscores) — a key containing ., *, or [
# would silently fail to match and be appended as a duplicate.
patch_kv_set() {
    local file=$1 key=$2 value=$3 content
    [[ -f $file ]] || { patch_write_if_different "$file" "$key=$value"; return 0; }
    content=$(awk -v key="$key" -v value="$value" '
        BEGIN { done = 0 }
        {
            if (!done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") {
                print key "=" value
                done = 1
                next
            }
            print
        }
        END { if (!done) print key "=" value }
    ' "$file")
    patch_write_if_different "$file" "$content"
}

# patch_ini_set FILE SECTION KEY VALUE — sectioned INI files.
# Creates the section if it is absent; only touches the key inside SECTION.
# KEY is interpolated unescaped into an awk regex, so it must be a plain
# identifier (alphanumerics and underscores) — a key containing ., *, or [
# would silently fail to match and be appended as a duplicate.
patch_ini_set() {
    local file=$1 section=$2 key=$3 value=$4 content
    if [[ ! -f $file ]]; then
        patch_write_if_different "$file" "[$section]
$key=$value"
        return 0
    fi
    content=$(awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { insec = 0; done = 0 }
        # Any section header.
        /^[[:space:]]*\[/ {
            # Leaving the target section without having set the key.
            if (insec && !done) { print key "=" value; done = 1 }
            insec = ($0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$")
            print
            next
        }
        {
            if (insec && !done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") {
                print key "=" value
                done = 1
                next
            }
            print
        }
        END {
            if (done) { }
            else if (insec) { print key "=" value }
            else { print "[" section "]"; print key "=" value }
        }
    ' "$file")
    patch_write_if_different "$file" "$content"
}
